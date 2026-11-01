import XCTest
@testable import OpenPush
import OpenPushCore

/// OpenPush keeps process-global state and persists sessions in UserDefaults.
/// Every test class clears the shared default session so tests cannot inherit
/// state from another class or from an earlier test run.
class OpenPushTestCase: XCTestCase {
    /// `PermissionSeam.system` is inert on the macOS host that runs `swift test`
    /// — compiled without UIKit it answers "not determined" and touches nothing
    /// — but on an iOS Simulator destination it reaches the real
    /// `UNUserNotificationCenter`, which traps in a bundle-less test process
    /// (`bundleProxyForCurrentProcess is nil`). This is the same inert answer,
    /// spelled out rather than inherited from the platform, so a test that is
    /// not about permission behaves identically on either destination. Tests
    /// that are about permission install a seam of their own.
    static let inertPermissionSeam = OpenPush.PermissionSeam(
        status: { done in done(.notDetermined) },
        request: { _, done in done(false) },
        openSettings: {},
        registerForRemoteNotifications: {},
        settings: { done in done(OpenPush.AuthorizationSnapshot(status: .notDetermined)) }
    )

    private static var sharedSessionKey: String {
        OpenPush.State.sessionKey(
            forTokenKey: OpenPushConfiguration(appID: "", sdkKey: "").tokenKey)
    }

    private static var sharedTokenKey: String {
        OpenPushConfiguration(appID: "", sdkKey: "").tokenKey
    }

    private static var sharedLiveActivityTypesKey: String {
        OpenPush.State.liveActivityTypesKey(forTokenKey: sharedTokenKey)
    }

    private static var sharedLiveActivityQueueKey: String {
        OpenPush.LiveActivityExecutor.storageKey(forTokenKey: sharedTokenKey)
    }

    private static var sharedReceiptQueueKey: String {
        OpenPush.ReceiptQueue.storageKey(forTokenKey: sharedTokenKey)
    }

    private static var sharedReceiptSentKey: String {
        OpenPush.ReceiptQueue.sentKey(forTokenKey: sharedTokenKey)
    }

    private static var sharedAddressWritesKey: String {
        OpenPush.AddressSubscriptions.pendingKey(forTokenKey: sharedTokenKey)
    }

    private static var sharedAddressIDsKey: String {
        OpenPush.AddressSubscriptions.idsKey(forTokenKey: sharedTokenKey)
    }

