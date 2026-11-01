import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0

        func next() -> Int {
            lock.withLock {
                attempts += 1
                return attempts
            }
        }

        func get() -> Int { lock.withLock { attempts } }
    }

    private final class StringCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String) { lock.withLock { value = newValue } }
        func get() -> String? { lock.withLock { value } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
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
        func set(_ value: @escaping (Int, String) -> Void) {
            lock.withLock { completion = value }
        }
        func finish(_ code: Int, _ response: String) {
            lock.withLock { completion }?(code, response)
        }
    }

    func testAPNsTokenIsLowercaseHex() {
        XCTAssertEqual(OpenPush.hexToken(Data([0x00, 0xAF, 0x10])), "00af10")
    }

    func testPublicModuleHasReceivePrimitives() {
        XCTAssertNil(OpenPush.messageID(from: [:]))
        XCTAssertFalse(OpenPush.deviceModel().isEmpty)
    }

    func testRegistrationRequestCanBeInjectedAndCarriesPublicAndDeviceCredentials() throws {
        let capture = Capture()
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public", serverURL: "https://push.example"),
            credential: { "opdev_secret" },
            transport: { request, done in capture.set(request); done(201, "ok") })

        OpenPush.login(externalId: "person-1")
        OpenPush.register(token: "aabb")

        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.absoluteString, "https://push.example/v1/apps/sample/subscriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-Device-Key"), "opdev_secret")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["token"] as? String, "aabb")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["external_id"] as? String, "person-1")
        XCTAssertEqual(json["country"] as? String, OpenPush.countryCode())
        XCTAssertEqual(json["sdk_version"] as? String, OpenPush.sdkVersion)
        XCTAssertNotNil(json["os_version"] as? String)
    }

    func testRegistrationReportsTheSignedAPNsEnvironment() throws {
        let capture = Capture()
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example"),
            credential: { "opdev_secret" },
            transport: { request, done in capture.set(request); done(201, "ok") })

        OpenPush.performRegistration(token: "aabb",
                                     apsEnvironment: "development", completion: nil)

        let request = try XCTUnwrap(capture.get())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["sandbox"] as? Bool, true,
                       "a development-signed device token must use Apple's sandbox host")
        XCTAssertEqual(OpenPush.sandboxFlag(forAPNsEnvironment: "production"), false)
        XCTAssertNil(OpenPush.sandboxFlag(forAPNsEnvironment: "unknown"))
    }

    func testLanguageIsTheFullTag() throws {
        let capture = Capture()
        OpenPush.preferredLanguageSeam = { "zh-Hant-TW" }
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example"),
            credential: { "opdev_secret" },
            transport: { request, done in capture.set(request); done(201, "ok") })

        OpenPush.register(token: "aabb")

        XCTAssertEqual(try language(of: capture.get()), "zh-Hant-TW",
                       "a script-and-region tag must ride the wire whole; truncating it to " +
                       "'zh' loses the only thing that distinguishes traditional from " +
                       "simplified copy")

        OpenPush.preferredLanguageSeam = { nil }
        OpenPush.register(token: "aabb")

        XCTAssertEqual(try language(of: capture.get()), "en",
                       "a device that reports no preferred language still needs a language")
    }

    private func language(of request: URLRequest?) throws -> String {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["language"] as? String)
    }

    func testDeviceModelNeverLies() {
        #if targetEnvironment(simulator)
        // A Simulator's `uname` reports the host Mac's hardware, so the model
        // comes from the runtime's own identifier and the machine string is
        // deliberately ignored. Naming the Mac, or a phone this is not, is the
        // lie this test is about — the prefix is what says neither happened.
        XCTAssertTrue(OpenPush.deviceModel(machine: "").hasPrefix("Simulator "))
        XCTAssertTrue(OpenPush.deviceModel(machine: "iPhone17,1").hasPrefix("Simulator "))
        #else
        XCTAssertEqual(OpenPush.deviceModel(machine: ""), "unknown",
                       "an unreadable machine string must say so, not name a device this " +
                       "install may not be")
        XCTAssertEqual(OpenPush.deviceModel(machine: "iPhone17,1"), "iPhone17,1")
        #endif
    }

    func testCountryCodeUsesTheDeviceLocaleRegion() {
        XCTAssertEqual(OpenPush.countryCode(locale: Locale(identifier: "en_IN")), "IN")
        XCTAssertNil(OpenPush.countryCode(locale: Locale(identifier: "en")))
    }

    func testOperatingSystemVersionUsesStableNumericComponents() {
        XCTAssertEqual(
            OpenPush.operatingSystemVersion(
                OperatingSystemVersion(majorVersion: 18, minorVersion: 5, patchVersion: 0)),
            "18.5"
        )
        XCTAssertEqual(
            OpenPush.operatingSystemVersion(
                OperatingSystemVersion(majorVersion: 18, minorVersion: 5, patchVersion: 1)),
            "18.5.1"
        )
    }

    func testFailedReceiptCanBeRetriedButSuccessfulReceiptIsDeduplicated() {
        let counter = AttemptCounter()
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example"),
            credential: { "opdev_secret" },
            transport: { _, done in
                done(counter.next() == 1 ? 503 : 202, "")
            })
        OpenPush.storeToken("aabb")

        OpenPush.receipt("received", messageID: "msg_retry")
        OpenPush.receipt("received", messageID: "msg_retry")

        XCTAssertEqual(counter.get(), 1,
                       "a receipt already queued is not posted again by a duplicate call")

        clock.fire(2)

        XCTAssertEqual(counter.get(), 2,
                       "a failure must release the receipt for retry, on the queue's schedule")

        OpenPush.receipt("received", messageID: "msg_retry")

        XCTAssertEqual(counter.get(), 2, "a success must close it")
    }

    func testRegistrationFailureIsReportedWithoutCallingSuccess() {
        let failure = StringCapture()
        let success = AttemptCounter()
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example"),
            credential: { "opdev_secret" },
            transport: { _, done in done(503, "upstream unavailable") })
        OpenPush.onRegistered = { _ = success.next() }
        OpenPush.onRegistrationFailed = { failure.set($0) }

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        XCTAssertEqual(success.get(), 0)
        XCTAssertNil(failure.get(), "a retryable first failure stays internal")
        XCTAssertEqual(clock.pendingDelays(), [2])
        clock.fire(2)
        waitForMainQueue()
        XCTAssertNil(failure.get())
        XCTAssertEqual(clock.pendingDelays(), [8])
        clock.fire(8)

        waitForMainQueue()
        XCTAssertEqual(failure.get(),
                       "OpenPush could not register this device (503). Check your connection and try again.")
    }

    func testWorkspaceConflictHasAnActionableRegistrationFailure() {
        let failure = StringCapture()
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example"),
            credential: { "opdev_secret" },
            transport: { _, done in
                done(409, #"{"code":"scope_conflict","detail":"device already linked"}"#)
            })
        OpenPush.onRegistrationFailed = { failure.set($0) }

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        XCTAssertEqual(failure.get(),
                       "This device is still linked to another workspace. Reset this device, then sign in again.")
    }

    func testRegistrationResponseFromPreviousCredentialIsIgnoredAfterReset() {
        let credential = CredentialBox("opdev_old")
        let completion = CompletionCapture()
        let success = AttemptCounter()
        let failure = StringCapture()
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example"),
            credential: { credential.get() },
            transport: { _, done in completion.set(done) })
        OpenPush.onRegistered = { _ = success.next() }
        OpenPush.onRegistrationFailed = { failure.set($0) }

        OpenPush.register(token: "aabb")
        credential.set(nil)
        completion.finish(201, "ok")

        waitForMainQueue()
        XCTAssertEqual(success.get(), 0)
        XCTAssertNil(failure.get())
        XCTAssertTrue(clock.pendingDelays().isEmpty,
                      "a response from a replaced credential is terminal, not retryable")
    }

    /// The registration is accepted, so nothing else tells the host that a field
    /// it sends on every launch is being discarded by the app's collection
    /// settings.
    func testNotCollectedFieldsAreLogged() {
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        OpenPush.initialize(
            appId: "sample", sdkKey: "sdk_public", serverURL: "https://push.example",
            transport: { _, done in
                done(200, #"{"id":"sub_1","not_collected":["country","language"]}"#)
            })
        OpenPush.onLog = { log.add($0) }

        OpenPush.register(token: "aabb")

        let lines = log.joined()
        XCTAssertTrue(lines.contains("the server did not store: country, language"),
                      "a discarded field is invisible on a 2xx unless the SDK names it: \(lines)")
        XCTAssertTrue(lines.contains("collection is disabled for this app"))
        XCTAssertEqual(
            OpenPush.parseRegistration(#"{"not_collected":["country"]}"#).notCollected,
            ["country"])
        XCTAssertEqual(
            OpenPush.parseRegistration(#"{"not_collected":"country"}"#).notCollected,
            ["country"], "a single field may arrive unwrapped")
        XCTAssertEqual(OpenPush.parseRegistration(#"{"id":"sub_1"}"#).notCollected, [])
        XCTAssertEqual(OpenPush.parseRegistration("not json").notCollected, [])
    }

    // ------------------------------------------------------------ SDK identity

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func all() -> [URLRequest] { lock.withLock { requests } }
        func paths() -> Set<String> { Set(all().compactMap { $0.url?.path }) }
    }

    private func clearSDKHeaderStorage(_ tokenKey: String) {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: tokenKey + ".receipts")
        UserDefaults.standard.removeObject(forKey: tokenKey + ".receiptsSent")
        UserDefaults.standard.removeObject(forKey: tokenKey + ".customEvents")
        UserDefaults.standard.removeObject(
            forKey: OpenPush.State.sessionKey(forTokenKey: tokenKey))
    }

    /// Server-side triage starts with "which SDK sent this?". A header on the
    /// registration alone answers that for the one request that already carries
    /// `sdk_version`, and leaves receipts, sessions and events anonymous.
    func testEveryRequestCarriesTheSDKHeader() throws {
        let log = RequestLog()
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        let tokenKey = "openpush.sdkheader.\(UUID().uuidString)"
        defer { clearSDKHeaderStorage(tokenKey) }

        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                 serverURL: "https://push.example",
                                                 tokenKey: tokenKey),
            credential: { "opdev_secret" },
            transport: { request, done in
                log.add(request)
                done(200, #"{"id":"sub_1","accepted":1}"#)
            })

        OpenPush.register(token: "aabb")
        OpenPush.receipt("received", messageID: "msg-sdk-header")
        OpenPush.Notifications.onAppForegrounded()
        OpenPush.trackEvent("sdk_header_check", properties: ["step": 1])
        clock.fire(OpenPush.writeCoalescingWindow)

        let paths = log.paths()
        XCTAssertTrue(paths.contains("/v1/apps/sample/subscriptions"), "\(paths)")
        XCTAssertTrue(paths.contains("/v1/ingest"), "\(paths)")
        XCTAssertTrue(paths.contains("/v1/apps/sample/sessions"), "\(paths)")
        XCTAssertTrue(paths.contains("/v1/apps/sample/events"), "\(paths)")

        for request in log.all() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK"),
                           "openpush/ios/\(OpenPush.sdkVersion)",
                           "\(request.url?.path ?? "?") went out unidentified")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-OP-SDK-Wrapper"),
                         "a native install claims no wrapper")
        }
    }

    /// A wrapper SDK is set before `initialize` — it is the wrapper that calls
    /// `initialize` — so the identity must outlive `attach`, ride every request
    /// as a header, and reach the subscription row through the registration body.
    func testAWrapperIsReportedInHeaderAndBody() throws {
        let log = RequestLog()
        let logLines = LogCapture()
        let clock = ManualClock()
        OpenPush.scheduler = clock.seam
        let tokenKey = "openpush.sdkwrapper.\(UUID().uuidString)"
        defer {
            clearSDKHeaderStorage(tokenKey)
            OpenPush.wrapper = nil
        }

        OpenPush.wrapper = OpenPush.SDKWrapper(name: "  unity  ", version: " 1.1.4 ")
        XCTAssertEqual(OpenPush.wrapper,
                       OpenPush.SDKWrapper(name: "unity", version: "1.1.4"),
                       "a stray space around a wrapper name must not reach the wire")

        OpenPush.attach(
            configuration: OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                 serverURL: "https://push.example",
                                                 tokenKey: tokenKey),
            credential: { "opdev_secret" },
            transport: { request, done in
                log.add(request)
                done(200, #"{"id":"sub_1","accepted":1}"#)
            })
        XCTAssertNotNil(OpenPush.wrapper,
                        "attach must not clear an identity the wrapper set before it")

        OpenPush.register(token: "aabb")
        OpenPush.receipt("received", messageID: "msg-sdk-wrapper")
        OpenPush.Notifications.onAppForegrounded()

        XCTAssertFalse(log.all().isEmpty)
        for request in log.all() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Wrapper"),
                           "unity/1.1.4",
                           "\(request.url?.path ?? "?") did not name the wrapper")
        }
        let registration = try XCTUnwrap(
            log.all().first { $0.url?.path == "/v1/apps/sample/subscriptions" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(registration.httpBody)) as? [String: Any])
        XCTAssertEqual(json["sdk_wrapper"] as? String, "unity/1.1.4")
        XCTAssertEqual(json["sdk_version"] as? String, OpenPush.sdkVersion,
                       "the wrapper is additive; the native version still rides along")

        OpenPush.onLog = { logLines.add($0) }
        OpenPush.wrapper = OpenPush.SDKWrapper(name: "unity", version: "   ")
        XCTAssertNil(OpenPush.wrapper,
                     "half a wrapper identity is worse than none — it cannot be parsed")
        XCTAssertTrue(logLines.joined().contains("wrapper"),
                      "a refused wrapper has to say so: \(logLines.joined())")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
