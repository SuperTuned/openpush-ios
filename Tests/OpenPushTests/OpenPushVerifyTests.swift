import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushVerifyTests: OpenPushTestCase {
    /// Answers every `/verify` request with the next scripted reply and keeps
    /// the request; anything else (an app session ping) gets an empty 200.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [(Int, String)]
        private var requests: [URLRequest] = []

        init(_ replies: [(Int, String)]) { self.replies = replies }

        var transport: OpenPush.Transport {
            { [self] request, done in
                guard request.url?.path.contains("/verify") == true else {
                    done(200, "{}")
                    return
                }
                let reply: (Int, String) = lock.withLock {
                    requests.append(request)
                    return replies.count > 1 ? replies.removeFirst() : replies[0]
                }
                done(reply.0, reply.1)
            }
        }

        func verifyRequests() -> [URLRequest] { lock.withLock { requests } }
    }

    private static func pending(attempts: Int = 0, channel: String = "sms") -> String {
        #"{"id":"vf_123","to":"+1415•••0123","channel":"\#(channel)","status":"pending","#
            + #""attempts":\#(attempts),"expires_at":"2026-10-23T12:10:00.123456+00:00"}"#
    }

    private func start(_ server: Server) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: server.transport)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func verifyError(_ work: () async throws -> OpenPushVerification) async
        -> OpenPushVerifyError? {
        do {
            _ = try await work()
            XCTFail("expected an OpenPushVerifyError")
            return nil
        } catch {
            return error as? OpenPushVerifyError
        }
    }

    // MARK: - start

    func testStartPostsTheNormalisedNumberChannelAndLocale() async throws {
        let server = Server([(200, Self.pending())])
        start(server)

        _ = try await OpenPush.Verify.start("00 41 555 501-23456", channel: .sms, locale: "en")

        let request = try XCTUnwrap(server.verifyRequests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://push.example/v1/apps/sample/verify")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        let body = try body(request)
        XCTAssertEqual(body["to"] as? String, "+4155550123456")
        XCTAssertEqual(body["channel"] as? String, "sms")
        XCTAssertEqual(body["locale"] as? String, "en")
    }

    func testStartDefaultsToTheAutoChannelAndOmitsTheLocale() async throws {
        let server = Server([(200, Self.pending())])
        start(server)

        _ = try await OpenPush.Verify.start("+14155550123")

        let body = try body(try XCTUnwrap(server.verifyRequests().first))
        XCTAssertEqual(body["channel"] as? String, "auto")
        XCTAssertNil(body["locale"])
    }

    func testStartDecodesTheVerification() async throws {
        let server = Server([(200, Self.pending(attempts: 0, channel: "whatsapp"))])
        start(server)

        let verification = try await OpenPush.Verify.start("+14155550123")

        XCTAssertEqual(verification.id, "vf_123")
        XCTAssertEqual(verification.maskedNumber, "+1415•••0123")
        XCTAssertEqual(verification.channel, .whatsapp,
                       "the channel the server chose, not the auto that was asked for")
        XCTAssertEqual(verification.status, .pending)
        XCTAssertEqual(verification.attempts, 0)
        XCTAssertEqual(verification.expiresAt,
                       ISO8601DateFormatter().date(from: "2026-10-23T12:10:00Z"))
        XCTAssertEqual(verification.phoneNumber, "+14155550123",
                       "the full number is kept in memory for check and resend")
    }

    func testAnInvalidNumberThrowsWithoutARequest() async {
        let server = Server([(200, Self.pending())])
        start(server)

        let error = await verifyError { try await OpenPush.Verify.start("+0123456789") }

        XCTAssertEqual(error?.code, .invalidNumber)
        XCTAssertTrue(server.verifyRequests().isEmpty)
    }

    // MARK: - check and resend

    func testCheckSendsTheFullNumberAndCodeToTheVerificationsCheckPath() async throws {
        let approved = #"{"id":"vf_123","to":"+1415•••0123","channel":"sms","status":"approved","attempts":1,"expires_at":"2026-10-23T12:10:00Z"}"#
        let server = Server([(200, Self.pending()), (200, approved)])
        start(server)
        let verification = try await OpenPush.Verify.start("+14155550123")

        let checked = try await OpenPush.Verify.check(verification, code: " 482913 ")

        let request = try XCTUnwrap(server.verifyRequests().last)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/verify/vf_123/check")
        let body = try body(request)
        XCTAssertEqual(body["to"] as? String, "+14155550123")
        XCTAssertEqual(body["code"] as? String, "482913")
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(checked.status, .approved)
        XCTAssertEqual(checked.attempts, 1)
        XCTAssertEqual(checked.phoneNumber, "+14155550123")
    }

    func testEveryStatusDecodes() {
        let cases: [(String, OpenPushVerification.Status)] = [
            ("pending", .pending), ("approved", .approved),
            ("expired", .expired), ("max_attempts", .maxAttempts),
        ]
        for (wire, status) in cases {
            let decoded = OpenPushVerification.decode(
                #"{"id":"vf_1","to":"+1•••3","status":"\#(wire)","attempts":5}"#,
                phoneNumber: "+14155550123", requestedChannel: .call)
            XCTAssertEqual(decoded?.status, status, wire)
            XCTAssertEqual(decoded?.channel, .call, "no channel in the body keeps the request's")
            XCTAssertNil(decoded?.expiresAt)
        }
        XCTAssertNil(OpenPushVerification.decode(
            #"{"id":"vf_1","status":"approved_later"}"#,
            phoneNumber: "+14155550123", requestedChannel: .sms),
            "an unknown status is unreadable, not a guess")
        XCTAssertNil(OpenPushVerification.decode(
            "<html>captive portal</html>", phoneNumber: "+14155550123",
            requestedChannel: .sms))
    }

    func testExpiryReadsEpochSecondsAndISOTextWithoutFractions() {
        XCTAssertEqual(OpenPushTimestamp.date(from: 1_800_000_000),
                       Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(OpenPushTimestamp.date(from: "2026-10-23T12:10:00Z"),
                       ISO8601DateFormatter().date(from: "2026-10-23T12:10:00Z"))
        XCTAssertNil(OpenPushTimestamp.date(from: "tomorrow"))
        XCTAssertNil(OpenPushTimestamp.date(from: nil))
    }

    func testResendPostsTheNumberAndNewChannel() async throws {
        let server = Server([(200, Self.pending()), (200, Self.pending(channel: "call"))])
        start(server)
        let verification = try await OpenPush.Verify.start("+14155550123")

        let resent = try await OpenPush.Verify.resend(verification, channel: .call)

        let request = try XCTUnwrap(server.verifyRequests().last)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/verify/vf_123/resend")
        let body = try body(request)
        XCTAssertEqual(body["to"] as? String, "+14155550123")
        XCTAssertEqual(body["channel"] as? String, "call")
        XCTAssertEqual(resent.channel, .call)
    }

    func testAVerificationIdCannotChangeThePath() {
        XCTAssertEqual(VerifyRequest.pathComponent("vf_abc"), "vf_abc")
        XCTAssertEqual(VerifyRequest.pathComponent("../x?y"), "..%2Fx%3Fy")
    }

    // MARK: - Errors

    func testRateLimitedMapsFromA429() async {
        let server = Server([(429, #"{"detail":{"code":"rate_limited","message":"Too many codes for this number."}}"#)])
        start(server)

        let error = await verifyError { try await OpenPush.Verify.start("+14155550123") }

        XCTAssertEqual(error, OpenPushVerifyError(code: .rateLimited,
                                                  message: "Too many codes for this number."))
    }

    func testTooSoonMapsFromA429OnResend() async throws {
        let server = Server([(200, Self.pending()),
                             (429, #"{"detail":{"code":"too_soon","message":"Wait 30 seconds."}}"#)])
        start(server)
        let verification = try await OpenPush.Verify.start("+14155550123")

        let error = await verifyError {
            try await OpenPush.Verify.resend(verification, channel: .sms)
        }

        XCTAssertEqual(error?.code, .tooSoon)
        XCTAssertEqual(error?.message, "Wait 30 seconds.")
    }

    func testNotPendingMapsFromA409OnCheck() async throws {
        let server = Server([(200, Self.pending()),
                             (409, #"{"detail":{"code":"not_pending","message":"Already approved."}}"#)])
        start(server)
        let verification = try await OpenPush.Verify.start("+14155550123")

        let error = await verifyError { try await OpenPush.Verify.check(verification, code: "1") }

        XCTAssertEqual(error?.code, .notPending)
    }

    func testATransportFailureIsANetworkError() async {
        let server = Server([(-1, "The Internet connection appears to be offline.")])
        start(server)

        let error = await verifyError { try await OpenPush.Verify.start("+14155550123") }

        XCTAssertEqual(error?.code, .network)
        XCTAssertEqual(error?.message, "The Internet connection appears to be offline.")
    }

    func testErrorMappingCoversEveryShapeTheServerSends() {
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 400, body: #"{"detail":{"code":"provider","message":"The provider failed."}}"#).code,
                       .provider)
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 400, body: #"{"detail":{"code":"refused","message":"Channel off."}}"#).code,
                       .refused)
        XCTAssertEqual(OpenPushVerifyError.from(status: 400, body: #"{"detail":"bad number"}"#),
                       OpenPushVerifyError(code: .refused, message: "bad number"),
                       "a plain string detail is a refusal carrying the server's words")
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 422, body: #"{"detail":[{"msg":"field required"}]}"#).message,
                       "field required")
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 404, body: #"{"detail":{"code":"gone_fishing","message":"?"}}"#).code,
                       .refused, "an unknown code from a newer server is still a refusal")
        XCTAssertEqual(OpenPushVerifyError.from(status: 429, body: "").code, .rateLimited,
                       "a bare 429 is still a rate limit")
        XCTAssertEqual(OpenPushVerifyError.from(status: 503, body: "upstream").code, .network)
        XCTAssertEqual(OpenPushVerifyError.from(status: 0, body: "").code, .network)
    }

    func testOptOutCreditAndRateRefusalsMapToTheirOwnCodes() {
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 409, body: #"{"detail":{"code":"opted_out","message":"Replied STOP."}}"#),
                       OpenPushVerifyError(code: .optedOut, message: "Replied STOP."))
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 402, body: #"{"detail":{"code":"credit","message":"No text credit."}}"#).code,
                       .noCredit)
        XCTAssertEqual(OpenPushVerifyError.from(
            status: 409, body: #"{"detail":{"code":"no_rate","message":"Not priced."}}"#).code,
                       .noRate)
        XCTAssertEqual(OpenPushVerifyError.from(status: 409, body: "").code, .refused,
                       "a 409 without a code is a refusal, not notPending")
        XCTAssertEqual(OpenPushVerifyError.from(status: 402, body: "").code, .refused)
    }

    func testAnUnreadableSuccessIsANetworkError() async {
        let server = Server([(200, "<html>captive portal</html>")])
        start(server)

        let error = await verifyError { try await OpenPush.Verify.start("+14155550123") }

        XCTAssertEqual(error?.code, .network)
    }

    func testBeforeInitializeTheCallIsRefused() async {
        let error = await verifyError { try await OpenPush.Verify.start("+14155550123") }
        XCTAssertEqual(error?.code, .refused)
    }
}
