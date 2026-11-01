import XCTest
@testable import OpenPush

final class OpenPushNotificationTypesTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
    }

    private func seam(_ snapshot: OpenPush.AuthorizationSnapshot,
                      request: @escaping @Sendable (Bool) -> Bool = { _ in false })
        -> OpenPush.PermissionSeam {
        OpenPush.PermissionSeam(
            status: { done in done(snapshot.status) },
            request: { provisional, done in done(request(provisional)) },
            openSettings: {},
            registerForRemoteNotifications: {},
            settings: { done in done(snapshot) })
    }

    private func status(_ snapshot: OpenPush.AuthorizationSnapshot) throws -> Int {
        let capture = Capture()
        OpenPush.permissionSeam = seam(snapshot)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")
        let data = try XCTUnwrap(capture.last()?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["status"] as? Int)
    }

    func testTheFullAuthorizationMaskIsReportedVerbatim() throws {
        let snapshot = OpenPush.AuthorizationSnapshot(
            status: .granted, badge: true, sound: true, alert: true,
            carPlay: true, critical: true, appSettings: true,
            announcement: true, timeSensitive: true)
        XCTAssertEqual(try status(snapshot), 447)
    }

    func testProvisionalAuthorizationSetsBitSixtyFourAndStaysTargetable() throws {
        let value = try status(OpenPush.AuthorizationSnapshot(
            status: .provisional, badge: true, sound: true, alert: true))
        XCTAssertEqual(value, 71)
        XCTAssertEqual(value & 64, 64)
        XCTAssertGreaterThan(value, 0)
    }

    func testDeniedAndNeverPromptedStatesUseTheirExactCodes() throws {
        XCTAssertEqual(try status(OpenPush.AuthorizationSnapshot(status: .denied)), 0)
        OpenPush.state.resetAsIfTheProcessJustStarted()
        XCTAssertEqual(try status(OpenPush.AuthorizationSnapshot(status: .notDetermined)), -18)
    }

    func testAuthorizedWithEverySurfaceOffStillReportsSubscribed() throws {
        XCTAssertEqual(try status(OpenPush.AuthorizationSnapshot(status: .granted)), 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
