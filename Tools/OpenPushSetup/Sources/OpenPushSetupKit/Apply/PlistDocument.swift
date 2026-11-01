import Foundation

/// An Info.plist or entitlements file being edited: read once, changed in
/// memory, written once (as XML) only if something changed.
final class PlistDocument {
    let url: URL
    private(set) var root: [String: Any]
    private(set) var changed = false

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            root = [:]
            return
        }
        // An existing file that cannot be read as a dictionary is never
        // replaced by an empty one: the step fails instead.
        guard let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw SetupError.unreadablePlist(url.path) }
        root = dictionary
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Adds `value` to the array at `key` unless an entry already resolves to
    /// it — `$(APP_GROUP)` counts as the group it expands to.
    @discardableResult
    func addToArray(_ key: String, _ value: String, expand: (String) -> String = { $0 }) -> Bool {
        var array = root[key] as? [Any] ?? []
        if array.contains(where: { ($0 as? String).map(expand) == value }) { return false }
        array.append(value)
        root[key] = array
        changed = true
        return true
    }

    /// Sets a string or boolean value, reporting whether anything changed.
    @discardableResult
    func set(_ key: String, _ value: Any) -> Bool {
        if let current = root[key] as? NSObject, let new = value as? NSObject, current.isEqual(new) { return false }
        root[key] = value
        changed = true
        return true
    }

    @discardableResult
    func setIfMissing(_ key: String, _ value: Any) -> Bool {
        guard root[key] == nil else { return false }
        return set(key, value)
    }

    func string(_ key: String) -> String? { root[key] as? String }

    /// Makes a new, possibly empty, file be written.
    func markChanged() { if !exists { changed = true } }

    func save(backup: BackupStore) throws {
        guard changed else { return }
        try backup.preserve(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        changed = false
    }
}
