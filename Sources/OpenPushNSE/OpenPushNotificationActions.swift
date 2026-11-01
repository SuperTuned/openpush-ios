import OpenPushCore
@preconcurrency import UserNotifications

/// Applies dashboard-configured action buttons inside a Notification Service
/// Extension. The server category identifies the exact labels and action IDs.
@available(macOS 10.14, *)
public enum OpenPushNotificationActions {
    static let categoryLimit = 32
    private static let ledgerKey = "io.openpush.nse.action-category-recency"

    /// The notification-center seam. Registration is asynchronous — the categories
    /// have to be read before they can be written back — so an extension that
    /// delivers its content too early shows a notification whose buttons are not
    /// registered yet. The seam exists so that sequence can be tested at all.
    public struct CategoryStore: Sendable {
        public var read: @Sendable (@escaping @Sendable (Set<UNNotificationCategory>) -> Void) -> Void
        public var write: @Sendable (Set<UNNotificationCategory>) -> Void

        public init(read: @escaping @Sendable (@escaping @Sendable (Set<UNNotificationCategory>) -> Void) -> Void,
                    write: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {
            self.read = read
            self.write = write
        }

        /// The real notification center.
        public static let system = CategoryStore(
            read: { completion in
                UNUserNotificationCenter.current().getNotificationCategories(completionHandler: completion)
            },
            write: { categories in
                UNUserNotificationCenter.current().setNotificationCategories(categories)
            })
    }

    /// The recency order, in whichever defaults suite the caller named.
    ///
    /// `UserDefaults` is thread-safe but not `Sendable`, and the order is read and
    /// written inside the store's `@Sendable` callback; the box says so once here
    /// rather than leaving a concurrency warning at the call site.
    private struct Ledger: @unchecked Sendable {
        let defaults: UserDefaults

        func order() -> [String] { defaults.stringArray(forKey: ledgerKey) ?? [] }
        func store(_ order: [String]) { defaults.set(order, forKey: ledgerKey) }
    }

    static func pruned(_ existing: Set<UNNotificationCategory>,
                       adding category: UNNotificationCategory,
                       recency: [String]) -> (Set<UNNotificationCategory>, [String]) {
        let host = existing.filter { !$0.identifier.hasPrefix("op_") }
        var owned = Dictionary(uniqueKeysWithValues: existing
            .filter { $0.identifier.hasPrefix("op_") && $0.identifier != category.identifier }
            .map { ($0.identifier, $0) })
        owned[category.identifier] = category
        var order = recency.filter { owned[$0] != nil && $0 != category.identifier }
        let untracked = owned.keys.filter { !order.contains($0) && $0 != category.identifier }.sorted()
        order = untracked + order + [category.identifier]
        if order.count > categoryLimit { order.removeFirst(order.count - categoryLimit) }
        return (Set(host).union(order.compactMap { owned[$0] }), order)
    }

    /// The buttons one payload asks for, icons included where the platform has them.
    static func notificationActions(for actions: [OpenPushPayload.Action]) -> [UNNotificationAction] {
        actions.map { action in
            if #available(iOS 15.0, macOS 12.0, *), !action.icon.isEmpty {
                let icon = action.systemIcon
                    ? UNNotificationActionIcon(systemImageName: action.icon)
                    : UNNotificationActionIcon(templateImageName: action.icon)
                return UNNotificationAction(identifier: action.id, title: action.label,
                                            options: [.foreground], icon: icon)
            }
            return UNNotificationAction(identifier: action.id, title: action.label,
                                        options: [.foreground])
        }
    }

    /// Registers this payload's category and sets it on `content`, then completes.
    ///
    /// `completion` runs after the write, so a service extension can hold its
    /// content back until the buttons it is about to show actually exist. It is
    /// given the number of actions registered — `0` on every path that registers
    /// nothing — so a caller reports what happened rather than what was asked for.
    /// It runs on whatever thread the store answered on, and exactly once on every
    /// path — including the paths that register nothing at all:
    ///
    /// - a `categoryIdentifier` the host set itself (non-empty and not `op_`-prefixed)
    ///   is left alone; the host owns its own categories and a push must not
    ///   silently replace one.
    /// - a payload with no actions, or with no category to register them under,
    ///   completes without touching the store.
    ///
    /// `ledger` holds the recency order that bounds how many of our categories
    /// survive. It defaults to `UserDefaults.standard`, which inside an extension
    /// is that extension's own container; a host with an App Group should pass the
    /// group's suite so the order is shared with the app.
    public static func apply(from userInfo: [AnyHashable: Any],
                             to content: UNMutableNotificationContent,
                             categories: CategoryStore = .system,
                             ledger: UserDefaults = .standard,
                             completion: @escaping @Sendable (Int) -> Void) {
        guard content.categoryIdentifier.isEmpty
                || content.categoryIdentifier.hasPrefix("op_") else {
            completion(0)
            return
        }
        let actions = OpenPushPayload.actions(from: userInfo)
        guard !actions.isEmpty,
              let identifier = OpenPushPayload.actionCategory(from: userInfo),
              !identifier.isEmpty else {
            completion(0)
            return
        }

        content.categoryIdentifier = identifier
        let category = UNNotificationCategory(identifier: identifier,
                                              actions: notificationActions(for: actions),
                                              intentIdentifiers: [], options: [])
        let recency = Ledger(defaults: ledger)
        categories.read { existing in
            let (updated, order) = pruned(existing, adding: category, recency: recency.order())
            recency.store(order)
            categories.write(updated)
            completion(actions.count)
        }
    }

    /// The fire-and-forget form, kept for hosts that drive their own extension and
    /// do not need to know when registration finished.
    public static func apply(from userInfo: [AnyHashable: Any],
                             to content: UNMutableNotificationContent) {
        apply(from: userInfo, to: content, completion: { _ in })
    }
}
