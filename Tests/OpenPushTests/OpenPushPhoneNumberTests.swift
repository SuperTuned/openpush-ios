import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushPhoneNumberTests: OpenPushTestCase {
    /// Every subscription request a number write made, in order. Requests for
    /// other paths (an app session ping) are not phone writes and are skipped.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func phoneBodies() -> [[String: Any]] {
            lock.withLock { requests }.compactMap { request in
                guard request.url?.path.hasSuffix("/subscriptions") == true,
                      let data = request.httpBody,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      ["sms", "whatsapp"].contains(body["platform"] as? String ?? "")
                else { return nil }
                return body
            }
        }
        func phoneRequests() -> [URLRequest] {
            lock.withLock { requests }.filter { request in
                guard let data = request.httpBody,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return false }
                return ["sms", "whatsapp"].contains(body["platform"] as? String ?? "")
            }
        }
    }

    /// A status code per phone request; the last one repeats.
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

    private let clock = ManualClock()
    private let logs = LogCapture()

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = clock.seam
        let logs = self.logs
        OpenPush.onLog = { logs.add($0) }
    }

    private func start(_ capture: Capture, codes: Codes = Codes([200]),
                       response: String = #"{"id":"sub_sms_1","status":0,"status_name":"Not verified","created":true}"#) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                let isPhone = request.httpBody.flatMap {
                                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                                }.map { ["sms", "whatsapp"].contains($0["platform"] as? String ?? "") }
                                if isPhone == true {
                                    done(codes.next(), response)
                                } else {
                                    done(200, "{}")
                                }
                            })
    }

    // MARK: - Normalisation

    /// The cases are the server's `normalise_e164`, so the two cannot disagree.
    func testNormalisationStripsSeparatorsAndReadsALeadingDoubleZeroAsPlus() throws {
        let accepted: [(String, String)] = [
            ("  +14155550123\n", "+14155550123"),
            ("+1 (415) 555-0123", "+14155550123"),
            ("+1-415-555-0123", "+14155550123"),
            ("+1.415.555.0123", "+14155550123"),
            ("0014155550123", "+14155550123"),
            ("00 1 415 555 0123", "+14155550123"),
            ("tel: +1 415 555 0123", "+14155550123"),
            ("004915112345678", "+4915112345678"),
            ("+12345678", "+12345678"),
            ("+123456789012345", "+123456789012345"),
        ]
        for (raw, expected) in accepted {
            XCTAssertEqual(try OpenPushPhoneNumber.normalized(raw), expected, raw)
        }
    }

    func testNormalisationRefusesWhatTheServerRefuses() {
        let refused = [
            "", "   ", "415", "4155550123", "(415) 555-0123",  // no + or 00
            "+1234567", "+1234567890123456",                  // 7 and 16 digits
            "++14155550123", "+1415+5550123",                 // a second +
            "+0123456789", "000123456789",                    // country code starting 0
            "+١٤١٥٥٥٥٠١٢٣",                                    // not ASCII digits
        ]
        for raw in refused {
            XCTAssertThrowsError(try OpenPushPhoneNumber.normalized(raw), raw) { error in
                let verifyError = error as? OpenPushVerifyError
                XCTAssertEqual(verifyError?.code, .invalidNumber, raw)
                XCTAssertFalse(verifyError?.message.contains("5550123") ?? true,
                               "the refusal does not repeat the number: \(raw)")
            }
        }
    }

    // MARK: - Results

    func testEveryCallReturnsTrueWhenTheWriteIsQueued() {
        start(Capture())

        XCTAssertTrue(OpenPush.User.addSms("+1 (415) 555-0123"))
        XCTAssertTrue(OpenPush.User.removeSms("+14155550123"))
        XCTAssertTrue(OpenPush.User.addWhatsApp("0014155550124"))
        XCTAssertTrue(OpenPush.User.removeWhatsApp("+14155550124"))
    }

    func testEveryCallReturnsFalseForAnInvalidNumber() {
        let capture = Capture()
        start(capture)

        XCTAssertFalse(OpenPush.User.addSms("415"))
        XCTAssertFalse(OpenPush.User.removeSms("+0123456789"))
        XCTAssertFalse(OpenPush.User.addWhatsApp("++14155550123"))
        XCTAssertFalse(OpenPush.User.removeWhatsApp(""))
        XCTAssertTrue(capture.phoneBodies().isEmpty)
    }

    func testEveryCallReturnsFalseBeforeInitialize() {
        XCTAssertFalse(OpenPush.User.addSms("+14155550123"))
        XCTAssertFalse(OpenPush.User.removeSms("+14155550123"))
        XCTAssertFalse(OpenPush.User.addWhatsApp("+14155550123"))
        XCTAssertFalse(OpenPush.User.removeWhatsApp("+14155550123"))
        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty)
        XCTAssertFalse(logs.all().contains { $0.contains("+14155550123") },
                       "logs never carry the full number")
    }

    // MARK: - Request bodies

    func testAddSmsPostsTheNumberOnTheSubscriptionsEndpointWithoutAStatus() throws {
        let capture = Capture()
        start(capture)

        OpenPush.User.addSms(" 00 1 (415) 555-0123 ")

        let request = try XCTUnwrap(capture.phoneRequests().first)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/subscriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        let body = try XCTUnwrap(capture.phoneBodies().first)
        XCTAssertEqual(body["token"] as? String, "+14155550123")
        XCTAssertEqual(body["platform"] as? String, "sms")
        XCTAssertNil(body["status"], "a device never sends a positive status for a number")
        XCTAssertNil(body["external_id"], "an anonymous install asserts no user")
    }

    func testAddWhatsAppUsesTheWhatsAppPlatformAndTheLoggedInUser() throws {
        let capture = Capture()
        start(capture)
        OpenPush.login(externalId: "player-9")

        OpenPush.User.addWhatsApp("+447700900123")

        let body = try XCTUnwrap(capture.phoneBodies().first)
        XCTAssertEqual(body["token"] as? String, "+447700900123")
        XCTAssertEqual(body["platform"] as? String, "whatsapp")
        XCTAssertEqual(body["external_id"] as? String, "player-9")
        XCTAssertNil(body["status"])
    }

    func testRemoveSmsSendsTheOptOutStatus() throws {
        let capture = Capture()
        start(capture)

        OpenPush.User.removeSms("+14155550123")

        let body = try XCTUnwrap(capture.phoneBodies().first)
        XCTAssertEqual(body["token"] as? String, "+14155550123")
        XCTAssertEqual(body["platform"] as? String, "sms")
        XCTAssertEqual(body["status"] as? Int, -2)
    }

    func testRemoveWhatsAppSendsTheOptOutStatusOnWhatsApp() throws {
        let capture = Capture()
        start(capture)

        OpenPush.User.removeWhatsApp("+14155550123")

        let body = try XCTUnwrap(capture.phoneBodies().first)
        XCTAssertEqual(body["platform"] as? String, "whatsapp")
        XCTAssertEqual(body["status"] as? Int, -2)
    }

    func testAnInvalidNumberIsRefusedLocallyAndNothingIsSent() {
        let capture = Capture()
        start(capture)

        OpenPush.User.addSms("415 555 0123")
        OpenPush.User.removeWhatsApp("12")

        XCTAssertTrue(capture.phoneBodies().isEmpty)
        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty)
        XCTAssertTrue(logs.all().contains { $0.contains("SMS number not added") },
                      "the refusal is logged: \(logs.all())")
        XCTAssertTrue(logs.all().contains { $0.contains("WhatsApp number not removed") })
    }

    // MARK: - Subscription ids

    func testTheSubscriptionIdIsKeptPerChannelAndNumberAndForgottenOnRemove() {
        let capture = Capture()
        start(capture)

        OpenPush.User.addSms("+14155550123")
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .sms, address: "+14155550123"), "sub_sms_1")
        XCTAssertNil(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .whatsapp, address: "+14155550123"))

        OpenPush.User.removeSms("+14155550123")
        XCTAssertNil(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .sms, address: "+14155550123"))
    }

    func testStoredIdsAndPendingWritesSurviveARelaunch() {
        let capture = Capture()
        start(capture, codes: Codes([200, 503]))
        OpenPush.User.addSms("+14155550123")
        OpenPush.User.removeWhatsApp("+14155550124")
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.pendingWrites.count, 1)

        OpenPush.AddressSubscriptions.shared.resetForTests()

        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .sms, address: "+14155550123"), "sub_sms_1")
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.pendingWrites.map(\.address),
                       ["+14155550124"])
    }

    // MARK: - Queue and retry

    func testAServerFailureIsRetriedOnTheRegistrationSchedule() {
        let capture = Capture()
        start(capture, codes: Codes([503, 200]))

        OpenPush.User.addSms("+14155550123")

        XCTAssertEqual(capture.phoneBodies().count, 1)
        XCTAssertEqual(clock.pendingDelays(), [2])
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.pendingWrites.count, 1)

        clock.fire(2)

        XCTAssertEqual(capture.phoneBodies().count, 2)
        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty)
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .sms, address: "+14155550123"), "sub_sms_1")
    }

    func testASpentScheduleHoldsTheWriteForTheNextWrite() {
        let capture = Capture()
        start(capture, codes: Codes([503, 503, 503, 200]))

        OpenPush.User.addSms("+14155550123")
        clock.fire(2)
        clock.fire(8)

        XCTAssertEqual(capture.phoneBodies().count, 3)
        XCTAssertTrue(clock.pendingDelays().isEmpty, "no timer after the table is spent")
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.pendingWrites.count, 1,
                       "the write is held, not dropped")

        OpenPush.User.addWhatsApp("+14155550124")

        XCTAssertEqual(capture.phoneBodies().map { $0["platform"] as? String },
                       ["sms", "sms", "sms", "sms", "whatsapp"],
                       "the held write goes first, in order")
        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty)
    }

    func testAClientRefusalDropsTheWriteAndTheNextOneStillGoes() {
        let capture = Capture()
        start(capture, codes: Codes([422, 200]))

        OpenPush.User.addSms("+14155550123")

        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty,
                      "a refused number cannot wedge the queue")
        XCTAssertTrue(clock.pendingDelays().isEmpty)

        OpenPush.User.addSms("+14155550124")
        XCTAssertEqual(capture.phoneBodies().count, 2)
    }

    func testALaterWriteForTheSameNumberReplacesOneStillWaiting() {
        let capture = Capture()
        start(capture, codes: Codes([503, 200]))

        OpenPush.User.addSms("+14155550123")
        OpenPush.User.removeSms("+14155550123")

        let bodies = capture.phoneBodies()
        XCTAssertEqual(bodies.count, 2, "the failed add is not sent again")
        XCTAssertEqual(bodies.last?["status"] as? Int, -2,
                       "the remove replaced the waiting add and went at once")
        XCTAssertTrue(clock.pendingDelays().isEmpty, "the add's armed retry was cancelled")
        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty)
    }

    func testAnAcceptedRegistrationSendsAHeldWrite() {
        let capture = Capture()
        start(capture, codes: Codes([503, 503, 503, 200]))
        OpenPush.User.addSms("+14155550123")
        clock.fire(2)
        clock.fire(8)
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.pendingWrites.count, 1)

        OpenPush.AddressSubscriptions.shared.registrationCompleted()

        XCTAssertTrue(OpenPush.AddressSubscriptions.shared.pendingWrites.isEmpty)
    }

    func testARefusedIdentityHashIsLoggedAsStoredWithoutTheUser() {
        let capture = Capture()
        start(capture, response: #"{"id":"sub_sms_1","status":0,"identity_rejected":true}"#)

        OpenPush.User.addSms("+14155550123")

        XCTAssertTrue(logs.all().contains {
            $0.hasPrefix("✗") && $0.contains("stored without a user")
                && $0.contains("identity hash was refused")
        }, "\(logs.all())")
        XCTAssertFalse(logs.all().contains { $0.contains("added — not verified") },
                       "\(logs.all())")
    }

    func testBeforeInitializeTheWriteIsDroppedWithALogLine() {
        OpenPush.User.addSms("+14155550123")
        XCTAssertTrue(logs.all().contains { $0.contains("initialize OpenPush first") })
        XCTAssertFalse(logs.all().contains { $0.contains("+14155550123") },
                       "logs never carry the full number")
    }

    func testTheAuthHashRidesWithTheUserWhoAddedTheNumber() throws {
        let capture = Capture()
        start(capture)
        OpenPush.login(externalId: "player-9", authHash: "hash-9")

        OpenPush.User.addSms("+14155550123")

        let body = try XCTUnwrap(capture.phoneBodies().first)
        XCTAssertEqual(body["external_id"] as? String, "player-9")
        XCTAssertEqual(body["external_id_auth_hash"] as? String, "hash-9")
    }
}
