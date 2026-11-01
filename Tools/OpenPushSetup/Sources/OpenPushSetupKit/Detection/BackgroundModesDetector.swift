import Foundation

/// `UIBackgroundModes` holding `remote-notification` in a target's Info.plist.
public struct BackgroundModesDetector: ProjectSignalDetector {
    public static let remoteNotification = "remote-notification"

    public init() {}

    public func findings(in project: ScannedProject) -> [SetupFinding] {
        var sightings: [(finding: SetupFinding, configuration: String)] = []
        for target in project.targets {
            for configuration in target.configurations {
                let modes = configuration.infoPlist["UIBackgroundModes"]?.strings ?? []
                guard modes.contains(Self.remoteNotification) else { continue }
                let finding = SetupFinding(
                    kind: .backgroundMode, id: Self.remoteNotification,
                    source: configuration.infoPlistPath ?? project.pbxprojPath,
                    details: ["target": .string(target.name), "modes": .strings(modes)])
                sightings.append((finding, configuration.name))
            }
        }
        return merged(sightings)
    }
}
