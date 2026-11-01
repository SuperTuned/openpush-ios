import XCTest
@testable import OpenPush
import OpenPushCore

/// Four OpenPush overloads exist so a host migrating from another push SDK can
/// replace that SDK's prefix with `OpenPush.` and compile unchanged. Every other
/// member the compatibility surface maps already matches by name, so these four
/// are the whole delta — see the migration guide. Pinning them here stops a later
/// cleanup from "tidying away" a signature the migration path depends on.
final class OpenPushMigrationOverloadTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        func get() -> Int { lock.withLock { n } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool { lock.withLock { value } }
    }

    override func setUp() {
        super.setUp()
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

    func testTheCompatibilityShapedInitializeConfiguresFromTheBundledKey() {
        OpenPush.initialize("sample", withLaunchOptions: [:])
        XCTAssertTrue(OpenPush.isInitialized)
    }

    func testPositionalLoginSetsTheExternalIdOnTheWire() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login("player-9")
        XCTAssertEqual(try body(of: capture.get())["external_id"] as? String, "player-9")
    }

    func testTheInstanceObserverSharesTheStaticObserverList() {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        let seen = Counter()
        // Registered through the instance, removed through the static pair: one list.
        let handle = OpenPush.User.pushSubscription.addObserver { _ in seen.bump() }
        OpenPush.PushSubscription.removeObserver(handle)
        OpenPush.User.pushSubscription.optOut()
        waitForMainQueue()
        XCTAssertEqual(seen.get(), 0, "the instance and static spellings must share one list")
    }

    func testTheInstanceObserverReceivesChanges() {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        let seen = Counter()
        let handle = OpenPush.User.pushSubscription.addObserver { _ in seen.bump() }
        OpenPush.User.pushSubscription.optOut()
        waitForMainQueue()
        XCTAssertGreaterThan(seen.get(), 0)
        OpenPush.User.pushSubscription.removeObserver(handle)
    }

    func testRequestPermissionAcceptsTheCompatibilityArgumentOrder() {
        let granted = Flag()
        OpenPush.permissionSeam = OpenPush.PermissionSeam(
            status: { done in done(.notDetermined) },
            request: { _, done in done(true) },
            openSettings: {},
            registerForRemoteNotifications: {})
        OpenPush.Notifications.requestPermission({ granted.set($0) },
                                                 fallbackToSettings: true)
        waitForMainQueue()
        XCTAssertTrue(granted.get(),
                      "the response block is v5's FIRST argument, not a trailing label")
    }
}
