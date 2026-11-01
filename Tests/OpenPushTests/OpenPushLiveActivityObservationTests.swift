import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushLiveActivityObservationTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
        func paths() -> [String] { all().compactMap { $0.url?.path } }
    }

    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        func all() -> [String] { lock.withLock { ids } }
    }

    private struct FakeHandle: OpenPushLiveActivityHandle {
        var appleId: String
        var topicKey: String
        var currentPushToken: Data?
        var tokens: [Data] = []
        var stateSequence: [OpenPush.LiveActivityState] = []
        var notifications: [String] = []
        var ended: Ended?

        func pushTokens() -> AsyncStream<Data> { .finite(tokens) }
        func states() -> AsyncStream<OpenPush.LiveActivityState> { .finite(stateSequence) }
        func notificationIds() -> AsyncStream<String> { .finite(notifications) }
        func endImmediately() async { ended?.add(appleId) }
    }

    private struct FakeSource: OpenPushLiveActivitySource {
        var existing: [FakeHandle] = []
        var updates: [FakeHandle] = []
        var startTokens: [Data] = []

        func existingActivities() -> [FakeHandle] { existing }
        func activityUpdates() -> AsyncStream<FakeHandle> { .finite(updates) }
        func pushToStartTokens() -> AsyncStream<Data> { .finite(startTokens) }
    }

    private final class OpenDataStream: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<Data>.Continuation?

        func make() -> AsyncStream<Data> {
            AsyncStream { stream in
                lock.withLock { continuation = stream }
                stream.onTermination = { [self] _ in
                    lock.withLock { continuation = nil }
                }
            }
        }
    }

    private struct LongLivedHandle: OpenPushLiveActivityHandle {
        var appleId: String
        var topicKey: String
        var currentPushToken: Data?
        var openTokens: OpenDataStream

        func pushTokens() -> AsyncStream<Data> { openTokens.make() }
        func states() -> AsyncStream<OpenPush.LiveActivityState> { .finite([]) }
        func notificationIds() -> AsyncStream<String> { .finite([]) }
        func endImmediately() async {}
    }

    private struct LongLivedSource: OpenPushLiveActivitySource {
        var updates: [LongLivedHandle]

        func existingActivities() -> [LongLivedHandle] { [] }
        func activityUpdates() -> AsyncStream<LongLivedHandle> { .finite(updates) }
        func pushToStartTokens() -> AsyncStream<Data> { .finite([]) }
    }

    private final class SnapshotRace: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FakeHandle
        private var snapshotTaken = false
        private var continuation: AsyncStream<FakeHandle>.Continuation?

        init(handle: FakeHandle) { self.handle = handle }

        func existingActivities() -> [FakeHandle] {
            let waiting = lock.withLock { () -> AsyncStream<FakeHandle>.Continuation? in
                snapshotTaken = true
                let waiting = continuation
                continuation = nil
                return waiting
            }
            waiting?.yield(handle)
            waiting?.finish()
            return []
        }

        func activityUpdates() -> AsyncStream<FakeHandle> {
            AsyncStream { stream in
                let missed = lock.withLock { () -> Bool in
                    if snapshotTaken { return true }
                    continuation = stream
                    return false
                }
                if missed { stream.finish() }
            }
        }
    }

    private struct SnapshotRaceSource: OpenPushLiveActivitySource {
        let race: SnapshotRace

        func existingActivities() -> [FakeHandle] { race.existingActivities() }
        func activityUpdates() -> AsyncStream<FakeHandle> { race.activityUpdates() }
        func pushToStartTokens() -> AsyncStream<Data> { .finite([]) }
    }

    private struct FakeAuthorizationSource: OpenPushLiveActivityAuthorizationSource {
        var activitiesEnabled: Bool
        var frequentPushesEnabled: Bool
        var activityUpdates: [Bool] = []
        var frequentPushUpdates: [Bool] = []

        func activityEnablementUpdates() -> AsyncStream<Bool> { .finite(activityUpdates) }
        func frequentPushEnablementUpdates() -> AsyncStream<Bool> { .finite(frequentPushUpdates) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        func get() -> Int { lock.withLock { value } }
    }

    /// Holds the newer activity back until the older one's dismissal has
    /// actually reached the server.
    ///
    /// Both halves of the duplicate-topic claim run through one topic key and
    /// one coalescing executor: the older activity's `exit` and the newer one's
    /// registration are the same key, and they are raised from two tasks the
    /// observer runs side by side. Let them race and roughly one run in twenty
    /// has the registration overtake the unregistration, which coalesces the
    /// end away — a flake about task scheduling, not about the rule. The rule
    /// itself is "a duplicate ends the activity that was already there", so the
    /// order is part of the scenario and is stated here rather than hoped for.
    ///
    /// The wait is bounded and then yields anyway: a genuine break has to fail
    /// an assertion, never hang the suite.
    private struct AfterDismissalSource: OpenPushLiveActivitySource {
        let existing: [FakeHandle]
        let newer: FakeHandle
        let capture: Capture
        let endPath: String

        func existingActivities() -> [FakeHandle] { existing }
        func pushToStartTokens() -> AsyncStream<Data> { .finite([]) }

        func activityUpdates() -> AsyncStream<FakeHandle> {
            let capture = capture, endPath = endPath, newer = newer
            return AsyncStream { stream in
                Task {
                    for _ in 0..<200 where !capture.paths().contains(endPath) {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    stream.yield(newer)
                    stream.finish()
                }
            }
        }
    }

    private func start(_ capture: Capture) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in
                                capture.add(request); done(200, "{}")
                            })
        OpenPush.storeToken("aabb")
    }

    func testAnActivityAlreadyRunningAtLaunchIsSeeded() async throws {
        let capture = Capture()
        start(capture)
        let source = FakeSource(existing: [
            FakeHandle(appleId: "apple-1", topicKey: "match-42",
                       currentPushToken: Data([0x0A, 0xFF])),
        ])

        await OpenPush.LiveActivities.observeAndWaitForTests(
            source, activityType: "LiveScoreAttributes",
            enablePushToStart: true, enablePushToUpdate: true)

        let request = try XCTUnwrap(capture.all().last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["activity_id"] as? String, "match-42")
        XCTAssertEqual(json["update_token"] as? String, "0aff")
        XCTAssertEqual(json["activity_type"] as? String, "LiveScoreAttributes")
    }

    func testAnActivityUpdateRegistersWithoutAppearingInTheExistingSnapshot() async throws {
        let capture = Capture()
        start(capture)
        let remoteStart = FakeHandle(
            appleId: "apple-remote",
            topicKey: "match-remote",
            currentPushToken: nil,
            tokens: [Data([0xBE, 0xEF])])

        await OpenPush.LiveActivities.observeAndWaitForTests(
            FakeSource(existing: [], updates: [remoteStart]),
            activityType: "LiveScoreAttributes",
            enablePushToStart: true, enablePushToUpdate: true)

        let request = try XCTUnwrap(capture.all().last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["activity_id"] as? String, "match-remote")
        XCTAssertEqual(json["update_token"] as? String, "beef",
                       "a remotely started activity must use the object yielded by " +
                       "ActivityKit instead of waiting for the global snapshot")
    }

    func testLaterActivityRegistersWhileEarlierActivityStreamsRemainOpen() async throws {
        let capture = Capture()
        start(capture)
        let observation = Task {
            await OpenPush.LiveActivities.observeAndWaitForTests(
                LongLivedSource(updates: [
                    LongLivedHandle(appleId: "apple-first", topicKey: "match-first",
                                    currentPushToken: Data([0xAA, 0x01]),
                                    openTokens: OpenDataStream()),
                    LongLivedHandle(appleId: "apple-second", topicKey: "match-second",
                                    currentPushToken: Data([0xAA, 0x02]),
                                    openTokens: OpenDataStream()),
                ]),
                activityType: "LiveScoreAttributes",
                enablePushToStart: false, enablePushToUpdate: true)
        }

        for _ in 0..<100 where capture.all().count < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let registeredBeforeCancel = capture.all()
        observation.cancel()
        await observation.value

        let activityIds = try registeredBeforeCancel.map { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            return try XCTUnwrap(json["activity_id"] as? String)
        }
        XCTAssertEqual(Set(activityIds), ["match-first", "match-second"],
                       "one long-lived ActivityKit stream must not block later activities")
    }

    func testActivityCreatedDuringObserverStartupIsNotMissed() async throws {
        let capture = Capture()
        start(capture)
        let race = SnapshotRace(handle: FakeHandle(
            appleId: "apple-race", topicKey: "match-race",
            currentPushToken: Data([0xBE, 0xEF])))

        await OpenPush.LiveActivities.observeAndWaitForTests(
            SnapshotRaceSource(race: race), activityType: "LiveScoreAttributes",
            enablePushToStart: false, enablePushToUpdate: true)

        let request = try XCTUnwrap(capture.all().last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["activity_id"] as? String, "match-race")
    }

    func testDismissalUnregistersAndDuplicateTopicEndsOlderActivity() async {
        let capture = Capture()
        start(capture)
        let ended = Ended()
        let older = FakeHandle(appleId: "apple-2", topicKey: "match-7",
                               currentPushToken: Data([0x0A, 0xFF]),
                               stateSequence: [.active, .dismissed], ended: ended)
        let newer = FakeHandle(appleId: "apple-3", topicKey: "match-7",
                               currentPushToken: Data([0xBE, 0xEF]), ended: ended)

        let endPath = OpenPush.liveActivityEndPath(appID: "sample", activityId: "match-7")

        await OpenPush.LiveActivities.observeAndWaitForTests(
            AfterDismissalSource(existing: [older], newer: newer,
                                 capture: capture, endPath: endPath),
            activityType: "LiveScoreAttributes",
            enablePushToStart: true, enablePushToUpdate: true)

        XCTAssertTrue(capture.paths().contains(endPath),
                      "the dismissed activity is unregistered with the server")
        XCTAssertEqual(ended.all(), ["apple-2"],
                       "the duplicate ends the activity that was already on this topic")
    }

    func testSetupOptionsDisableOnlyTheirOwnTokenStreams() async {
        let capture = Capture()
        start(capture)
        let source = FakeSource(
            existing: [FakeHandle(appleId: "apple-4", topicKey: "match-8",
                                  currentPushToken: Data([0x0A, 0xFF]))],
            startTokens: [Data([0xCA, 0xFE])])

        await OpenPush.LiveActivities.observeAndWaitForTests(
            source, activityType: "LiveScoreAttributes",
            enablePushToStart: false, enablePushToUpdate: false)

        XCTAssertFalse(capture.paths().contains(OpenPush.liveActivityPath(appID: "sample")))
        XCTAssertFalse(capture.paths().contains(
            OpenPush.liveActivityStartTokenPath(appID: "sample")))
        XCTAssertEqual(OpenPush.state.liveActivityType(for: "match-8"),
                       "LiveScoreAttributes")
    }

    func testAuthorizationObservationSeedsAndTracksBothSettings() async {
        await OpenPush.LiveActivities.observeAuthorizationAndWaitForTests(
            FakeAuthorizationSource(
                activitiesEnabled: true,
                frequentPushesEnabled: false,
                activityUpdates: [false],
                frequentPushUpdates: [true]
            )
        )

        XCTAssertEqual(
            OpenPush.User.getTags()[OpenPush.LiveActivities.activitiesEnabledTagKey],
            "false"
        )
        XCTAssertEqual(
            OpenPush.User.getTags()[OpenPush.LiveActivities.frequentPushesTagKey],
            "true"
        )
    }

    func testAuthorizationObservationIsInstalledOnlyOncePerProcess() {
        let counter = Counter()

        OpenPush.LiveActivities.authorizationMonitor.start { counter.increment() }
        OpenPush.LiveActivities.authorizationMonitor.start { counter.increment() }

        XCTAssertEqual(counter.get(), 1)
    }

