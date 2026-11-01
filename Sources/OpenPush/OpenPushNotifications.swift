import Foundation
import UserNotifications
import OpenPushCore
#if canImport(UIKit)
import UIKit
#endif

extension OpenPush {
    /// The authorization state iOS reports, kept whole rather than collapsed to a
    /// boolean: a host that wants to nudge a provisional user into a full grant,
    /// or to leave an App Clip alone, needs to tell those apart.
    public enum PermissionStatus: Sendable, Equatable {
        case notDetermined
        case denied
        case granted
        /// Quiet delivery: straight to the notification centre, no banner.
        case provisional
        /// An App Clip's temporary authorization, which ends with the clip.
        case ephemeral

        /// Provisional and ephemeral authorization can both deliver, so all three
        /// count as permission for `optedIn` purposes.
        public var isGranted: Bool {
            self == .granted || self == .provisional || self == .ephemeral
        }
    }

    /// UNUserNotificationCenter traps in a bundle-less SwiftPM test process and
    /// UIApplication does not exist there, so every platform call the permission
    /// surface makes goes through this seam — the same injection philosophy as
    /// `Transport`. Without UIKit (the macOS host that runs `swift test`) the
    /// system seam is inert rather than absent, so an un-injected call reports
    /// "not granted" instead of crashing.
    struct PermissionSeam: Sendable {
        var status: @Sendable (@escaping @Sendable (PermissionStatus) -> Void) -> Void
        var request: @Sendable (_ provisional: Bool,
                                @escaping @Sendable (Bool) -> Void) -> Void
        var openSettings: @Sendable () -> Void
        var registerForRemoteNotifications: @Sendable () -> Void
        var settings: (@Sendable (@escaping @Sendable (OpenPush.AuthorizationSnapshot) -> Void)
                       -> Void)? = nil

        static let system = PermissionSeam(
            status: { done in
                #if canImport(UIKit)
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    switch settings.authorizationStatus {
                    case .authorized: done(.granted)
                    case .ephemeral: done(.ephemeral)
                    case .provisional: done(.provisional)
                    case .denied: done(.denied)
                    case .notDetermined: done(.notDetermined)
                    @unknown default: done(.notDetermined)
                    }
                }
                #else
                done(.notDetermined)
                #endif
            },
            request: { provisional, done in
                #if canImport(UIKit)
                let options: UNAuthorizationOptions = provisional
                    ? [.provisional, .alert, .sound, .badge]
                    : [.alert, .sound, .badge]
                UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
                    if let error {
                        OpenPush.onLog("✗ authorization request failed: \(error.localizedDescription)")
                    }
                    done(granted)
                }
                #else
                done(false)
                #endif
            },
            openSettings: {
                #if canImport(UIKit)
                DispatchQueue.main.async {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
                        return
                    }
                    UIApplication.shared.open(url)
                }
                #endif
            },
            registerForRemoteNotifications: {
                #if canImport(UIKit)
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                #endif
            },
            settings: { done in
                #if canImport(UIKit)
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let status: OpenPush.PermissionStatus
                    switch settings.authorizationStatus {
                    case .authorized: status = .granted
                    case .ephemeral: status = .ephemeral
                    case .provisional: status = .provisional
                    case .denied: status = .denied
                    case .notDetermined: status = .notDetermined
                    @unknown default: status = .notDetermined
                    }
                    done(OpenPush.AuthorizationSnapshot(
                        status: status,
                        badge: settings.badgeSetting == .enabled,
                        sound: settings.soundSetting == .enabled,
                        alert: settings.alertSetting == .enabled,
                        carPlay: settings.carPlaySetting == .enabled,
                        critical: settings.criticalAlertSetting == .enabled,
                        appSettings: settings.providesAppNotificationSettings,
                        announcement: settings.announcementSetting == .enabled,
                        timeSensitive: settings.timeSensitiveSetting == .enabled))
                }
                #else
                done(OpenPush.AuthorizationSnapshot(status: .notDetermined))
                #endif
            })
    }

    static var permissionSeam: PermissionSeam {
        get { state.permissionSeam }
        set { state.setPermissionSeam(newValue) }
    }
}

public extension OpenPush {
    enum Notifications {
        /// The cached authorization state, refreshed at `attach`, `initialize`,
        /// actual app foreground transitions, and `requestPermission`. Reading it
        /// never blocks; receiving a notification does not rewrite it.
        public static var permission: Bool { OpenPush.state.permissionGrantedCache }

