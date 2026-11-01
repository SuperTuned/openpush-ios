import Foundation

/// `apply`: scan, settle the choices, run every step in memory, and only then
/// write — files first, then the project, then the answer file. A run that
/// fails before writing leaves the project exactly as it was; one that fails
/// while writing is rolled back from its backup.
public struct SetupApplier {
    let loader: any ProjectLoading
    let scanner: ProjectScanner
    let steps: [any ApplyStep]

    public init(loader: any ProjectLoading = XcodeProjectLoader(), scanner: ProjectScanner = ProjectScanner()) {
        self.loader = loader
        self.scanner = scanner
        steps = [ServiceExtensionStep(fingerprints: scanner.fingerprints)] + Self.otherSteps
    }

    /// The service extension runs first: the steps after it treat a created or
    /// taken-over extension like any other.
    static let otherSteps: [any ApplyStep] = [
        WidgetStep(),
        CapabilitiesStep(),
        GroupsStep(),
        CredentialsStep(),
        LinkingStep(),
    ]

    public func apply(_ projectURL: URL, options: ApplyOptions,
                      prompter: (any ChoicePrompter)?) throws -> ApplyReport {
        let project = try loader.load(projectURL)
        let findings = scanner.scan(project)
        let answersURL = project.folder.appendingPathComponent(SetupAnswerFile.relativePath)
        var answers = try SetupAnswerFile.load(from: answersURL)

        let plan = try ChoiceResolver(project: project, findings: findings, stored: SetupChoices(answers: answers),
                                      options: options, prompter: prompter).resolve()
        _ = try CredentialsStep.credentials(project, app: plan.appTarget, options: options)

        let backup = BackupStore(projectFolder: project.folder, timestamp: options.timestamp)
        let context = ApplyContext(project: project, findings: findings, plan: plan, options: options,
                                   editor: try ProjectEditor(projectURL: projectURL), backup: backup)
        for step in steps { try step.apply(context) }
        reportKeptSigning(context)

        // Every step has succeeded in memory. If writing still fails part-way,
        // the files already written are put back from the backup.
        do {
            try context.writeFiles()
            try context.editor.save(backup: backup)
            plan.choices.store(in: &answers)
            try answers.replaceFound(scanner.scan(loader.load(projectURL)))
            try answers.write(to: answersURL)
        } catch {
            backup.rollback()
            throw error
        }

        var report = context.report
        if !backup.isEmpty { report.backupFolder = project.relativePath(backup.root) }
        return report
    }

    private func reportKeptSigning(_ context: ApplyContext) {
        let touched = [context.plan.appTarget, context.serviceExtensionTarget,
                       context.choices.widgetExtension?.mode == .reuse ? context.choices.widgetExtension?.target : nil]
        for name in touched.compactMap({ $0 }) {
            guard let target = context.project.target(named: name) else { continue }
            SigningPolicy.kept(on: target).forEach { context.report.keep($0) }
        }
    }
}
