import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushCustomEventTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func add(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
        }

        func all() -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    /// A status code per events request; the last one repeats, so `[503, 200]`
    /// fails the first attempt and accepts the retry.
    private final class Codes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int]
        init(_ values: [Int]) { self.values = values }

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            return values.count > 1 ? values.removeFirst() : (values.first ?? 200)
        }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// Transport completions the test refuses to call, so a flush stays in
    /// flight for as long as it needs to. Released on the way out, because a
    /// completion dropped on the floor leaks the background assertion with it.
    private final class HeldCompletions: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [@Sendable (Int, String) -> Void] = []

        func hold(_ done: @escaping @Sendable (Int, String) -> Void) {
            lock.lock(); defer { lock.unlock() }
            held.append(done)
        }

        func count() -> Int { lock.lock(); defer { lock.unlock() }; return held.count }

        func release() {
            lock.lock()
            let due = held
            held = []
            lock.unlock()
            for done in due { done(200, #"{"accepted":0,"dropped":0}"#) }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); defer { lock.unlock() }; value = true }
        func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let clock = ManualClock()

    private static let eventsPath = "/v1/apps/journey-app/events"

    private func attach(_ capture: Capture, tokenKey: String, eventCodes: [Int] = [200]) {
        let codes = Codes(eventCodes)
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(
                appID: "journey-app", sdkKey: "sdk-public",
                serverURL: "https://push.example", tokenKey: tokenKey),
            credential: { nil },
            transport: { request, done in
                capture.add(request)
                let code = request.url?.path == Self.eventsPath ? codes.next() : 200
                done(code, #"{"accepted":2,"dropped":0}"#)
            })
        OpenPush.state.setSubscriptionID("sub-journey")
    }

    /// The `idempotency_key` of every event, grouped by events request, in order.
    private func idempotencyKeys(in capture: Capture) throws -> [[String]] {
        try capture.all()
            .filter { $0.url?.path == Self.eventsPath }
            .map { request in
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                        as? [String: Any])
                let events = try XCTUnwrap(body["events"] as? [[String: Any]])
                return try events.map { try XCTUnwrap($0["idempotency_key"] as? String) }
            }
    }

    func testNearbyEventsShareOneAttributedRequest() throws {
        let capture = Capture()
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey)

        OpenPush.trackEvent("onboarding_started", properties: ["step": 1])
        OpenPush.trackEvent("onboarding_finished", properties: ["step": 2])

        XCTAssertEqual(clock.pendingDelays(), [OpenPush.writeCoalescingWindow])
        clock.fire(OpenPush.writeCoalescingWindow)

        let request = try XCTUnwrap(capture.all().last)
        XCTAssertEqual(request.url?.path, "/v1/apps/journey-app/events")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["name"] as? String },
                       ["onboarding_started", "onboarding_finished"])
        XCTAssertTrue(events.allSatisfy { $0["subscription_id"] as? String == "sub-journey" })
    }

    func testInvalidEventDoesNotScheduleOrPersist() {
        let capture = Capture()
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey)

        OpenPush.trackEvent("bad/event", properties: [:])
        OpenPush.trackEvent("not_json", properties: ["value": Double.nan])

        XCTAssertTrue(clock.pendingDelays().isEmpty)
        XCTAssertNil(UserDefaults.standard.string(forKey: tokenKey + ".customEvents"))
    }

    func testWorkspaceSwitchClearsQueuedEvents() {
        let capture = Capture()
        let firstKey = "openpush.events.first.\(UUID().uuidString)"
        let secondKey = "openpush.events.second.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: firstKey + ".customEvents")
            UserDefaults.standard.removeObject(forKey: secondKey + ".customEvents")
        }
        attach(capture, tokenKey: firstKey)
        OpenPush.trackEvent("belongs_to_first_workspace")

        attach(capture, tokenKey: secondKey)
        OpenPush.CustomEvents.shared.registrationCompleted()
        clock.fire(0)

        XCTAssertNil(UserDefaults.standard.string(forKey: firstKey + ".customEvents"),
                     "the workspace being left keeps nothing queued")
        XCTAssertTrue(capture.all().allSatisfy { $0.url?.path != "/v1/apps/journey-app/events" })
    }

    /// A workspace switch takes `State`'s lock and then had to reach into the
    /// Custom Event queue's; the queue takes its own lock and reaches back into
    /// `State` for the scheduler. Two locks taken in both orders is a deadlock,
    /// and the moment both happen at once is a switch landing on a queue that is
    /// still flushing. Neither thread may block: the timeout is the assertion.
    func testAWorkspaceSwitchDuringAFlushNeverDeadlocks() {
        let capture = Capture()
        let held = HeldCompletions()
        let firstKey = "openpush.events.lockA.\(UUID().uuidString)"
        let secondKey = "openpush.events.lockB.\(UUID().uuidString)"
        defer {
            held.release()
            UserDefaults.standard.removeObject(forKey: firstKey + ".customEvents")
            UserDefaults.standard.removeObject(forKey: secondKey + ".customEvents")
        }
        OpenPush.scheduler = clock.seam
        let transport: OpenPush.Transport = { request, done in
            capture.add(request)
            // The batch never comes back, so the queue stays in flight for the
            // whole test and every switch lands on a flush that is still open.
            if request.url?.path == Self.eventsPath { held.hold(done); return }
            done(200, "{}")
        }
        func configuration(_ tokenKey: String) -> OpenPushConfiguration {
            OpenPushConfiguration(appID: "journey-app", sdkKey: "sdk-public",
                                  serverURL: "https://push.example", tokenKey: tokenKey)
        }
        OpenPush.attach(configuration: configuration(firstKey),
                        credential: { nil }, transport: transport)
        OpenPush.state.setSubscriptionID("sub-journey")
        OpenPush.trackEvent("in_flight")
        clock.fire(OpenPush.writeCoalescingWindow)
        XCTAssertEqual(held.count(), 1,
                       "the batch is in flight and its completion is deliberately held")

        let stop = Flag()
        let tracking = expectation(description: "the tracking thread finished")
        DispatchQueue.global().async {
            while !stop.isSet() { OpenPush.trackEvent("contending_event") }
            tracking.fulfill()
        }
        let switching = expectation(description: "every workspace switch returned")
        DispatchQueue.global().async {
            for index in 0..<200 {
                OpenPush.attach(configuration: configuration(index.isMultiple(of: 2)
                                                             ? secondKey : firstKey),
                                credential: { nil }, transport: transport)
            }
            switching.fulfill()
        }
        wait(for: [switching], timeout: 20)
        stop.set()
        wait(for: [tracking], timeout: 20)
    }

    /// Custom events have no background hook of their own: the coalescing window
    /// simply expires wherever the app happens to be, which is often just after
    /// it was backgrounded. The request needs the same protection as the flush.
    func testTheEventRequestHoldsABackgroundTask() {
        let capture = Capture()
        let spy = OpenPushCoalescingTests.AssertionSpy()
        OpenPush.backgroundAssertion = spy.seam
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey)

        OpenPush.trackEvent("onboarding_started")
        clock.fire(OpenPush.writeCoalescingWindow)

        XCTAssertEqual(capture.all().count, 1)
        XCTAssertEqual(spy.names(), ["openpush.events"])
        XCTAssertEqual(spy.endedHandles().count, 1)
    }

    /// Two calls that look identical are two events. The key is what lets a
    /// resent batch be recognised as a repeat, so it belongs to the call, not to
    /// the name.
    func testEveryEventCarriesAUniqueIdempotencyKey() throws {
        let capture = Capture()
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey)

        OpenPush.trackEvent("level_complete", properties: ["level": 1])
        OpenPush.trackEvent("level_complete", properties: ["level": 1])
        clock.fire(OpenPush.writeCoalescingWindow)

        let keys = try idempotencyKeys(in: capture)
        XCTAssertEqual(keys.count, 1, "the two events shared one request")
        XCTAssertEqual(keys[0].count, 2, "every event carries a key")
        XCTAssertEqual(Set(keys[0]).count, 2,
                       "two identical calls are two events, not one")
    }

    /// The server's rule is ASCII. `CharacterSet.alphanumerics` is the whole of
    /// Unicode, so a client that accepted it would send names the server refuses
    /// — and a refused batch would retry forever.
    func testANonASCIIEventNameIsDroppedAtTheCallSite() {
        let capture = Capture()
        let logs = LogCapture()
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey)
        OpenPush.onLog = { logs.add($0) }

        OpenPush.trackEvent("niveau_terminé")
        OpenPush.trackEvent("レベル完了")
        OpenPush.trackEvent("emoji_🎉")

        XCTAssertTrue(clock.pendingDelays().isEmpty,
                      "nothing was queued, so nothing is scheduled")
        XCTAssertNil(UserDefaults.standard.string(forKey: tokenKey + ".customEvents"))
        XCTAssertTrue(capture.all().allSatisfy { $0.url?.path != Self.eventsPath })
        XCTAssertEqual(logs.all().filter { $0.contains("^[a-zA-Z0-9_\\-. ]+$") }.count, 3,
                       "each drop names the rule: \(logs.all())")

        // The same word in the ASCII the server accepts still goes through.
        OpenPush.trackEvent("niveau termine-1.0")
        XCTAssertEqual(clock.pendingDelays(), [OpenPush.writeCoalescingWindow])
    }

    /// A 4xx that is not a 429 is the server saying it will never take this
    /// batch. Retrying it every two seconds wedges every later event behind it.
    func testA400DropsTheEventBatchWithALog() throws {
        let capture = Capture()
        let logs = LogCapture()
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey, eventCodes: [400, 200])
        OpenPush.onLog = { logs.add($0) }

        OpenPush.trackEvent("refused_by_the_server")
        clock.fire(OpenPush.writeCoalescingWindow)

        XCTAssertEqual(capture.all().filter { $0.url?.path == Self.eventsPath }.count, 1)
        XCTAssertNil(UserDefaults.standard.string(forKey: tokenKey + ".customEvents"),
                     "a batch the server refuses is dropped, not kept forever")
        XCTAssertFalse(clock.pendingDelays().contains(2),
                       "a refused batch is not retried: \(clock.pendingDelays())")
        XCTAssertTrue(logs.all().contains { $0.contains("custom events dropped (400)") },
                      "the drop is explained: \(logs.all())")

        // The pipeline is not wedged: the next event still flushes.
        OpenPush.trackEvent("accepted_after_the_drop")
        clock.fire(OpenPush.writeCoalescingWindow)

        let requests = capture.all().filter { $0.url?.path == Self.eventsPath }
        XCTAssertEqual(requests.count, 2)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last?.httpBody))
                as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["name"] as? String }, ["accepted_after_the_drop"],
                       "the refused event is gone; only the new one is sent")
    }

    /// The retry resends the persisted rows verbatim. Minting the keys at send
    /// time instead of at call time would make the server count the batch twice.
    func testARetriedBatchResendsTheSameKeys() throws {
        let capture = Capture()
        let tokenKey = "openpush.events.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents") }
        attach(capture, tokenKey: tokenKey, eventCodes: [503, 200])

        OpenPush.trackEvent("checkout_started")
        OpenPush.trackEvent("checkout_finished")
        clock.fire(OpenPush.writeCoalescingWindow)
        clock.fire(2)
        clock.fire(0)

        let keys = try idempotencyKeys(in: capture)
        XCTAssertEqual(keys.count, 2, "the rejected batch was sent again")
        XCTAssertEqual(keys[0].count, 2)
        XCTAssertEqual(keys[0], keys[1],
                       "the retry carries the keys the first attempt carried")
    }
}
