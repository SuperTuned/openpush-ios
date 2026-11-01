import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushTagsTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        private var attempts = 0
        func set(_ request: URLRequest) {
            lock.withLock {
                value = request
                attempts += 1
            }
        }
        func get() -> URLRequest? { lock.withLock { value } }
        func count() -> Int { lock.withLock { attempts } }
    }

    private let clock = ManualClock()

    override func setUp() {
        super.setUp()
        OpenPush.scheduler = clock.seam
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private func tags(of request: URLRequest?) throws -> [String: String] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["tags"] as? [String: String])
    }

    func testTagWritesRideOneCoalescedRegistrationWithTheWholeMap() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.User.addTag(key: "plan", value: "pro")
        OpenPush.User.addTag(key: "locale", value: "en-GB")

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(try tags(of: capture.get()), ["plan": "pro", "locale": "en-GB"],
                       "one registration carries the full map, not just the newest key")
    }

    func testAddTagsSendsOneRegistrationForTheBatch() throws {
        let capture = Capture()
        let requests = AttemptCounter()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request)
                                _ = requests.next()
                                done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.User.addTags(["plan": "pro", "seats": "12", "locale": "en-GB"])

        XCTAssertEqual(requests.get(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(requests.get(), 1)
        XCTAssertEqual(try tags(of: capture.get()),
                       ["plan": "pro", "seats": "12", "locale": "en-GB"])
    }

    func testRemoveTagKeepsTheKeyWithAnEmptyValue() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.User.addTags(["plan": "pro", "seats": "12"])

        OpenPush.User.removeTag("plan")

        XCTAssertEqual(capture.count(), 0)
        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(capture.count(), 1)
        XCTAssertEqual(try tags(of: capture.get()), ["plan": "", "seats": "12"],
                       "a deletion has to travel; dropping the key would keep the old value")
    }

    func testTagsWithoutATokenAreHeldForTheNextRegistration() throws {
        let capture = Capture()
        let requests = AttemptCounter()
        // Test-isolation rule 1: a test that needs "no token yet" attaches with its
        // own token key. Clearing the token under the *default* key would rewrite
        // `UserDefaults.standard` for every later test in this process — and for the
        // developer's own simulator — so the sentinel pins that this test cannot go
        // back to doing that.
        let sharedKey = OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                              serverURL: "https://push.example").tokenKey
        UserDefaults.standard.set("sentinel", forKey: sharedKey)
        defer { UserDefaults.standard.removeObject(forKey: sharedKey) }
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
                            capture.set(request)
                            _ = requests.next()
                            done(200, #"{"id":"sub_1"}"#)
                        })
        OpenPush.state.setToken(nil, persist: true)

        OpenPush.User.addTag(key: "plan", value: "trial")
        XCTAssertEqual(requests.get(), 0)
        XCTAssertTrue(clock.pendingDelays().isEmpty)

        OpenPush.register(token: "aabb")

        XCTAssertEqual(try tags(of: capture.get()), ["plan": "trial"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: sharedKey), "sentinel",
                       "this test owns a unique token key and must leave the shared default " +
                       "one exactly as it found it")
    }

    func testOverlongTagKeysAndValuesAreDroppedWithALog() throws {
        let capture = Capture()
        let logs = LogCapture()
        OpenPush.onLog = { logs.add($0) }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        let longKey = String(repeating: "k", count: 61)
        let longValue = String(repeating: "v", count: 301)
        OpenPush.User.addTags([
            "plan": "pro",
            longKey: "pro",
            "seats": longValue,
            "": "pro",
            "two words": "pro",
            "retired": "",
        ])

        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(try tags(of: capture.get()), ["plan": "pro", "retired": ""],
                       "only the valid tags travel; a deletion is an empty value, not an " +
                       "invalid one")
        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro"])
        XCTAssertTrue(logs.contains("60"),
                      "the log has to name the key-length rule: \(logs.all())")
        XCTAssertTrue(logs.contains("300"),
                      "the log has to name the value-length rule: \(logs.all())")
        XCTAssertTrue(logs.contains("two words"),
                      "the log has to name the key it dropped: \(logs.all())")
        XCTAssertEqual(logs.dropped(), 4,
                       "one log line per dropped key, no more: \(logs.all())")
    }

    func testRemoveTagDeletesAKeyAddTagsWouldRefuse() throws {
        let capture = Capture()
        let logs = LogCapture()
        OpenPush.onLog = { logs.add($0) }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")
        let longKey = String(repeating: "k", count: 61)

        // An earlier SDK build could have put either key on the server. The tombstone is
        // the only way to clean it up, so validation must not refuse it.
        OpenPush.User.removeTag("two words")
        OpenPush.User.removeTags([longKey])

        XCTAssertEqual(clock.pendingDelays(), [0.3])
        clock.fire(0.3)

        XCTAssertEqual(try tags(of: capture.get()), ["two words": "", longKey: ""],
                       "a deletion for a key addTags would refuse still has to travel")
        XCTAssertEqual(logs.dropped(), 0,
                       "a tombstone is not a validation failure: \(logs.all())")

        OpenPush.User.addTag(key: "two words", value: "pro")
        XCTAssertEqual(logs.dropped(), 1,
                       "setting that same key is still refused: \(logs.all())")
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func all() -> [String] { lock.withLock { lines } }
        func contains(_ needle: String) -> Bool {
            all().contains { $0.contains(needle) }
        }
        func dropped() -> Int {
            all().filter { $0.hasPrefix("✗ tag") }.count
        }
    }

    func testATagFreeInstallSendsNoTagsKey() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.set(request); done(200, #"{"id":"sub_1"}"#)
                            })

        OpenPush.register(token: "aabb")

        let request = try XCTUnwrap(capture.get())
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(json.keys.contains("tags"),
                       "the wire shape has no tags key for a host that never tags")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
