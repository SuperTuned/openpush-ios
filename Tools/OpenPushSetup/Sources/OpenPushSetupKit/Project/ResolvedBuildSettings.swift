import Foundation

/// The build settings one target sees in one configuration, resolved the way
/// Xcode layers them, with `$(VAR)` expansion.
///
/// Layers, lowest first: the project's xcconfig, the project's settings, the
/// target's xcconfig, the target's settings. `$(inherited)` in a layer is the
/// value from the layers below it. A variable nothing defines — such as
/// `$(AppIdentifierPrefix)`, which only signing knows — is left as written.
public struct ResolvedBuildSettings: Sendable {
    public let values: [String: String]

    public init(layers: [[String: String]], defaults: [String: String] = [:]) {
        var merged = defaults
        for layer in layers {
            for (key, value) in layer {
                merged[key] = Self.inheriting(value, from: merged[key])
            }
        }
        values = merged
    }

    public subscript(key: String) -> String? {
        values[key].map { expand($0) }
    }

    public func bool(_ key: String) -> Bool { self[key]?.uppercased() == "YES" }

    /// Expands every `$(VAR)` and `${VAR}` it can, recursively, with the
    /// modifiers a bundle id or module name is usually written with.
    public func expand(_ text: String) -> String { expand(text, depth: 0) }

    private func expand(_ text: String, depth: Int) -> String {
        guard depth < 12, text.contains("$") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard character == "$", next < text.endIndex,
                  let close = Self.closer(for: text[next]),
                  let end = text[next...].firstIndex(of: close) else {
                output.append(character)
                index = next
                continue
            }
            let reference = String(text[text.index(after: next)..<end])
            let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
            if let name = parts.first, let raw = values[name] {
                let value = expand(raw, depth: depth + 1)
                output += parts.count > 1 ? Self.apply(modifier: parts[1], to: value) : value
            } else {
                output += text[index...end]
            }
            index = text.index(after: end)
        }
        return output
    }

    private static func closer(for opener: Character) -> Character? {
        switch opener {
        case "(": return ")"
        case "{": return "}"
        default: return nil
        }
    }

    private static func apply(modifier: String, to value: String) -> String {
        switch modifier {
        case "c99extidentifier", "identifier":
            return String(value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        case "rfc1034identifier":
            return String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
        case "lower": return value.lowercased()
        case "upper": return value.uppercased()
        default: return value
        }
    }

    static func inheriting(_ value: String, from previous: String?) -> String {
        value.replacingOccurrences(of: "$(inherited)", with: previous ?? "")
            .replacingOccurrences(of: "${inherited}", with: previous ?? "")
            .trimmingCharacters(in: .whitespaces)
    }
}
