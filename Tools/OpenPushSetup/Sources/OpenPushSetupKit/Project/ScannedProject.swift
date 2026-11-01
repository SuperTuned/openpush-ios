import Foundation

/// Everything the detectors read, loaded once: the targets, the remote package
/// references, and the folder the project lives in.
public struct ScannedProject: Sendable {
    public struct RemotePackage: Sendable, Equatable {
        public let url: String
        public let requirement: String?
    }

    public let projectURL: URL
    public let targets: [ProjectTarget]
    public let remotePackages: [RemotePackage]

    public init(projectURL: URL, targets: [ProjectTarget], remotePackages: [RemotePackage]) {
        self.projectURL = projectURL
        self.targets = targets
        self.remotePackages = remotePackages
    }

    /// The folder holding the `.xcodeproj`: `SRCROOT`, and where `.openpush/` lives.
    public var folder: URL { projectURL.deletingLastPathComponent() }

    public var pbxprojPath: String { relativePath(projectURL.appendingPathComponent("project.pbxproj")) }

    public var apps: [ProjectTarget] { targets.filter { $0.role == .app } }

    public func target(named name: String) -> ProjectTarget? { targets.first { $0.name == name } }

    public func relativePath(_ url: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    public func url(for relativePath: String) -> URL {
        relativePath.hasPrefix("/") ? URL(fileURLWithPath: relativePath)
            : folder.appendingPathComponent(relativePath)
    }

    public func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url(for: relativePath), encoding: .utf8)
    }
}
