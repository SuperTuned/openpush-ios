import Foundation

/// One family of generic signals. A detector reads the project model and
/// reports what it found; it never sets `vendor` — fingerprints do that after.
public protocol ProjectSignalDetector: Sendable {
    func findings(in project: ScannedProject) -> [SetupFinding]
}

extension ProjectSignalDetector {
    /// Merges per-configuration sightings of one value into one finding per
    /// (kind, id, target, source), listing the configurations it appears in.
    func merged(_ sightings: [(finding: SetupFinding, configuration: String)]) -> [SetupFinding] {
        var order: [String] = []
        var merged: [String: SetupFinding] = [:]
        for (finding, configuration) in sightings {
            let key = [finding.kind.rawValue, finding.id, finding.target ?? "", finding.source]
                .joined(separator: "\u{1F}")
            if merged[key] == nil { order.append(key); merged[key] = finding }
            var configurations = merged[key]?.details["configurations"]?.strings ?? []
            if !configurations.contains(configuration) { configurations.append(configuration) }
            merged[key]?.details["configurations"] = .strings(configurations)
        }
        return order.compactMap { merged[$0] }
    }
}
