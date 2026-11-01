import ArgumentParser
import Foundation
import OpenPushSetupKit

struct OpenPushIOSSetup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openpush-ios-setup",
        abstract: "Set up OpenPush in an iOS project, reusing the push plumbing it already has.",
        subcommands: [Scan.self, Apply.self])
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the push plumbing the project already has.",
        discussion: """
            Reads the project and prints what it found: notification, content and \
            widget extensions, App Groups, Keychain groups, aps-environment, \
            remote-notification background mode, and the push SDKs installed. \
            Nothing is changed unless --write is given.
            """)

    @Option(name: .long, help: "The .xcodeproj, or the folder holding it. Defaults to the current folder.")
    var project: String = "."

    @Flag(name: .long, help: "Print the answer-file document (schema openpush-setup/1) as JSON.")
    var json = false

    @Flag(name: .long, help: "Also store the list in .openpush/setup.json beside the project, keeping its choices.")
    var write = false

    func run() throws {
        do {
            let projectURL = try ProjectLocator.locate(project)
            let findings = try ProjectScanner().scan(projectURL)
            let answersURL = projectURL.deletingLastPathComponent()
                .appendingPathComponent(SetupAnswerFile.relativePath)
            var answers = try write ? SetupAnswerFile.load(from: answersURL) : SetupAnswerFile()
            try answers.replaceFound(findings)
            if write { try answers.write(to: answersURL) }
            if json {
                FileHandle.standardOutput.write(try answers.data())
            } else {
                print(ScanReport(projectName: projectURL.lastPathComponent, findings: findings).text)
                if write { print("Wrote \(SetupAnswerFile.relativePath).") }
            }
        } catch let error as SetupError {
            fail(error)
        }
    }
}

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up OpenPush, reusing what the project already has.",
        discussion: """
            Reads the answers stored in .openpush/setup.json, asks for any that are \
            missing when run in a terminal, and applies them. In CI pass --yes to take \
            the Reuse defaults; a choice with no safe default fails with the option \
            to pass. Every file changed is backed up to .openpush/backup/ first.
            """)

    @Option(name: .long, help: "The .xcodeproj, or the folder holding it.")
    var project: String = "."
    @Option(name: .long, help: "The app target, when the project has more than one.")
    var appTarget: String?
    @Option(name: .long, help: "The App Group to use, reused if a target has it, otherwise added.")
    var appGroup: String?
    @Option(name: .long, help: "A Keychain access group for the device credential.")
    var keychainGroup: String?
    @Option(name: .long, help: "What to do with the notification service extension: take_over, share, inject or off.")
    var nseMode: String?
    @Option(name: .long, help: "Bundle id of a created service extension.")
    var nseBundleId: String?
    @Option(name: .long, help: "Profile for a created service extension: a name, or Debug=<name>,Release=<name>.")
    var nseProfile: String?
    @Option(name: .long, help: "The Live Activity widget: reuse, new or off.")
    var widgetMode: String?
    @Option(name: .long, help: "Bundle id of a created widget extension.")
    var widgetBundleId: String?
    @Option(name: .long, help: "Profile for a created widget extension.")
    var widgetProfile: String?
    @Option(name: .long, help: "OpenPush app id, written to the Info.plist.")
    var appId: String?
    @Option(name: .long, help: "OpenPush public SDK key, written to the Info.plist.")
    var sdkKey: String?
    @Option(name: .long, help: "Link OpenPush from this local checkout instead of the published package.")
    var packagePath: String?
    @Flag(name: .long, help: "Take the Reuse defaults without asking.")
    var yes = false

    func run() throws {
        var options = ApplyOptions()
        options.appTarget = appTarget
        options.appGroup = appGroup
        options.keychainGroup = keychainGroup
        options.nseMode = try nseMode.map { try parse($0, "--nse-mode", SetupChoices.ServiceExtensionMode.init) }
        options.nseBundleID = nseBundleId
        options.nseProfile = nseProfile.map(ProvisioningProfiles.init)
        options.widgetMode = try widgetMode.map { try parse($0, "--widget-mode", SetupChoices.WidgetMode.init) }
        options.widgetBundleID = widgetBundleId
        options.widgetProfile = widgetProfile.map(ProvisioningProfiles.init)
        options.appID = appId
        options.sdkKey = sdkKey
        if let packagePath { options.package = .local(path: packagePath) }
        options.assumeDefaults = yes
        let prompter: (any ChoicePrompter)? = !yes && isatty(STDIN_FILENO) == 1 ? TerminalPrompter() : nil
        do {
            let report = try SetupApplier().apply(ProjectLocator.locate(project), options: options, prompter: prompter)
            print(report.text)
        } catch let error as SetupError {
            fail(error)
        }
    }

    private func parse<T>(_ value: String, _ flag: String, _ make: (String) -> T?) throws -> T {
        guard let parsed = make(value) else { throw ValidationError("\(flag): unknown value \(value)") }
        return parsed
    }
}

/// Asks on the terminal; Return takes the default.
struct TerminalPrompter: ChoicePrompter {
    func choose(_ question: SetupQuestion) -> Int {
        print(question.text)
        for (index, option) in question.options.enumerated() {
            print("  \(index + 1). \(option)\(index == question.defaultIndex ? " (default)" : "")")
        }
        while true {
            print("> ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty, let index = question.defaultIndex { return index }
            if let number = Int(line), (1...question.options.count).contains(number) { return number - 1 }
            print("Type a number from 1 to \(question.options.count).")
        }
    }
}

/// A setup error is a message for the developer, not a usage mistake: print
/// it alone and exit non-zero.
func fail(_ error: SetupError) -> Never {
    FileHandle.standardError.write(Data((error.description + "\n").utf8))
    Foundation.exit(1)
}

OpenPushIOSSetup.main()
