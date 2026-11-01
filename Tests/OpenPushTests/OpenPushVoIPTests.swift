import XCTest
@testable import OpenPush
@testable import OpenPushVoIP
import OpenPushCore

/// The VoIP token's life on the server, driven without PushKit: the registrar is
/// what PushKit's delegate calls, so these tests call it the same way.
final class OpenPushVoIPTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var status = 200
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
        func setStatus(_ value: Int) { lock.withLock { status = value } }
        func currentStatus() -> Int { lock.withLock { status } }
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var pushes: [OpenPushVoIP.Push] = []
        private var completions = 0
        func add(_ push: OpenPushVoIP.Push) { lock.withLock { pushes.append(push) } }
        func all() -> [OpenPushVoIP.Push] { lock.withLock { pushes } }
        func complete() { lock.withLock { completions += 1 } }
        func completed() -> Int { lock.withLock { completions } }
    }

    private let capture = Capture()
    private let registrar = OpenPushVoIP.registrar

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        func all() -> [String] { lock.withLock { names } }
    }

    private let pushKitCalls = Calls()

    override func setUp() {
        super.setUp()
        OpenPushVoIP.registrar.resetForTests()
        let calls = pushKitCalls
        OpenPushVoIP.registrar.pushKit = .init(register: { calls.add("register") },
                                               unregister: { calls.add("unregister") })
    }

    override func tearDown() {
        OpenPushVoIP.registrar.resetForTests()
        OpenPushVoIP.registrar.pushKit = .system
        super.tearDown()
    }

    func testStartRegistersWithPushKitAndStopUnregisters() {
        OpenPushVoIP.start { _, completion in completion() }
        XCTAssertTrue(OpenPushVoIP.isStarted)
        OpenPushVoIP.stop()
        XCTAssertEqual(pushKitCalls.all(), ["register", "unregister"])
    }

    /// Registration answers with a subscription id; every VoIP call answers with
    /// whatever status the test set.
    private func initialize(subscriptionID: String = "sub_1") {
        let capture = capture
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                if request.url?.path.contains("/voip-tokens") == true {
                                    done(capture.currentStatus(), "{}")
                                } else {
                                    done(200, #"{"id":"\#(subscriptionID)"}"#)
                                }
                            })
    }

    private func voipRequests() -> [URLRequest] {
        capture.all().filter { $0.url?.path.contains("/voip-tokens") == true }
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let tokenData = Data([0xde, 0xad, 0xbe, 0xef])

    // MARK: - Registration

    func testTheTokenIsPostedWithTheSubscriptionIdOnceBothAreKnown() throws {
        initialize()
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)
        XCTAssertTrue(voipRequests().isEmpty, "no subscription id yet")

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        let request = try XCTUnwrap(voipRequests().first)
        XCTAssertEqual(voipRequests().count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://push.example/v1/apps/sample/voip-tokens")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        XCTAssertEqual(request.value(forHTTPHeaderField: OpenPushSDKVersion.headerField),
                       OpenPushSDKVersion.headerValue)
        let json = try body(request)
        XCTAssertEqual(json["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(json["token"] as? String, "deadbeef")
        XCTAssertEqual(json["sandbox"] as? Bool, false,
                       "the test host has no embedded profile, which reads as production")
        XCTAssertEqual(OpenPushVoIP.token, "deadbeef")
    }

    func testAKnownSubscriptionIsPostedAsSoonAsPushKitIssuesTheToken() throws {
        initialize()
        OpenPush.register(token: "aabb")
        OpenPushVoIP.start { _, completion in completion() }
        XCTAssertTrue(voipRequests().isEmpty, "no token yet")

        registrar.didUpdate(token: tokenData)

        XCTAssertEqual(try body(voipRequests().first)["subscription_id"] as? String, "sub_1")
    }

    func testAnUnchangedPairIsNotPostedAgainButARotatedTokenIs() throws {
        initialize()
        OpenPush.register(token: "aabb")
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)
        registrar.didUpdate(token: tokenData)
        registrar.sync()
        XCTAssertEqual(voipRequests().count, 1)

        registrar.didUpdate(token: Data([0x01, 0x02]))

        XCTAssertEqual(voipRequests().count, 2)
        XCTAssertEqual(try body(voipRequests().last)["token"] as? String, "0102")
    }

    func testANewSubscriptionIdIsPostedAgain() throws {
        initialize()
        OpenPush.register(token: "aabb")
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)

        OpenPush.state.setSubscriptionID("sub_2")
        OpenPush.notifySubscriptionObservers()

        waitForMainQueue()
        XCTAssertEqual(voipRequests().count, 2)
        XCTAssertEqual(try body(voipRequests().last)["subscription_id"] as? String, "sub_2")
    }

    func testAFailedPostIsTriedAgainOnTheNextSync() throws {
        initialize()
        OpenPush.register(token: "aabb")
        capture.setStatus(503)
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)
        XCTAssertNil(registrar.lastRegistration)

        capture.setStatus(200)
        registrar.sync()

        XCTAssertEqual(voipRequests().count, 2)
        XCTAssertEqual(registrar.lastRegistration?.token, "deadbeef")
    }

    func testNothingIsPostedBeforeStart() {
        initialize()
        OpenPush.register(token: "aabb")
        registrar.didUpdate(token: tokenData)

        XCTAssertTrue(voipRequests().isEmpty)
        XCTAssertFalse(OpenPushVoIP.isStarted)
    }

    // MARK: - Removal

    func testStopRemovesTheTokenFromTheServer() throws {
        initialize()
        OpenPush.register(token: "aabb")
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)

        OpenPushVoIP.stop()

        let request = try XCTUnwrap(voipRequests().last)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/voip-tokens/remove")
        let json = try body(request)
        XCTAssertEqual(json["subscription_id"] as? String, "sub_1")
        XCTAssertEqual(json["token"] as? String, "deadbeef")
        XCTAssertFalse(OpenPushVoIP.isStarted)

        OpenPush.state.setSubscriptionID("sub_2")
        OpenPush.notifySubscriptionObservers()
        XCTAssertEqual(voipRequests().count, 2, "after stop nothing is posted again")
    }

    func testStopRemovesAPairAnEarlierLaunchMayHaveRegistered() throws {
        initialize()
        OpenPush.register(token: "aabb")
        capture.setStatus(503)
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)
        capture.setStatus(200)

        OpenPushVoIP.stop()

        XCTAssertEqual(voipRequests().last?.url?.path, "/v1/apps/sample/voip-tokens/remove")
        XCTAssertEqual(try body(voipRequests().last)["token"] as? String, "deadbeef")
    }

    func testAnInvalidatedTokenIsRemoved() throws {
        initialize()
        OpenPush.register(token: "aabb")
        OpenPushVoIP.start { _, completion in completion() }
        registrar.didUpdate(token: tokenData)

        registrar.didInvalidateToken()

        XCTAssertEqual(voipRequests().last?.url?.path, "/v1/apps/sample/voip-tokens/remove")
        XCTAssertNil(OpenPushVoIP.token)
    }

    // MARK: - Incoming pushes

    func testAnIncomingPushReachesTheHandlerWithItsDataAndTheCompletion() throws {
        let received = Received()
        OpenPushVoIP.start { push, completion in
            received.add(push)
            completion()
        }

        registrar.didReceive(payload: [
            "aps": [:], "op_voip": "1", "op_message_id": "msg_9",
            "caller": "Ada", "call": ["id": "c1", "video": true],
        ]) { received.complete() }

        let push = try XCTUnwrap(received.all().first)
        XCTAssertEqual(push.messageId, "msg_9")
        XCTAssertTrue(push.isOpenPush)
        XCTAssertEqual(push.data["caller"], .string("Ada"))
        XCTAssertEqual(push.data["call"]?["video"], .bool(true))
        XCTAssertNil(push.data["aps"])
        XCTAssertNil(push.data["op_voip"], "op_ keys are OpenPush's own, not the sender's data")
        XCTAssertEqual(push.rawPayload["op_voip"], .string("1"))
        XCTAssertEqual(received.completed(), 1, "the app calls PushKit's completion")
    }

    func testWithoutAHandlerTheCompletionIsCalledAtOnce() {
        let received = Received()

        registrar.didReceive(payload: ["aps": [:], "op_voip": "1"]) { received.complete() }

        XCTAssertEqual(received.completed(), 1)
    }

    func testAPushOpenPushDidNotSendIsStillHandedOver() throws {
        let received = Received()
        OpenPushVoIP.start { push, completion in received.add(push); completion() }

        registrar.didReceive(payload: ["aps": [:], "caller": "Bob"]) {}

        let push = try XCTUnwrap(received.all().first)
        XCTAssertFalse(push.isOpenPush, "every VoIP push must reach CallKit, whoever sent it")
        XCTAssertEqual(push.data["caller"], .string("Bob"))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
