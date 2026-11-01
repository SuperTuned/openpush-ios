import XCTest
@testable import OpenPush
import OpenPushCore
import OpenPushOneSignal

/// The compatibility facade forwards to OpenPush, so its observers and
/// completions reach the host on the main thread too — what a migrating app
/// already expects. Driven from a transport and a permission seam that answer
/// off the main thread.
final class OpenPushOneSignalMainThreadTests: OpenPushTestCase {
    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(label: String, onMain: Bool)] = []
        private let expectation: XCTestExpectation

        init(_ expectation: XCTestExpectation) { self.expectation = expectation }

        func record(_ label: String) {
            let onMain = Thread.isMainThread
            lock.lock()
            entries.append((label, onMain))
            let due = entries.count <= expectation.expectedFulfillmentCount
            lock.unlock()
            if due { expectation.fulfill() }
        }
        func labels() -> [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.label) }
        func offMain() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { !$0.onMain }.map(\.label)
        }
    }

    func testFacadeObserversAndCompletionsRunOnMain() {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                DispatchQueue.global().async { done(200, #"{"id":"sub_1"}"#) }
                            })
        OpenPush.storeToken("aabb")
        waitForMainQueue()
        let granted = OpenPush.AuthorizationSnapshot(status: .granted, badge: true,
                                                     sound: true, alert: true)
        OpenPush.permissionSeam = OpenPush.PermissionSeam(
            status: { done in DispatchQueue.global().async { done(.notDetermined) } },
            request: { _, done in DispatchQueue.global().async { done(true) } },
            openSettings: {},
            registerForRemoteNotifications: {},
            settings: { done in DispatchQueue.global().async { done(granted) } })
        let done = expectation(description: "observer, login and permission")
        done.expectedFulfillmentCount = 3
        let heard = Deliveries(done)
        let id = OneSignal.User.pushSubscription.addObserver { _ in heard.record("observer") }
        defer { OneSignal.User.pushSubscription.removeObserver(id) }

        OneSignal.login(externalId: "person-2") { _ in heard.record("login") }
        OneSignal.Notifications.requestPermission({ _ in heard.record("permission") })

        wait(for: [done], timeout: 2)
        XCTAssertEqual(Set(heard.labels()), ["observer", "login", "permission"])
        XCTAssertEqual(heard.offMain(), [])
    }
}
