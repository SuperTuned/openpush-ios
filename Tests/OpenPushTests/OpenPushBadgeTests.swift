import XCTest
@testable import OpenPush
import OpenPushCore
import OpenPushOneSignal

/// The app's side of the incremental badge: whatever the app sets is the count
/// the extension's next `op_badge_increment` adds to.
final class OpenPushBadgeTests: OpenPushTestCase {
    private var group = ""

    override func setUp() {
        super.setUp()
        group = "openpush.tests.badge.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: group)?.removePersistentDomain(forName: group)
        super.tearDown()
    }

    private func initialize(appGroup: String?) {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            appGroup: appGroup,
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
    }

    func testSetBadgeCountAlsoStoresTheCountInTheAppGroup() {
        initialize(appGroup: group)
        _ = OpenPushSharedState.incrementBadgeCount(by: 5, appGroup: group)

        OpenPush.Notifications.setBadgeCount(0)

        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: group), 0,
                       "a reset to 0 is where the extension's next increment counts from")
        XCTAssertEqual(OpenPush.Notifications.badgeCount, 0)

        OpenPush.Notifications.setBadgeCount(12)
        XCTAssertEqual(OpenPush.Notifications.badgeCount, 12)
    }

    func testSetBadgeCountStillSetsTheIconBadge() {
        let set = LogBox()
        OpenPush.badgeSetter = { set.add("\($0)") }
        initialize(appGroup: group)

        OpenPush.Notifications.setBadgeCount(3)

        XCTAssertEqual(set.all(), ["3"])
    }

    func testTheStoredCountReflectsWhatTheExtensionRaisedItTo() {
        initialize(appGroup: group)
        OpenPush.Notifications.setBadgeCount(1)
        _ = OpenPushSharedState.incrementBadgeCount(by: 2, appGroup: group)

        XCTAssertEqual(OpenPush.Notifications.badgeCount, 3)
    }

    func testWithoutAnAppGroupThereIsNoStoredCount() {
        let logs = LogBox()
        OpenPush.onLog = { logs.add($0) }
        initialize(appGroup: nil)

        OpenPush.Notifications.setBadgeCount(0)

        XCTAssertNil(OpenPush.Notifications.badgeCount)
        XCTAssertTrue(logs.all().contains { $0.contains("not stored") })
    }

    /// The compatibility facade's spelling lands on the same store.
    func testTheFacadeSpellingStoresTheCountToo() {
        initialize(appGroup: group)
        _ = OpenPushSharedState.incrementBadgeCount(by: 4, appGroup: group)

        OneSignal.Notifications.setBadgeCount(0)

        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: group), 0)
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