#if compiler(>=6.0)
    // Deliberately spells the unprefixed names: this test exists to prove the
    // deprecated typealiases still resolve to the prefixed types. The method is
    // itself marked deprecated so Swift suppresses the deprecation warnings its
    // body would otherwise emit; XCTest still discovers and runs it.
    @available(*, deprecated, message: "Exercises the deprecated aliases on purpose.")
    func testDeprecatedAliasesStillResolve() {
        let value: AnyCodable = AnyCodable(7)
        XCTAssertEqual(value.asInt(), 7)
        XCTAssertTrue(type(of: value) == OpenPushAnyCodable.self)

        let options: LiveActivitySetupOptions = LiveActivitySetupOptions(enablePushToStart: false)
        XCTAssertFalse(options.enablePushToStart)
        XCTAssertTrue(type(of: options) == OpenPushLiveActivitySetupOptions.self)
    }
#endif

    // `DefaultLiveActivityAttributes` keeps its unprefixed name because the
    // derived name is the ActivityKit `attributes-type` on the wire.
    func testDefaultAttributesDeriveTheWireActivityType() {
        XCTAssertEqual(OpenPush.LiveActivities.defaultActivityTypeName,
                       "DefaultLiveActivityAttributes")
#if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            XCTAssertEqual(
                OpenPush.LiveActivities.derivedActivityType(DefaultLiveActivityAttributes.self),
                OpenPush.LiveActivities.defaultActivityTypeName)
        }
#endif
    }
}

private extension AsyncStream {
    static func finite(_ values: [Element]) -> AsyncStream<Element> where Element: Sendable {
        AsyncStream { continuation in
            values.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
