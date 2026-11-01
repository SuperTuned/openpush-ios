import Foundation

/// The entitlements each target signs with, per configuration and with
/// `$(VAR)` expanded: App Groups, Keychain access groups and `aps-environment`.
public struct EntitlementsDetector: ProjectSignalDetector {
    public init() {}

    public func findings(in project: ScannedProject) -> [SetupFinding] {
        var sightings: [(finding: SetupFinding, configuration: String)] = []
        for target in project.targets where target.role != .other {
            for configuration in target.configurations {
                guard let source = configuration.entitlementsPath else { continue }
                let entitlements = configuration.entitlements
                func add(_ kind: SetupFinding.Kind, _ id: String) {
                    let details: [String: JSONValue] = [
                        "target": .string(target.name),
                        "target_role": .string(target.role.rawValue),
                    ]
                    sightings.append((SetupFinding(kind: kind, id: id, source: source, details: details),
                                      configuration.name))
                }
                entitlements["com.apple.security.application-groups"]?.strings.forEach { add(.appGroup, $0) }
                entitlements["keychain-access-groups"]?.strings.forEach { add(.keychainGroup, $0) }
                if let environment = entitlements["aps-environment"]?.stringValue {
                    add(.apsEnvironment, environment)
                }
            }
        }
        return merged(sightings)
    }
}
