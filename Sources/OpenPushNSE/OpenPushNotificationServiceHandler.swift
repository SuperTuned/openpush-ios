import Foundation
import OpenPushCore
@preconcurrency import UserNotifications

/// A whole Notification Service Extension in one object: action buttons, media
/// attachment and delivery receipt, driven from `didReceive`.
///
/// A host's extension becomes three lines:
///
/// ```swift
/// final class NotificationService: UNNotificationServiceExtension {
///     private let openPush = OpenPushNotificationServiceHandler(options: .init())
///
///     override func didReceive(_ request: UNNotificationRequest,
///                              withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
///         openPush.didReceive(request, withContentHandler: contentHandler)
///     }
///
///     override func serviceExtensionTimeWillExpire() { openPush.serviceExtensionTimeWillExpire() }
/// }
/// ```
///
/// What it guarantees:
///
/// - The content handler is called **exactly once**, on every path — including the
///   expiry path, and including a payload OpenPush did not send, which is handed
///   straight back untouched.
/// - Delivery waits for all three pieces of work: the action category being
///   registered, the image having finished or been skipped, and the receipt having
///   completed (with any status, or an error) or been skipped. The receipt is not
///   fire-and-forget: calling the content handler lets the system suspend the
///   extension, and a request still in flight — or a jittered one not yet fired —
///   dies with it. That reliability costs latency, so the default jitter is short:
///   the worst case is ~2 s of jitter plus the request, and the receipt is started
///   in the same breath as the image fetch rather than after it.
/// - `serviceExtensionTimeWillExpire` delivers whatever is ready — the actions are
///   applied synchronously, so the buttons survive an expiry even when the image
///   or the receipt does not.
///
/// Diagnostics go to `NSLog`: an extension is a separate process and has no access
/// to the app's log hook. `Options.onEvent` is the host-facing counterpart, for a
/// sample app or a debug surface that wants to show what the extension did.
public final class OpenPushNotificationServiceHandler: @unchecked Sendable {
    public struct Options: Sendable {
        /// The App Group the app mirrors its state into. Without one the extension
        /// cannot read the APNs token, so no receipt can be sent, and has no stored
        /// badge count, so an `op_badge_increment` leaves the badge unchanged.
        public var appGroup: String?
        /// Optional. The shared-Keychain store holding this install's device
        /// credential, sent with the receipt when it can be read. Receipts are
        /// posted without it: the server authenticates them on the SDK key. The
        /// credential is never mirrored into the App Group, so using it needs the
        /// Keychain access group in the extension's entitlements.
        public var credentialStore: DeviceCredentialStore?
        /// Explicit configuration. When nil, the App Group mirror is used, and the
        /// bundled `OpenPushAppID` / `OpenPushSDKKey` keys after that.
        public var configuration: OpenPushConfiguration?
        public var receiptTypes: [String] = ["received", "confirmed"]
        /// The receipt is delayed by a random offset in this range, so a broadcast
        /// does not turn every device's wake-up into one synchronised spike.
        ///
        /// Delivery waits for the receipt, so this delay is added to how long the
        /// notification takes to appear; the default of 0–2 s spreads a large
        /// campaign's receipts while keeping that cost small. Raise it only if your
        /// server asks for it.
        public var receiptJitter: ClosedRange<Double> = 0...2
        public var attachments = OpenPushAttachmentLoader.Options()
        /// Set false to render text only and never fetch `image_url`.
        public var loadAttachments = true
        /// Reports what the extension did, one short line at a time:
        /// `"actions: <n>"` — the number of buttons actually registered, `0` when a
        /// category the host owns was left alone — `"attachment: ok|skipped|failed"`,
        /// `"receipt: HTTP <code>"` or `"receipt: skipped (<reason>)"`, and for a push
        /// with `op_badge_increment`, `"badge: <count>"` or `"badge: skipped (<reason>)"`.
        /// It may be called from any thread.
        public var onEvent: (@Sendable (String) -> Void)?

        public init() {}
    }

    /// The network seam for the receipt. The `Int` is the HTTP status, or 0 when
    /// the request never got one.
    public typealias Transport = @Sendable (URLRequest, @escaping @Sendable (Int) -> Void) -> Void
    /// The delay seam for the receipt jitter.
    public typealias Scheduler = @Sendable (Double, @escaping @Sendable () -> Void) -> Void

    private let options: Options
    private let categories: OpenPushNotificationActions.CategoryStore
    private let download: OpenPushAttachmentLoader.Download
    private let transport: Transport
    private let scheduler: Scheduler
    private let random: @Sendable (ClosedRange<Double>) -> Double
    private let credential: @Sendable () -> String?

