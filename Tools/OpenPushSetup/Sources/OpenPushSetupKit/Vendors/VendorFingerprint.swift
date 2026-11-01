import Foundation

/// A known push vendor's template, recognised in a finding. Detection is
/// generic; a fingerprint only adds a name (`vendor`) to what was found, so
/// setup can default to taking that vendor's extension over.
public protocol VendorFingerprint: Sendable {
    /// The value written to a finding's `vendor`.
    var vendor: String { get }
    func claims(_ finding: SetupFinding, in project: ScannedProject) -> Bool
    /// The vendor's own dependency in an extension it no longer runs: a Swift
    /// package product or a pod, removed (or listed for removal) on take-over.
    func isExtensionDependency(_ name: String) -> Bool
}
