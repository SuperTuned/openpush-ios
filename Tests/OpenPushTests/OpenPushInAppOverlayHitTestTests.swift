#if canImport(UIKit)
import UIKit
import XCTest
@testable import OpenPush

/// The overlay is a window of its own, sitting above the app's for as long as a
/// message is up. That makes hit testing the whole of the message's manners: a
/// banner has to decline every touch outside the strip it actually draws, or it
/// swallows the app underneath it, and a centred message has to swallow them, or
/// it is not modal at all.
///
/// Two levels have to agree. `IamOverlayView` decides, and `IamOverlayWindow`
/// carries the decision out — `UIWindow` answers with itself where its root view
/// returned nil, and UIKit reads that as a hit rather than passing the touch on,
/// so the window has to turn that one answer back into nil. Either level alone
/// stops the touch, which is why both are pinned here.
@MainActor
final class OpenPushInAppOverlayHitTestTests: XCTestCase {
    private static let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    /// A banner's strip, in the overlay's own coordinates.
    private static let banner = CGRect(x: 0, y: 0, width: 390, height: 120)

    private struct Overlay {
        let window: IamOverlayWindow
        let view: IamOverlayView
        let content: UIView?
    }

    /// The overlay as the presenter builds it: the view fills the window, and
    /// the content is a subview of it exactly as the web view is.
    private func makeOverlay(content: CGRect?, passesThrough: Bool) -> Overlay {
        let view = IamOverlayView(frame: Self.frame)
        view.passesThroughOutsideContent = passesThrough
        var contentView: UIView?
        if let content {
            let web = UIView(frame: content)
            view.addSubview(web)
            view.contentView = web
            contentView = web
        }
        let window = IamOverlayWindow(frame: Self.frame)
        window.rootViewController = IamHostController(overlay: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return Overlay(window: window, view: view, content: contentView)
    }

    func testAPointInsideABannerBelongsToTheBanner() {
        let overlay = makeOverlay(content: Self.banner, passesThrough: true)

        XCTAssertTrue(overlay.window.hitTest(CGPoint(x: 195, y: 60), with: nil) === overlay.content,
                      "the strip the message drew is the message's to handle")
    }

    func testAPointOutsideABannerIsHandedBackToTheApp() {
        let overlay = makeOverlay(content: Self.banner, passesThrough: true)

        XCTAssertNil(overlay.window.hitTest(CGPoint(x: 195, y: 500), with: nil),
                     "nil is the window saying the touch belongs to the app behind it")
    }

    /// The dimmed backdrop of a centred message is what makes it modal: the
    /// pass-through is off, so even a point on bare backdrop is a hit and the
    /// window must not turn it into nil.
    func testACentredMessagesBackdropSwallowsThePointsAroundIt() {
        let overlay = makeOverlay(content: CGRect(x: 45, y: 300, width: 300, height: 240),
                                  passesThrough: false)

        let hit = overlay.window.hitTest(CGPoint(x: 195, y: 80), with: nil)

        XCTAssertNotNil(hit, "a modal message may not let the app be tapped around it")
        XCTAssertFalse(hit === overlay.content, "and the backdrop, not the document, took it")
    }

    /// A banner that rendered without saying how tall it is keeps the full
    /// safe-area height it started with, so its document really does cover the
    /// screen and really does own every point of it.
    func testABannerThatRenderedWithoutAHeightOwnsTheWholeFrame() {
        let overlay = makeOverlay(content: Self.frame, passesThrough: true)

        XCTAssertTrue(overlay.window.hitTest(CGPoint(x: 195, y: 700), with: nil) === overlay.content,
                      "a height-less banner fills the frame, so nothing is outside it")
    }

    /// Between the window appearing and the document reporting a render a banner
    /// has drawn nothing and owns nothing, so every touch is still the app's.
    func testABannerOwnsNothingBeforeItHasAContentView() {
        let overlay = makeOverlay(content: nil, passesThrough: true)

        XCTAssertNil(overlay.window.hitTest(CGPoint(x: 195, y: 60), with: nil),
                     "no content view yet means no part of the screen is the message's")
    }

    /// The view's own answer, without the window's correction on top: this is
    /// the half of the rule that decides, and it has to decline by itself.
    func testTheOverlayViewDeclinesOutsideItsContentByItself() {
        let overlay = makeOverlay(content: Self.banner, passesThrough: true)

        XCTAssertTrue(overlay.view.hitTest(CGPoint(x: 195, y: 60), with: nil) === overlay.content)
        XCTAssertNil(overlay.view.hitTest(CGPoint(x: 195, y: 500), with: nil))
    }
}
#endif