        /// The same cache, unflattened: which authorization iOS actually reports.
        /// Refreshed on exactly the same occasions as `permission`.
        public static var permissionStatus: OpenPush.PermissionStatus {
            OpenPush.state.permissionStatusCache
        }

        /// True while iOS can still show the standard authorization prompt. A
        /// provisional grant does not consume that prompt, so it remains
        /// requestable; a denial, full grant, or App Clip grant is final for this
        /// purpose.
        public static var canRequestPermission: Bool {
            permissionStatus == .notDetermined || permissionStatus == .provisional
        }

        /// Ask for provisional authorization: notifications begin arriving quietly,
        /// in the notification centre only, with no prompt at all. The user
        /// promotes or turns them off from the notification itself.
        ///
        /// Never routes to Settings — there is nothing for the user to fix, because
        /// nothing was refused.
        public static func requestProvisionalPermission(
            completion: (@Sendable (Bool) -> Void)? = nil
        ) {
            request(provisional: true, fallbackToSettings: false,
                    completion: OpenPush.onMain(completion))
        }

        /// Ask for notification authorization and, on a grant, start APNs
        /// registration. When authorization was already denied iOS cannot prompt
        /// again: with `fallbackToSettings` this opens the app's notification
        /// settings, and either way the completion reports `false`.
        public static func requestPermission(fallbackToSettings: Bool = false,
                                             completion: (@Sendable (Bool) -> Void)? = nil) {
            request(provisional: false, fallbackToSettings: fallbackToSettings,
                    completion: OpenPush.onMain(completion))
        }

        /// The completion is called on whatever thread the system answered on.
        /// The public entry points wrap it for the main thread; SDK-internal
        /// callers (opt-in, provisional initialize) take it as it comes.
        static func request(provisional: Bool, fallbackToSettings: Bool,
                            completion: (@Sendable (Bool) -> Void)?) {
            let seam = OpenPush.permissionSeam
            seam.status { status in
                if status.isGranted {
                    refreshPermission { _ in
                        seam.registerForRemoteNotifications()
                        completion?(true)
                    }
                    return
                }
                if status == .denied {
                    refreshPermission { _ in
                        if fallbackToSettings {
                            OpenPush.onLog("• notifications are denied — opening this app's " +
                                           "notification settings")
                            seam.openSettings()
                        } else {
                            OpenPush.onLog("• notifications are denied in Settings; iOS will " +
                                           "not show the prompt again")
                        }
                        completion?(false)
                    }
                    return
                }
                // Quiet authorization does not show or consume the system prompt.
                // Keep the durable flag clear so a later full request remains
                // distinguishable from a repeated prompt attempt.
                if !provisional { OpenPush.state.recordPrompted() }
                seam.request(provisional) { granted in
                    refreshPermission { _ in
                        if granted {
                            seam.registerForRemoteNotifications()
                            OpenPush.onLog(provisional
                                ? "✓ provisional authorization granted — notifications deliver quietly"
                                : "✓ notification authorization granted")
                        } else {
                            OpenPush.onLog("• notification authorization was not granted")
                        }
                        completion?(granted)
                    }
                }
            }
        }

        static func refreshPermission(then: (@Sendable (Int) -> Void)? = nil) {
            let seam = OpenPush.permissionSeam
            let apply: @Sendable (OpenPush.AuthorizationSnapshot) -> Void = { snapshot in
                OpenPush.state.setPermissionGranted(snapshot.status.isGranted)
                OpenPush.state.setPermissionStatus(snapshot.status)
                let types = OpenPush.notificationTypes(from: snapshot,
                                                       prompted: OpenPush.state.wasPrompted)
                OpenPush.state.setNotificationTypes(types)
                OpenPush.notifyPermissionObservers()
                then?(OpenPush.wireStatus())
            }
            if let settings = seam.settings {
                settings(apply)
            } else {
                seam.status { apply(OpenPush.AuthorizationSnapshot.derived(from: $0)) }
            }
        }

        /// Refresh the cache and, only when authorization already exists, ask
        /// iOS to re-issue the APNs token. This path never prompts.
        static func resyncAPNsTokenIfAuthorized() {
            let seam = OpenPush.permissionSeam
            refreshPermission { _ in
                guard OpenPush.Notifications.permission else { return }
                seam.registerForRemoteNotifications()
                OpenPush.onLog("• notification authorization is already granted — asking " +
                               "iOS to re-issue this device's APNs token")
            }
        }
    }
}

