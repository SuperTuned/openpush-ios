import XCTest
@testable import OpenPushSetupKit

/// The four ways setup treats a notification service extension.
final class ServiceExtensionModeTests: XCTestCase {
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

    private func setting(_ project: ScannedProject, _ target: String, _ key: String,
                         _ configuration: String = "Release") -> String? {
        project.target(named: target)?.configurations.first { $0.name == configuration }?.settings[key]
    }

    // MARK: - Share

    func testShareKeepsEveryOriginalByteOutsideTheInsertedLines() throws {
        let fixture = try workspace("CustomExtension")
        let file = "RichPush/RichPushService.swift"
        let original = try fixture.text(file)
        let report = try fixture.apply(fixture.options())

        let patched = try fixture.text(file)
        // Walk the written file against the original: every original line must
        // appear, in order and unchanged, and every other line must be one of
        // the lines share adds — nothing else.
        let originalLines = original.components(separatedBy: "\n")
        var matched = 0
        var added: [String] = []
        for line in patched.components(separatedBy: "\n") {
            if matched < originalLines.count, line == originalLines[matched] { matched += 1 } else { added.append(line) }
        }
        XCTAssertEqual(matched, originalLines.count, "every original line is kept, in order")
        XCTAssertEqual(added, [
            "import OpenPushNSE",
            "    private let openPush = OpenPushNotificationServiceHandler(options: {",
            "        var options = OpenPushNotificationServiceHandler.Options()",
            "        options.appGroup = \"group.com.example.shop\"",
            "        return options",
            "    }())",
            "",
            "        if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }",
            "        if openPush.serviceExtensionTimeWillExpireIfHandling() { return }",
        ])

        XCTAssertTrue(patched.contains("import OpenPushNSE\n"))
        XCTAssertTrue(patched.contains("    private let openPush = OpenPushNotificationServiceHandler(options: {"))
        XCTAssertTrue(patched.contains("options.appGroup = \"group.com.example.shop\""))
        XCTAssertTrue(patched.contains(
            "        if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }\n"
            + "        self.contentHandler = contentHandler"), "the branch is the first line of didReceive")
        XCTAssertTrue(patched.contains(
            "        if openPush.serviceExtensionTimeWillExpireIfHandling() { return }\n"
            + "        if let contentHandler, let bestAttempt"))
        XCTAssertTrue(report.changes.contains("RichPush: links OpenPushNSE"))
        XCTAssertTrue(fixture.exists(".openpush/backup/test/\(file)"))

        XCTAssertEqual(try fixture.apply(fixture.options { $0.timestamp = "again" }).changes, [],
                       "a shared extension is not patched twice")
    }

    func testShareAddsTheExpiryOverrideWhenTheClassHasNone() throws {
        let fixture = try workspace("TwoGroups")
        try fixture.apply(fixture.options())

        let patched = try fixture.text("DuoService/NotificationService.swift")
        XCTAssertTrue(patched.contains("""
                override func serviceExtensionTimeWillExpire() {
                    if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
                    super.serviceExtensionTimeWillExpire()
                }
            """), "anything else keeps the system's expiry behaviour")
        XCTAssertTrue(patched.contains("if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }"))
    }

    func testSharePreservesCRLFAndRenamesAClashingProperty() {
        let source = "import UserNotifications\r\n\r\nclass Service: UNNotificationServiceExtension {\r\n"
            + "    let openPush = 1\r\n"
            + "    override func didReceive(_ req: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {\r\n"
            + "        handler(req.content)\r\n    }\r\n}\r\n"
        guard case .patched(let text, _) = SharePatcher(className: "Service", appGroup: "group.x").patch(source) else {
            return XCTFail()
        }
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ends in CRLF")
        XCTAssertTrue(text.contains("private let openPushHandler = "))
        XCTAssertTrue(text.contains("if openPushHandler.handleIfOpenPush(req, withContentHandler: handler) { return }"))
    }

    func testMissingAnchorsWriteAPatchAndChangeNothing() throws {
        let fixture = try workspace("CustomExtension")
        let file = fixture.folder.appendingPathComponent("RichPush/RichPushService.swift")
        // The opening brace on its own line is a shape the patcher will not guess at.
        let reshaped = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "final class RichPushService: UNNotificationServiceExtension {",
                                  with: "final class RichPushService: UNNotificationServiceExtension\n{")
        try reshaped.write(to: file, atomically: true, encoding: .utf8)
        let before = try fixture.snapshot()

