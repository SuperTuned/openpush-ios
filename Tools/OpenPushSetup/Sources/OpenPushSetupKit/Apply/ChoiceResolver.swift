import Foundation

/// Completes the choices for one run: an option on the command line wins, then
/// a stored answer, then a question — asked on a TTY, defaulted under `--yes`,
/// and otherwise reported as missing so CI fails with the flag to pass.
public struct ChoiceResolver {
    public struct Plan: Equatable, Sendable {
        public let appTarget: String
        public let choices: SetupChoices
    }

    public static let createdExtensionName = "OpenPushNotificationService"
    public static let createdWidgetName = "LiveActivityWidget"

    let project: ScannedProject
    let findings: [SetupFinding]
    let stored: SetupChoices
    let options: ApplyOptions
    let prompter: (any ChoicePrompter)?

    public init(project: ScannedProject, findings: [SetupFinding], stored: SetupChoices,
                options: ApplyOptions, prompter: (any ChoicePrompter)?) {
        self.project = project
        self.findings = findings
        self.stored = stored
        self.options = options
        self.prompter = prompter
    }

    public func resolve() throws -> Plan {
        let app = try appTarget()
        let bundleID = project.target(named: app)?.primary?.bundleID ?? app
        var missing: [SetupQuestion] = []
        func decide(_ question: SetupQuestion) -> Int? {
            if let prompter { return prompter.choose(question) }
            if options.assumeDefaults, let index = question.defaultIndex { return index }
            missing.append(question)
            return nil
        }

        let service = try serviceExtension(app: app, bundleID: bundleID, decide: decide)
        let reused = service.flatMap { [.takeOver, .share].contains($0.mode) ? $0.target : nil }
        let group = appGroup(app: app, bundleID: bundleID, reusedExtension: reused, decide: decide)
        let keychain = keychainGroup(app: app, reusedExtension: reused, decide: decide)
        let widget = widgetExtension(bundleID: bundleID, decide: decide)

        guard missing.isEmpty else { throw SetupError.missingChoices(missing) }
        return Plan(appTarget: app, choices: SetupChoices(
            appGroup: group, keychainGroup: keychain, serviceExtension: service, widgetExtension: widget))
    }

    // MARK: - App target

    private func appTarget() throws -> String {
        let apps = project.apps.map(\.name)
        if let named = options.appTarget {
            guard apps.contains(named) else { throw SetupError.unknownTarget(named, apps) }
            return named
        }
        let hosts = Set(findings.filter { $0.kind == .serviceExtension }
            .flatMap { $0.details["embedded_in"]?.strings ?? [] })
        if hosts.count == 1, let host = hosts.first { return host }
        if apps.count == 1, let only = apps.first { return only }
        throw SetupError.ambiguousAppTarget(apps)
    }

    // MARK: - Service extension

    private func serviceExtension(app: String, bundleID: String,
                                  decide: (SetupQuestion) -> Int?) throws -> SetupChoices.ServiceExtension? {
        let existing = findings.filter { $0.kind == .serviceExtension }
        func created() -> SetupChoices.ServiceExtension {
            .init(mode: .inject, target: Self.createdExtensionName,
                  bundleID: options.nseBundleID ?? stored.serviceExtension?.bundleID
                      ?? "\(bundleID).\(Self.createdExtensionName)",
                  profile: options.nseProfile ?? stored.serviceExtension?.profile)
        }
        func reusing(_ mode: SetupChoices.ServiceExtensionMode, _ finding: SetupFinding) -> SetupChoices.ServiceExtension {
            .init(mode: mode, target: finding.id, bundleID: finding.details["bundle_id"]?.stringValue, profile: nil)
        }

        let others = existing.map(\.id).filter { $0 != Self.createdExtensionName }
        if let mode = options.nseMode ?? stored.serviceExtension?.mode {
            switch mode {
            case .inject:
                // iOS runs one service extension per app: a second one is never added.
                guard others.isEmpty else { throw SetupError.injectWithExistingExtension(others) }
                return created()
            case .off: return .init(mode: .off, target: nil, bundleID: nil, profile: nil)
            case .takeOver, .share:
                let named = stored.serviceExtension?.target
                guard let target = existing.first(where: { $0.id == named }) ?? (existing.count == 1 ? existing.first : nil)
                else { throw SetupError.noExistingExtension(mode.rawValue) }
                return reusing(mode, target)
            }
        }
        if options.nseBundleID != nil {
            guard others.isEmpty else { throw SetupError.injectWithExistingExtension(others) }
            return created()
        }
        guard !existing.isEmpty else { return created() }
        guard existing.count == 1, let only = existing.first else {
            _ = decide(SetupQuestion(
                choice: "service_extension",
                text: "The project has \(existing.count) notification service extensions (\(existing.map(\.id).joined(separator: ", "))). iOS runs one.",
                options: [], defaultIndex: nil, flag: "--nse-mode (after removing the extra extensions)"))
            return nil
        }
        // A vendor's own template is taken over without asking; an extension
        // the studio wrote is theirs, so that one is always a question.
        if only.vendor != nil { return reusing(.takeOver, only) }
        let modes: [SetupChoices.ServiceExtensionMode] = [.share, .takeOver, .off]
        let answer = decide(SetupQuestion(
            choice: "service_extension",
            text: "\(only.id) is an existing notification service extension. How should OpenPush use it?",
            options: [
                "Share it: OpenPush handles its own pushes, your code handles the rest",
                "Take it over: replace its code with OpenPush's (sources are backed up)",
                "Leave it alone: no OpenPush images, buttons or delivery receipts",
            ],
            defaultIndex: 0, flag: "--nse-mode share|take_over|off"))
        return answer.map { reusing(modes[$0], only) }
    }

