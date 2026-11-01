import XCTest
@testable import OpenPush
import OpenPushCore

/// The threading contract: every public callback reaches the host on the main
/// thread, posted rather than called inline, in the order the SDK raised it.
/// Click and foreground listeners are the documented exception and run inline
/// on the delegate's thread. The compatibility facade's half of this contract
/// is in `OpenPushOneSignalMainThreadTests`.
///
/// The work behind each callback is driven from a background queue here — a
/// transport that answers off the main thread, a permission seam that answers
/// off it, an in-app engine poked from a global queue — because that is where
/// a callback used to leak to the host.
final class OpenPushMainThreadDeliveryTests: OpenPushTestCase {
    /// What the host heard, and whether it heard it on the main thread. The
    /// expectation is fulfilled by the first `expectedFulfillmentCount` entries;
    /// anything heard after that is still recorded, so an extra or late call
    /// shows up in `labels()` rather than as an over-fulfilled expectation.
    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(label: String, onMain: Bool)] = []
        private let expectation: XCTestExpectation?

        init(_ expectation: XCTestExpectation? = nil) { self.expectation = expectation }

        func record(_ label: String) {
            let onMain = Thread.isMainThread
            lock.lock()
            entries.append((label, onMain))
            let due = expectation.map { entries.count <= $0.expectedFulfillmentCount } ?? false
            lock.unlock()
            if due { expectation?.fulfill() }
        }
        func labels() -> [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.label) }
        func offMain() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { !$0.onMain }.map(\.label)
        }
    }

    private static func background(_ code: Int, _ body: String) -> OpenPush.Transport {
        { _, done in DispatchQueue.global().async { done(code, body) } }
    }

    private func initialize(_ transport: @escaping OpenPush.Transport) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example", transport: transport)
    }

    /// A permission seam that answers every question from a global queue, the
    /// way `UNUserNotificationCenter` does.
    private static func backgroundPermissionSeam(granting: Bool) -> OpenPush.PermissionSeam {
        let snapshot = OpenPush.AuthorizationSnapshot(status: granting ? .granted : .denied,
                                                      badge: granting, sound: granting,
                                                      alert: granting)
        return OpenPush.PermissionSeam(
            status: { done in DispatchQueue.global().async { done(.notDetermined) } },
            request: { _, done in DispatchQueue.global().async { done(granting) } },
            openSettings: {},
            registerForRemoteNotifications: {},
            settings: { done in DispatchQueue.global().async { done(snapshot) } })
    }

    // MARK: - Push subscription observers

    func testSubscriptionObserversRunOnMainAndInOrderAfterABackgroundResponse() {
        initialize(Self.background(200, #"{"id":"sub_1"}"#))
        waitForMainQueue()
        let done = expectation(description: "both observer lists heard the change")
        done.expectedFulfillmentCount = 2
        let heard = Deliveries(done)
        let state = OpenPush.PushSubscription.addObserver { _ in heard.record("state") }
        let change = OpenPush.PushSubscription.addChangeObserver { _ in heard.record("change") }
        defer {
            OpenPush.PushSubscription.removeObserver(state)
            OpenPush.PushSubscription.removeChangeObserver(change)
        }

        OpenPush.register(token: "aabb")

        wait(for: [done], timeout: 2)
        XCTAssertEqual(heard.labels(), ["state", "change"],
                       "state observers still hear a change before change observers")
        XCTAssertEqual(heard.offMain(), [])
    }

    func testAnObserverNeverRunsInsideTheCallThatChangedTheSubscription() {
        initialize({ _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.register(token: "aabb")
        waitForMainQueue()
        let heard = Deliveries()
        let id = OpenPush.PushSubscription.addObserver { heard.record("opted in: \($0.optedIn)") }
        defer { OpenPush.PushSubscription.removeObserver(id) }

        OpenPush.PushSubscription.optOut()

        XCTAssertEqual(heard.labels(), [],
                       "posted even from the main thread: optOut returns before the host hears it")
        waitForMainQueue()
        XCTAssertEqual(heard.labels(), ["opted in: false"])
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - Permission

    func testPermissionObserverAndRequestCompletionRunOnMainWhenIOSAnswersOffIt() {
        initialize({ _, done in done(200, #"{"id":"sub_1"}"#) })
        waitForMainQueue()
        OpenPush.permissionSeam = Self.backgroundPermissionSeam(granting: true)
        let done = expectation(description: "observer and completion")
        done.expectedFulfillmentCount = 2
        let heard = Deliveries(done)
        let id = OpenPush.Notifications.addPermissionObserver { heard.record("observer:\($0)") }
        defer { OpenPush.Notifications.removePermissionObserver(id) }

        OpenPush.Notifications.requestPermission { heard.record("completion:\($0)") }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(heard.labels(), ["observer:true", "completion:true"],
                       "the cache is refreshed and observed before the request completes")
        XCTAssertEqual(heard.offMain(), [])
    }

    func testTheProvisionalRequestCompletionRunsOnMain() {
        OpenPush.permissionSeam = Self.backgroundPermissionSeam(granting: true)
        let done = expectation(description: "completion")
        let heard = Deliveries(done)

        OpenPush.Notifications.requestProvisionalPermission { heard.record("completion:\($0)") }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(heard.labels(), ["completion:true"])
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - Identity

    func testLoginAndLogoutCompletionsRunOnMainAfterABackgroundResponse() {
        initialize(Self.background(200, #"{"id":"sub_1"}"#))
        OpenPush.storeToken("aabb")
        let loggedIn = expectation(description: "login")
        let heard = Deliveries(loggedIn)

        OpenPush.login(externalId: "person-1") { heard.record("login:\($0)") }
        wait(for: [loggedIn], timeout: 2)

        let loggedOut = expectation(description: "logout")
        let heardLogout = Deliveries(loggedOut)
        OpenPush.logout { heardLogout.record("logout:\($0)") }
        wait(for: [loggedOut], timeout: 2)

        XCTAssertEqual(heard.labels(), ["login:success"])
        XCTAssertEqual(heardLogout.labels(), ["logout:success"])
        XCTAssertEqual(heard.offMain() + heardLogout.offMain(), [])
    }

    func testALoginThatCompletesAtOnceIsStillPostedRatherThanCalledInline() {
        let heard = Deliveries()

        OpenPush.login(externalId: "") { heard.record("login:\($0)") }

        XCTAssertEqual(heard.labels(), [], "the refusal is posted, not called inside login")
        waitForMainQueue()
        XCTAssertEqual(heard.labels().count, 1)
        XCTAssertEqual(heard.offMain(), [])
    }

    func testTheIdentityVerificationRequestRunsOnMainWhenTheHookIsInstalledOffIt() {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: OpenPush.State.sessionKey(forTokenKey: tokenKey))
        }
        let configuration = OpenPushConfiguration(appID: "sample", sdkKey: "sdk_public",
                                                  serverURL: "https://push.example",
                                                  tokenKey: tokenKey)
        let transport: OpenPush.Transport = { _, done in done(200, #"{"id":"sub_1"}"#) }
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: configuration, credential: { nil }, transport: transport)
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.login(externalId: "person-7", authHash: "hash-7")
        // A relaunch: the identity comes back without its hash and a request is owed.
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: configuration, credential: { nil }, transport: transport)
        let done = expectation(description: "verification request")
        let heard = Deliveries(done)

        DispatchQueue.global().async {
            OpenPush.onIdentityVerificationRequired = { heard.record($0) }
        }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(heard.labels(), ["person-7"])
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - Registration hooks

    func testOnRegisteredRunsOnMainAfterABackgroundResponse() {
        let registered = expectation(description: "registered")
        let heard = Deliveries(registered)
        OpenPush.onRegistered = { heard.record("registered") }
        initialize(Self.background(200, #"{"id":"sub_1"}"#))

        OpenPush.register(token: "aabb")

        wait(for: [registered], timeout: 2)
        XCTAssertEqual(heard.labels(), ["registered"])
        XCTAssertEqual(heard.offMain(), [])
    }

    func testOnRegistrationFailedRunsOnMainAfterABackgroundResponse() {
        let failed = expectation(description: "failed")
        let heard = Deliveries(failed)
        OpenPush.onRegistrationFailed = { _ in heard.record("failed") }
        initialize(Self.background(409, #"{"code":"scope_conflict"}"#))

        OpenPush.register(token: "aabb")

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(heard.labels(), ["failed"])
        XCTAssertEqual(heard.offMain(), [])
    }

    func testARefusedAttachReportsItsFailureOnMainAfterReturning() {
        let heard = Deliveries()
        OpenPush.onRegistrationFailed = { _ in heard.record("failed") }
        OpenPush.onLog = { _ in }

        OpenPush.initialize(appId: " ", sdkKey: "sdk_public", serverURL: "https://push.example",
                            transport: { _, done in done(200, "{}") })

        XCTAssertEqual(heard.labels(), [], "posted, not called inside initialize")
        waitForMainQueue()
        XCTAssertEqual(heard.labels(), ["failed"])
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - Live Activities

    func testLiveActivityCompletionsRunOnMainAfterABackgroundResponse() {
        initialize(Self.background(200, "{}"))
        OpenPush.storeToken("aabb")
        let done = expectation(description: "enter, start token and exit")
        done.expectedFulfillmentCount = 3
        let heard = Deliveries(done)

        OpenPush.LiveActivities.enter("act-1", withToken: "0aff", activityType: "delivery") {
            heard.record("enter:\($0)")
        }
        OpenPush.LiveActivities.setPushToStartToken(activityType: "delivery", token: "cafe") {
            heard.record("start:\($0)")
        }
        OpenPush.LiveActivities.exit("act-2") { heard.record("exit:\($0)") }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(Set(heard.labels()), ["enter:true", "start:true", "exit:true"])
        XCTAssertEqual(heard.offMain(), [])
    }

    func testARefusedLiveActivityCallIsPostedRatherThanCalledInline() {
        let heard = Deliveries()

        OpenPush.LiveActivities.enter("act-1", withToken: "", activityType: "delivery") {
            heard.record("enter:\($0)")
        }

        XCTAssertEqual(heard.labels(), [])
        waitForMainQueue()
        XCTAssertEqual(heard.labels(), ["enter:false"])
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - In-app messages

    func testInAppLifecycleAndClickListenersRunOnMainWhenTheEngineRunsOffIt() {
        let harness = IamHarness(rows: "[\(IamHarness.row(id: "iam_1"))]")
        let done = expectation(description: "four stages and a click")
        done.expectedFulfillmentCount = 5
        let heard = Deliveries(done)
        let lifecycle = OpenPush.InAppMessages.addLifecycleListener { heard.record($0.phase) }
        let click = OpenPush.InAppMessages.addClickListener { _ in heard.record("click") }
        defer {
            OpenPush.InAppMessages.removeLifecycleListener(lifecycle)
            OpenPush.InAppMessages.removeClickListener(click)
        }

        // willDisplay is raised by whatever thread made the message eligible:
        // here a global queue, as a fetch response or the scheduler would.
        DispatchQueue.global().async {
            harness.fetch()
            harness.emitLast(.rendered(height: nil))
            harness.emitLast(.action(.init(clickID: "c1", blockKey: "b1", closes: true)))
        }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(heard.labels(),
                       ["willDisplay", "didDisplay", "click", "willDismiss", "didDismiss"])
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - Notification clicks and foreground

    func testHeldClicksReplayOnMainWhileALiveClickStaysInline() {
        initialize({ _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "held"], actionId: nil)
        let replayed = expectation(description: "held click replayed")
        let heard = Deliveries(replayed)
        let box = ListenerBox()

        DispatchQueue.global().async {
            box.set(OpenPush.Notifications.addClickListener { heard.record($0.messageId ?? "") })
        }
        wait(for: [replayed], timeout: 2)
        defer { if let id = box.get() { OpenPush.Notifications.removeClickListener(id) } }

        OpenPush.Notifications.handleClick(userInfo: ["op_message_id": "live"], actionId: nil)

        XCTAssertEqual(heard.labels(), ["held", "live"],
                       "a live click reaches the listener before processClick returns")
        XCTAssertEqual(heard.offMain(), [])
    }

    func testForegroundListenersStayInlineSoTheirDecisionIsHonoured() {
        initialize({ _, done in done(200, #"{"id":"sub_1"}"#) })
        let heard = Deliveries()
        let id = OpenPush.Notifications.addForegroundLifecycleListener { event in
            heard.record("foreground")
            event.preventDefault()
        }
        defer { OpenPush.Notifications.removeForegroundLifecycleListener(id) }

        let options = OpenPush.Notifications.handleForeground(
            userInfo: ["op_message_id": "msg_\(UUID().uuidString)"])

        XCTAssertEqual(heard.labels(), ["foreground"], "the listener ran before the answer")
        XCTAssertEqual(options, [], "so preventDefault() reached the presentation decision")
        XCTAssertEqual(heard.offMain(), [])
    }

    // MARK: - Receipts

    func testAReceiptCompletionRunsOnMainAfterABackgroundResponse() {
        initialize(Self.background(200, #"{"accepted":1}"#))
        OpenPush.storeToken("aabb")
        let done = expectation(description: "receipt")
        let heard = Deliveries(done)

        OpenPush.receipt("received", messageID: "msg_1") { heard.record("then") }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(heard.labels(), ["then"])
        XCTAssertEqual(heard.offMain(), [])
    }
}

private final class ListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?
    func set(_ value: UUID) { lock.lock(); id = value; lock.unlock() }
    func get() -> UUID? { lock.lock(); defer { lock.unlock() }; return id }
}
