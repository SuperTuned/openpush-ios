import XCTest
@testable import OpenPushSetupKit

/// The share insertion's anchors, on sources shaped to mislead it.
final class SharePatcherTests: XCTestCase {
    private let patcher = SharePatcher(className: "Service", appGroup: "group.x")

    private func patched(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .patched(let text, _) = patcher.patch(source) else {
            XCTFail("expected a patch, got \(patcher.patch(source))", file: file, line: line)
            return nil
        }
        return text
    }

    private let receive = """
            override func didReceive(_ request: UNNotificationRequest,
                                     withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
                contentHandler(request.content)
            }
        """

    func testTheImportGoesAfterTheLastTopLevelImportNotInsideAnIfBlock() throws {
        let text = try XCTUnwrap(patched("""
            import UserNotifications
            #if canImport(Analytics)
            import Analytics
            #endif

            final class Service: UNNotificationServiceExtension {
            \(receive)
            }
            """))
        XCTAssertTrue(text.hasPrefix("import UserNotifications\nimport OpenPushNSE\n#if canImport(Analytics)\n"), text)
    }

    func testOnlyThePrincipalClassBodyIsSearched() {
        let source = """
            import UserNotifications

            final class Service: UNNotificationServiceExtension {
                override func serviceExtensionTimeWillExpire() {}
            }

            final class Other: UNNotificationServiceExtension {
            \(receive)
            }
            """
        guard case .anchorsMissing(let missing) = patcher.patch(source) else {
            return XCTFail("a didReceive in another class is not the principal class's")
        }
        XCTAssertTrue(missing.contains { $0.contains("didReceive") }, "\(missing)")
    }

    func testASpaceBeforeTheExpiryParenthesesIsStillTheOverride() throws {
        let text = try XCTUnwrap(patched("""
            import UserNotifications

            final class Service: UNNotificationServiceExtension {
            \(receive)

                override func serviceExtensionTimeWillExpire () {
                    print("expiring")
                }
            }
            """))
        XCTAssertTrue(text.contains("""
                override func serviceExtensionTimeWillExpire () {
                    if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
                    print("expiring")
            """), text)
        XCTAssertEqual(text.components(separatedBy: "func serviceExtensionTimeWillExpire").count, 2,
                       "no second override is added")
    }

    func testConditionalCompilationInTheClassStops() {
        let source = """
            import UserNotifications

            final class Service: UNNotificationServiceExtension {
            #if DEBUG
            \(receive)
            #else
            \(receive)
            #endif
            }
            """
        XCTAssertEqual(patcher.patch(source), .anchorsMissing(["#if blocks inside class Service"]))
    }

    func testBracesInStringsAndCommentsDoNotEndTheClass() throws {
        let text = try XCTUnwrap(patched("""
            import UserNotifications

            final class Service: UNNotificationServiceExtension {
                let marker = "}" // }
            \(receive)
            }
            """))
        XCTAssertTrue(text.contains("if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }"))
    }
}