    /// Everything mutable lives behind this lock, and no seam is ever called while
    /// it is held.
    private let lock = NSLock()
    private var content: UNMutableNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?
    private var delivered = false
    private var categoriesRegistered = false
    private var attachmentSettled = false
    private var receiptSettled = false

    public convenience init(
        options: Options = Options(),
        categories: OpenPushNotificationActions.CategoryStore = .system,
        download: @escaping OpenPushAttachmentLoader.Download = OpenPushAttachmentLoader.urlSessionDownload,
        transport: @escaping Transport = OpenPushNotificationServiceHandler.urlSessionTransport,
        scheduler: @escaping Scheduler = OpenPushNotificationServiceHandler.dispatchAfter,
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.init(options: options, categories: categories, download: download,
                  transport: transport, scheduler: scheduler, random: random,
                  credential: { options.credentialStore?.load() })
    }

    /// The credential seam exists for the tests: `DeviceCredentialStore` reads the
    /// Keychain, which a test host cannot stand in for.
    init(options: Options,
         categories: OpenPushNotificationActions.CategoryStore,
         download: @escaping OpenPushAttachmentLoader.Download,
         transport: @escaping Transport,
         scheduler: @escaping Scheduler,
         random: @escaping @Sendable (ClosedRange<Double>) -> Double,
         credential: @escaping @Sendable () -> String?) {
        self.options = options
        self.categories = categories
        self.download = download
        self.transport = transport
        self.scheduler = scheduler
        self.random = random
        self.credential = credential
    }

    // MARK: - Extension entry points

