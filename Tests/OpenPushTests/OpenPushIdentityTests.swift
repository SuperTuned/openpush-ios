import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushIdentityTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private final class ResultCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.IdentityResult?
        func set(_ newValue: OpenPush.IdentityResult) { lock.withLock { value = newValue } }
        func get() -> OpenPush.IdentityResult? { lock.withLock { value } }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    /// Flips a transport between accepting and failing mid-test.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var accepting = false
        func accept() { lock.withLock { accepting = true } }
        func refuse() { lock.withLock { accepting = false } }
        func isAccepting() -> Bool { lock.withLock { accepting } }
    }

    private let clock = ManualClock()

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLoginReRegistersTheStoredTokenWithTheExternalIdAndAuthHash() throws {
        let capture = Capture()
        let result = ResultCapture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "person-7", authHash: "deadbeef") { result.set($0) }

        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "person-7")
        XCTAssertEqual(json["external_id_auth_hash"] as? String, "deadbeef")
        XCTAssertEqual(json["token"] as? String, "aabb")
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)
    }

    func testLoginWithoutATokenDefersTheIdentityToTheNextRegistration() throws {
        let capture = Capture()
        let result = ResultCapture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.onLog = { log.add($0) }

        OpenPush.login(externalId: "person-8") { result.set($0) }

        XCTAssertNil(capture.get(), "there is no token to register yet")
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)
        XCTAssertTrue(log.joined().contains("next registration"),
                      "a deferred identity must say so in the log")

        OpenPush.register(token: "ccdd")

        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "person-8",
                       "the stored identity rides the first registration that follows")
        XCTAssertNil(json["external_id_auth_hash"])
    }

    func testEveryLaterRegistrationKeepsTheIdentity() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-9", authHash: "hash-9")

        OpenPush.register(token: "eeff")

        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "person-9")
        XCTAssertEqual(json["external_id_auth_hash"] as? String, "hash-9")
    }

    func testLogoutSendsAnExplicitEmptyExternalId() throws {
        let capture = Capture()
        let result = ResultCapture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-10")

        OpenPush.logout { result.set($0) }

        let json = try body(of: capture.get())
        XCTAssertTrue(json.keys.contains("external_id"),
                      "the key must be present — an absent key means 'leave identity alone'")
        XCTAssertEqual(json["external_id"] as? String, "")
        XCTAssertNil(json["external_id_auth_hash"])
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)
    }

    func testAnonymousInstallOmitsTheExternalIdEntirely() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })

        OpenPush.register(token: "aabb")

        let json = try body(of: capture.get())
        XCTAssertFalse(json.keys.contains("external_id"),
                       "the wire shape has no external_id for a host that never calls login")
    }

    func testStrippedIdentityIsSurfacedEvenThoughTheDeviceWasAccepted() throws {
        let result = ResultCapture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                done(200, #"{"id":"sub_1","identity_rejected":"auth hash did not verify"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.onLog = { log.add($0) }

        OpenPush.login(externalId: "person-11", authHash: "wrong") { result.set($0) }

        waitForMainQueue()
        XCTAssertEqual(result.get(), .identityRejected("auth hash did not verify"))
        XCTAssertTrue(log.joined().contains("identity NOT applied"),
                      "a silent rejection would leave the host believing the user is identified")
    }

    func testRejectedRegistrationFailsTheLogin() {
        let result = ResultCapture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                done(409, #"{"code":"scope_conflict","detail":"device already linked"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "person-12") { result.set($0) }

        waitForMainQueue()
        XCTAssertEqual(result.get(), .failed(
            "This device is still linked to another workspace. Reset this device, then sign in again."))
    }

    func testEmptyExternalIdIsRejectedWithoutARequest() {
        let requests = AttemptCounter()
        let result = ResultCapture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in _ = requests.next(); done(200, "{}") })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "") { result.set($0) }

        XCTAssertEqual(requests.get(), 0)
        waitForMainQueue()
        XCTAssertEqual(result.get(), .failed(
            "login requires a non-empty external ID; use logout to detach this install"))
    }
    func testLoggingInAgainAsTheSameUserSendsNothing() {
        let requests = AttemptCounter()
        let result = ResultCapture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = requests.next(); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-13")
        XCTAssertEqual(requests.get(), 1, "the first login registers the identity")
        OpenPush.onLog = { log.add($0) }

        OpenPush.login(externalId: "person-13") { result.set($0) }

        XCTAssertEqual(requests.get(), 1,
                       "the server already knows this person — a second login is a wasted round trip")
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)
        XCTAssertTrue(log.joined().contains("already logged in as person-13"),
                      "a skipped login must say why nothing was sent")
        XCTAssertEqual(OpenPush.User.externalId, "person-13")
    }

    func testLoggingInAgainWithARotatedAuthHashStillRegisters() throws {
        let capture = Capture()
        let requests = AttemptCounter()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); _ = requests.next()
                                done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-14", authHash: "hash-old")

        OpenPush.login(externalId: "person-14", authHash: "hash-new")

        XCTAssertEqual(requests.get(), 2, "a rotated hash is new proof and must reach the server")
        XCTAssertEqual(try body(of: capture.get())["external_id_auth_hash"] as? String, "hash-new")
    }

    func testLogoutWhileAnonymousSendsNothing() {
        let requests = AttemptCounter()
        let result = ResultCapture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = requests.next(); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.onLog = { log.add($0) }

        OpenPush.logout { result.set($0) }

        XCTAssertEqual(requests.get(), 0,
                       "an install that was never identified has nothing to detach")
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)
        XCTAssertTrue(log.joined().contains("nothing to detach"),
                      "a skipped logout must say why nothing was sent")
        XCTAssertNil(OpenPush.User.externalId)
    }

    /// A logout that sends nothing still has to leave this install holding
    /// nobody's data, or the next person to log in inherits it.
    func testLogoutWhileAnonymousClearsTheWritesStagedOnThisInstall() {
        let requests = AttemptCounter()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = requests.next(); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.User.addTags(["plan": "trial"])
        OpenPush.User.addAliases(["crm_id": "c-1"])
        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "trial"])

        OpenPush.logout()

        XCTAssertEqual(requests.get(), 0,
                       "an install that was never identified has nothing to detach")
        XCTAssertEqual(OpenPush.User.getTags(), [:])
        XCTAssertEqual(OpenPush.state.aliasMap, [:])
        XCTAssertFalse(OpenPush.state.hasOpenWriteWindow,
                       "the window was open for writes that no longer exist")
        XCTAssertTrue(clock.pendingDelays().isEmpty)
    }

    func testASecondLogoutSendsNothing() {
        let requests = AttemptCounter()
        let result = ResultCapture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = requests.next(); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-15")
        OpenPush.logout()
        let afterFirstLogout = requests.get()

        OpenPush.logout { result.set($0) }

        XCTAssertEqual(requests.get(), afterFirstLogout,
                       "the detach was already sent — repeating it changes nothing")
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)
    }

    /// A login whose registration never reached the server changed nothing the
    /// server can see. Answering the retry with a local `.success` strands the
    /// person as anonymous for the life of the install.
    func testARepeatLoginRegistersUntilTheIdentityHasBeenDelivered() {
        let requests = AttemptCounter()
        let result = ResultCapture()
        let gate = Gate()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = requests.next()
                                if gate.isAccepting() { done(200, #"{"id":"sub_1"}"#) }
                                else { done(500, "boom") }
                            })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "person-17")
        clock.fire(2)
        clock.fire(8)
        XCTAssertEqual(requests.get(), 3, "the first login exhausted its retries")

        gate.accept()
        OpenPush.login(externalId: "person-17") { result.set($0) }

        XCTAssertEqual(requests.get(), 4,
                       "the server never heard this identity, so a repeat login must send it")
        waitForMainQueue()
        XCTAssertEqual(result.get(), .success)

        OpenPush.login(externalId: "person-17")
        XCTAssertEqual(requests.get(), 4,
                       "now that it has been accepted the repeat is a no-op again")
    }

    /// The same hole on the detach side: a logout whose registration failed left
    /// the user linked on the server, and the no-op would never let it be retried.
    func testARepeatLogoutRegistersUntilTheDetachHasBeenDelivered() {
        let requests = AttemptCounter()
        let gate = Gate()
        gate.accept()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                _ = requests.next()
                                if gate.isAccepting() { done(200, #"{"id":"sub_1"}"#) }
                                else { done(500, "boom") }
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-18")
        XCTAssertEqual(requests.get(), 1)

        gate.refuse()
        OpenPush.logout()
        clock.fire(2)
        clock.fire(8)
        XCTAssertEqual(requests.get(), 4, "the detach exhausted its retries")

        gate.accept()
        OpenPush.logout()
        XCTAssertEqual(requests.get(), 5,
                       "the server never heard the detach, so a repeat logout must send it")

        OpenPush.logout()
        XCTAssertEqual(requests.get(), 5, "now that it landed the repeat is a no-op again")
    }

    func testARejectedIdentityIsNoLongerReportedByExternalId() {
        let result = ResultCapture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                done(200, #"{"id":"sub_1","identity_rejected":"auth hash did not verify"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.login(externalId: "person-16", authHash: "wrong") { result.set($0) }

        waitForMainQueue()
        XCTAssertEqual(result.get(), .identityRejected("auth hash did not verify"))
        XCTAssertNil(OpenPush.User.externalId,
                     "the server stripped the identity — reporting it would be a lie")
    }

    func testLoggingInAsADifferentUserDoesNotCarryThePreviousUsersTagsAndAliases() throws {
        let capture = Capture()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-a")
        OpenPush.User.addTags(["plan": "pro"])
        OpenPush.User.addAliases(["crm_id": "c-a"])

        OpenPush.login(externalId: "person-b")

        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "person-b")
        XCTAssertNil(json["tags"], "user A's tags must not be written onto user B")
        XCTAssertNil(json["aliases"], "user A's aliases must not be written onto user B")
        XCTAssertEqual(OpenPush.User.getTags(), [:])
    }

    func testLogoutSendsTheDetachWithoutTheOldUsersTags() throws {
        let capture = Capture()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-a")
        OpenPush.User.addTags(["plan": "pro"])

        OpenPush.logout()

        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "")
        XCTAssertNil(json["tags"], "the fresh anonymous user must not be born holding A's tags")
        XCTAssertEqual(OpenPush.User.getTags(), [:])
    }

    func testLoggingInFromAnonymousCarriesTheAnonymousSessionsTagsForward() throws {
        let capture = Capture()
        OpenPush.scheduler = clock.seam
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.User.addTags(["plan": "trial"])

        OpenPush.login(externalId: "person-a")

        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "person-a")
        XCTAssertEqual(json["tags"] as? [String: String], ["plan": "trial"],
                       "tags set before the user was known were set for this person")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
