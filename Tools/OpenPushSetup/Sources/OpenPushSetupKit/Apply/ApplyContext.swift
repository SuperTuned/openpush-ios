import Foundation

/// The state of one `apply` run that every step shares: the project as scanned
/// before the run, the decisions, the editor, and the files being changed.
final class ApplyContext {
    struct CreatedTarget {
        let infoPlist: String
        let entitlements: String?
        let settings: [String: ResolvedBuildSettings]
    }

    let project: ScannedProject
    let findings: [SetupFinding]
    let plan: ChoiceResolver.Plan
    let options: ApplyOptions
    let editor: ProjectEditor
    let backup: BackupStore
    var report = ApplyReport()
    private(set) var created: [String: CreatedTarget] = [:]
    private var documents: [String: PlistDocument] = [:]
    /// Files a step creates, written only once every step has succeeded.
    private(set) var staged: [(path: String, data: Data)] = []

    init(project: ScannedProject, findings: [SetupFinding], plan: ChoiceResolver.Plan,
         options: ApplyOptions, editor: ProjectEditor, backup: BackupStore) {
        self.project = project
        self.findings = findings
        self.plan = plan
        self.options = options
        self.editor = editor
        self.backup = backup
    }

    var choices: SetupChoices { plan.choices }
    var app: ProjectTarget? { project.target(named: plan.appTarget) }

    /// The service extension OpenPush will run in, unless the choice is off.
    var serviceExtensionTarget: String? {
        guard let choice = choices.serviceExtension, choice.mode != .off else { return nil }
        return choice.target
    }

    /// Links through CocoaPods (printed, never edited) when the project already
    /// uses a Podfile and has no OpenPush Swift package.
    var usesPods: Bool {
        FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("Podfile").path)
            && !project.remotePackages.contains { PackageResolved.identity(of: $0.url) == "openpush-ios" }
    }

    func plist(_ relativePath: String) throws -> PlistDocument {
        if let document = documents[relativePath] { return document }
        let document = try PlistDocument(url: project.url(for: relativePath))
        documents[relativePath] = document
        return document
    }

    func register(_ name: String, _ target: CreatedTarget) { created[name] = target }

    /// Queues a new file; a file already on disk is left as it is.
    func stage(_ relativePath: String, _ data: Data) {
        guard !FileManager.default.fileExists(atPath: project.url(for: relativePath).path),
              !staged.contains(where: { $0.path == relativePath }) else { return }
        staged.append((relativePath, data))
    }

    /// Replaces an existing file, after backing it up, at write time.
    func stageReplacement(_ relativePath: String, _ data: Data) {
        staged.removeAll { $0.path == relativePath }
        staged.append((relativePath, data))
    }

    func settings(of target: String) -> [ResolvedBuildSettings] {
        if let created = created[target] { return Array(created.settings.values) }
        return project.target(named: target)?.configurations.map(\.settings) ?? []
    }

    /// Every entitlements file the target signs with. A target with none gets
    /// `<folder>/<Target>.entitlements`, set on every configuration.
    func entitlementsFiles(of target: String) -> [String] {
        if let created = created[target] { return created.entitlements.map { [$0] } ?? [] }
        guard let scanned = project.target(named: target) else { return [] }
        let existing = unique(scanned.configurations.compactMap(\.entitlementsPath))
        if !existing.isEmpty { return existing }
        let folder = scanned.primary?.infoPlistPath.map { ($0 as NSString).deletingLastPathComponent } ?? target
        let path = (folder.isEmpty ? "" : folder + "/") + "\(target).entitlements"
        editor.setSetting("CODE_SIGN_ENTITLEMENTS", path, target: target)
        report.changed("\(target): CODE_SIGN_ENTITLEMENTS = \(path) (new file)")
        return [path]
    }

    /// Every Info.plist file the target builds with. A target that generates
    /// its Info.plist with no file gets `<Target>/Info.plist`, which Xcode
    /// merges with the generated keys.
    func infoPlistFiles(of target: String) -> [String] {
        if let created = created[target] { return [created.infoPlist] }
        guard let scanned = project.target(named: target) else { return [] }
        let existing = unique(scanned.configurations.compactMap(\.infoPlistPath))
        if !existing.isEmpty { return existing }
        let path = "\(target)/Info.plist"
        editor.setSetting("INFOPLIST_FILE", path, target: target)
        report.changed("\(target): INFOPLIST_FILE = \(path) (new file)")
        for excluded in editor.excludeFromSynchronizedFolders(path) {
            report.changed("\(excluded): \(path) excluded from its synchronized folder, so it is not also copied as a resource")
        }
        return [path]
    }

    /// Expands a value through any of the target's configurations.
    func expander(for target: String) -> (String) -> String {
        let settings = settings(of: target)
        return { value in settings.first.map { $0.expand(value) } ?? value }
    }

    /// Writes everything the steps prepared: staged files, then plists.
    func writeFiles() throws {
        for file in staged {
            let url = project.url(for: file.path)
            try backup.preserve(url)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try file.data.write(to: url, options: .atomic)
        }
        for (_, document) in documents.sorted(by: { $0.key < $1.key }) {
            try document.save(backup: backup)
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// One part of `apply`. Steps run in order over a shared context, and each
/// must leave an already-applied project unchanged.
protocol ApplyStep: Sendable {
    func apply(_ context: ApplyContext) throws
}
