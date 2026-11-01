import Foundation

/// The assignments an `.xcconfig` makes, in file order with its includes
/// spliced in where they appear.
///
/// Only unconditional assignments are kept: `KEY[sdk=…] = …` depends on the
/// destination being built, which a scan does not have. `#include?` is the
/// optional include Xcode skips silently when the file is missing.
enum XCConfigFile {
    static func settings(at url: URL, depth: Int = 0) -> [String: String] {
        var settings: [String: String] = [:]
        apply(url, into: &settings, depth: depth)
        return settings
    }

    private static func apply(_ url: URL, into settings: inout [String: String], depth: Int) {
        guard depth < 16, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include") {
                guard let path = quoted(line) else { continue }
                apply(url.deletingLastPathComponent().appendingPathComponent(path),
                      into: &settings, depth: depth + 1)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains("["),
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            settings[key] = ResolvedBuildSettings.inheriting(value, from: settings[key])
        }
    }

    /// `//` starts a comment anywhere on an xcconfig line, which is how Xcode
    /// reads it too (a URL in a value needs `/$()/` to survive).
    private static func stripComment(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[..<range.lowerBound])
    }

    private static func quoted(_ line: String) -> String? {
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[1]) : nil
    }
}
