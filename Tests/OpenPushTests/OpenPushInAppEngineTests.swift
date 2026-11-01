import XCTest
@testable import OpenPush
import OpenPushCore

/// Drives the in-app engine end to end through the transport seam and a
/// recording presenter. `rows` is the `in_app_messages` array the fetch returns.
final class IamHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var ingest: [[String: Any]] = []
    private var fetches = 0
    private var presented: [(message: OpenPush.IamMessage,
                             emit: @Sendable (OpenPush.IamPresentation.Event) -> Void)] = []
    private var dismissals = 0
    var fetchStatus = 200
    var rows: String
    let clock = ManualClock()

    init(rows: String) {
        self.rows = rows
        OpenPush.scheduler = clock.seam
        OpenPush.IamEngine.shared.setPresenter { [self] message, emit in
            lock.withLock { presented.append((message, emit)) }
        }
        OpenPush.IamEngine.shared.setDismisser { [self] in lock.withLock { dismissals += 1 } }
        OpenPush.initialize(
            appId: "sample", sdkKey: "sdk_public", serverURL: "https://push.example",
            transport: { [self] request, done in
                switch request.url?.path {
                case "/v1/apps/sample/subscriptions":
                    done(200, #"{"id":"sub_1"}"#)
                case "/v1/apps/sample/subscriptions/sub_1/iams":
                    let status = lock.withLock { fetches += 1; return fetchStatus }
                    let rows = lock.withLock { self.rows }
                    done(status, status == 200 ? #"{"in_app_messages":\#(rows)}"# : "")
                case "/v1/ingest":
                    if let data = request.httpBody,
                       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let events = root["events"] as? [[String: Any]] {
                        lock.withLock { ingest.append(contentsOf: events) }
                    }
                    done(200, #"{"accepted":1,"dropped":0}"#)
                default:
                    done(404, "")
                }
            })
        OpenPush.register(token: "aabbcc")
        // These tests are the ones that do want the registration-driven fetch,
        // and `fetch()` is how they ask for it. Armed after the registration
        // above so the count starts at zero on a UIKit destination too, where
        // that registration would otherwise have fetched once already.
        OpenPush.IamEngine.shared.setAutomaticFetchForTests(true)
    }

    func fetch() { OpenPush.InAppMessages.onSubscriptionReady() }
    func presentedIds() -> [String] { lock.withLock { presented.map(\.message.id) } }
    func presentedLayouts() -> [String] { lock.withLock { presented.map(\.message.layout) } }
    func emitLast(_ event: OpenPush.IamPresentation.Event) {
        let last = lock.withLock { presented.last }
        last?.emit(event)
    }
    /// Emits through the closure a specific presentation was given, so a test
    /// can speak for a presentation that is no longer the current one.
    func emit(at index: Int, _ event: OpenPush.IamPresentation.Event) {
        let entry = lock.withLock { index < presented.count ? presented[index] : nil }
        entry?.emit(event)
    }
    func ingestTypes() -> [String] { lock.withLock { ingest.compactMap { $0["type"] as? String } } }
    func ingestEvents() -> [[String: Any]] { lock.withLock { ingest } }
    func dismissCount() -> Int { lock.withLock { dismissals } }
    func fetchCount() -> Int { lock.withLock { fetches } }

    static func row(id: String, layout: String = "center", triggers: String = "[]",
                    extra: String = "") -> String {
        #"{"id":"\#(id)","html_path":"/v1/apps/sample/iams/\#(id)/html","layout":"\#(layout)","triggers":\#(triggers)\#(extra)}"#
    }
}

final class OpenPushInAppEngineTests: OpenPushTestCase {
    func testImpressionAndDidDisplayWaitForTheDocumentToRender() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        let phases = PhaseBox()
        let listener = OpenPush.InAppMessages.addLifecycleListener { phases.add($0.phase) }
        defer { OpenPush.InAppMessages.removeLifecycleListener(listener) }

        harness.fetch()

        XCTAssertEqual(harness.presentedIds(), ["iam_1"])
        waitForMainQueue()
        XCTAssertEqual(phases.all(), ["willDisplay"], "didDisplay must wait for the render")
        XCTAssertEqual(harness.ingestTypes(), [], "no impression before anything is on screen")

        harness.emitLast(.rendered(height: 320))

        waitForMainQueue()
        XCTAssertEqual(phases.all(), ["willDisplay", "didDisplay"])
        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"])

        harness.emitLast(.rendered(height: 320))
        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"], "one impression per presentation")
    }

    /// Sizing a banner to its document is the presenter's job alone. This pins
    /// the other half of that bargain: the engine hands the layout through
    /// untouched and counts a banner's render exactly as it counts a centred
    /// one — no special case, no second path to keep in step.
    func testBannerLayoutsAreReportedWithTheirHeightToThePresenter() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1", layout: "top"))]")
        let phases = PhaseBox()
        let layouts = PhaseBox()
        let listener = OpenPush.InAppMessages.addLifecycleListener {
            phases.add($0.phase); layouts.add($0.layout)
        }
        defer { OpenPush.InAppMessages.removeLifecycleListener(listener) }

        harness.fetch()

        XCTAssertEqual(harness.presentedLayouts(), ["top"], "the layout reaches the presenter verbatim")
        waitForMainQueue()
        XCTAssertEqual(layouts.all(), ["top"],
                       "the host is told how the message it is being told about is presented")
        XCTAssertEqual(phases.all(), ["willDisplay"])
        XCTAssertEqual(harness.ingestTypes(), [], "a banner counts nothing before it renders either")

        harness.emitLast(.rendered(height: 96))

        waitForMainQueue()
        XCTAssertEqual(phases.all(), ["willDisplay", "didDisplay"])
        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"])

        harness.emitLast(.rendered(height: 128))

        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"],
                       "a re-measured banner is still one impression")
    }

    func testAFailedDocumentIsAbandonedWithoutConsumingADisplay() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        harness.emitLast(.failed("HTTP 404"))

        XCTAssertEqual(harness.ingestTypes(), [])
        XCTAssertEqual(harness.presentedIds(), ["iam_1"], "not re-presented in this session")
        XCTAssertFalse(OpenPush.IamEngine.shared.debugState().dismissed.contains("iam_1"))
        XCTAssertNil(OpenPush.IamEngine.shared.debugState().redisplay["iam_1"],
                     "a message nobody saw has not been displayed")
    }

    func testACloseActionFinishesTheMessageAndRecordsTheDisplay() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))

        XCTAssertTrue(OpenPush.IamEngine.shared.debugState().dismissed.contains("iam_1"))
        XCTAssertEqual(OpenPush.IamEngine.shared.debugState().redisplay["iam_1"]?.displayQuantity, 1)
    }

    func testPausingHidesTheActiveMessageAndKeepsItEligible() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), ["iam_1"])

        OpenPush.InAppMessages.paused = true

        XCTAssertEqual(harness.dismissCount(), 1, "the overlay must leave the screen")
        XCTAssertNil(OpenPush.IamEngine.shared.debugState().redisplay["iam_1"],
                     "pausing is not a display")
        XCTAssertEqual(harness.ingestTypes(), [])

        OpenPush.InAppMessages.paused = false

        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_1"], "it comes back when unpaused")
    }

    func testAPausedAndResumedMessagePostsOneImpressionAndOneDidDisplay() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        let phases = PhaseBox()
        let listener = OpenPush.InAppMessages.addLifecycleListener { phases.add($0.phase) }
        defer { OpenPush.InAppMessages.removeLifecycleListener(listener) }

        harness.fetch()
        harness.emitLast(.rendered(height: nil))

        OpenPush.InAppMessages.paused = true
        OpenPush.InAppMessages.paused = false

        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_1"], "it comes back when unpaused")

        harness.emitLast(.rendered(height: nil))

        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"],
                       "a pause interrupts one presentation: the impression latch holds until finish")
        waitForMainQueue()
        XCTAssertEqual(phases.all(), ["willDisplay", "didDisplay", "willDisplay"],
                       "the message that returns is not displayed a second time")
    }

    func testAStaleEventFromADismissedPresentationIsIgnored() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        let phases = PhaseBox()
        let listener = OpenPush.InAppMessages.addLifecycleListener { phases.add($0.phase) }
        defer { OpenPush.InAppMessages.removeLifecycleListener(listener) }

        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))

        harness.emitLast(.rendered(height: nil))

        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"],
                       "a render from a presentation that is over is not a new impression")
        waitForMainQueue()
        XCTAssertEqual(phases.all().filter { $0 == "didDisplay" }.count, 1)
    }

    func testAbandoningAMessagePresentsTheNextOne() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1")),\(IamHarness.row(id: "iam_2"))]")
        harness.fetch()
        harness.emitLast(.failed("HTTP 404"))

        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_2"],
                       "the slot is handed to the next message")
    }

    func testRedisplayPostsANewImpression() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0}"#))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))
        OpenPush.InAppMessages.addTrigger("again", withValue: true)
        harness.emitLast(.rendered(height: nil))

        XCTAssertEqual(harness.ingestTypes().filter { $0 == "iam_impression" }.count, 2,
                       "each display of a redisplaying message is its own impression")
    }

    func testADeactivatedMessageLeavesTheQueueOnTheNextFetch() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1")),\(IamHarness.row(id: "iam_2"))]")
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), ["iam_1"], "iam_2 waits in the queue")

        harness.rows = "[\(IamHarness.row(id: "iam_1"))]"   // iam_2 was deactivated server-side
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))

        XCTAssertEqual(harness.presentedIds(), ["iam_1"],
                       "a fetch replaces the queue; a definition the server no longer returns is never shown")
    }

    func testAMessagePastItsEndTimeIsNotShown() {
        let past = Date().timeIntervalSince1970 - 60
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1", extra: #","end_time":\#(past)"#))]")
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), [])
    }

    func testAnEndTimeMayArriveAsAnISO8601String() {
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","end_time":"\#(past)""#))]")
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), [])
    }

    func testAMessageBeforeItsEndTimeStillShows() {
        let future = Date().timeIntervalSince1970 + 600
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1", extra: #","end_time":\#(future)"#))]")
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), ["iam_1"])
    }

    func testAFailedFetchIsRetriedTwiceThenGivesUpUntilTheNextSession() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetchStatus = 503
        harness.fetch()
        XCTAssertEqual(harness.fetchCount(), 1)
        XCTAssertEqual(harness.clock.pendingDelays(), [2])

        harness.clock.fire(2)
        XCTAssertEqual(harness.fetchCount(), 2)
        XCTAssertEqual(harness.clock.pendingDelays(), [8])

        harness.clock.fire(8)
        XCTAssertEqual(harness.fetchCount(), 3)
        XCTAssertEqual(harness.clock.pendingDelays(), [],
                       "two retries is the budget; the next session tries again")
        XCTAssertEqual(harness.presentedIds(), [])

        harness.fetchStatus = 200
        harness.fetch()
        XCTAssertEqual(harness.fetchCount(), 4)
        XCTAssertEqual(harness.presentedIds(), ["iam_1"])
    }

    func testAnUnretryableFetchFailureIsNotRetried() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetchStatus = 404
        harness.fetch()

        XCTAssertEqual(harness.fetchCount(), 1)
        XCTAssertEqual(harness.clock.pendingDelays(), [],
                       "a definition the server rejects outright is not worth retrying")
    }

    func testAnImpressionLatchLeftByAKilledProcessDoesNotSuppressTheNextOne() throws {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"])

        // The process is killed between the render and the dismiss: the latch
        // that says "already counted" is on disk with nothing on screen.
        let tokenKey = try XCTUnwrap(OpenPush.state.config?.tokenKey)
        OpenPush.IamEngine.shared.resetForTests()
        let stale = OpenPush.IamPersistedState(impressioned: ["iam_1"])
        UserDefaults.standard.set(try? JSONEncoder().encode(stale), forKey: tokenKey + ".iamState")

        let relaunched = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        relaunched.fetch()
        relaunched.emitLast(.rendered(height: nil))

        XCTAssertEqual(relaunched.ingestTypes(), ["iam_impression"],
                       "a fresh session has nothing on screen, so the latch cannot suppress this impression")
    }

    func testAClosedMessageTheServerStoppedReturningIsNotRequeued() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0}"#))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))

        harness.rows = "[]"        // the campaign is deactivated while it is on screen
        harness.fetch()
        harness.emitLast(.action(.init(closes: true)))
        OpenPush.InAppMessages.addTrigger("again", withValue: true)

        XCTAssertEqual(harness.presentedIds(), ["iam_1"],
                       "redisplay budget does not re-admit a definition the server stopped returning")
    }

    func testARequeuedMessageComesBackWithTheDefinitionTheServerSentLast() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0}"#))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))

        // Same campaign, now with an end_time in the past.
        let past = Date().timeIntervalSince1970 - 60
        harness.rows = "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0},"end_time":\#(past)"#))]"
        harness.fetch()
        harness.emitLast(.action(.init(closes: true)))
        OpenPush.InAppMessages.addTrigger("again", withValue: true)

        XCTAssertEqual(harness.presentedIds(), ["iam_1"],
                       "the requeued copy carries the fields of the latest fetch, so its end_time applies")
    }

    func testARefetchWhileAMessageIsOnScreenKeepsItsImpressionLatch() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))

        harness.fetch()                            // definitions refresh mid-presentation
        harness.emitLast(.rendered(height: nil))   // the document reports a render again

        XCTAssertEqual(harness.ingestTypes(), ["iam_impression"],
                       "the message on screen was already counted; a refresh does not reset that")
    }

    func testAnEventFromAnEarlierPresentationOfTheSameMessageIsIgnored() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0}"#))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))
        OpenPush.InAppMessages.addTrigger("again", withValue: true)
        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_1"], "it is on screen a second time")

        harness.emit(at: 0, .rendered(height: nil))

        XCTAssertEqual(harness.ingestTypes().filter { $0 == "iam_impression" }.count, 1,
                       "a render from the first presentation says nothing about the second")

        harness.emit(at: 1, .rendered(height: nil))
        XCTAssertEqual(harness.ingestTypes().filter { $0 == "iam_impression" }.count, 2,
                       "the presentation that is actually on screen still counts")
    }

    func testASessionTimeMessageAppearsWhenItsDeadlinePasses() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1", triggers: #"[[{"id":"t","kind":"session_time","operator":"greater","value":5}]]"#))]")
        let start = Date().timeIntervalSince1970
        OpenPush.IamEngine.shared.setClock { start }
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), [])
        XCTAssertEqual(harness.clock.pendingDelays().filter { $0 > 4.5 && $0 < 5.5 }.count, 1,
                       "one re-evaluation is scheduled just past the deadline")

        OpenPush.IamEngine.shared.setClock { start + 6 }
        harness.clock.fire(harness.clock.pendingDelays().first { $0 > 4.5 && $0 < 5.5 }!)

        XCTAssertEqual(harness.presentedIds(), ["iam_1"])
    }

    func testAWakeReArmsARedisplayEnabledMessage() {
        let soon = #"[[{"id":"t","kind":"session_time","operator":"greater","value":5}]]"#
        let redisplay = #","redisplay":{"limit":2,"delay":0}"#
        let first = IamHarness.row(id: "iam_1", triggers: soon, extra: redisplay)
        let harness = IamHarness(rows: "[\(first)]")
        let start = Date().timeIntervalSince1970
        OpenPush.IamEngine.shared.setClock { start }
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), [], "its deadline has not passed yet")

        OpenPush.IamEngine.shared.setClock { start + 6 }
        harness.clock.fire(harness.clock.pendingDelays().first { $0 > 4.5 && $0 < 5.5 }!)
        XCTAssertEqual(harness.presentedIds(), ["iam_1"])
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))

        // A second message is waiting only on the clock. The wake it earns is
        // a change of circumstances for the whole queue: the message that has
        // redisplay budget left must be re-armed by it, not held back because
        // it was last shown under the same triggers.
        let later = #"[[{"id":"t2","kind":"session_time","operator":"greater","value":20}]]"#
        harness.rows = "[\(first),\(IamHarness.row(id: "iam_2", triggers: later))]"
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), ["iam_1"], "nothing is eligible yet")

        OpenPush.IamEngine.shared.setClock { start + 21 }
        harness.clock.fire(harness.clock.pendingDelays().first { $0 > 13 && $0 < 15 }!)

        XCTAssertEqual(harness.presentedIds().filter { $0 == "iam_1" }.count, 2,
                       "the wake re-armed the redisplaying message")
    }

    func testTheFirstClickOnAMessageIsFlaggedAndLaterOnesAreNot() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        let firsts = FlagBox()
        let listener = OpenPush.InAppMessages.addClickListener { firsts.add($0.firstClick) }
        defer { OpenPush.InAppMessages.removeClickListener(listener) }

        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: false)))
        harness.emitLast(.action(.init(clickID: "c2", blockKey: "b2", closes: false)))

        let clicks = harness.ingestEvents().filter { $0["type"] as? String == "iam_click" }
        XCTAssertEqual(clicks.map { $0["first_click"] as? Bool }, [true, false])
        waitForMainQueue()
        XCTAssertEqual(firsts.all(), [true, false],
                       "the host hears the same answer the receipt carries")
    }

    /// The phase string is a rendering of the stage, not a separate fact: a host
    /// that switches over a `Stage` cannot drift from one that reads `phase`.
    func testLifecycleEventsCarryATypedStage() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        let stages = StageBox()
        let phases = PhaseBox()
        let listener = OpenPush.InAppMessages.addLifecycleListener {
            stages.add($0.stage); phases.add($0.phase)
        }
        defer { OpenPush.InAppMessages.removeLifecycleListener(listener) }

        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))

        waitForMainQueue()
        XCTAssertEqual(stages.all(), [.willDisplay, .didDisplay, .willDismiss, .didDismiss])
        XCTAssertEqual(phases.all(), stages.all().map(\.rawValue))
    }

    func testAClickSurvivesARestoreBeforeTheMessageFinishes() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: false)))

        harness.fetch()   // restores persisted state inside fetchIfSession
        harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: false)))

        XCTAssertEqual(harness.ingestTypes().filter { $0 == "iam_click" }.count, 1,
                       "the click id was persisted at click time, so the duplicate is dropped")
    }

    func testRedisplayReArmsTheMessagesClicks() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0}"#))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: true)))
        OpenPush.InAppMessages.addTrigger("again", withValue: true)
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: true)))

        XCTAssertEqual(harness.ingestTypes().filter { $0 == "iam_click" }.count, 2,
                       "a second display is a second chance to click the same block")
    }

    func testAWorkspaceSwitchDropsTheInAppQueueAndDismissesTheActiveMessage() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1")),\(IamHarness.row(id: "iam_2"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        // iam_1 is closed first, so the blob on disk carries a display, a
        // dismissal and a click — history the next workspace must not inherit,
        // whether from memory or from storage.
        harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: true)))
        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_2"])
        let before = OpenPush.IamEngine.shared.debugState()
        XCTAssertTrue(before.dismissed.contains("iam_1"))
        XCTAssertEqual(before.redisplay["iam_1"]?.displayQuantity, 1)

        OpenPush.initialize(appId: "other-app", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                switch request.url?.path {
                                case "/v1/apps/other-app/subscriptions":
                                    done(200, #"{"id":"sub_2"}"#)
                                case "/v1/apps/other-app/subscriptions/sub_2/iams":
                                    done(200, #"{"in_app_messages":[]}"#)
                                case "/v1/ingest":
                                    done(200, #"{"accepted":1,"dropped":0}"#)
                                default:
                                    done(404, "")
                                }
                            })
        // The new workspace registers and fetches: this is where a blob left on
        // disk would be restored.
        OpenPush.register(token: "aabbcc")
        OpenPush.InAppMessages.onSubscriptionReady()

        XCTAssertEqual(harness.dismissCount(), 1,
                       "the message on screen leaves with the workspace that queued it")
        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_2"],
                       "nothing the previous workspace queued is presented in the new one")
        let state = OpenPush.IamEngine.shared.debugState()
        XCTAssertTrue(state.dismissed.isEmpty, "the previous workspace's dismissals are gone")
        XCTAssertTrue(state.redisplay.isEmpty, "and so is its display history")
        XCTAssertTrue(state.impressioned.isEmpty)
        XCTAssertTrue(state.clickedByMessage.isEmpty)
        XCTAssertTrue(state.firstClicked.isEmpty)
        XCTAssertNil(state.lastTimeInAppDismissed)
    }

    /// A message clicked and then killed mid-presentation has no `redisplay`
    /// record and is not `dismissed`: to a purge running before the fetch has
    /// said what exists, it looks like a campaign nobody remembers, and its
    /// click history goes with it. The fetch then brings the very same message
    /// back, and the click already counted is counted again — a second
    /// `iam_click` for one click id, carrying `first_click` a second time. The
    /// purge waits for the fetch for exactly this reason.
    func testAClickOutlivesBeingKilledWithTheMessageStillOnScreen() throws {
        let before = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        before.fetch()
        before.emitLast(.rendered(height: nil))
        before.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: false)))
        XCTAssertEqual(
            before.ingestEvents().filter { $0["type"] as? String == "iam_click" }
                .map { $0["first_click"] as? Bool },
            [true])

        // The kill. Nothing dismissed the message, so the blob on disk holds
        // the click and no display record at all. `resetForTests` clears the
        // store as well as the engine, so what the device would still have
        // after a relaunch is put back by hand.
        let tokenKey = try XCTUnwrap(OpenPush.state.config?.tokenKey)
        let onDisk = try XCTUnwrap(UserDefaults.standard.data(forKey: tokenKey + ".iamState"))
        OpenPush.IamEngine.shared.resetForTests()
        UserDefaults.standard.set(onDisk, forKey: tokenKey + ".iamState")

        let after = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        after.fetch()
        after.emitLast(.rendered(height: nil))
        after.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: false)))
        after.emitLast(.action(.init(clickID: "c2", blockKey: "b2", closes: false)))

        let clicks = after.ingestEvents().filter { $0["type"] as? String == "iam_click" }
        XCTAssertEqual(clicks.map { $0["click_id"] as? String }, ["c2"],
                       "the click id reported before the kill is not reported again")
        XCTAssertEqual(clicks.map { $0["first_click"] as? Bool }, [false],
                       "this message's first click happened in the run that was killed")
    }

    func testTheFetchPurgeDropsStaleRedisplayRecordsAndKeepsLiveOnes() throws {
        let bootstrap = IamHarness(rows: "[]")
        bootstrap.fetch()
        let tokenKey = try XCTUnwrap(OpenPush.state.config?.tokenKey)
        OpenPush.IamEngine.shared.resetForTests()

        let now = Date().timeIntervalSince1970
        var blob = OpenPush.IamPersistedState()
        blob.redisplay["old"] = .init(lastDisplayTime: now - 181 * 86_400, displayQuantity: 1)
        blob.redisplay["fresh"] = .init(lastDisplayTime: now - 10, displayQuantity: 1)
        blob.dismissed = ["gone"]
        blob.clickedByMessage = ["old": ["c_old"], "fresh": ["c_fresh"], "gone": ["c_gone"]]
        blob.firstClicked = ["old", "fresh", "gone"]
        UserDefaults.standard.set(try JSONEncoder().encode(blob), forKey: tokenKey + ".iamState")

        let harness = IamHarness(rows: "[\(IamHarness.row(id: "fresh"))]")
        OpenPush.IamEngine.shared.setClock { now }
        harness.fetch()

        let state = OpenPush.IamEngine.shared.debugState()
        XCTAssertNil(state.redisplay["old"], "half a year without a display is history")
        XCTAssertNil(state.clickedByMessage["old"],
                     "the click state of a message the engine no longer remembers goes with it")
        XCTAssertFalse(state.firstClicked.contains("old"))
        XCTAssertEqual(state.redisplay["fresh"]?.displayQuantity, 1)
        XCTAssertEqual(state.clickedByMessage["fresh"], ["c_fresh"])
        XCTAssertTrue(state.firstClicked.contains("fresh"))
        XCTAssertEqual(state.clickedByMessage["gone"], ["c_gone"],
                       "a dismissed message is still known, so its click state stays")
        XCTAssertTrue(state.firstClicked.contains("gone"))
    }

    func testAnExhaustedMessageContributesNoWakeDeadline() {
        // Two alternative groups, because only a condition that is still false
        // has a deadline to contribute: the first opens the one display this
        // message is allowed, and the second is what would be armed for it
        // afterwards — once its budget is already spent.
        let triggers = #"[[{"id":"t","kind":"session_time","operator":"greater","value":5}],"#
            + #"[{"id":"t2","kind":"session_time","operator":"greater","value":8}]]"#
        let spent = IamHarness.row(id: "iam_1", triggers: triggers,
                                   extra: #","redisplay":{"limit":1,"delay":0}"#)
        let harness = IamHarness(rows: "[\(spent)]")
        let start = Date().timeIntervalSince1970
        OpenPush.IamEngine.shared.setClock { start + 6 }

        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), ["iam_1"])
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true)))

        // A second message takes the slot, so the refreshed queue is not pruned
        // on the way past and still holds the retired definition.
        harness.rows = "[\(spent),\(IamHarness.row(id: "iam_2"))]"
        harness.fetch()
        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_2"])

        harness.fetch()

        XCTAssertEqual(harness.clock.pendingDelays().filter { $0 > 0 && $0 < 10 }, [],
                       "a message that can never be shown again is worth no wake-up")
    }

    /// A carousel counts each card the reader actually reaches, once. Swiping
    /// back to a card already seen is not a new page impression.
    func testEachCarouselPageIsReportedOnce() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))

        harness.emitLast(.pageChanged(pageId: "p1", index: 0))
        harness.emitLast(.pageChanged(pageId: "p1", index: 0))
        harness.emitLast(.pageChanged(pageId: "p2", index: 1))

        let pages = harness.ingestEvents().filter { $0["type"] as? String == "iam_page_impression" }
        XCTAssertEqual(pages.compactMap { $0["page_id"] as? String }, ["p1", "p2"])
        XCTAssertEqual(pages.compactMap { $0["card_id"] as? String }, ["p1", "p2"],
                       "the same value rides both keys, so either reader agrees")
        XCTAssertEqual(pages.compactMap { $0["message_id"] as? String }, ["iam_1", "iam_1"])
    }

    /// `willDisplay` is a request to show. A page that reports itself before the
    /// document has rendered has been seen by nobody.
    func testPageImpressionsAreOnlyAcceptedAfterRender() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        harness.fetch()

        harness.emitLast(.pageChanged(pageId: "p1", index: 0))

        XCTAssertEqual(harness.ingestTypes(), [], "nothing is on screen yet")

        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.pageChanged(pageId: "p1", index: 0))

        XCTAssertEqual(harness.ingestTypes(), ["iam_impression", "iam_page_impression"],
                       "the page counts once the document is on screen")
    }

    /// A message with redisplay budget gets a fresh carousel every display: the
    /// pages counted last time must not silence the ones counted this time.
    func testRedisplayReArmsTheMessagesPageImpressions() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1", extra: #","redisplay":{"limit":5,"delay":0}"#))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.pageChanged(pageId: "p1", index: 0))
        harness.emitLast(.action(.init(closes: true)))
        OpenPush.InAppMessages.addTrigger("again", withValue: true)
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.pageChanged(pageId: "p1", index: 0))

        XCTAssertEqual(harness.ingestTypes().filter { $0 == "iam_page_impression" }.count, 2,
                       "a second display is a second chance to see the same card")
    }

    /// An action that opens the system permission prompt keeps the slot until
    /// the person answers. The next message would otherwise arrive under an
    /// alert nobody has dealt with yet — unreadable, and dismissed blind.
    func testTheNextMessageWaitsUntilThePermissionPromptResolves() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1")),\(IamHarness.row(id: "iam_2"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true, holdsQueue: true)))

        XCTAssertEqual(harness.presentedIds(), ["iam_1"],
                       "the queue waits while the permission prompt is on screen")

        OpenPush.IamEngine.shared.promptFinished()

        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_2"],
                       "the answer hands the slot to the next message")
    }

    /// The hold depends on an answer coming back. It may not: the person can be
    /// sent to Settings and never return, and a permission the app can no longer
    /// ask for raises no prompt to answer at all. Without this the rest of the
    /// session's messages would be lost to a prompt nobody is looking at.
    func testAStuckPermissionPromptReleasesTheQueueAfterAMinute() {
        let harness = IamHarness(
            rows: "[\(IamHarness.row(id: "iam_1")),\(IamHarness.row(id: "iam_2"))]")
        harness.fetch()
        harness.emitLast(.rendered(height: nil))
        harness.emitLast(.action(.init(closes: true, holdsQueue: true)))

        XCTAssertEqual(harness.presentedIds(), ["iam_1"],
                       "the queue waits while the permission prompt is on screen")
        XCTAssertTrue(harness.clock.pendingDelays().contains(60),
                      "the hold is given a minute, not the rest of the session")

        harness.clock.fire(60)

        XCTAssertEqual(harness.presentedIds(), ["iam_1", "iam_2"],
                       "an answer that never arrives still hands the slot on")
    }

    func testAStateBlobWrittenBeforeClicksWereTrackedPerMessageStillDecodes() throws {
        let legacy = #"{"dismissed":["iam_9"],"impressioned":[],"clickedClickIds":["c1"],"redisplay":{}}"#
        let decoded = try JSONDecoder().decode(OpenPush.IamPersistedState.self,
                                               from: XCTUnwrap(legacy.data(using: .utf8)))

        XCTAssertEqual(decoded.dismissed, ["iam_9"])
        XCTAssertEqual(decoded.clickedByMessage["_legacy"], ["c1"])
        XCTAssertTrue(decoded.firstClicked.isEmpty)
    }

    /// The definitions fetch is a request like any other: it can answer after
    /// the host has switched workspaces. Everything its completion does — the
    /// queue it installs, the purge it runs, the blob it writes — resolves the
    /// token key that is current when it runs, so the workspace being left
    /// would file its answer under the workspace being entered.
    func testAFetchAnsweringAfterAWorkspaceSwitchIsDroppedWhole() throws {
        let leaving = "openpush.test.\(UUID().uuidString)"
        let entering = "openpush.test.\(UUID().uuidString)"
        let enteringIam = entering + ".iamState"
        defer {
            for key in [leaving, leaving + ".iamState",
                        OpenPush.State.sessionKey(forTokenKey: leaving),
                        entering, enteringIam,
                        OpenPush.State.sessionKey(forTokenKey: entering)] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // What the workspace being entered already knows about its own audience.
        var stored = OpenPush.IamPersistedState()
        stored.dismissed = ["iam_b"]
        UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: enteringIam)

        let presented = PhaseBox()
        OpenPush.IamEngine.shared.setPresenter { message, _ in presented.add(message.id) }
        OpenPush.IamEngine.shared.setAutomaticFetchForTests(true)

        let held = HeldTransport()
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "workspace-a",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: leaving),
                        credential: { nil },
                        transport: { request, done in
                            if request.url?.path.hasSuffix("/iams") == true {
                                held.hold(done)
                            } else {
                                done(200, #"{"id":"sub_a"}"#)
                            }
                        })
        OpenPush.register(token: "aabb")
        #if canImport(UIKit)
        XCTAssertTrue(held.waitForRequest(), "the accepted registration starts the fetch")
        #else
        // The package's macOS test host has no registration-driven UIKit hook.
        OpenPush.InAppMessages.onSubscriptionReady()
        #endif
        XCTAssertEqual(held.count(), 1, "the leaving workspace's fetch is in flight")

        // Nothing of the leaving workspace's may register against the new app
        // id, and `syncNotificationTypes` registers nothing without a token.
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "workspace-b",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: entering),
                        credential: { nil },
                        transport: { _, done in done(200, #"{"id":"sub_b"}"#) })

        held.release(200, #"{"in_app_messages":[\#(IamHarness.row(id: "iam_a"))]}"#)

        let onDisk = try JSONDecoder().decode(
            OpenPush.IamPersistedState.self,
            from: try XCTUnwrap(UserDefaults.standard.data(forKey: enteringIam)))
        XCTAssertEqual(onDisk.dismissed, ["iam_b"],
                       "the incoming workspace's blob is not the leaving one's to overwrite")
        XCTAssertEqual(OpenPush.IamEngine.shared.debugQueuedIds(), [],
                       "and its documents are not queued for the new workspace's audience")
        XCTAssertEqual(presented.all(), [], "so nothing is shown either")
    }
}

/// Transport completions a test refuses to call, so a request stays in flight
/// across a workspace switch.
private final class HeldTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private var held: [@Sendable (Int, String) -> Void] = []
    func hold(_ done: @escaping @Sendable (Int, String) -> Void) {
        lock.withLock { held.append(done) }
        started.signal()
    }
    func count() -> Int { lock.withLock { held.count } }
    func waitForRequest() -> Bool { started.wait(timeout: .now() + 2) == .success }
    func release(_ code: Int, _ body: String) {
        let due = lock.withLock { () -> [@Sendable (Int, String) -> Void] in
            let all = held; held = []; return all
        }
        due.forEach { $0(code, body) }
    }
}

private final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpenPush.InAppMessageLifecycleEvent.Stage] = []
    func add(_ value: OpenPush.InAppMessageLifecycleEvent.Stage) {
        lock.withLock { values.append(value) }
    }
    func all() -> [OpenPush.InAppMessageLifecycleEvent.Stage] { lock.withLock { values } }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.withLock { values.append(value) } }
    func all() -> [Bool] { lock.withLock { values } }
}

private final class PhaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    func all() -> [String] { lock.withLock { values } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
