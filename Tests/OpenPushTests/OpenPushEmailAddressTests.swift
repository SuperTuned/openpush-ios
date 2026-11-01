import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushEmailAddressTests: OpenPushTestCase {
    /// Every email subscription request, in order. Other requests (an app
    /// session ping) are skipped.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func emailRequests() -> [URLRequest] {
            lock.withLock { requests }.filter { Self.body(of: $0)?["platform"] as? String == "email" }
        }
        func emailBodies() -> [[String: Any]] { emailRequests().compactMap(Self.body(of:)) }
        /// The platform of every subscription request, email or phone, in order.
        func platforms() -> [String] {
            lock.withLock { requests }.compactMap { Self.body(of: $0)?["platform"] as? String }
        }
        static func body(of request: URLRequest) -> [String: Any]? {
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    /// A status code per email request; the last one repeats.
    private final class Codes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int]
        init(_ values: [Int]) { self.values = values }
        func next() -> Int {
            lock.withLock { values.count > 1 ? values.removeFirst() : (values.first ?? 200) }
        }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func all() -> [String] { lock.withLock { lines } }
    }

    private static let subscribed =
        #"{"id":"sub_email_1","status":1,"status_name":"Subscribed","created":true}"#
    private static let suppressed =
        #"{"id":"sub_email_2","status":-2,"status_name":"Unsubscribed","created":true}"#

    private let clock = ManualClock()
    private let logs = LogCapture()

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = clock.seam
        let logs = self.logs
        OpenPush.onLog = { logs.add($0) }
    }

    private func start(_ capture: Capture, codes: Codes = Codes([200]),
                       response: String = subscribed) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                if Capture.body(of: request)?["platform"] as? String == "email" {
                                    let code = codes.next()
                                    done(code, code == 400
                                         ? #"{"detail":"Email is off for this app."}"# : response)
                                } else {
                                    done(200, "{}")
                                }
                            })
    }

    private var queue: OpenPush.AddressSubscriptions { .shared }

    // MARK: - Local check

    func testTheAddressIsTrimmedAndLowerCased() throws {
        XCTAssertEqual(try OpenPushEmailAddress.normalized("  Ana@Example.COM\n"), "ana@example.com")
        XCTAssertEqual(try OpenPushEmailAddress.normalized("a@b.c"), "a@b.c")
        let longest = String(repeating: "a", count: 254 - "@example.com".count) + "@example.com"
        XCTAssertEqual(try OpenPushEmailAddress.normalized(longest), longest)
    }

    func testAnythingElseIsRefusedAsInvalidEmail() {
        let tooLong = String(repeating: "a", count: 255 - "@example.com".count) + "@example.com"
        for raw in ["", "   ", "ana", "ana@", "@example.com", "ana@example", "ana@@example.com",
                    "ana@b@example.com", tooLong] {
            XCTAssertThrowsError(try OpenPushEmailAddress.normalized(raw), raw) { error in
                let refusal = error as? OpenPushVerifyError
                XCTAssertEqual(refusal?.code, .invalidEmail, raw)
                XCTAssertFalse(raw.count > 3 && (refusal?.message.contains(raw) ?? true),
                               "the refusal does not repeat the address: \(raw)")
            }
        }
    }

    func testAnInvalidAddressReturnsFalseAndNothingIsSent() {
        let capture = Capture()
        start(capture)

        XCTAssertFalse(OpenPush.User.addEmail("ana@example"))
        XCTAssertFalse(OpenPush.User.removeEmail("not an address"))

        XCTAssertTrue(capture.emailBodies().isEmpty)
        XCTAssertTrue(queue.pendingWrites.isEmpty)
        XCTAssertTrue(logs.all().contains { $0.contains("email address not added") },
                      "the refusal is logged: \(logs.all())")
        XCTAssertTrue(logs.all().contains { $0.contains("email address not removed") })
    }

    func testBeforeInitializeBothReturnFalseAndLogsNeverCarryTheAddress() {
        XCTAssertFalse(OpenPush.User.addEmail("ana@example.com"))
        XCTAssertFalse(OpenPush.User.removeEmail("ana@example.com"))
        XCTAssertTrue(queue.pendingWrites.isEmpty)
        XCTAssertTrue(logs.all().contains { $0.contains("initialize OpenPush first") })
        XCTAssertFalse(logs.all().contains { $0.contains("ana@") })
    }

    // MARK: - Request shape

    func testAddEmailPostsTheAddressOnTheSubscriptionsEndpoint() throws {
        let capture = Capture()
        start(capture)

        XCTAssertTrue(OpenPush.User.addEmail(" Ana@Example.com "))

        let request = try XCTUnwrap(capture.emailRequests().first)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/subscriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        let body = try XCTUnwrap(capture.emailBodies().first)
        XCTAssertEqual(body["token"] as? String, "ana@example.com")
        XCTAssertEqual(body["platform"] as? String, "email")
        XCTAssertNil(body["status"], "the server decides an added address's status")
        XCTAssertNil(body["external_id"], "an anonymous install asserts no user")
        XCTAssertEqual(queue.subscriptionID(channel: .email, address: "ana@example.com"),
                       "sub_email_1")
        XCTAssertTrue(logs.all().contains { $0.contains("✓ email address •••@example.com subscribed") },
                      "\(logs.all())")
        XCTAssertFalse(logs.all().contains { $0.contains("ana@") }, "logs show only the domain")
    }

    func testTheLoggedInUserAndAuthHashRideWithTheAddress() throws {
        let capture = Capture()
        start(capture)
        OpenPush.login(externalId: "player-9", authHash: "hash-9")

        OpenPush.User.addEmail("ana@example.com")

        let body = try XCTUnwrap(capture.emailBodies().first)
        XCTAssertEqual(body["external_id"] as? String, "player-9")
        XCTAssertEqual(body["external_id_auth_hash"] as? String, "hash-9")
    }

    func testRemoveEmailSendsStatusMinusTwoAndForgetsTheId() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addEmail("ana@example.com")

        XCTAssertTrue(OpenPush.User.removeEmail("ANA@example.com"))

        let body = try XCTUnwrap(capture.emailBodies().last)
        XCTAssertEqual(body["token"] as? String, "ana@example.com")
        XCTAssertEqual(body["platform"] as? String, "email")
        XCTAssertEqual(body["status"] as? Int, -2)
        XCTAssertNil(queue.subscriptionID(channel: .email, address: "ana@example.com"))
        XCTAssertTrue(logs.all().contains { $0.contains("✓ email address •••@example.com removed") })
    }

    // MARK: - Server answers

    func testASuppressedAddressIsReportedAndNotRetried() {
        let capture = Capture()
        start(capture, response: Self.suppressed)

        OpenPush.User.addEmail("gone@example.com")

        XCTAssertEqual(capture.emailBodies().count, 1)
        XCTAssertTrue(clock.pendingDelays().isEmpty)
        XCTAssertTrue(queue.pendingWrites.isEmpty)
        XCTAssertTrue(logs.all().contains { $0.contains("suppression list") }, "\(logs.all())")
        XCTAssertFalse(logs.all().contains { $0.contains("subscribed") && $0.hasPrefix("✓") })
    }

    func testARefusedIdentityHashIsLoggedAsStoredWithoutTheUser() {
        let capture = Capture()
        start(capture, response:
              #"{"id":"sub_email_3","status":1,"identity_rejected":"auth hash did not verify"}"#)
        OpenPush.login(externalId: "player-9", authHash: "stale")

        OpenPush.User.addEmail("ana@example.com")

        XCTAssertTrue(logs.all().contains {
            $0.contains("✗ email address •••@example.com stored without a user") &&
                $0.contains("auth hash did not verify")
        }, "\(logs.all())")
        XCTAssertFalse(logs.all().contains { $0.contains("✓ email address") }, "\(logs.all())")
        XCTAssertTrue(queue.pendingWrites.isEmpty, "the write was accepted, so it is not retried")
    }

    func testABadRequestIsLoggedInWordsAndNotRetried() {
        let capture = Capture()
        start(capture, codes: Codes([400, 200]))

        OpenPush.User.addEmail("ana@example.com")

        XCTAssertEqual(capture.emailBodies().count, 1)
        XCTAssertTrue(clock.pendingDelays().isEmpty)
        XCTAssertTrue(queue.pendingWrites.isEmpty, "a refusal cannot wedge the queue")
        XCTAssertTrue(logs.all().contains {
            $0.contains("refused (400)") && $0.contains("refused: Email is off for this app.")
        }, "\(logs.all())")

        OpenPush.User.addEmail("bo@example.com")
        XCTAssertEqual(capture.emailBodies().count, 2, "the next write still goes")
    }

    func testAServerFailureIsRetriedThenSucceeds() {
        let capture = Capture()
        start(capture, codes: Codes([503, 200]))

        OpenPush.User.addEmail("ana@example.com")

        XCTAssertEqual(capture.emailBodies().count, 1)
        XCTAssertEqual(clock.pendingDelays(), [2])
        XCTAssertEqual(queue.pendingWrites.map(\.key), ["email:ana@example.com"])

        clock.fire(2)

        XCTAssertEqual(capture.emailBodies().count, 2)
        XCTAssertTrue(queue.pendingWrites.isEmpty)
        XCTAssertEqual(queue.subscriptionID(channel: .email, address: "ana@example.com"),
                       "sub_email_1")
    }

    func testAHeldRemoveSurvivesARelaunchAndGoesOnTheNextRegistration() throws {
        let capture = Capture()
        start(capture, codes: Codes([503, 503, 503, 200]))
        OpenPush.User.removeEmail("ana@example.com")
        clock.fire(2)
        clock.fire(8)
        XCTAssertTrue(clock.pendingDelays().isEmpty, "no timer after the table is spent")

        queue.resetForTests()
        XCTAssertEqual(queue.pendingWrites.map(\.key), ["email:ana@example.com"],
                       "the store kept the held remove")

        queue.registrationCompleted()

        XCTAssertTrue(queue.pendingWrites.isEmpty)
        XCTAssertEqual(try XCTUnwrap(capture.emailBodies().last)["status"] as? Int, -2)
    }

    func testEmailAndPhoneWritesShareOneOrderedQueue() {
        let capture = Capture()
        start(capture, codes: Codes([503, 200]))

        OpenPush.User.addEmail("ana@example.com")
        XCTAssertEqual(queue.pendingWrites.map(\.key), ["email:ana@example.com"])

        OpenPush.User.addSms("+14155550123")

        XCTAssertEqual(capture.platforms().filter { $0 != "ios" },
                       ["email", "email", "sms"],
                       "the waiting email goes again first, then the number behind it")
        XCTAssertTrue(queue.pendingWrites.isEmpty)
        XCTAssertTrue(clock.pendingDelays().isEmpty)
    }
}
