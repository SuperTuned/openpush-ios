import Foundation

/// One piece of existing push plumbing the scan found: an entry of the answer
/// file's `found` list (schema `openpush-setup/1`).
public struct SetupFinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case appGroup = "app_group"
        case keychainGroup = "keychain_group"
        case serviceExtension = "service_extension"
        case widgetExtension = "widget_extension"
        case contentExtension = "content_extension"
        case pushSDK = "push_sdk"
        /// The `aps-environment` entitlement: push is already enabled.
        case apsEnvironment = "aps_environment"
        /// `UIBackgroundModes` holding `remote-notification`.
        case backgroundMode = "background_mode"
    }

    public var kind: Kind
    public var id: String
    /// The file the signal was read from, relative to the project folder.
    public var source: String
    /// Set only by a known vendor fingerprint; nil for generic plumbing.
    public var vendor: String?
    /// Whether the setup tool may edit it in place. Podfile entries are not: the
    /// tool prints Podfile lines rather than rewriting a developer's Podfile.
    public var editable: Bool
    public var details: [String: JSONValue]

    public init(kind: Kind, id: String, source: String, vendor: String? = nil,
                editable: Bool = true, details: [String: JSONValue] = [:]) {
        self.kind = kind
        self.id = id
        self.source = source
        self.vendor = vendor
        self.editable = editable
        self.details = details
    }

    private enum CodingKeys: String, CodingKey { case kind, id, source, vendor, editable, details }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(String.self, forKey: .source)
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor)
        editable = try container.decodeIfPresent(Bool.self, forKey: .editable) ?? true
        details = try container.decodeIfPresent([String: JSONValue].self, forKey: .details) ?? [:]
    }

    /// `vendor` is always written, as null when no fingerprint claimed the item,
    /// so a reader never has to tell "absent" from "generic".
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        if let vendor { try container.encode(vendor, forKey: .vendor) }
        else { try container.encodeNil(forKey: .vendor) }
        try container.encode(editable, forKey: .editable)
        try container.encode(details, forKey: .details)
    }

    /// The target the signal belongs to, for findings that are per target.
    public var target: String? { details["target"]?.stringValue }
}
