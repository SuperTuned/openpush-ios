import XCTest
@testable import OpenPush
import OpenPushCore

/// Failed event sends back off on the shared retry schedule and then wait for
/// the next event or registration instead of retrying every two seconds; the
/// queue is capped; and events an earlier build queued still send.
final class OpenPushCustomEventBackoffTests: OpenPushTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        private var completions: [@Sendable (Int, String) -> Void] = []
        private var codes: [Int]
        private var retryAfter: Double?
        var holdResponses = false
        init(codes: [Int]) { self.codes = codes }

        func respond(_ request: URLRequest, _ done: @escaping @Sendable (Int, String) -> Void) {
            let (code, after, hold): (Int, Double?, Bool) = lock.withLock {
                if let data = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    bodies.append(json)
                }
                let code = codes.count > 1 ? codes.removeFirst() : (codes.first ?? 200)
                if holdResponses { completions.append(done) }
                return (code, retryAfter, holdResponses)
            }
            guard !hold else { return }
            if let after { OpenPush.lastRetryAfter.store(after) }
            done(code, #"{"accepted":1,"dropped":0}"#)
        }

        func setCodes(_ values: [Int]) { lock.withLock { codes = values } }
        func setRetryAfter(_ value: Double?) { lock.withLock { retryAfter = value } }
        var sends: Int { lock.withLock { bodies.count } }
        var lastNames: [String] {
            lock.withLock {
                ((bodies.last?["events"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            }
        }
        func releaseHeld(_ code: Int) {
            let due: [@Sendable (Int, String) -> Void] = lock.withLock {
                holdResponses = false
                defer { completions = [] }
                return completions
            }
            for done in due { done(code, "{}") }
        }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func count(containing text: String) -> Int {
            lock.withLock { lines.filter { $0.contains(text) }.count }
        }
    }

    private let clock = ManualClock()
    private static let eventsPath = "/v1/apps/journey-app/events"
    private var tokenKey = ""

    override func setUp() {
        super.setUp()
        tokenKey = "openpush.events.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents")
        super.tearDown()
    }

    private func attach(_ recorder: Recorder, attributed: Bool = true) {
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "journey-app", sdkKey: "sdk-public",
                                                 serverURL: "https://push.example",
                                                 tokenKey: tokenKey),
            credential: { nil },
            transport: { request, done in
                guard request.url?.path == Self.eventsPath else {
                    done(200, #"{"id":"sub-journey"}"#)
                    return
                }
                recorder.respond(request, done)
            })
        if attributed { OpenPush.state.setSubscriptionID("sub-journey") }
    }

    func testFailedSendsBackOffThenWaitForTheNextEvent() {
        let recorder = Recorder(codes: [503])
        attach(recorder)

        OpenPush.trackEvent("first")
        clock.fire(OpenPush.writeCoalescingWindow)
        XCTAssertEqual(recorder.sends, 1)
        XCTAssertEqual(clock.pendingDelays(), [2])

        clock.fire(2); clock.fire(0)
        XCTAssertEqual(recorder.sends, 2)
        XCTAssertEqual(clock.pendingDelays(), [8], "the second wait is longer than the first")

        clock.fire(8); clock.fire(0)
        XCTAssertEqual(recorder.sends, 3)
        XCTAssertEqual(clock.pendingDelays(), [],
                       "the schedule is spent: no retry every two seconds for ever")
        XCTAssertEqual(OpenPush.CustomEvents.shared.pendingCount, 1, "the event is kept")

        recorder.setCodes([200])
        OpenPush.trackEvent("second")
        clock.fire(OpenPush.writeCoalescingWindow)

        XCTAssertEqual(recorder.sends, 4)
        XCTAssertEqual(recorder.lastNames, ["first", "second"],
                       "the held event goes out with the next one")
        XCTAssertEqual(OpenPush.CustomEvents.shared.pendingCount, 0)
    }

    func testAnAcceptedRegistrationRestartsTheSchedule() {
        let recorder = Recorder(codes: [503])
        attach(recorder)
        OpenPush.trackEvent("first")
        clock.fire(OpenPush.writeCoalescingWindow)
        clock.fire(2); clock.fire(0)
        clock.fire(8); clock.fire(0)
        XCTAssertEqual(clock.pendingDelays(), [])

        OpenPush.CustomEvents.shared.registrationCompleted()
        clock.fire(0)

        XCTAssertEqual(recorder.sends, 4)
        XCTAssertEqual(clock.pendingDelays(), [2], "a fresh set of retries, starting short")
    }

    func testNewEventsWaitForAPendingRetryInsteadOfJumpingIt() {
        let recorder = Recorder(codes: [503])
        attach(recorder)
        OpenPush.trackEvent("first")
        clock.fire(OpenPush.writeCoalescingWindow)
        XCTAssertEqual(clock.pendingDelays(), [2])

        OpenPush.trackEvent("second")

        XCTAssertEqual(clock.pendingDelays(), [2],
                       "a new event must not cut the back-off short")
    }

    func testRetryAfterIsHonouredUpToTheCap() {
        let recorder = Recorder(codes: [429])
        recorder.setRetryAfter(600)
        attach(recorder)

        OpenPush.trackEvent("limited")
        clock.fire(OpenPush.writeCoalescingWindow)

        XCTAssertEqual(clock.pendingDelays(), [OpenPush.retryAfterCap])
    }

    func testTheDelayIsJittered() {
        OpenPush.retryJitter = { $0 * (1 + OpenPush.retryJitterFraction) }
        let recorder = Recorder(codes: [503])
        attach(recorder)

        OpenPush.trackEvent("jittered")
        clock.fire(OpenPush.writeCoalescingWindow)

        XCTAssertEqual(clock.pendingDelays(), [2 * (1 + OpenPush.retryJitterFraction)])
    }

    func testTheQueueKeepsTheNewestFiveHundredAndLogsOnce() {
        let recorder = Recorder(codes: [200])
        let logs = LogCapture()
        attach(recorder, attributed: false) // unattributed: held, never sent
        OpenPush.onLog = { logs.add($0) }

        for index in 0..<(OpenPush.CustomEvents.queueCap + 2) {
            OpenPush.trackEvent("event_\(index)")
        }
        waitForMainQueue()

        XCTAssertEqual(OpenPush.CustomEvents.shared.pendingCount, OpenPush.CustomEvents.queueCap)
        let stored = storedNames()
        XCTAssertEqual(stored.first, "event_2", "the two oldest were evicted")
        XCTAssertEqual(stored.last, "event_\(OpenPush.CustomEvents.queueCap + 1)")
        XCTAssertEqual(logs.count(containing: "oldest is dropped"), 1, "logged once, not per event")
    }

    func testEvictionNeverRemovesARowOfTheBatchInFlight() {
        let recorder = Recorder(codes: [200])
        recorder.holdResponses = true
        attach(recorder)
        OpenPush.trackEvent("in_flight_a")
        OpenPush.trackEvent("in_flight_b")
        clock.fire(OpenPush.writeCoalescingWindow)
        XCTAssertEqual(recorder.sends, 1)

        for index in 0..<(OpenPush.CustomEvents.queueCap - 1) {
            OpenPush.trackEvent("queued_\(index)")
        }
        XCTAssertEqual(storedNames().prefix(3), ["in_flight_a", "in_flight_b", "queued_1"],
                       "the oldest row not in flight was evicted")

        recorder.releaseHeld(200)

        XCTAssertEqual(storedNames().first, "queued_1",
                       "the response removed exactly the two rows it carried")
        XCTAssertEqual(OpenPush.CustomEvents.shared.pendingCount,
                       OpenPush.CustomEvents.queueCap - 2)
    }

    func testEventsQueuedByAnEarlierBuildStillSend() throws {
        // The stored format is unchanged: a JSON array of event rows.
        let rows: [[String: Any]] = [
            ["name": "queued_before_upgrade", "properties": ["k": "v"],
             "timestamp": 1_700_000_000.0, "idempotency_key": "key-1",
             "subscription_id": "sub-old"],
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        UserDefaults.standard.set(String(data: data, encoding: .utf8),
                                  forKey: tokenKey + ".customEvents")
        let recorder = Recorder(codes: [200])
        attach(recorder)

        OpenPush.CustomEvents.shared.registrationCompleted()
        clock.fire(0)

        XCTAssertEqual(recorder.sends, 1)
        XCTAssertEqual(recorder.lastNames, ["queued_before_upgrade"])
        XCTAssertNil(UserDefaults.standard.string(forKey: tokenKey + ".customEvents"))
    }

    func testABacklogOverTheCapFromAnEarlierBuildIsNotTrimmedOnLoad() throws {
        let rows: [[String: Any]] = (0..<600).map {
            ["name": "old_\($0)", "properties": [String: Any](), "timestamp": 1.0,
             "idempotency_key": "key-\($0)"]
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        UserDefaults.standard.set(String(data: data, encoding: .utf8),
                                  forKey: tokenKey + ".customEvents")
        let recorder = Recorder(codes: [200])
        attach(recorder, attributed: false)

        OpenPush.trackEvent("new")

        XCTAssertEqual(OpenPush.CustomEvents.shared.pendingCount, 600,
                       "one old row makes room for the new one; nothing else is dropped")
        XCTAssertEqual(storedNames().first, "old_1")
        XCTAssertEqual(storedNames().last, "new")
    }

    private func storedNames() -> [String] {
        guard let text = UserDefaults.standard.string(forKey: tokenKey + ".customEvents"),
              let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { $0["name"] as? String }
    }
}
