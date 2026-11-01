import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushIdentityVerificationTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String) { lock.withLock { value = newValue } }
        func get() -> String? { lock.withLock { value } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        func get() -> Int { lock.withLock { value } }
    }

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func coldStart(tokenKey: String, _ transport: @escaping OpenPush.Transport) {
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil }, transport: transport)
    }

    func testAfterARelaunchAVerifiedIdentityIsNotAssertedWithoutItsHash() throws {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        coldStart(tokenKey: tokenKey) { _, done in done(200, #"{"id":"sub_1"}"#) }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.login(externalId: "person-7", authHash: "hash-7")

        let capture = Capture()
        let asked = Box()
        OpenPush.onIdentityVerificationRequired = { asked.set($0) }
        coldStart(tokenKey: tokenKey) { request, done in
            capture.set(request); done(200, #"{"id":"sub_1"}"#)
        }
        OpenPush.register(token: "aabb")

        let json = try body(of: capture.get())
        XCTAssertFalse(json.keys.contains("external_id"),
                       "without the hash the server would strip identity, tags and aliases; " +
                       "omitting the key leaves the existing link untouched")
        waitForMainQueue()
        XCTAssertEqual(asked.get(), "person-7")
        XCTAssertEqual(OpenPush.User.externalId, "person-7", "the local identity is still known")

        OpenPush.login(externalId: "person-7", authHash: "hash-7")

        let verified = try body(of: capture.get())
        XCTAssertEqual(verified["external_id"] as? String, "person-7")
        XCTAssertEqual(verified["external_id_auth_hash"] as? String, "hash-7")
    }

    func testAHookInstalledAfterInitializeStillReceivesThePendingRequest() throws {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        coldStart(tokenKey: tokenKey) { _, done in done(200, #"{"id":"sub_1"}"#) }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.login(externalId: "person-7", authHash: "hash-7")

        // The sample app installs its hooks after `initialize`; the request must
        // wait for the hook rather than being burned by attach.
        coldStart(tokenKey: tokenKey) { _, done in done(200, #"{"id":"sub_1"}"#) }

        let asked = Box()
        OpenPush.onIdentityVerificationRequired = { asked.set($0) }
        waitForMainQueue()
        XCTAssertEqual(asked.get(), "person-7")
    }

    func testTheVerificationRequestFiresOnceForTheProcess() throws {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        coldStart(tokenKey: tokenKey) { _, done in done(200, #"{"id":"sub_1"}"#) }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.login(externalId: "person-7", authHash: "hash-7")

        let counter = Counter()
        OpenPush.onIdentityVerificationRequired = { _ in counter.bump() }
        let configuration = OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example",
                                                  tokenKey: tokenKey)
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: configuration, credential: { nil },
                        transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.attach(configuration: configuration, credential: { nil },
                        transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.onIdentityVerificationRequired = { _ in counter.bump() }

        waitForMainQueue()
        XCTAssertEqual(counter.get(), 1,
                       "one process, one ask: neither a repeated initialize nor a second " +
                       "hook re-raises it")
    }

    func testAnUnverifiedIdentityStillRidesEveryRegistrationAfterARelaunch() throws {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        coldStart(tokenKey: tokenKey) { _, done in done(200, #"{"id":"sub_1"}"#) }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.login(externalId: "person-8")

        let capture = Capture()
        let asked = Box()
        OpenPush.onIdentityVerificationRequired = { asked.set($0) }
        coldStart(tokenKey: tokenKey) { request, done in
            capture.set(request); done(200, #"{"id":"sub_1"}"#)
        }
        OpenPush.register(token: "aabb")

        XCTAssertEqual(try body(of: capture.get())["external_id"] as? String, "person-8")
        waitForMainQueue()
        XCTAssertNil(asked.get(), "an app that never used verification is never asked for a hash")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
