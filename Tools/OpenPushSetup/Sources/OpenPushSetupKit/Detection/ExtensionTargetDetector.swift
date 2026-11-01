import Foundation

/// App extensions classified by `NSExtensionPointIdentifier`: notification
/// service, notification content and WidgetKit. For each one, what a setup
/// needs to reuse or edit it: bundle id and signing per configuration, the
/// principal class and the file declaring it, sources, imports and embedding.
public struct ExtensionTargetDetector: ProjectSignalDetector {
    public init() {}

    public func findings(in project: ScannedProject) -> [SetupFinding] {
        project.targets.compactMap { target in
            guard let kind = Self.kind(for: target.role), let primary = target.primary else { return nil }
            var details: [String: JSONValue] = [
                "target": .string(target.name),
                "bundle_id": .optional(primary.bundleID),
                "info_plist": .optional(primary.infoPlistPath),
                "generated_info_plist": .bool(primary.generatesInfoPlist),
                "display_name": .optional(primary.infoPlist["CFBundleDisplayName"]?.stringValue),
                "deployment_target": .optional(primary.settings["IPHONEOS_DEPLOYMENT_TARGET"]),
                "embedded": .bool(!target.embeddedIn.isEmpty),
                "embedded_in": .strings(target.embeddedIn),
                "sources": .strings(target.sources),
                "imports": .strings(imports(of: target, project: project)),
                "packages": .strings(target.packageProducts.map(\.name)),
                "configurations": .object(Dictionary(uniqueKeysWithValues: target.configurations.map {
                    ($0.name, Self.signing($0))
                })),
            ]
            let principal = primary.infoPlist["NSExtension"]?["NSExtensionPrincipalClass"]?.stringValue
            details["principal_class"] = .optional(principal)
            details["principal_class_file"] = .optional(principal.flatMap { name in
                SourceInspector.file(declaring: Self.className(name), in: target.sources, read: project.read)
            })
            if kind == .contentExtension {
                details["categories"] = .strings(Self.categories(primary))
            }
            return SetupFinding(kind: kind, id: target.name,
                                source: primary.infoPlistPath ?? project.pbxprojPath,
                                details: details)
        }
    }

    static func kind(for role: ProjectTarget.Role) -> SetupFinding.Kind? {
        switch role {
        case .serviceExtension: return .serviceExtension
        case .contentExtension: return .contentExtension
        case .widgetExtension: return .widgetExtension
        default: return nil
        }
    }

    /// The signing values A4 must never overwrite on an existing target.
    static func signing(_ configuration: ProjectTarget.Configuration) -> JSONValue {
        let keys = [
            ("bundle_id", "PRODUCT_BUNDLE_IDENTIFIER"),
            ("entitlements", "CODE_SIGN_ENTITLEMENTS"),
            ("code_sign_style", "CODE_SIGN_STYLE"),
            ("development_team", "DEVELOPMENT_TEAM"),
            ("code_sign_identity", "CODE_SIGN_IDENTITY"),
            ("provisioning_profile_specifier", "PROVISIONING_PROFILE_SPECIFIER"),
            ("provisioning_profile", "PROVISIONING_PROFILE"),
        ]
        return .object(Dictionary(uniqueKeysWithValues: keys.map { name, setting in
            (name, JSONValue.optional(configuration.settings[setting].flatMap { $0.isEmpty ? nil : $0 }))
        }))
    }

    /// `Module.ClassName` names the class; the module is the target's own.
    static func className(_ principal: String) -> String {
        principal.split(separator: ".").last.map(String.init) ?? principal
    }

    private static func categories(_ configuration: ProjectTarget.Configuration) -> [String] {
        let value = configuration.infoPlist["NSExtension"]?["NSExtensionAttributes"]?["UNNotificationExtensionCategory"]
        if let single = value?.stringValue { return [single] }
        return value?.strings ?? []
    }

    private func imports(of target: ProjectTarget, project: ScannedProject) -> [String] {
        var modules: [String] = []
        for path in target.sources {
            for module in SourceInspector.imports(in: project.read(path) ?? "") where !modules.contains(module) {
                modules.append(module)
            }
        }
        return modules
    }
}
