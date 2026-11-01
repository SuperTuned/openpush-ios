#if canImport(UIKit)
import UIKit
import XCTest
@testable import OpenPush

/// Presenting `url_target: "webview"`'s `SFSafariViewController` on the top view
/// controller of the key window would fail: while a message is up, that is the
/// overlay's own `IamHostController`. The action that opened the link usually
/// closes the message too, and the teardown drops the overlay window with
/// whatever it was presenting: the person taps the link and nothing appears.
///
/// These tests pin the rule that avoids it: the presenting controller is always
/// one the app owns and outlives the message, and never the overlay host.
@MainActor
final class OpenPushInAppBrowserPresentationTests: XCTestCase {
    private static let frame = CGRect(x: 0, y: 0, width: 390, height: 844)

    /// Stands in for a controller that is already showing something of the
    /// app's own. Presenting for real needs a window in a live scene, which a
    /// logic-test bundle has no business arranging; the walk under test only
    /// ever reads `presentedViewController`, so this says the same thing
    /// without the UIKit machinery.
    private final class ShowingController: UIViewController {
        let modal: UIViewController
        init(showing modal: UIViewController) {
            self.modal = modal
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override var presentedViewController: UIViewController? { modal }
    }

    private func overlayWindow() -> IamOverlayWindow {
        let window = IamOverlayWindow(frame: Self.frame)
        window.rootViewController = IamHostController(overlay: IamOverlayView())
        return window
    }

    private func appWindow(_ root: UIViewController) -> UIWindow {
        let window = UIWindow(frame: Self.frame)
        window.rootViewController = root
        return window
    }

    func testTheSheetIsPresentedOnTheWindowTheAppHadBeforeTheMessage() {
        let root = UIViewController()
        let app = appWindow(root)
        let overlay = overlayWindow()

        let presenter = IamBrowser.presentingController(preferring: app,
                                                        among: [overlay, app])

        XCTAssertTrue(presenter === root,
                      "the app's own root controller is what holds the sheet")
        XCTAssertFalse(presenter is IamHostController,
                       "the overlay host is torn down with the message")
    }

    /// The overlay is key and on top while the message is up, so "the top view
    /// controller of the key window" is exactly the wrong answer. Nothing to
    /// present on is better than presenting on something about to be released.
    func testTheOverlayHostIsNeverTheAnswerEvenWhenItIsTheOnlyWindowLeft() {
        XCTAssertNil(IamBrowser.presentingController(preferring: nil,
                                                     among: [overlayWindow()]),
                     "no app window means no sheet, not a sheet on the overlay")
    }

    func testAModalTheAppIsAlreadyShowingIsWhatPresentsTheSheet() {
        let modal = UIViewController()
        let app = appWindow(ShowingController(showing: modal))

        let presenter = IamBrowser.presentingController(preferring: app,
                                                        among: [overlayWindow(), app])

        XCTAssertTrue(presenter === modal,
                      "presenting on a controller that is already covered shows nothing")
    }

    /// The window the message recorded may be gone by the time the link is
    /// tapped. The fallback still has to skip the overlay.
    func testAnAppWindowIsFoundWhenTheRecordedOneIsGone() {
        let root = UIViewController()
        let app = appWindow(root)

        let presenter = IamBrowser.presentingController(preferring: nil,
                                                        among: [overlayWindow(), app])

        XCTAssertTrue(presenter === root)
    }

    /// An overlay window that somehow became key must not win the key-window
    /// fallback over an app window that is merely not key.
    func testAKeyOverlayDoesNotBeatAnAppWindowThatIsNotKey() {
        let root = UIViewController()
        let app = appWindow(root)

        let presenter = IamBrowser.presentingController(preferring: nil,
                                                        among: [overlayWindow(), app,
                                                                overlayWindow()])

        XCTAssertTrue(presenter === root)
    }

    /// A message's links are content the server hands down, and
    /// `UIApplication.open` will open whatever the device has a handler for —
    /// `tel:` dials, `sms:` composes, a custom scheme launches another app.
    /// A campaign gets the web and nothing else. `SFSafariViewController` traps
    /// on a non-web URL outright, so the same rule guards both paths.
    func testOnlyWebLinksAreOpened() {
        for allowed in ["https://example.com/sale", "http://example.com",
                        "HTTPS://example.com"] {
            XCTAssertTrue(IamBrowser.isOpenable(URL(string: allowed)!), allowed)
        }
        for refused in ["tel:+15550100", "sms:+15550100", "mailto:a@example.com",
                        "file:///etc/passwd", "someapp://buy?sku=1", "javascript:alert(1)"] {
            XCTAssertFalse(IamBrowser.isOpenable(URL(string: refused)!), refused)
        }
    }
}
#endif
