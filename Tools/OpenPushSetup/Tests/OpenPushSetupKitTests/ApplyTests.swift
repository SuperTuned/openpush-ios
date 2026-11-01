import XCTest
@testable import OpenPushSetupKit

/// `apply` on copies of the fixtures: what it writes, what it keeps, and when
/// it refuses.
final class ApplyTests: XCTestCase {
    private var workspaces: [FixtureWorkspace] = []

    override func tearDown() {
        workspaces.forEach { $0.remove() }
        super.tearDown()
    }

    private func workspace(_ fixture: String) throws -> FixtureWorkspace {
        let workspace = try FixtureWorkspace(fixture)
        workspaces.append(workspace)
        return workspace
    }

    private func settings(_ project: ScannedProject, _ target: String, _ configuration: String) -> ResolvedBuildSettings? {
        project.target(named: target)?.configurations.first { $0.name == configuration }?.settings
    }

    // MARK: - Idempotence, backup, answers

    func testApplyWritesOnceThenChangesNothing() throws {
        let fixture = try workspace("TwoGroups")
        let first = try fixture.apply(fixture.options())

        XCTAssertTrue(first.changes.contains("Duo: links OpenPush"), "\(first.changes)")
        XCTAssertTrue(first.changes.contains("DuoService: links OpenPushNSE"))
        XCTAssertEqual(first.backupFolder, ".openpush/backup/test")
        XCTAssertTrue(fixture.exists(".openpush/backup/test/Duo.xcodeproj/project.pbxproj"))
        XCTAssertTrue(fixture.exists(".openpush/backup/test/Duo-Info.plist"))
        XCTAssertEqual(try fixture.plist("Duo-Info.plist")["OpenPushAppID"] as? String, "app-1")
        XCTAssertEqual(try fixture.plist("DuoService-Info.plist")["OpenPushSDKKey"] as? String, "key-1",
                       "the extension's Info.plist carries the fallback too")

        let applied = try fixture.snapshot().filter { !$0.key.hasPrefix(".openpush/") }
        let second = try fixture.apply(fixture.options { $0.timestamp = "again" })
        XCTAssertEqual(second.changes, [])
        XCTAssertNil(second.backupFolder, "nothing changed, so nothing was backed up")
        XCTAssertEqual(try fixture.snapshot().filter { !$0.key.hasPrefix(".openpush/") }, applied)
    }

    func testAnswersAreStoredSoALaterRunNeedsNoOptions() throws {
        let fixture = try workspace("TwoGroups")
        try fixture.apply(fixture.options())

        let answers = try SetupAnswerFile.load(from: fixture.folder.appendingPathComponent(SetupAnswerFile.relativePath))
        let stored = SetupChoices(answers: answers)
        XCTAssertEqual(stored.appGroup, .init(mode: .reuse, value: "group.com.example.duo.push"))
        XCTAssertEqual(stored.serviceExtension?.mode, .share)
        XCTAssertEqual(stored.serviceExtension?.target, "DuoService")
        XCTAssertEqual(stored.keychainGroup?.mode, SetupChoices.KeychainMode.none)
        XCTAssertFalse((answers.document["found"] as? [Any] ?? []).isEmpty)

        // No --yes, no TTY: the stored answers are enough.
        XCTAssertNoThrow(try fixture.apply(fixture.options { $0.assumeDefaults = false }))
    }

    func testAPromptAnswersTheQuestionsAndItsAnswerIsKept() throws {
        let fixture = try workspace("TwoGroups")
        let prompter = ScriptedPrompter([0, 1])   // share; then "Create" over the shared group
        try fixture.apply(fixture.options { $0.assumeDefaults = false }, prompter: prompter)

        XCTAssertEqual(prompter.asked.map(\.choice), ["service_extension", "app_group"])
        let stored = SetupChoices(answers: try SetupAnswerFile.load(
            from: fixture.folder.appendingPathComponent(SetupAnswerFile.relativePath)))
        XCTAssertEqual(prompter.asked[1].options, ["Reuse group.com.example.duo.push", "Create group.com.example.duo.openpush"])
        XCTAssertEqual(stored.appGroup, .init(mode: .new, value: "group.com.example.duo.openpush"))
    }

