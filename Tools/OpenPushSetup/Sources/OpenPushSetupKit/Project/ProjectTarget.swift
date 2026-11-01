import Foundation

/// One native target as the scan sees it: its role, and per configuration the
/// resolved settings, Info.plist and entitlements.
public struct ProjectTarget: Sendable {
    public enum Role: String, Sendable {
        case app
        case serviceExtension = "service_extension"
        case contentExtension = "content_extension"
        case widgetExtension = "widget_extension"
        case otherExtension = "other_extension"
        case other
    }

    public struct Configuration: Sendable {
        public let name: String
        public let settings: ResolvedBuildSettings
        /// Project-relative, or nil when the target has no Info.plist file (a
        /// fully generated one).
        public let infoPlistPath: String?
        /// The file's keys, plus the `INFOPLIST_KEY_*` settings when the target
        /// generates its Info.plist. The file wins where both name a key.
        public let infoPlist: [String: JSONValue]
        public let entitlementsPath: String?
        public let entitlements: [String: JSONValue]

        public var bundleID: String? { settings["PRODUCT_BUNDLE_IDENTIFIER"] }
        public var generatesInfoPlist: Bool { settings.bool("GENERATE_INFOPLIST_FILE") }
    }

    public struct PackageProduct: Sendable, Equatable {
        public let name: String
        /// nil for a product of a local package.
        public let repositoryURL: String?
    }

    public let name: String
    public let productType: String?
    public let configurations: [Configuration]
    public let sources: [String]
    public let embeddedIn: [String]
    public let packageProducts: [PackageProduct]
    /// Frameworks and XCFrameworks from the project's own folders linked by
    /// the target's Frameworks phase — vendored SDKs, as a Unity export has.
    public let linkedFrameworks: [String]

    public static let applicationType = "com.apple.product-type.application"
    public static let extensionTypes: Set<String> = [
        "com.apple.product-type.app-extension",
        "com.apple.product-type.extensionkit-extension",
    ]

    /// The configuration that represents the target when one value is needed:
    /// Release when there is one, since that is what ships.
    public var primary: Configuration? {
        configurations.first { $0.name == "Release" } ?? configurations.first
    }

    public var extensionPoint: String? {
        primary?.infoPlist["NSExtension"]?["NSExtensionPointIdentifier"]?.stringValue
    }

    /// The framework of that name the target links, such as
    /// `Frameworks/OpenPushNative/OpenPush.xcframework` for `OpenPush`.
    public func linkedFramework(named name: String) -> String? {
        linkedFrameworks.first {
            let file = ($0 as NSString).lastPathComponent
            return file == "\(name).xcframework" || file == "\(name).framework"
        }
    }

    public var role: Role {
        if productType == Self.applicationType { return .app }
        guard let productType, Self.extensionTypes.contains(productType) else { return .other }
        switch extensionPoint {
        case "com.apple.usernotifications.service": return .serviceExtension
        case "com.apple.usernotifications.content-extension": return .contentExtension
        case "com.apple.widgetkit-extension": return .widgetExtension
        default: return .otherExtension
        }
    }
}