    public func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo
        let notification = OpenPushNotification(userInfo: userInfo)
        guard notification.isOpenPush,
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }

        lock.lock()
        self.content = content
        self.handler = contentHandler
        delivered = false
        categoriesRegistered = false
        attachmentSettled = false
        receiptSettled = false
        lock.unlock()

        // Synchronous and local — one App Group read and write — so an expiry
        // still delivers the badge along with everything else set here.
        applyBadge(notification, to: content)

        // The category is set on `content` synchronously here, which is what makes
        // an expiry still deliver the buttons; only the registration is async.
        OpenPushNotificationActions.apply(from: userInfo, to: content,
                                          categories: categories, ledger: ledger()) { [self] registered in
            report("actions: \(registered)")
            lock.lock(); categoriesRegistered = true; lock.unlock()
            deliverIfReady()
        }
        // Both are started here, so the receipt's jitter runs alongside the image
        // fetch instead of being queued behind it: the two costs overlap rather
        // than adding up.
        startReceipt(for: notification)
        startAttachment(notification.imageURL)
    }

    /// The system is about to take the budget back. Deliver what is ready.
    public func serviceExtensionTimeWillExpire() {
        lock.lock()
        guard !delivered, let handler, let content else { lock.unlock(); return }
        delivered = true
        self.handler = nil
        // Handed to the system, and the system owns it from here: a download or a
        // receipt that lands afterwards must find nothing left to mutate.
        self.content = nil
        lock.unlock()
        NSLog("OpenPush: extension time expired, delivering the content as it stands")
        handler(content)
    }

    // MARK: - Sharing an existing extension

    /// For an extension that already handles another sender's pushes: OpenPush
    /// takes the request only when it is OpenPush's own.
    ///
    /// ```swift
    /// override func didReceive(_ request: UNNotificationRequest,
    ///                          withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    ///     if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }
    ///     // the extension's existing code
    /// }
    /// ```
    ///
    /// Returns false, and never calls `contentHandler`, when the payload has no
    /// `op_message_id`: the request stays the caller's. Otherwise it behaves
    /// exactly like `didReceive` and returns true.
    public func handleIfOpenPush(_ request: UNNotificationRequest,
                                 withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) -> Bool {
        guard OpenPushNotification(userInfo: request.content.userInfo).isOpenPush else { return false }
        didReceive(request, withContentHandler: contentHandler)
        return true
    }

    /// The expiry counterpart of `handleIfOpenPush`. Returns true, after
    /// delivering what is ready, while OpenPush still holds a request it has not
    /// delivered; false otherwise — the request is the caller's, or OpenPush's
    /// is already delivered — and the caller runs its own expiry code.
    ///
    /// ```swift
    /// override func serviceExtensionTimeWillExpire() {
    ///     if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
    ///     // the extension's existing code
    /// }
    /// ```
    public func serviceExtensionTimeWillExpireIfHandling() -> Bool {
        lock.lock(); let pending = handler != nil && !delivered; lock.unlock()
        guard pending else { return false }
        serviceExtensionTimeWillExpire()
        return true
    }

    // MARK: - Badge

    /// Logged once per extension process, not once per push: a host without an
    /// App Group would otherwise repeat the same line for every increment.
    private static let missingGroupLogged = OnceFlag()

    /// `op_badge_increment` adds to the stored count and shows the sum; an
    /// absolute `aps.badge` is recorded as the stored count, so a later increment
    /// counts up from what the icon actually shows. Without an App Group there is
    /// no count to add to, and the badge is left exactly as the payload set it.
    private func applyBadge(_ notification: OpenPushNotification,
                            to content: UNMutableNotificationContent) {
        if let increment = notification.badgeIncrement {
            guard let appGroup = options.appGroup,
                  let count = OpenPushSharedState.incrementBadgeCount(by: increment,
                                                                      appGroup: appGroup) else {
                if Self.missingGroupLogged.claim() {
                    NSLog("OpenPush: op_badge_increment ignored — the extension has no App " +
                          "Group to keep the badge count in; the badge is left unchanged")
                }
                report("badge: skipped (no App Group)")
                return
            }
            content.badge = NSNumber(value: count)
            report("badge: \(count)")
        } else if let badge = notification.badge, let appGroup = options.appGroup {
            OpenPushSharedState.setBadgeCount(badge, appGroup: appGroup)
        }
    }

    // MARK: - Attachment

    private func startAttachment(_ url: URL?) {
        guard options.loadAttachments, let url else {
            report("attachment: skipped")
            settleAttachment()
            return
        }
        OpenPushAttachmentLoader.load(url, options: options.attachments,
                                      download: download) { [self] attachment in
            if let attachment {
                lock.lock()
                content?.attachments = [attachment]
                lock.unlock()
                report("attachment: ok")
            } else {
                NSLog("OpenPush: the notification image could not be used; delivering text only")
                report("attachment: failed")
            }
            settleAttachment()
        }
    }

    private func settleAttachment() {
        lock.lock(); attachmentSettled = true; lock.unlock()
        deliverIfReady()
    }

    // MARK: - Receipt

    private func startReceipt(for notification: OpenPushNotification) {
        let shared = options.appGroup.flatMap { OpenPushSharedState.load(appGroup: $0) }
        guard let messageID = notification.messageId else {
            skipReceipt("no message id"); return
        }
        guard let token = shared?.token, !token.isEmpty else {
            skipReceipt("no APNs token in the App Group"); return
        }
        // Optional: the server accepts a receipt on the SDK key alone, so an
        // extension with no Keychain store still reports delivery.
        let credential = credential()
        guard let configuration = options.configuration ?? shared?.configuration
                ?? Self.bundledConfiguration() else {
            skipReceipt("no configuration"); return
        }
        guard let request = OpenPushReceiptRequest.make(
            configuration: configuration, deviceCredential: credential, token: token,
            messageID: messageID, types: options.receiptTypes,
            sdkWrapper: shared?.sdkWrapper) else {
            skipReceipt("the server URL is not valid"); return
        }

        let delay = random(options.receiptJitter)
        scheduler(delay) { [self] in
            transport(request) { [self] status in
                report("receipt: HTTP \(status)")
                settleReceipt()
            }
        }
    }

    private func skipReceipt(_ reason: String) {
        NSLog("OpenPush: delivery receipt skipped — %@", reason)
        report("receipt: skipped (\(reason))")
        settleReceipt()
    }

    private func settleReceipt() {
        lock.lock(); receiptSettled = true; lock.unlock()
        deliverIfReady()
    }

    private static func bundledConfiguration() -> OpenPushConfiguration? {
        guard let appID = OpenPushConfiguration.bundledAppID(),
              let sdkKey = OpenPushConfiguration.bundledSDKKey() else { return nil }
        return OpenPushConfiguration(appID: appID, sdkKey: sdkKey)
    }

    // MARK: - Delivery

    private func deliverIfReady() {
        lock.lock()
        guard !delivered, categoriesRegistered, attachmentSettled, receiptSettled,
              let handler, let content else {
            lock.unlock()
            return
        }
        delivered = true
        self.handler = nil
        self.content = nil
        lock.unlock()
        handler(content)
    }

    private func report(_ event: String) { options.onEvent?(event) }

    /// The category ledger belongs in the App Group when there is one, so the app
    /// and every extension agree on which categories are the recent ones.
    private func ledger() -> UserDefaults {
        options.appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    // MARK: - Default seams

    /// One ephemeral session per receipt: an extension is torn down right after
    /// delivery, so nothing is gained by keeping a shared one alive.
    public static func urlSessionTransport(_ request: URLRequest,
                                           _ completion: @escaping @Sendable (Int) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("OpenPush: delivery receipt failed — %@", error.localizedDescription)
            }
            completion((response as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
        session.finishTasksAndInvalidate()
    }

    public static func dispatchAfter(_ delay: Double, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// A flag that answers true exactly once per process.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
