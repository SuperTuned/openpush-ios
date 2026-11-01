import Foundation

/// The pods a Podfile declares, and the targets each is declared in.
///
/// A line-level reading of the Ruby DSL, not an evaluation: `target 'X' do`
/// opens a block, `end` closes the innermost block, and `pod 'Name', …` belongs
/// to every enclosing target (nested targets inherit, as `inherit!` defaults).
struct Podfile {
    struct Declaration: Equatable {
        let name: String
        var targets: [String]
        var requirement: String?
    }

    let declarations: [Declaration]

    init(text: String) {
        var stack: [String?] = []
        var byName: [String: Declaration] = [:]
        var order: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if line.hasPrefix("target ") || line.hasPrefix("abstract_target ") {
                stack.append(Self.quoted(line).first)
            } else if line.range(of: #"\bdo(\s*\|.*\|)?$"#, options: .regularExpression) != nil {
                stack.append(nil)
            } else if line == "end" {
                _ = stack.popLast()
            } else if line.hasPrefix("pod ") {
                let arguments = Self.quoted(line)
                guard let name = arguments.first else { continue }
                let root = String(name.split(separator: "/").first ?? Substring(name))
                let targets = stack.compactMap { $0 }
                if byName[root] == nil {
                    order.append(root)
                    byName[root] = Declaration(name: root, targets: [], requirement: nil)
                }
                for target in targets where !(byName[root]?.targets.contains(target) ?? true) {
                    byName[root]?.targets.append(target)
                }
                let requirement = arguments.dropFirst().joined(separator: ", ")
                if byName[root]?.requirement == nil, !requirement.isEmpty {
                    byName[root]?.requirement = requirement
                }
            }
        }
        declarations = order.compactMap { byName[$0] }
    }

    private static func quoted(_ line: String) -> [String] {
        var values: [String] = []
        var current: String?
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { values.append(current ?? ""); current = nil; quote = nil }
                else { current?.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                current = ""
            }
        }
        return values
    }
}

/// The resolved pod versions and subspecs from `Podfile.lock`'s `PODS:` list.
struct PodfileLock {
    struct Pod: Equatable {
        let name: String
        var version: String?
        var subspecs: [String]
    }

    let pods: [Pod]

    init(text: String) {
        var byName: [String: Pod] = [:]
        var order: [String] = []
        var inPods = false
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix(" ") && !line.isEmpty { inPods = line == "PODS:"; continue }
            // Top-level entries are "  - Name (1.2.3)" or "  - Name (1.2.3):";
            // deeper indentation lists that pod's own dependencies.
            guard inPods, line.hasPrefix("  - ") else { continue }
            let entry = line.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " :\""))
            let parts = entry.split(separator: " ", maxSplits: 1)
            guard let full = parts.first.map(String.init) else { continue }
            let version = parts.count > 1
                ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) : nil
            let components = full.split(separator: "/", maxSplits: 1).map(String.init)
            let root = components[0]
            if byName[root] == nil { order.append(root); byName[root] = Pod(name: root, version: nil, subspecs: []) }
            if byName[root]?.version == nil { byName[root]?.version = version }
            if components.count > 1, !(byName[root]?.subspecs.contains(components[1]) ?? true) {
                byName[root]?.subspecs.append(components[1])
            }
        }
        pods = order.compactMap { byName[$0] }
    }
}
