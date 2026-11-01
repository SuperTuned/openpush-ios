import XCTest
@testable import OpenPush

final class OpenPushAppSessionTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var heldDuration: (@Sendable (Int, String) -> Void)?
        var durationStatus = 200
        var holdDuration = false

        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func sessions() -> [URLRequest] {
            lock.withLock { requests.filter { $0.url?.path.hasSuffix("/sessions") == true } }
        }
        func receive(_ request: URLRequest,
                     _ done: @escaping @Sendable (Int, String) -> Void) {
            let duration = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }?["duration_seconds"] != nil
            lock.withLock { requests.append(request) }
            if duration, holdDuration {
                lock.withLock { heldDuration = done }
            } else {
                done(duration ? durationStatus : 200, #"{"id":"sub_1"}"#)
            }
        }
        func resolveDuration(_ status: Int) {
            let done = lock.withLock { () -> (@Sendable (Int, String) -> Void)? in
                defer { heldDuration = nil }
                return heldDuration
            }
            done?(status, "{}")
        }
        func durationBodies() throws -> [[String: Any]] {
            try sessions().compactMap { request in
                guard let data = request.httpBody,
                      let body = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      body["duration_seconds"] != nil else { return nil }
                return body
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 2_000_000
        func now() -> TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    func testForegroundSendsOneThrottledSessionPing() throws {
        let capture = Capture()
        let clock = Clock()
        OpenPush.appSessionClock = { clock.now() }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")

        OpenPush.Notifications.onAppForegrounded()
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(capture.sessions().count, 1)
        let first = try XCTUnwrap(capture.sessions().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(first.httpBody)) as? [String: String])
        XCTAssertEqual(body["token"], "aabb")

        clock.advance(OpenPush.appSessionMinimumInterval)
        OpenPush.Notifications.onAppForegrounded()
        XCTAssertEqual(capture.sessions().count, 2)
    }

    private func initialized(_ capture: Capture, clock: Clock) {
        OpenPush.appSessionClock = { clock.now() }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk",
                            serverURL: "https://push.example",
                            transport: capture.receive)
        OpenPush.register(token: "aabb")
    }

    func testBackgroundPostsForegroundDurationWithAnIdempotencyKey() throws {
        let capture = Capture()
        let clock = Clock()
        initialized(capture, clock: clock)
        clock.advance(40)

        OpenPush.recordSessionDurationOnBackground()

        let body = try XCTUnwrap(capture.durationBodies().single)
        XCTAssertEqual(body["token"] as? String, "aabb")
        XCTAssertEqual(body["duration_seconds"] as? Double, 40)
        XCTAssertFalse((body["idempotency_key"] as? String ?? "").isEmpty)
        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 0)
    }

    private func assertLaunchOutsideActiveStateWaitsForActivation(
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let capture = Capture()
        let clock = Clock()
        initialized(capture, clock: clock)
        OpenPush.recordSessionDurationOnBackground()

        OpenPush.beginForegroundSessionIfActive(false)
        clock.advance(30)
        OpenPush.recordSessionDurationOnBackground()

        XCTAssertTrue(try capture.durationBodies().isEmpty,
                      "time before activation must not count as foreground use",
                      file: file, line: line)

        OpenPush.beginForegroundSessionIfActive(true)
        clock.advance(12)
        OpenPush.recordSessionDurationOnBackground()
        XCTAssertEqual(try capture.durationBodies().single?["duration_seconds"] as? Double, 12,
                       file: file, line: line)
    }

    func testInactiveColdLaunchWaitsForDidBecomeActive() throws {
        try assertLaunchOutsideActiveStateWaitsForActivation()
    }

    func testBackgroundOrPrewarmLaunchWaitsForDidBecomeActive() throws {
        try assertLaunchOutsideActiveStateWaitsForActivation()
    }

    func testAnAlreadyActiveAttachDoesNotClaimTheActivationTwice() {
        XCTAssertTrue(OpenPush.state.recordApplicationIsActive(true))
        XCTAssertFalse(OpenPush.state.recordApplicationIsActive(true))
        XCTAssertTrue(OpenPush.state.recordApplicationIsActive(false))
    }

    func testSuccessfulPostSubtractsOnlyTheInFlightDuration() throws {
        let capture = Capture()
        capture.holdDuration = true
        let clock = Clock()
        initialized(capture, clock: clock)
        clock.advance(40)
        OpenPush.recordSessionDurationOnBackground()
        let first = try XCTUnwrap(capture.durationBodies().single)

        OpenPush.Notifications.onAppForegrounded()
        clock.advance(15)
        OpenPush.recordSessionDurationOnBackground()
        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 55)
        XCTAssertEqual(try capture.durationBodies().count, 1)

        capture.resolveDuration(200)
        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 15)
        OpenPush.Notifications.onAppForegrounded()
        let bodies = try capture.durationBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotEqual(first["idempotency_key"] as? String,
                          bodies[1]["idempotency_key"] as? String)
    }

    func testServerFailureSurvivesRestartAndRetriesWithTheSameKey() throws {
        let first = Capture()
        first.durationStatus = 503
        let clock = Clock()
        initialized(first, clock: clock)
        clock.advance(27)
        OpenPush.recordSessionDurationOnBackground()
        let firstBody = try XCTUnwrap(first.durationBodies().single)
        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 27)

        OpenPush.state.resetAsIfTheProcessJustStarted()
        let second = Capture()
        initialized(second, clock: clock)
        let retried = try XCTUnwrap(second.durationBodies().single)
        XCTAssertEqual(firstBody["duration_seconds"] as? Double,
                       retried["duration_seconds"] as? Double)
        XCTAssertEqual(firstBody["idempotency_key"] as? String,
                       retried["idempotency_key"] as? String)
        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 0)
    }

    func testDurationReportsAreChunkedAtOneDay() throws {
        let capture = Capture()
        let clock = Clock()
        initialized(capture, clock: clock)
        clock.advance(OpenPush.maxSessionDuration + 15)

        OpenPush.recordSessionDurationOnBackground()

        let body = try XCTUnwrap(capture.durationBodies().single)
        XCTAssertEqual(body["duration_seconds"] as? Double, 86_400)
        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 15)
    }

    func testClientRefusalDropsTheRejectedChunk() {
        let capture = Capture()
        capture.durationStatus = 400
        let clock = Clock()
        initialized(capture, clock: clock)
        clock.advance(12)

        OpenPush.recordSessionDurationOnBackground()

        XCTAssertEqual(OpenPush.state.pendingSessionDurationSeconds, 0)
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
