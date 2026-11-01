import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushRetryTests: OpenPushTestCase {
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [OpenPush.IdentityResult] = []
        func add(_ value: OpenPush.IdentityResult) { lock.withLock { values.append(value) } }
        func all() -> [OpenPush.IdentityResult] { lock.withLock { values } }
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [OpenPush.RegistrationResult] = []
        func add(_ value: OpenPush.RegistrationResult) { lock.withLock { values.append(value) } }
        func all() -> [OpenPush.RegistrationResult] { lock.withLock { values } }
    }

    private final class Wait: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double
        init(_ value: Double) { self.value = value }
        func set(_ newValue: Double) { lock.withLock { value = newValue } }
        func get() -> Double { lock.withLock { value } }
    }

    /// Transport completions the test refuses to call, so a registration stays
    /// in flight across a workspace switch.
    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [@Sendable (Int, String) -> Void] = []
        func hold(_ done: @escaping @Sendable (Int, String) -> Void) {
            lock.withLock { held.append(done) }
        }
        func count() -> Int { lock.withLock { held.count } }
        func release(_ code: Int, _ body: String) {
            let due = lock.withLock { () -> [@Sendable (Int, String) -> Void] in
                let all = held; held = []; return all
            }
            due.forEach { $0(code, body) }
        }
    }

    private final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        func all() -> [String] { lock.withLock { values } }
    }

    private let clock = ManualClock()

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = clock.seam
    }

    func testATransientFailureRetriesTwiceAndReportsOnlyTheFinalOne() {
        let attempts = AttemptCounter()
        let failures = AttemptCounter()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = attempts.next()
                                done(503, "upstream down")
                            })
        OpenPush.onRegistrationFailed = { _ in _ = failures.next() }

        OpenPush.register(token: "aabb")
        waitForMainQueue()
        XCTAssertEqual(attempts.get(), 1)
        XCTAssertEqual(failures.get(), 0)
        XCTAssertEqual(clock.pendingDelays(), [2])

        clock.fire(2)
        waitForMainQueue()
        XCTAssertEqual(attempts.get(), 2)
        XCTAssertEqual(failures.get(), 0)
        XCTAssertEqual(clock.pendingDelays(), [8])

        clock.fire(8)
        XCTAssertEqual(attempts.get(), 3)
        waitForMainQueue()
        XCTAssertEqual(failures.get(), 1)
        XCTAssertTrue(clock.pendingDelays().isEmpty)
    }

    func testA4xxIsNeverRetried() {
        let attempts = AttemptCounter()
        let failures = AttemptCounter()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = attempts.next()
                                done(409, "scope conflict")
                            })
        OpenPush.onRegistrationFailed = { _ in _ = failures.next() }

        OpenPush.register(token: "aabb")

        XCTAssertEqual(attempts.get(), 1)
        waitForMainQueue()
        XCTAssertEqual(failures.get(), 1)
        XCTAssertTrue(clock.pendingDelays().isEmpty)
    }

    func testATransportLevelErrorIsRetried() {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(-1, "offline") })

        OpenPush.register(token: "aabb")

        XCTAssertEqual(clock.pendingDelays(), [2])
    }

    func testANewerRegistrationSupersedesAPendingRetry() {
        let attempts = AttemptCounter()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                let attempt = attempts.next()
                                done(attempt == 1 ? 503 : 200, attempt == 1 ? "down" : "{}")
                            })

        OpenPush.register(token: "aabb")
        OpenPush.register(token: "ccdd")
        clock.fire(2)

        XCTAssertEqual(attempts.get(), 2)
    }

    func testALoginCompletionRidesTheFinalOutcomeExactlyOnce() {
        let attempts = AttemptCounter()
        let results = Results()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                let attempt = attempts.next()
                                done(attempt < 3 ? 503 : 200,
                                     attempt < 3 ? "down" : #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "person-7") { results.add($0) }
        waitForMainQueue()
        XCTAssertTrue(results.all().isEmpty)
        clock.fire(2)
        waitForMainQueue()
        XCTAssertTrue(results.all().isEmpty)
        clock.fire(8)
        waitForMainQueue()
        XCTAssertEqual(results.all(), [.success])
    }

    /// A 429 is the server asking this device to come back later. Treating it as
    /// a permanent refusal drops the registration; ignoring `Retry-After` and
    /// retrying on the table instead walks straight back into the rate limit.
    func testA429IsRetriedAfterTheServersRetryAfterCappedAtThirtySeconds() {
        let attempts = AttemptCounter()
        let failures = AttemptCounter()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                // What `urlSessionTransport` does with the real
                                // response header: the transport contract carries
                                // no headers, so the value travels in the box.
                                let attempt = attempts.next()
                                OpenPush.lastRetryAfter.store(attempt == 1 ? 120 : 5)
                                done(429, "slow down")
                            })
        OpenPush.onRegistrationFailed = { _ in _ = failures.next() }

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        XCTAssertTrue(OpenPush.isRetryableRegistrationFailure(429))
        XCTAssertEqual(attempts.get(), 1)
        XCTAssertEqual(failures.get(), 0, "a rate limit is not a rejection")
        XCTAssertEqual(clock.pendingDelays(), [30],
                       "a 120-second Retry-After is capped so a mistaken header cannot park " +
                       "registration")

        clock.fire(30)
        XCTAssertEqual(attempts.get(), 2)
        XCTAssertEqual(clock.pendingDelays(), [5],
                       "under the cap the server's own number is honoured, not the table")

        clock.fire(5)
        XCTAssertEqual(attempts.get(), 3)
        waitForMainQueue()
        XCTAssertEqual(failures.get(), 1)

        XCTAssertEqual(OpenPush.retryAfterSeconds("30"), 30)
        XCTAssertEqual(OpenPush.retryAfterSeconds(" 7 "), 7)
        XCTAssertNil(OpenPush.retryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT"),
                     "an HTTP date needs a trusted clock; a skewed device would wait for days")
        XCTAssertNil(OpenPush.retryAfterSeconds("0"))
        XCTAssertNil(OpenPush.retryAfterSeconds(nil))
    }

    /// Without jitter every device that failed in the same outage comes back in
    /// the same instant and recreates it.
    func testRetryDelaysCarryJitter() throws {
        OpenPush.retryJitter = OpenPush.systemRetryJitter
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(503, "upstream down") })

        var firsts: [Double] = []
        var seconds: [Double] = []
        for _ in 0..<25 {
            OpenPush.register(token: "aabb")
            let first = try XCTUnwrap(clock.pendingDelays().first)
            XCTAssertEqual(clock.pendingDelays().count, 1)
            firsts.append(first)
            clock.fire(first)
            let second = try XCTUnwrap(clock.pendingDelays().first)
            seconds.append(second)
            clock.fire(second)
        }

        XCTAssertTrue(firsts.allSatisfy { (1.5...2.5).contains($0) },
                      "the first retry stays within ±25 % of 2 seconds: \(firsts)")
        XCTAssertTrue(seconds.allSatisfy { (6.0...10.0).contains($0) },
                      "the second retry stays within ±25 % of 8 seconds: \(seconds)")
        XCTAssertGreaterThan(Set(firsts).count, 1, "a fixed delay is not jitter")
        XCTAssertGreaterThan(Set(seconds).count, 1, "a fixed delay is not jitter")
    }

    /// Jitter exists to spread a fleet, not to renegotiate the rate limiter: a
    /// retry that lands before the wait the server named walks straight back into
    /// the limit, and one jittered past the cap parks registration for longer than
    /// the SDK ever allows.
    func testJitterNeverMovesA429RetryBelowTheServersWaitOrPastTheCap() throws {
        let wait = Wait(120)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                OpenPush.lastRetryAfter.store(wait.get())
                                done(429, "slow down")
                            })

        OpenPush.retryJitter = { $0 * (1 + OpenPush.retryJitterFraction) }
        OpenPush.register(token: "aabb")
        XCTAssertEqual(clock.pendingDelays(), [30],
                       "a capped wait cannot be jittered past the cap")

        wait.set(5)
        OpenPush.retryJitter = { $0 * (1 - OpenPush.retryJitterFraction) }
        clock.fire(30)
        XCTAssertEqual(clock.pendingDelays(), [5],
                       "jitter may push a Retry-After later, never earlier")

        clock.fire(5)
        XCTAssertTrue(clock.pendingDelays().isEmpty, "two retries is the whole budget")
    }

    func testACompletionWaitingOnASupersededChainStillFiresExactlyOnce() {
        let attempts = AttemptCounter()
        let results = Results()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                let attempt = attempts.next()
                                done(attempt == 1 ? 503 : 200, attempt == 1 ? "down" : "{}")
                            })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "person-8") { results.add($0) }
        OpenPush.register(token: "ccdd")

        waitForMainQueue()
        XCTAssertEqual(results.all(), [.success])
        clock.fire(2)
        waitForMainQueue()
        XCTAssertEqual(results.all().count, 1)
    }

    /// `setup` cancels the write window and any armed retry *before* it takes
    /// the lock that installs the new configuration. A registration already in
    /// flight can answer inside that gap, and a failure there arms a retry of
    /// its own that no cancel ever saw. The only thing between that retry and
    /// the workspace the host just entered is the registration generation, and
    /// `setup` never moved it — so the retry fires the previous workspace's
    /// token at the new workspace's app id.
    ///
    /// The APNs token is cleared before the switch on purpose. A switch that
    /// registers the new workspace bumps the generation on its way past and
    /// papers over the hole; the guard has to hold when nothing else does, and
    /// `syncNotificationTypes` registers nothing while there is no token.
    func testAWorkspaceSwitchInvalidatesARetryArmedByAnInFlightRegistration() {
        let held = Held()
        let paths = Paths()
        OpenPush.initialize(appId: "first-app", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                paths.add(request.url?.path ?? "")
                                held.hold(done)
                            })
        OpenPush.User.addTag(key: "workspace", value: "first")
        OpenPush.register(token: "aabb")
        XCTAssertEqual(held.count(), 1, "the first workspace's registration is in flight")
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "second-app",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example"),
                        credential: { nil },
                        transport: { request, done in
                            paths.add(request.url?.path ?? "")
                            done(200, #"{"id":"sub_2"}"#)
                        })
        // The response the switch could not cancel, landing after it.
        held.release(503, "upstream down")
        XCTAssertTrue(clock.pendingDelays().contains(2),
                      "the stale response did arm a retry — the guard is what must stop it")

        let before = paths.all()
        clock.fire(2)

        XCTAssertEqual(paths.all(), before,
                       "a retry belonging to the workspace the host left must not fire at all")
        XCTAssertFalse(paths.all().contains("/v1/apps/second-app/subscriptions"),
                       "and nothing of the first workspace's may reach the second's app id")
    }

    /// The generation guard is right to stop that retry — but the retry was the
    /// last thing that would ever answer the caller. The failure that armed it
    /// reported nothing, and the registration that superseded it carries a
    /// waiter list of its own, so a `register` or `login` completion left on the
    /// old chain hangs for the life of the process.
    func testASupersededRetryStillCompletesTheCallerWaitingOnIt() {
        let held = Held()
        let outcomes = Outcomes()
        OpenPush.initialize(appId: "first-app", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in held.hold(done) })

        OpenPush.performRegistration(token: "aabb") { outcomes.add($0) }
        XCTAssertEqual(held.count(), 1, "the first workspace's registration is in flight")
        XCTAssertTrue(outcomes.all().isEmpty)
        // Same reason as the test above: with no token the switch registers
        // nothing of its own, so the guard is the only thing in the way.
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "second-app",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example"),
                        credential: { nil },
                        transport: { _, done in done(200, #"{"id":"sub_2"}"#) })
        held.release(503, "upstream down")
        XCTAssertTrue(outcomes.all().isEmpty,
                      "a retry is armed, so the failure itself reports nothing yet")
        XCTAssertTrue(clock.pendingDelays().contains(2))

        clock.fire(2)

        XCTAssertEqual(outcomes.all(),
                       [.dropped("a newer configuration replaced this registration")],
                       "the caller is told once, and told the truth")
    }

    /// The sibling of the test above, one call site over. `setup` cancels an
    /// already-armed retry before it takes the lock, and that cancel is the end
    /// of the chain: the guard the test above exercises is never even reached,
    /// because the retry never runs. Nothing else drains the waiters, so a
    /// completion riding that chain hangs for the life of the process.
    func testAWorkspaceSwitchCompletesTheCallerOfARetryItCancelled() {
        let attempts = AttemptCounter()
        let outcomes = Outcomes()
        let paths = Paths()
        OpenPush.initialize(appId: "first-app", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                paths.add(request.url?.path ?? "")
                                _ = attempts.next()
                                done(503, "upstream down")
                            })

        OpenPush.performRegistration(token: "aabb") { outcomes.add($0) }
        XCTAssertEqual(attempts.get(), 1)
        XCTAssertTrue(outcomes.all().isEmpty, "the retry is what answers, and it has not run")
        XCTAssertEqual(clock.pendingDelays(), [2])
        // With no token the switch registers nothing of its own, so nothing but
        // the cancel itself can account for the completion.
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "second-app",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example"),
                        credential: { nil },
                        transport: { request, done in
                            paths.add(request.url?.path ?? "")
                            done(200, #"{"id":"sub_2"}"#)
                        })

        XCTAssertEqual(outcomes.all(),
                       [.dropped("a newer configuration replaced this registration")],
                       "the cancel ends the chain, so the cancel is what has to report")
        XCTAssertTrue(clock.pendingDelays().isEmpty, "and the retry itself is gone")

        let before = paths.all()
        clock.fire(2)

        XCTAssertEqual(outcomes.all().count, 1, "exactly once, however the clock is driven")
        XCTAssertEqual(paths.all(), before,
                       "a cancelled retry posts nothing, before or after the switch")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
