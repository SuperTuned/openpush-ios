import Foundation

/// The setup answer file, `.openpush/setup.json` beside the `.xcodeproj`.
///
/// The rules from the shared contract: `found` is always regenerated, `choices`
/// is changed only by an explicit answer, and every field this tool does not
/// know is kept on rewrite. The document is therefore held as raw JSON and only
/// the keys the caller names are replaced.
public struct SetupAnswerFile {
    public static let schema = "openpush-setup/1"
    public static let platform = "ios"
    public static let folder = ".openpush"
    public static let relativePath = ".openpush/setup.json"

    public private(set) var document: [String: Any]

    public init(document: [String: Any] = [:]) {
        self.document = document
        self.document["schema"] = Self.schema
        if self.document["platform"] == nil { self.document["platform"] = Self.platform }
    }

    public static func load(from url: URL) throws -> SetupAnswerFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return SetupAnswerFile() }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let document = object as? [String: Any] else {
            throw SetupError.invalidAnswerFile(url.path)
        }
        return SetupAnswerFile(document: document)
    }

    /// Replaces `found` wholesale; nothing else in the document changes.
    public mutating func replaceFound(_ findings: [SetupFinding]) throws {
        let data = try JSONEncoder().encode(findings)
        document["found"] = try JSONSerialization.jsonObject(with: data)
    }

    /// Merges each named choice's fields into the stored one, keeping any
    /// field — and any other choice — this tool does not know.
    public mutating func mergeChoices(_ fields: [String: [String: Any]]) {
        var choices = document["choices"] as? [String: Any] ?? [:]
        for (key, values) in fields {
            var existing = choices[key] as? [String: Any] ?? [:]
            existing.merge(values) { _, new in new }
            choices[key] = existing
        }
        document["choices"] = choices
    }

    public func data() throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data().write(to: url, options: .atomic)
    }
}
