import XCTest

final class OpenPushPrivacyManifestTests: XCTestCase {
    private let targets = ["OpenPush", "OpenPushCore", "OpenPushNSE",
                           "OpenPushLiveActivities", "OpenPushOneSignal", "OpenPushVoIP"]
    private let userDefaultsTargets: Set<String> = ["OpenPush", "OpenPushCore", "OpenPushNSE"]
    /// These read the App Group suite (`UserDefaults(suiteName:)`), which needs
    /// the App Group reason on top of the app-only one.
    private let appGroupTargets: Set<String> = ["OpenPushCore", "OpenPushNSE"]
    /// Every product but the registering one declares no collected data types.
    private let noCollectionTargets = ["OpenPushCore", "OpenPushNSE",
                                       "OpenPushLiveActivities", "OpenPushOneSignal",
                                       "OpenPushVoIP"]
    /// These touch no required-reason API at all.
    private let noAccessedAPITargets = ["OpenPushLiveActivities", "OpenPushOneSignal",
                                        "OpenPushVoIP"]

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func manifest(for target: String) throws -> [String: Any] {
        let url = packageRoot.appendingPathComponent("Sources/\(target)/Resources/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
    }

    /// The text of the `.target(name: "<target>" ... )` declaration, paren-balanced.
    private func targetDeclaration(_ target: String, in manifestSource: String) -> String? {
        let needle = ".target(name: \"\(target)\""
        guard let match = manifestSource.range(of: needle) else { return nil }
        guard let open = manifestSource[match.lowerBound...].firstIndex(of: "(") else { return nil }
        var depth = 0
        var index = open
        while index < manifestSource.endIndex {
            let character = manifestSource[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    return String(manifestSource[match.lowerBound...index])
                }
            }
            index = manifestSource.index(after: index)
        }
        return nil
    }

    func testEveryTargetDeclaresItsManifestAsAResource() throws {
        let source = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"),
                                encoding: .utf8)
        for target in targets {
            let declaration = try XCTUnwrap(targetDeclaration(target, in: source),
                                            "no .target declaration for \(target)")
            XCTAssertTrue(declaration.contains(#".copy("Resources/PrivacyInfo.xcprivacy")"#),
                          "\(target) does not ship its privacy manifest as a resource")
        }
    }

    func testEveryProductShipsAManifestThatDeclaresNoTracking() throws {
        for target in targets {
            let plist = try manifest(for: target)
            XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false, target)
            XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, target)
            XCTAssertNotNil(plist["NSPrivacyCollectedDataTypes"] as? [Any], target)
            XCTAssertNotNil(plist["NSPrivacyAccessedAPITypes"] as? [Any], target)
        }
    }

    func testTargetsThatReadUserDefaultsDeclareTheReason() throws {
        for target in userDefaultsTargets {
            let plist = try manifest(for: target)
            let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            let defaults = apis.first {
                $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
            }
            let reasons = try XCTUnwrap(defaults?["NSPrivacyAccessedAPITypeReasons"] as? [String])
            let expected: Set<String> = appGroupTargets.contains(target)
                ? ["CA92.1", "1C8F.1"] : ["CA92.1"]
            XCTAssertEqual(Set(reasons), expected, target)
        }
    }

    /// Every target whose sources open the App Group suite must declare 1C8F.1,
    /// so adding a suite read elsewhere fails here instead of at review.
    func testEveryTargetThatOpensTheAppGroupSuiteDeclaresTheAppGroupReason() throws {
        for target in targets {
            guard try sources(of: target).contains("UserDefaults(suiteName:") else { continue }
            let plist = try manifest(for: target)
            let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            let reasons = apis.first {
                $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
            }?["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            XCTAssertTrue(reasons.contains("1C8F.1"), "\(target) reads the App Group suite")
        }
    }

    /// `attributesOfItem` also returns file timestamps, a required-reason API the
    /// manifests do not declare; the size is read as a resource value instead.
    func testNoTargetUsesTheFileTimestampAPIs() throws {
        let timestampCalls = ["attributesOfItem(", ".creationDate", ".modificationDate",
                              "contentModificationDateKey", "creationDateKey"]
        for target in targets {
            let source = try sources(of: target)
            for call in timestampCalls {
                XCTAssertFalse(source.contains(call), "\(target) calls \(call)")
            }
        }
    }

    private func sources(of target: String) throws -> String {
        let directory = packageRoot.appendingPathComponent("Sources/\(target)")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory,
                                                                  includingPropertiesForKeys: nil))
        var text = ""
        for case let file as URL in files where file.pathExtension == "swift" {
            text += try String(contentsOf: file, encoding: .utf8)
        }
        return text
    }

    func testProductsThatCollectNothingDeclareAnEmptyList() throws {
        for target in noCollectionTargets {
            let plist = try manifest(for: target)
            XCTAssertEqual(try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [Any]).count, 0,
                           "\(target) must collect nothing")
        }
    }

    func testProductsThatTouchNoRequiredReasonAPIDeclareAnEmptyList() throws {
        for target in noAccessedAPITargets {
            let plist = try manifest(for: target)
            XCTAssertEqual(try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [Any]).count, 0,
                           "\(target) must declare no accessed API")
        }
    }

    /// Device and user ids from registration; email addresses and phone numbers
    /// from the address subscriptions; product interaction from custom events,
    /// sessions, clicks and in-app message actions.
    func testTheRegisteringProductDeclaresEverythingItCollects() throws {
        let plist = try manifest(for: "OpenPush")
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(types.count, Set(types).count, "a data type is declared twice")
        XCTAssertEqual(Set(types), ["NSPrivacyCollectedDataTypeDeviceID",
                                    "NSPrivacyCollectedDataTypeUserID",
                                    "NSPrivacyCollectedDataTypeEmailAddress",
                                    "NSPrivacyCollectedDataTypePhoneNumber",
                                    "NSPrivacyCollectedDataTypeProductInteraction"])
        for entry in collected {
            let name = entry["NSPrivacyCollectedDataType"] as? String ?? "unknown"
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, name)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, name)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"], name)
        }
    }
}
