import Foundation

/// The human-readable form of a scan: one line per finding, grouped by kind.
public struct ScanReport {
    public let projectName: String
    public let findings: [SetupFinding]

    public init(projectName: String, findings: [SetupFinding]) {
        self.projectName = projectName
        self.findings = findings
    }

    public var text: String {
        guard !findings.isEmpty else { return "\(projectName): no existing push plumbing found." }
        var lines = ["\(projectName): \(findings.count) item\(findings.count == 1 ? "" : "s") found."]
        for kind in SetupFinding.Kind.allCases {
            let matching = findings.filter { $0.kind == kind }
            guard !matching.isEmpty else { continue }
            lines.append("")
            lines.append(kind.rawValue)
            for finding in matching {
                var line = "  \(finding.id)"
                if let target = finding.target, target != finding.id { line += "  [\(target)]" }
                line += "  \(finding.source)"
                if let vendor = finding.vendor { line += "  (vendor: \(vendor))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
