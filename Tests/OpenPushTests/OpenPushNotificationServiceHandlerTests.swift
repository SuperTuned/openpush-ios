import XCTest
import UserNotifications
import OpenPushCore
@testable import OpenPushNSE

/// The handler is the whole extension in one object, so every test drives it the
/// way the system does: `didReceive`, then the seams answer, then the content is
/// delivered — once, and only once.
final class OpenPushNotificationServiceHandlerTests: XCTestCase {
    /// A 1x1 PNG, so the host's own attachment validation has real bytes to accept.
    private let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
        """)!

    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "io.openpush.tests.nse.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Seams

    /// Holds the category read open until the test closes it, so "delivered only
    /// after the categories are registered" can be observed rather than assumed.
    private final class Categories: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable (Set<UNNotificationCategory>) -> Void)?
        private var reads = 0
        private var writes = 0

        var store: OpenPushNotificationActions.CategoryStore {
            OpenPushNotificationActions.CategoryStore(
                read: { completion in
                    self.lock.lock(); self.reads += 1; self.pending = completion; self.lock.unlock()
                },
                write: { _ in self.lock.lock(); self.writes += 1; self.lock.unlock() })
        }

        func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
        func writeCount() -> Int { lock.lock(); defer { lock.unlock() }; return writes }

        /// Answers the pending read, which drives the write and the completion.
        func finish() {
            lock.lock(); let completion = pending; pending = nil; lock.unlock()
            completion?([])
        }
    }

    /// Holds the media download open the same way. The seam hands over a file, the
    /// way a real download task does, so the bytes land on disk here too.
    private final class Downloads: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable (URL?, URLResponse?, Error?) -> Void)?
        private var requests: [URLRequest] = []

        var download: OpenPushAttachmentLoader.Download {
            { request, completion in
                self.lock.lock()
                self.requests.append(request)
                self.pending = completion
                self.lock.unlock()
            }
        }

        func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }

        func finish(_ data: Data?, mime: String?) {
            lock.lock()
            let completion = pending
            let url = requests.last?.url
            pending = nil
            lock.unlock()
            let response = url.map {
                URLResponse(url: $0, mimeType: mime,
                            expectedContentLength: data?.count ?? 0, textEncodingName: nil)
            }
            let file = data.map { body -> URL in
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("openpush-test-\(UUID().uuidString)")
                try? body.write(to: staged)
                return staged
            }
            completion?(file, response, nil)
        }
    }

    /// Holds the receipt request open, so "delivery waits for the receipt" can be
    /// observed rather than assumed.
    private final class Receipts: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable (Int) -> Void)?

        func transport(_ record: Record) -> OpenPushNotificationServiceHandler.Transport {
            { request, completion in
                record.send(request)
                self.lock.lock(); self.pending = completion; self.lock.unlock()
            }
        }

        func finish(_ status: Int) {
            lock.lock(); let completion = pending; pending = nil; lock.unlock()
            completion?(status)
        }
    }

    /// Everything the handler reports or hands out: deliveries, events, receipts.
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var contents: [UNNotificationContent] = []
        private var events: [String] = []
        private var delays: [Double] = []
        private var ranges: [ClosedRange<Double>] = []
        private var requests: [URLRequest] = []

        func deliver(_ content: UNNotificationContent) {
            lock.lock(); defer { lock.unlock() }; contents.append(content)
        }
        func deliveries() -> [UNNotificationContent] {
            lock.lock(); defer { lock.unlock() }; return contents
        }
        func event(_ text: String) { lock.lock(); defer { lock.unlock() }; events.append(text) }
        func reported() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
        func schedule(_ delay: Double) { lock.lock(); defer { lock.unlock() }; delays.append(delay) }
        func scheduled() -> [Double] { lock.lock(); defer { lock.unlock() }; return delays }
        func rolled(_ range: ClosedRange<Double>) {
            lock.lock(); defer { lock.unlock() }; ranges.append(range)
        }
        func rolls() -> [ClosedRange<Double>] { lock.lock(); defer { lock.unlock() }; return ranges }
        func send(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
        func sent() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    // MARK: - Fixtures

    private func userInfo(image: Bool = true, openPush: Bool = true) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Hello", "body": "World"], "mutable-content": 1],
        ]
        if openPush {
            info["op_message_id"] = "m-1"
            info["op_action_category"] = "op_actions_abc"
            info["op_actions"] = [["id": "yes", "label": "Yes"]]
        }
        if image { info["image_url"] = "https://cdn.example.com/a.png" }
        return info
    }

    private func request(_ info: [AnyHashable: Any]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Hello"
        content.userInfo = info
        return UNNotificationRequest(identifier: "req-1", content: content, trigger: nil)
    }

    private func options() -> OpenPushNotificationServiceHandler.Options {
        var options = OpenPushNotificationServiceHandler.Options()
        options.appGroup = suite
        options.configuration = OpenPushConfiguration(appID: "app-1", sdkKey: "key-1",
                                                      serverURL: "https://push.example.com")
        return options
    }

    private func mirrorToken() {
        OpenPushSharedState.save(
            OpenPushSharedState(appID: "app-1", serverURL: "https://push.example.com",
                                sdkKey: "key-1", token: "apns-token", subscriptionID: "sub-1",
                                appGroup: suite),
            appGroup: suite)
    }

    private func handler(_ options: OpenPushNotificationServiceHandler.Options,
                         categories: Categories, downloads: Downloads, record: Record,
                         credential: String?,
                         receipts: Receipts? = nil,
                         jitter: Double = 3,
                         runScheduled: Bool = true,
                         status: Int = 200) -> OpenPushNotificationServiceHandler {
        var configured = options
        configured.onEvent = { record.event($0) }
        let transport: OpenPushNotificationServiceHandler.Transport
        if let receipts {
            transport = receipts.transport(record)
        } else {
            transport = { request, completion in record.send(request); completion(status) }
        }
        return OpenPushNotificationServiceHandler(
            options: configured,
            categories: categories.store,
            download: downloads.download,
            transport: transport,
            scheduler: { delay, work in
                record.schedule(delay)
                if runScheduled { work() }
            },
            random: { range in record.rolled(range); return jitter },
            credential: { credential })
    }

    // MARK: - Delivery

    func testDeliversOnceAfterActionsAndAttachment() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let receipts = Receipts()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key", receipts: receipts)

        subject.didReceive(request(userInfo())) { record.deliver($0) }
        XCTAssertEqual(record.deliveries().count, 0, "nothing is delivered while all three are pending")

        categories.finish()
        XCTAssertEqual(record.deliveries().count, 0, "the image is still being fetched")

        downloads.finish(png, mime: "image/png")
        XCTAssertEqual(record.deliveries().count, 0, "the receipt is still in flight")

        receipts.finish(200)
        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(categories.writeCount(), 1)

        let delivered = record.deliveries().first
        XCTAssertEqual(delivered?.categoryIdentifier, "op_actions_abc")
        XCTAssertEqual(delivered?.attachments.count, 1)
        XCTAssertTrue(record.reported().contains("actions: 1"))
        XCTAssertTrue(record.reported().contains("attachment: ok"))

        subject.serviceExtensionTimeWillExpire()
        XCTAssertEqual(record.deliveries().count, 1, "the content handler is called exactly once")
    }

    func testAFailedImageStillDelivers() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo())) { record.deliver($0) }
        categories.finish()
        downloads.finish(nil, mime: nil)

        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(record.deliveries().first?.attachments.count, 0)
        XCTAssertTrue(record.reported().contains("attachment: failed"))
    }

    func testAPayloadWithoutAnImageDeliversWithTheActionsAlone() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(downloads.count(), 0)
        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertTrue(record.reported().contains("attachment: skipped"))
    }

    func testExpiryDeliversContentWithActionsWithoutWaitingForTheImage() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo())) { record.deliver($0) }
        categories.finish()
        subject.serviceExtensionTimeWillExpire()

        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(record.deliveries().first?.categoryIdentifier, "op_actions_abc",
                       "the actions applied before the budget ran out are kept")
        XCTAssertEqual(record.deliveries().first?.attachments.count, 0)

        downloads.finish(png, mime: "image/png")
        XCTAssertEqual(record.deliveries().count, 1, "a late image never delivers a second time")
        XCTAssertEqual(record.deliveries().first?.attachments.count, 0,
                       "a download that lands after delivery must not write onto content iOS already owns")
    }

    // MARK: - Receipt

    func testReceiptIsScheduledWithinTheJitterRange() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.rolls(), [0...2],
                       "the jitter is rolled over the configured range, which delivery waits out")
        XCTAssertEqual(record.scheduled(), [3], "the roll is what the scheduler is given")
        XCTAssertEqual(record.sent().count, 1)
        XCTAssertEqual(record.sent().first?.url?.absoluteString,
                       "https://push.example.com/v1/ingest")
        XCTAssertEqual(record.sent().first?.value(forHTTPHeaderField: "X-OP-Device-Key"),
                       "device-key")
        XCTAssertTrue(record.reported().contains("receipt: HTTP 200"))
    }

    /// The extension posts the SDK's highest-volume request, and until it named
    /// itself a receipt was the one request server-side triage could not attribute
    /// to a client version.
    func testTheExtensionReceiptIdentifiesTheSDK() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        let sent = record.sent().first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "X-OP-SDK"),
                       "openpush/ios/\(OpenPushSDKVersion.current)")
        XCTAssertNil(sent?.value(forHTTPHeaderField: "X-OP-SDK-Wrapper"),
                     "a native install claims no wrapper")
    }

    /// The extension cannot see `OpenPush.wrapper` — it is another process — so the
    /// identity travels through the App Group mirror the app writes.
    func testTheExtensionReceiptNamesTheWrapperFromTheAppGroup() {
        OpenPushSharedState.save(
            OpenPushSharedState(appID: "app-1", serverURL: "https://push.example.com",
                                sdkKey: "key-1", token: "apns-token", subscriptionID: "sub-1",
                                sdkWrapper: "unity/1.1.4", appGroup: suite),
            appGroup: suite)
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().first?.value(forHTTPHeaderField: "X-OP-SDK-Wrapper"),
                       "unity/1.1.4")
    }

    /// Delivering first would let the system suspend the extension with the receipt
    /// still in flight, which is exactly how a receipt goes missing.
    func testDeliveryWaitsForTheReceiptUnlessTheExtensionExpires() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let receipts = Receipts()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key", receipts: receipts)

        subject.didReceive(request(userInfo())) { record.deliver($0) }
        categories.finish()
        downloads.finish(png, mime: "image/png")
        XCTAssertEqual(record.deliveries().count, 0,
                       "actions and image are done, but the receipt has not come back")

        receipts.finish(200)
        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(record.deliveries().first?.attachments.count, 1)
        XCTAssertTrue(record.reported().contains("receipt: HTTP 200"))
    }

    func testExpiryDeliversBeforeTheReceiptCompletes() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let receipts = Receipts()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key", receipts: receipts)

        subject.didReceive(request(userInfo())) { record.deliver($0) }
        categories.finish()
        downloads.finish(png, mime: "image/png")
        subject.serviceExtensionTimeWillExpire()
        XCTAssertEqual(record.deliveries().count, 1, "the budget wins over the receipt")

        receipts.finish(200)
        XCTAssertEqual(record.deliveries().count, 1, "a late receipt never delivers a second time")
    }

    func testAScheduledButUnfiredReceiptHoldsDelivery() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key", runScheduled: false)

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().count, 0, "the jittered receipt has not fired yet")
        XCTAssertEqual(record.deliveries().count, 0, "delivery waits for it rather than racing it")

        subject.serviceExtensionTimeWillExpire()
        XCTAssertEqual(record.deliveries().count, 1)
    }

    /// A store that holds nothing yet — the app has not registered — does not
    /// cost the receipt; it goes out on the SDK key alone.
    func testAnEmptyCredentialStorePostsTheReceiptWithoutTheDeviceHeader() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: nil)

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().count, 1)
        XCTAssertNil(record.sent().first?.value(forHTTPHeaderField: "X-OP-Device-Key"))
        XCTAssertFalse(record.reported().contains { $0.hasPrefix("receipt: skipped (") },
                       "got \(record.reported())")
        XCTAssertEqual(record.deliveries().count, 1, "the notification still renders")
    }

    func testTheDeviceHeaderIsSentWhenTheStoreHoldsACredential() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().first?.value(forHTTPHeaderField: "X-OP-Device-Key"),
                       "device-key")
    }

    func testTheReceiptRequestOmitsTheDeviceHeaderWithoutACredential() throws {
        let configuration = OpenPushConfiguration(appID: "app-1", sdkKey: "key-1",
                                                  serverURL: "https://push.example.com")
        let bare = try XCTUnwrap(OpenPushReceiptRequest.make(
            configuration: configuration, deviceCredential: nil, token: "t",
            messageID: "m-1", types: ["received"]))
        XCTAssertNil(bare.value(forHTTPHeaderField: "X-OP-Device-Key"))
        XCTAssertEqual(bare.value(forHTTPHeaderField: "X-OP-SDK-Key"), "key-1")

        let empty = try XCTUnwrap(OpenPushReceiptRequest.make(
            configuration: configuration, deviceCredential: "", token: "t",
            messageID: "m-1", types: ["received"]))
        XCTAssertNil(empty.value(forHTTPHeaderField: "X-OP-Device-Key"),
                     "an empty credential is no credential")
    }

    /// Without the App Group mirror there is still no token, and that skip — and
    /// its reason — is unchanged.
    func testMissingTokenStillSkipsWithItsReason() {
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: nil)

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().count, 0)
        XCTAssertTrue(record.reported().contains("receipt: skipped (no APNs token in the App Group)"),
                      "got \(record.reported())")
        XCTAssertEqual(record.deliveries().count, 1)
    }

    /// The shape an injected or pasted extension has: an App Group and a
    /// configuration, no Keychain store. The server authenticates a receipt on the
    /// SDK key, so the receipt is posted, with no device-key header at all.
    func testAReceiptIsPostedWithOnlyAnAppGroupAndConfiguration() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        var configured = options()
        configured.onEvent = { record.event($0) }
        XCTAssertNil(configured.credentialStore)
        let subject = OpenPushNotificationServiceHandler(
            options: configured,
            categories: categories.store,
            download: downloads.download,
            transport: { request, completion in record.send(request); completion(202) },
            scheduler: { _, work in work() },
            random: { _ in 0 })

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().count, 1, "got \(record.reported())")
        let sent = record.sent().first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "X-OP-SDK-Key"), "key-1")
        XCTAssertNil(sent?.value(forHTTPHeaderField: "X-OP-Device-Key"),
                     "no credential, no header — never an empty one")
        XCTAssertTrue(record.reported().contains("receipt: HTTP 202"))
        XCTAssertEqual(record.deliveries().count, 1)
    }

    func testMissingTokenSkipsTheReceipt() {
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        subject.didReceive(request(userInfo(image: false))) { record.deliver($0) }
        categories.finish()

        XCTAssertEqual(record.sent().count, 0)
        XCTAssertTrue(record.reported().contains { $0.hasPrefix("receipt: skipped (") })
        XCTAssertEqual(record.deliveries().count, 1)
    }

    /// The report is what the extension did, not what the payload asked for: a
    /// host that owns the category keeps it, and no button is registered at all.
    func testAHostOwnedCategoryReportsThatNothingWasRegistered() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        let content = UNMutableNotificationContent()
        content.title = "Hello"
        content.categoryIdentifier = "host.marketing"
        content.userInfo = userInfo(image: false)
        subject.didReceive(UNNotificationRequest(identifier: "req-1", content: content,
                                                 trigger: nil)) { record.deliver($0) }

        XCTAssertEqual(categories.readCount(), 0, "the host's own category is left alone")
        XCTAssertTrue(record.reported().contains("actions: 0"),
                      "the count reports what was registered, got \(record.reported())")
        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(record.deliveries().first?.categoryIdentifier, "host.marketing")
    }

    // MARK: - Foreign payloads

    func testAForeignPayloadIsDeliveredUntouched() {
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        let incoming = request(userInfo(image: true, openPush: false))
        subject.didReceive(incoming) { record.deliver($0) }

        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertTrue(record.deliveries().first === incoming.content,
                      "a notification OpenPush did not send is handed back as it arrived")
        XCTAssertEqual(categories.readCount(), 0)
        XCTAssertEqual(downloads.count(), 0)
        XCTAssertEqual(record.sent().count, 0)
    }

    // MARK: - Sharing an existing extension

    func testHandleIfOpenPushLeavesAForeignPayloadToTheCaller() {
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        let handled = subject.handleIfOpenPush(request(userInfo(openPush: false))) {
            record.deliver($0)
        }

        XCTAssertFalse(handled)
        XCTAssertEqual(record.deliveries().count, 0, "the content handler stays the caller's")
        XCTAssertEqual(categories.readCount(), 0)
        XCTAssertEqual(downloads.count(), 0)
        XCTAssertEqual(record.sent().count, 0)
        XCTAssertEqual(record.reported(), [])
    }

    func testHandleIfOpenPushTakesAnOpenPushPayloadAndDeliversOnce() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        let handled = subject.handleIfOpenPush(request(userInfo(image: false))) {
            record.deliver($0)
        }
        XCTAssertTrue(handled)
        categories.finish()

        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(record.deliveries().first?.categoryIdentifier, "op_actions_abc")
        XCTAssertEqual(record.sent().count, 1, "the receipt is posted as from didReceive")

        XCTAssertFalse(subject.serviceExtensionTimeWillExpireIfHandling(),
                       "OpenPush has delivered, so nothing of its own is pending")
        XCTAssertEqual(record.deliveries().count, 1, "the content handler is called exactly once")
    }

    func testExpiryIfHandlingDeliversAnOpenPushRequestInFlight() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        XCTAssertTrue(subject.handleIfOpenPush(request(userInfo())) { record.deliver($0) })
        categories.finish()
        XCTAssertEqual(record.deliveries().count, 0, "the image is still being fetched")

        XCTAssertTrue(subject.serviceExtensionTimeWillExpireIfHandling())
        XCTAssertEqual(record.deliveries().count, 1)
        XCTAssertEqual(record.deliveries().first?.categoryIdentifier, "op_actions_abc")

        downloads.finish(png, mime: "image/png")
        XCTAssertEqual(record.deliveries().count, 1, "a late image never delivers a second time")
    }

    func testExpiryIfHandlingLeavesAForeignRequestToTheCaller() {
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        XCTAssertFalse(subject.serviceExtensionTimeWillExpireIfHandling(),
                       "nothing has been received yet")
        XCTAssertFalse(subject.handleIfOpenPush(request(userInfo(openPush: false))) {
            record.deliver($0)
        })
        XCTAssertFalse(subject.serviceExtensionTimeWillExpireIfHandling())
        XCTAssertEqual(record.deliveries().count, 0)
    }

    /// The answer is whether OpenPush holds an undelivered request — not which
    /// request came last: a foreign push arriving while OpenPush's is still in
    /// flight does not hand OpenPush's expiry to the caller.
    func testExpiryIfHandlingAnswersForAnUndeliveredOpenPushRequest() {
        mirrorToken()
        let categories = Categories(), downloads = Downloads(), record = Record()
        let subject = handler(options(), categories: categories, downloads: downloads,
                              record: record, credential: "device-key")

        XCTAssertTrue(subject.handleIfOpenPush(request(userInfo())) { record.deliver($0) })
        categories.finish()
        XCTAssertFalse(subject.handleIfOpenPush(request(userInfo(openPush: false))) { _ in })
        XCTAssertTrue(subject.serviceExtensionTimeWillExpireIfHandling(),
                      "OpenPush's image is still loading, so its request is pending")
        XCTAssertEqual(record.deliveries().count, 1)

        XCTAssertFalse(subject.serviceExtensionTimeWillExpireIfHandling(), "and once delivered, it is not")
    }

    // MARK: - Badge increment

    private func incrementInfo(_ increment: String) -> [AnyHashable: Any] {
        var info = userInfo(image: false)
        info["op_badge_increment"] = increment
        return info
    }

    private func deliver(_ info: [AnyHashable: Any],
                         options: OpenPushNotificationServiceHandler.Options,
                         record: Record) -> UNNotificationContent? {
        let categories = Categories(), downloads = Downloads()
        let subject = handler(options, categories: categories, downloads: downloads,
                              record: record, credential: nil)
        subject.didReceive(request(info)) { record.deliver($0) }
        categories.finish()
        return record.deliveries().last
    }

    func testABadgeIncrementAddsToTheStoredCountAndStoresTheSum() {
        mirrorToken()
        let record = Record()

        XCTAssertEqual(deliver(incrementInfo("1"), options: options(), record: record)?.badge, 1)
        XCTAssertEqual(deliver(incrementInfo("2"), options: options(), record: record)?.badge, 3)
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 3)
        XCTAssertTrue(record.reported().contains("badge: 3"))
    }

    func testABadgeIncrementCountsFromWhatTheAppLastSet() {
        mirrorToken()
        OpenPushSharedState.setBadgeCount(0, appGroup: suite)
        _ = OpenPushSharedState.incrementBadgeCount(by: 9, appGroup: suite)
        OpenPushSharedState.setBadgeCount(0, appGroup: suite)

        XCTAssertEqual(deliver(incrementInfo("2"), options: options(), record: Record())?.badge, 2,
                       "the app's reset to 0 is where the next increment counts from")
    }

    func testWithoutAnAppGroupTheBadgeIsLeftUnchanged() {
        var noGroup = options()
        noGroup.appGroup = nil
        let record = Record()

        let delivered = deliver(incrementInfo("1"), options: noGroup, record: record)

        XCTAssertEqual(record.deliveries().count, 1, "the push is still delivered")
        XCTAssertNil(delivered?.badge, "no stored count to add to, so the badge is not touched")
        XCTAssertTrue(record.reported().contains("badge: skipped (no App Group)"))
    }

    func testAnAbsoluteBadgeIsRecordedAsTheStoredCount() {
        mirrorToken()
        var info = userInfo(image: false)
        info["aps"] = ["alert": ["title": "Hello"], "badge": 7, "mutable-content": 1]

        let delivered = deliver(info, options: options(), record: Record())

        XCTAssertNil(delivered?.badge, "an absolute badge is iOS's to show; the extension leaves it")
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 7,
                       "so a later increment counts up from what the icon shows")
    }

    func testAPushWithoutABadgeLeavesTheStoredCountAlone() {
        mirrorToken()
        OpenPushSharedState.setBadgeCount(4, appGroup: suite)
        let record = Record()

        XCTAssertNil(deliver(userInfo(image: false), options: options(), record: record)?.badge)
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 4)
        XCTAssertFalse(record.reported().contains { $0.hasPrefix("badge:") })
    }
}
