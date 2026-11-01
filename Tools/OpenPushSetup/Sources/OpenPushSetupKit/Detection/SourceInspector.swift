import Foundation

/// What a target's source files say about it: the modules they import and the
/// file that declares a given class.
enum SourceInspector {
    static func imports(in text: String) -> [String] {
        var modules: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let module = swiftImport(trimmed) ?? objcImport(trimmed), !modules.contains(module) {
                modules.append(module)
            }
        }
        return modules
    }

    /// `import X`, `@testable import X`, `@preconcurrency import X`, `import class X.Y`.
    private static func swiftImport(_ line: String) -> String? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let index = words.firstIndex(of: "import"),
              words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { return nil }
        let kinds: Set<Substring> = ["class", "struct", "enum", "protocol", "typealias", "func", "var", "let"]
        var rest = words[(index + 1)...]
        if let first = rest.first, kinds.contains(first) { rest = rest.dropFirst() }
        guard let path = rest.first else { return nil }
        return path.split(separator: ".").first.map(String.init)
    }

    /// `@import X;` and `#import <X/Header.h>`.
    private static func objcImport(_ line: String) -> String? {
        if line.hasPrefix("@import ") {
            return line.dropFirst("@import ".count).split(whereSeparator: { $0 == ";" || $0 == "." })
                .first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if line.hasPrefix("#import <") || line.hasPrefix("#include <") {
            guard let open = line.firstIndex(of: "<"), let slash = line[open...].firstIndex(of: "/") else { return nil }
            return String(line[line.index(after: open)..<slash])
        }
        return nil
    }

    /// The source declaring `className`, by Swift class declaration or an
    /// `@objc(Name)` / `@interface Name` the Info.plist could name instead.
    static func file(declaring className: String, in sources: [String],
                     read: (String) -> String?) -> String? {
        let patterns = ["class \(className)", "@objc(\(className))", "@interface \(className)",
                        "@implementation \(className)"]
        return sources.first { path in
            guard let text = read(path) else { return false }
            return patterns.contains { pattern in
                text.components(separatedBy: pattern).dropFirst().contains { tail in
                    guard let next = tail.first else { return true }
                    return !(next.isLetter || next.isNumber || next == "_")
                }
            }
        }
    }
}
