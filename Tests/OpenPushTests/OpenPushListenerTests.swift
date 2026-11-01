import XCTest
import UserNotifications
@testable import OpenPush
import OpenPushCore

final class OpenPushListenerTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
    }

    private final class ClickBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.ClickEvent?
        func set(_ newValue: OpenPush.ClickEvent) { lock.withLock { value = newValue } }
        func get() -> OpenPush.ClickEvent? { lock.withLock { value } }
    }

    private final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        func all() -> [String] { lock.withLock { values } }
    }

    private final class ForegroundBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.ForegroundEvent?
        func set(_ newValue: OpenPush.ForegroundEvent) { lock.withLock { value = newValue } }
        func get() -> OpenPush.ForegroundEvent? { lock.withLock { value } }
    }

    private final class OptionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UNNotificationPresentationOptions] = []
        func add(_ value: UNNotificationPresentationOptions) {
            lock.withLock { values.append(value) }
        }
        func all() -> [UNNotificationPresentationOptions] { lock.withLock { values } }
    }

    private let clock = ManualClock()

    private func receiptTypes(in capture: Capture) throws -> [String] {
        try capture.all().compactMap { request -> String? in
            guard request.url?.path == "/v1/ingest", let data = request.httpBody else { return nil }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            return events.first?["type"] as? String
        }
    }

    private func attach(_ capture: Capture) {
        OpenPush.permissionSeam = OpenPush.PermissionSeam(
            status: { done in done(.granted) },
            request: { _, done in done(true) },
            openSettings: {},
            registerForRemoteNotifications: {})
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
    }

    override func tearDown() {
        OpenPush.permissionSeam = .system
        super.tearDown()
    }

    // `payload` is deprecated; these two cases cover it until it is removed.
    @available(*, deprecated)
    func testForegroundNotificationPresentsByDefaultAndPostsDeliveryReceipts() throws {
        let capture = Capture()
        let box = ForegroundBox()
        attach(capture)
        let listener = OpenPush.Notifications.addForegroundLifecycleListener { box.set($0) }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(listener) }
        let messageID = "msg_\(UUID().uuidString)"

        let options = OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": messageID, "deep_link": "app://home"])

        XCTAssertEqual(options, [.banner, .list, .sound, .badge])
        XCTAssertEqual(box.get()?.messageId, messageID)
        XCTAssertEqual(box.get()?.payload["deep_link"], "app://home")
        XCTAssertEqual(try receiptTypes(in: capture), ["received", "confirmed"])
    }

    func testPreventDefaultSuppressesTheSystemPresentation() throws {
        let capture = Capture()
        attach(capture)
        let listener = OpenPush.Notifications.addForegroundLifecycleListener { event in
            event.preventDefault()
        }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(listener) }

        let options = OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "msg_\(UUID().uuidString)"])

        XCTAssertEqual(options, [])
        XCTAssertEqual(try receiptTypes(in: capture), ["received"],
                       "a suppressed notification was received but not displayed")
    }

    func testRemovedForegroundListenerStopsReceivingEvents() {
        let capture = Capture()
        let box = ForegroundBox()
        attach(capture)
        let listener = OpenPush.Notifications.addForegroundLifecycleListener { box.set($0) }
        OpenPush.Notifications.removeForegroundLifecycleListener(listener)

        _ = OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "msg_\(UUID().uuidString)"])

        XCTAssertNil(box.get())
    }

    // `payload` is deprecated; these two cases cover it until it is removed.
    @available(*, deprecated)
    func testClickPostsAClickedReceiptAndDeliversAStringCoercedPayload() throws {
        let capture = Capture()
        let box = ClickBox()
        attach(capture)
        let listener = OpenPush.Notifications.addClickListener { box.set($0) }
        defer { OpenPush.Notifications.removeClickListener(listener) }
        let messageID = "msg_\(UUID().uuidString)"

        OpenPush.Notifications.handleClick(
            userInfo: ["op_message_id": messageID, "deep_link": "app://offer", "badge": 7],
            actionId: "open_offer")

        let event = try XCTUnwrap(box.get())
        XCTAssertEqual(event.messageId, messageID)
        XCTAssertEqual(event.actionId, "open_offer")
        XCTAssertEqual(event.payload["deep_link"], "app://offer")
        XCTAssertEqual(event.payload["badge"], "7", "numbers are coerced, not dropped")
        XCTAssertEqual(try receiptTypes(in: capture), ["clicked"])
    }

    func testDuplicateForegroundDeliveryPostsOneReceipt() throws {
        let capture = Capture()
        attach(capture)
        let userInfo: [AnyHashable: Any] = ["op_message_id": "msg_\(UUID().uuidString)"]

        _ = OpenPush.Notifications.handleForeground(userInfo: userInfo)
        _ = OpenPush.Notifications.handleForeground(userInfo: userInfo)

        XCTAssertEqual(try receiptTypes(in: capture), ["received", "confirmed"],
                       "each delivery rung is deduplicated for the same message")
    }

    func testADismissIsNotAClickAndTheDefaultActionHasNoActionId() {
        XCTAssertEqual(OpenPush.Notifications.clickDisposition(
            for: UNNotificationDismissActionIdentifier), .dismissed)
        XCTAssertEqual(OpenPush.Notifications.clickDisposition(
            for: UNNotificationDefaultActionIdentifier), .open(actionId: nil))
        XCTAssertEqual(OpenPush.Notifications.clickDisposition(for: "open_offer"),
                       .open(actionId: "open_offer"))
    }

    func testAClickBeforeAnyListenerIsAttachedIsDeliveredToTheFirstListener() throws {
        let capture = Capture()
        let box = ClickBox()
        attach(capture)
        let messageID = "msg_\(UUID().uuidString)"

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": messageID], actionId: nil)
        XCTAssertEqual(try receiptTypes(in: capture), ["clicked"], "the receipt never waits")

        let listener = OpenPush.Notifications.addClickListener { box.set($0) }
        defer { OpenPush.Notifications.removeClickListener(listener) }

        waitForMainQueue()
        XCTAssertEqual(box.get()?.messageId, messageID,
                       "a tap that cold-started the app must reach the listener the host adds later")
    }

    func testHeldClicksAreDeliveredOnceAndInOrder() {
        let capture = Capture()
        attach(capture)
        let seen = OrderBox()
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m2"], actionId: nil)

        let first = OpenPush.Notifications.addClickListener { seen.add($0.messageId ?? "") }
        defer { OpenPush.Notifications.removeClickListener(first) }
        let second = OpenPush.Notifications.addClickListener { seen.add("second:" + ($0.messageId ?? "")) }
        defer { OpenPush.Notifications.removeClickListener(second) }

        waitForMainQueue()
        XCTAssertEqual(seen.all(), ["m1", "m2"], "only the first listener drains the buffer")

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m3"], actionId: nil)

        waitForMainQueue()
        XCTAssertEqual(seen.all().dropFirst(2).sorted(), ["m3", "second:m3"],
                       "a click after both are attached reaches both listeners")
    }

    func testTheHeldClickBufferKeepsTheTenMostRecent() {
        let capture = Capture()
        attach(capture)
        let seen = OrderBox()
        for index in 1...12 {
            OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m\(index)"],
                                               actionId: nil)
        }

        let listener = OpenPush.Notifications.addClickListener { seen.add($0.messageId ?? "") }
        defer { OpenPush.Notifications.removeClickListener(listener) }

        waitForMainQueue()
        XCTAssertEqual(seen.all(), (3...12).map { "m\($0)" },
                       "the buffer keeps the ten most recent clicks; the oldest two fall off")
    }

    func testServerUTMUrlSurvivesForegroundAndColdStartActionClick() throws {
        let capture = Capture()
        attach(capture)
        let url = "https://example.com/offers?utm_source=owned&utm_medium=push&utm_campaign=Launch+day&utm_term=a%2Bb&coupon=&coupon=SAVE#details"
        let payload: [AnyHashable: Any] = ["op_message_id": "utm-1", "deep_link": url]
        let click = ClickBox()
        let foreground = ForegroundBox()
        let f = OpenPush.Notifications.addForegroundLifecycleListener { foreground.set($0) }
        _ = OpenPush.Notifications.handleForeground(userInfo: payload)
        // Queue a cold-start click before its listener is attached.
        OpenPush.Notifications.handleClick(userInfo: payload, actionId: "open")
        let c = OpenPush.Notifications.addClickListener { click.set($0) }
        defer { OpenPush.Notifications.removeClickListener(c); OpenPush.Notifications.removeForegroundLifecycleListener(f) }
        waitForMainQueue()
        XCTAssertEqual(click.get()?.actionId, "open")
        XCTAssertEqual(click.get()?.notification.launchURL?.absoluteString, url)
        XCTAssertEqual(click.get()?.notification.rawPayload["deep_link"], .string(url))
        XCTAssertEqual(foreground.get()?.notification.launchURL?.absoluteString, url)
    }

    func testClickAndForegroundEventsCarryTheNotificationModel() throws {
        let capture = Capture()
        let click = ClickBox()
        let fore = ForegroundBox()
        attach(capture)
        let c = OpenPush.Notifications.addClickListener { click.set($0) }
        let f = OpenPush.Notifications.addForegroundLifecycleListener { fore.set($0) }
        defer { OpenPush.Notifications.removeClickListener(c); OpenPush.Notifications.removeForegroundLifecycleListener(f) }
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "T", "body": "B"]],
                                            "op_message_id": "m1", "deep_link": "app://x",
                                            "data": ["nested": ["k": 1]]]

        OpenPush.Notifications.handleClick(userInfo: userInfo, actionId: nil)
        _ = OpenPush.Notifications.handleForeground(userInfo: userInfo)

        XCTAssertEqual(click.get()?.notification.title, "T")
        XCTAssertEqual(click.get()?.notification.launchURL, URL(string: "app://x"))
        XCTAssertEqual(click.get()?.notification.additionalData["data"]?["nested"]?["k"]?.numberValue, 1)
        XCTAssertEqual(fore.get()?.notification.body, "B")
    }

    func testAForeignForegroundNotificationIsPresentedButNotReportedAsOurs() throws {
        let capture = Capture()
        let fore = ForegroundBox()
        attach(capture)
        let f = OpenPush.Notifications.addForegroundLifecycleListener { fore.set($0) }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(f) }

        let options = OpenPush.Notifications.handleForeground(userInfo: ["aps": ["alert": "local"]])

        XCTAssertEqual(options, OpenPush.Notifications.defaultPresentation)
        XCTAssertNil(fore.get(), "a host's own local notification is not an OpenPush event (D20)")
        XCTAssertEqual(try receiptTypes(in: capture), [])
    }

    /// A host that suppresses the system banner to show its own may find a moment
    /// later that it could not — the in-app surface was busy, or the user waved it
    /// away. `display()` hands the decision back to iOS instead of losing the
    /// notification.
    func testDisplayAfterPreventDefaultPresentsTheNotification() throws {
        OpenPush.scheduler = clock.seam
        let capture = Capture()
        let held = ForegroundBox()
        let seen = OptionsBox()
        attach(capture)
        let listener = OpenPush.Notifications.addForegroundLifecycleListener { event in
            event.preventDefault()
            held.set(event)
        }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(listener) }

        OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "msg_\(UUID().uuidString)"]) { seen.add($0) }

        XCTAssertEqual(seen.all(), [], "the answer waits while the host shows its own UI")

        let event = try XCTUnwrap(held.get())
        event.display()

        XCTAssertEqual(seen.all(), [OpenPush.Notifications.defaultPresentation])
        XCTAssertEqual(try receiptTypes(in: capture), ["received", "confirmed"])

        event.display()
        clock.fire(OpenPush.Notifications.deferredDisplayWindow)
        XCTAssertEqual(seen.all().count, 1,
                       "the delegate's completion handler runs exactly once")
    }

    /// iOS does not wait forever for `willPresent` to answer. A host that prevents
    /// the default and then never calls `display()` gets the suppression it asked
    /// for, rather than a delegate that never returns.
    func testTheDeferredDecisionTimesOutToSuppressed() throws {
        OpenPush.scheduler = clock.seam
        let capture = Capture()
        let seen = OptionsBox()
        attach(capture)
        let listener = OpenPush.Notifications.addForegroundLifecycleListener {
            $0.preventDefault()
        }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(listener) }

        OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "msg_\(UUID().uuidString)"]) { seen.add($0) }

        XCTAssertTrue(clock.pendingDelays()
            .contains(OpenPush.Notifications.deferredDisplayWindow))
        XCTAssertEqual(seen.all(), [])

        clock.fire(OpenPush.Notifications.deferredDisplayWindow)

        XCTAssertEqual(seen.all(), [UNNotificationPresentationOptions([])])
        XCTAssertEqual(try receiptTypes(in: capture), ["received"],
                       "a timed-out deferred display remains suppressed")
    }

    /// Nothing is held unless a listener asked for it: the asynchronous spelling
    /// costs a host that never prevents the default exactly nothing, and reports
    /// the delivery just as the synchronous one does.
    func testWithoutPreventDefaultTheAsyncPathCompletesImmediately() throws {
        OpenPush.scheduler = clock.seam
        let capture = Capture()
        let seen = OptionsBox()
        let box = ForegroundBox()
        attach(capture)
        let listener = OpenPush.Notifications.addForegroundLifecycleListener { box.set($0) }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(listener) }

        OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "msg_\(UUID().uuidString)"]) { seen.add($0) }

        XCTAssertEqual(seen.all(), [OpenPush.Notifications.defaultPresentation])
        XCTAssertFalse(clock.pendingDelays()
            .contains(OpenPush.Notifications.deferredDisplayWindow),
                       "nothing is held, so nothing has to time out")
        XCTAssertEqual(try receiptTypes(in: capture), ["received", "confirmed"])

        // A notification OpenPush did not send reaches no listener and is
        // presented as iOS would, without waiting.
        OpenPush.Notifications.handleForeground(
            userInfo: ["aps": ["alert": "local"]]) { seen.add($0) }

        XCTAssertEqual(seen.all(), Array(repeating: OpenPush.Notifications.defaultPresentation,
                                         count: 2))
        XCTAssertEqual(try receiptTypes(in: capture), ["received", "confirmed"],
                       "a foreign notification is still not ours to report")

        // `display()` without a preceding `preventDefault()` is a no-op.
        try XCTUnwrap(box.get()).display()
        XCTAssertEqual(seen.all().count, 2)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
