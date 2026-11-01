import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushPermissionTests: OpenPushTestCase {
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        func next() -> Int { lock.withLock { attempts += 1; return attempts } }
        func get() -> Int { lock.withLock { attempts } }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool? { lock.withLock { value } }
    }

    private final class PermissionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.PermissionStatus
        init(_ value: OpenPush.PermissionStatus) { self.value = value }
        func get() -> OpenPush.PermissionStatus { lock.withLock { value } }
        func set(_ value: OpenPush.PermissionStatus) { lock.withLock { self.value = value } }
    }

    /// Records every platform call the permission surface would make.
    private struct Recorder {
        let requests = AttemptCounter()
        let settings = AttemptCounter()
        let remote = AttemptCounter()
        let provisionalSeen = FlagBox()

        func seam(status: OpenPush.PermissionStatus, grant: Bool) -> OpenPush.PermissionSeam {
            let requests = self.requests
            let settings = self.settings
            let remote = self.remote
            let provisionalSeen = self.provisionalSeen
            let statusBox = PermissionBox(status)
            return OpenPush.PermissionSeam(
                status: { done in done(statusBox.get()) },
                request: { provisional, done in
                    _ = requests.next()
                    provisionalSeen.set(provisional)
                    if grant { statusBox.set(provisional ? .provisional : .granted) }
                    done(grant)
                },
                openSettings: { _ = settings.next() },
                registerForRemoteNotifications: { _ = remote.next() })
        }
    }

    override func tearDown() {
        OpenPush.permissionSeam = .system
        super.tearDown()
    }

    func testGrantedPermissionCachesAndStartsRemoteRegistration() {
        let recorder = Recorder()
        let outcome = FlagBox()
        OpenPush.permissionSeam = recorder.seam(status: .notDetermined, grant: true)

        OpenPush.Notifications.requestPermission { outcome.set($0) }

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), true)
        XCTAssertTrue(OpenPush.Notifications.permission)
        XCTAssertEqual(recorder.requests.get(), 1)
        XCTAssertEqual(recorder.provisionalSeen.get(), false)
        XCTAssertEqual(recorder.remote.get(), 1,
                       "a grant is worthless without APNs registration")
        XCTAssertEqual(recorder.settings.get(), 0)
    }

    func testRefusedPermissionIsReportedAndNotCached() {
        let recorder = Recorder()
        let outcome = FlagBox()
        OpenPush.permissionSeam = recorder.seam(status: .notDetermined, grant: false)

        OpenPush.Notifications.requestPermission { outcome.set($0) }

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false)
        XCTAssertFalse(OpenPush.Notifications.permission)
        XCTAssertEqual(recorder.remote.get(), 0)
        XCTAssertEqual(recorder.settings.get(), 0,
                       "a fresh refusal must not bounce the user into Settings")
    }

    func testAlreadyDeniedPermissionOpensSettingsOnlyWhenAsked() {
        let recorder = Recorder()
        let outcome = FlagBox()
        OpenPush.permissionSeam = recorder.seam(status: .denied, grant: false)

        OpenPush.Notifications.requestPermission(fallbackToSettings: true) { outcome.set($0) }

        waitForMainQueue()
        XCTAssertEqual(outcome.get(), false)
        XCTAssertEqual(recorder.requests.get(), 0,
                       "iOS cannot prompt again after a denial; do not pretend otherwise")
        XCTAssertEqual(recorder.settings.get(), 1)

        let quiet = Recorder()
        OpenPush.permissionSeam = quiet.seam(status: .denied, grant: false)
        OpenPush.Notifications.requestPermission()
        XCTAssertEqual(quiet.settings.get(), 0)
    }

    func testProvisionalInitializeAsksForQuietAuthorizationWithoutAPrompt() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .notDetermined, grant: true)

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            provisional: true,
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })

        XCTAssertEqual(recorder.requests.get(), 1)
        XCTAssertEqual(recorder.provisionalSeen.get(), true)
        XCTAssertEqual(recorder.remote.get(), 1)
        XCTAssertTrue(OpenPush.Notifications.permission)
    }

    /// A host that uses the legacy entry point calls `attach` and never `initialize`. `attach` resets the
    /// permission cache to false, so without a refresh here that host reads
    /// `permission == false` — and therefore `optedIn == false` — for the whole
    /// process, no matter what the OS has granted.
    func testAttachRefreshesThePermissionCacheWithoutPrompting() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .granted, grant: false)
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(
                forKey: OpenPush.State.sessionKey(forTokenKey: tokenKey))
        }

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.storeToken("aabb")

        XCTAssertTrue(OpenPush.Notifications.permission)
        XCTAssertTrue(OpenPush.PushSubscription.optedIn,
                      "an authorized, registered install is opted in whichever entry point the " +
                      "host used")
        XCTAssertEqual(recorder.requests.get(), 0, "attach must never prompt")
        XCTAssertEqual(recorder.remote.get(), 0,
                       "token re-sync is an initialize ergonomic, not attach behavior")
    }

    func testPlainInitializeRefreshesTheCacheAndReSyncsWithoutPrompting() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .provisional, grant: false)

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })

        XCTAssertEqual(recorder.requests.get(), 0, "initialize must never prompt on its own")
        XCTAssertEqual(recorder.remote.get(), 1)
        XCTAssertTrue(OpenPush.Notifications.permission,
                      "provisional authorization can deliver, so it counts as permission")
    }

    // MARK: - Permission surface

    func testCanRequestPermissionIsTrueOnlyBeforeThePromptWasEverShown() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .notDetermined, grant: true)
        OpenPush.Notifications.refreshPermission()

        XCTAssertTrue(OpenPush.Notifications.canRequestPermission)

        OpenPush.Notifications.requestPermission()

        XCTAssertFalse(OpenPush.Notifications.canRequestPermission,
                       "iOS shows the system prompt once per install; a host that asks again " +
                       "gets nothing")
    }

    func testCanRequestPermissionIsFalseOnceAuthorizationWasDecided() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .denied, grant: false)
        OpenPush.Notifications.refreshPermission()

        XCTAssertFalse(OpenPush.Notifications.canRequestPermission)
        XCTAssertEqual(OpenPush.Notifications.permissionStatus, .denied)
    }

    func testPermissionStatusDistinguishesProvisionalFromFullAuthorization() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .provisional, grant: false)
        OpenPush.Notifications.refreshPermission()

        XCTAssertEqual(OpenPush.Notifications.permissionStatus, .provisional)
        XCTAssertTrue(OpenPush.Notifications.permission,
                      "the boolean stays coarse; only the status tells the two apart")
    }

    func testEphemeralAuthorizationIsItsOwnStatusAndStillDelivers() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .ephemeral, grant: false)
        OpenPush.Notifications.refreshPermission()

        XCTAssertEqual(OpenPush.Notifications.permissionStatus, .ephemeral,
                       "an App Clip's authorization is not the same thing as a full grant")
        XCTAssertTrue(OpenPush.Notifications.permission)
        XCTAssertTrue(OpenPush.PermissionStatus.ephemeral.isGranted)
        XCTAssertFalse(OpenPush.Notifications.canRequestPermission)
    }

    func testRequestProvisionalPermissionUsesTheQuietPath() {
        let recorder = Recorder()
        OpenPush.permissionSeam = recorder.seam(status: .notDetermined, grant: true)

        OpenPush.Notifications.requestProvisionalPermission()

        XCTAssertEqual(recorder.provisionalSeen.get(), true,
                       "a provisional request must never raise the system prompt")
        XCTAssertEqual(recorder.requests.get(), 1)
        XCTAssertEqual(recorder.settings.get(), 0)
        XCTAssertEqual(OpenPush.Notifications.permissionStatus, .provisional)
        XCTAssertTrue(OpenPush.Notifications.canRequestPermission,
                      "quiet authorization does not consume the standard prompt")
        XCTAssertFalse(OpenPush.state.wasPrompted)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