public extension OpenPush.Notifications {
    /// The compatibility argument order — the response block first — so a migrated
    /// call site compiles unchanged. Forwards to
    /// `requestPermission(fallbackToSettings:completion:)`.
    /// The response block is NOT defaulted on purpose: with a default it would make
    /// a bare `requestPermission()` ambiguous against the labelled overload above.
    static func requestPermission(
        _ block: @escaping @Sendable (Bool) -> Void,
        fallbackToSettings: Bool = false
    ) {
        requestPermission(fallbackToSettings: fallbackToSettings, completion: block)
    }

    static func addPermissionObserver(
        _ observer: @escaping @Sendable (Bool) -> Void
    ) -> UUID {
        OpenPush.state.addPermissionObserver(observer)
    }

    static func removePermissionObserver(_ id: UUID) {
        OpenPush.state.removePermissionObserver(id)
    }

    /// Recomputes notification permission and updates the subscription only when
    /// it differs from the last registration accepted by the server.
    static func onAppForegrounded() {
        OpenPush.beginForegroundSession()
        OpenPush.sendAppSessionIfDue()
        OpenPush.InAppMessages.onAppForegrounded()
        // A receipt whose retries ran out while the app was away is owed to the
        // server the moment the app is back.
        OpenPush.ReceiptQueue.shared.drain()
        let wasGranted = OpenPush.Notifications.permission
        refreshPermission { status in
            syncNotificationTypes(status)
            registerForTokenIfNewlyAuthorized(wasGranted: wasGranted)
        }
    }

    /// Authorization granted outside this SDK — another plugin's `requestAuthorization` — is
    /// noticed when the alert's dismissal reactivates the app, but only this SDK's own prompt
    /// asks iOS for the APNs token. Without this the device would hold no token, and so stay
    /// unreachable, until the next launch. Only a change to granted counts: a launch that was
    /// already authorized asked for the token in `initialize`, and is just waiting for it.
    static func registerForTokenIfNewlyAuthorized(wasGranted: Bool) {
        guard !wasGranted, OpenPush.Notifications.permission, OpenPush.currentToken == nil else { return }
        OpenPush.permissionSeam.registerForRemoteNotifications()
        OpenPush.onLog("• notification authorization was granted outside the SDK — asking iOS " +
                       "for this device's APNs token")
    }

    static func addClickListener(
        _ listener: @escaping @Sendable (OpenPush.ClickEvent) -> Void
    ) -> UUID {
        OpenPush.state.addClickListener(listener)
    }

    static func removeClickListener(_ id: UUID) {
        OpenPush.state.removeClickListener(id)
    }

    static func addForegroundLifecycleListener(
        _ listener: @escaping @Sendable (OpenPush.ForegroundEvent) -> Void
    ) -> UUID {
        OpenPush.state.addForegroundListener(listener)
    }

    static func removeForegroundLifecycleListener(_ id: UUID) {
        OpenPush.state.removeForegroundListener(id)
    }

    /// Forward this from `UNUserNotificationCenterDelegate`
    /// `userNotificationCenter(_:willPresent:withCompletionHandler:)` and return
    /// its result to the completion handler.
    ///
    /// Adapter only: it pulls `userInfo` out of the notification and nothing else,
    /// because `UNNotification` cannot be constructed in a test. All behavior is
    /// in `handleForeground(userInfo:)`.
    static func processForeground(_ notification: UNNotification) -> UNNotificationPresentationOptions {
        handleForeground(userInfo: notification.request.content.userInfo)
    }

    /// The same, for a host that wants to decide later: forward this from
    /// `userNotificationCenter(_:willPresent:withCompletionHandler:)` and hand it
    /// that method's completion handler instead of returning a value.
    ///
    /// The listeners, the foreign-notification guard, and the receipt are exactly
    /// those of `processForeground(_:)`. What this spelling adds is that a
    /// listener which called `preventDefault()` may still call the event's
    /// `display()` to present after all: until it does, the answer is held, for at
    /// most 25 seconds, after which the notification is suppressed as asked. The
    /// completion handler runs exactly once on every path.
    ///
    /// Adapter only — see `processForeground(_:)`.
    static func processForeground(
        _ notification: UNNotification,
        completion: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        handleForeground(userInfo: notification.request.content.userInfo,
                         completion: completion)
    }

