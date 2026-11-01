#if canImport(UIKit) && canImport(WebKit)
import XCTest
import WebKit
@testable import OpenPush

final class OpenPushInAppCloseControlTests: XCTestCase {
    @MainActor
    func testCloseControlIsMovedToTheNonScrollingRootAtDocumentEnd() {
        let controller = WKUserContentController()

        IamCloseControl.install(in: controller)

        XCTAssertEqual(controller.userScripts.count, 1)
        let script = controller.userScripts[0]
        XCTAssertEqual(script.injectionTime, .atDocumentEnd)
        XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertTrue(script.source.contains(".op-card > .op-close"))
        XCTAssertTrue(script.source.contains("root.appendChild(close)"))
        XCTAssertTrue(script.source.contains("data-op-close-pinned"))
    }
}
#endif
