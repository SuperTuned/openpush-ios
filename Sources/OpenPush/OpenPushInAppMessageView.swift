import Foundation

extension OpenPush {
    enum IamPresentation {
        struct Action: Sendable {
            var clickID: String?
            var blockKey: String?
            var actionID: String?
            var url: String?
            var urlTarget: String?
            var closes: Bool
            /// The action asked for a system permission prompt. The engine holds
            /// the queue from here until `promptFinished()` says it is answered.
            var holdsQueue: Bool = false
        }

        /// Everything the presenter can tell the engine about one presentation.
        /// `rendered` is the only event that means "a human can see this"; the
        /// engine counts nothing until it arrives.
        enum Event: Sendable {
            case rendered(height: Double?)
            case pageChanged(pageId: String, index: Int)
            case action(Action)
            case failed(String)
        }

        typealias Presenter = @Sendable (IamMessage, @escaping @Sendable (Event) -> Void) -> Void
        typealias Dismisser = @Sendable () -> Void

        static let system: Presenter = { message, emit in
            #if canImport(UIKit) && canImport(WebKit)
            DispatchQueue.main.async { IamWebViewPresenter.show(message, emit: emit) }
            #else
            OpenPush.onLog("• in-app message \(message.id) is eligible; this platform has no presenter")
            emit(.failed("no presenter on this platform"))
            #endif
        }

        static let systemDismiss: Dismisser = {
            #if canImport(UIKit) && canImport(WebKit)
            DispatchQueue.main.async { IamWebViewPresenter.dismissActive() }
            #endif
        }
    }
}

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import SafariServices