    /// Payload form for delegate adapters that already received the APNs
    /// dictionary. This has the same listener, receipt, suppression, and deferred
    /// `display()` behavior as the `UNNotification` overload.
    static func processForeground(
        userInfo: [AnyHashable: Any],
        completion: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        handleForeground(userInfo: userInfo, completion: completion)
    }

    /// Remove every delivered notification and clear the app icon badge. The
    /// stored badge count goes back to 0 with it.
    static func clearAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        setBadgeCount(0)
    }

    /// Set the app icon badge count through the notification center.
    ///
    /// The count is also stored in the App Group passed to `initialize`, so the
    /// next push carrying a badge increment counts up from this value rather than
    /// from a number the icon no longer shows. Without an App Group only the icon
    /// changes.
    static func setBadgeCount(_ count: Int) {
        storeBadgeCount(count)
        OpenPush.badgeSetter(count)
    }

    /// The badge count OpenPush last stored: what `setBadgeCount(_:)` set, or
    /// what the Notification Service Extension raised it to for a push with a
    /// badge increment. nil without an App Group — iOS offers no way to read the
    /// icon's own badge.
    static var badgeCount: Int? {
        guard let appGroup = OpenPush.state.config?.appGroup else { return nil }
        return OpenPushSharedState.badgeCount(appGroup: appGroup)
    }

    enum ClickDisposition: Equatable, Sendable {
        case dismissed
        case open(actionId: String?)
    }

    /// Swipe-to-dismiss reaches the delegate too when a category opts in. It is
    /// not an open and must never post a `clicked` receipt.
    static func clickDisposition(for identifier: String) -> ClickDisposition {
        if identifier == UNNotificationDismissActionIdentifier { return .dismissed }
        if identifier == UNNotificationDefaultActionIdentifier { return .open(actionId: nil) }
        return .open(actionId: identifier)
    }

    /// Forward this from `UNUserNotificationCenterDelegate`
    /// `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    ///
    /// Adapter only — see `processForeground(_:)`.
    static func processClick(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        switch clickDisposition(for: response.actionIdentifier) {
        case .dismissed:
            let messageId = OpenPush.messageID(from: userInfo) ?? "no message id"
            OpenPush.onLog("• notification \(messageId) dismissed — not an open, " +
                           "no receipt posted")
        case .open(let actionId):
            handleClick(userInfo: userInfo, actionId: actionId)
        }
    }

    /// Whether `processClick(_:)` would ignore this response as a repeat: a tap,
    /// with any action, on a message this install already handled — a resent
    /// copy of the push, or iOS delivering the same response again.
    ///
    /// For a bridge that acts on a tap itself before forwarding it, such as one
    /// that opens the launch URL, so it skips a repeat exactly as the SDK does.
    /// Reading only: `processClick(_:)` is still what records the tap. A
    /// dismissal, a notification OpenPush did not send, and a history that
    /// cannot be read all answer `false`.
    ///
    /// Adapter only — see `processForeground(_:)`.
    static func isRepeatClick(_ response: UNNotificationResponse) -> Bool {
        guard case .open = clickDisposition(for: response.actionIdentifier) else { return false }
        return isRepeatClick(userInfo: response.notification.request.content.userInfo)
    }

    /// Records a tap that a bridge handles itself, without `processClick(_:)`,
    /// and answers whether it is the first for its message. `false` means the
    /// message was already handled — by this call or by `processClick(_:)` — so
    /// the bridge should skip its listeners and receipt. A notification OpenPush
    /// did not send answers `false`; a history that cannot be used answers `true`.
    ///
    /// Adapter only — see `processForeground(_:)`.
    static func recordClick(userInfo: [AnyHashable: Any]) -> Bool {
        guard let messageId = OpenPush.messageID(from: userInfo) else { return false }
        return recordFirstClick(messageId: messageId, actionId: nil)
    }
}

extension OpenPush {
    /// The notification-centre call behind `setBadgeCount(_:)`, behind a seam
    /// like `permissionSeam`: `UNUserNotificationCenter` traps in a bundle-less
    /// test process on a Simulator destination.
    final class BadgeSeam: @unchecked Sendable {
        private let lock = NSLock()
        private var setter: @Sendable (Int) -> Void = BadgeSeam.system

