import XCTest
@testable import OpenPush
import OpenPushCore
import OpenPushOneSignal

/// The `OpenPushOneSignal` compatibility facade is names only: every member is
/// one line of delegation. These tests therefore never assert on the facade's own
/// behavior — they assert that a call made through the facade's spelling lands on
/// the SAME OpenPush state and produces the SAME wire body as the equivalent
/// `OpenPush.` call. The facade's own symbol names are the code under test, so
/// they are spelled as a migrating host spells them.
final class OpenPushOneSignalAliasTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private final class AtomicCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        func get() -> Int { lock.withLock { count } }
    }

    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool { lock.withLock { value } }
    }

    private let clock = ManualClock()

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = clock.seam
        OpenPush.bundledSDKKeySeam = { "pk_bundled" }
    }

    override func tearDown() {
        OpenPush.bundledSDKKeySeam = { OpenPushConfiguration.bundledSDKKey() }
        super.tearDown()
    }

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func start(_ capture: Capture) {
        OneSignal.initialize(appId: "sample", sdkKey: "sdk_public",
                             serverURL: "https://push.example",
                             transport: { request, done in
                                 capture.set(request)
                                 done(200, #"{"id":"sub_1"}"#)
                             })
    }

    /// The v5-shaped `initialize` is one line of delegation to
    /// `OpenPush.initialize(_:withLaunchOptions:)`, so the launch-options branch
    /// and its log line live in exactly one place. Both spellings must configure
    /// the process from the bundled key; `launchOptions` is accepted and unused,
    /// which is observable only as "it did not change the outcome".
    func testAliasCompatibilityShapedInitializeConfiguresFromTheBundledKey() {
        OneSignal.initialize("sample")
        XCTAssertTrue(OpenPush.isInitialized)
    }

    func testAliasInitializeAcceptsAndIgnoresLaunchOptions() {
        OneSignal.initialize("sample", withLaunchOptions: ["from_notification": true])
        XCTAssertTrue(OpenPush.isInitialized)
    }

    func testAliasLoginDrivesTheOpenPushIdentity() throws {
        let capture = Capture()
        start(capture)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        OneSignal.login("player-9")
        XCTAssertEqual(try body(of: capture.get())["external_id"] as? String, "player-9")
    }

    func testCurrentLoginTokenSpellingForwardsTheIdentityProof() throws {
        let capture = Capture()
        start(capture)
        OneSignal.Notifications.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))

        OneSignal.login(externalId: "player-9", token: "jwt-9")

        let payload = try body(of: capture.get())
        XCTAssertEqual(payload["external_id"] as? String, "player-9")
        XCTAssertEqual(payload["external_id_auth_hash"] as? String, "jwt-9")
    }

    func testAliasLogoutSendsAnExplicitEmptyExternalId() throws {
        let capture = Capture()
        start(capture)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        OneSignal.login("player-9")
        OneSignal.logout()
        XCTAssertEqual(try body(of: capture.get())["external_id"] as? String, "")
    }

    func testAliasTagsAndAliasesShareTheOpenPushSessionMaps() {
        OneSignal.User.addTag(key: "tier", value: "vip")
        OneSignal.User.addAlias(label: "steam_id", id: "7656")
        XCTAssertEqual(OpenPush.User.getTags()["tier"], "vip")
        XCTAssertEqual(OneSignal.User.getTags()["tier"], "vip")
    }

    func testAliasOutcomePostsAJourneyCustomEvent() throws {
        let capture = Capture()
        start(capture)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))

        OneSignal.Session.addOutcomeWithValue("tutorial_complete", 1)
        clock.fire(OpenPush.writeCoalescingWindow)

        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.path, "/v1/apps/sample/events")
        let events = try XCTUnwrap(try body(of: request)["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["name"] as? String, "tutorial_complete")
        XCTAssertEqual((events.first?["properties"] as? [String: Any])?["value"] as? Int, 1)
    }

    func testCurrentUserTrackEventSpellingPostsACustomEvent() throws {
        let capture = Capture()
        start(capture)
        OneSignal.Notifications.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))

        OneSignal.User.trackEvent(name: "level_complete", properties: ["level": 7])
        clock.fire(OpenPush.writeCoalescingWindow)

        let events = try XCTUnwrap(try body(of: capture.get())["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["name"] as? String, "level_complete")
        XCTAssertEqual((events.first?["properties"] as? [String: Any])?["level"] as? Int, 7)
    }

    /// A "unique" outcome is not a property on the event — it is a promise that
    /// recording it twice on one device is one event. That promise is kept by the
    /// idempotency key, which the server dedupes on. The key names the
    /// installation by its subscription id: the push token is a credential, and
    /// writing it into an analytics store would cross the SDK's own boundary.
    func testAddUniqueOutcomeUsesADeviceScopedIdempotencyKey() throws {
        let capture = Capture()
        start(capture)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        let token = try XCTUnwrap(OpenPush.currentToken)
        let subscriptionID = try XCTUnwrap(OpenPush.User.pushSubscription.id)

        OneSignal.Session.addUniqueOutcome("tutorial_complete")
        OneSignal.Session.addUniqueOutcome("tutorial_complete")
        clock.fire(OpenPush.writeCoalescingWindow)

        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.path, "/v1/apps/sample/events")
        let events = try XCTUnwrap(try body(of: request)["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["idempotency_key"] as? String },
                       Array(repeating: "unique:tutorial_complete:\(subscriptionID)",
                             count: 2),
                       "the same outcome on the same device carries the same key")
        XCTAssertTrue(events.allSatisfy {
            ($0["idempotency_key"] as? String)?.contains(token) == false
        }, "the push token never reaches the analytics store")
        XCTAssertNil((events.first?["properties"] as? [String: Any])?["unique"],
                     "the honest signal is the key, not an invented property")
    }

    func testAliasPushSubscriptionIsALiveViewOverTheAccessor() throws {
        let capture = Capture()
        start(capture)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        OneSignal.User.pushSubscription.optOut()
        XCTAssertEqual(try body(of: capture.get())["status"] as? Int, -2)
        XCTAssertFalse(OneSignal.User.pushSubscription.optedIn)
        XCTAssertFalse(OpenPush.User.pushSubscription.optedIn)
    }

    func testAliasSubscriptionObserverIsRegisteredWithOpenPush() {
        let capture = Capture()
        start(capture)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        let seen = AtomicCount()
        let handle = OneSignal.User.pushSubscription.addObserver { _ in seen.bump() }
        OneSignal.User.pushSubscription.optOut()
        waitForMainQueue()
        XCTAssertGreaterThan(seen.get(), 0)
        OneSignal.User.pushSubscription.removeObserver(handle)
    }

    func testAliasRequestPermissionKeepsTheCompatibilityArgumentOrder() {
        let granted = AtomicFlag()
        OpenPush.permissionSeam = OpenPush.PermissionSeam(
            status: { done in done(.notDetermined) },
            request: { _, done in done(true) },
            openSettings: {},
            registerForRemoteNotifications: {})
        OneSignal.Notifications.requestPermission({ granted.set($0) },
                                                  fallbackToSettings: true)
        waitForMainQueue()
        XCTAssertTrue(granted.get())
    }

    func testCurrentProvisionalAuthorizationSpellingUsesTheQuietPath() {
        let granted = AtomicFlag()
        let provisional = AtomicFlag()
        OpenPush.permissionSeam = OpenPush.PermissionSeam(
            status: { done in done(.notDetermined) },
            request: { quiet, done in provisional.set(quiet); done(true) },
            openSettings: {},
            registerForRemoteNotifications: {})

        OneSignal.Notifications.registerForProvisionalAuthorization { granted.set($0) }

        waitForMainQueue()
        XCTAssertTrue(granted.get())
        XCTAssertTrue(provisional.get())
    }

    func testManualForegroundPayloadForwardsSuppression() {
        let capture = Capture()
        start(capture)
        OneSignal.Notifications.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        let suppressed = AtomicFlag()
        let listener = OneSignal.Notifications.addForegroundLifecycleListener {
            $0.preventDefault()
        }
        defer { OneSignal.Notifications.removeForegroundLifecycleListener(listener) }

        OneSignal.Notifications.willPresentNotification(
            payload: ["op_message_id": "m1"]
        ) { notification in
            suppressed.set(notification == nil)
        }
        clock.fire(OpenPush.Notifications.deferredDisplayWindow)

        XCTAssertTrue(suppressed.get())
    }

    func testAliasClickListenerIsTheOpenPushListener() {
        let seen = AtomicCount()
        let handle = OneSignal.Notifications.addClickListener { _ in seen.bump() }
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        XCTAssertGreaterThan(seen.get(), 0)
        OneSignal.Notifications.removeClickListener(handle)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
