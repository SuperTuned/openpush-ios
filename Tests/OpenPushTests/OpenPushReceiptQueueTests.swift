import XCTest
@testable import OpenPush
import OpenPushCore

/// Receipts are the SDK's only delivery evidence, so a failed one may not be
/// lost and a delivered one may not be counted twice — not even across a
/// relaunch, which is exactly where an in-memory set forgets everything.
final class OpenPushReceiptQueueTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
        func ingests() -> [URLRequest] {
            all().filter { $0.url?.path == "/v1/ingest" }
        }
    }

    /// Response codes for `/v1/ingest`, in order. The last one repeats.
    private final class Codes: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [Int]
        init(_ codes: [Int]) { self.codes = codes }
        func next() -> Int {
            lock.withLock {
                codes.count > 1 ? codes.removeFirst() : (codes.first ?? 200)
            }
        }
    }

    /// A transport that answers `/v1/ingest` only when the test says so, which is
    /// what makes a receipt observable while it is still owed.
    private final class HeldIngest: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable (Int, String) -> Void)?
        func hold(_ done: @escaping @Sendable (Int, String) -> Void) {
            lock.withLock { pending = done }
        }

        func answer(_ code: Int) {
            let done: (@Sendable (Int, String) -> Void)? = lock.withLock {
                let held = pending
                pending = nil
                return held
            }
            done?(code, #"{"accepted":1}"#)
        }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func all() -> [String] { lock.withLock { lines } }
    }

    private let clock = ManualClock()

    private func storageKey(_ tokenKey: String) -> String { tokenKey + ".receipts" }
    private func sentKey(_ tokenKey: String) -> String { tokenKey + ".receiptsSent" }

    private func clearStorage(_ tokenKey: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(tokenKey))
        UserDefaults.standard.removeObject(forKey: sentKey(tokenKey))
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(
            forKey: OpenPush.State.sessionKey(forTokenKey: tokenKey))
    }

    private func attach(_ capture: Capture, tokenKey: String, codes: Codes,
                        token: String? = "aabb") {
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                 serverURL: "https://push.example",
                                                 tokenKey: tokenKey),
            credential: { nil },
            transport: { request, done in
                capture.add(request)
                if request.url?.path == "/v1/ingest" {
                    done(codes.next(), #"{"accepted":1}"#)
                } else {
                    done(200, #"{"id":"sub_1"}"#)
                }
            })
        if let token { OpenPush.storeToken(token) }
    }

    /// A relaunch: the process-global state is gone, UserDefaults is not.
    private func coldStart(_ capture: Capture, tokenKey: String, codes: Codes) {
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.ReceiptQueue.shared.resetForTests()
        attach(capture, tokenKey: tokenKey, codes: codes, token: nil)
    }

    func testAFailedReceiptIsRetriedAndSurvivesARelaunch() throws {
        let capture = Capture()
        // The relaunch fails too, so the receipt has to reach the foreground drain
        // that runs after the retry table has already had its turn.
        let codes = Codes([503, 503, 200])
        let spy = OpenPushCoalescingTests.AssertionSpy()
        OpenPush.backgroundAssertion = spy.seam
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        attach(capture, tokenKey: tokenKey, codes: codes)

        OpenPush.receipt("received", messageID: "msg_retry")

        XCTAssertEqual(capture.ingests().count, 1, "the first attempt goes out at once")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 1)
        XCTAssertNotNil(UserDefaults.standard.string(forKey: storageKey(tokenKey)),
                        "a receipt the server did not accept must outlive this process")
        XCTAssertTrue(clock.pendingDelays().contains(2),
                      "the first retry comes from the table: \(clock.pendingDelays())")
        XCTAssertTrue(spy.names().contains("openpush.receipts"),
                      "the request holds a background task: \(spy.names())")

        // The process is gone; UserDefaults is not. The registration this launch
        // performs drains what it finds there.
        coldStart(capture, tokenKey: tokenKey, codes: codes)

        XCTAssertEqual(capture.ingests().count, 2,
                       "the queued receipt survived the relaunch and was retried")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 1,
                       "a second failure keeps it queued")
        XCTAssertTrue(clock.pendingDelays().contains(8),
                      "the retry table advanced with the attempt: \(clock.pendingDelays())")

        OpenPush.Notifications.onAppForegrounded()

        XCTAssertEqual(capture.ingests().count, 3, "the foreground drain retries the receipt")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: storageKey(tokenKey)),
                     "an accepted receipt leaves the queue")
    }

    func testDuplicateReceiptsAreDeduplicatedAcrossRelaunches() {
        let capture = Capture()
        let codes = Codes([200])
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        attach(capture, tokenKey: tokenKey, codes: codes)

        OpenPush.receipt("received", messageID: "msg_dupe")
        OpenPush.receipt("received", messageID: "msg_dupe")

        XCTAssertEqual(capture.ingests().count, 1, "the second call is the same receipt")

        coldStart(capture, tokenKey: tokenKey, codes: codes)
        OpenPush.receipt("received", messageID: "msg_dupe")

        XCTAssertEqual(capture.ingests().count, 1,
                       "a delivered receipt stays delivered across a relaunch")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 0,
                       "the duplicate was collapsed, not queued")
    }

    func testAReceiptBeforeTheTokenExistsIsSentAfterRegistration() throws {
        let capture = Capture()
        let codes = Codes([200])
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        attach(capture, tokenKey: tokenKey, codes: codes, token: nil)

        OpenPush.receipt("received", messageID: "msg_early")

        XCTAssertTrue(capture.ingests().isEmpty, "there is no token to report against yet")
        XCTAssertNotNil(UserDefaults.standard.string(forKey: storageKey(tokenKey)),
                        "the receipt waits rather than being thrown away")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 1)

        OpenPush.register(token: "aabb")

        XCTAssertEqual(capture.ingests().count, 1, "registration drains the queue")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(capture.ingests().first?.httpBody)) as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "received")
        XCTAssertEqual(events.first?["message_id"] as? String, "msg_early")
        XCTAssertEqual(events.first?["token"] as? String, "aabb")
        XCTAssertEqual(events.first?["app"] as? String, "sample")
        XCTAssertNil(UserDefaults.standard.string(forKey: storageKey(tokenKey)))
    }

    /// The ring is persisted, so an install that receives pushes for years would
    /// otherwise grow one UserDefaults string without limit.
    func testTheSentRingKeepsOnlyTheLastFiveHundredIds() throws {
        let capture = Capture()
        let codes = Codes([200])
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        attach(capture, tokenKey: tokenKey, codes: codes)

        let overflow = OpenPush.ReceiptQueue.sentLimit + 5
        for index in 0..<overflow {
            OpenPush.receipt("received", messageID: "msg_\(index)")
        }

        XCTAssertEqual(capture.ingests().count, overflow)
        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(
                    UserDefaults.standard.string(forKey: sentKey(tokenKey))?
                        .data(using: .utf8))) as? [String])
        XCTAssertEqual(stored.count, OpenPush.ReceiptQueue.sentLimit)
        XCTAssertEqual(stored.last, "received|msg_\(overflow - 1)", "the newest id is kept")
        XCTAssertFalse(stored.contains("received|msg_0"), "the oldest id has aged out")

        // An id that aged out is no longer deduplicated — the bound is a real
        // trade-off, and this is the side of it a reader should see.
        OpenPush.receipt("received", messageID: "msg_0")
        XCTAssertEqual(capture.ingests().count, overflow + 1)
    }

    /// The unsent queue is persisted too. A device that spends a month offline
    /// under a firehose must not grow one UserDefaults string without limit.
    func testTheOwedQueueDropsTheOldestBeyondFiveHundred() throws {
        let capture = Capture()
        let codes = Codes([200])
        let logs = LogCapture()
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        // No token: nothing can be sent, so everything piles up in the queue.
        attach(capture, tokenKey: tokenKey, codes: codes, token: nil)
        OpenPush.onLog = { logs.add($0) }

        let overflow = OpenPush.ReceiptQueue.pendingLimit + 5
        for index in 0..<overflow {
            OpenPush.receipt("received", messageID: "msg_\(index)")
        }

        XCTAssertTrue(capture.ingests().isEmpty, "there is no token to report against")
        XCTAssertEqual(OpenPush.pendingReceiptCount, OpenPush.ReceiptQueue.pendingLimit,
                       "the queue is capped, and the count says so")
        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(
                    UserDefaults.standard.string(forKey: storageKey(tokenKey))?
                        .data(using: .utf8))) as? [[String: Any]])
        XCTAssertEqual(stored.count, OpenPush.ReceiptQueue.pendingLimit)
        XCTAssertEqual(stored.last?["message_id"] as? String, "msg_\(overflow - 1)",
                       "the newest receipt is kept")
        XCTAssertEqual(stored.first?["message_id"] as? String, "msg_5",
                       "the oldest five aged out")
        XCTAssertEqual(logs.all().filter { $0.contains("receipt queue full") }.count, 5,
                       "each eviction says so once: \(logs.all().suffix(6))")
    }

    /// A backlog is one request per fifty, not one per receipt: the ingest
    /// contract's `events` array already carries a list.
    func testDrainSendsQueuedReceiptsInBatchesOfFifty() throws {
        let capture = Capture()
        let codes = Codes([200])
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        attach(capture, tokenKey: tokenKey, codes: codes, token: nil)

        for index in 0..<120 { OpenPush.receipt("received", messageID: "msg_\(index)") }

        XCTAssertTrue(capture.ingests().isEmpty)
        XCTAssertEqual(OpenPush.pendingReceiptCount, 120)

        OpenPush.register(token: "aabb")

        let ingests = capture.ingests()
        XCTAssertEqual(ingests.count, 3, "120 receipts are three requests, not 120")
        let counts = try ingests.map { request -> Int in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: Any])
            return try XCTUnwrap(body["events"] as? [[String: Any]]).count
        }
        XCTAssertEqual(counts, [50, 50, 20])

        // Each member of a batch keeps the keys a single receipt carries.
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(ingests.first?.httpBody))
                as? [String: Any])
        let events = try XCTUnwrap(first["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "received")
        XCTAssertEqual(events.first?["message_id"] as? String, "msg_0")
        XCTAssertEqual(events.first?["token"] as? String, "aabb")
        XCTAssertEqual(events.first?["app"] as? String, "sample")
        XCTAssertEqual(events.last?["message_id"] as? String, "msg_49")

        XCTAssertEqual(OpenPush.pendingReceiptCount, 0,
                       "a 2xx clears every member of the batch")
        XCTAssertNil(UserDefaults.standard.string(forKey: storageKey(tokenKey)))
    }

    func testA400DropsTheReceiptWithALog() {
        let capture = Capture()
        let codes = Codes([400])
        let logs = LogCapture()
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        attach(capture, tokenKey: tokenKey, codes: codes)
        OpenPush.onLog = { logs.add($0) }

        OpenPush.receipt("received", messageID: "msg_bad")

        XCTAssertEqual(capture.ingests().count, 1)
        XCTAssertFalse(clock.pendingDelays().contains(2), "a rejected receipt is not retried")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: storageKey(tokenKey)),
                     "a receipt the server refuses is dropped, not kept forever")
        XCTAssertTrue(logs.all().contains { $0.contains("receipt dropped (4xx)") },
                      "the drop is explained: \(logs.all())")
    }

    /// `OpenPush.pendingReceiptCount` is the public spelling of the queue depth —
    /// what a host puts on its own diagnostics screen. Holding the response open
    /// is what makes it observable: the receipt is queued before the request is
    /// answered, and leaves the queue only once the server has accepted it.
    func testPendingReceiptCountReportsWhatIsStillOwed() {
        let capture = Capture()
        let held = HeldIngest()
        let tokenKey = "openpush.receipts.\(UUID().uuidString)"
        defer { clearStorage(tokenKey) }
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                 serverURL: "https://push.example",
                                                 tokenKey: tokenKey),
            credential: { nil },
            transport: { request, done in
                capture.add(request)
                if request.url?.path == "/v1/ingest" {
                    held.hold(done)
                } else {
                    done(200, #"{"id":"sub_1"}"#)
                }
            })
        OpenPush.storeToken("aabb")

        XCTAssertEqual(OpenPush.pendingReceiptCount, 0, "nothing is owed yet")

        OpenPush.receipt("received", messageID: "msg_pending")

        XCTAssertEqual(capture.ingests().count, 1, "the receipt is in flight")
        XCTAssertEqual(OpenPush.pendingReceiptCount, 1,
                       "a receipt the server has not accepted is still owed")

        held.answer(200)

        XCTAssertEqual(OpenPush.pendingReceiptCount, 0,
                       "an accepted receipt is no longer owed")
    }
}
