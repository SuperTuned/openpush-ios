import XCTest
@testable import OpenPush

final class OpenPushAccessorTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var held: [@Sendable (Int, String) -> Void] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
        func count() -> Int { lock.withLock { requests.count } }
        /// Keeps a request in flight so a test can write while the server has not
        /// answered yet.
        func hold(_ completion: @escaping @Sendable (Int, String) -> Void) {
            lock.withLock { held.append(completion) }
        }
        func answerHeld(_ code: Int, _ response: String) {
            let pending: [@Sendable (Int, String) -> Void] = lock.withLock {
                let current = held
                held = []
                return current
            }
            for completion in pending { completion(code, response) }
        }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private let clock = ManualClock()

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func start(_ capture: Capture, response: String = #"{"id":"sub_9"}"#,
                       holdingCompletions: Bool = false) {
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request)
                                if holdingCompletions {
                                    capture.hold(done)
                                } else {
                                    done(200, response)
                                }
                            })
        OpenPush.storeToken("aabb")
    }

    func testGetTagsIsTheMapThatActuallyRidesTheBody() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTags(["plan": "pro", "seats": "12"])
        clock.fire(0.3)

        XCTAssertEqual(OpenPush.User.getTags(),
                       try body(of: capture.last())["tags"] as? [String: String])
        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro", "seats": "12"])
    }

    func testRemoveTagsDeletesEveryNamedKeyInOneRegistration() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTags(["plan": "pro", "seats": "12", "locale": "en-GB"])
        clock.fire(0.3)

        OpenPush.User.removeTags(["plan", "seats"])
        clock.fire(0.3)

        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["plan": "", "seats": "", "locale": "en-GB"])
        XCTAssertEqual(capture.count(), 2)
    }

    func testRemoveAliasesDeletesEveryNamedLabelInOneRegistration() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addAliases(["player_id": "p-1", "crm_id": "c-1", "steam_id": "s-1"])
        clock.fire(0.3)

        OpenPush.User.removeAliases(["player_id", "crm_id"])
        clock.fire(0.3)

        XCTAssertEqual(try body(of: capture.last())["aliases"] as? [String: String],
                       ["player_id": "", "crm_id": "", "steam_id": "s-1"])
        XCTAssertEqual(capture.count(), 2)
    }

    func testExternalIdReportsTheStoredIdentityAndNothingAfterLogout() {
        let capture = Capture()
        start(capture)

        OpenPush.login(externalId: "person-7", authHash: "hash-7")
        XCTAssertEqual(OpenPush.User.externalId, "person-7")
        OpenPush.logout()
        XCTAssertNil(OpenPush.User.externalId)
    }

    func testIsInitializedIsFalseUntilTheFirstAttach() {
        let capture = Capture()
        OpenPush.state.resetAsIfTheProcessJustStarted()
        XCTAssertFalse(OpenPush.isInitialized)

        start(capture)

        XCTAssertTrue(OpenPush.isInitialized)
    }

    func testSdkVersionIsTheOneTheChangelogAnnounces() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let changelog = try String(contentsOf: repoRoot.appendingPathComponent("CHANGELOG.md"),
                                   encoding: .utf8)
        // `sdkVersion` and the newest heading are bumped by the same release, but
        // not always in the same commit: the docs may open an `Unreleased` section
        // for the next version before the constant moves, and the constant moves
        // while the heading still says `Unreleased` and waits for its date at tag
        // time. So either satisfies this — an `Unreleased` heading that names
        // `sdkVersion`, or the newest released heading — and replacing a
        // heading's `Unreleased` with its date at tag time needs no change here.
        // What it catches is the constant and every heading naming different
        // versions.
        let headings = changelog.split(separator: "\n").filter { $0.hasPrefix("## ") }
        let newestReleased = try XCTUnwrap(headings.first { !$0.contains("Unreleased") })
        let unreleased = headings.first { $0.contains("Unreleased") }
        XCTAssertTrue(newestReleased.contains(OpenPush.sdkVersion)
                          || unreleased?.contains(OpenPush.sdkVersion) == true,
                      """
                      sdkVersion \(OpenPush.sdkVersion) is named by neither the newest \
                      released heading (\(newestReleased)) nor an Unreleased one \
                      (\(unreleased.map { String($0) } ?? "none"))
                      """)
    }

    func testTheUserPushSubscriptionOptsOutOnTheWire() throws {
        let capture = Capture()
        start(capture)

        OpenPush.User.pushSubscription.optOut()

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, -2)
        XCTAssertFalse(OpenPush.PushSubscription.optedIn)
    }

    func testTheUserPushSubscriptionIsLiveNotASnapshot() {
        let capture = Capture()
        start(capture)
        OpenPush.state.setToken(nil, persist: true)
        let subscription = OpenPush.User.pushSubscription
        XCTAssertNil(subscription.id)

        OpenPush.register(token: "aabb")

        XCTAssertEqual(subscription.id, "sub_9")
        XCTAssertEqual(subscription.token, "aabb")
    }

    func testGetTagsHidesADeletedKeyWhileTheWireStillCarriesTheTombstone() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTags(["plan": "pro", "seats": "12"])
        clock.fire(0.3)

        OpenPush.User.removeTag("plan")

        XCTAssertEqual(OpenPush.User.getTags(), ["seats": "12"],
                       "a deleted tag must not read back as an empty-string value")
        clock.fire(0.3)
        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["plan": "", "seats": "12"],
                       "the deletion still has to travel; only the reader hides it")
    }

    func testTombstonesLeaveTheBodyAfterTheDeletingRegistrationIsAccepted() throws {
        let capture = Capture()
        start(capture)
        OpenPush.User.addTags(["plan": "pro", "seats": "12"])
        clock.fire(0.3)

        OpenPush.User.removeTag("plan")
        clock.fire(0.3)
        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["plan": "", "seats": "12"])

        OpenPush.User.addTag(key: "locale", value: "en-GB")
        clock.fire(0.3)

        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["seats": "12", "locale": "en-GB"],
                       "the server applied the deletion already; re-sending it forever is waste")
        XCTAssertEqual(capture.count(), 3)
    }

    func testATombstoneAddedDuringAnInFlightRegistrationSurvivesToTheNextBody() throws {
        let capture = Capture()
        start(capture, holdingCompletions: true)
        OpenPush.User.addTags(["plan": "pro", "seats": "12", "region": "eu"])
        clock.fire(0.3)
        capture.answerHeld(200, #"{"id":"sub_9"}"#)

        OpenPush.User.removeTags(["plan", "region"])
        clock.fire(0.3)
        // Both tombstones are on the wire; the response has not arrived yet.
        OpenPush.User.addTag(key: "plan", value: "enterprise")
        OpenPush.User.removeTag("seats")
        capture.answerHeld(200, #"{"id":"sub_9"}"#)

        XCTAssertEqual(OpenPush.state.tagMap, ["plan": "enterprise", "seats": ""],
                       "only the delivered region tombstone is pruned")
        clock.fire(0.3)
        XCTAssertEqual(try body(of: capture.last())["tags"] as? [String: String],
                       ["plan": "enterprise", "seats": ""],
                       "a deletion made mid-flight was never sent, so it must ride the next body")
    }

    func testAddAliasWithAnEmptyIdIsRefused() {
        let capture = Capture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture)
        OpenPush.onLog = { log.add($0) }

        OpenPush.User.addAlias(label: "player_id", id: "")

        XCTAssertEqual(capture.count(), 0)
        XCTAssertTrue(OpenPush.state.aliasMap.isEmpty,
                      "an empty id is a typo, not a deletion; removeAlias is the deletion")
        XCTAssertTrue(log.joined().contains(
            "alias 'player_id' dropped — an alias id cannot be empty; use removeAlias"))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
