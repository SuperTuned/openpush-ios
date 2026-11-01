import XCTest
@testable import OpenPush
import OpenPushCore

/// An in-memory history for tests. `OpenPushTestCase` installs a fresh one
/// before every test, so no test reads or writes the real `UserDefaults` key and
/// a message id reused across tests is never mistaken for a repeat.
final class FakeClickHistory: OpenPushClickHistory, @unchecked Sendable {
    struct Unavailable: Error {}

    private let lock = NSLock()
    private var keys: [String] = []
    private var failing = false

    var recorded: [String] { lock.withLock { keys } }
    func fail(_ value: Bool) { lock.withLock { failing = value } }

    func contains(_ key: String, at now: Date) throws -> Bool {
        try lock.withLock {
            if failing { throw Unavailable() }
            return keys.contains(key)
        }
    }

    func recordIfNew(_ key: String, at now: Date) throws -> Bool {
        try lock.withLock {
            if failing { throw Unavailable() }
            guard !keys.contains(key) else { return false }
            keys.append(key)
            return true
        }
    }
}

final class OpenPushClickHistoryTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        func all() -> [String] { lock.withLock { values } }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OpenPushClickHistoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func attach(_ capture: Capture) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
    }

    /// Every `clicked` receipt the transport saw, by message id.
    private func clickedReceipts(in capture: Capture) throws -> [String] {
        try capture.all().flatMap { request -> [String] in
            guard request.url?.path == "/v1/ingest", let data = request.httpBody else { return [] }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            return events.filter { $0["type"] as? String == "clicked" }
                .compactMap { $0["message_id"] as? String }
        }
    }

    private func listen(_ seen: Lines) -> UUID {
        OpenPush.Notifications.addClickListener { event in
            seen.add((event.messageId ?? "") + (event.actionId.map { "|" + $0 } ?? ""))
        }
    }

    // MARK: - Click handling

    func testTheSameMessageTappedTwiceRunsListenersAndTheReceiptOnce() throws {
        let capture = Capture()
        let seen = Lines()
        let log = Lines()
        attach(capture)
        OpenPush.onLog = { log.add($0) }
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }
        let messageID = "msg_\(UUID().uuidString)"

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": messageID], actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": messageID], actionId: nil)

        XCTAssertEqual(seen.all(), [messageID])
        XCTAssertEqual(try clickedReceipts(in: capture), [messageID])
        XCTAssertTrue(log.all().contains { $0.contains("\(messageID)") && $0.contains("already handled") },
                      "a repeat says why it was dropped")
    }

    func testDifferentMessagesAreBothHandled() throws {
        let capture = Capture()
        let seen = Lines()
        attach(capture)
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m2"], actionId: nil)

        XCTAssertEqual(seen.all(), ["m1", "m2"])
        XCTAssertEqual(try clickedReceipts(in: capture), ["m1", "m2"])
    }

    /// iOS forwards one response per delivered notification, so a second one
    /// for the same message — whatever its action — is a tap on another copy.
    func testASecondResponseForOneMessageIsSuppressedWhateverItsAction() throws {
        let capture = Capture()
        let seen = Lines()
        attach(capture)
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }
        let userInfo: [AnyHashable: Any] = ["op_message_id": "m1"]

        OpenPush.Notifications.handleClick(userInfo: userInfo, actionId: "accept")
        OpenPush.Notifications.handleClick(userInfo: userInfo, actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: userInfo, actionId: "decline")
        OpenPush.Notifications.handleClick(userInfo: userInfo, actionId: "accept")

        XCTAssertEqual(seen.all(), ["m1|accept"],
                       "only the first response for a message runs, whatever its action")
        XCTAssertEqual(try clickedReceipts(in: capture), ["m1"])
    }

    func testARepeatOfAHeldColdStartClickIsNotHeldTwice() {
        let capture = Capture()
        let seen = Lines()
        attach(capture)

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }

        waitForMainQueue()
        XCTAssertEqual(seen.all(), ["m1"])
    }

    func testAResentCopyTappedAfterARelaunchIsRecognised() throws {
        let capture = Capture()
        let seen = Lines()
        attach(capture)
        OpenPush.clickHistory = OpenPushUserDefaultsClickHistory(defaults: defaults)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)

        // The app is killed; the resent copy cold-starts it. Only what was stored
        // survives: a new history over the same defaults, fresh process state.
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.clickHistory = OpenPushUserDefaultsClickHistory(defaults: defaults)
        attach(capture)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }

        XCTAssertEqual(seen.all(), [], "the held buffer never saw the repeat")
        XCTAssertEqual(try clickedReceipts(in: capture), ["m1"])
    }

    func testAForeignNotificationIsUntouched() throws {
        let capture = Capture()
        let seen = Lines()
        let history = FakeClickHistory()
        attach(capture)
        OpenPush.clickHistory = history
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }
        let foreign: [AnyHashable: Any] = ["aps": ["alert": "local"]]

        OpenPush.Notifications.handleClick(userInfo: foreign, actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: foreign, actionId: nil)

        XCTAssertEqual(history.recorded, [], "a push OpenPush did not send is never recorded")
        XCTAssertEqual(seen.all(), [])
        XCTAssertEqual(try clickedReceipts(in: capture), [])
        XCTAssertFalse(OpenPush.Notifications.isRepeatClick(userInfo: foreign))
    }

    func testAStorageFailureFailsOpen() throws {
        let capture = Capture()
        let seen = Lines()
        let log = Lines()
        let history = FakeClickHistory()
        history.fail(true)
        attach(capture)
        OpenPush.clickHistory = history
        OpenPush.onLog = { log.add($0) }
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)

        XCTAssertEqual(seen.all(), ["m1", "m1"], "every tap is handled when the history is down")
        XCTAssertEqual(try clickedReceipts(in: capture), ["m1"])
        XCTAssertTrue(log.all().contains { $0.contains("click history unavailable") })
        XCTAssertFalse(OpenPush.Notifications.isRepeatClick(userInfo: ["op_message_id": "m1"]))
    }

    func testStoredStateUnreadableBeforeFirstUnlockSkipsTheCheckAndWritesNothing() {
        let capture = Capture()
        let seen = Lines()
        let history = FakeClickHistory()
        attach(capture)
        OpenPush.clickHistory = history
        OpenPush.protectedDataAvailableSeam = { false }
        let listener = listen(seen)
        defer { OpenPush.Notifications.removeClickListener(listener) }

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)

        XCTAssertEqual(seen.all(), ["m1"])
        XCTAssertEqual(history.recorded, [])
    }

    func testIsRepeatClickReadsWithoutRecording() {
        let capture = Capture()
        let history = FakeClickHistory()
        attach(capture)
        OpenPush.clickHistory = history
        let userInfo: [AnyHashable: Any] = ["op_message_id": "m1"]

        XCTAssertFalse(OpenPush.Notifications.isRepeatClick(userInfo: userInfo))
        XCTAssertEqual(history.recorded, [], "asking is not handling")

        OpenPush.Notifications.handleClick(userInfo: userInfo, actionId: "accept")

        XCTAssertTrue(OpenPush.Notifications.isRepeatClick(userInfo: userInfo),
                      "a body tap after an action tap of the same message is a repeat")
        XCTAssertFalse(OpenPush.Notifications.isRepeatClick(userInfo: ["op_message_id": "m2"]))
    }

    func testRecordClickClaimsAMessageOnceAndSharesTheHistoryWithProcessClick() throws {
        let capture = Capture()
        let history = FakeClickHistory()
        attach(capture)
        OpenPush.clickHistory = history

        XCTAssertTrue(OpenPush.Notifications.recordClick(userInfo: ["op_message_id": "m1"]))
        XCTAssertFalse(OpenPush.Notifications.recordClick(userInfo: ["op_message_id": "m1"]),
                       "a bridge that handles the tap itself sees the repeat")
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "m1"], actionId: nil)
        XCTAssertEqual(try clickedReceipts(in: capture), [],
                       "the SDK path skips a message the bridge claimed")
        XCTAssertFalse(OpenPush.Notifications.recordClick(userInfo: ["no": "id"]),
                       "a notification OpenPush did not send is never claimed")
        XCTAssertEqual(history.recorded, ["m1"])
    }

    func testRecordClickFailsOpen() {
        let history = FakeClickHistory()
        history.fail(true)
        OpenPush.clickHistory = history
        XCTAssertTrue(OpenPush.Notifications.recordClick(userInfo: ["op_message_id": "m1"]))
    }

    // MARK: - The UserDefaults history

    func testTheHistoryPersistsAcrossInstances() {
        let now = Date()
        let first = OpenPushUserDefaultsClickHistory(defaults: defaults)
        XCTAssertTrue(first.recordIfNew("m1", at: now))
        XCTAssertFalse(first.recordIfNew("m1", at: now))

        let second = OpenPushUserDefaultsClickHistory(defaults: defaults)
        XCTAssertTrue(second.contains("m1", at: now))
        XCTAssertFalse(second.recordIfNew("m1", at: now))
        XCTAssertTrue(second.recordIfNew("m2", at: now))
    }

    func testTheOldestEntriesAreEvictedPastTheCap() {
        let history = OpenPushUserDefaultsClickHistory(defaults: defaults, limit: 3)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 1...4 {
            XCTAssertTrue(history.recordIfNew("m\(index)", at: start + Double(index)))
        }

        let now = start + 5
        XCTAssertFalse(history.contains("m1", at: now), "the oldest fell off")
        XCTAssertTrue(history.contains("m2", at: now))
        XCTAssertTrue(history.contains("m4", at: now))
        XCTAssertEqual(defaults.dictionary(forKey: OpenPushUserDefaultsClickHistory.storageKey)?.count, 3)
    }

    func testTheCapDefaultsToTwoHundredAndTheRetentionToAWeek() {
        XCTAssertEqual(OpenPushUserDefaultsClickHistory.defaultLimit, 200)
        XCTAssertEqual(OpenPushUserDefaultsClickHistory.defaultRetention, 7 * 24 * 60 * 60)
    }

    func testEntriesExpireAfterTheRetentionWindow() {
        let history = OpenPushUserDefaultsClickHistory(defaults: defaults, retention: 60)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(history.recordIfNew("m1", at: start))
        XCTAssertTrue(history.recordIfNew("m2", at: start + 30))

        XCTAssertTrue(history.contains("m1", at: start + 59))
        XCTAssertFalse(history.contains("m1", at: start + 61), "a week-old tap is not a repeat")
        XCTAssertTrue(history.recordIfNew("m1", at: start + 61))

        let stored = defaults.dictionary(forKey: OpenPushUserDefaultsClickHistory.storageKey)
        XCTAssertEqual(Set(stored?.keys.map { $0 } ?? []), ["m1", "m2"],
                       "expired entries are dropped from storage on the next write")
    }

    func testAnUnreadableStoredValueFailsOpenAndIsReplaced() {
        defaults.set("not a dictionary", forKey: OpenPushUserDefaultsClickHistory.storageKey)
        let history = OpenPushUserDefaultsClickHistory(defaults: defaults)
        let now = Date()

        XCTAssertFalse(history.contains("m1", at: now))
        XCTAssertTrue(history.recordIfNew("m1", at: now), "the first tap is never swallowed")
        XCTAssertFalse(history.recordIfNew("m1", at: now), "and the history works again after")
    }

    func testTheKeyIsTheMessageIdAlone() {
        XCTAssertEqual(OpenPush.Notifications.clickKey(messageId: "m1"), "m1")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
