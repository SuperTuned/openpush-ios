import Foundation

/// The developer's answers, as the answer file's `choices` object stores them.
///
/// Only the four choices iOS setup asks about are modelled. Every other key in
/// `choices`, and every unknown field inside a modelled one, is kept: a choice
/// is written by merging its fields into what was there.
public struct SetupChoices: Equatable, Sendable {
    public enum GroupMode: String, Sendable { case reuse, new }
    public enum KeychainMode: String, Sendable { case reuse, new, none }
    public enum ServiceExtensionMode: String, Sendable, CaseIterable {
        case takeOver = "take_over", share, inject, off
    }
    public enum WidgetMode: String, Sendable, CaseIterable { case reuse, new, off }

    public struct AppGroup: Equatable, Sendable {
        public var mode: GroupMode
        public var value: String
    }

    public struct KeychainGroup: Equatable, Sendable {
        public var mode: KeychainMode
        public var value: String?
    }

    public struct ServiceExtension: Equatable, Sendable {
        public var mode: ServiceExtensionMode
        /// The existing target for take_over and share, the created one for inject.
        public var target: String?
        public var bundleID: String?
        public var profile: ProvisioningProfiles?
    }

    public struct WidgetExtension: Equatable, Sendable {
        public var mode: WidgetMode
        public var target: String?
        public var bundleID: String?
        public var profile: ProvisioningProfiles?
    }

    public var appGroup: AppGroup?
    public var keychainGroup: KeychainGroup?
    public var serviceExtension: ServiceExtension?
    public var widgetExtension: WidgetExtension?

    public init(appGroup: AppGroup? = nil, keychainGroup: KeychainGroup? = nil,
                serviceExtension: ServiceExtension? = nil, widgetExtension: WidgetExtension? = nil) {
        self.appGroup = appGroup
        self.keychainGroup = keychainGroup
        self.serviceExtension = serviceExtension
        self.widgetExtension = widgetExtension
    }

    // MARK: - Answer file

    public init(answers: SetupAnswerFile) {
        let choices = answers.document["choices"] as? [String: Any] ?? [:]
        func object(_ key: String) -> [String: Any]? { choices[key] as? [String: Any] }
        func string(_ object: [String: Any], _ key: String) -> String? { object[key] as? String }

        if let group = object("app_group"), let mode = string(group, "mode").flatMap(GroupMode.init),
           let value = string(group, "value") {
            appGroup = AppGroup(mode: mode, value: value)
        }
        if let keychain = object("keychain_group"),
           let mode = string(keychain, "mode").flatMap(KeychainMode.init) {
            keychainGroup = KeychainGroup(mode: mode, value: string(keychain, "value"))
        }
        if let service = object("service_extension"),
           let mode = string(service, "mode").flatMap(ServiceExtensionMode.init) {
            serviceExtension = ServiceExtension(mode: mode, target: string(service, "target"),
                                                bundleID: string(service, "bundle_id"),
                                                profile: string(service, "profile").map(ProvisioningProfiles.init))
        }
        if let widget = object("widget_extension"),
           let mode = string(widget, "mode").flatMap(WidgetMode.init) {
            widgetExtension = WidgetExtension(mode: mode, target: string(widget, "target"),
                                              bundleID: string(widget, "bundle_id"),
                                              profile: string(widget, "profile").map(ProvisioningProfiles.init))
        }
    }

    /// Writes these choices into the answer file, field by field.
    public func store(in answers: inout SetupAnswerFile) {
        var fields: [String: [String: Any]] = [:]
        if let appGroup { fields["app_group"] = ["mode": appGroup.mode.rawValue, "value": appGroup.value] }
        if let keychainGroup {
            fields["keychain_group"] = ["mode": keychainGroup.mode.rawValue,
                                        "value": keychainGroup.value as Any? ?? NSNull()]
        }
        if let serviceExtension {
            fields["service_extension"] = [
                "mode": serviceExtension.mode.rawValue,
                "target": serviceExtension.target as Any? ?? NSNull(),
                "bundle_id": serviceExtension.bundleID as Any? ?? NSNull(),
                "profile": serviceExtension.profile?.description as Any? ?? NSNull(),
            ]
        }
        if let widgetExtension {
            fields["widget_extension"] = [
                "mode": widgetExtension.mode.rawValue,
                "target": widgetExtension.target as Any? ?? NSNull(),
                "bundle_id": widgetExtension.bundleID as Any? ?? NSNull(),
                "profile": widgetExtension.profile?.description as Any? ?? NSNull(),
            ]
        }
        answers.mergeChoices(fields)
    }
}

/// A provisioning profile name for every configuration, or one per
/// configuration: `"Example NSE"` or `"Debug=Example Dev,Release=Example Store"`.
public struct ProvisioningProfiles: Equatable, Sendable, CustomStringConvertible {
    public let all: String?
    public let byConfiguration: [String: String]

    public init(_ text: String) {
        let pairs = text.split(separator: ",").map { $0.split(separator: "=", maxSplits: 1) }
        if !pairs.isEmpty, pairs.allSatisfy({ $0.count == 2 }) {
            all = nil
            byConfiguration = Dictionary(pairs.map {
                (String($0[0]).trimmingCharacters(in: .whitespaces),
                 String($0[1]).trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { _, last in last })
        } else {
            all = text
            byConfiguration = [:]
        }
    }

    public func profile(for configuration: String) -> String? { byConfiguration[configuration] ?? all }

    public var description: String {
        all ?? byConfiguration.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}
