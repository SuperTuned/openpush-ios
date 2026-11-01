import XCTest
import UserNotifications
@testable import OpenPushNSE

final class OpenPushNotificationActionsTests: XCTestCase {
    private func category(_ id: String) -> UNNotificationCategory {
        UNNotificationCategory(identifier: id, actions: [], intentIdentifiers: [])
    }

    func testOpenPushCategoriesAreBoundedAndOldestIsEvicted() {
        let host = category("host.marketing")
        let owned = (0..<(OpenPushNotificationActions.categoryLimit + 5)).map {
            category("op_actions_\($0)")
        }
        let existing = Set([host] + owned)
        let newest = category("op_actions_new")
        let result = OpenPushNotificationActions.pruned(
            existing, adding: newest, recency: owned.map(\.identifier))
        XCTAssertEqual(result.0.filter { $0.identifier.hasPrefix("op_") }.count,
                       OpenPushNotificationActions.categoryLimit)
        XCTAssertTrue(result.0.contains { $0.identifier == host.identifier })
        XCTAssertFalse(result.0.contains { $0.identifier == owned[0].identifier })
        XCTAssertTrue(result.0.contains { $0.identifier == newest.identifier })
    }

    func testSameRenderedLabelSetReusesOneCategory() {
        let same = category("op_actions_same")
        let result = OpenPushNotificationActions.pruned(
            Set([same]), adding: same, recency: [same.identifier])
        XCTAssertEqual(result.0.filter { $0.identifier == same.identifier }.count, 1)
        XCTAssertEqual(result.1, [same.identifier])
    }
}

// MARK: - Completion-based registration (D8)

extension OpenPushNotificationActionsTests {
    /// Records the order the seam is driven in, so "the completion fires after the
    /// write" is asserted as a sequence rather than as a count.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []
        private var written: Set<UNNotificationCategory> = []

        private var registered: Int?

        func add(_ step: String) { lock.lock(); defer { lock.unlock() }; steps.append(step) }
        func complete(_ count: Int) {
            lock.lock(); registered = count; lock.unlock()
            add("completion")
        }
        func registeredCount() -> Int? { lock.lock(); defer { lock.unlock() }; return registered }
        func order() -> [String] { lock.lock(); defer { lock.unlock() }; return steps }
        func store(_ categories: Set<UNNotificationCategory>) {
            lock.lock(); defer { lock.unlock() }; written = categories
        }
        func categories() -> Set<UNNotificationCategory> {
            lock.lock(); defer { lock.unlock() }; return written
        }
    }

    private func store(_ recorder: Recorder) -> OpenPushNotificationActions.CategoryStore {
        OpenPushNotificationActions.CategoryStore(
            read: { completion in recorder.add("read"); completion([]) },
            write: { categories in recorder.add("write"); recorder.store(categories) })
    }

    private func ledger() -> UserDefaults {
        UserDefaults(suiteName: "io.openpush.tests.actions.\(UUID().uuidString)")!
    }

    private func payload(icons: Bool = false) -> [AnyHashable: Any] {
        [
            "op_message_id": "m-1",
            "op_action_category": "op_actions_abc",
            "op_actions": [
                ["id": "yes", "label": "Yes",
                 "icon": icons ? "hand.thumbsup" : "", "system_icon": icons],
                ["id": "no", "label": "No",
                 "icon": icons ? "action-decline" : "", "system_icon": false],
            ],
        ]
    }

    func testApplyCompletesAfterTheCategoryIsWritten() {
        let recorder = Recorder()
        let content = UNMutableNotificationContent()
        OpenPushNotificationActions.apply(from: payload(), to: content,
                                          categories: store(recorder), ledger: ledger()) {
            recorder.complete($0)
        }

        XCTAssertEqual(recorder.order(), ["read", "write", "completion"])
        XCTAssertEqual(recorder.registeredCount(), 2,
                       "the completion carries how many actions were registered")
        XCTAssertEqual(content.categoryIdentifier, "op_actions_abc")
        XCTAssertTrue(recorder.categories().contains { $0.identifier == "op_actions_abc" })
    }

    func testAHostSetCategoryIsPreserved() {
        let recorder = Recorder()
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "host.marketing"
        OpenPushNotificationActions.apply(from: payload(), to: content,
                                          categories: store(recorder), ledger: ledger()) {
            recorder.complete($0)
        }

        XCTAssertEqual(recorder.registeredCount(), 0,
                       "nothing was registered, and the count says so")
        XCTAssertEqual(content.categoryIdentifier, "host.marketing",
                       "a category the host set itself is the host's to keep")
        XCTAssertEqual(recorder.order(), ["completion"],
                       "nothing is read or written when the host owns the category")
    }

    func testIconsAreAttachedToActions() {
        let recorder = Recorder()
        let content = UNMutableNotificationContent()
        OpenPushNotificationActions.apply(from: payload(icons: true), to: content,
                                          categories: store(recorder), ledger: ledger()) { _ in }

        let category = recorder.categories().first { $0.identifier == "op_actions_abc" }
        XCTAssertNotNil(category)
        XCTAssertEqual(category?.actions.count, 2)
        #if canImport(UIKit)
        XCTAssertNotNil(category?.actions.first?.icon, "a system icon reaches the action")
        XCTAssertNotNil(category?.actions.last?.icon, "a template icon reaches the action")
        #endif
    }

    func testAnActionWithoutAnIconStillRegisters() {
        let recorder = Recorder()
        let content = UNMutableNotificationContent()
        OpenPushNotificationActions.apply(from: payload(), to: content,
                                          categories: store(recorder), ledger: ledger()) { _ in }

        let category = recorder.categories().first { $0.identifier == "op_actions_abc" }
        XCTAssertEqual(category?.actions.map(\.identifier), ["yes", "no"])
    }

    func testAPayloadWithoutActionsCompletesWithoutTouchingTheStore() {
        let recorder = Recorder()
        let content = UNMutableNotificationContent()
        OpenPushNotificationActions.apply(from: ["op_message_id": "m-2"], to: content,
                                          categories: store(recorder), ledger: ledger()) {
            recorder.complete($0)
        }

        XCTAssertEqual(recorder.order(), ["completion"])
        XCTAssertEqual(recorder.registeredCount(), 0)
        XCTAssertEqual(content.categoryIdentifier, "")
    }
}