    /// Public callbacks are posted to the main queue, never called inline. The
    /// main queue is serial, so once a block posted here has run, every callback
    /// posted before it has run too. Call it from the test method (the main
    /// thread) after the action and before asserting on what the host heard —
    /// including when the assertion is that the host heard nothing.
    func waitForMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    override class func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: sharedSessionKey)
        UserDefaults.standard.removeObject(forKey: sharedTokenKey)
        UserDefaults.standard.removeObject(forKey: sharedLiveActivityTypesKey)
        UserDefaults.standard.removeObject(forKey: sharedLiveActivityQueueKey)
        UserDefaults.standard.removeObject(forKey: sharedReceiptQueueKey)
        UserDefaults.standard.removeObject(forKey: sharedReceiptSentKey)
        UserDefaults.standard.removeObject(forKey: sharedAddressWritesKey)
        UserDefaults.standard.removeObject(forKey: sharedAddressIDsKey)
    }

    override class func tearDown() {
        UserDefaults.standard.removeObject(forKey: sharedSessionKey)
        UserDefaults.standard.removeObject(forKey: sharedTokenKey)
        UserDefaults.standard.removeObject(forKey: sharedLiveActivityTypesKey)
        UserDefaults.standard.removeObject(forKey: sharedLiveActivityQueueKey)
        UserDefaults.standard.removeObject(forKey: sharedReceiptQueueKey)
        UserDefaults.standard.removeObject(forKey: sharedReceiptSentKey)
        UserDefaults.standard.removeObject(forKey: sharedAddressWritesKey)
        UserDefaults.standard.removeObject(forKey: sharedAddressIDsKey)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        OpenPush.permissionSeam = Self.inertPermissionSeam
        // Retry delays are jittered in production. Pin the factor so every test
        // that fires a ManualClock delay by value keeps matching; the tests that
        // are about jitter restore `OpenPush.systemRetryJitter` themselves.
        OpenPush.retryJitter = { $0 }
        OpenPush.lastRetryAfter.store(nil)
        OpenPush.state.cancelWriteWindow()
        OpenPush.state.cancelPendingRetry()
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.LiveActivities.executor.resetForTests()
        OpenPush.LiveActivities.authorizationMonitor.resetForTests()
        OpenPush.CustomEvents.shared.resetForTests()
        OpenPush.ReceiptQueue.shared.resetForTests()
        OpenPush.AddressSubscriptions.shared.resetForTests()
        OpenPush.IamEngine.shared.resetForTests()
        // On a UIKit destination an accepted registration also fetches in-app
        // definitions, which is a second request through the same transport.
        // Every assertion that counts what the transport saw was written on the
        // macOS host, where the fetch is compiled out; the tests that are about
        // in-app messages arm it again.
        OpenPush.IamEngine.shared.setAutomaticFetchForTests(false)
        // `systemProtectedDataAvailable` asks UIKit, and a bundle-less test
        // process on a Simulator is told the device is locked, which leaves
        // every stored session pending and unreadable. The macOS host answers
        // `true` unconditionally; say so here so both destinations restore.
        // The tests about a locked device install a seam of their own.
        OpenPush.protectedDataAvailableSeam = { true }
        // The production history is `UserDefaults.standard`, which outlives a
        // test: a message id reused by a later test would read as a repeat tap.
        OpenPush.clickHistory = FakeClickHistory()
        // Process-global like the rest: the compatibility facade's `initialize`
        // turns launch-URL opening on, and no other test may inherit that.
        OpenPush.launchURLs.resetForTests()
        // Launch URLs open by default, and `UIApplication.open` has no business
        // running in a test process; the tests about opening install a recorder.
        OpenPush.launchURLOpener = { _ in }
        // `UNUserNotificationCenter` traps in a bundle-less test process on a
        // Simulator destination, exactly like the permission seam above.
        OpenPush.badgeSetter = { _ in }
        OpenPush.state.clearObserversForTests()
        UserDefaults.standard.removeObject(forKey: Self.sharedSessionKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedLiveActivityTypesKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedLiveActivityQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedReceiptQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedReceiptSentKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedAddressWritesKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedAddressIDsKey)
    }

    override func tearDown() {
        // `permissionSeam` and `protectedDataAvailableSeam` are deliberately put
        // back to the inert stub and a constant `true`, NOT to the system
        // defaults the SDK ships. `UNUserNotificationCenter` and the real
        // protected-data check need an app bundle and a running app, which a
        // `swift test` bundle on a Simulator does not have; restoring them would
        // make whichever test ran next hang or raise a prompt. The system paths
        // behind both seams are exercised only by the sample app builds.
        OpenPush.permissionSeam = Self.inertPermissionSeam
        OpenPush.scheduler = .system
        OpenPush.retryJitter = OpenPush.systemRetryJitter
        OpenPush.lastRetryAfter.store(nil)
        OpenPush.backgroundAssertion = .system
        OpenPush.preferredLanguageSeam = { Locale.preferredLanguages.first }
        OpenPush.protectedDataAvailableSeam = { true }
        OpenPush.clickHistory = FakeClickHistory()
        OpenPush.launchURLs.resetForTests()
        OpenPush.launchURLOpener = { _ in }
        OpenPush.badgeSetter = { _ in }
        OpenPush.IamEngine.shared.resetForTests()
        OpenPush.onLog = OpenPush.State.defaultLogSink
        OpenPush.onRegistered = {}
        OpenPush.onRegistrationFailed = { _ in }
        OpenPush.state.clearIdentityVerificationHookForTests()
        UserDefaults.standard.removeObject(forKey: Self.sharedSessionKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedLiveActivityTypesKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedLiveActivityQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedReceiptQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedReceiptSentKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedAddressWritesKey)
        UserDefaults.standard.removeObject(forKey: Self.sharedAddressIDsKey)
        super.tearDown()
    }
}