    // MARK: - Refusals

    func testWithoutATerminalOrYesTheMissingChoicesAreNamed() throws {
        let fixture = try workspace("TwoGroups")
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.assumeDefaults = false })) { error in
            guard case SetupError.missingChoices(let questions) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(questions.map(\.flag), ["--nse-mode share|take_over|off", "--app-group"])
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testAGroupOnTheAppAloneIsNeverGuessed() throws {
        let fixture = try workspace("GroupWithoutExtension")
        XCTAssertThrowsError(try fixture.apply(fixture.options())) { error in
            guard case SetupError.missingChoices(let questions) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(questions.map(\.flag), ["--app-group"], "--yes does not pick among unshared groups")
        }
        let before = try fixture.data("Solo.entitlements")
        try fixture.apply(fixture.options { $0.appGroup = "group.com.example.solo" })
        XCTAssertEqual(try fixture.data("Solo.entitlements"), before, "the app already has the group")
    }

    func testMissingCredentialsChangeNothing() throws {
        let fixture = try workspace("TwoGroups")
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.appID = nil })) { error in
            XCTAssertEqual(error as? SetupError, .missingCredentials(["--app-id"]))
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    // MARK: - Groups and entitlements

    func testAGroupWrittenThroughAVariableIsNotAddedAgain() throws {
        let fixture = try workspace("CustomExtension")
        let before = try fixture.data("Support/App.entitlements")
        try fixture.apply(fixture.options())

        XCTAssertEqual(try fixture.data("Support/App.entitlements"), before,
                       "$(SHOP_APP_GROUP) already is group.com.example.shop, and the Keychain group is reused as is")
        XCTAssertEqual(try fixture.data("Support/RichPush.entitlements").count,
                       try Data(contentsOf: FixtureWorkspace.fixtures
                        .appendingPathComponent("CustomExtension/Support/RichPush.entitlements")).count)
    }

    func testANewGroupIsMergedIntoBothTargets() throws {
        let fixture = try workspace("TwoGroups")
        let report = try fixture.apply(fixture.options { $0.appGroup = "group.com.example.duo.openpush" })

        for file in ["Duo.entitlements", "DuoService.entitlements"] {
            let groups = try fixture.plist(file)["com.apple.security.application-groups"] as? [String] ?? []
            XCTAssertTrue(groups.contains("group.com.example.duo.openpush"), file)
            XCTAssertTrue(groups.contains("group.com.example.duo.push"), "existing groups are kept in \(file)")
        }
        XCTAssertTrue(report.notes.contains { $0.contains("manual signing") })
    }

    func testPushCapabilityAndBackgroundModeAreAddedWhereMissing() throws {
        let fixture = try workspace("WidgetAndContent")
        try fixture.apply(fixture.options { $0.nseMode = .off; $0.widgetMode = .off })

        let info = try fixture.plist("Gallery-Info.plist")
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["remote-notification"])
        XCTAssertEqual(try fixture.plist("Gallery.entitlements")["aps-environment"] as? String, "development")
        XCTAssertNil(try fixture.plist("Gallery.entitlements")["com.apple.security.application-groups"],
                     "with the extension off nothing reads a group, so none is added")
    }

    // MARK: - Signing

    func testManualSigningIsKeptAndACreatedTargetRefusesWithoutAProfile() throws {
        let fixture = try workspace("ManualSigning")
        let protected = SigningPolicy.protectedKeys
        let original = try fixture.scan()
        let before = try fixture.snapshot()

        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.widgetMode = .new })) { error in
            XCTAssertEqual(error as? SetupError, .manualSigningNeedsProfile(
                target: "LiveActivityWidget", configurations: ["Debug", "Release"], flag: "--widget-profile"))
        }
        XCTAssertEqual(try fixture.snapshot(), before, "a refusal changes nothing")

        let report = try fixture.apply(fixture.options {
            $0.widgetMode = .new
            $0.widgetProfile = ProvisioningProfiles("Debug=Bank Widget Dev,Release=Bank Widget Store")
        })
        let applied = try fixture.scan()
        for target in ["Bank", "BankService"] {
            for configuration in ["Debug", "Release"] {
                for key in protected {
                    XCTAssertEqual(settings(applied, target, configuration)?[key],
                                   settings(original, target, configuration)?[key], "\(target) \(configuration) \(key)")
                }
            }
        }
        XCTAssertTrue(report.kept.contains {
            $0.hasPrefix("BankService (Release):") && $0.contains("PROVISIONING_PROFILE_SPECIFIER=Bank NSE AppStore")
        }, "\(report.kept)")

        let widgetDebug = try XCTUnwrap(settings(applied, "LiveActivityWidget", "Debug"))
        let widgetRelease = try XCTUnwrap(settings(applied, "LiveActivityWidget", "Release"))
        XCTAssertEqual(widgetDebug["PROVISIONING_PROFILE_SPECIFIER"], "Bank Widget Dev")
        XCTAssertEqual(widgetRelease["PROVISIONING_PROFILE_SPECIFIER"], "Bank Widget Store")
        XCTAssertEqual(widgetRelease["CODE_SIGN_STYLE"], "Manual")
        XCTAssertEqual(widgetRelease["DEVELOPMENT_TEAM"], "ABCDE12345")
        XCTAssertEqual(widgetRelease["CODE_SIGN_IDENTITY"], settings(original, "Bank", "Release")?["CODE_SIGN_IDENTITY"],
                       "the identity is the app's, per configuration")
        XCTAssertEqual(widgetRelease["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.bank.LiveActivityWidget")
        XCTAssertEqual(applied.target(named: "LiveActivityWidget")?.embeddedIn, ["Bank"])
        XCTAssertEqual(applied.target(named: "LiveActivityWidget")?.role, .widgetExtension)
        XCTAssertTrue(applied.target(named: "LiveActivityWidget")?.packageProducts.map(\.name)
                        .contains("OpenPushLiveActivities") ?? false)
    }

    func testAProfileForEveryConfigurationIsAccepted() {
        let single = ProvisioningProfiles("Example Widget")
        XCTAssertEqual(single.profile(for: "Debug"), "Example Widget")
        let split = ProvisioningProfiles("Debug=Dev, Release=Store")
        XCTAssertEqual(split.profile(for: "Release"), "Store")
        XCTAssertNil(split.profile(for: "Staging"))
    }

    // MARK: - CocoaPods

    func testACocoaPodsProjectGetsPodfileLinesNotAPackage() throws {
        let fixture = try workspace("OneSignalStyleExport")
        let podfile = try fixture.data("Podfile")
        let report = try fixture.apply(fixture.options())

        XCTAssertEqual(try fixture.data("Podfile"), podfile, "the Podfile is never edited")
        XCTAssertTrue(report.manual.contains { $0.contains("target 'Unity-iPhone' add pod 'OpenPush'") }, "\(report.manual)")
        XCTAssertTrue(report.manual.contains {
            $0.contains("target 'OneSignalNotificationServiceExtension' add pod 'OpenPushNSE'")
        })
        XCTAssertEqual(try fixture.scan().remotePackages, [])
        XCTAssertFalse(try fixture.text("Unity-iPhone.xcodeproj/project.pbxproj").contains("XCLocalSwiftPackageReference"))
    }

    // MARK: - Synchronized folders

    func testAnInfoPlistCreatedInASynchronizedFolderIsExcludedFromIt() throws {
        let fixture = try workspace("SynchronizedFolder")
        let report = try fixture.apply(fixture.options())

        let project = try fixture.scan()
        XCTAssertEqual(project.target(named: "Sync")?.primary?.infoPlistPath, "Sync/Info.plist")
        XCTAssertEqual(try fixture.plist("Sync/Info.plist")["UIBackgroundModes"] as? [String], ["remote-notification"])
        let pbxproj = try fixture.text("Sync.xcodeproj/project.pbxproj")
        XCTAssertTrue(pbxproj.contains("isa = PBXFileSystemSynchronizedBuildFileExceptionSet;"))
        XCTAssertTrue(pbxproj.contains("membershipExceptions = (\n\t\t\t\tInfo.plist,"), pbxproj)
        XCTAssertTrue(report.changes.contains { $0.hasPrefix("Sync: Sync/Info.plist excluded from its synchronized folder") })
        XCTAssertEqual(try fixture.apply(fixture.options { $0.timestamp = "again" }).changes, [])
    }

    func testOnlyThePbxprojIsWrittenInsideTheProject() throws {
        let fixture = try workspace("TwoGroups")
        let schemes = fixture.folder.appendingPathComponent("Duo.xcodeproj/xcshareddata/xcschemes")
        let userData = fixture.folder.appendingPathComponent("Duo.xcodeproj/xcuserdata/dev.xcuserdatad/xcdebugger")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        // Hand-formatted on purpose: a rewrite would normalise it.
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme LastUpgradeVersion = "1500"   version = "1.7">
              <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES"/>
            </Scheme>

            """.utf8).write(to: schemes.appendingPathComponent("Duo.xcscheme"))
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Bucket uuid = "X" type = "1"   version = "2.0"/>

            """.utf8).write(to: userData.appendingPathComponent("Breakpoints_v2.xcbkptlist"))
        let before = try fixture.snapshot().filter { $0.key.hasPrefix("Duo.xcodeproj/") && !$0.key.hasSuffix("project.pbxproj") }

        try fixture.apply(fixture.options())

        let after = try fixture.snapshot().filter { $0.key.hasPrefix("Duo.xcodeproj/") && !$0.key.hasSuffix("project.pbxproj") }
        XCTAssertEqual(after, before)
        XCTAssertNotEqual(try fixture.data("Duo.xcodeproj/project.pbxproj"),
                          try Data(contentsOf: FixtureWorkspace.fixtures.appendingPathComponent("TwoGroups/Duo.xcodeproj/project.pbxproj")))
    }

    // MARK: - Credentials

    /// The app writes its credentials as build-setting references.
    private func referencedCredentials() throws -> FixtureWorkspace {
        let fixture = try workspace("CustomExtension")
        let xcconfig = fixture.folder.appendingPathComponent("Support/Shared.xcconfig")
        try (String(contentsOf: xcconfig, encoding: .utf8) + "SHOP_SDK_KEY = shop-key\n")
            .write(to: xcconfig, atomically: true, encoding: .utf8)
        let info = fixture.folder.appendingPathComponent("Support/App-Info.plist")
        var plist = try fixture.plist("Support/App-Info.plist")
        plist["OpenPushAppID"] = "$(PRODUCT_BUNDLE_IDENTIFIER)"
        plist["OpenPushSDKKey"] = "$(SHOP_SDK_KEY)"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        return fixture
    }

    func testCredentialReferencesAreKeptWithoutOptions() throws {
        let fixture = try referencedCredentials()
        let before = try fixture.data("Support/App-Info.plist")
        try fixture.apply(fixture.options { $0.appID = nil; $0.sdkKey = nil })

        XCTAssertEqual(try fixture.data("Support/App-Info.plist"), before, "the app's references are left as written")
        let service = try fixture.plist("Support/RichPush-Info.plist")
        XCTAssertEqual(service["OpenPushSDKKey"] as? String, "$(SHOP_SDK_KEY)",
                       "the shared xcconfig gives the extension the same value, so the reference is copied")
        XCTAssertEqual(service["OpenPushAppID"] as? String, "com.example.shop",
                       "$(PRODUCT_BUNDLE_IDENTIFIER) is the extension's own id there, so the app's value is written out")
    }

    func testAnOptionMatchingAReferenceKeepsItAndADifferentOneSaysWhatItReplaces() throws {
        let fixture = try referencedCredentials()
        let report = try fixture.apply(fixture.options { $0.appID = "com.example.shop"; $0.sdkKey = "new-key" })

        let app = try fixture.plist("Support/App-Info.plist")
        XCTAssertEqual(app["OpenPushAppID"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)", "it already builds to the option")
        XCTAssertEqual(app["OpenPushSDKKey"] as? String, "new-key")
        XCTAssertTrue(report.changes.contains(
            "Support/App-Info.plist: OpenPushSDKKey replaces the reference $(SHOP_SDK_KEY) with the value given"),
            "\(report.changes)")
    }

    // MARK: - Vendored frameworks

    func testVendoredOpenPushFrameworksAreNotLinkedAgain() throws {
        let fixture = try workspace("VendoredFrameworks")
        let source = try fixture.data("NotificationService/NotificationService.swift")
        let report = try fixture.apply(fixture.options())

        let project = try fixture.scan()
        XCTAssertEqual(project.remotePackages, [])
        XCTAssertFalse(try fixture.text("Unity-iPhone.xcodeproj/project.pbxproj").contains("XCLocalSwiftPackageReference"))
        XCTAssertTrue(project.targets.allSatisfy { $0.packageProducts.isEmpty })
        XCTAssertTrue(report.kept.contains(
            "Unity-iPhone: OpenPush already comes from Frameworks/OpenPushNative/OpenPush.xcframework (linked to UnityFramework)"),
            "\(report.kept)")
        XCTAssertTrue(report.kept.contains(
            "NotificationService: OpenPushNSE already comes from Frameworks/OpenPushNative/OpenPushNSE.xcframework"))
        XCTAssertEqual(try fixture.data("NotificationService/NotificationService.swift"), source,
                       "an extension already on OpenPush's handler is not patched")
    }

    // MARK: - Package references

    func testAPackageSpelledDifferentlyIsTheSameReference() throws {
        let fixture = try workspace("TwoGroups")
        let canonical = "https://github.com/SuperTuned/openpush-ios.git"
        // The same repository in other case, with a trailing slash and no `.git`.
        let respelled = canonical.lowercased()
            .replacingOccurrences(of: "openpush-ios.git", with: "OpenPush-iOS/")
        try fixture.apply(fixture.options {
            $0.nseMode = .off
            $0.appGroup = "group.com.example.duo.push"
            $0.package = .remote(url: canonical, from: "1.2.2")
        })
        try fixture.apply(fixture.options {
            $0.nseMode = .share
            $0.timestamp = "again"
            $0.package = .remote(url: respelled, from: "1.2.2")
        })

        let project = try fixture.scan()
        XCTAssertEqual(project.remotePackages.count, 1, "\(project.remotePackages)")
        XCTAssertEqual(project.target(named: "DuoService")?.packageProducts.map(\.repositoryURL),
                       [canonical])
    }

    func testReportLinesAreNotRepeated() {
        var report = ApplyReport()
        report.changed("Duo: links OpenPush")
        report.changed("Duo: links OpenPush")
        XCTAssertEqual(report.changes, ["Duo: links OpenPush"])
    }

    func testAnAppGroupIsEscapedInTheSwiftSetupWrites() {
        let source = ExtensionTemplates.serviceExtension(className: "NotificationService",
                                                         appGroup: #"group.a"b\c"#, objcName: false)
        XCTAssertTrue(source.contains(#"options.appGroup = "group.a\"b\\c""#), source)
        XCTAssertEqual(SwiftLiteral.string("line\nbreak"), #""line\nbreak""#)
    }
}
