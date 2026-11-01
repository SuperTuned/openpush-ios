import Foundation

/// A notification as it arrived, parsed once into the fields a host actually
/// reads. Everything is optional because APNs only guarantees the `aps` key:
/// a silent push has no alert, and a notification the host itself scheduled has
/// none of our keys at all (`isOpenPush` is then `false`).
///
/// `rawPayload` keeps every JSON-representable key of the `userInfo`, nesting
/// intact (non-string keys and non-JSON values are dropped; all numbers are
/// `Double`), so nothing is hidden by the fields this type happens to name.
public struct OpenPushNotification: Sendable, Equatable {
    public let messageId: String?
    public let title: String?
    public let subtitle: String?
    public let body: String?
    /// The `deep_link` the composer set, when it parses as a URL.
    public let launchURL: URL?
    /// The `image_url` the composer set, when it parses as a URL.
    public let imageURL: URL?
    public let badge: Int?
    /// The `op_badge_increment` this push carries: how much the Notification
    /// Service Extension adds to the stored badge count. nil for a push that sets
    /// an absolute `badge`, or none at all.
    public let badgeIncrement: Int?
    public let sound: String?
    public let category: String?
    public let threadId: String?
    public let interruptionLevel: String?
    public let relevanceScore: Double?
    public let contentAvailable: Bool
    public let mutableContent: Bool
    public let actions: [OpenPushPayload.Action]
    /// Every top-level key that is not `aps`, not one of the rendered fields,
    /// and not reserved by OpenPush — that is, the composer's own custom data.
    public let additionalData: [String: OpenPushJSONValue]
    /// The `userInfo`: every JSON-representable key, nesting intact (non-string
    /// keys and non-JSON values are dropped; all numbers are `Double`).
    public let rawPayload: [String: OpenPushJSONValue]

    /// `false` for a notification OpenPush did not send — a local notification
    /// the host scheduled, or another provider's push.
    public var isOpenPush: Bool { messageId != nil }

    /// Keys the rendered fields above already carry, so they do not repeat in
    /// `additionalData`. Anything prefixed `op_` is reserved too.
    private static let reservedKeys: Set<String> =
        ["aps", "title", "body", "image_url", "deep_link"]

    public init(userInfo: [AnyHashable: Any]) {
        let raw = OpenPushJSONValue(userInfo)?.objectValue ?? [:]
        rawPayload = raw

        let aps = Self.dictionary(userInfo["aps"])
        let alert = aps?["alert"]
        let alertFields = Self.dictionary(alert)
        let alertText = alert as? String

        title = alertFields?["title"] as? String ?? userInfo["title"] as? String
        subtitle = alertFields?["subtitle"] as? String
        body = alertFields?["body"] as? String ?? alertText ?? userInfo["body"] as? String

        launchURL = Self.url(userInfo["deep_link"])
        imageURL = Self.url(userInfo["image_url"])

        badge = (aps?["badge"] as? NSNumber)?.intValue
        badgeIncrement = OpenPushPayload.badgeIncrement(from: userInfo)
        sound = aps?["sound"] as? String
            ?? Self.dictionary(aps?["sound"])?["name"] as? String
        category = aps?["category"] as? String
        threadId = aps?["thread-id"] as? String
        interruptionLevel = aps?["interruption-level"] as? String
        relevanceScore = (aps?["relevance-score"] as? NSNumber)?.doubleValue
        contentAvailable = (aps?["content-available"] as? NSNumber)?.boolValue ?? false
        mutableContent = (aps?["mutable-content"] as? NSNumber)?.boolValue ?? false

        messageId = OpenPushPayload.messageID(from: userInfo)
        actions = OpenPushPayload.actions(from: userInfo)

        additionalData = raw.filter { key, _ in
            !Self.reservedKeys.contains(key) && !key.hasPrefix("op_")
        }
    }

    /// `userInfo` and its nested values arrive as Objective-C dictionaries, whose
    /// keys bridge to `AnyHashable` rather than `String`.
    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let map = value as? [String: Any] { return map }
        guard let map = value as? [AnyHashable: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, element) in map {
            guard let name = key as? String else { continue }
            out[name] = element
        }
        return out
    }

    private static func url(_ value: Any?) -> URL? {
        guard let text = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return URL(string: text)
    }
}
