import CryptoKit
import Foundation

/// Copies every file setup is about to change into its own folder for this
/// run, `.openpush/backup/<timestamp>/`, the first time it is touched, and can
/// put everything back.
///
/// A file in the project keeps its project-relative path there. A file outside
/// it goes under `external/<hash of its full path>/`, so two files with the same
/// name never overwrite each other's backup.
public final class BackupStore {
    public let root: URL
    private let folder: URL
    /// Original location → backup copy.
    private var preserved: [String: URL] = [:]
    /// Files that did not exist before this run.
    private var created: Set<String> = []

    public init(projectFolder: URL, timestamp: String) {
        folder = projectFolder.standardizedFileURL
        let base = folder.appendingPathComponent(".openpush/backup")
        var candidate = base.appendingPathComponent(timestamp)
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(timestamp)-\(attempt)")
            attempt += 1
        }
        root = candidate
    }

    /// Keeps the file's current contents before it changes. A file that does
    /// not exist yet is remembered as new, so a rollback removes it.
    public func preserve(_ url: URL) throws {
        let source = url.standardizedFileURL
        guard preserved[source.path] == nil, !created.contains(source.path) else { return }
        guard FileManager.default.fileExists(atPath: source.path) else {
            created.insert(source.path)
            return
        }
        let destination = root.appendingPathComponent(relativeName(of: source))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        preserved[source.path] = destination
    }

    /// Puts every preserved file back and removes the new ones. Best effort:
    /// one file that cannot be restored does not stop the others.
    public func rollback() {
        for (original, copy) in preserved {
            let target = URL(fileURLWithPath: original)
            guard (try? Data(contentsOf: target)) != (try? Data(contentsOf: copy)) else { continue }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: copy, to: target)
        }
        for path in created { try? FileManager.default.removeItem(atPath: path) }
    }

    public var isEmpty: Bool { preserved.isEmpty }

    private func relativeName(of source: URL) -> String {
        if source.path.hasPrefix(folder.path + "/") { return String(source.path.dropFirst(folder.path.count + 1)) }
        let digest = SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "external/\(digest.prefix(16))/\(source.lastPathComponent)"
    }
}
