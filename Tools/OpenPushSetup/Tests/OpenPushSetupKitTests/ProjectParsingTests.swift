import XCTest
@testable import OpenPushSetupKit

final class ProjectParsingTests: XCTestCase {
    func testSettingsLayerInheritAndExpand() {
        let settings = ResolvedBuildSettings(layers: [
            ["GROUP_BASE": "group.com.example", "FLAGS": "-a"],
            ["FLAGS": "$(inherited) -b", "GROUP": "$(GROUP_BASE).$(TARGET_NAME:lower)"],
        ], defaults: ["TARGET_NAME": "My App", "PRODUCT_NAME": "$(TARGET_NAME)",
                      "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)"])

        XCTAssertEqual(settings["FLAGS"], "-a -b")
        XCTAssertEqual(settings["GROUP"], "group.com.example.my app")
        XCTAssertEqual(settings["PRODUCT_MODULE_NAME"], "My_App")
        XCTAssertEqual(settings.expand("${GROUP_BASE}.$(UNKNOWN)"), "group.com.example.$(UNKNOWN)",
                       "an undefined variable is left as written")
    }

    func testXCConfigIncludesOptionalIncludesAndConditions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xcconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "APP_GROUP = group.base\nTEAM = BASE".write(to: folder.appendingPathComponent("Base.xcconfig"),
                                                       atomically: true, encoding: .utf8)
        try """
            #include "Base.xcconfig"
            APP_GROUP = $(inherited).main // a comment
            TEAM[sdk=iphonesimulator*] = SIM
            #include? "Missing.xcconfig"
            """.write(to: folder.appendingPathComponent("App.xcconfig"), atomically: true, encoding: .utf8)

        let values = XCConfigFile.settings(at: folder.appendingPathComponent("App.xcconfig"))
        XCTAssertEqual(values["APP_GROUP"], "group.base.main")
        XCTAssertEqual(values["TEAM"], "BASE", "conditional assignments are not applied")
    }

    func testPodfileTargetsAndNestedBlocks() {
        let podfile = Podfile(text: """
            platform :ios, '15.0'
            target 'App' do
              use_frameworks!
              pod 'Analytics', '~> 4.0'  # comment
              target 'AppTests' do
                inherit! :search_paths
              end
            end
            target 'NSE' do
              pod 'Analytics/Core'
              pod "Rich"
            end
            post_install do |installer|
            end
            """)
        XCTAssertEqual(podfile.declarations, [
            .init(name: "Analytics", targets: ["App", "NSE"], requirement: "~> 4.0"),
            .init(name: "Rich", targets: ["NSE"], requirement: nil),
        ])
    }

    func testPodfileLockVersionsAndSubspecs() {
        let lock = PodfileLock(text: """
            PODS:
              - Analytics (4.1.0):
                - Analytics/Core (= 4.1.0)
              - Analytics/Core (4.1.0)
              - Rich (1.0.0)

            DEPENDENCIES:
              - Analytics (~> 4.0)
            """)
        XCTAssertEqual(lock.pods, [
            .init(name: "Analytics", version: "4.1.0", subspecs: ["Core"]),
            .init(name: "Rich", version: "1.0.0", subspecs: []),
        ])
    }

    func testSourceImports() {
        XCTAssertEqual(SourceInspector.imports(in: """
            @preconcurrency import UserNotifications
            import class Vendor.Thing
            @import Legacy;
            #import <Kit/Kit.h>
            // import Commented
            let x = 1
            """), ["UserNotifications", "Vendor", "Legacy", "Kit"])
    }
}