/// Moves the authored close control out of `.op-card`, the document's scrolling element.
///
/// The control itself is retained, so its campaign icon, margins, click metadata and JavaScript
/// handler keep working. A carousel repeats the same campaign-level control on every card; only
/// the first is needed once it is anchored to the non-scrolling root. Custom documents without
/// OpenPush's standard classes are left untouched.
@MainActor
enum IamCloseControl {
    static let pinScript = """
    (function(){
      var root=document.querySelector('.op-root');
      if(!root||root.getAttribute('data-op-close-pinned')==='true')return;
      var buttons=root.querySelectorAll('.op-card > .op-close');
      if(!buttons.length)return;
      var close=buttons[0];
      root.style.position='relative';
      close.style.position='absolute';
      close.style.top='12px';
      close.style.right='12px';
      close.style.zIndex='2147483647';
      root.appendChild(close);
      for(var i=1;i<buttons.length;i++)buttons[i].style.display='none';
      root.setAttribute('data-op-close-pinned','true');
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: pinScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
    }
}

/// The view the message's window is built on. A banner covers the whole screen
/// but only owns the strip its document occupies; everything outside that strip
/// still belongs to the app, so a touch there has to fall through to the window
/// underneath rather than being swallowed by an invisible full-screen view.
///
/// Falling through takes both levels, because either one alone stops the touch.
/// This view is the only one that decides: a banner turns the pass-through on
/// before it owns anything at all — between the window appearing and the
/// document reporting its height nothing is drawn, the overlay sits at alpha 0
/// and `contentView` is still nil, so every touch belongs to the app — and
/// sizing the banner sets the content view, narrowing the pass-through to
/// everything outside that strip. A layout that never turns the pass-through on
/// declines nothing: the dimmed backdrop of a `center`, `full` or `carousel`
/// message keeps swallowing taps, which is what makes it modal.
///
/// `IamOverlayWindow` only carries that decision out. `UIWindow`'s own hit test
/// answers with the window itself where its root view returned nil, and UIKit
/// takes that for a hit rather than carrying the touch on to the key window
/// behind; the overlay window answers nil there instead. It never second-guesses
/// a view that did claim the point.
final class IamOverlayView: UIView {
    var passesThroughOutsideContent = false
    weak var contentView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard passesThroughOutsideContent else { return super.hitTest(point, with: event) }
        guard let contentView, contentView.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The window the overlay is hosted in, and the second half of the pass-through
/// rule described on `IamOverlayView`. The window itself as the answer is
/// `UIWindow` reporting that the overlay declined the point — the only case
/// where the touch belongs to the app, and the case that would otherwise stop
/// here instead of reaching the app's own window. Every other answer, the
/// overlay view included, is a view that claimed the point, and is handed back
/// untouched.
final class IamOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The overlay's own view controller. A window needs a root controller for the
/// system to consult about rotation at all, and the answer has to be the host
/// app's: a message that let itself rotate where the app cannot would turn the
/// screen sideways under a portrait-only app.
final class IamHostController: UIViewController {
    private let overlay: UIView

    init(overlay: UIView) {
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = overlay }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIApplication.shared.supportedInterfaceOrientations(for: nil)
    }
}

/// Where an in-app browser (`url_target: "webview"`) is presented from, and the
/// one rule that matters: never the overlay's own `IamHostController`.
///
/// The overlay takes the key window for as long as the message is up, so "the
/// top view controller of the key window" is the message's host, not the app's.
/// A sheet presented there is torn down with the overlay the moment the action
/// closes the message — the window is hidden, its root controller is nilled and
/// the window is dropped — so the person taps a link and nothing appears. The
/// app's own window outlives the message, which makes it the only correct
/// presenter.
/// `@MainActor` because every type it touches is: this is an internal helper on
/// the presenter's own main-thread path, not part of the SDK's API surface.
@MainActor
enum IamBrowser {
    /// `previousKeyWindow` is whatever was key when the message went up, so it
    /// is demonstrably the app's own. A host that tore it down in the meantime
    /// falls back to the first key window that is not an overlay, and then to
    /// the first non-overlay window with a root controller at all.
    static func presentingController(preferring previousKeyWindow: UIWindow?,
                                     among windows: [UIWindow]) -> UIViewController? {
        let app = windows.filter { !($0 is IamOverlayWindow) }
        let ordered = [previousKeyWindow].compactMap { $0 }
            + app.filter { $0.isKeyWindow }
            + app
        for window in ordered where !(window is IamOverlayWindow) {
            guard var top = window.rootViewController else { continue }
            while let presented = top.presentedViewController { top = presented }
            // A window the app owns can still be showing the overlay's host if
            // the SDK ever changes how the overlay is hosted; refuse it here
            // too rather than trusting the window test alone.
            if top is IamHostController { continue }
            return top
        }
        return nil
    }

    static func open(_ url: URL, from presenter: UIViewController) {
        presenter.present(SFSafariViewController(url: url), animated: true)
    }

    /// The only schemes a message may send the person to. A campaign is content
    /// the server hands down and the document renders, so its links reach
    /// `UIApplication.open` — and that will open anything the device has a
    /// handler for, including `tel:`, `sms:`, `mailto:` and whatever custom
    /// scheme happens to be installed. `SFSafariViewController` refuses
    /// anything else outright and traps on it, so the same rule has to hold on
    /// both paths.
    static func isOpenable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        default: return false
        }
    }

    /// Hands the URL to the system, or says why it did not.
    static func openExternally(_ url: URL) {
        guard isOpenable(url) else {
            OpenPush.onLog("\u{2022} in-app link ignored — only http(s) links are opened "
                           + "(\(url.scheme ?? "no scheme"))")
            return
        }
        UIApplication.shared.open(url)
    }
}

@MainActor
private final class IamWebViewPresenter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static var active: IamWebViewPresenter?
    private let message: OpenPush.IamMessage
    private let emit: @Sendable (OpenPush.IamPresentation.Event) -> Void
    private let overlay = IamOverlayView()
    private let webView: WKWebView
    /// The constraints that give the document the full safe-area height. A
    /// banner trades them for a height constraint once it says how tall it is.
    private var fullHeightConstraints: [NSLayoutConstraint] = []
    private var bannerHeight: NSLayoutConstraint?
    /// The message gets a window of its own rather than a subview of the host's:
    /// the app is free to push, present and dismiss underneath without the
    /// overlay riding along or being torn off with the view it was added to.
    private var window: UIWindow?
    /// The window that was key when the message went up, so it can be handed
    /// back on the way down rather than left to whatever the system picks.
    private weak var previousKeyWindow: UIWindow?
    private var timer: Timer?
    /// The first of `rendered` and `failed` wins: a document that failed must
    /// never also report a render, and a rendered document must never be
    /// abandoned by a later sub-resource error.
    private var reported = false

    /// How long a message waits for a window before it gives up: 20 attempts at
    /// half a second. Long enough to cover the gap between a launch-time
    /// presentation and the first key window, short enough that a host with no
    /// window at all stops polling for the life of the process.
    private static let windowWaitAttempts = 20

    private init(_ message: OpenPush.IamMessage,
                 emit: @escaping @Sendable (OpenPush.IamPresentation.Event) -> Void) {
        self.message = message; self.emit = emit
        let controller = WKUserContentController()
        IamCloseControl.install(in: controller)
        let config = WKWebViewConfiguration(); config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(); controller.add(self, name: "openpush")
        webView.navigationDelegate = self
        // Debug builds only: a message that renders wrong is otherwise a blank
        // rectangle with no way in from Safari's develop menu.
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
    }

    /// `attempt` counts only the tries made while the app was in the foreground:
    /// a backgrounded app has no window to wait for, so waiting there is free
    /// and the budget is untouched. Once it runs out the engine is told, which
    /// hands the slot to the next message instead of retrying forever.
    static func show(_ message: OpenPush.IamMessage,
                     emit: @escaping @Sendable (OpenPush.IamPresentation.Event) -> Void,
                     attempt: Int = 0) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              scene.windows.contains(where: { $0.isKeyWindow }),
              let config = OpenPush.state.config,
              let sub = OpenPush.state.currentSubscriptionID,
              let url = URL(string: config.serverURL + message.htmlPath + "?subscription_id=" + sub) else {
            let background = UIApplication.shared.applicationState == .background
            guard background || attempt < windowWaitAttempts else {
                OpenPush.onLog("✗ in-app message \(message.id) never found an active window")
                emit(.failed("no active window"))
                return
            }
            // Once, and only for a wait that is actually costing budget: a
            // backgrounded app holds `attempt` at 0 and would otherwise say this
            // twice a second for as long as it stays there.
            if attempt == 0 && !background {
                OpenPush.onLog("• in-app message \(message.id) is waiting for an active window")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Something else took the screen while this one waited, which
                // makes this the stale presentation — a pause/unpause or a
                // workspace switch has already re-presented what belongs there,
                // and the engine's `current` points at that one, not this.
                guard active == nil else { return }
                show(message, emit: emit, attempt: background ? attempt : attempt + 1)
            }
            return
        }
        active?.dismiss(notify: true)
        let presenter = IamWebViewPresenter(message, emit: emit); active = presenter
        presenter.overlay.backgroundColor = message.layout == "center" ? UIColor.black.withAlphaComponent(0.38) : .clear
        // Nothing shows until the document reports a render: a half-drawn or
        // never-arriving page would otherwise flash an empty dimming layer.
        presenter.overlay.alpha = 0
        // The message owns the screen while it is up, so assistive technology
        // should not be able to reach past it into the app behind.
        presenter.overlay.accessibilityViewIsModal = true
        presenter.webView.translatesAutoresizingMaskIntoConstraints = false
        presenter.webView.isOpaque = false; presenter.webView.backgroundColor = .clear
        presenter.webView.scrollView.backgroundColor = .clear
        presenter.webView.scrollView.bounces = false
        presenter.overlay.addSubview(presenter.webView)
        // A banner owns nothing until it says how tall it is; until then the
        // whole screen is the app's, invisible overlay notwithstanding.
        presenter.overlay.passesThroughOutsideContent =
            message.layout == "top" || message.layout == "bottom"
        // Whatever is key now gets the key window back when the message comes
        // down; read before the overlay's own window joins the scene.
        presenter.previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = IamOverlayWindow(windowScene: scene)
        host.backgroundColor = .clear
        // Just under `.alert`, so the message covers the app but never a system
        // alert or the keyboard's own accessory window.
        host.windowLevel = .alert - 1
        host.rootViewController = IamHostController(overlay: presenter.overlay)
        presenter.window = host
        host.isHidden = false
        // A text field inside a message can only become first responder in the
        // key window, so the overlay takes it for as long as it is up.
        host.makeKey()
        #if DEBUG
        OpenPush.onLog("• in-app window shown")
        #endif
        let guide = presenter.overlay.safeAreaLayoutGuide
        // Every layout starts at the full safe-area frame; a banner shrinks to
        // its document once it reports a height, and the rest stay here.
        presenter.fullHeightConstraints = [
            presenter.webView.topAnchor.constraint(equalTo: guide.topAnchor),
            presenter.webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ]
        NSLayoutConstraint.activate([
            presenter.webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            presenter.webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
        ] + presenter.fullHeightConstraints)
        var request = URLRequest(url: url); request.setValue(config.sdkKey, forHTTPHeaderField: "X-OP-SDK-Key")
        if let deviceKey = OpenPush.state.deviceCredential { request.setValue(deviceKey, forHTTPHeaderField: "X-OP-Device-Key") }
        presenter.webView.load(request)
    }

    static func dismissActive() { active?.tearDown(animated: true) }

    /// A link the person taps to somewhere other than the message's own origin
    /// is the browser's job: loading it inside the overlay would leave a web
    /// page wearing the message's frame, with no address bar and no way back.
    /// Everything the document does for itself — the initial request, redirects,
    /// sub-frames, script-driven navigation — passes through untouched. A link
    /// with no frame of its own (`target="_blank"`) would otherwise go nowhere
    /// at all, so it is treated as leaving too.
    ///
    /// Same `@MainActor @Sendable` note as below: the signature must match
    /// WebKit's exactly or the method is never called.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let origin = OpenPush.state.config.flatMap { URL(string: $0.serverURL)?.host }
        guard navigationAction.navigationType == .linkActivated,
              navigationAction.targetFrame.map(\.isMainFrame) ?? true,
              let url = navigationAction.request.url,
              url.host != origin else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        IamBrowser.openExternally(url)
    }

    /// `decisionHandler` carries WebKit's own `@MainActor @Sendable` annotations.
    /// Declaring it bare compiles, but only "nearly matches" the optional
    /// requirement — WebKit would never call it and a 404 would never be caught.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400,
           navigationResponse.isForMainFrame {
            decisionHandler(.cancel)
            fail("HTTP \(http.statusCode)")
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { rendered(height: nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail(error.localizedDescription)
    }

    /// A banner is as tall as its document and no taller, capped at 60% of the
    /// screen so a runaway document cannot quietly become a full-screen message.
    /// The rest of the screen goes back to the app, touches included.
    ///
    /// Only `top` and `bottom` size themselves: `center` is positioned by its
    /// own document inside the full frame, and `full` and `carousel` are the
    /// full frame.
    private func sizeToContent(_ height: Double) {
        guard message.layout == "top" || message.layout == "bottom", height > 0 else { return }
        let cap = (window?.bounds.height ?? overlay.bounds.height) * 0.6
        let value = cap > 0 ? min(CGFloat(height), cap) : CGFloat(height)
        if let bannerHeight {
            guard bannerHeight.constant != value else { return }
            bannerHeight.constant = value
            overlay.layoutIfNeeded()
            return
        }
        NSLayoutConstraint.deactivate(fullHeightConstraints)
        fullHeightConstraints = []
        let guide = overlay.safeAreaLayoutGuide
        let edge = message.layout == "top"
            ? webView.topAnchor.constraint(equalTo: guide.topAnchor)
            : webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        let sized = webView.heightAnchor.constraint(equalToConstant: value)
        bannerHeight = sized
        NSLayoutConstraint.activate([edge, sized])
        overlay.contentView = webView
        overlay.layoutIfNeeded()
    }

    /// The display-duration countdown starts at the render, not at the load:
    /// a five-second message that spent four seconds fetching was on screen
    /// for one.
    private func rendered(height: Double?) {
        // Before the `reported` guard: a document that finished loading first
        // reports its height afterwards, and that late measurement is the only
        // one a banner ever gets.
        if let height { sizeToContent(height) }
        guard !reported else { return }
        reported = true
        // A banner that reported no height keeps the full frame it loaded with,
        // so the document — close button and all — is what the overlay owns.
        if overlay.passesThroughOutsideContent, overlay.contentView == nil { overlay.contentView = webView }
        UIView.animate(withDuration: 0.2) { self.overlay.alpha = 1 }
        emit(.rendered(height: height))
        if let duration = message.displayDuration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.dismiss(notify: true) }
            }
        }
    }

    private func fail(_ reason: String) {
        guard !reported else { return }
        reported = true
        tearDown()
        emit(.failed(reason))
    }

    /// A full-screen or carousel document reports -1: it has no intrinsic height
    /// to size the host view to, so it is read as "no height".
    private static func reportedHeight(_ envelope: [String: Any]?) -> Double? {
        let raw = ((envelope?["pageMetaData"] as? [String: Any])?["rect"] as? [String: Any])?["height"] as? NSNumber
        return raw.map { $0.doubleValue }.flatMap { $0 > 0 ? $0 : nil }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive scriptMessage: WKScriptMessage) {
        let envelope: [String: Any]?
        if let value = scriptMessage.body as? [String: Any] { envelope = value }
        else if let value = scriptMessage.body as? String,
                let data = value.data(using: .utf8) {
            envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else { envelope = nil }
        switch envelope?["type"] as? String {
        case "rendering_complete":
            rendered(height: Self.reportedHeight(envelope))
            return
        case "resize":
            // A document that re-measures itself after it rendered — a banner
            // whose content grew or shrank. Nothing else about the presentation
            // changes, so this never re-reports a render.
            if let height = Self.reportedHeight(envelope) { sizeToContent(height) }
            return
        case "page_change":
            if let pageId = envelope?["pageId"] as? String {
                emit(.pageChanged(pageId: pageId, index: (envelope?["pageIndex"] as? NSNumber)?.intValue ?? 0))
            }
            return
        case "action_taken":
            break
        default:
            return
        }
        guard let envelope, let body = envelope["body"] as? [String: Any] else { return }
        let closes = body["close"] as? Bool ?? false
        let actionID = body["name"] as? String
        let prompts = body["prompts"] as? [String] ?? []
        // The engine is told before the prompt is raised, never after: the
        // action may close the message, and a queue released between the close
        // and the alert would show the next message underneath it.
        let promptsForPush = prompts.contains("push")
        emit(.action(.init(clickID: body["id"] as? String,
                           blockKey: body["block_key"] as? String,
                           actionID: actionID,
                           url: body["url"] as? String,
                           urlTarget: body["url_target"] as? String,
                           closes: closes,
                           holdsQueue: promptsForPush)))
        if promptsForPush {
            OpenPush.Notifications.requestPermission(fallbackToSettings: true) { _ in
                OpenPush.IamEngine.shared.promptFinished()
            }
        }
        if prompts.contains("location") {
            OpenPush.onLog("• location prompt ignored — OpenPush does not own location permission")
        }
        if let tags = body["tags"] as? [String: Any],
           let adds = tags["adds"] as? [String: String] { OpenPush.User.addTags(adds) }
        if let outcomes = body["outcomes"] as? [[String: Any]] {
            outcomes.compactMap { $0["name"] as? String }.forEach { OpenPush.trackEvent($0) }
        }
        if let raw = body["url"] as? String, let url = URL(string: raw) {
            // Presented before the message is closed below, while
            // `previousKeyWindow` still names the window the app was showing.
            if IamBrowser.isOpenable(url),
               body["url_target"] as? String == "webview",
               let presenter = IamBrowser.presentingController(
                preferring: previousKeyWindow,
                among: UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)) {
                IamBrowser.open(url, from: presenter)
            } else { IamBrowser.openExternally(url) }
        }
        if closes { dismiss(notify: false) }
    }

    /// Takes the document off screen and releases every retain the presenter
    /// holds. Idempotent, so a teardown racing a timer costs nothing.
    ///
    /// The slot is given up synchronously — the web view stops talking and
    /// `active` is cleared before this returns — so a fade on the way out can
    /// never delay or block the message that replaces this one. Only the window
    /// release waits for the animation.
    private func tearDown(animated: Bool = false) {
        timer?.invalidate(); timer = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "openpush")
        if Self.active === self { Self.active = nil }
        guard animated, window != nil, overlay.alpha > 0 else {
            releaseWindow()
            return
        }
        UIView.animate(withDuration: 0.15, animations: { self.overlay.alpha = 0 },
                       completion: { _ in self.releaseWindow() })
    }

    private func releaseWindow() {
        guard let host = window else { return }
        overlay.removeFromSuperview()
        host.isHidden = true
        host.rootViewController = nil
        window = nil
        // Only if it is still part of a scene: the app may have torn it down
        // while the message was up, and making a detached window key does
        // nothing but leave the scene without one.
        if let previous = previousKeyWindow, previous.windowScene != nil { previous.makeKey() }
        previousKeyWindow = nil
        #if DEBUG
        OpenPush.onLog("• in-app window hidden")
        #endif
    }

    private func dismiss(notify: Bool) {
        tearDown(animated: true)
        if notify { emit(.action(.init(closes: true))) }
    }
}
#endif
