import XCTest
@testable import OpenPush

final class OpenPushObserverTests: OpenPushTestCase {
    private final class Values<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [T] = []
        func add(_ value: T) { lock.withLock { values.append(value) } }
        func all() -> [T] { lock.withLock { values } }
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.PushSubscriptionState?
        func set(_ newValue: OpenPush.PushSubscriptionState) { lock.withLock { value = newValue } }
        func get() -> OpenPush.PushSubscriptionState? { lock.withLock { value } }
    }

    private final class SeamBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OpenPush.AuthorizationSnapshot
        init(_ value: OpenPush.AuthorizationSnapshot) { self.value = value }
        func set(_ newValue: OpenPush.AuthorizationSnapshot) { lock.withLock { value = newValue } }
        func seam() -> OpenPush.PermissionSeam {
            OpenPush.PermissionSeam(
                status: { done in done(self.lock.withLock { self.value.status }) },
                request: { _, done in done(false) }, openSettings: {},
                registerForRemoteNotifications: {},
                settings: { done in done(self.lock.withLock { self.value }) })
        }
    }

    private func initialize(_ box: SeamBox) {
        OpenPush.permissionSeam = box.seam()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk", serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
    }

    func testPermissionObserverFiresOnceWhenSettingsChangeAtForeground() {
        let box = SeamBox(.init(status: .denied))
        initialize(box)
        let observed = Values<Bool>()
        _ = OpenPush.Notifications.addPermissionObserver { observed.add($0) }

        box.set(.init(status: .granted, badge: true, sound: true, alert: true))
        OpenPush.Notifications.onAppForegrounded()
        OpenPush.Notifications.onAppForegrounded()

        waitForMainQueue()
        XCTAssertEqual(observed.all(), [true])
    }

    func testSubscriptionObserverReportsOptOutAndOptIn() {
        let box = SeamBox(.init(status: .granted, badge: true, sound: true,
                                alert: true, timeSensitive: true))
        initialize(box)
        OpenPush.register(token: "aabb")
        let observed = Values<OpenPush.PushSubscriptionState>()
        _ = OpenPush.PushSubscription.addObserver { observed.add($0) }

        OpenPush.PushSubscription.optOut()
        OpenPush.PushSubscription.optIn()

        waitForMainQueue()
        XCTAssertEqual(observed.all().map(\.status), [-2, 263])
        XCTAssertEqual(observed.all().map(\.optedIn), [false, true])
    }

    func testChangeObserverReportsPreviousAndCurrent() {
        let box = SeamBox(.init(status: .granted, badge: true, sound: true,
                                alert: true, timeSensitive: true))
        initialize(box)
        OpenPush.register(token: "aabb")
        let observed = Values<OpenPush.PushSubscriptionChange>()
        let id = OpenPush.PushSubscription.addChangeObserver { observed.add($0) }
        defer { OpenPush.PushSubscription.removeChangeObserver(id) }

        OpenPush.PushSubscription.optOut()
        OpenPush.PushSubscription.optIn()

        waitForMainQueue()
        let changes = observed.all()
        XCTAssertEqual(changes.map(\.current.status), [-2, 263])
        XCTAssertEqual(changes.first?.previous?.status, 263,
                       "the first change carries what registration left behind")
        XCTAssertEqual(changes.last?.previous, changes.first?.current,
                       "each change must pick up exactly where the last one left off")
    }

    func testTheFirstChangeTheSDKReportsHasNoPrevious() {
        let observed = Values<OpenPush.PushSubscriptionChange>()
        _ = OpenPush.PushSubscription.addChangeObserver { observed.add($0) }
        let box = SeamBox(.init(status: .granted, badge: true, sound: true, alert: true))
        initialize(box)

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        let changes = observed.all()
        guard let first = changes.first else {
            return XCTFail("attaching before the first report must still see it")
        }
        XCTAssertNil(first.previous, "nothing was reported before this, so there is no previous")
        XCTAssertEqual(changes.last?.current.id, "sub_1")
        for (earlier, later) in zip(changes, changes.dropFirst()) {
            XCTAssertEqual(later.previous, earlier.current, "the chain must not skip a state")
        }
    }

    func testTheTwoObserverListsKeepIndependentIds() {
        let box = SeamBox(.init(status: .granted, badge: true, sound: true, alert: true))
        initialize(box)
        let changes = Values<OpenPush.PushSubscriptionChange>()
        let changeID = OpenPush.PushSubscription.addChangeObserver { changes.add($0) }
        OpenPush.PushSubscription.removeObserver(changeID)

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        XCTAssertEqual(changes.all().count, 1,
                       "an id from the other list must not unregister a change observer")
    }

    func testRemovedObserversStopFiring() {
        let box = SeamBox(.init(status: .denied))
        initialize(box)
        let observed = Values<Bool>()
        let id = OpenPush.Notifications.addPermissionObserver { observed.add($0) }
        OpenPush.Notifications.removePermissionObserver(id)
        box.set(.init(status: .granted, badge: true))
        OpenPush.Notifications.onAppForegrounded()
        waitForMainQueue()
        XCTAssertTrue(observed.all().isEmpty)
    }

    func testSubscriptionObserverFiresWhenRegistrationAssignsTheSubscriptionId() {
        let box = StateBox()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_42","status":7}"#) })
        let id = OpenPush.PushSubscription.addObserver { box.set($0) }
        defer { OpenPush.PushSubscription.removeObserver(id) }

        OpenPush.register(token: "aabb")

        waitForMainQueue()
        XCTAssertEqual(box.get()?.id, "sub_42",
                       "the canonical 'send my id to my backend' moment must be observable")
    }

    func testACarriedOptOutFromTheServerIsAdopted() {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1","status":-2}"#) })
        OpenPush.register(token: "aabb")

        XCTAssertTrue(OpenPush.state.isOptedOut)
        XCTAssertFalse(OpenPush.User.pushSubscription.optedIn,
                       "the server will not send to this device; the SDK must not say otherwise")
    }

    func testAConsoleSetNegativeStatusIsStillOnlyReported() {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1","status":-31}"#) })
        let deviceValue = OpenPush.state.currentNotificationTypes
        OpenPush.register(token: "aabb")

        XCTAssertFalse(OpenPush.state.isOptedOut, "-31 belongs to the console, not to this device")
        XCTAssertEqual(OpenPush.state.currentNotificationTypes, deviceValue,
                       "a console-owned status must not rewrite the device value either")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
