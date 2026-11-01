import Foundation

/// Swift package pins, from any of the three `Package.resolved` versions.
struct PackageResolved {
    struct Pin: Equatable {
        let identity: String
        let location: String
        let version: String?
    }

    let pins: [Pin]

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Version 1 nests the pins under "object" and names fields differently.
        let entries = (root["pins"] as? [[String: Any]])
            ?? ((root["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        pins = entries.compactMap { entry in
            guard let location = (entry["location"] ?? entry["repositoryURL"]) as? String else { return nil }
            let identity = (entry["identity"] as? String) ?? Self.identity(of: location)
            let version = (entry["state"] as? [String: Any])?["version"] as? String
            return Pin(identity: identity, location: location, version: version)
        }
    }

    /// The identity SwiftPM derives from a URL: its last path component, lowercased, without `.git`.
    static func identity(of url: String) -> String {
        var name = url.split(separator: "/").last.map(String.init) ?? url
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.lowercased()
    }

    /// A package URL as compared: lowercased, without a trailing slash or `.git`.
    static func normalizedURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespaces).lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value
    }

    /// Where Xcode writes the file for a project, and for any workspace beside it.
    static func locations(for project: ScannedProject) -> [URL] {
        let suffix = "xcshareddata/swiftpm/Package.resolved"
        var urls = [project.projectURL.appendingPathComponent("project.xcworkspace/" + suffix)]
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: project.folder.path)) ?? []
        for workspace in siblings.sorted() where workspace.hasSuffix(".xcworkspace") {
            urls.append(project.folder.appendingPathComponent(workspace + "/" + suffix))
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
