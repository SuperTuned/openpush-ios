import Foundation

/// Signing for the targets setup touches.
///
/// A created target copies the app's team, style and identity per
/// configuration and takes the profile it is given. An existing target's
/// signing is never written: setup only reports what it kept.
enum SigningPolicy {
    /// The values setup must never overwrite on an existing target.
    static let protectedKeys = ["PROVISIONING_PROFILE_SPECIFIER", "PROVISIONING_PROFILE",
                                "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY"]
    static let copiedKeys = ["DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY"]

    /// Signing settings per configuration for a target created beside `app`.
    /// Under manual signing every configuration needs a profile; without one
    /// nothing is created, and the error names the option to pass.
    static func settings(copying app: ProjectTarget, profiles: ProvisioningProfiles?,
                         target: String, flag: String) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var unsigned: [String] = []
        for configuration in app.configurations {
            var settings: [String: String] = [:]
            for (key, raw) in configuration.settings.values
            where copiedKeys.contains(key) || key.hasPrefix("CODE_SIGN_IDENTITY[") {
                let value = configuration.settings.expand(raw)
                if !value.isEmpty { settings[key] = value }
            }
            if let profile = profiles?.profile(for: configuration.name) {
                settings["PROVISIONING_PROFILE_SPECIFIER"] = profile
            } else if settings["CODE_SIGN_STYLE"] == "Manual" {
                unsigned.append(configuration.name)
            }
            result[configuration.name] = settings
        }
        guard unsigned.isEmpty else {
            throw SetupError.manualSigningNeedsProfile(target: target, configurations: unsigned, flag: flag)
        }
        return result
    }

    /// One line per configuration with the signing values left in place.
    static func kept(on target: ProjectTarget) -> [String] {
        target.configurations.compactMap { configuration in
            let values = protectedKeys.compactMap { key -> String? in
                guard let value = configuration.settings[key], !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            return values.isEmpty ? nil : "\(target.name) (\(configuration.name)): \(values.joined(separator: ", "))"
        }
    }
}
