import Foundation

/// What a run did, in the words the developer reads at the end.
public struct ApplyReport: Sendable {
    /// Every change made, one line each.
    public private(set) var changes: [String] = []
    /// Values found and deliberately left as they were — signing above all.
    public private(set) var kept: [String] = []
    /// Steps setup does not take itself, such as Podfile lines to add.
    public private(set) var manual: [String] = []
    public private(set) var notes: [String] = []
    public var backupFolder: String?

    public init() {}

    mutating func changed(_ line: String) { if !changes.contains(line) { changes.append(line) } }
    mutating func keep(_ line: String) { if !kept.contains(line) { kept.append(line) } }
    mutating func todo(_ line: String) { if !manual.contains(line) { manual.append(line) } }
    mutating func note(_ line: String) { if !notes.contains(line) { notes.append(line) } }

    public var text: String {
        var lines: [String] = []
        if changes.isEmpty { lines.append("Nothing to change: the project is already set up.") }
        else { lines.append("Changed:"); lines += changes.map { "  - \($0)" } }
        if !kept.isEmpty { lines.append("Kept as they were:"); lines += kept.map { "  - \($0)" } }
        if !manual.isEmpty { lines.append("Still to do by hand:"); lines += manual.map { "  - \($0)" } }
        if !notes.isEmpty { lines.append("Notes:"); lines += notes.map { "  - \($0)" } }
        if let backupFolder { lines.append("Originals backed up to \(backupFolder).") }
        return lines.joined(separator: "\n")
    }
}
