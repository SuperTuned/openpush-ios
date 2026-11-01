import Foundation
import OpenPushCore
#if canImport(UIKit)
import UIKit
#endif

/// Receive-only OpenPush client: APNs registration and delivery receipts.
/// There is intentionally no message creation or send surface in this module.
public enum OpenPush {
    public typealias Transport = @Sendable (
        URLRequest, @escaping @Sendable (Int, String) -> Void
    ) -> Void

    struct ScheduledWork: Sendable {
        let cancel: @Sendable () -> Void
    }

    struct SessionDurationReport: Sendable {
        let token: String
        let seconds: TimeInterval
        let id: String
    }

    private final class DispatchScheduledWork: @unchecked Sendable {
        let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) {
            self.item = item
        }
    }

    struct Scheduler: Sendable {
        var run: @Sendable (_ afterSeconds: Double,
                            _ work: @escaping @Sendable () -> Void) -> ScheduledWork

        static let system = Scheduler { seconds, work in
            let item = DispatchWorkItem(block: work)
            let scheduled = DispatchScheduledWork(item)
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + seconds, execute: item)
            return ScheduledWork { scheduled.item.cancel() }
        }
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var configuration: OpenPushConfiguration?
        private var token: String?
        private var credential: @Sendable () -> String? = { nil }
        /// The sink a process starts with. A debug build prints, because an SDK
        /// that says nothing while you are integrating it is the harder bug. A
        /// release build says nothing at all: `print` reaches the device console
        /// of every install, and none of this is the host's diagnostics to emit.
        /// Set `OpenPush.onLog` to route it wherever the app already logs.
        static let defaultLogSink: @Sendable (String) -> Void = {
            #if DEBUG
            return { print("[OpenPush] \($0)") }
            #else
            return { _ in }
            #endif
        }()
        private var log: @Sendable (String) -> Void = State.defaultLogSink
        /// Set by a wrapper SDK before `initialize`, so it is deliberately not
        /// part of the configuration `attach` replaces: the wrapper identifies
        /// the binary, not the workspace.
        private var wrapper: OpenPush.SDKWrapper?
        private var registered: @Sendable () -> Void = {}
        private var registrationFailed: @Sendable (String) -> Void = { _ in }
        private var transport: Transport = OpenPush.urlSessionTransport
        private var scheduler = OpenPush.Scheduler.system
        private var writeWindowOpen = false
        private var writeWindow: OpenPush.ScheduledWork?
        private var registrationGeneration = 0
        private var waiters: [(generation: Int,
                               completion: @Sendable (OpenPush.RegistrationResult) -> Void)] = []
        private var pendingRetry: OpenPush.ScheduledWork?
        private var lastAppSessionAt: TimeInterval = 0
        private var foregroundStartedAt: TimeInterval = 0
        private var pendingSessionDuration: TimeInterval = 0
        private var pendingSessionDurationID: String?
        private var sessionDurationInFlightID: String?
        private var appSessionClock: @Sendable () -> TimeInterval = {
            Date().timeIntervalSince1970
        }
        /// Where the registration body's language comes from. Production reads the
        /// device's preference list; tests substitute a closure. Lock-guarded like
        /// every other seam here, because Swift 6 has no mutable global shared state.
        private var preferredLanguage: @Sendable () -> String? = {
            Locale.preferredLanguages.first
        }
        /// Whether this process can actually read what it stored. A background
        /// launch before the device's first unlock sees an empty `UserDefaults`,
        /// and writing that emptiness back would destroy the real session.
        /// Production asks UIKit; tests substitute a closure.
        private var protectedData: @Sendable () -> Bool = OpenPush.systemProtectedDataAvailable
        /// The last reading taken where it is safe to take one: on the main
        /// thread, or from UIKit's own protected-data notifications, which are
        /// delivered there. `nil` until one of those has happened.
        private var protectedDataCache: Bool?
        /// Hands the closure out rather than calling it: invoking it while this
        /// lock is held would run host code under the lock.
        var protectedDataAvailable: @Sendable () -> Bool { lock.withLock { protectedData } }
        func setProtectedDataAvailable(_ value: @escaping @Sendable () -> Bool) {
            // A new reading makes the old answer meaningless, and a test that
            // swaps the seam must not be told what the last one said.
            lock.withLock { protectedData = value; protectedDataCache = nil }
        }

        /// What UIKit's notifications say, recorded on the main thread where
        /// they arrive.
        func cacheProtectedData(_ value: Bool) {
            lock.withLock { protectedDataCache = value }
        }

        /// Whether this process can read what it stored, without touching
        /// `UIApplication` off the main thread.
        ///
        /// On the main thread the property is read directly and the answer is
        /// kept, so the cache is never staler than the last main-thread pass.
        /// Off it, the cached answer is used — the notifications keep it true
        /// from the device's first unlock onwards, which is every launch past
        /// the first, and they are the only thing that can change it.
        ///
        /// Off the main thread before any notification or main-thread reading
        /// has populated the cache, return false conservatively. A
        /// `DispatchQueue.main.sync` hop was rejected outright: `attach` is
        /// documented as callable from anywhere, and a host that initializes
        /// from `main` behind a lock of its own would deadlock on it. Treating
        /// the store as unreadable defers restoration without risking a write
        /// over protected state.
        ///
        /// A cached `true` can go stale across a suspension — the device locks
        /// again while the app is suspended and the relock notification is not
        /// delivered until it resumes. Harmless: everything this cache gates is
        /// stored in `UserDefaults.standard`, which is
        /// `CompleteUntilFirstUserAuthentication`, so it stays readable from the
        /// device's first unlock until the next boot however often the screen
        /// locks afterwards. The reading only has to be right about that first
        /// unlock, and once it is true it stays true for the life of the boot.
        ///
        /// Never call under `lock`.
        func protectedDataReadable() -> Bool {
            let (seam, cached) = lock.withLock { (protectedData, protectedDataCache) }
            guard Thread.isMainThread else { return cached ?? false }
            let value = seam()
            lock.withLock { protectedDataCache = value }
            return value
        }
        /// How long a request that runs while the app is backgrounded may keep the
        /// process alive. Production asks UIKit; the macOS host and the tests
        /// substitute a closure pair so begin/end pairing stays observable.
        private var backgroundAssertion = OpenPush.BackgroundAssertion.system
        var backgroundAssertionSeam: OpenPush.BackgroundAssertion {
            lock.withLock { backgroundAssertion }
        }
        func setBackgroundAssertion(_ value: OpenPush.BackgroundAssertion) {
            lock.withLock { backgroundAssertion = value }
        }
        /// Spreads retries so a fleet that failed together does not come back
        /// together. Production draws a random factor; tests pin it.
        private var retryJitter: @Sendable (Double) -> Double = OpenPush.systemRetryJitter
        var retryJitterSeam: @Sendable (Double) -> Double { lock.withLock { retryJitter } }
        func setRetryJitter(_ value: @escaping @Sendable (Double) -> Double) {
            lock.withLock { retryJitter = value }
        }
        /// Set when a first attach could not read the stored session. While it is
        /// true this process writes nothing back — not the session blob, not the
        /// Live Activity types, not the App Group mirror — because everything it
        /// would write is empty by accident rather than by intent.
        private var sessionRestorePending = false
        /// Set when a login or logout happened while the restore was still
        /// pending. The stored blob then belongs to whoever this install was
        /// before that call, so its identity, tags and aliases are dropped on the
        /// deferred restore instead of being merged onto the person holding the
        /// install now.
        private var discardStoredUserDataOnRestore = false
        /// True once an accepted registration carried the identity held now. A
        /// login or logout whose registration never landed changed nothing the
        /// server can see, so repeating it must register rather than report a
        /// success that only happened locally. Deliberately not persisted: a
        /// relaunch re-registers anyway.
        private var identityDelivered = false

        static func sessionKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".session"
        }

        enum AttachKind: Sendable { case first, repeated, workspaceSwitch }

        private func attachKindLocked(for value: OpenPushConfiguration) -> AttachKind {
            guard let previous = configuration else { return .first }
            return previous == value ? .repeated : .workspaceSwitch
        }

        /// Decides what a call to `attach` means. The FIRST attach restores the
        /// session a previous process persisted and keeps anything the host staged
        /// before initializing. A REPEATED attach with an identical configuration
        /// (SwiftUI `App.init` plus `didFinishLaunching`, or an init-after-login
        /// pattern) changes nothing: clearing here would lose the host's data. Only
        /// a DIFFERENT configuration is a workspace switch, and carrying one
        /// workspace's identity into another would leak it, so that path clears.
        ///
        /// The token key and App Group of the configuration being replaced come back
        /// with the kind, so a caller that has its own storage to clear — the in-app
        /// engine, the Custom Event queue, the receipt queue and the App Group
        /// mirror all do — can do it after this returns, outside `State`'s lock.
        /// None of them may be called from in here: each takes a lock of its own
        /// and reads `State` back through it, so nesting the two in this order is
        /// the inversion half of a deadlock.
        @discardableResult
        func setup(_ value: OpenPushConfiguration,
                   credential: @escaping @Sendable () -> String?,
                   transport: @escaping Transport)
            -> (kind: AttachKind, previousTokenKey: String?, previousAppGroup: String?,
                strandedWaiters: [@Sendable (OpenPush.RegistrationResult) -> Void]) {
            // A repeated attach interrupts nothing: the coalescing window a host
            // opened moments earlier still fires on its own timer, so tags staged
            // just before the second `initialize` are not left waiting for the next
            // write. The cancels run outside the lock, and only where the state they
            // would have flushed is about to be thrown away anyway.
            // Cancelling that retry ends the only chain that was ever going to
            // answer a `register`/`login` completion riding it: the failure that
            // armed it reported nothing, and the configuration being installed
            // here may never register at all. Its waiters are taken now, while
            // the generation is still the one they belong to, and handed back
            // for the caller to call outside this lock and after the new
            // configuration is in place — never from in here, and never before,
            // or a host that registers from its completion would register
            // against the workspace it is leaving. A `.repeated` attach keeps
            // the retry, so it keeps the waiters with it.
            var strandedWaiters: [@Sendable (OpenPush.RegistrationResult) -> Void] = []
            if lock.withLock({ attachKindLocked(for: value) }) != .repeated {
                cancelWriteWindow()
                if cancelPendingRetry() {
                    strandedWaiters = drainWaiters(upTo: currentRegistrationGeneration)
                }
            }
            // Read before the lock is taken, never under it: the reading can
            // reach UIKit, and host code has no business running under `State`.
            let storeIsReadable = protectedDataReadable()
            return lock.withLock {
                let previous = configuration
                let kind = attachKindLocked(for: value)
                configuration = value
                self.credential = credential
                self.transport = transport
                switch kind {
                case .repeated:
                    break
                case .first:
                    // Same reason as the switch below, and the same bump
                    // `beginRegistration` makes: nothing a registration started
                    // before this configuration existed may retry against it.
                    registrationGeneration += 1
                    subscriptionID = nil
                    permissionGranted = false
                    permissionStatus = .notDetermined
                    lastSentStatus = nil
                    // A launch before the device's first unlock reads an empty
                    // store. Restoring from it would report a session this
                    // device does not have, and persisting that back would
                    // destroy the real one. Wait for the unlock instead.
                    sessionRestorePending = !storeIsReadable
                    discardStoredUserDataOnRestore = false
                    if storeIsReadable {
                        restoreSessionLocked(tokenKey: value.tokenKey)
                        restoreLiveActivityTypesLocked(tokenKey: value.tokenKey)
                        persistSessionLocked()
                    }
                case .workspaceSwitch:
                    // The cancels above closed the write window and the retry
                    // that was already armed, but they run before this lock is
                    // taken. A failure response landing in the gap arms a fresh
                    // retry, and the only thing standing between it and the new
                    // workspace is this counter — it would otherwise fire the
                    // previous workspace's token, tags and identity at the new
                    // app id. Bumped here, exactly as `beginRegistration` does,
                    // so every registration started under the old configuration
                    // is stale the moment the new one is installed.
                    registrationGeneration += 1
                    subscriptionID = nil
                    permissionGranted = false
                    permissionStatus = .notDetermined
                    lastSentStatus = nil
                    identity = .anonymous
                    identityAwaitsAuthHash = false
                    identityDelivered = false
                    verificationRequested = false
                    pendingVerification = nil
                    tags.removeAll()
                    aliases.removeAll()
                    notificationTypes = OpenPush.notificationTypesNeverPrompted
                    optedOut = false
                    prompted = false
                    lastAppSessionAt = 0
                    foregroundStartedAt = 0
                    pendingSessionDuration = 0
                    pendingSessionDurationID = nil
                    sessionDurationInFlightID = nil
                    liveActivityTypes.removeAll()
                    // A switch is a host decision rather than a launch, but the
                    // store it has to read is the same one, and before the
                    // device's first unlock it answers nothing. Leaving the
                    // restore disarmed there would let the attach's first
                    // `syncNotificationTypes` write replace the workspace being
                    // entered with an empty session — the very loss the `.first`
                    // branch defers for. `restorePendingSession` reads the token
                    // key when it runs, not when the flag was set, so a further
                    // switch before the unlock still restores the workspace the
                    // host is actually in.
                    sessionRestorePending = !storeIsReadable
                    discardStoredUserDataOnRestore = false
                    // Only the workspace being left. A host that keeps the
                    // default token key gives both workspaces the same key, so
                    // this still clears the one blob they share — but a host
                    // that gave each workspace a key of its own is entering a
                    // workspace with a history, and erasing it here would throw
                    // away state this switch was never told to touch.
                    if let leaving = previous?.tokenKey {
                        UserDefaults.standard.removeObject(
                            forKey: State.sessionKey(forTokenKey: leaving))
                        UserDefaults.standard.removeObject(
                            forKey: State.liveActivityTypesKey(forTokenKey: leaving))
                        UserDefaults.standard.removeObject(
                            forKey: LiveActivityExecutor.storageKey(forTokenKey: leaving))
                    }
                    // Entering a workspace has to read that workspace back,
                    // exactly as launching straight into it would. Keeping the
                    // blob is not enough on its own: the attach goes on to sync
                    // notification types, and that first write would replace a
                    // session nothing had read with an empty one. Where both
                    // workspaces share a token key this reads what was just
                    // deleted — nothing — and the switch stays the clean slate
                    // it has always been.
                    if storeIsReadable {
                        restoreSessionLocked(tokenKey: value.tokenKey)
                        restoreLiveActivityTypesLocked(tokenKey: value.tokenKey)
                        persistSessionLocked()
                    }
                }
                return (kind, previous?.tokenKey, previous?.appGroup, strandedWaiters)
            }
        }

        /// Finishes an attach that happened before the device's first unlock: the
        /// stored session is readable now, so restore it, write the merged result
        /// back, and bring the subscription's notification types in line with the
        /// permission this process never got to read.
        ///
        /// Idempotent. A second notification, a call with nothing pending, or a
        /// call while the files are still locked all do nothing. The token key is
        /// read here rather than captured when the flag was set, so a workspace
        /// switch in between restores the workspace the host is actually in.
        func restorePendingSession() {
            guard lock.withLock({ sessionRestorePending }), protectedDataReadable() else { return }
            let (restored, discarded, mirror) = lock.withLock {
                () -> (Bool, Bool, SharedStateMirror?) in
                guard sessionRestorePending,
                      let tokenKey = configuration?.tokenKey else { return (false, false, nil) }
                sessionRestorePending = false
                let discarding = discardStoredUserDataOnRestore
                restoreSessionLocked(tokenKey: tokenKey)
                restoreLiveActivityTypesLocked(tokenKey: tokenKey)
                // `attach` looked for the cached token while the file was still
                // unreadable and found nothing. It is there now.
                if token == nil { token = UserDefaults.standard.string(forKey: tokenKey) }
                persistSessionLocked()
                persistLiveActivityTypesLocked()
                return (true, discarding, sharedStateLocked())
            }
            guard restored else { return }
            // Outside the lock, exactly as every other App Group write is.
            if let mirror { OpenPushSharedState.save(mirror.value, appGroup: mirror.appGroup) }
            OpenPush.onLog("• stored session restored after first unlock")
            if discarded {
                OpenPush.onLog("• the stored user's identity, tags and aliases were dropped — " +
                               "a login or logout replaced them while the store was locked")
            }
            OpenPush.Notifications.refreshPermission {
                OpenPush.Notifications.syncNotificationTypes($0)
            }
        }

        /// The first-ever `attach` keeps session state the host set before it, while
        /// a differently configured one clears it, and `OpenPush.state` is a
        /// process-global that the whole test suite shares. This is what lets a test
        /// reach the first-attach branch at all. In-memory only: it never touches
        /// `UserDefaults`.
        func resetAsIfTheProcessJustStarted() {
            lock.withLock {
                configuration = nil
                token = nil
                identity = .anonymous
                identityAwaitsAuthHash = false
                verificationRequested = false
                pendingVerification = nil
                tags.removeAll()
                aliases.removeAll()
                subscriptionID = nil
                notificationTypes = OpenPush.notificationTypesNeverPrompted
                optedOut = false
                lastSentStatus = nil
                prompted = false
                permissionGranted = false
                permissionStatus = .notDetermined
                lastObservedPermission = nil
                lastObservedSubscription = nil
                applicationIsActive = false
                liveActivityTypes.removeAll()
                lastAppSessionAt = 0
                foregroundStartedAt = 0
                pendingSessionDuration = 0
                pendingSessionDurationID = nil
                sessionDurationInFlightID = nil
                sessionRestorePending = false
                discardStoredUserDataOnRestore = false
                identityDelivered = false
                appSessionClock = { Date().timeIntervalSince1970 }
                pendingClicks.removeAll()
                wrapper = nil
            }
        }

        var config: OpenPushConfiguration? { lock.withLock { configuration } }
        var currentToken: String? { lock.withLock { token } }
        func setToken(_ value: String?, persist: Bool) {
            let (key, mirror) = lock.withLock {
                token = value
                return (configuration?.tokenKey, sharedStateLocked())
            }
            if persist, let key { UserDefaults.standard.set(value, forKey: key) }
            // Outside the lock: an App Group write goes through UserDefaults and has
            // no business happening while `State` is held.
            if persist, let mirror {
                OpenPushSharedState.save(mirror.value, appGroup: mirror.appGroup)
            }
        }
        var logSink: @Sendable (String) -> Void { lock.withLock { log } }
        var sdkWrapper: OpenPush.SDKWrapper? { lock.withLock { wrapper } }
        func setSDKWrapper(_ value: OpenPush.SDKWrapper?) {
            lock.withLock { wrapper = value }
        }
        func setLog(_ value: @escaping @Sendable (String) -> Void) {
            lock.withLock { log = value }
        }
        var registeredHook: @Sendable () -> Void { lock.withLock { registered } }
        func setRegistered(_ value: @escaping @Sendable () -> Void) {
            lock.withLock { registered = value }
        }
        var registrationFailedHook: @Sendable (String) -> Void {
            lock.withLock { registrationFailed }
        }
        func setRegistrationFailed(_ value: @escaping @Sendable (String) -> Void) {
            lock.withLock { registrationFailed = value }
        }
        var deviceCredential: String? { lock.withLock { credential }() }
        var requestTransport: Transport { lock.withLock { transport } }
        func setAppSessionClock(_ value: @escaping @Sendable () -> TimeInterval) {
            lock.withLock { appSessionClock = value }
        }
        var appSessionClockSeam: @Sendable () -> TimeInterval {
            lock.withLock { appSessionClock }
        }
        var preferredLanguageSeam: @Sendable () -> String? {
            lock.withLock { preferredLanguage }
        }
        func setPreferredLanguageSeam(_ value: @escaping @Sendable () -> String?) {
            lock.withLock { preferredLanguage = value }
        }
        func claimAppSessionToken() -> String? {
            lock.withLock {
                guard let token else { return nil }
                let observedAt = appSessionClock()
                if lastAppSessionAt > 0,
                   observedAt - lastAppSessionAt < OpenPush.appSessionMinimumInterval {
                    return nil
                }
                lastAppSessionAt = observedAt
                persistSessionLocked()
                return token
            }
        }

        private func claimSessionDurationLocked() -> OpenPush.SessionDurationReport? {
            guard sessionDurationInFlightID == nil,
                  pendingSessionDuration >= 1,
                  let id = pendingSessionDurationID,
                  let token else { return nil }
            let seconds = min(OpenPush.maxSessionDuration, floor(pendingSessionDuration))
            guard seconds > 0 else { return nil }
            sessionDurationInFlightID = id
            return OpenPush.SessionDurationReport(token: token, seconds: seconds, id: id)
        }

        func beginForegroundSession() -> OpenPush.SessionDurationReport? {
            lock.withLock {
                if foregroundStartedAt == 0 { foregroundStartedAt = appSessionClock() }
                return claimSessionDurationLocked()
            }
        }

        func finishForegroundSession() -> OpenPush.SessionDurationReport? {
            lock.withLock {
                let endedAt = appSessionClock()
                if foregroundStartedAt > 0, endedAt > foregroundStartedAt {
                    pendingSessionDuration += endedAt - foregroundStartedAt
                    if pendingSessionDurationID == nil {
                        pendingSessionDurationID = UUID().uuidString
                    }
                }
                foregroundStartedAt = 0
                persistSessionLocked()
                return claimSessionDurationLocked()
            }
        }

        func settleSessionDuration(_ report: OpenPush.SessionDurationReport,
                                   status: Int) {
            lock.withLock {
                if sessionDurationInFlightID == report.id {
                    sessionDurationInFlightID = nil
                }
                guard (200...299).contains(status) || (400...499).contains(status),
                      pendingSessionDurationID == report.id else { return }
                pendingSessionDuration = max(0, pendingSessionDuration - report.seconds)
                pendingSessionDurationID = pendingSessionDuration == 0
                    ? nil : UUID().uuidString
                persistSessionLocked()
            }
        }

        func cancelSessionDuration(_ report: OpenPush.SessionDurationReport) {
            lock.withLock {
                if sessionDurationInFlightID == report.id {
                    sessionDurationInFlightID = nil
                }
            }
        }

        var pendingSessionDurationSeconds: TimeInterval {
            lock.withLock { pendingSessionDuration }
        }
        var schedulerSeam: OpenPush.Scheduler { lock.withLock { scheduler } }
        func setScheduler(_ value: OpenPush.Scheduler) {
            lock.withLock { scheduler = value }
        }
        var hasOpenWriteWindow: Bool { lock.withLock { writeWindowOpen } }
        @discardableResult
        func scheduleWriteFlush(after seconds: Double,
                                _ flush: @escaping @Sendable () -> Void) -> Bool {
            let scheduler: OpenPush.Scheduler? = lock.withLock {
                guard !writeWindowOpen else { return nil }
                writeWindowOpen = true
                return self.scheduler
            }
            guard let scheduler else { return false }
            let handle = scheduler.run(seconds) { [self] in
                let due: Bool = lock.withLock {
                    guard writeWindowOpen else { return false }
                    writeWindowOpen = false
                    writeWindow = nil
                    return true
                }
                if due { flush() }
            }
            lock.withLock {
                if writeWindowOpen { writeWindow = handle }
            }
            return true
        }
        func cancelWriteWindow() {
            let handle: OpenPush.ScheduledWork? = lock.withLock {
                let current = writeWindow
                writeWindow = nil
                writeWindowOpen = false
                return current
            }
            handle?.cancel()
        }
        func beginRegistration(
            completion: (@Sendable (OpenPush.RegistrationResult) -> Void)?
        ) -> Int {
            lock.withLock {
                registrationGeneration += 1
                if let completion {
                    waiters.append((registrationGeneration, completion))
                }
                return registrationGeneration
            }
        }
        var currentRegistrationGeneration: Int {
            lock.withLock { registrationGeneration }
        }
        func drainWaiters(upTo generation: Int)
            -> [@Sendable (OpenPush.RegistrationResult) -> Void] {
            lock.withLock {
                let due = waiters
                    .filter { $0.generation <= generation }
                    .map(\.completion)
                waiters.removeAll { $0.generation <= generation }
                return due
            }
        }
        func setPendingRetry(_ handle: OpenPush.ScheduledWork?) {
            lock.withLock { pendingRetry = handle }
        }
        /// True when there was a retry to cancel. `setup` needs the answer:
        /// a cancelled retry is a chain that will never report, and whoever was
        /// waiting on it has to be told so.
        @discardableResult
        func cancelPendingRetry() -> Bool {
            let handle: OpenPush.ScheduledWork? = lock.withLock {
                let current = pendingRetry
                pendingRetry = nil
                return current
            }
            handle?.cancel()
            return handle != nil
        }

        private var subscriptionID: String?
        var currentSubscriptionID: String? { lock.withLock { subscriptionID } }
        func setSubscriptionID(_ value: String?) {
            let mirror = lock.withLock { () -> SharedStateMirror? in
                subscriptionID = value
                persistSessionLocked()
                return sharedStateLocked()
            }
            if let mirror { OpenPushSharedState.save(mirror.value, appGroup: mirror.appGroup) }
        }
        /// D6: the server may legitimately answer with a status this device did
        /// not send — a carried opt-out onto a new row, or opt-out precedence.
        /// Adopt the opt-out axis only; every other negative stays reported.
        func adoptServerStatus(_ status: Int) {
            lock.withLock {
                if status == OpenPush.optedOutStatus { optedOut = true }
                else if status > 0 { optedOut = false }
                else { return }
                persistSessionLocked()
            }
        }

        private var identity: OpenPush.Identity = .anonymous
        var currentIdentity: OpenPush.Identity { lock.withLock { identity } }
        /// `clearUserData` scopes tags and aliases to the identity: a switch to a
        /// different identified user, or a logout, must not carry the previous
        /// person's targeting data into the next body (D4).
        func setIdentity(_ value: OpenPush.Identity, clearUserData: Bool = false) {
            lock.withLock {
                identity = value
                // Nothing the server has accepted describes this identity yet.
                identityDelivered = false
                // A proof is owed for one asserted id; dropping the id drops the debt.
                switch value {
                case .identified: break
                case .anonymous, .detached: identityAwaitsAuthHash = false
                }
                if clearUserData {
                    noteStoredUserDataIsStaleLocked()
                    tags.removeAll()
                    aliases.removeAll()
                }
                persistSessionLocked()
            }
        }

        /// What `login` did, so the caller knows whether a registration is owed.
        enum LoginOutcome: Sendable, Equatable {
            /// Already this person, with no fresh proof to carry: nothing changed.
            case unchanged
            /// The identity was adopted. `switchedUsers` is true when a different
            /// identified user was replaced and their tags and aliases were cleared.
            case adopted(switchedUsers: Bool)
        }

        /// Decides and applies a login under one lock acquisition, so a concurrent
        /// call cannot slip between reading the identity and replacing it.
        func applyLogin(externalID: String, authHash: String?) -> LoginOutcome {
            lock.withLock {
                let carriesNewHash = !(authHash?.isEmpty ?? true)
                // `identityDelivered` is what keeps a repeat login honest: a first
                // login whose registration failed left the server knowing nothing,
                // so answering `.unchanged` would strand this person as anonymous.
                if case .identified(let current, _) = identity, current == externalID,
                   !carriesNewHash, !needsAuthHashLocked, identityDelivered {
                    return .unchanged
                }
                var switchedUsers = false
                if case .identified(let current, _) = identity, current != externalID {
                    switchedUsers = true
                    tags.removeAll()
                    aliases.removeAll()
                }
                identity = .identified(externalID: externalID, authHash: authHash)
                identityAwaitsAuthHash = authHash != nil
                identityDelivered = false
                // Inside the deferred-restore window the stored blob belongs to
                // whoever this install was before this call — and it cannot be read
                // to find out who that was — so it must not be merged onto this
                // person. Anything staged locally is this person's and stays.
                noteStoredUserDataIsStaleLocked()
                persistSessionLocked()
                return .adopted(switchedUsers: switchedUsers)
            }
        }

        /// Detaches an identified install. Answers true when a registration is
        /// owed: either the identity just changed, or an earlier detach never
        /// reached the server. Whatever the answer, this install stops holding
        /// staged tags and aliases — a logout is a statement that it carries
        /// nobody's data, and an anonymous install can hold data too.
        func applyLogout() -> Bool {
            lock.withLock {
                defer {
                    tags.removeAll()
                    aliases.removeAll()
                    noteStoredUserDataIsStaleLocked()
                    persistSessionLocked()
                }
                switch identity {
                case .identified:
                    identity = .detached
                    identityDelivered = false
                    return true
                case .detached:
                    // A detach whose registration failed was never applied
                    // anywhere: repeating it is the only way the server hears it.
                    return !identityDelivered
                case .anonymous:
                    return false
                }
            }
        }

        /// The stored session predates the identity change being applied, so the
        /// deferred restore must keep its subscription id and status axes and drop
        /// its identity, tags and aliases. A no-op once the restore has run.
        private func noteStoredUserDataIsStaleLocked() {
            guard sessionRestorePending else { return }
            discardStoredUserDataOnRestore = true
        }

        /// Records whether the registration that was just accepted carried the
        /// identity this install holds now. A body that carried someone else's id —
        /// a superseded chain, or an id replaced while the request was in flight —
        /// proves nothing about the identity held here.
        func noteIdentityDelivered(externalIDInBody: String?) {
            lock.withLock {
                switch identity {
                case .identified(let externalID, _):
                    identityDelivered = externalIDInBody == externalID
                case .detached:
                    // Present-and-empty is the detach; an absent key is not.
                    identityDelivered = externalIDInBody == ""
                case .anonymous:
                    identityDelivered = false
                }
            }
        }

        /// True when the last `login` supplied an auth hash. Persisted (the hash is
        /// not), so a relaunch knows this identity may only be asserted with proof.
        private var identityAwaitsAuthHash = false
        private var verificationRequested = false
        private var pendingVerification: String?
        private var hookInstalled = false
        private var identityVerificationRequired: @Sendable (String) -> Void = { _ in }
        var identityNeedsAuthHash: Bool { lock.withLock { needsAuthHashLocked } }
        /// The identity is asserted but its proof is missing, so registrations
        /// leave the server-side link alone until the host supplies the hash.
        private var needsAuthHashLocked: Bool {
            guard identityAwaitsAuthHash,
                  case .identified(_, let hash) = identity, hash == nil else { return false }
            return true
        }
        func setIdentityRequiresAuthHash(_ value: Bool) {
            lock.withLock { identityAwaitsAuthHash = value; persistSessionLocked() }
        }
        static func verificationNeededMessage(_ externalID: String) -> String {
            "• identity \(externalID) needs its auth hash again — call " +
            "login(externalId:authHash:); until then registrations leave the " +
            "server-side link untouched"
        }
        /// Notes, once per process, that the restored identity may not be asserted
        /// until the host supplies its hash again. The id comes back only when a
        /// hook is already installed, so `attach` can fire it immediately; with no
        /// hook yet the request stays PENDING and is delivered by whichever
        /// `onIdentityVerificationRequired` is installed next. A host that assigns
        /// the hook after `initialize` must still hear about it.
        func noteVerificationNeeded() -> String? {
            lock.withLock {
                guard !verificationRequested, identityAwaitsAuthHash,
                      case .identified(let externalID, let hash) = identity, hash == nil else {
                    return nil
                }
                verificationRequested = true
                guard hookInstalled else {
                    pendingVerification = externalID
                    return nil
                }
                return externalID
            }
        }
        var identityVerificationRequiredHook: @Sendable (String) -> Void {
            lock.withLock { identityVerificationRequired }
        }
        func setIdentityVerificationRequired(_ value: @escaping @Sendable (String) -> Void) {
            let pending: String? = lock.withLock {
                identityVerificationRequired = value
                hookInstalled = true
                let waiting = pendingVerification
                pendingVerification = nil
                return waiting
            }
            // A pending request is delivered exactly once, and never under the lock.
            guard let pending else { return }
            logSink(State.verificationNeededMessage(pending))
            OpenPush.deliverOnMain { value(pending) }
        }
        /// `tearDown` restoring the default no-op must not look like a host that
        /// installed a hook, or the next test's pending request would be swallowed.
        func clearIdentityVerificationHookForTests() {
            lock.withLock {
                identityVerificationRequired = { _ in }
                hookInstalled = false
                pendingVerification = nil
            }
        }

        private var clickListeners: [UUID: @Sendable (OpenPush.ClickEvent) -> Void] = [:]
        private var foregroundListeners: [UUID: @Sendable (OpenPush.ForegroundEvent) -> Void] = [:]
        private var permissionObservers: [UUID: @Sendable (Bool) -> Void] = [:]
        private var subscriptionObservers:
            [UUID: @Sendable (OpenPush.PushSubscriptionState) -> Void] = [:]
        private var subscriptionChangeObservers:
            [UUID: @Sendable (OpenPush.PushSubscriptionChange) -> Void] = [:]
        private var lastObservedPermission: Bool?
        private var lastObservedSubscription: OpenPush.PushSubscriptionState?
        private var applicationIsActive = false
        private var foregroundObserverInstalled = false
        private var protectedDataObserverInstalled = false
        private var pendingClicks: [OpenPush.ClickEvent] = []
        /// One lock acquisition settles the click: with a listener attached the
        /// caller fans out to the snapshot returned here, and with none the event
        /// joins the buffer and the caller gets an empty list back. Asking whether
        /// a listener exists and then holding in a second acquisition would park a
        /// click forever when a listener arrives in between.
        func deliverOrHold(
            _ event: OpenPush.ClickEvent
        ) -> [@Sendable (OpenPush.ClickEvent) -> Void] {
            lock.withLock {
                let listeners = Array(clickListeners.values)
                guard listeners.isEmpty else { return listeners }
                pendingClicks.append(event)
                let overflow = pendingClicks.count - OpenPush.Notifications.pendingClickLimit
                if overflow > 0 { pendingClicks.removeFirst(overflow) }
                return []
            }
        }
        func addClickListener(_ listener: @escaping @Sendable (OpenPush.ClickEvent) -> Void) -> UUID {
            let id = UUID()
            let held: [OpenPush.ClickEvent] = lock.withLock {
                clickListeners[id] = listener
                let due = pendingClicks
                pendingClicks.removeAll()
                return due
            }
            // Held clicks are replayed, not delivered by the delegate, so they take
            // the main-thread road every other notifying callback takes. One post,
            // so they keep their order.
            if !held.isEmpty {
                OpenPush.deliverOnMain { for event in held { listener(event) } }
            }
            return id
        }
        func removeClickListener(_ id: UUID) { lock.withLock { clickListeners[id] = nil } }
        var clickListenerList: [@Sendable (OpenPush.ClickEvent) -> Void] {
            lock.withLock { Array(clickListeners.values) }
        }
        func addForegroundListener(
            _ listener: @escaping @Sendable (OpenPush.ForegroundEvent) -> Void
        ) -> UUID {
            let id = UUID()
            lock.withLock { foregroundListeners[id] = listener }
            return id
        }
        func removeForegroundListener(_ id: UUID) { lock.withLock { foregroundListeners[id] = nil } }
        var foregroundListenerList: [@Sendable (OpenPush.ForegroundEvent) -> Void] {
            lock.withLock { Array(foregroundListeners.values) }
        }
        func addPermissionObserver(_ observer: @escaping @Sendable (Bool) -> Void) -> UUID {
            let id = UUID()
            lock.withLock { permissionObservers[id] = observer }
            return id
        }
        func removePermissionObserver(_ id: UUID) {
            lock.withLock { permissionObservers[id] = nil }
        }
        var permissionObserverList: [@Sendable (Bool) -> Void] {
            lock.withLock { Array(permissionObservers.values) }
        }
        func addSubscriptionObserver(
            _ observer: @escaping @Sendable (OpenPush.PushSubscriptionState) -> Void
        ) -> UUID {
            let id = UUID()
            lock.withLock { subscriptionObservers[id] = observer }
            return id
        }
        func removeSubscriptionObserver(_ id: UUID) {
            lock.withLock { subscriptionObservers[id] = nil }
        }
        var subscriptionObserverList:
            [@Sendable (OpenPush.PushSubscriptionState) -> Void] {
            lock.withLock { Array(subscriptionObservers.values) }
        }
        func addSubscriptionChangeObserver(
            _ observer: @escaping @Sendable (OpenPush.PushSubscriptionChange) -> Void
        ) -> UUID {
            let id = UUID()
            lock.withLock { subscriptionChangeObservers[id] = observer }
            return id
        }
        func removeSubscriptionChangeObserver(_ id: UUID) {
            lock.withLock { subscriptionChangeObservers[id] = nil }
        }
        var subscriptionChangeObserverList:
            [@Sendable (OpenPush.PushSubscriptionChange) -> Void] {
            lock.withLock { Array(subscriptionChangeObservers.values) }
        }
        func recordObservedPermission(_ value: Bool) -> Bool {
            lock.withLock {
                guard lastObservedPermission != value else { return false }
                lastObservedPermission = value
                return true
            }
        }
        /// One acquisition settles the emission: the dedupe check, the change the
        /// observers will be handed, and the value that becomes the next change's
        /// `previous`. Reading the previous value in a second acquisition would let
        /// two notifications interleave and hand out a chain that skips a state or
        /// reports one twice.
        func recordObservedSubscription(
            _ value: OpenPush.PushSubscriptionState
        ) -> OpenPush.PushSubscriptionChange? {
            lock.withLock {
                guard lastObservedSubscription != value else { return nil }
                let change = OpenPush.PushSubscriptionChange(previous: lastObservedSubscription,
                                                             current: value)
                lastObservedSubscription = value
                return change
            }
        }
        func claimForegroundObserver() -> Bool {
            lock.withLock {
                guard !foregroundObserverInstalled else { return false }
                foregroundObserverInstalled = true
                return true
            }
        }
        /// Records UIKit's active/inactive edge and returns whether this is a
        /// real transition. A late duplicate `didBecomeActive` must not run all
        /// foreground work twice after `attach` already observed `.active`.
        func recordApplicationIsActive(_ value: Bool) -> Bool {
            lock.withLock {
                guard applicationIsActive != value else { return false }
                applicationIsActive = value
                return true
            }
        }
        func claimProtectedDataObserver() -> Bool {
            lock.withLock {
                guard !protectedDataObserverInstalled else { return false }
                protectedDataObserverInstalled = true
                return true
            }
        }
        func clearObserversForTests() {
            lock.withLock {
                permissionObservers.removeAll()
                subscriptionObservers.removeAll()
                subscriptionChangeObservers.removeAll()
                lastObservedPermission = nil
                lastObservedSubscription = nil
            }
        }

        private var permissionGranted = false
        private var permissionStatus = OpenPush.PermissionStatus.notDetermined
        private var permission = OpenPush.PermissionSeam.system
        var permissionGrantedCache: Bool { lock.withLock { permissionGranted } }
        func setPermissionGranted(_ value: Bool) { lock.withLock { permissionGranted = value } }
        var permissionStatusCache: OpenPush.PermissionStatus {
            lock.withLock { permissionStatus }
        }
        func setPermissionStatus(_ value: OpenPush.PermissionStatus) {
            lock.withLock { permissionStatus = value }
        }
        var permissionSeam: OpenPush.PermissionSeam { lock.withLock { permission } }
        func setPermissionSeam(_ value: OpenPush.PermissionSeam) {
            lock.withLock { permission = value }
        }

        /// The taps already handled. Persisted, so it is deliberately left alone by
        /// `resetAsIfTheProcessJustStarted`: surviving a relaunch is its job.
        private var clickHistory: any OpenPushClickHistory = OpenPushUserDefaultsClickHistory()
        var clickHistorySeam: any OpenPushClickHistory { lock.withLock { clickHistory } }
        func setClickHistorySeam(_ value: any OpenPushClickHistory) {
            lock.withLock { clickHistory = value }
        }

        /// Where `initialize(appId:)` reads the SDK key from. Production reads the
        /// app bundle; tests substitute a closure. Lock-guarded like every other
        /// seam here, because Swift 6 has no mutable global shared state.
        private var bundledSDKKey: @Sendable () -> String? = {
            OpenPushConfiguration.bundledSDKKey()
        }
        var bundledSDKKeySeam: @Sendable () -> String? { lock.withLock { bundledSDKKey } }
        func setBundledSDKKeySeam(_ value: @Sendable @escaping () -> String?) {
            lock.withLock { bundledSDKKey = value }
        }

        private var notificationTypes = OpenPush.notificationTypesNeverPrompted
        var currentNotificationTypes: Int { lock.withLock { notificationTypes } }
        func setNotificationTypes(_ value: Int) {
            lock.withLock {
                notificationTypes = value
                persistSessionLocked()
            }
        }

        private var optedOut = false
        var isOptedOut: Bool { lock.withLock { optedOut } }
        func setOptedOut(_ value: Bool) {
            lock.withLock {
                optedOut = value
                persistSessionLocked()
            }
        }

        private var prompted = false
        var wasPrompted: Bool { lock.withLock { prompted } }
        func recordPrompted() {
            lock.withLock {
                prompted = true
                persistSessionLocked()
            }
        }

        private var lastSentStatus: Int?
        var lastAcceptedStatus: Int? { lock.withLock { lastSentStatus } }
        func setLastAcceptedStatus(_ value: Int?) { lock.withLock { lastSentStatus = value } }

        private var liveActivityTypes: [String: String] = [:]
        static func liveActivityTypesKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".liveActivityTypes"
        }
        func liveActivityType(for activityId: String) -> String? {
            lock.withLock { liveActivityTypes[activityId] }
        }
        func setLiveActivityType(_ value: String?, for activityId: String) {
            lock.withLock {
                liveActivityTypes[activityId] = value
                persistLiveActivityTypesLocked()
            }
        }
        private func persistLiveActivityTypesLocked() {
            guard !sessionRestorePending,
                  let tokenKey = configuration?.tokenKey else { return }
            let key = State.liveActivityTypesKey(forTokenKey: tokenKey)
            if liveActivityTypes.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(liveActivityTypes, forKey: key) }
        }
        private func restoreLiveActivityTypesLocked(tokenKey: String) {
            let stored = UserDefaults.standard.dictionary(
                forKey: State.liveActivityTypesKey(forTokenKey: tokenKey)) as? [String: String]
            liveActivityTypes = (stored ?? [:]).merging(liveActivityTypes) { _, staged in staged }
        }

        private var aliases: [String: String] = [:]
        var aliasMap: [String: String] { lock.withLock { aliases } }
        /// Merges and returns the whole map in one critical section, so a caller can
        /// check the label count without a second lock acquisition.
        func mergeAliases(_ values: [String: String]) -> [String: String] {
            lock.withLock {
                aliases.merge(values) { _, replacement in replacement }
                persistSessionLocked()
                return aliases
            }
        }

        private var tags: [String: String] = [:]
        var tagMap: [String: String] { lock.withLock { tags } }
        /// Merges and returns the whole map in one critical section so a caller
        /// can log the resulting size without a second lock acquisition.
        func mergeTags(_ values: [String: String]) -> [String: String] {
            lock.withLock {
                tags.merge(values) { _, replacement in replacement }
                persistSessionLocked()
                return tags
            }
        }

        /// Drops the deletions an accepted registration has just delivered, so the
        /// next body stops carrying them. The caller passes the keys it actually
        /// sent as tombstones: a key the app re-set to a real value while the
        /// request was in flight is left alone, and a deletion made during the
        /// flight is not in these sets at all, so it still rides the next body.
        func pruneTombstones(tags deliveredTags: Set<String>,
                             aliases deliveredAliases: Set<String>) {
            guard !deliveredTags.isEmpty || !deliveredAliases.isEmpty else { return }
            lock.withLock {
                for key in deliveredTags where tags[key]?.isEmpty == true {
                    tags.removeValue(forKey: key)
                }
                for label in deliveredAliases where aliases[label]?.isEmpty == true {
                    aliases.removeValue(forKey: label)
                }
                persistSessionLocked()
            }
        }

        typealias SharedStateMirror = (value: OpenPushSharedState, appGroup: String)

        /// What an extension may read, or nil when no App Group is configured (D9).
        /// The device credential is never part of it: an App Group is readable by
        /// every extension the host ships, and that key authenticates this install.
        /// Callers write the result AFTER releasing the lock.
        private func sharedStateLocked() -> SharedStateMirror? {
            // A mirror built from an unread session carries no token and no
            // subscription id, and writing it would strip both from whatever an
            // extension already had.
            guard !sessionRestorePending,
                  let configuration, let appGroup = configuration.appGroup else { return nil }
            return (OpenPushSharedState(appID: configuration.appID,
                                        serverURL: configuration.serverURL,
                                        sdkKey: configuration.sdkKey,
                                        token: token,
                                        subscriptionID: subscriptionID,
                                        sdkWrapper: wrapper?.wireValue,
                                        appGroup: appGroup),
                    appGroup)
        }

        /// The same snapshot for a caller that holds no lock — `attach`, once the
        /// cached token is back in place.
        func sharedStateSnapshot() -> SharedStateMirror? {
            lock.withLock { sharedStateLocked() }
        }

        /// Persists non-secret session intent beside the configured token. The
        /// external-ID authentication hash deliberately stays in memory: it is
        /// an identity proof and must never be written to UserDefaults.
        private func persistSessionLocked() {
            // Until the pending restore has run, everything this process could
            // write is empty by accident rather than by intent — including the
            // notification types the permission refresh recomputes at attach.
            guard !sessionRestorePending,
                  let tokenKey = configuration?.tokenKey else { return }
            let key = State.sessionKey(forTokenKey: tokenKey)
            var plist: [String: Any] = [:]
            if !tags.isEmpty { plist["tags"] = tags }
            if !aliases.isEmpty { plist["aliases"] = aliases }
            plist["notificationTypes"] = notificationTypes
            if optedOut { plist["optedOut"] = true }
            if prompted { plist["permissionPrompted"] = true }
            if let subscriptionID { plist["subscriptionId"] = subscriptionID }
            if lastAppSessionAt > 0 { plist["appSessionAt"] = lastAppSessionAt }
            if pendingSessionDuration > 0 {
                plist["sessionDuration"] = pendingSessionDuration
            }
            if let pendingSessionDurationID {
                plist["sessionDurationId"] = pendingSessionDurationID
            }
            switch identity {
            case .anonymous:
                break
            case .detached:
                plist["identity"] = "detached"
            case .identified(let externalID, _):
                plist["identity"] = "identified"
                plist["externalId"] = externalID
                if identityAwaitsAuthHash { plist["identityVerified"] = true }
            }
            if plist.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(plist, forKey: key)
            }
        }

        private func restoreSessionLocked(tokenKey: String) {
            let stored = UserDefaults.standard.dictionary(
                forKey: State.sessionKey(forTokenKey: tokenKey)) ?? [:]
            // A login or logout during the window already decided who this install
            // belongs to. The rest of the blob — the subscription row, the status
            // axes, the prompt and session marks — is about the device, not the
            // user, and is restored either way.
            let discardUserData = discardStoredUserDataOnRestore
            discardStoredUserDataOnRestore = false
            if !discardUserData, let storedTags = stored["tags"] as? [String: String] {
                tags = storedTags.merging(tags) { _, staged in staged }
            }
            if !discardUserData, let storedAliases = stored["aliases"] as? [String: String] {
                aliases = storedAliases.merging(aliases) { _, staged in staged }
            }
            if notificationTypes == OpenPush.notificationTypesNeverPrompted,
               let storedTypes = stored["notificationTypes"] as? Int {
                notificationTypes = storedTypes
            } else if notificationTypes == OpenPush.notificationTypesNeverPrompted,
                      let legacyStatus = stored["status"] as? Int {
                // Preserve a decision stored in the single legacy `status` value,
                // splitting it into the retained device value and explicit opt-out axes.
                if legacyStatus == OpenPush.optedOutStatus {
                    optedOut = true
                } else {
                    notificationTypes = legacyStatus
                }
            }
            if !optedOut { optedOut = stored["optedOut"] as? Bool ?? false }
            if !prompted { prompted = stored["permissionPrompted"] as? Bool ?? false }
            if subscriptionID == nil { subscriptionID = stored["subscriptionId"] as? String }
            if lastAppSessionAt == 0 {
                lastAppSessionAt = stored["appSessionAt"] as? TimeInterval ?? 0
            }
            if pendingSessionDuration == 0 {
                pendingSessionDuration = stored["sessionDuration"] as? TimeInterval ?? 0
                pendingSessionDurationID = stored["sessionDurationId"] as? String
            }
            if !discardUserData, identity == .anonymous {
                switch stored["identity"] as? String {
                case "detached":
                    identity = .detached
                case "identified":
                    if let externalID = stored["externalId"] as? String,
                       !externalID.isEmpty {
                        identity = .identified(externalID: externalID, authHash: nil)
                        identityAwaitsAuthHash = stored["identityVerified"] as? Bool ?? false
                    }
                default:
                    break
                }
            }
        }
    }

    static let state = State()

    static let appSessionMinimumInterval: TimeInterval = 30 * 60
    static let maxSessionDuration: TimeInterval = 24 * 60 * 60

    static var appSessionClock: @Sendable () -> TimeInterval {
        get { state.appSessionClockSeam }
        set { state.setAppSessionClock(newValue) }
    }

    /// Overridable for tests, exactly like `appSessionClock` and `scheduler`.
    static var preferredLanguageSeam: @Sendable () -> String? {
        get { state.preferredLanguageSeam }
        set { state.setPreferredLanguageSeam(newValue) }
    }

    /// Whether the device has been unlocked at least once since boot, so this
    /// process can read and write its own stored state. Overridable for tests,
    /// exactly like `preferredLanguageSeam`.
    static var protectedDataAvailableSeam: @Sendable () -> Bool {
        get { state.protectedDataAvailable }
        set { state.setProtectedDataAvailable(newValue) }
    }

    /// The production reading. `UIApplication.isProtectedDataAvailable` is
    /// main-thread state, so callers go through `State.protectedDataReadable()`
    /// rather than here: it takes this reading on the main thread and keeps the
    /// answer, and off the main thread it prefers what UIKit's own
    /// protected-data notifications last recorded. Platforms without UIKit have
    /// no locked-file state to wait for.
    static let systemProtectedDataAvailable: @Sendable () -> Bool = {
        #if canImport(UIKit)
        return MainActor.assumeIsolated {
            UIApplication.shared.isProtectedDataAvailable
        }
        #else
        return true
        #endif
    }

    static let registrationRetryDelays: [Double] = [2, 8]

    /// How far a retry delay may be moved in either direction.
    static let retryJitterFraction = 0.25

    /// The longest wait a `Retry-After` can buy. Past this the SDK stops obeying
    /// the server and falls back to its own schedule, so a mistaken header cannot
    /// park registration for an hour.
    static let retryAfterCap = 30.0

    /// The production factor. Without it every device that failed in the same
    /// outage retries in the same instant and recreates the outage.
    static let systemRetryJitter: @Sendable (Double) -> Double = { delay in
        delay * Double.random(in: (1 - retryJitterFraction)...(1 + retryJitterFraction))
    }

    static var retryJitter: @Sendable (Double) -> Double {
        get { state.retryJitterSeam }
        set { state.setRetryJitter(newValue) }
    }

    /// `Transport` is public and hands back only a status code and a body, so a
    /// response header has nowhere to travel. Rather than change that contract,
    /// `urlSessionTransport` drops the parsed `Retry-After` here and the
    /// registration response handler takes it back out. Taking clears it, so a
    /// header from one response can never be spent on a later one.
    ///
    /// The store and the take are separated only by the synchronous `done` call,
    /// but another endpoint's response landing in that window would hand the
    /// registration the wrong number. The cost of losing that race is one retry
    /// on the table delay instead of the server's, which is why the value rides
    /// here rather than in a wider change to the public `Transport`.
    final class RetryAfterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double?

        func store(_ value: Double?) { lock.withLock { seconds = value } }

        func take() -> Double? {
            lock.withLock {
                let value = seconds
                seconds = nil
                return value
            }
        }
    }

    static let lastRetryAfter = RetryAfterBox()

    /// RFC 9110 allows both a delay in seconds and an HTTP date. Only the integer
    /// form is honoured: a date needs a trusted clock, and a device with a skewed
    /// one would wait for days. A non-positive value is no instruction at all.
    static func retryAfterSeconds(_ header: String?) -> Double? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return Double(value)
    }

    /// 429 joins the retryable set: it is the server asking this device to come
    /// back later, not refusing it. The in-app fetch and the Live Activity
    /// executor share this predicate and want the same answer.
    static func isRetryableRegistrationFailure(_ code: Int) -> Bool {
        code <= 0 || code == 429 || (500...599).contains(code)
    }

    /// How long to wait before retrying a write that failed with `code` on
    /// `attempt`, or `nil` when it should not be retried automatically: the
    /// failure is a refusal, or the table is spent. Registration and the phone
    /// number writes share it, so the two cannot back off differently.
    static func retryDelay(afterAttempt attempt: Int, code: Int,
                           retryAfter: Double?) -> Double? {
        guard isRetryableRegistrationFailure(code),
              attempt >= 1, attempt <= registrationRetryDelays.count else { return nil }
        // A rate limiter that named a wait knows better than the table, up to the
        // cap. Everything else backs off on the table.
        let base: Double
        let serverNamedTheWait: Bool
        if code == 429, let retryAfter {
            base = min(retryAfterCap, retryAfter)
            serverNamedTheWait = true
        } else {
            base = registrationRetryDelays[attempt - 1]
            serverNamedTheWait = false
        }
        // Jitter spreads a fleet that failed together, but it may not pull a
        // retry in front of the wait the rate limiter named — that walks straight
        // back into the limit — nor push any wait past the cap.
        var delay = min(retryJitter(base), retryAfterCap)
        if serverNamedTheWait { delay = max(delay, base) }
        return delay
    }

    static var backgroundAssertion: BackgroundAssertion {
        get { state.backgroundAssertionSeam }
        set { state.setBackgroundAssertion(newValue) }
    }

    static var scheduler: Scheduler {
        get { state.schedulerSeam }
        set { state.setScheduler(newValue) }
    }

    /// Where handled taps are remembered. Overridable for tests, exactly like
    /// `scheduler`; production keeps them in `UserDefaults`.
    static var clickHistory: any OpenPushClickHistory {
        get { state.clickHistorySeam }
        set { state.setClickHistorySeam(newValue) }
    }

    public static var onLog: @Sendable (String) -> Void {
        get { state.logSink }
        set { state.setLog(newValue) }
    }
    public static var onRegistered: @Sendable () -> Void {
        get { state.registeredHook }
        set { state.setRegistered(newValue) }
    }
    public static var onRegistrationFailed: @Sendable (String) -> Void {
        get { state.registrationFailedHook }
        set { state.setRegistrationFailed(newValue) }
    }
    /// Fires once per process when a previously verified identity was restored
    /// without its authentication hash. Until the host calls
    /// `login(externalId:authHash:)` again, registrations omit `external_id` so
    /// the server keeps the existing link instead of stripping it.
    /// Set it before or after `initialize`: a request raised while no hook was
    /// installed waits, and reaches the hook once one is assigned. Like every
    /// host callback, it runs on the main thread.
    public static var onIdentityVerificationRequired: @Sendable (String) -> Void {
        get { state.identityVerificationRequiredHook }
        set { state.setIdentityVerificationRequired(newValue) }
    }
    /// The APNs token this install last registered, as lowercase hex, or `nil`
    /// before the first token arrives.
    ///
    /// Read it freely. Do not assign it: forward tokens with `register(token:)`
    /// or `didRegisterForRemoteNotifications(deviceToken:)`. The setter is kept
    /// only so existing code compiles. Assigning a token registers it exactly as
    /// `register(token:)` does (once `initialize` has run), so the server and
    /// this install never disagree about which token is current; assigning `nil`
    /// or an empty string forgets the stored token and sends nothing.
    public static var currentToken: String? {
        get { state.currentToken }
        @available(*, deprecated, message: "Forward tokens with register(token:) or didRegisterForRemoteNotifications(deviceToken:); assigning a token now registers it.")
        set { assignTokenFromHost(newValue) }
    }

    /// The deprecated `currentToken` setter. A non-empty token is stored and
    /// registered, so it can never sit on the device unknown to the server; an
    /// empty or `nil` one only clears the stored token, as it always has.
    static func assignTokenFromHost(_ value: String?) {
        guard let value, !value.isEmpty else {
            state.setToken(nil, persist: true)
            return
        }
        // Stored first, as the setter always did, so a token assigned before
        // `initialize` is still the one the first registration sends.
        state.setToken(value, persist: true)
        guard state.config != nil else { return }
        performRegistration(token: value, completion: nil)
    }

    /// Stores a token without registering it. Internal: the SDK's own paths and
    /// tests that need a token in place before the code under test runs.
    static func storeToken(_ value: String?) {
        state.setToken(value, persist: true)
    }

    /// An app id is the one part of the configuration the SDK cannot recover
    /// from: it is spliced straight into every path, so a malformed one produces
    /// requests the server can only reject, on a retry schedule, for the whole
    /// session. Refusing at the door is the only way the host hears about it.
    static func appIDRefusal(_ appID: String) -> String? {
        // `/` and `?` are refused for the same reason whitespace is, only worse:
        // spliced into a path they do not fail, they retarget — an id of
        // "a/b" or "a?x=1" silently addresses another route with a query of its
        // own choosing.
        guard appID.isEmpty
                || appID.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                || appID.contains("/") || appID.contains("?")
        else { return nil }
        return "\u{2717} attach refused \u{2014} the app id \"\(appID)\" is empty or "
            + "contains whitespace or a path character (/ or ?). Pass the app id "
            + "exactly as the console shows it."
    }

    /// The id every quickstart ships with. It is a legal id, so it is a warning
    /// and not a refusal — but an install still wearing it is almost always a
    /// copy-paste that was never finished.
    static let placeholderAppIDPrefix = "replace-with-"

    public static func attach(configuration: OpenPushConfiguration,
                              credential: @escaping @Sendable () -> String?,
                              transport: @escaping Transport = urlSessionTransport) {
        if let refusal = appIDRefusal(configuration.appID) {
            onLog(refusal)
            fireRegistrationFailed(refusal)
            return
        }
        if configuration.appID.lowercased().hasPrefix(placeholderAppIDPrefix) {
            onLog("\u{26a0} the app id is still the placeholder "
                  + "\"\(configuration.appID)\" \u{2014} nothing will reach a real app")
        }
        // Read once here: the opt-out that needs no code.
        launchURLs.applyInfoPlistOptOut()
        let (kind, previousTokenKey, previousAppGroup, strandedWaiters) =
            state.setup(configuration, credential: credential, transport: transport)
        // The callers of a retry this attach cancelled. Outside `State`'s lock
        // and with the new configuration already installed, exactly as the
        // engine and queue clears below are. `drainWaiters` removed them, so
        // each is called once and a later stale-generation retry finds none.
        for waiter in strandedWaiters {
            waiter(.dropped("a newer configuration replaced this registration"))
        }
        // Outside `setup`, which holds `State`'s lock: the engine takes its own,
        // and the two must never nest.
        if kind == .workspaceSwitch {
            IamEngine.shared.workspaceSwitched(previousTokenKey: previousTokenKey)
            // Same rule, same reason: the queue's own lock is taken here, where
            // `State`'s is not held, never from inside `setup`.
            CustomEvents.shared.workspaceSwitched(previousTokenKey: previousTokenKey)
            // A phone number added in one workspace belongs to that app id.
            AddressSubscriptions.shared.workspaceSwitched(previousTokenKey: previousTokenKey)
            // Receipts are keyed by token key too, and one workspace's delivery
            // evidence has no business being posted to another's app id.
            ReceiptQueue.shared.workspaceSwitched(previousTokenKey: previousTokenKey)
            // Carrying one workspace's identity into another leaks it, and an
            // extension reading the old group would keep doing exactly that.
            if let previousAppGroup, previousAppGroup != configuration.appGroup {
                OpenPushSharedState.clear(appGroup: previousAppGroup)
            }
        }
        // Every attach, so the engine always knows which workspace's blob is its
        // own — and never has to read that back out of `State` from under its
        // own lock. Here, where `State`'s lock is not held.
        IamEngine.shared.adoptTokenKey(configuration.tokenKey)
        if kind == .repeated {
            onLog("• initialize called again with the same configuration — OpenPush is " +
                  "already initialized and local state was kept")
        } else {
            LiveActivities.executor.attach(tokenKey: configuration.tokenKey,
                                           isFirstAttach: kind == .first)
        }
        observeBackgrounding()
        if currentToken == nil,
           let cached = UserDefaults.standard.string(forKey: configuration.tokenKey) {
            state.setToken(cached, persist: false)
        }
        // After the cached token is restored, so an extension launched before the
        // app ever registers still finds one. Never under `State`'s lock.
        if let mirror = state.sharedStateSnapshot() {
            OpenPushSharedState.save(mirror.value, appGroup: mirror.appGroup)
        }
        // After the cached token is back, so a host that logs in from the hook
        // registers immediately instead of only staging the identity. The hook
        // itself runs later, on the main thread, like every host callback.
        if let awaiting = state.noteVerificationNeeded() {
            onLog(State.verificationNeededMessage(awaiting))
            let hook = state.identityVerificationRequiredHook
            deliverOnMain { hook(awaiting) }
        }
        #if canImport(UIKit)
        if Thread.isMainThread {
            let isActive = MainActor.assumeIsolated {
                UIApplication.shared.applicationState == .active
            }
            beginForegroundSessionIfActive(isActive)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    beginForegroundSessionIfActive(
                        UIApplication.shared.applicationState == .active)
                }
            }
        }
        #else
        beginForegroundSession()
        #endif
        sendAppSessionIfDue()
        // Session start is a recompute: a permission change made while the app
        // was not running reaches the server as soon as a cached token exists.
        Notifications.refreshPermission { Notifications.syncNotificationTypes($0) }
        installForegroundObserver()
        installProtectedDataObserver()
        onLog("attach · server \(configuration.serverURL) · app \(configuration.appID) " +
              "· platform \(configuration.platform)")
    }

    static func sendAppSessionIfDue() {
        guard let config = state.config,
              let token = state.claimAppSessionToken() else { return }
        post("/v1/apps/\(config.appID)/sessions",
             OpenPushPayload.appSessionBody(token: token)) { code, _ in
            onLog("app-session ping → \(code)")
        }
    }

    static func beginForegroundSession() {
        guard let report = state.beginForegroundSession() else { return }
        sendSessionDuration(report)
    }

    /// A normal cold launch initializes while the application is inactive; a
    /// silent-push or prewarm launch can initialize in the background. Starting
    /// the clock in either state would count time before actual foreground use.
    static func beginForegroundSessionIfActive(_ isActive: Bool) {
        _ = state.recordApplicationIsActive(isActive)
        guard isActive else { return }
        beginForegroundSession()
    }

    static func recordSessionDurationOnBackground() {
        _ = state.recordApplicationIsActive(false)
        let assertion = backgroundAssertion
        let handle = assertion.begin("openpush.session-duration")
        guard let report = state.finishForegroundSession() else {
            assertion.end(handle)
            return
        }
        sendSessionDuration(report) { assertion.end(handle) }
    }

    private static func sendSessionDuration(
        _ report: SessionDurationReport,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        guard let config = state.config else {
            state.cancelSessionDuration(report)
            completion()
            return
        }
        post("/v1/apps/\(config.appID)/sessions",
             OpenPushPayload.appSessionDurationBody(
                token: report.token,
                seconds: report.seconds,
                idempotencyKey: report.id)) { code, _ in
            state.settleSessionDuration(report, status: code)
            if (400...499).contains(code) {
                onLog("session duration refused (\(code)) — dropping the report")
            } else if (200...299).contains(code) {
                onLog("session duration → \(code)")
            } else {
                onLog("session duration failed (\(code)) — queued for retry")
            }
            completion()
        }
    }

    public static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Forwards an APNs token (lowercase hex) and registers this install. The
    /// identity it carries is the one set with `login(externalId:authHash:)`.
    public static func register(token: String) {
        performRegistration(token: token, completion: nil)
    }

    /// Kept so existing calls compile. A non-empty `externalID` is applied as
    /// `login(externalId:)` (no auth hash) before the token is registered, so it
    /// follows the same rules as a login: switching users clears the previous
    /// user's staged tags and aliases, and an identity that is waiting for its
    /// auth hash is not asserted without it. An `externalID` equal to the
    /// identity already logged in changes nothing. `nil` or empty is the same as
    /// `register(token:)`.
    @available(*, deprecated, message: "Call login(externalId:authHash:) for the identity and register(token:) for the token.")
    public static func register(token: String, externalID: String?) {
        if let externalID, !externalID.isEmpty {
            applyLoginForRegister(externalID: externalID)
        }
        performRegistration(token: token, completion: nil)
    }

    /// The identity half of the deprecated `register(token:externalID:)`: the
    /// login bookkeeping without login's own registration, because the caller
    /// registers next with the new token. The same id as the current identity is
    /// left alone, so a stored auth hash is never dropped by a repeat call.
    static func applyLoginForRegister(externalID: String) {
        if case .identified(let current, _) = state.currentIdentity, current == externalID {
            return
        }
        if case .adopted(let switchingUsers) = state.applyLogin(externalID: externalID,
                                                                 authHash: nil),
           switchingUsers {
            onLog("• login switched users — the previous user's tags and aliases were " +
                  "cleared locally so they are not written onto \(externalID)")
        }
    }

    struct RegistrationOutcome: Sendable, Equatable {
        let subscriptionID: String?
        let identityRejected: String?
        /// The status the server says the row now holds (S2). Always reported;
        /// adopted only on the opt-out axis (D6): `-2` sets the local opt-out and
        /// any positive value clears it. `-31`/`-22`/`-10` are set by the console,
        /// an import, or APNs feedback — they stay reported-only, because this
        /// device has no standing to claim them as its own state.
        let serverStatus: Int?
        /// Body fields the app's data-collection settings told the server to drop.
        /// The response is a 2xx, so without this the host would keep sending a
        /// field for months and keep believing it landed.
        let notCollected: [String]
        /// Alias labels the server ignored (S3 refuses reserved and over-cap labels
        /// by naming them on an otherwise-2xx response rather than by failing the
        /// whole registration).
        let aliasesRefused: [String]?
    }

    /// Three states, not an optional: "never identified" and "explicitly
    /// detached" send different bodies, and collapsing them would make logout
    /// indistinguishable from a fresh install.
    enum Identity: Sendable, Equatable {
        case anonymous
        case identified(externalID: String, authHash: String?)
        case detached
    }

    enum RegistrationResult: Sendable, Equatable {
        case accepted(RegistrationOutcome)
        case rejected(code: Int, message: String)
        case dropped(String)
    }

    /// The single place a subscription body is built. `register`, `login`, `logout`,
    /// and tag changes all land here, so identity and tags cannot drift apart
    /// between entry points.
    static func performRegistration(token: String,
                                    attempt: Int = 1,
                                    apsEnvironment: String? = cachedAPNsEnvironment,
                                    completion: (@Sendable (RegistrationResult) -> Void)?) {
        guard let config = state.config else {
            onLog("✗ register dropped — OpenPush.attach was not called")
            completion?(.dropped("OpenPush.initialize was not called"))
            return
        }
        state.cancelWriteWindow()
        let generation: Int
        if attempt == 1 {
            state.cancelPendingRetry()
            generation = state.beginRegistration(completion: completion)
        } else {
            generation = state.currentRegistrationGeneration
        }
        let finish: @Sendable (RegistrationResult) -> Void = { result in
            for waiter in state.drainWaiters(upTo: generation) {
                waiter(result)
            }
        }
        // A reset or account switch can happen while this request is in flight.
        // Its response belongs to the credential that started it; allowing that
        // stale callback to update the UI would make a cleared/new session look
        // registered (or failed) for the previous workspace.
        let credentialAtStart = state.deviceCredential
        state.setToken(token, persist: true)
        var body: [String: Any] = [
            "token": token, "platform": config.platform,
            "device": deviceModel(), "language": languageCode(),
            "timezone": TimeZone.current.identifier,
            "sdk_version": sdkVersion,
            "os_version": operatingSystemVersion(),
        ]
        // The header identifies the request; this identifies the subscription, so
        // a wrapper install can be segmented long after its requests are gone.
        if let wrapper = state.sdkWrapper { body["sdk_wrapper"] = wrapper.wireValue }
        if let sandbox = sandboxFlag(forAPNsEnvironment: apsEnvironment) {
            body["sandbox"] = sandbox
        }
        if let country = countryCode() { body["country"] = country }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["app_version"] = version
        }
        // Identity comes only from the login state, so every body follows the
        // same auth-hash rules: there is no per-request override.
        switch state.currentIdentity {
        case .anonymous:
            break
        case .identified(let externalID, let authHash):
            if let authHash {
                body["external_id"] = externalID
                body["external_id_auth_hash"] = authHash
            } else if state.identityNeedsAuthHash {
                // Asserting the id without proof makes the server strip identity,
                // tags and aliases on a 200. Absent means "leave identity alone".
                onLog("• external_id omitted — waiting for the auth hash")
            } else {
                body["external_id"] = externalID
            }
        case .detached:
            // Present-and-empty is the detach signal (server task S1): replace
            // the identified user with a fresh anonymous one. Omitting the key
            // would instead mean "leave identity untouched".
            body["external_id"] = ""
        }
        let sessionTags = state.tagMap
        if !sessionTags.isEmpty { body["tags"] = sessionTags }
        // Every registration reports the resolved
        // notification_types value. The retained opt-out wins over the current
        // device authorization.
        let status = wireStatus()
        body["status"] = status
        let sessionAliases = state.aliasMap
        if !sessionAliases.isEmpty { body["aliases"] = sessionAliases }
        // What this body asks the server to delete. Captured before the post so the
        // pruning on 2xx cannot swallow a write made while the request is in flight.
        let tombstones = (tags: Set(sessionTags.filter { $0.value.isEmpty }.keys),
                          aliases: Set(sessionAliases.filter { $0.value.isEmpty }.keys))
        // What this body says about identity, captured for the accepted path: only
        // a registration that actually carried the id (or the empty detach) proves
        // the server was told about it.
        let sentExternalID = body["external_id"] as? String
        post("/v1/apps/\(config.appID)/subscriptions", body) { code, response in
            guard state.deviceCredential == credentialAtStart else {
                onLog("• ignored registration response for a previous device session")
                // The hooks stay silent, but a caller that is
                // waiting on a completion must not hang forever.
                finish(.dropped("the device session changed before the response arrived"))
                return
            }
            let outcome = parseRegistration(response)
            // Always taken, never only on a 429: leaving a header in the box would
            // let one response's back-off be spent on an unrelated later failure.
            let retryAfter = lastRetryAfter.take()
            let accepted = (200...299).contains(code)
            if let refused = outcome.aliasesRefused {
                // Refusals arrive on a 2xx, so nothing else makes them visible: the
                // labels are simply absent from the user row afterwards.
                onLog("✗ aliases NOT applied — the server refused these labels: " +
                      refused.sorted().joined(separator: ", "))
            }
            if let serverStatus = outcome.serverStatus, serverStatus < 0,
               serverStatus != status {
                if serverStatus == optedOutStatus, accepted {
                    // Adoption follows on the accepted path, so saying this device
                    // cannot change it would be wrong.
                    onLog("• the server carried an opt-out onto this install — adopted")
                } else {
                    onLog("• the server reports subscription status \(serverStatus) for this " +
                          "install — it was set outside this SDK (console, import, or APNs " +
                          "feedback) and this device cannot change it")
                }
            }
            if accepted {
                onLog("✓ registered with OpenPush: \(boundedLog(response))")
                if !outcome.notCollected.isEmpty {
                    // A 2xx with a field quietly dropped looks exactly like a 2xx
                    // that stored it, so the host has to be told once per response.
                    onLog("• the server did not store: " +
                          outcome.notCollected.joined(separator: ", ") +
                          " — collection is disabled for this app")
                }
                fireRegistered()
                // A repeat login or logout may only be skipped once the identity
                // this body carried has actually been accepted.
                state.noteIdentityDelivered(externalIDInBody: sentExternalID)
                // Failed status syncs remain eligible for the next foreground.
                state.setLastAcceptedStatus(status)
                // The deletions in this body have landed; re-sending them on every
                // later registration would be waste and would keep them visible to
                // `getTags()`.
                state.pruneTombstones(tags: tombstones.tags, aliases: tombstones.aliases)
                // Only an accepted registration says anything about the row, so the
                // id is persisted here rather than on every response.
                if let id = outcome.subscriptionID { state.setSubscriptionID(id) }
                if let serverStatus = outcome.serverStatus {
                    state.adoptServerStatus(serverStatus)
                    state.setLastAcceptedStatus(wireStatus())
                }
                notifySubscriptionObservers()
                LiveActivities.executor.registrationCompleted(
                    subscriptionID: outcome.subscriptionID)
                CustomEvents.shared.registrationCompleted()
                AddressSubscriptions.shared.registrationCompleted()
                ReceiptQueue.shared.registrationCompleted()
                #if canImport(UIKit)
                InAppMessages.onSubscriptionReady()
                #endif
                finish(.accepted(outcome))
            } else {
                let message = registrationFailureMessage(code: code, response: response)
                if let delay = retryDelay(afterAttempt: attempt, code: code,
                                          retryAfter: retryAfter) {
                    onLog("• register attempt \(attempt) failed (\(code)); retrying in " +
                          "\(Int(delay.rounded()))s: \(boundedLog(response))")
                    let handle = state.schedulerSeam.run(delay) {
                        guard state.currentRegistrationGeneration == generation else {
                            onLog("• a newer registration replaced the retry of attempt " +
                                  "\(attempt)")
                            // This chain is over, and it is the only thing that
                            // was ever going to answer the caller: the failure
                            // that armed this retry reported nothing, and the
                            // registration that superseded it carries a waiter
                            // list of its own. Without this a `login` or
                            // `register` completion whose request 503'd just
                            // before a workspace switch never fires at all.
                            finish(.dropped("a newer configuration replaced this registration"))
                            return
                        }
                        performRegistration(token: token,
                                            attempt: attempt + 1,
                                            apsEnvironment: apsEnvironment,
                                            completion: nil)
                    }
                    state.setPendingRetry(handle)
                    return
                }
                onLog("✗ register failed (\(code)): \(boundedLog(response))")
                fireRegistrationFailed(message)
                finish(.rejected(code: code, message: message))
            }
        }
    }

    static func notifyPermissionObservers() {
        let granted = Notifications.permission
        guard state.recordObservedPermission(granted) else { return }
        let observers = state.permissionObserverList
        deliverOnMain { for observer in observers { observer(granted) } }
    }

    static func notifySubscriptionObservers() {
        let snapshot = User.pushSubscription.snapshot()
        guard let change = state.recordObservedSubscription(snapshot) else { return }
        // One post for both lists, so state observers still hear a change before
        // change observers do, exactly as when this ran inline.
        let observers = state.subscriptionObserverList
        let changeObservers = state.subscriptionChangeObserverList
        deliverOnMain {
            for observer in observers { observer(snapshot) }
            for observer in changeObservers { observer(change) }
        }
    }

    /// Installs one UIKit foreground observer for the lifetime of the process.
    static func installForegroundObserver() {
        #if canImport(UIKit)
        guard state.claimForegroundObserver() else { return }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { _ in
                guard state.recordApplicationIsActive(true) else { return }
                // A protected-data notification that landed between the seam read
                // in `attach` and the observer install would otherwise leave the
                // flag armed for the life of the process. This is idempotent and
                // re-reads the seam, so a foreground while the device is still
                // locked changes nothing.
                state.restorePendingSession()
                Notifications.onAppForegrounded()
            }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main) { _ in
                guard state.recordApplicationIsActive(false) else { return }
                // Duration is foreground use, so stop at inactive rather than
                // counting the transition until `didEnterBackground` arrives.
                recordSessionDurationOnBackground()
            }
        #endif
    }

    /// Installs one UIKit protected-data observer for the lifetime of the
    /// process. A launch before the device's first unlock cannot read the stored
    /// session, and this is what finishes that attach once iOS says it can.
    static func installProtectedDataObserver() {
        #if canImport(UIKit)
        guard state.claimProtectedDataObserver() else { return }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main) { _ in
                state.cacheProtectedData(true)
                state.restorePendingSession()
            }
        // The other half, so the cached answer is a reading and not a latch: a
        // device relocked while the app runs must not leave a background write
        // believing the store is still readable.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main) { _ in
                state.cacheProtectedData(false)
            }
        #endif
    }

    /// The server answers registration with the subscription row and, when
    /// identity could not be applied, an explicit note. Both were previously
    /// discarded.
    static func parseRegistration(_ response: String) -> RegistrationOutcome {
        guard let data = response.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RegistrationOutcome(subscriptionID: nil, identityRejected: nil,
                                       serverStatus: nil, notCollected: [],
                                       aliasesRefused: nil)
        }
        var identifier = payload["id"] as? String
        if identifier == nil { identifier = (payload["id"] as? NSNumber)?.stringValue }
        if identifier?.isEmpty == true { identifier = nil }
        return RegistrationOutcome(
            subscriptionID: identifier,
            identityRejected: identityRejectionNote(payload["identity_rejected"]),
            // JSON numbers arrive as NSNumber; `as? Int` alone would also match a
            // JSON boolean, which is never a status.
            serverStatus: (payload["status"] as? NSNumber)?.intValue,
            notCollected: stringList(payload["not_collected"]),
            aliasesRefused: refusedAliasLabels(payload["aliases_refused"]))
    }

    /// The note is an array of labels, but be defensive about a single string:
    /// only a non-empty list ever counts as a refusal.
    private static func refusedAliasLabels(_ value: Any?) -> [String]? {
        let labels = stringList(value)
        return labels.isEmpty ? nil : labels
    }

    /// A field the server documents as a list of names, tolerant of the single
    /// unwrapped string some gateways send instead.
    private static func stringList(_ value: Any?) -> [String] {
        switch value {
        case let list as [Any]:
            return list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        case let single as String:
            return single.isEmpty ? [] : [single]
        default:
            return []
        }
    }

    private static func identityRejectionNote(_ value: Any?) -> String? {
        let fallback = "the server did not apply this external ID"
        switch value {
        case let note as String:
            return note.isEmpty ? nil : note
        case let detail as [String: Any]:
            for key in ["note", "reason", "detail", "message"] {
                if let note = detail[key] as? String, !note.isEmpty { return note }
            }
            return fallback
        case let flag as Bool:
            return flag ? fallback : nil
        default:
            return nil
        }
    }

    /// Diagnostics stay bounded; parsing does not. Keeping the two budgets
    /// separate is what lets the transport hand back a full body.
    static func boundedLog(_ text: String, limit: Int = 160) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// Registration is the one SDK failure rendered directly in the sample app.
    /// Preserve the structured server code here so a tenant-ownership conflict is
    /// not mislabeled as a connection problem with an endless Retry button.
    static func registrationFailureMessage(code: Int, response: String) -> String {
        if let data = response.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           payload["code"] as? String == "scope_conflict" {
            return "This device is still linked to another workspace. Reset this device, then sign in again."
        }
        return "OpenPush could not register this device (\(code)). Check your connection and try again."
    }

    /// Reports one delivery event for one message.
    ///
    /// The receipt is queued, not fired and forgotten: it is persisted until the
    /// server accepts it, retried on its own schedule and again on every
    /// foreground, and deduplicated against the receipts this install has already
    /// had accepted — across relaunches, not only within this process.
    public static func receipt(_ type: String, messageID: String?,
                               then: (@Sendable () -> Void)? = nil) {
        ReceiptQueue.shared.enqueue(type: type, messageID: messageID, then: onMain(then))
    }

    public static func messageID(from userInfo: [AnyHashable: Any]) -> String? {
        OpenPushPayload.messageID(from: userInfo)
    }

    public static func actions(from userInfo: [AnyHashable: Any]) -> [OpenPushPayload.Action] {
        OpenPushPayload.actions(from: userInfo)
    }

    public static func shortToken(_ token: String) -> String {
        token.count <= 20 ? token : String(token.prefix(12)) + "…(\(token.count) chars)"
    }

    public static func deviceModel() -> String {
        var value = utsname(); uname(&value)
        let machine = Mirror(reflecting: value.machine).children.reduce(into: "") { out, part in
            guard let byte = part.value as? Int8, byte > 0 else { return }
            out.append(Character(UnicodeScalar(UInt8(byte))))
        }
        return deviceModel(machine: machine)
    }

    /// The hardware identifier a registration reports, from a machine string the
    /// caller supplies. Every branch here is about not naming a device this
    /// install is not: a simulator says it is one (its `uname` reports the Mac's
    /// own hardware), Catalyst says `Mac`, and an unreadable machine string says
    /// `unknown` rather than guessing at a model the analytics will believe.
    static func deviceModel(machine: String) -> String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return "Simulator \(simulated)"
        }
        #endif
        return machine.isEmpty ? "unknown" : machine
        #endif
    }

    /// Numeric OS version without touching UIKit's main-actor-isolated device singleton.
    static func operatingSystemVersion(
        _ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        var result = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { result += ".\(version.patchVersion)" }
        return result
    }

    /// The device's preferred language as a full BCP-47 tag — script and region
    /// included. Truncating `zh-Hant-TW` to `zh` throws away the only part that
    /// picks traditional over simplified copy; the server falls back from a
    /// regional tag to its base language on its own.
    private static func languageCode() -> String {
        let tag = (preferredLanguageSeam() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? "en" : tag
    }

    static func countryCode(locale: Locale = .current) -> String? {
        let region: String?
        if #available(iOS 16, macOS 13, *) {
            region = locale.region?.identifier
        } else {
            // Unreachable on the shipped platform floor (iOS 16). It exists because
            // the package also compiles for macOS 12 so `swift test` runs on the host.
            region = locale.regionCode
        }
        guard let code = region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return nil }
        return code.uppercased()
    }

    /// Live Activity tokens are device-authenticated exactly like a registration:
    /// same headers, same 15s timeout, same credential-race rule. A response that
    /// belongs to a previous device session is ignored, and its completion reports
    /// failure — a caller awaiting one must never hang.
    static func postLiveActivity(path: String, body: [String: Any], label: String,
                                 completion: (@Sendable (Bool) -> Void)?) {
        postLiveActivity(path: path, body: body, label: label) { code in
            completion?((200...299).contains(code))
        }
    }

    static func postLiveActivity(path: String, body: [String: Any], label: String,
                                 outcome: @escaping @Sendable (Int) -> Void) {
        let credentialAtStart = state.deviceCredential
        post(path, body) { code, response in
            guard state.deviceCredential == credentialAtStart else {
                onLog("• ignored the \(label) response for a previous device session")
                outcome(-1)
                return
            }
            if (200...299).contains(code) {
                onLog("✓ sent the \(label)")
            } else {
                onLog("✗ the \(label) was rejected (\(code)): \(boundedLog(response))")
            }
            outcome(code)
        }
    }

    static func post(_ path: String, _ body: [String: Any],
                     done: @escaping @Sendable (Int, String) -> Void) {
        request(method: "POST", path: path, body: body, done: done)
    }

    static func get(_ path: String,
                    done: @escaping @Sendable (Int, String) -> Void) {
        request(method: "GET", path: path, body: nil, done: done)
    }

    static func request(method: String, path: String, body: [String: Any]?,
                        done: @escaping @Sendable (Int, String) -> Void) {
        guard let config = state.config,
              let url = URL(string: config.serverURL + path) else {
            done(-1, "invalid request")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                done(-1, "invalid request")
                return
            }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(config.sdkKey, forHTTPHeaderField: "X-OP-SDK-Key")
        if let key = state.deviceCredential {
            request.setValue(key, forHTTPHeaderField: "X-OP-Device-Key")
        }
        // Every request says which SDK sent it, not only the registration: a
        // receipt or a session ping is exactly where a version-specific bug shows
        // up, and triage that has to guess the client version cannot start.
        request.setValue(OpenPushSDKVersion.headerValue,
                         forHTTPHeaderField: OpenPushSDKVersion.headerField)
        if let wrapper = state.sdkWrapper {
            request.setValue(wrapper.wireValue,
                             forHTTPHeaderField: OpenPushSDKVersion.wrapperHeaderField)
        }
        state.requestTransport(request, done)
    }

    public static let urlSessionTransport: Transport = { request, done in
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                lastRetryAfter.store(nil)
                done(-1, error.localizedDescription)
                return
            }
            let http = response as? HTTPURLResponse
            // `Transport` is public and passes only a code and a body, so the one
            // header the retry schedule cares about is handed over out of band.
            // Stored on every response, including as nil, so nothing goes stale.
            lastRetryAfter.store(
                retryAfterSeconds(http?.value(forHTTPHeaderField: "Retry-After")))
            done(http?.statusCode ?? -1, transportBody(data ?? Data()))
        }.resume()
    }

    /// Response parsing and diagnostic logging have different budgets. In-app
    /// definitions legitimately exceed 4 KB, while every log call is already
    /// bounded by `boundedLog`; truncating here corrupts otherwise valid JSON.
    static func transportBody(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
