import XCTest
@testable import OpenPushSetupKit

/// One scan per committed fixture, each asserting the signals that fixture
/// exists to carry. The fixtures are generated once with XcodeGen
/// (`Tests/Fixtures/regenerate.sh`) and read here as Xcode would.
final class FixtureScanTests: XCTestCase {
    private func scan(_ fixture: String) throws -> [SetupFinding] {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixture)")
        return try ProjectScanner().scan(ProjectLocator.locate(folder.path))
    }

    private func only(_ findings: [SetupFinding], _ kind: SetupFinding.Kind,
                      file: StaticString = #filePath, line: UInt = #line) throws -> SetupFinding {
        let matching = findings.filter { $0.kind == kind }
        XCTAssertEqual(matching.count, 1, "\(kind): \(matching.map(\.id))", file: file, line: line)
        return try XCTUnwrap(matching.first, file: file, line: line)
    }

    private func groups(_ findings: [SetupFinding], on target: String) -> [String] {
        findings.filter { $0.kind == .appGroup && $0.target == target }.map(\.id).sorted()
    }

    func testVendorTemplateExportIsNamedAndEverythingElseStaysGeneric() throws {
        let found = try scan("OneSignalStyleExport")

        let service = try only(found, .serviceExtension)
        XCTAssertEqual(service.id, "OneSignalNotificationServiceExtension")
        XCTAssertEqual(service.vendor, "onesignal")
        XCTAssertEqual(service.details["bundle_id"]?.stringValue,
                       "com.example.game.OneSignalNotificationServiceExtension")
        XCTAssertEqual(service.details["principal_class"]?.stringValue,
                       "OneSignalNotificationServiceExtension.NotificationService",
                       "$(PRODUCT_MODULE_NAME) expands to the target's module")
        XCTAssertEqual(service.details["principal_class_file"]?.stringValue,
                       "OneSignalNotificationServiceExtension/NotificationService.swift")
        XCTAssertEqual(service.details["embedded_in"]?.strings, ["Unity-iPhone"])

        let appGroups = found.filter { $0.kind == .appGroup }
        XCTAssertEqual(appGroups.count, 2)
        XCTAssertTrue(appGroups.allSatisfy { $0.id == "group.com.example.game.onesignal" && $0.vendor == "onesignal" })

        let pod = try only(found, .pushSDK)
        XCTAssertEqual(pod.id, "OneSignalXCFramework")
        XCTAssertEqual(pod.vendor, "onesignal")
        XCTAssertFalse(pod.editable, "a Podfile is printed, never rewritten")
        XCTAssertEqual(pod.details["version"]?.stringValue, "5.2.9")
        XCTAssertEqual(pod.details["targets"]?.strings,
                       ["Unity-iPhone", "OneSignalNotificationServiceExtension"])

        XCTAssertNil(try only(found, .apsEnvironment).vendor)
        XCTAssertNil(try only(found, .backgroundMode).vendor)
    }

    func testACustomExtensionIsGenericAndItsGroupsExpandThroughTheXCConfig() throws {
        let found = try scan("CustomExtension")

        let service = try only(found, .serviceExtension)
        XCTAssertEqual(service.id, "RichPush")
        XCTAssertNil(service.vendor, "studio-written code matches no fingerprint")
        XCTAssertEqual(service.details["principal_class"]?.stringValue, "RichPushService")
        XCTAssertEqual(service.details["principal_class_file"]?.stringValue, "RichPush/RichPushService.swift")
        XCTAssertEqual(service.details["imports"]?.strings, ["UserNotifications", "RichMedia"])
        XCTAssertEqual(service.details["packages"]?.strings, ["RichMedia"])

        XCTAssertEqual(groups(found, on: "Shop"), ["group.com.example.shop"])
        XCTAssertEqual(groups(found, on: "RichPush"), ["group.com.example.shop"])
        let keychain = found.filter { $0.kind == .keychainGroup }
        XCTAssertEqual(Set(keychain.compactMap(\.target)), ["Shop", "RichPush"])
        XCTAssertTrue(keychain.allSatisfy { $0.id == "$(AppIdentifierPrefix)com.example.shop.shared" },
                      "the xcconfig variable expands; the signing-time prefix is kept as written")

        let package = try only(found, .pushSDK)
        XCTAssertEqual(package.id, "rich-media-ios")
        XCTAssertNil(package.vendor)
        XCTAssertEqual(package.details["version"]?.stringValue, "2.1.4", "pinned in Package.resolved")
        XCTAssertEqual(package.details["targets"]?.strings, ["RichPush"])
        XCTAssertEqual(found.filter { $0.vendor != nil }, [])
    }

    func testAGroupWithoutAnExtensionIsStillFound() throws {
        let found = try scan("GroupWithoutExtension")

        XCTAssertEqual(found.filter { $0.kind == .serviceExtension }, [])
        let group = try only(found, .appGroup)
        XCTAssertEqual(group.id, "group.com.example.solo")
        XCTAssertEqual(group.source, "Solo.entitlements")
        XCTAssertEqual(group.details["target_role"]?.stringValue, "app")
        XCTAssertEqual(group.details["configurations"]?.strings, ["Debug", "Release"])
        XCTAssertEqual(try only(found, .apsEnvironment).id, "development")
        XCTAssertEqual(found.filter { $0.kind == .backgroundMode }, [])
    }

    func testTwoGroupsShowWhichOneTheExtensionShares() throws {
        let found = try scan("TwoGroups")

        XCTAssertEqual(groups(found, on: "Duo"), ["group.com.example.duo.push", "group.com.example.duo.widgets"])
        XCTAssertEqual(groups(found, on: "DuoService"), ["group.com.example.duo.push"])
        XCTAssertEqual(try only(found, .serviceExtension).id, "DuoService")
    }

    func testAWidgetAndAContentExtensionAreClassifiedApart() throws {
        let found = try scan("WidgetAndContent")

        XCTAssertEqual(found.filter { $0.kind == .serviceExtension }, [])
        XCTAssertEqual(try only(found, .widgetExtension).id, "GalleryWidget")
        let content = try only(found, .contentExtension)
        XCTAssertEqual(content.id, "GalleryContent")
        XCTAssertEqual(content.details["categories"]?.strings, ["gallery.preview"],
                       "the host's categories are recorded so setup never overwrites them")
        XCTAssertEqual(content.details["embedded_in"]?.strings, ["Gallery"])
    }

    func testAManualSigningAppWithoutAnExtension() throws {
        let found = try scan("ManualSigningAppOnly")
        XCTAssertEqual(found.filter { $0.kind == .serviceExtension }, [])
        XCTAssertEqual(groups(found, on: "Vault"), ["group.com.example.vault"])
        XCTAssertEqual(try only(found, .apsEnvironment).id, "production")
    }

    func testManualSigningIsReadPerConfiguration() throws {
        let found = try scan("ManualSigning")

        let service = try only(found, .serviceExtension)
        let debug = try XCTUnwrap(service.details["configurations"]?["Debug"])
        let release = try XCTUnwrap(service.details["configurations"]?["Release"])
        XCTAssertEqual(debug["code_sign_style"]?.stringValue, "Manual")
        XCTAssertEqual(debug["provisioning_profile_specifier"]?.stringValue, "Bank NSE Development")
        XCTAssertEqual(debug["code_sign_identity"]?.stringValue, "Apple Development")
        XCTAssertEqual(release["provisioning_profile_specifier"]?.stringValue, "Bank NSE AppStore")
        XCTAssertEqual(release["code_sign_identity"]?.stringValue, "Apple Distribution")
        XCTAssertEqual(release["development_team"]?.stringValue, "ABCDE12345")

        let environments = found.filter { $0.kind == .apsEnvironment }
        XCTAssertEqual(environments.map(\.id), ["development", "production"])
        XCTAssertEqual(environments.map { $0.details["configurations"]?.strings ?? [] }, [["Debug"], ["Release"]],
                       "each configuration's own entitlements file is read")
        XCTAssertEqual(groups(found, on: "Bank"), ["group.com.example.bank", "group.com.example.bank"])
    }

    func testAGeneratedInfoPlistIsMergedWithItsBuildSettings() throws {
        let found = try scan("GeneratedInfoPlist")

        let service = try only(found, .serviceExtension)
        XCTAssertEqual(service.id, "NotesService")
        XCTAssertEqual(service.details["generated_info_plist"]?.boolValue, true)
        XCTAssertEqual(service.details["display_name"]?.stringValue, "NotesService",
                       "INFOPLIST_KEY_* settings are part of a generated Info.plist")
        XCTAssertEqual(service.details["principal_class"]?.stringValue, "NotesService.NotificationService")
        XCTAssertEqual(service.details["principal_class_file"]?.stringValue,
                       "Notes/NotesService/NotificationService.swift")
        XCTAssertEqual(try only(found, .backgroundMode).target, "Notes")
        XCTAssertEqual(groups(found, on: "NotesService"), ["group.com.example.notes"])
    }

    func testASynchronizedFolderListsItsSources() throws {
        let project = try XcodeProjectLoader().load(
            ProjectLocator.locate(FixtureWorkspace.fixtures.appendingPathComponent("SynchronizedFolder").path))
        XCTAssertEqual(project.target(named: "Sync")?.sources, ["Sync/AppDelegate.swift"])
        XCTAssertNil(project.target(named: "Sync")?.primary?.infoPlistPath, "the Info.plist is fully generated")
        XCTAssertEqual(try scan("SynchronizedFolder"), [], "nothing push-related yet")
    }

    func testAnObjectiveCExtensionNamesItsImplementationFile() throws {
        let service = try only(scan("ObjCExtension"), .serviceExtension)
        XCTAssertEqual(service.id, "LegacyService")
        XCTAssertNil(service.vendor)
        XCTAssertEqual(service.details["principal_class"]?.stringValue, "NotificationService")
        XCTAssertEqual(service.details["principal_class_file"]?.stringValue, "LegacyService/NotificationService.m")
        XCTAssertEqual(service.details["imports"]?.strings, [], "the .m imports only its own header")
    }

    func testVendoredOpenPushFrameworksAreAnExistingInstall() throws {
        let found = try scan("VendoredFrameworks")
        let sdks = found.filter { $0.kind == .pushSDK }
        XCTAssertEqual(sdks.map(\.id), ["OpenPush", "OpenPushCore", "OpenPushNSE"])
        XCTAssertTrue(sdks.allSatisfy { $0.details["manager"]?.stringValue == "framework"
            && $0.details["openpush"]?.boolValue == true && $0.vendor == nil })
        XCTAssertEqual(sdks.first { $0.id == "OpenPush" }?.details["path"]?.stringValue,
                       "Frameworks/OpenPushNative/OpenPush.xcframework")
        XCTAssertEqual(sdks.first { $0.id == "OpenPushCore" }?.details["targets"]?.strings,
                       ["NotificationService", "UnityFramework"], "in the project's own target order")
    }
}
