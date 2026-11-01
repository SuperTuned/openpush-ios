import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushOptInTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
        func all() -> [URLRequest] { lock.withLock { requests } }
        func count() -> Int { lock.withLock { requests.count } }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool? { lock.withLock { value } }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private final class PermissionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.PermissionStatus
        init(_ value: OpenPush.PermissionStatus) { self.value = value }
        func get() -> OpenPush.PermissionStatus { lock.withLock { value } }
        func set(_ value: OpenPush.PermissionStatus) { lock.withLock { self.value = value } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    /// `prompts` counts every authorization request the seam is asked for, so a
    /// test can prove `optIn` did or did not prompt.
    private struct Seam {
        let prompts = AttemptCounter()
        let remote = AttemptCounter()
        let settingsOpened = AttemptCounter()

        func install(status: OpenPush.PermissionStatus, grant: Bool) {
            let prompts = self.prompts
            let remote = self.remote
            let settingsOpened = self.settingsOpened
            let box = PermissionBox(status)
            OpenPush.permissionSeam = OpenPush.PermissionSeam(
                status: { done in done(box.get()) },
                request: { provisional, done in
                    _ = prompts.next()
                    if grant { box.set(provisional ? .provisional : .granted) }
                    done(grant)
                },
                openSettings: { _ = settingsOpened.next() },
                registerForRemoteNotifications: { _ = remote.next() })
        }
    }

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    override func tearDown() {
        OpenPush.permissionSeam = .system
        super.tearDown()
    }

    func testOptOutReRegistersWithTheOptOutStatusAndReportsNotOptedIn() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1","status":-2}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.PushSubscription.optOut()

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, -2)
        XCTAssertFalse(OpenPush.PushSubscription.optedIn,
                       "an opted-out install is not opted in, permission and token regardless")
        XCTAssertEqual(OpenPush.User.pushSubscription.status, -2)
    }

    func testOptInAfterAnOptOutSendsTheSubscribedStatus() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1","status":1}"#)
                            })
        OpenPush.storeToken("aabb")
        OpenPush.PushSubscription.optOut()

        OpenPush.PushSubscription.optIn()

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, 7)
        XCTAssertEqual(seam.prompts.get(), 0,
                       "authorization is already granted; optIn must not prompt again")
        XCTAssertTrue(OpenPush.PushSubscription.optedIn)
    }

    func testOptInPromptsWhenAuthorizationIsMissingThenRegisters() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .notDetermined, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1","status":1}"#)
                            })
        // A token cached from an earlier launch with authorization since revoked or
        // never determined: the one state where optIn has to prompt first.
        OpenPush.storeToken("aabb")

        OpenPush.PushSubscription.optIn()

        XCTAssertEqual(seam.prompts.get(), 1)
        XCTAssertEqual(seam.remote.get(), 1, "a grant is worthless without APNs registration")
        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, 7)
        XCTAssertTrue(OpenPush.PushSubscription.optedIn)
    }

    func testARefusedPromptDoesNotClaimASubscribedDevice() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .notDetermined, grant: false)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.PushSubscription.optIn()

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, -19,
                       "a refused prompt reports the prompted-but-unanswered device state")
        XCTAssertFalse(OpenPush.PushSubscription.optedIn)
    }

    func testAGrantAfterAnOptOutDoesNotSilentlyOptTheUserBackIn() {
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.storeToken("aabb")
        OpenPush.PushSubscription.optOut()

        OpenPush.Notifications.requestPermission()

        XCTAssertTrue(OpenPush.Notifications.permission)
        XCTAssertFalse(OpenPush.PushSubscription.optedIn,
                       "an OS-level grant is not consent to undo an explicit opt-out")
    }

    func testEveryRegistrationCarriesTheComputedNotificationTypes() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })

        OpenPush.register(token: "aabb")

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, 7)
        XCTAssertEqual(OpenPush.User.pushSubscription.status, 7)
    }

    func testOptOutWithoutATokenIsHeldForTheNextRegistration() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
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

        OpenPush.PushSubscription.optOut()
        XCTAssertEqual(capture.count(), 0)

        OpenPush.register(token: "ccdd")

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, -2)
    }

    func testOnlySubscribedAndOptOutCodesAreEverSent() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.storeToken("aabb")

        OpenPush.PushSubscription.optOut()
        OpenPush.PushSubscription.optIn()

        // Asserted on the wire, not on the constants: reading the constants back to
        // their own literals would still pass if optOut sent -10 itself.
        let sent = try capture.all().map { try body(of: $0)["status"] as? Int }
        XCTAssertEqual(sent, [-2, 7],
                       "the rest of the notification_types set (-31, -22, -10, -50) is " +
                       "server-owned; a device cannot claim them about itself")
        XCTAssertTrue(sent.allSatisfy { ![-10, -22, -31, -50].contains($0 ?? 0) })
    }

    func testAConsoleSetStatusIsLoggedWithoutRewritingTheLocalIntent() {
        let log = LogCapture()
        let previousLog = OpenPush.onLog
        defer { OpenPush.onLog = previousLog }
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1","status":-22}"#) })
        OpenPush.onLog = { log.add($0) }

        OpenPush.register(token: "aabb")

        XCTAssertTrue(log.joined().contains("-22"),
                      "a status this device did not set has to be visible to the developer")
        XCTAssertNotEqual(OpenPush.wireStatus(), -22,
                          "the server's status is reported, not adopted as device state")
    }

    func testOptOutSurvivesAProcessRestartAndOptInRestoresTheDeviceValue() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        let configuration = OpenPushConfiguration(appID: "sample", sdkKey: "sdk",
                                                  serverURL: "https://push.example",
                                                  tokenKey: tokenKey)
        let transport: OpenPush.Transport = { request, done in
            capture.add(request); done(200, #"{"id":"sub_1"}"#)
        }
        OpenPush.attach(configuration: configuration, credential: { nil }, transport: transport)
        OpenPush.register(token: "aabb")
        OpenPush.PushSubscription.optOut()

        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: configuration, credential: { nil }, transport: transport)
        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, -2)

        OpenPush.PushSubscription.optIn()
        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, 7)
    }

    func testWorkspaceSwitchClearsPersistedOptOut() throws {
        let capture = Capture()
        let seam = Seam()
        seam.install(status: .granted, grant: true)
        OpenPush.initialize(appId: "first", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_1"}"#)
                            })
        OpenPush.register(token: "aabb")
        OpenPush.PushSubscription.optOut()

        OpenPush.initialize(appId: "second", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { request, done in
                                capture.add(request); done(200, #"{"id":"sub_2"}"#)
                            })

        XCTAssertEqual(try body(of: capture.last())["status"] as? Int, 7)
    }

    func testOptInPromptsOnceAndFallsBackToSettingsPastThePromptLimit() {
        let denied = Seam()
        denied.install(status: .denied, grant: false)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.storeToken("aabb")
        OpenPush.PushSubscription.optIn()
        XCTAssertEqual(denied.prompts.get(), 0)
        XCTAssertEqual(denied.settingsOpened.get(), 1)

        OpenPush.state.resetAsIfTheProcessJustStarted()
        let undecided = Seam()
        undecided.install(status: .notDetermined, grant: false)
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.storeToken("aabb")
        OpenPush.PushSubscription.optIn()
        XCTAssertEqual(undecided.prompts.get(), 1)
        XCTAssertEqual(undecided.settingsOpened.get(), 0)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
