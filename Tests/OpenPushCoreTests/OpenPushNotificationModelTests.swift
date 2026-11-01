import XCTest
import OpenPushCore

final class OpenPushNotificationModelTests: XCTestCase {
    private let userInfo: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Order shipped", "subtitle": "Arrives Friday", "body": "Track it now"],
                "sound": "default", "badge": 3, "category": "op_actions_ab12",
                "thread-id": "orders", "interruption-level": "time-sensitive",
                "relevance-score": 0.8, "mutable-content": 1, "content-available": 1],
        "op_message_id": "msg_1", "op_app": "sample",
        "op_action_category": "op_actions_ab12",
        "op_actions": [["id": "track", "label": "Track"]],
        "title": "Order shipped", "body": "Track it now",
        "image_url": "https://cdn.example/ship.jpg", "deep_link": "app://orders/42",
        "order": ["id": 42, "items": ["a", "b"], "gift": true], "promo": NSNull(),
    ]

    func testEveryWireFieldIsModelled() throws {
        let n = OpenPushNotification(userInfo: userInfo)
        XCTAssertEqual(n.messageId, "msg_1")
        XCTAssertEqual(n.title, "Order shipped")
        XCTAssertEqual(n.subtitle, "Arrives Friday")
        XCTAssertEqual(n.body, "Track it now")
        XCTAssertEqual(n.launchURL, URL(string: "app://orders/42"))
        XCTAssertEqual(n.imageURL, URL(string: "https://cdn.example/ship.jpg"))
        XCTAssertEqual(n.badge, 3)
        XCTAssertEqual(n.sound, "default")
        XCTAssertEqual(n.category, "op_actions_ab12")
        XCTAssertEqual(n.threadId, "orders")
        XCTAssertEqual(n.interruptionLevel, "time-sensitive")
        XCTAssertEqual(n.relevanceScore, 0.8)
        XCTAssertTrue(n.contentAvailable)
        XCTAssertTrue(n.mutableContent)
        XCTAssertEqual(n.actions.map(\.id), ["track"])
        XCTAssertTrue(n.isOpenPush)
    }

    func testAdditionalDataKeepsNestedJSONAndExcludesReservedKeys() {
        let n = OpenPushNotification(userInfo: userInfo)
        XCTAssertEqual(Set(n.additionalData.keys), ["order", "promo"])
        XCTAssertEqual(n.additionalData["order"]?["id"]?.numberValue, 42)
        XCTAssertEqual(n.additionalData["order"]?["items"]?.arrayValue?.compactMap(\.stringValue), ["a", "b"])
        XCTAssertEqual(n.additionalData["order"]?["gift"]?.boolValue, true, "a JSON boolean stays a boolean")
        XCTAssertEqual(n.additionalData["promo"], .null)
    }

    func testRawPayloadIsLossless() {
        let n = OpenPushNotification(userInfo: userInfo)
        XCTAssertEqual(n.rawPayload["aps"]?["alert"]?["title"]?.stringValue, "Order shipped")
        XCTAssertEqual(n.rawPayload["op_actions"]?.arrayValue?.first?["label"]?.stringValue, "Track")
    }

    func testAForeignNotificationIsNotOpenPush() {
        let n = OpenPushNotification(userInfo: ["aps": ["alert": "hi"], "k": "v"])
        XCTAssertFalse(n.isOpenPush)
        XCTAssertEqual(n.body, "hi", "a string alert is the body")
        XCTAssertEqual(n.additionalData["k"]?.stringValue, "v")
    }

    func testJSONValueRoundTripsThroughCodable() throws {
        let value = OpenPushJSONValue(["a": [1, 2.5, true, "x", NSNull()]] as [String: Any])!
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(OpenPushJSONValue.self, from: data), value)
    }

    // MARK: - Badge increment

    func testABadgeIncrementIsReadFromItsStringWireForm() {
        let n = OpenPushNotification(userInfo: ["op_message_id": "m", "op_badge_increment": "3"])
        XCTAssertEqual(n.badgeIncrement, 3)
        XCTAssertNil(n.badge, "an increment push carries no aps.badge")
        XCTAssertNil(n.additionalData["op_badge_increment"], "op_ keys are reserved")
    }

    func testABadgeIncrementThatIsNotAPositiveIntegerIsIgnored() {
        for value: Any in ["0", "-2", "two", "", 1.5 as Double, NSNull()] {
            XCTAssertNil(OpenPushPayload.badgeIncrement(from: ["op_badge_increment": value]),
                         "\(value) is not an increment")
        }
        XCTAssertEqual(OpenPushPayload.badgeIncrement(from: ["op_badge_increment": 2]), 2,
                       "a numeric value is accepted as well")
        XCTAssertNil(OpenPushNotification(userInfo: userInfo).badgeIncrement)
    }

    // MARK: - A link per action button

    func testAnActionButtonCarriesItsOwnURL() {
        let actions = OpenPushPayload.actions(from: ["op_actions": [
            ["id": "shop", "label": "Shop", "url": " https://example.com/shop "],
            ["id": "later", "label": "Later"],
            ["id": "blank", "label": "Blank", "url": ""],
        ]])
        XCTAssertEqual(actions.map(\.url), [URL(string: "https://example.com/shop"), nil, nil])
    }

    func testTheJSONStringFormCarriesTheURLToo() {
        let json = #"[{"id":"play","label":"Play","url":"myapp://play/7"}]"#
        let actions = OpenPushPayload.actions(from: ["op_actions": json])
        XCTAssertEqual(actions.first?.url, URL(string: "myapp://play/7"))
        XCTAssertEqual(actions.first, OpenPushPayload.Action(id: "play", label: "Play",
                                                             url: URL(string: "myapp://play/7")))
    }

    func testAnActionWithoutAURLIsUnchanged() {
        XCTAssertEqual(OpenPushPayload.Action(id: "a", label: "A").url, nil)
        XCTAssertEqual(OpenPushNotification(userInfo: userInfo).actions,
                       [OpenPushPayload.Action(id: "track", label: "Track")])
    }
}