        XCTAssertThrowsError(try fixture.apply(fixture.options())) { error in
            XCTAssertEqual(error as? SetupError, .shareAnchorsMissing(file: "RichPush/RichPushService.swift",
                                                                      patch: ".openpush/share.patch"))
        }
        let patch = try fixture.text(".openpush/share.patch")
        XCTAssertTrue(patch.contains("if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }"))
        XCTAssertEqual(try fixture.snapshot().filter { $0.key != ".openpush/share.patch" }, before)
    }

    // MARK: - Take over

    func testTakeOverKeepsTheClassNameBundleIDAndSigning() throws {
        let fixture = try workspace("OneSignalStyleExport")
        let file = "OneSignalNotificationServiceExtension/NotificationService.swift"
        let target = "OneSignalNotificationServiceExtension"
        let original = try fixture.scan()
        let entitlements = try fixture.data("\(target)/\(target).entitlements")
        let report = try fixture.apply(fixture.options())

        let rewritten = try fixture.text(file)
        XCTAssertTrue(rewritten.contains("final class NotificationService: UNNotificationServiceExtension"),
                      "the Info.plist names $(PRODUCT_MODULE_NAME).NotificationService, so the class keeps that name")
        XCTAssertTrue(rewritten.contains("options.appGroup = \"group.com.example.game.onesignal\""))
        XCTAssertFalse(rewritten.contains("import OneSignalExtension"))
        XCTAssertTrue(fixture.exists(".openpush/backup/test/\(file)"), "the original source is backed up")

        let applied = try fixture.scan()
        XCTAssertEqual(applied.target(named: target)?.primary?.infoPlist["NSExtension"]?["NSExtensionPrincipalClass"],
                       original.target(named: target)?.primary?.infoPlist["NSExtension"]?["NSExtensionPrincipalClass"])
        for key in ["PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_ENTITLEMENTS"] + SigningPolicy.protectedKeys {
            XCTAssertEqual(setting(applied, target, key), setting(original, target, key), key)
        }
        XCTAssertEqual(try fixture.data("\(target)/\(target).entitlements"), entitlements,
                       "the vendor's group is reused, so the entitlements are untouched")
        XCTAssertEqual(setting(applied, target, "IPHONEOS_DEPLOYMENT_TARGET"), "16.0")
        XCTAssertEqual(setting(applied, "Unity-iPhone", "IPHONEOS_DEPLOYMENT_TARGET"), "13.0", "the app is never raised")
        XCTAssertTrue(report.manual.contains(
            "Podfile: remove pod 'OneSignalXCFramework' from target '\(target)', then run pod install"), "\(report.manual)")
        XCTAssertTrue(report.manual.contains { $0.contains("Unity-iPhone targets iOS 13.0") })
    }

    func testTakeOverKeepsManualSigningPerConfiguration() throws {
        let fixture = try workspace("ManualSigning")
        let original = try fixture.scan()
        let entitlements = try fixture.data("BankService.entitlements")
        try fixture.apply(fixture.options { $0.nseMode = .takeOver })

        let applied = try fixture.scan()
        for configuration in ["Debug", "Release"] {
            for key in ["PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_ENTITLEMENTS"] + SigningPolicy.protectedKeys {
                XCTAssertEqual(setting(applied, "BankService", key, configuration),
                               setting(original, "BankService", key, configuration), "\(configuration) \(key)")
            }
        }
        XCTAssertEqual(setting(applied, "BankService", "PROVISIONING_PROFILE_SPECIFIER", "Release"), "Bank NSE AppStore")
        XCTAssertEqual(try fixture.data("BankService.entitlements"), entitlements)
        XCTAssertTrue(try fixture.text("BankService/NotificationService.swift")
            .contains("final class NotificationService: UNNotificationServiceExtension"))
    }

    func testTakeOverOfAnUnqualifiedPrincipalClassKeepsItsObjCName() throws {
        let fixture = try workspace("CustomExtension")
        try fixture.apply(fixture.options { $0.nseMode = .takeOver })

        let rewritten = try fixture.text("RichPush/RichPushService.swift")
        XCTAssertTrue(rewritten.contains("@objc(RichPushService)\nfinal class RichPushService: UNNotificationServiceExtension"),
                      "the Info.plist names RichPushService without a module")
    }

    func testTakeOverUnlinksTheVendorsPackageProduct() throws {
        /// Stands in for a vendor whose extension product is the fixture's package.
        struct Vendor: VendorFingerprint {
            let vendor = "example"
            func claims(_ finding: SetupFinding, in project: ScannedProject) -> Bool {
                finding.kind == .serviceExtension && finding.id == "RichPush"
            }
            func isExtensionDependency(_ name: String) -> Bool { name == "RichMedia" }
        }
        let fixture = try workspace("CustomExtension")
        let report = try fixture.apply(fixture.options(), scanner: ProjectScanner(fingerprints: [Vendor()]))

        XCTAssertTrue(report.changes.contains("RichPush: no longer links RichMedia"), "\(report.changes)")
        let products = try fixture.scan().target(named: "RichPush")?.packageProducts.map(\.name)
        XCTAssertEqual(products, ["OpenPushNSE"])
        XCTAssertTrue(try fixture.text("RichPush/RichPushService.swift").contains("@objc(RichPushService)"),
                      "a vendor's extension is taken over by default")
    }

    // MARK: - Objective-C

    func testTakeOverRefusesAnObjectiveCExtension() throws {
        let fixture = try workspace("ObjCExtension")
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.nseMode = .takeOver })) { error in
            XCTAssertEqual(error as? SetupError, .takeOverNeedsSwift(file: "LegacyService/NotificationService.m"))
        }
        XCTAssertEqual(try fixture.snapshot(), before, "no Swift is ever written into a .m")
    }

    func testShareOfAnObjectiveCExtensionWritesTheStepsAndStops() throws {
        let fixture = try workspace("ObjCExtension")
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.apply(fixture.options())) { error in
            XCTAssertEqual(error as? SetupError, .objectiveCExtension(file: "LegacyService/NotificationService.m",
                                                                      patch: ".openpush/share.patch"))
        }
        let patch = try fixture.text(".openpush/share.patch")
        XCTAssertTrue(patch.contains("final class OpenPushNotificationService: NotificationService {"))
        XCTAssertTrue(patch.contains("super.didReceive(request, withContentHandler: contentHandler)"))
        XCTAssertTrue(patch.contains("options.appGroup = \"group.com.example.legacy\""))
        XCTAssertTrue(patch.contains("In LegacyService-Info.plist, set NSExtensionPrincipalClass"))
        XCTAssertEqual(try fixture.snapshot().filter { $0.key != ".openpush/share.patch" }, before)
    }

    // MARK: - Inject

    func testInjectCreatesTheExtensionWithTheAppsSigning() throws {
        let fixture = try workspace("GroupWithoutExtension")
        try fixture.apply(fixture.options { $0.appGroup = "group.com.example.solo" })

        let project = try fixture.scan()
        let created = try XCTUnwrap(project.target(named: "OpenPushNotificationService"))
        XCTAssertEqual(created.role, .serviceExtension)
        XCTAssertEqual(created.embeddedIn, ["Solo"])
        XCTAssertEqual(created.primary?.bundleID, "com.example.solo.OpenPushNotificationService")
        XCTAssertEqual(created.primary?.settings["IPHONEOS_DEPLOYMENT_TARGET"], "16.0")
        XCTAssertEqual(created.packageProducts.map(\.name), ["OpenPushNSE"])
        XCTAssertEqual(created.primary?.entitlements["com.apple.security.application-groups"]?.strings,
                       ["group.com.example.solo"])
        XCTAssertEqual(created.primary?.infoPlist["OpenPushAppID"]?.stringValue, "app-1")
        let source = try fixture.text("OpenPushNotificationService/NotificationService.swift")
        XCTAssertTrue(source.contains("options.appGroup = \"group.com.example.solo\""))
        XCTAssertEqual(try fixture.apply(fixture.options { $0.timestamp = "again" }).changes, [])
    }

    func testInjectIsRefusedWhenAnExtensionExists() throws {
        let fixture = try workspace("ManualSigning")
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.nseMode = .inject })) { error in
            XCTAssertEqual(error as? SetupError, .injectWithExistingExtension(["BankService"]))
        }
        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.nseBundleID = "com.example.bank.Other" }))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testInjectUnderManualSigningNeedsAProfile() throws {
        let fixture = try workspace("ManualSigningAppOnly")
        let before = try fixture.snapshot()
        // A group on the app alone is never guessed for a new extension either.
        let group = "group.com.example.vault"
        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.nseMode = .inject; $0.appGroup = group })) { error in
            XCTAssertEqual(error as? SetupError, .manualSigningNeedsProfile(
                target: "OpenPushNotificationService", configurations: ["Debug", "Release"], flag: "--nse-profile"))
        }
        XCTAssertEqual(try fixture.snapshot(), before)

        try fixture.apply(fixture.options {
            $0.nseMode = .inject
            $0.appGroup = group
            $0.nseProfile = ProvisioningProfiles("Vault OpenPush NSE")
        })
        let project = try fixture.scan()
        XCTAssertEqual(setting(project, "OpenPushNotificationService", "PROVISIONING_PROFILE_SPECIFIER", "Debug"),
                       "Vault OpenPush NSE")
        XCTAssertEqual(setting(project, "OpenPushNotificationService", "CODE_SIGN_STYLE", "Release"), "Manual")
        XCTAssertEqual(setting(project, "OpenPushNotificationService", "CODE_SIGN_IDENTITY", "Debug"),
                       setting(project, "Vault", "CODE_SIGN_IDENTITY", "Debug"))
        XCTAssertEqual(setting(project, "Vault", "PROVISIONING_PROFILE_SPECIFIER", "Release"), "Vault AppStore",
                       "the app's own profile is kept")
    }

    // MARK: - Off

    func testOffLeavesTheExtensionAloneAndSaysWhatIsLost() throws {
        let fixture = try workspace("CustomExtension")
        let source = try fixture.data("RichPush/RichPushService.swift")
        let entitlements = try fixture.data("Support/RichPush.entitlements")
        let report = try fixture.apply(fixture.options { $0.nseMode = .off; $0.appGroup = "group.com.example.shop" })

        XCTAssertEqual(try fixture.data("RichPush/RichPushService.swift"), source)
        XCTAssertEqual(try fixture.data("Support/RichPush.entitlements"), entitlements)
        XCTAssertFalse(try fixture.plist("Support/RichPush-Info.plist").keys.contains("OpenPushAppID"))
        XCTAssertFalse(try fixture.scan().target(named: "RichPush")?.packageProducts.map(\.name).contains("OpenPushNSE") ?? true)
        XCTAssertTrue(report.notes.contains { $0.contains("no images or action buttons") })
    }
}
