import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushSubscriptionTests: OpenPushTestCase {
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private func seam(status: OpenPush.PermissionStatus) -> OpenPush.PermissionSeam {
        OpenPush.PermissionSeam(status: { done in done(status) },
                                request: { _, done in done(status.isGranted) },
                                openSettings: {},
                                registerForRemoteNotifications: {})
    }

    override func tearDown() {
        OpenPush.permissionSeam = .system
        super.tearDown()
    }

    func testPushSubscriptionReportsServerIdentifierTokenAndOptedInState() {
        OpenPush.permissionSeam = seam(status: .granted)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(201, #"{"id":"sub_9"}"#) })

        OpenPush.register(token: "aabb")

        XCTAssertEqual(OpenPush.User.pushSubscription.snapshot(),
                       OpenPush.PushSubscriptionState(id: "sub_9", token: "aabb",
                                                      optedIn: true, status: 7))
    }

    func testPushSubscriptionIsNotOptedInWithoutPermission() {
        OpenPush.permissionSeam = seam(status: .denied)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(201, #"{"id":"sub_10"}"#) })

        OpenPush.register(token: "aabb")

        let subscription = OpenPush.User.pushSubscription
        XCTAssertEqual(subscription.id, "sub_10")
        XCTAssertEqual(subscription.token, "aabb")
        XCTAssertFalse(subscription.optedIn,
                       "a token without authorization is not an opted-in subscriber")
    }

    func testPushSubscriptionIsEmptyBeforeAnyRegistration() {
        OpenPush.permissionSeam = seam(status: .notDetermined)
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { _, done in done(201, "{}") })
        OpenPush.state.setToken(nil, persist: true)

        XCTAssertEqual(OpenPush.User.pushSubscription.snapshot(),
                       OpenPush.PushSubscriptionState(id: nil, token: nil,
                                                      optedIn: false, status: -18))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
