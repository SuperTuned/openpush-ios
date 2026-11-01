import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushAliasTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
        func count() -> Int { lock.withLock { requests.count } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private let clock = ManualClock()

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = clock.seam
    }

    private func aliases(of request: URLRequest?) throws -> [String: String] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["aliases"] as? [String: String])
    }

    private func start(_ capture: Capture, response: String = #"{"id":"sub_1"}"#) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, response)
                            })
    }

    func testAddAliasSendsTheWholeSessionAliasMap() throws {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")

        OpenPush.User.addAlias(label: "player_id", id: "p-77")
        OpenPush.User.addAlias(label: "crm_id", id: "c-12")

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(try aliases(of: capture.last()),
                       ["player_id": "p-77", "crm_id": "c-12"],
                       "the full map rides every registration, not just the newest label")
    }

    func testAddAliasesSendsOneRegistrationForTheBatch() throws {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")

        OpenPush.User.addAliases(["player_id": "p-1", "crm_id": "c-1", "steam_id": "s-1"])

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(try aliases(of: capture.last()),
                       ["player_id": "p-1", "crm_id": "c-1", "steam_id": "s-1"])
    }

    func testRemoveAliasKeepsTheLabelWithAnEmptyValue() throws {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")
        OpenPush.User.addAliases(["player_id": "p-1", "crm_id": "c-1"])

        OpenPush.User.removeAlias("player_id")

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(try aliases(of: capture.last()), ["player_id": "", "crm_id": "c-1"],
                       "a deletion has to travel; dropping the label would keep the old id")
    }

    func testAliasesWithoutATokenAreHeldForTheNextRegistration() throws {
        let capture = Capture()
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in
                            capture.add(request); done(200, #"{"id":"sub_1"}"#)
                        })
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.User.addAlias(label: "player_id", id: "p-9")
        XCTAssertEqual(capture.count(), 0)
        XCTAssertTrue(clock.pendingDelays().isEmpty)

        OpenPush.register(token: "aabb")

        XCTAssertEqual(try aliases(of: capture.last()), ["player_id": "p-9"])
    }

    func testAnAliasFreeInstallSendsNoAliasesKey() throws {
        let capture = Capture()
        start(capture)

        OpenPush.register(token: "aabb")

        let request = try XCTUnwrap(capture.last())
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(json.keys.contains("aliases"),
                       "the wire shape has no aliases key for a host that never sets an alias")
    }

    func testAStrippedIdentityOnAnAliasChangeIsLoggedLoudly() {
        let capture = Capture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture,
              response: #"{"id":"sub_1","identity_rejected":"external_id_auth_hash did not verify"}"#)
        OpenPush.storeToken("aabb")
        OpenPush.onLog = { log.add($0) }

        OpenPush.User.addAlias(label: "player_id", id: "p-5")
        clock.fire(0.3)

        XCTAssertTrue(log.joined().contains("identity NOT applied"),
                      "aliases ride the same identity gate as external_id; a silent downgrade " +
                      "would leave the host believing the alias is queryable")
    }

    /// Cross-part reconciliation: the server refuses reserved or over-cap labels by
    /// naming them in `aliases_refused` on an otherwise-2xx response, so the SDK
    /// has to say so wherever it reports `identity_rejected`.
    func testServerRefusedAliasLabelsAreLoggedLoudly() {
        let capture = Capture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture, response: #"{"id":"sub_1","aliases_refused":["label_11","external_id"]}"#)
        OpenPush.storeToken("aabb")
        OpenPush.onLog = { log.add($0) }

        OpenPush.User.addAlias(label: "label_11", id: "p-11")
        clock.fire(0.3)

        let lines = log.joined()
        XCTAssertTrue(lines.contains("aliases NOT applied"),
                      "a refused label is a silent no-op on the server unless the SDK says so")
        XCTAssertTrue(lines.contains("label_11"))
        XCTAssertEqual(OpenPush.parseRegistration(
            #"{"aliases_refused":["a","b"]}"#).aliasesRefused, ["a", "b"])
        XCTAssertNil(OpenPush.parseRegistration(#"{"id":"sub_1"}"#).aliasesRefused)
    }

    func testTheExternalIdLabelIsRefusedWithoutARequest() {
        let capture = Capture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture)
        OpenPush.storeToken("aabb")
        OpenPush.onLog = { log.add($0) }

        OpenPush.User.addAlias(label: "external_id", id: "person-1")

        XCTAssertEqual(capture.count(), 0,
                       "login owns external_id; an alias must not be a way around identity " +
                       "verification")
        XCTAssertTrue(log.joined().contains("external_id"))
        XCTAssertTrue(OpenPush.state.aliasMap.isEmpty)
    }

    func testAnEmptyLabelIsRefused() {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")

        OpenPush.User.addAliases(["": "p-1"])

        XCTAssertEqual(capture.count(), 0)
        XCTAssertTrue(OpenPush.state.aliasMap.isEmpty)
    }

    func testMoreLabelsThanTheServerKeepsIsSentAndSaidOutLoud() throws {
        let capture = Capture()
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        start(capture)
        OpenPush.storeToken("aabb")
        OpenPush.onLog = { log.add($0) }

        var many: [String: String] = [:]
        for index in 1...11 { many["label_\(index)"] = "id-\(index)" }
        OpenPush.User.addAliases(many)

        XCTAssertTrue(log.joined().contains("at most 10"),
                      "the local capacity warning is synchronous")
        clock.fire(0.3)
        XCTAssertEqual(try aliases(of: capture.last()).count, 11,
                       "the server decides which labels survive; the SDK does not guess")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
