import XCTest
@testable import OpenPush
import OpenPushCore
import OpenPushOneSignal

/// `addEmail` and `removeEmail` are forwarded, not refused: the
/// facade's spelling produces the same wire body as the `OpenPush.` call.
final class OpenPushOneSignalEmailTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        func add(_ request: URLRequest) {
            guard let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["platform"] as? String == "email" else { return }
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
                                 done(200, #"{"id":"sub_email_1","status":1}"#)
                             })
    }

    func testAddEmailForwardsToOpenPush() throws {
        let capture = Capture()
        start(capture)

        OneSignal.User.addEmail("Ana@Example.com")

        let body = try XCTUnwrap(capture.all().first)
        XCTAssertEqual(body["token"] as? String, "ana@example.com")
        XCTAssertNil(body["status"])
        XCTAssertEqual(OpenPush.AddressSubscriptions.shared.subscriptionID(
            channel: .email, address: "ana@example.com"), "sub_email_1")
    }

    func testRemoveEmailForwardsToOpenPush() throws {
        let capture = Capture()
        start(capture)

        OneSignal.User.removeEmail("ana@example.com")

        XCTAssertEqual(try XCTUnwrap(capture.all().first)["status"] as? Int, -2)
    }

    /// The refusals file is what makes a member a compile error; email must not
    /// be in it any more, or a migrating host's call stops compiling.
    func testTheRefusalListNoLongerHasEmail() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenPushOneSignal/OneSignalUnavailable.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("func addEmail"))
        XCTAssertFalse(text.contains("func removeEmail"))
        XCTAssertFalse(text.lowercased().contains("no email channel"))
    }
}