        var current: @Sendable (Int) -> Void { lock.lock(); defer { lock.unlock() }; return setter }
        func set(_ value: @escaping @Sendable (Int) -> Void) { lock.lock(); setter = value; lock.unlock() }

        static let system: @Sendable (Int) -> Void = { count in
            #if os(iOS)
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error {
                    OpenPush.onLog("✗ badge count could not be set: \(error.localizedDescription)")
                }
            }
            #else
            OpenPush.onLog("• badge count is available only in an iOS app")
            #endif
        }
    }

    static let badgeSeam = BadgeSeam()

    static var badgeSetter: @Sendable (Int) -> Void {
        get { badgeSeam.current }
        set { badgeSeam.set(newValue) }
    }
}

extension OpenPush.Notifications {
    /// Mirrors a badge the app set into the App Group, where the extension's
    /// increments read it back.
    static func storeBadgeCount(_ count: Int) {
        guard let appGroup = OpenPush.state.config?.appGroup else {
            OpenPush.onLog("• badge count \(max(0, count)) not stored — no App Group was " +
                           "passed to initialize, so badge increments cannot count from it")
            return
        }
        OpenPushSharedState.setBadgeCount(count, appGroup: appGroup)
    }

    static let defaultPresentation: UNNotificationPresentationOptions =
        [.banner, .list, .sound, .badge]

    /// How long the asynchronous path holds a prevented answer open. iOS gives
    /// the delegate a bounded time to answer `willPresent`; a host that prevents
    /// the default and then goes quiet must resolve to something rather than hang,
    /// and "suppressed" is what it asked for.
    static let deferredDisplayWindow: Double = 25

    /// Everything both spellings do before the presentation decision: the
    /// foreign-notification guard, the listeners, and the receipt. `nil` means
    /// the notification is not ours. Delivery deliberately does not run app
    /// foreground housekeeping or refresh authorization.
    private static func fireForegroundListeners(
        userInfo: [AnyHashable: Any]
    ) -> OpenPush.ForegroundEvent? {
        let notification = OpenPush.Notification(userInfo: userInfo)
        // A local notification the host scheduled, or another provider's push,
        // is none of our business: present it as iOS would and report nothing.
        guard notification.isOpenPush else { return nil }
        let event = OpenPush.ForegroundEvent(messageId: notification.messageId,
                                             payload: stringPayload(from: userInfo),
                                             notification: notification)
        for listener in OpenPush.state.foregroundListenerList { listener(event) }
        // The Notification Service Extension may already have posted this one, and
        // this process cannot tell: it is a separate process with its own dedupe.
        // The server keeps the first timestamp, so the duplicate is harmless, and a
        // host without an extension still gets a delivery record.
        OpenPush.receipt("received", messageID: event.messageId)
        return event
    }

    static func handleForeground(
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        OpenPush.assertOnDelegateThread("processForeground")
        guard let event = fireForegroundListeners(userInfo: userInfo) else {
            return defaultPresentation
        }
        let options = event.isPrevented ? [] : defaultPresentation
        if !options.isEmpty {
            OpenPush.receipt("confirmed", messageID: event.messageId)
        }
        return options
    }

    static func handleForeground(
        userInfo: [AnyHashable: Any],
        completion: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        OpenPush.assertOnDelegateThread("processForeground")
        // A foreign notification is presented untouched and is never reported
        // as ours. For an OpenPush notification, wrap the final decision so a
        // confirmed receipt is posted only when non-empty presentation options
        // are actually handed back to iOS.
        guard let event = fireForegroundListeners(userInfo: userInfo) else {
            completion(defaultPresentation)
            return
        }
        let reportingCompletion: @Sendable (UNNotificationPresentationOptions) -> Void = {
            options in
            completion(options)
            if !options.isEmpty {
                OpenPush.receipt("confirmed", messageID: event.messageId)
            }
        }
        // Nothing to defer when no listener suppressed it: answer immediately
        // and arm no timer.
        guard event.isPrevented else {
            reportingCompletion(defaultPresentation)
            return
        }
        guard event.holdDecision(presenting: defaultPresentation,
                                 completion: reportingCompletion) else { return }
        let timeout = OpenPush.state.schedulerSeam.run(deferredDisplayWindow) {
            guard event.deferredDecisionTimedOut() else { return }
            OpenPush.onLog("• foreground presentation of \(event.messageId ?? "no message id") " +
                           "suppressed — preventDefault() was not followed by display() " +
                           "within \(Int(deferredDisplayWindow))s")
        }
        event.holdTimeout(timeout)
    }