    // MARK: - App Group

    private func groups(_ kind: SetupFinding.Kind, on target: String?) -> [String] {
        var seen: [String] = []
        for finding in findings where finding.kind == kind && finding.target == target && target != nil
            && !seen.contains(finding.id) { seen.append(finding.id) }
        return seen
    }

    private func appGroup(app: String, bundleID: String, reusedExtension: String?,
                          decide: (SetupQuestion) -> Int?) -> SetupChoices.AppGroup? {
        let onApp = groups(.appGroup, on: app)
        if let value = options.appGroup {
            return .init(mode: onApp.contains(value) ? .reuse : .new, value: value)
        }
        if let stored = stored.appGroup { return stored }
        let fresh = "group.\(bundleID).openpush"
        let onExtension = groups(.appGroup, on: reusedExtension)
        let shared = onApp.filter(onExtension.contains)
        let candidates = !shared.isEmpty ? shared : onApp + onExtension.filter { !onApp.contains($0) }
        guard !candidates.isEmpty else { return .init(mode: .new, value: fresh) }

        // Reuse is only a safe default for one group both targets already sign
        // with. A group on the app alone, or more than one, is never guessed.
        let safe = shared.count == 1
        let text = safe
            ? "\(shared[0]) is on both \(app) and \(reusedExtension ?? "the extension"). Reuse it for OpenPush?"
            : "Which App Group should OpenPush use? Found: \(candidates.joined(separator: ", "))."
        let answer = decide(SetupQuestion(
            choice: "app_group", text: text,
            options: candidates.map { "Reuse \($0)" } + ["Create \(fresh)"],
            defaultIndex: safe ? 0 : nil, flag: "--app-group"))
        return answer.map { $0 < candidates.count ? .init(mode: .reuse, value: candidates[$0]) : .init(mode: .new, value: fresh) }
    }

    // MARK: - Keychain group

    private func keychainGroup(app: String, reusedExtension: String?,
                               decide: (SetupQuestion) -> Int?) -> SetupChoices.KeychainGroup? {
        let onApp = groups(.keychainGroup, on: app)
        if let value = options.keychainGroup {
            return .init(mode: onApp.contains(value) ? .reuse : .new, value: value)
        }
        if let stored = stored.keychainGroup { return stored }
        // The extension's receipt needs no credential, so with nothing to reuse
        // there is nothing to add.
        let shared = onApp.filter(groups(.keychainGroup, on: reusedExtension).contains)
        guard shared.count == 1 else { return .init(mode: .none, value: nil) }
        let answer = decide(SetupQuestion(
            choice: "keychain_group",
            text: "\(shared[0]) is a Keychain group on both targets. Let the extension read the device credential through it?",
            options: ["Reuse \(shared[0])", "No Keychain group"], defaultIndex: 0, flag: "--keychain-group"))
        return answer.map { $0 == 0 ? .init(mode: .reuse, value: shared[0]) : .init(mode: .none, value: nil) }
    }

    // MARK: - Widget

    private func widgetExtension(bundleID: String, decide: (SetupQuestion) -> Int?) -> SetupChoices.WidgetExtension? {
        let existing = findings.filter { $0.kind == .widgetExtension }
        func created() -> SetupChoices.WidgetExtension {
            .init(mode: .new, target: Self.createdWidgetName,
                  bundleID: options.widgetBundleID ?? stored.widgetExtension?.bundleID
                      ?? "\(bundleID).\(Self.createdWidgetName)",
                  profile: options.widgetProfile ?? stored.widgetExtension?.profile)
        }
        let mode = options.widgetMode ?? (options.widgetBundleID != nil ? .new : nil) ?? stored.widgetExtension?.mode
        switch mode {
        case .new?: return created()
        case .off?: return .init(mode: .off, target: nil, bundleID: nil, profile: nil)
        case .reuse?:
            let named = stored.widgetExtension?.target
            let target = existing.first { $0.id == named } ?? existing.first
            return target.map { .init(mode: .reuse, target: $0.id, bundleID: $0.details["bundle_id"]?.stringValue, profile: nil) }
                ?? .init(mode: .off, target: nil, bundleID: nil, profile: nil)
        case nil:
            // Live Activities are opt-in: with no widget there is nothing to ask.
            guard let first = existing.first else { return .init(mode: .off, target: nil, bundleID: nil, profile: nil) }
            let answer = decide(SetupQuestion(
                choice: "widget_extension",
                text: "\(first.id) is a widget extension. Link OpenPushLiveActivities to it for Live Activities?",
                options: ["Reuse \(first.id)", "No"], defaultIndex: 0, flag: "--widget-mode reuse|new|off"))
            return answer.map {
                $0 == 0 ? .init(mode: .reuse, target: first.id, bundleID: first.details["bundle_id"]?.stringValue, profile: nil)
                    : .init(mode: .off, target: nil, bundleID: nil, profile: nil)
            }
        }
    }
}
