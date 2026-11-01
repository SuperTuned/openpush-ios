import Foundation
import XCTest
@testable import OpenPushSetupKit

/// A throwaway copy of a committed fixture, so `apply` can change it freely.
struct FixtureWorkspace {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    /// The SDK checkout, linked as a local package so nothing is fetched.
    static let sdkRoot = fixtures.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    let folder: URL
    let projectURL: URL

    init(_ fixture: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openpush-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = root.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: folder)
        projectURL = try ProjectLocator.locate(folder.path)
    }

    func remove() { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

    func options(_ configure: (inout ApplyOptions) -> Void = { _ in }) -> ApplyOptions {
        var options = ApplyOptions()
        options.appID = "app-1"
        options.sdkKey = "key-1"
        options.package = .local(path: Self.sdkRoot.path)
        options.assumeDefaults = true
        options.timestamp = "test"
        configure(&options)
        return options
    }

    @discardableResult
    func apply(_ options: ApplyOptions, prompter: (any ChoicePrompter)? = nil,
               scanner: ProjectScanner = ProjectScanner()) throws -> ApplyReport {
        try SetupApplier(scanner: scanner).apply(projectURL, options: options, prompter: prompter)
    }

    func scan() throws -> ScannedProject { try XcodeProjectLoader().load(projectURL) }

    func data(_ relative: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(relative)) }

    func text(_ relative: String) throws -> String { try String(decoding: data(relative), as: UTF8.self) }

    func plist(_ relative: String) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: data(relative), format: nil) as? [String: Any] ?? [:]
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relative).path)
    }

    /// Every file's bytes, for "nothing was changed" assertions.
    func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }
}

/// Answers questions from a script, recording what was asked.
final class ScriptedPrompter: ChoicePrompter {
    private var answers: [Int]
    private(set) var asked: [SetupQuestion] = []

    init(_ answers: [Int]) { self.answers = answers }

    func choose(_ question: SetupQuestion) -> Int {
        asked.append(question)
        return answers.isEmpty ? (question.defaultIndex ?? 0) : answers.removeFirst()
    }
}
