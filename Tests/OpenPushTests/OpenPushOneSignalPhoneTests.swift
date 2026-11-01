import XCTest
@testable import OpenPush
import OpenPushCore
import OpenPushOneSignal

/// `addSms` and `removeSms` are forwarded, not refused. As with the
/// other facade tests, what is asserted is that the facade's spelling produces
/// the same wire body as the `OpenPush.` call it forwards to.
final class OpenPushOneSignalPhoneTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        func add(_ request: URLRequest) {
            guard let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["platform"] as? String == "sms" else { return }
            lock.withLock { bodies.append(body) }
        }
        func all() -> [[String: Any]] { lock.withLock { bodies } }
    }

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = ManualClock().seam
    }

    private func start(_ capture: Capture) {
        OneSignal.initialize(appId: "sample", sdkKey: "sdk_public",
                             serverURL: "https://push.example",
                             transport: { request, done in
                                 capture.add(request)
                                 done(200, #"{"id":"sub_sms_1","status":0}"#)
                             })
    }

    func testAddSmsForwardsToOpenPush() throws {
        let capture = Capture()
        start(capture)

        OneSignal.User.addSms("+14155550123")

        let body = try XCTUnwrap(capture.all().first)
        XCTAssertEqual(body["token"] as? String, "+14155550123")
        XCTAssertEqual(body["platform"] as? String, "sms")
        XCTAssertNil(body["status"])
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .sms, address: "+14155550123"), "sub_sms_1")
    }

    func testRemoveSmsForwardsToOpenPush() throws {
        let capture = Capture()
        start(capture)

        OneSignal.User.removeSms("+14155550123")

        let body = try XCTUnwrap(capture.all().first)
        XCTAssertEqual(body["status"] as? Int, -2)
    }
}
