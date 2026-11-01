import XCTest
@testable import OpenPushCore

final class OpenPushCoreTests: XCTestCase {
    func testConfigurationLeadsWithTheAppAndDefaultsTheHost() {
        let configuration = OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public")

        XCTAssertEqual(configuration.serverURL, "https://app.openpush.ai",
                       "the host a developer should not have to think about is the defaulted one")
        XCTAssertEqual(configuration.appID, "sample")
        XCTAssertEqual(configuration.sdkKey, "sdk_public")
        XCTAssertEqual(configuration.tokenKey, "openpush.deviceToken")
    }

    func testTrailingSlashesAreStillTrimmedFromAnExplicitHost() {
        XCTAssertEqual(OpenPushConfiguration(appID: "a", sdkKey: "k",
                                             serverURL: "https://push.example/").serverURL,
                       "https://push.example")
    }

    func testReceiptContract() throws {
        let body = OpenPushPayload.receiptBody(
            types: ["received", "confirmed"], messageID: "msg_1",
            token: "abc", appID: "openpush-sample")
        let events = try XCTUnwrap(body["events"] as? [[String: String]])
        XCTAssertEqual(events, [
            ["type": "received", "app": "openpush-sample",
             "message_id": "msg_1", "token": "abc"],
            ["type": "confirmed", "app": "openpush-sample",
             "message_id": "msg_1", "token": "abc"],
        ])
    }

    func testMessageIDAcceptsStringAndNumber() {
        XCTAssertEqual(OpenPushPayload.messageID(from: ["op_message_id": "msg_2"]), "msg_2")
        XCTAssertEqual(OpenPushPayload.messageID(from: ["op_message_id": 42]), "42")
        XCTAssertNil(OpenPushPayload.messageID(from: [:]))
    }

    func testActionButtonsAcceptAPNsArraysAndFCMStrings() throws {
        let rows: [[String: Any]] = [
            ["id": "save", "label": "Save", "icon": "bookmark", "system_icon": true],
            ["id": "", "label": "Broken"],
            ["id": "share", "label": "Share"],
        ]
        let apns = OpenPushPayload.actions(from: ["op_actions": rows])
        XCTAssertEqual(apns.map(\.id), ["save", "share"])
        XCTAssertEqual(apns.first?.icon, "bookmark")
        XCTAssertEqual(apns.first?.systemIcon, true)

        let data = try JSONSerialization.data(withJSONObject: rows)
        let fcm = OpenPushPayload.actions(from: [
            "op_actions": try XCTUnwrap(String(data: data, encoding: .utf8))
        ])
        XCTAssertEqual(fcm, apns)
        XCTAssertEqual(OpenPushPayload.actionCategory(from: [
            "op_action_category": "op_actions_1"
        ]), "op_actions_1")
    }
}
