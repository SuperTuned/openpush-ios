import Foundation

/// Runs every detector over a project, lets the fingerprints name what they
/// recognise, and returns the `found` list in a stable order.
public struct ProjectScanner {
    public let loader: any ProjectLoading
    public let detectors: [any ProjectSignalDetector]
    public let fingerprints: [any VendorFingerprint]

    public init(loader: any ProjectLoading = XcodeProjectLoader(),
                detectors: [any ProjectSignalDetector] = ProjectScanner.defaultDetectors,
                fingerprints: [any VendorFingerprint] = KnownVendorFingerprints.all) {
        self.loader = loader
        self.detectors = detectors
        self.fingerprints = fingerprints
    }

    public static let defaultDetectors: [any ProjectSignalDetector] = [
        ExtensionTargetDetector(),
        EntitlementsDetector(),
        BackgroundModesDetector(),
        DependencyDetector(),
    ]

    public func scan(_ projectURL: URL) throws -> [SetupFinding] {
        try scan(loader.load(projectURL))
    }

    public func scan(_ project: ScannedProject) -> [SetupFinding] {
        let kinds = SetupFinding.Kind.allCases
        return detectors.flatMap { $0.findings(in: project) }
            .map { finding in
                var named = finding
                named.vendor = fingerprints.first { $0.claims(finding, in: project) }?.vendor
                return named
            }
            .filter(isPushRelevant)
            .sorted { lhs, rhs in
                let left = kinds.firstIndex(of: lhs.kind) ?? 0, right = kinds.firstIndex(of: rhs.kind) ?? 0
                if left != right { return left < right }
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                if lhs.target != rhs.target { return (lhs.target ?? "") < (rhs.target ?? "") }
                return lhs.source < rhs.source
            }
    }

    /// A dependency is reported only when it touches push: a known vendor's,
    /// OpenPush's own, or one linked into a notification extension.
    private func isPushRelevant(_ finding: SetupFinding) -> Bool {
        guard finding.kind == .pushSDK else { return true }
        return finding.vendor != nil
            || finding.details["openpush"]?.boolValue == true
            || finding.details["in_extension"]?.boolValue == true
    }
}
