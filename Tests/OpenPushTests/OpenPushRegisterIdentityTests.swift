import XCTest
@testable import OpenPush
import OpenPushCore

/// `register(token:externalID:)` and the `currentToken` setter stay for source
/// compatibility, but identity only ever reaches a registration body through
/// the login state, and an assigned token is registered rather than stored
/// silently. The test methods that call the deprecated members are marked
/// deprecated themselves so the calls compile without warnings.
final class OpenPushRegisterIdentityTests: OpenPushTestCase {
    private final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String: Any]] = []
        func add(_ request: URLRequest) {
            guard let data = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            lock.withLock { values.append(json) }
        }
        var all: [[String: Any]] { lock.withLock { values } }
        var last: [String: Any]? { lock.withLock { values.last } }
    }

    private func attach(_ bodies: Bodies, tokenKey: String? = nil) {
        let configuration = tokenKey.map {
            OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                  serverURL: "https://push.example", tokenKey: $0)
        } ?? OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                   serverURL: "https://push.example")
        OpenPush.attach(configuration: configuration, credential: { nil },
                        transport: { request, done in
                            bodies.add(request); done(200, #"{"id":"sub_1"}"#)
                        })
    }

    @available(*, deprecated)
    func testTheOldTwoArgumentRegisterStillIdentifiesThroughLogin() throws {
        let bodies = Bodies()
        attach(bodies)

        OpenPush.register(token: "aabb", externalID: "person-1")

        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body["token"] as? String, "aabb")
        XCTAssertEqual(body["external_id"] as? String, "person-1",
                       "an existing caller must keep identifying its users")
        XCTAssertEqual(OpenPush.User.externalId, "person-1",
                       "the id is applied as a login, so the install now holds it")

        OpenPush.register(token: "ccdd")

        XCTAssertEqual(bodies.last?["external_id"] as? String, "person-1",
                       "a login persists, unlike the old one-request override")
    }

    @available(*, deprecated)
    func testTheOldRegisterWithNoIdIsAPlainRegistration() throws {
        let bodies = Bodies()
        attach(bodies)

        OpenPush.register(token: "aabb", externalID: nil)
        OpenPush.register(token: "aabb", externalID: "")

        XCTAssertEqual(bodies.all.count, 2)
        for body in bodies.all {
            XCTAssertFalse(body.keys.contains("external_id"))
        }
        XCTAssertNil(OpenPush.User.externalId)
    }

    @available(*, deprecated)
    func testTheOldRegisterNeverAssertsAnIdentityThatIsWaitingForItsHash() throws {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        let first = Bodies()
        OpenPush.state.resetAsIfTheProcessJustStarted()
        attach(first, tokenKey: tokenKey)
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.login(externalId: "person-7", authHash: "hash-7")

        // A relaunch restores the verified identity without its hash.
        let bodies = Bodies()
        OpenPush.state.resetAsIfTheProcessJustStarted()
        attach(bodies, tokenKey: tokenKey)
        XCTAssertTrue(OpenPush.state.identityNeedsAuthHash)

        OpenPush.register(token: "aabb", externalID: "person-7")

        let body = try XCTUnwrap(bodies.last)
        XCTAssertFalse(body.keys.contains("external_id"),
                       "the old override sent the id with no hash; it must wait for login")
        XCTAssertTrue(OpenPush.state.identityNeedsAuthHash,
                      "a repeat of the same id must not drop the owed hash")
    }

    @available(*, deprecated)
    func testTheOldRegisterWithAnotherIdSwitchesUsersLikeLogin() throws {
        let bodies = Bodies()
        attach(bodies)
        OpenPush.storeToken("aabb")
        OpenPush.login(externalId: "person-a")
        OpenPush.User.addTag(key: "level", value: "9")
        waitForMainQueue()

        OpenPush.register(token: "aabb", externalID: "person-b")

        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body["external_id"] as? String, "person-b")
        XCTAssertNil((body["tags"] as? [String: String])?["level"],
                     "person-a's tags must not be written onto person-b")
        XCTAssertEqual(OpenPush.User.externalId, "person-b")
    }

    @available(*, deprecated)
    func testAssigningCurrentTokenRegistersIt() throws {
        let bodies = Bodies()
        attach(bodies)

        OpenPush.currentToken = "aabb"

        XCTAssertEqual(OpenPush.currentToken, "aabb")
        XCTAssertEqual(bodies.last?["token"] as? String, "aabb",
                       "an assigned token is registered, never left unknown to the server")
    }

    @available(*, deprecated)
    func testAssigningCurrentTokenBeforeInitializeIsKeptForTheFirstRegistration() throws {
        OpenPush.state.resetAsIfTheProcessJustStarted()

        OpenPush.currentToken = "aabb"

        XCTAssertEqual(OpenPush.currentToken, "aabb", "the setter has always stored the token")
    }

    @available(*, deprecated)
    func testAssigningNilClearsTheTokenAndSendsNothing() throws {
        let bodies = Bodies()
        attach(bodies)
        OpenPush.storeToken("aabb")

        OpenPush.currentToken = nil

        XCTAssertNil(OpenPush.currentToken)
        XCTAssertTrue(bodies.all.isEmpty)
    }

    func testRegisterCarriesOnlyTheLoggedInIdentity() throws {
        let bodies = Bodies()
        attach(bodies)

        OpenPush.register(token: "aabb")
        XCTAssertFalse(try XCTUnwrap(bodies.last).keys.contains("external_id"))

        OpenPush.login(externalId: "person-1")
        XCTAssertEqual(bodies.last?["external_id"] as? String, "person-1")
    }
}
