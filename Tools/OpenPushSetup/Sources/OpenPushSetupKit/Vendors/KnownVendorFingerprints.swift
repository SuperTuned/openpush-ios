import Foundation

// The vendor-fingerprint surface. Every vendor name and string the setup tool
// matches on lives in this file and nowhere else.

public enum KnownVendorFingerprints {
    /// Only fingerprints of known public releases are listed.
    public static let all: [any VendorFingerprint] = [OneSignalFingerprint()]
}

/// OneSignal's iOS SDK, as a project that uses it is laid out.
public struct OneSignalFingerprint: VendorFingerprint {
    public let vendor = "onesignal"

    static let extensionModule = "OneSignalExtension"
    static let extensionCall = "OneSignalExtension.didReceiveNotificationExtensionRequest"
    static let appGroupInfoKey = "OneSignal_app_groups_key"
    static let packageURL = "github.com/onesignal/onesignal-ios-sdk"
    static let podPrefix = "OneSignal"

    public init() {}

    public func claims(_ finding: SetupFinding, in project: ScannedProject) -> Bool {
        switch finding.kind {
        case .serviceExtension: return isTemplateExtension(finding, in: project)
        case .appGroup: return isVendorGroup(finding.id, in: project)
        case .pushSDK: return isVendorPackage(finding)
        default: return false
        }
    }

    /// The template's two markers together: the module import and the call
    /// that hands the request to the SDK. Either alone may be a studio's own
    /// extension that happens to use the module.
    private func isTemplateExtension(_ finding: SetupFinding, in project: ScannedProject) -> Bool {
        guard finding.details["imports"]?.strings.contains(Self.extensionModule) == true else { return false }
        return finding.details["sources"]?.strings.contains { path in
            project.read(path)?.contains(Self.extensionCall) == true
        } == true
    }

    /// `group.<app bundle id>.onesignal` by default, or whatever an app's
    /// Info.plist names under the SDK's override key.
    private func isVendorGroup(_ group: String, in project: ScannedProject) -> Bool {
        project.apps.flatMap(\.configurations).contains { configuration in
            if let bundleID = configuration.bundleID, group == "group.\(bundleID).onesignal" { return true }
            return configuration.infoPlist[Self.appGroupInfoKey]?.stringValue == group
        }
    }

    public func isExtensionDependency(_ name: String) -> Bool {
        name == Self.extensionModule || name.hasPrefix(Self.podPrefix)
    }

    private func isVendorPackage(_ finding: SetupFinding) -> Bool {
        switch finding.details["manager"]?.stringValue {
        case "spm":
            let url = finding.details["url"]?.stringValue?.lowercased() ?? ""
            return url.contains(Self.packageURL)
        case "cocoapods", "framework":
            return finding.id.hasPrefix(Self.podPrefix)
        default:
            return false
        }
    }
}