    static let pendingClickLimit = 10

    static func handleClick(userInfo: [AnyHashable: Any], actionId: String?) {
        OpenPush.assertOnDelegateThread("processClick")
        let notification = OpenPush.Notification(userInfo: userInfo)
        guard notification.isOpenPush, let messageId = notification.messageId else {
            OpenPush.onLog("• click on a notification OpenPush did not send — ignored")
            return
        }
        // Before the receipt and before any listener: a repeat must not reach
        // either, and a held cold-start click counts as handled once it is held.
        guard recordFirstClick(messageId: messageId, actionId: actionId) else { return }
        OpenPush.receipt("clicked", messageID: messageId)
        let url = launchURLToOpen(for: notification, actionId: actionId)
        let event = OpenPush.ClickEvent(messageId: messageId,
                                        payload: stringPayload(from: userInfo),
                                        actionId: actionId,
                                        notification: notification,
                                        launchURLOpened: url != nil)
        let listeners = OpenPush.state.deliverOrHold(event)
        if listeners.isEmpty {
            OpenPush.onLog("• click \(messageId) held — no click listener " +
                           "is attached yet; it is delivered to the first one added")
        }
        for listener in listeners { listener(event) }
        // After the listeners, and whether or not the click was held: a cold
        // start must not keep the URL waiting for a listener the app adds later.
        if let url {
            OpenPush.onLog("• opening the launch URL of click \(messageId)")
            OpenPush.launchURLOpener(url)
        }
    }

    /// Records the tap and answers whether it is the first for its message,
    /// whatever its action. Every failure answers `true`: the tap is handled,
    /// and only the repeat check is lost.
    private static func recordFirstClick(messageId: String, actionId: String?) -> Bool {
        // Until the first unlock this process cannot read what it stored, so the
        // history would look empty and a write would replace it with one entry.
        guard OpenPush.state.protectedDataReadable() else {
            OpenPush.onLog("• click \(messageId) handled without the repeat check — stored " +
                           "state is not readable before the device's first unlock")
            return true
        }
        let key = clickKey(messageId: messageId)
        do {
            guard try OpenPush.clickHistory.recordIfNew(key, at: Date()) else {
                OpenPush.onLog("• click \(messageId) (action \(actionId ?? "default")) " +
                               "ignored — this message was already handled, so this is a " +
                               "repeated tap or a resent copy; no listener, no receipt")
                return false
            }
            return true
        } catch {
            OpenPush.onLog("✗ click history unavailable (\(error.localizedDescription)) — " +
                           "click \(messageId) handled without the repeat check")
            return true
        }
    }

    static func isRepeatClick(userInfo: [AnyHashable: Any]) -> Bool {
        guard let messageId = OpenPush.messageID(from: userInfo),
              OpenPush.state.protectedDataReadable() else { return false }
        let key = clickKey(messageId: messageId)
        return (try? OpenPush.clickHistory.contains(key, at: Date())) ?? false
    }

    static func syncNotificationTypes(_ status: Int) {
        OpenPush.notifySubscriptionObservers()
        guard status != OpenPush.state.lastAcceptedStatus else { return }
        guard let token = OpenPush.currentToken else {
            OpenPush.onLog("• notification_types \(status) held — no APNs token yet, so it " +
                           "is sent with the next registration")
            return
        }
        OpenPush.onLog("• notification_types changed to \(status) — updating this subscription")
        OpenPush.performRegistration(token: token, completion: nil)
    }

    /// APNs `userInfo` is `[AnyHashable: Any]`, which is not `Sendable` and not
    /// safe to hand to a host closure. Coercing the top level to strings keeps
    /// the event crossing-safe and keeps numeric keys usable instead of dropped.
    static func stringPayload(from userInfo: [AnyHashable: Any]) -> [String: String] {
        var payload: [String: String] = [:]
        for (key, value) in userInfo {
            guard let name = key as? String else { continue }
            switch value {
            case let text as String: payload[name] = text
            case let number as NSNumber: payload[name] = number.stringValue
            default: payload[name] = String(describing: value)
            }
        }
        return payload
    }
}
