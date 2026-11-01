import XCTest
@testable import OpenPush

final class OpenPushForegroundSyncTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
        func count() -> Int { lock.withLock { requests.count } }
        func registrations() -> [URLRequest] {
            lock.withLock { requests.filter { $0.url?.path.hasSuffix("/subscriptions") == true } }
        }
    }

    private final class SeamBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: OpenPush.AuthorizationSnapshot
        private var apnsRegistrations = 0
        init(_ snapshot: OpenPush.AuthorizationSnapshot) { self.snapshot = snapshot }
        func set(_ value: OpenPush.AuthorizationSnapshot) { lock.withLock { snapshot = value } }
        var registrationsForRemoteNotifications: Int { lock.withLock { apnsRegistrations } }
        func seam() -> OpenPush.PermissionSeam {
            OpenPush.PermissionSeam(
                status: { done in done(self.lock.withLock { self.snapshot.status }) },
                request: { _, done in done(false) }, openSettings: {},
                registerForRemoteNotifications: { self.lock.withLock { self.apnsRegistrations += 1 } },
                settings: { done in done(self.lock.withLock { self.snapshot }) })
        }
    }

    private func status(of request: URLRequest) throws -> Int {
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["status"] as? Int)
    }

    func testEnablingNotificationsInSettingsSyncsOnNextForeground() throws {
        let capture = Capture()
        let box = SeamBox(.init(status: .denied))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")
        XCTAssertEqual(try status(of: capture.all().last!), 0)
        let baseline = capture.registrations().count

        box.set(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.Notifications.onAppForegrounded()

        XCTAssertEqual(capture.registrations().count, baseline + 1)
        XCTAssertEqual(try status(of: capture.registrations().last!), 7)
    }

    func testAPermissionGrantedByAnotherPromptAsksForTheAPNsToken() {
        // Another plugin called requestAuthorization: the alert's dismissal reactivates the app,
        // and with no token yet nothing else would ever ask iOS for one until the next launch.
        let box = SeamBox(.init(status: .notDetermined))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        let atLaunch = box.registrationsForRemoteNotifications

        box.set(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(box.registrationsForRemoteNotifications, atLaunch + 1)

        OpenPush.register(token: "aabb")
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(box.registrationsForRemoteNotifications, atLaunch + 1,
                       "a device that already holds a token is not asked again")
    }

    func testAnAlreadyAuthorizedLaunchIsNotAskedAgainOnItsFirstForeground() {
        let box = SeamBox(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        let atLaunch = box.registrationsForRemoteNotifications
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(box.registrationsForRemoteNotifications, atLaunch,
                       "initialize already asked; the token is simply still on its way")
    }

    func testAForegroundWithoutPermissionNeverAsksForTheAPNsToken() {
        let box = SeamBox(.init(status: .denied))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(box.registrationsForRemoteNotifications, 0)
    }

    func testUnchangedForegroundsSendNothing() {
        let capture = Capture()
        let box = SeamBox(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")
        let baseline = capture.registrations().count
        OpenPush.Notifications.onAppForegrounded()
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(capture.registrations().count, baseline)
    }

    func testRevokingPermissionAndFailedSyncAreRetried() throws {
        let capture = Capture()
        let box = SeamBox(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                let registrations = capture.registrations().count
                                done(registrations == 2 ? 400 : 200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")
        box.set(.init(status: .denied))
        OpenPush.Notifications.onAppForegrounded()
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(capture.registrations().count, 3)
        XCTAssertEqual(try status(of: capture.registrations().last!), 0)
    }

    func testReceivingAForegroundPushDoesNotRewriteASubscribedDeviceAsStatusZero() throws {
        let capture = Capture()
        let box = SeamBox(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")
        XCTAssertEqual(try status(of: capture.registrations().last!), 7)
        let baseline = capture.registrations().count

        // A delivery is not an app lifecycle transition. Even if a permission read would
        // temporarily report denied here, willPresent must only dispatch and record receipts.
        box.set(.init(status: .denied))
        _ = OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "m1"])

        XCTAssertEqual(capture.registrations().count, baseline)
        XCTAssertTrue(OpenPush.Notifications.permission)
        XCTAssertTrue(OpenPush.User.pushSubscription.optedIn)
    }

    func testForegroundWithoutTokenIsHeldForNextRegistration() throws {
        let capture = Capture()
        let box = SeamBox(.init(status: .denied))
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        box.set(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(capture.count(), 0)
        OpenPush.register(token: "aabb")
        XCTAssertEqual(try status(of: capture.all().last!), 7)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
