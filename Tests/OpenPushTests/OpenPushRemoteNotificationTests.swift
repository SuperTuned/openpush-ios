import XCTest
@testable import OpenPush

final class OpenPushRemoteNotificationTests: OpenPushTestCase {
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func last() -> URLRequest? { lock.withLock { requests.last } }
        func all() -> [URLRequest] { lock.withLock { requests } }
    }

    private final class StringCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String) { lock.withLock { value = newValue } }
        func get() -> String? { lock.withLock { value } }
    }

    private struct Recorder {
        let requests = AttemptCounter()
        let remote = AttemptCounter()

        func seam(status: OpenPush.PermissionStatus, grant: Bool) -> OpenPush.PermissionSeam {
            let requests = self.requests
            let remote = self.remote
            return OpenPush.PermissionSeam(
                status: { done in done(status) },
                request: { _, done in _ = requests.next(); done(grant) },
                openSettings: {},
                registerForRemoteNotifications: { _ = remote.next() })
        }
    }

    private func start(_ capture: Capture) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { request, done in capture.add(request); done(200, "{}") })
    }

    private func receiptTypes(in capture: Capture) throws -> [String] {
        try capture.all().compactMap { request -> String? in
            guard request.url?.path == "/v1/ingest", let data = request.httpBody else { return nil }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            return events.first?["type"] as? String
        }
    }

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInitializeReSyncsARotatedTokenWhenAuthorizationIsAlreadyGranted() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .granted, grant: false)

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, "{}") })

        XCTAssertEqual(recorder.remote.get(), 1)
        XCTAssertEqual(recorder.requests.get(), 0)
    }

    func testInitializeAsksForNoTokenWhenAuthorizationWasNeverGranted() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .notDetermined, grant: false)

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, "{}") })

        XCTAssertEqual(recorder.remote.get(), 0)
        XCTAssertEqual(recorder.requests.get(), 0)
    }

    func testProvisionalInitializeAsksForATokenExactlyOnce() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .granted, grant: true)

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example", provisional: true,
                            transport: { _, done in done(200, "{}") })

        XCTAssertEqual(recorder.remote.get(), 1)
    }

    func testForwardedDeviceTokenIsHexedAndRegistered() throws {
        let capture = Capture()
        start(capture)

        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0x00, 0xAF, 0x10]))

        XCTAssertEqual(try body(of: capture.last())["token"] as? String, "00af10")
    }

    func testAMissingPushCapabilityIsNamedRatherThanDescribedAsAServerProblem() throws {
        let capture = Capture()
        let failure = StringCapture()
        start(capture)
        OpenPush.onRegistrationFailed = { failure.set($0) }

        OpenPush.didFailToRegisterForRemoteNotifications(
            error: NSError(domain: NSCocoaErrorDomain, code: 3000,
                           userInfo: [NSLocalizedDescriptionKey:
                                        "no valid 'aps-environment' entitlement string found"]))

        waitForMainQueue()
        let message = try XCTUnwrap(failure.get())
        XCTAssertTrue(message.contains("Push Notifications capability"))
        XCTAssertTrue(message.contains("aps-environment"))
    }

    func testTheSimulatorCaseIsNamed() {
        XCTAssertTrue(OpenPush.apnsRegistrationDiagnostic(
            NSError(domain: NSCocoaErrorDomain, code: 3010)).contains("simulator"))
    }

    func testAnUnrecognisedFailureStillCarriesItsOwnDescription() {
        XCTAssertTrue(OpenPush.apnsRegistrationDiagnostic(
            NSError(domain: "SomeOtherDomain", code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "kaboom"])).contains("kaboom"))
    }

    // MARK: - Background pushes

    func testABackgroundPushPostsAReceivedReceiptAndReportsOwnership() throws {
        let capture = Capture()
        start(capture)
        OpenPush.storeToken("aabb")

        XCTAssertTrue(OpenPush.didReceiveRemoteNotification(
            userInfo: ["op_message_id": "m1", "aps": ["content-available": 1]]))
        XCTAssertEqual(try receiptTypes(in: capture), ["received"])

        XCTAssertFalse(OpenPush.didReceiveRemoteNotification(
            userInfo: ["aps": ["content-available": 1]]),
                       "a push OpenPush did not send is the host's to handle")
        XCTAssertEqual(try receiptTypes(in: capture), ["received"],
                       "a foreign payload must never be reported as a delivery")
    }

    func testABackgroundPushNeverFiresClickOrForegroundListeners() throws {
        let capture = Capture()
        let clicks = AttemptCounter()
        let foregrounds = AttemptCounter()
        start(capture)
        OpenPush.storeToken("aabb")
        let click = OpenPush.Notifications.addClickListener { _ in _ = clicks.next() }
        let foreground = OpenPush.Notifications.addForegroundLifecycleListener { _ in
            _ = foregrounds.next()
        }
        defer {
            OpenPush.Notifications.removeClickListener(click)
            OpenPush.Notifications.removeForegroundLifecycleListener(foreground)
        }

        OpenPush.didReceiveRemoteNotification(
            userInfo: ["op_message_id": "m2", "aps": ["content-available": 1]])

        XCTAssertEqual(clicks.get(), 0, "nobody tapped anything")
        XCTAssertEqual(foregrounds.get(), 0, "a silent push is never presented")
        XCTAssertEqual(try receiptTypes(in: capture), ["received"])
    }

    /// An iOS background push is `content-available` and reaches the app through
    /// `didReceiveRemoteNotification`. Launch-URL opening must not reach into that
    /// path: a silent push opens no URL even with launch-URL opening on, and is
    /// never a click.
    func testABackgroundPushReachesTheAppAndOpensNoURL() throws {
        let capture = Capture()
        let clicks = AttemptCounter()
        let opened = AttemptCounter()
        start(capture)
        OpenPush.storeToken("aabb")
        OpenPush.Notifications.openLaunchURLs = true
        OpenPush.launchURLOpener = { _ in _ = opened.next() }
        let click = OpenPush.Notifications.addClickListener { _ in _ = clicks.next() }
        defer { OpenPush.Notifications.removeClickListener(click) }

        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1], "op_message_id": "bg-silent",
            "deep_link": "https://example.com/never", "sync": "inventory",
        ]
        XCTAssertTrue(OpenPush.didReceiveRemoteNotification(userInfo: payload))
        XCTAssertTrue(OpenPush.Notification(userInfo: payload).contentAvailable)

        XCTAssertEqual(try receiptTypes(in: capture), ["received"])
        XCTAssertEqual(clicks.get(), 0)
        XCTAssertEqual(opened.get(), 0, "a silent push never opens a URL")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
