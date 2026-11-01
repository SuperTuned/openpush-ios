import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushReinitializeTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func count() -> Int { lock.withLock { requests.count } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private let clock = ManualClock()

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func start(_ capture: Capture, appID: String = "sample") {
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: appID, sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
    }

    func testInitializingAgainWithTheSameConfigurationKeepsLocalUserState() {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-1")
        OpenPush.User.addTags(["plan": "pro"])
        OpenPush.User.addAliases(["crm_id": "c-1"])
        OpenPush.PushSubscription.optOut()

        start(capture)

        XCTAssertEqual(OpenPush.User.externalId, "person-1")
        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro"])
        XCTAssertEqual(OpenPush.state.aliasMap, ["crm_id": "c-1"])
        XCTAssertTrue(OpenPush.state.isOptedOut)
        XCTAssertEqual(OpenPush.currentToken, "aabb")
    }

    func testInitializingWithADifferentAppIdIsStillAWorkspaceSwitch() {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-1")
        OpenPush.User.addTags(["plan": "pro"])

        start(capture, appID: "other-app")

        XCTAssertNil(OpenPush.User.externalId)
        XCTAssertEqual(OpenPush.User.getTags(), [:])
        XCTAssertFalse(OpenPush.state.isOptedOut)
    }

    func testARepeatedInitializeKeepsTheOpenWriteWindow() throws {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")
        // One flushed window first, so this subscription's status is already in sync
        // and the second `initialize` has no registration of its own to piggyback the
        // staged tags onto: the coalescing timer is the only thing that can send them.
        OpenPush.User.addTags(["plan": "pro"])
        clock.fire(0.3)

        OpenPush.User.addTags(["seats": "12"])
        XCTAssertEqual(clock.pendingDelays(), [0.3])

        start(capture)

        XCTAssertEqual(clock.pendingDelays(), [0.3],
                       "a repeated initialize must leave the coalescing timer armed")
        clock.fire(0.3)

        let json = try body(of: capture.last())
        XCTAssertEqual(json["tags"] as? [String: String], ["plan": "pro", "seats": "12"],
                       "the tags staged before the repeated initialize still flush")
    }

    func testARepeatedInitializeSaysSoInTheLog() {
        let capture = Capture()
        let log = LogCapture()
        start(capture)
        OpenPush.onLog = { log.add($0) }

        start(capture)

        XCTAssertTrue(log.joined().contains("already initialized"),
                      "a host that calls initialize twice must be told nothing was reset")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
