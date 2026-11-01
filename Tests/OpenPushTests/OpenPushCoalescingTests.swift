import XCTest
@testable import OpenPush
import OpenPushCore

final class ManualClock: @unchecked Sendable {
    private final class Item: @unchecked Sendable {
        let delay: Double
        let work: @Sendable () -> Void
        var cancelled = false

        init(delay: Double, work: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.work = work
        }
    }

    private let lock = NSLock()
    private var items: [Item] = []

    var seam: OpenPush.Scheduler {
        OpenPush.Scheduler { [self] delay, work in
            let item = Item(delay: delay, work: work)
            lock.withLock { items.append(item) }
            return OpenPush.ScheduledWork { [self] in
                lock.withLock { item.cancelled = true }
            }
        }
    }

    func pendingDelays() -> [Double] {
        lock.withLock { items.filter { !$0.cancelled }.map(\.delay) }
    }

    func fire(_ delay: Double) {
        let due: [Item] = lock.withLock {
            let matches = items.filter { !$0.cancelled && $0.delay == delay }
            items.removeAll { !$0.cancelled && $0.delay == delay }
            return matches
        }
        for item in due { item.work() }
    }
}

final class OpenPushCoalescingTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
        func count() -> Int { lock.withLock { requests.count } }
        func registrationCount() -> Int {
            lock.withLock { requests.filter { !$0.url!.path.hasSuffix("/sessions") }.count }
        }
    }

    /// Watches begin/end pairing without a UIApplication.
    final class AssertionSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var begun: [String] = []
        private var ended: [OpenPush.BackgroundAssertion.Handle] = []
        private var counter = 0

        var seam: OpenPush.BackgroundAssertion {
            OpenPush.BackgroundAssertion(
                begin: { [self] name in
                    lock.withLock {
                        counter += 1
                        begun.append(name)
                        return OpenPush.BackgroundAssertion.Handle(raw: counter)
                    }
                },
                end: { [self] handle in lock.withLock { ended.append(handle) } })
        }

        func names() -> [String] { lock.withLock { begun } }
        func endedHandles() -> [OpenPush.BackgroundAssertion.Handle] { lock.withLock { ended } }
    }

    private let clock = ManualClock()

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func start(_ capture: Capture, appID: String = "sample") {
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: appID, sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
    }

    func testEveryWriteInOneWindowRidesASingleRegistration() throws {
        let capture = Capture()
        start(capture)

        OpenPush.User.addTag(key: "plan", value: "pro")
        OpenPush.User.addTags(["seats": "12", "locale": "en-GB"])
        OpenPush.User.addAlias(label: "player_id", id: "p-1")

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])

        clock.fire(0.3)

        XCTAssertEqual(capture.count(), 1)
        let json = try body(of: capture.last())
        XCTAssertEqual(json["tags"] as? [String: String],
                       ["plan": "pro", "seats": "12", "locale": "en-GB"])
        XCTAssertEqual(json["aliases"] as? [String: String], ["player_id": "p-1"])
    }

    func testLoginCarriesAnOpenWindowInItsOwnBodyInsteadOfAddingARequest() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTag(key: "plan", value: "pro")

        OpenPush.login(externalId: "person-7")

        XCTAssertEqual(capture.count(), 1)
        let json = try body(of: capture.last())
        XCTAssertEqual(json["external_id"] as? String, "person-7")
        XCTAssertEqual(json["tags"] as? [String: String], ["plan": "pro"])
        clock.fire(0.3)
        XCTAssertEqual(capture.count(), 1)
    }

    func testAWorkspaceSwitchCancelsAPendingWindow() {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTag(key: "plan", value: "pro")

        start(capture, appID: "other")
        clock.fire(0.3)

        XCTAssertEqual(capture.registrationCount(), 1,
                       "the new workspace performs its required launch status sync, while " +
                       "the old workspace's pending write stays cancelled")
    }

    func testWritesWithoutATokenNeverArmAWindow() throws {
        let capture = Capture()
        OpenPush.scheduler = clock.seam
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(
                forKey: OpenPush.State.sessionKey(forTokenKey: tokenKey))
        }
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.add(request); done(200, "{}") })
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.User.addTag(key: "plan", value: "trial")

        XCTAssertTrue(clock.pendingDelays().isEmpty)
        OpenPush.register(token: "aabb")
        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["plan": "trial"])
    }

    func testBackgroundingSendsPendingWritesBeforeTheProcessCanBeSuspended() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTag(key: "plan", value: "pro")

        OpenPush.flushPendingWritesOnBackground()

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["plan": "pro"])
        clock.fire(0.3)
        XCTAssertEqual(capture.count(), 1)
    }

    /// The flush is started as the app is being backgrounded, so the request it
    /// raises is exactly the one iOS is about to suspend. Without an assertion
    /// held until the response lands, the pending writes are lost.
    func testTheBackgroundFlushHoldsABackgroundTaskUntilTheRegistrationCompletes() {
        let capture = Capture()
        let spy = AssertionSpy()
        OpenPush.backgroundAssertion = spy.seam
        start(capture)
        OpenPush.User.addTag(key: "plan", value: "pro")

        OpenPush.flushPendingWritesOnBackground()

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(spy.names(), ["openpush.flush"])
        XCTAssertEqual(spy.endedHandles().count, 1,
                       "an assertion that is never ended is a watchdog termination")
    }

    /// Ending immediately when there is nothing to send matters just as much:
    /// a held assertion with no work behind it burns the app's background budget.
    func testTheBackgroundFlushEndsItsTaskWhenThereIsNothingToSend() {
        let capture = Capture()
        let spy = AssertionSpy()
        OpenPush.backgroundAssertion = spy.seam
        start(capture)

        OpenPush.flushPendingWritesOnBackground()

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(spy.names(), ["openpush.flush"])
        XCTAssertEqual(spy.endedHandles().count, 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
