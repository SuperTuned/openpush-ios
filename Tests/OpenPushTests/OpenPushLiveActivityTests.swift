import XCTest
@testable import OpenPush
import OpenPushCore

/// Expectations here follow the reconciled S4 contract (2026-08-17): `enter`
/// posts to `/live-activities` with the DEVICE token as `token` and the
/// activity's own token as `update_token`, `exit` posts to
/// `/live-activities/{id}/end`, and push-to-start posts to
/// `/live-activities/push-to-start` with `push_to_start_token`.
final class OpenPushLiveActivityTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
        func count() -> Int { lock.withLock { requests.count } }
        func all() -> [URLRequest] { lock.withLock { requests } }
    }

    private final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        func all() -> [String] { lock.withLock { values } }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool? { lock.withLock { value } }
    }

    private final class CredentialBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        func set(_ newValue: String?) { lock.withLock { value = newValue } }
        func get() -> String? { lock.withLock { value } }
    }

    private final class CompletionCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: ((Int, String) -> Void)?
        func set(_ value: @escaping (Int, String) -> Void) { lock.withLock { completion = value } }
        func finish(_ code: Int, _ response: String) { lock.withLock { completion }?(code, response) }
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ value: Int) { self.value = value }
        func set(_ newValue: Int) { lock.withLock { value = newValue } }
        func get() -> Int { lock.withLock { value } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Starts the SDK with a device token already registered: every Live Activity
    /// route resolves the subscription by that token, so it is a precondition.
    private func start(_ capture: Capture, code: Int = 200) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in capture.add(request); done(code, "{}") })
        OpenPush.storeToken("aabb")
    }

    func testEnterPostsTheUpdateTokenToTheLiveActivityRouteWithStandardHeaders() throws {
        let capture = Capture()
        let outcome = FlagBox()
        start(capture)

        OpenPush.LiveActivities.enter("act-1", withToken: "0aff", activityType: "delivery") {
            outcome.set($0)
        }

        let request = try XCTUnwrap(capture.last())
        // S4 ALIGNMENT: this literal and the constant move together, or not at all.
        XCTAssertEqual(OpenPush.liveActivityPath(appID: "sample"),
                       "/v1/apps/sample/live-activities")
        XCTAssertEqual(request.url?.path, OpenPush.liveActivityPath(appID: "sample"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-Device-Key"), "opdev_secret")
        let json = try body(of: request)
        XCTAssertEqual(json["activity_id"] as? String, "act-1")
        XCTAssertEqual(json["token"] as? String, "aabb",
                       "the server resolves the subscription by the device token")
        XCTAssertEqual(json["update_token"] as? String, "0aff",
                       "the activity's own token travels as update_token")
        waitForMainQueue()
        XCTAssertEqual(outcome.get(), true)
    }

    /// The host README documents this path for an app that owns its ActivityKit
    /// tokens: no `setup(_:activityType:)`, no adapter, nothing that could have
    /// recorded the type. It has to reach the wire on its own.
    func testEnterWithAnActivityTypeNeedsNoPriorSetup() throws {
        let capture = Capture()
        let outcome = FlagBox()
        start(capture)

        OpenPush.LiveActivities.enter("act-11", withToken: "0aff", activityType: "delivery") {
            outcome.set($0)
        }

        XCTAssertEqual(capture.count(), 1, "a self-managing host must not be refused locally")
        let request = try XCTUnwrap(capture.last())
        XCTAssertEqual(request.url?.path, OpenPush.liveActivityPath(appID: "sample"))
        let json = try body(of: request)
        XCTAssertEqual(json["activity_id"] as? String, "act-11")
        XCTAssertEqual(json["activity_type"] as? String, "delivery")
        XCTAssertEqual(json["update_token"] as? String, "0aff")
        XCTAssertEqual(json["token"] as? String, "aabb")
        waitForMainQueue()
        XCTAssertEqual(outcome.get(), true)
    }

    func testTheActivityTypeRidesTheTokenOnceItIsKnown() throws {
        let capture = Capture()
        start(capture)
        OpenPush.LiveActivities.enter("act-2", withToken: "0aff", activityType: "delivery")

        OpenPush.LiveActivities.enter("act-2", withToken: "beef")

        XCTAssertEqual(capture.count(), 2, "the type-free overload still sends once it is known")
        let json = try body(of: capture.last())
        XCTAssertEqual(json["activity_type"] as? String, "delivery")
        XCTAssertEqual(json["update_token"] as? String, "beef")
    }

    func testAnEmptyActivityTypeIsRefusedWithoutClobberingAKnownOne() throws {
        let capture = Capture()
        let outcome = FlagBox()
        start(capture)
        OpenPush.LiveActivities.enter("act-12", withToken: "0aff", activityType: "delivery")

        OpenPush.LiveActivities.enter("act-12", withToken: "beef", activityType: "") {
            outcome.set($0)
        }

        XCTAssertEqual(capture.count(), 1)
        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false)
        XCTAssertEqual(OpenPush.state.liveActivityType(for: "act-12"), "delivery",
                       "a refused call must not erase the type an accepted one recorded")
    }

    func testAnUnknownActivityTypeIsSentWithoutATypeForServerD9() {
        let capture = Capture()
        let outcome = FlagBox()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture)
        OpenPush.onLog = { log.add($0) }

        OpenPush.LiveActivities.enter("act-3", withToken: "beef") { outcome.set($0) }

        XCTAssertEqual(capture.count(), 1,
                       "D9 accepts enter(activityId, token) before a type is learned")
        waitForMainQueue()
        XCTAssertEqual(outcome.get(), true)
        XCTAssertFalse(log.joined().contains("no activity type"))
    }

    func testExitEndsTheActivityThroughItsOwnRoute() throws {
        let capture = Capture()
        let outcome = FlagBox()
        start(capture)
        OpenPush.LiveActivities.enter("act-4", withToken: "0aff", activityType: "delivery")

        OpenPush.LiveActivities.exit("act-4") { outcome.set($0) }

        let request = try XCTUnwrap(capture.last())
        // S4 ALIGNMENT: this literal and the constant move together, or not at all.
        XCTAssertEqual(OpenPush.liveActivityEndPath(appID: "sample", activityId: "act-4"),
                       "/v1/apps/sample/live-activities/act-4/end")
        XCTAssertEqual(request.url?.path,
                       OpenPush.liveActivityEndPath(appID: "sample", activityId: "act-4"))
        let json = try body(of: request)
        XCTAssertEqual(json["token"] as? String, "aabb")
        XCTAssertEqual(json.count, 1,
                       "the end route identifies the activity in its path, not in its body")
        waitForMainQueue()
        XCTAssertEqual(outcome.get(), true)
        XCTAssertNil(OpenPush.state.liveActivityType(for: "act-4"),
                     "an exited activity must not keep its type for a later id collision")
    }

    func testAFailedExitKeepsTheActivityTypeSoTheEndCanBeRetried() throws {
        let capture = Capture()
        let outcome = FlagBox()
        start(capture, code: 503)
        OpenPush.LiveActivities.enter("act-13", withToken: "0aff", activityType: "delivery")

        OpenPush.LiveActivities.exit("act-13") { outcome.set($0) }

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false)
        XCTAssertEqual(OpenPush.state.liveActivityType(for: "act-13"), "delivery",
                       "the type may only be forgotten once the server has accepted the end")
        // The point of keeping it: the host can still reach the wire afterwards.
        OpenPush.LiveActivities.enter("act-13", withToken: "beef")
        XCTAssertEqual(capture.count(), 3)
        XCTAssertEqual(try body(of: capture.last())["activity_type"] as? String, "delivery")
    }

    func testPushToStartTokenCarriesTheTypeAndNoActivityIdentifier() throws {
        let capture = Capture()
        start(capture)

        OpenPush.LiveActivities.setPushToStartToken(activityType: "tournament", token: "cafe")

        let request = try XCTUnwrap(capture.last())
        // S4 ALIGNMENT: this literal and the constant move together, or not at all.
        XCTAssertEqual(OpenPush.liveActivityStartTokenPath(appID: "sample"),
                       "/v1/apps/sample/live-activities/push-to-start")
        XCTAssertEqual(request.url?.path, OpenPush.liveActivityStartTokenPath(appID: "sample"))
        let json = try body(of: request)
        XCTAssertEqual(json["activity_type"] as? String, "tournament")
        XCTAssertEqual(json["push_to_start_token"] as? String, "cafe")
        XCTAssertEqual(json["token"] as? String, "aabb")
        XCTAssertFalse(json.keys.contains("activity_id"),
                       "no activity exists yet for a push-to-start token")
    }

    func testEmptyIdentifiersAndTokensAreRefusedWithoutARequest() {
        let capture = Capture()
        let enterOutcome = FlagBox()
        let startOutcome = FlagBox()
        start(capture)

        OpenPush.LiveActivities.enter("", withToken: "0aff") { enterOutcome.set($0) }
        OpenPush.LiveActivities.enter("act-5", withToken: "") { enterOutcome.set($0) }
        OpenPush.LiveActivities.setPushToStartToken(activityType: "", token: "0aff") {
            startOutcome.set($0)
        }

        XCTAssertEqual(capture.count(), 0)
        waitForMainQueue()
        XCTAssertEqual(enterOutcome.get(), false)
        XCTAssertEqual(startOutcome.get(), false)
    }

    func testATokenPostWithoutARegisteredDeviceTokenIsQueued() {
        let capture = Capture()
        let outcome = FlagBox()
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.add(request); done(200, "{}") })
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.LiveActivities.enter("act-10", withToken: "0aff", activityType: "delivery") {
            outcome.set($0)
        }

        XCTAssertEqual(capture.count(), 0,
                       "the server resolves the subscription by the device token; without one " +
                       "this is a guaranteed 404")
        waitForMainQueue()
        XCTAssertNil(outcome.get())
        XCTAssertEqual(OpenPush.LiveActivities.executor.pendingKeys(in: .updateTokens),
                       ["act-10"])
    }

    func testPushToStartRetriesAfterDeviceRegistrationRecoversFromA404() {
        let capture = Capture()
        let status = StatusBox(404)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in
                                capture.add(request)
                                done(status.get(), "{}")
                            })
        OpenPush.storeToken("cached-device-token")

        OpenPush.LiveActivities.setPushToStartToken(
            activityType: "LiveScoreAttributes", token: "cafe")

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(OpenPush.LiveActivities.executor.pendingKeys(in: .startTokens),
                       ["LiveScoreAttributes"],
                       "a launch-order 404 must not discard ActivityKit's standing token")

        status.set(200)
        OpenPush.storeToken("current-device-token")
        OpenPush.LiveActivities.executor.registrationCompleted(subscriptionID: "sub-current")

        XCTAssertEqual(capture.count(), 2,
                       "successful device registration must redrive the saved token")
        XCTAssertEqual(OpenPush.LiveActivities.executor.pendingKeys(in: .startTokens), [])
    }

    func testMalformedPushToStartRegistrationIsNotRetried() {
        let capture = Capture()
        start(capture, code: 400)

        OpenPush.LiveActivities.setPushToStartToken(
            activityType: "LiveScoreAttributes", token: "cafe")

        XCTAssertEqual(OpenPush.LiveActivities.executor.pendingKeys(in: .startTokens), [],
                       "a genuine payload error should not be retried forever")
    }

    func testARejectedTokenPostReportsFailureWithABoundedLog() {
        let capture = Capture()
        let outcome = FlagBox()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture, code: 503)
        OpenPush.onLog = { log.add($0) }

        OpenPush.LiveActivities.enter("act-6", withToken: "0aff", activityType: "delivery") {
            outcome.set($0)
        }

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false)
        XCTAssertTrue(log.joined().contains("act-6"))
    }

    func testATokenPostFromAPreviousDeviceSessionIsIgnoredButStillCompletes() {
        let credential = CredentialBox("opdev_old")
        let completion = CompletionCapture()
        let outcome = FlagBox()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { credential.get() },
                            transport: { _, done in completion.set(done) })
        OpenPush.storeToken("aabb")

        OpenPush.LiveActivities.enter("act-7", withToken: "0aff", activityType: "delivery") {
            outcome.set($0)
        }
        credential.set(nil)
        completion.finish(200, "{}")

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false,
                       "a caller awaiting a completion must never hang, and a stale response " +
                       "must not read as success for the new session")
    }

    func testActivityKitTokenDataIsSentAsLowercaseHexAndRemembersItsType() throws {
        let capture = Capture()
        start(capture)

        OpenPush.LiveActivities.record(activityId: "act-8", activityType: "countdown",
                                       tokenData: Data([0x0A, 0xFF, 0x10]))

        let json = try body(of: capture.last())
        XCTAssertEqual(json["update_token"] as? String, "0aff10")
        XCTAssertEqual(json["activity_type"] as? String, "countdown")
        XCTAssertEqual(OpenPush.state.liveActivityType(for: "act-8"), "countdown",
                       "the adapter records the type so a later enter(_:withToken:) carries it")
    }

    func testAPushToStartTokenFromActivityKitIsHexEncoded() throws {
        let capture = Capture()
        start(capture)

        OpenPush.LiveActivities.recordPushToStart(activityType: "energy",
                                                  tokenData: Data([0xDE, 0xAD]))

        XCTAssertEqual(try body(of: capture.last())["push_to_start_token"] as? String, "dead")
    }

    func testAnUnusableServerConfigurationFailsClosedInsteadOfReportingSuccess() {
        let outcome = FlagBox()
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        // There is no un-initialize in the process, so the drop path is exercised
        // through a configuration whose URL cannot be built. The space has to sit
        // in the authority: this toolchain's URL parser percent-encodes a space in
        // a path but still rejects one in the host.
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "http://exa mple.com",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { _, done in done(200, "{}") })
        OpenPush.storeToken("aabb")

        OpenPush.LiveActivities.enter("act-9", withToken: "0aff", activityType: "delivery") {
            outcome.set($0)
        }

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false,
                       "an unusable server URL fails closed through post()'s invalid-request " +
                       "path instead of reporting a delivered token")
    }

    func testAConfirmedReceiptIsSentOnceForANotificationId() {
        let capture = Capture()
        start(capture)

        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")
        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")

        XCTAssertEqual(capture.all().filter { $0.url?.path == "/v1/ingest" }.count, 1,
                       "a sent receipt is the dedup marker for its 24h TTL")
    }

    func testEnterWithAnUnchangedTokenStillCallsItsCompletion() {
        let capture = Capture()
        start(capture)
        let results = OrderBox()

        OpenPush.LiveActivities.enter("a1", withToken: "0aff", activityType: "delivery") {
            results.add("first:\($0)")
        }
        OpenPush.LiveActivities.enter("a1", withToken: "0aff", activityType: "delivery") {
            results.add("second:\($0)")
        }

        waitForMainQueue()
        XCTAssertEqual(results.all(), ["first:true", "second:true"],
                       "a caller awaiting an unchanged token must not hang")
    }

    func testAConfirmedReceiptIsNotResentWhenTheSubscriptionIdChanges() {
        let capture = Capture()
        start(capture)
        let tokenRoute = OpenPush.liveActivityPath(appID: "sample")

        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")
        OpenPush.LiveActivities.enter("a1", withToken: "0aff", activityType: "delivery")
        let tokenPostsBefore = capture.all().filter { $0.url?.path == tokenRoute }.count
        XCTAssertEqual(capture.all().filter { $0.url?.path == "/v1/ingest" }.count, 1)

        OpenPush.LiveActivities.executor.registrationCompleted(subscriptionID: "sub_new")

        XCTAssertEqual(capture.all().filter { $0.url?.path == "/v1/ingest" }.count, 1,
                       "a receipt is not resolved per subscription, so a new subscription id " +
                       "must not re-post a confirmation the server already counted")
        XCTAssertGreaterThan(capture.all().filter { $0.url?.path == tokenRoute }.count,
                             tokenPostsBefore,
                             "a token registration IS resolved per subscription, so the sweep " +
                             "must still re-send it")
    }

    func testAFailedReceiptIsRetriedOnTheBackoffSchedule() {
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        let capture = Capture()
        let ingestStatus = StatusBox(503)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in
                                capture.add(request)
                                guard request.url?.path == "/v1/ingest" else {
                                    done(200, "{}")
                                    return
                                }
                                let code = ingestStatus.get()
                                ingestStatus.set(200)
                                done(code, "{}")
                            })
        OpenPush.storeToken("aabb")

        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")

        XCTAssertEqual(capture.all().filter { $0.url?.path == "/v1/ingest" }.count, 1)
        XCTAssertEqual(clock.pendingDelays(), [OpenPush.registrationRetryDelays[0]],
                       "a 503 is transient, so the receipt owes itself a retry on the " +
                       "shared schedule")

        clock.fire(OpenPush.registrationRetryDelays[0])

        XCTAssertEqual(capture.all().filter { $0.url?.path == "/v1/ingest" }.count, 2,
                       "the retry re-sends a receipt the server never accepted")
        XCTAssertEqual(OpenPush.LiveActivities.executor.pendingKeys(in: .receipts), [],
                       "and the accepted receipt is now marked succeeded, not pending")

        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")

        XCTAssertEqual(capture.all().filter { $0.url?.path == "/v1/ingest" }.count, 2,
                       "the succeeded entry is still the dedup marker — it was kept, not forgotten")
    }

    func testATokenQueuedBeforeTheDeviceTokenExistsWaitsForRegistration() {
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.LiveActivities.enter("a1", withToken: "0aff", activityType: "delivery")

        XCTAssertEqual(clock.pendingDelays(), [],
                       "no timer: without a device token a wake-up finds nothing to send")
        XCTAssertTrue(capture.all().isEmpty)

        OpenPush.register(token: "aabb")

        let route = OpenPush.liveActivityPath(appID: "sample")
        XCTAssertEqual(capture.all().filter { $0.url?.path == route }.count, 1,
                       "the accepted registration sends the queued token")
    }

    func testRetriesGrowThenHoldUntilTheNextRegistration() {
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        let capture = Capture()
        let ingestStatus = StatusBox(503)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in
                                capture.add(request)
                                guard request.url?.path == "/v1/ingest" else {
                                    done(200, #"{"id":"sub_1"}"#)
                                    return
                                }
                                done(ingestStatus.get(), "{}")
                            })
        OpenPush.storeToken("aabb")
        let ingests = { capture.all().filter { $0.url?.path == "/v1/ingest" }.count }

        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")
        XCTAssertEqual(clock.pendingDelays(), [2])
        clock.fire(2)
        XCTAssertEqual(ingests(), 2)
        XCTAssertEqual(clock.pendingDelays(), [8], "the second wait is longer")
        clock.fire(8)
        XCTAssertEqual(ingests(), 3)
        XCTAssertEqual(clock.pendingDelays(), [],
                       "the schedule is spent: no 30 s poll for the life of the process")

        ingestStatus.set(200)
        OpenPush.register(token: "aabb")

        XCTAssertEqual(ingests(), 4, "the next accepted registration sends it again")
        XCTAssertEqual(OpenPush.LiveActivities.executor.pendingKeys(in: .receipts), [])
    }

    func testARetryHonoursRetryAfterUpToTheCap() {
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in
                                guard request.url?.path == "/v1/ingest" else {
                                    done(200, "{}")
                                    return
                                }
                                OpenPush.lastRetryAfter.store(600)
                                done(429, "{}")
                            })
        OpenPush.storeToken("aabb")

        OpenPush.LiveActivities.reportReceipt(notificationId: "n1", activityId: "a1",
                                              activityType: "delivery")

        XCTAssertEqual(clock.pendingDelays(), [OpenPush.retryAfterCap])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
