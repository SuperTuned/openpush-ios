import Foundation

public struct OpenPushConfiguration: Sendable, Equatable {
    public static let defaultServerURL = "https://app.openpush.ai"

    public let serverURL: String
    public let appID: String
    public let sdkKey: String
    public let platform: String
    public let tokenKey: String
    /// The App Group both the app and its extensions belong to, when the host
    /// configured one. It is what lets a Notification Service Extension read the
    /// app id, server, SDK key, APNs token and subscription id — none of which it
    /// can reach through the app's own UserDefaults or Info.plist.
    public let appGroup: String?

    /// Derived keys retained for hosts that isolate OpenPush defaults by token key.
    /// The SDK stores these values inside the existing session payload.
    public var optedOutKey: String { tokenKey + ".optedOut" }
    public var promptedKey: String { tokenKey + ".permissionPrompted" }

    // ---------------------------------------------------------------- bundled config
    /// The Info.plist keys OpenPush reads, named here so the SDK, the docs and the
    /// tests cannot drift apart.
    public static let sdkKeyInfoKey = "OpenPushSDKKey"
    public static let appIDInfoKey = "OpenPushAppID"
    /// The Info.plist boolean that keeps the SDK from opening tapped launch URLs,
    /// read once at `initialize`: true turns `OpenPush.Notifications.openLaunchURLs`
    /// off.
    public static let suppressLaunchURLsInfoKey = "OpenPushSuppressLaunchURLs"

    /// The bundled SDK key, or nil when the host did not set one.
    ///
    /// The key is not a secret: the server calls it ingest-only and documents that
    /// it ships inside public binaries by design, and the webpush-config route
    /// serves it unauthenticated already.  Reading it from the app bundle changes
    /// nothing about who can see it — it moves here so `initialize` can take the
    /// same arguments the SDK a host is migrating from does.
    ///
    /// `lookup` exists so a negative case can be written at all: Bundle's
    /// info-dictionary read cannot be stubbed, and a resolver testable only against
    /// the test bundle's own plist has no way to assert the absent path.
    public static func bundledSDKKey(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) -> String? {
        nonEmptyString(lookup(sdkKeyInfoKey))
    }

    /// The bundled app id, for hosts that would rather not repeat it in code.
    public static func bundledAppID(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) -> String? {
        nonEmptyString(lookup(appIDInfoKey))
    }

    /// A non-String plist value is absent, never stringified: a number under the key
    /// would otherwise become a syntactically valid, permanently rejected credential
    /// sent on every request.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(appID: String, sdkKey: String,
                serverURL: String = OpenPushConfiguration.defaultServerURL,
                platform: String = "ios",
                tokenKey: String = "openpush.deviceToken",
                appGroup: String? = nil) {
        self.serverURL = serverURL.trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        self.appID = appID
        self.sdkKey = sdkKey
        self.platform = platform
        self.tokenKey = tokenKey
        self.appGroup = appGroup.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

public enum OpenPushPayload {
    public struct Action: Sendable, Equatable {
        public let id: String
        public let label: String
        public let icon: String
        public let systemIcon: Bool
        /// The link this button opens, when the composer gave it one (the action's
        /// `url` in `op_actions`). A tap on the button reports it as the click
        /// event's `actionURL`, and opens it in place of the push's `deep_link`
        /// when launch-URL opening is on.
        public let url: URL?

        public init(id: String, label: String, icon: String = "", systemIcon: Bool = false,
                    url: URL? = nil) {
            self.id = id
            self.label = label
            self.icon = icon
            self.systemIcon = systemIcon
            self.url = url
        }
    }

    public static func messageID(from userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo["op_message_id"] as? String, !value.isEmpty {
            return value
        }
        return (userInfo["op_message_id"] as? NSNumber)?.stringValue
    }

    /// Action buttons configured in the OpenPush composer, in display order.
    public static func actions(from userInfo: [AnyHashable: Any]) -> [Action] {
        var value: Any? = userInfo["op_actions"]
        if let text = value as? String, let data = text.data(using: .utf8) {
            do { value = try JSONSerialization.jsonObject(with: data) }
            catch {
                NSLog("OpenPush: notification actions ignored — op_actions is not valid JSON: %@",
                      error.localizedDescription)
                return []
            }
        }
        guard let rows = value as? [[String: Any]] else {
            if value != nil { NSLog("OpenPush: notification actions ignored — op_actions has no rows") }
            return []
        }
        let valid: [Action] = rows.compactMap { row -> Action? in
            guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, !label.isEmpty else { return nil }
            let link = (row["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Action(id: id, label: label,
                          icon: (row["icon"] as? String) ?? "",
                          systemIcon: (row["system_icon"] as? Bool) ?? false,
                          url: link.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        }
        if !rows.isEmpty && valid.isEmpty {
            NSLog("OpenPush: notification actions ignored — every rendered id or label is empty")
        }
        return Array(valid.prefix(3))
    }

    /// The wire key of an incremental badge: a positive integer, sent as a string,
    /// that the Notification Service Extension adds to the stored badge count.
    public static let badgeIncrementKey = "op_badge_increment"

    /// The increment an `op_badge_increment` push asks for, or nil when the key is
    /// absent or is not a positive integer.
    public static func badgeIncrement(from userInfo: [AnyHashable: Any]) -> Int? {
        let value: Int?
        switch userInfo[badgeIncrementKey] {
        case let text as String:
            value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case let number as NSNumber where number.doubleValue == Double(number.intValue):
            value = number.intValue
        default:
            value = nil
        }
        guard let value, value > 0 else { return nil }
        return value
    }

    public static func actionCategory(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["op_action_category"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func receiptBody(types: [String], messageID: String,
                                   token: String, appID: String,
                                   surface: String? = nil) -> [String: Any] {
        ["events": types.map { type in
            var event: [String: Any] = ["type": type, "app": appID,
                                        "message_id": messageID, "token": token]
            if let surface { event["surface"] = surface }
            return event
        }]
    }

    /// The same body for receipts that are about different messages. The wire
    /// contract is unchanged — `events` is already a list, and each member
    /// carries the same keys the single-message form writes — so this is how a
    /// queued backlog goes out in a few requests instead of one per receipt.
    public static func receiptBody(receipts: [(type: String, messageID: String)],
                                   token: String, appID: String) -> [String: Any] {
        ["events": receipts.map { receipt in
            ["type": receipt.type, "app": appID,
             "message_id": receipt.messageID, "token": token]
        }]
    }

    /// Body for one foreground tick sent to `/v1/apps/{app}/sessions`.
    public static func appSessionBody(token: String) -> [String: Any] {
        ["token": token]
    }

    /// Body for one idempotent foreground-duration report.
    public static func appSessionDurationBody(token: String, seconds: TimeInterval,
                                              idempotencyKey: String) -> [String: Any] {
        ["token": token, "duration_seconds": seconds,
         "idempotency_key": idempotencyKey]
    }
}
