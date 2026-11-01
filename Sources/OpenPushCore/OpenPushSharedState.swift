import Foundation

/// What a Notification Service (or Content) Extension needs to talk to OpenPush,
/// mirrored into the App Group the host configured (D9).
///
/// An extension runs in its own process with its own container: it cannot read the
/// app's `UserDefaults.standard`, and the app's `Info.plist` keys are not its own.
/// Without this mirror every host has to hand-plumb the app id, server URL and SDK
/// key into the extension target by hand, and the APNs token and subscription id
/// are simply unavailable there.
///
/// Only non-secret values are mirrored. The device credential is deliberately
/// absent: it authenticates this install and an App Group is readable by every
/// extension the host ships, so it stays in the app process alone.
public struct OpenPushSharedState: Sendable, Equatable {
    public let appID: String
    public let serverURL: String
    public let sdkKey: String
    public let token: String?
    public let subscriptionID: String?
    /// The wrapper SDK this install is built on, as `"<name>/<version>"`, when
    /// there is one. An extension cannot read `OpenPush.wrapper` — that lives in
    /// the app's process — so the identity travels through the mirror.
    public let sdkWrapper: String?
    /// The group these values were read from, carried so `configuration` can hand
    /// the extension something that still knows where to look.
    public let appGroup: String?

    public init(appID: String, serverURL: String, sdkKey: String,
                token: String? = nil, subscriptionID: String? = nil,
                sdkWrapper: String? = nil,
                appGroup: String? = nil) {
        self.appID = appID
        self.serverURL = serverURL
        self.sdkKey = sdkKey
        self.token = token
        self.subscriptionID = subscriptionID
        self.sdkWrapper = sdkWrapper
        self.appGroup = appGroup
    }

    /// Every key is namespaced: the App Group belongs to the host, and the SDK is
    /// a guest in it.
    public static let keyPrefix = "openpush.shared."

    private enum Key: String, CaseIterable {
        case appID = "appId"
        case serverURL = "serverURL"
        case sdkKey = "sdkKey"
        case token = "token"
        case subscriptionID = "subscriptionId"
        /// Optional: a group written without it loads exactly as it did before,
        /// with no wrapper.
        case sdkWrapper = "sdkWrapper"

        var storageKey: String { OpenPushSharedState.keyPrefix + rawValue }
    }

    public static func save(_ value: OpenPushSharedState, appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(value.appID, forKey: Key.appID.storageKey)
        defaults.set(value.serverURL, forKey: Key.serverURL.storageKey)
        defaults.set(value.sdkKey, forKey: Key.sdkKey.storageKey)
        write(value.token, forKey: Key.token.storageKey, into: defaults)
        write(value.subscriptionID, forKey: Key.subscriptionID.storageKey, into: defaults)
        write(value.sdkWrapper, forKey: Key.sdkWrapper.storageKey, into: defaults)
    }

    /// nil when the group holds no mirror yet — an extension that runs before the
    /// app ever initialized OpenPush must be able to tell, rather than reading a
    /// half-written configuration.
    public static func load(appGroup: String) -> OpenPushSharedState? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let appID = nonEmpty(defaults.string(forKey: Key.appID.storageKey)),
              let serverURL = nonEmpty(defaults.string(forKey: Key.serverURL.storageKey)),
              let sdkKey = nonEmpty(defaults.string(forKey: Key.sdkKey.storageKey)) else {
            return nil
        }
        return OpenPushSharedState(
            appID: appID,
            serverURL: serverURL,
            sdkKey: sdkKey,
            token: nonEmpty(defaults.string(forKey: Key.token.storageKey)),
            subscriptionID: nonEmpty(defaults.string(forKey: Key.subscriptionID.storageKey)),
            sdkWrapper: nonEmpty(defaults.string(forKey: Key.sdkWrapper.storageKey)),
            appGroup: appGroup)
    }

    /// Removes the SDK's own keys and nothing else: `removePersistentDomain` here
    /// would take the host's values with it.
    public static func clear(appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        for key in Key.allCases { defaults.removeObject(forKey: key.storageKey) }
    }

    /// A configuration an extension can send receipts with. The token key is the
    /// default one: the extension never persists a token, it reads the mirrored one.
    public var configuration: OpenPushConfiguration {
        OpenPushConfiguration(appID: appID, sdkKey: sdkKey, serverURL: serverURL,
                              appGroup: appGroup)
    }

    private static func write(_ value: String?, forKey key: String,
                              into defaults: UserDefaults) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Stored badge count

/// The app icon's badge count as OpenPush last set it, kept in the same App Group
/// as the mirror above so the app and its Notification Service Extension share it.
///
/// iOS has no API that reads the icon's current badge from an extension, so an
/// incremental badge (`op_badge_increment`) needs a count of its own: the extension
/// adds to this value, shows the sum and stores it back, and the app resets it
/// whenever it sets the badge itself.
///
/// The count lives under its own key, outside the mirror: the app rewrites the
/// mirror whenever its token or subscription changes, and must never overwrite a
/// count the extension raised in the meantime. `clear(appGroup:)` leaves it alone
/// for the same reason — the badge belongs to the app icon, not to a workspace.
public extension OpenPushSharedState {
    /// The `UserDefaults` key the stored badge count lives under.
    static let badgeCountKey = keyPrefix + "badgeCount"

    /// Increments within one process are serialised here. The app and the
    /// extension are separate processes, so a reset racing an increment can still
    /// interleave; the window is a single read and write.
    private static let badgeLock = NSLock()

    /// The stored badge count, `0` when none was ever stored. nil when the App
    /// Group cannot be opened.
    static func badgeCount(appGroup: String) -> Int? {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        return max(0, defaults.integer(forKey: badgeCountKey))
    }

    /// Stores `count` (clamped to zero or more) as the badge count. Returns false
    /// when the App Group cannot be opened.
    @discardableResult
    static func setBadgeCount(_ count: Int, appGroup: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return false }
        badgeLock.lock(); defer { badgeLock.unlock() }
        defaults.set(max(0, count), forKey: badgeCountKey)
        return true
    }

    /// Adds `increment` to the stored count, stores the sum and returns it. nil
    /// when the App Group cannot be opened. The sum never goes below zero.
    static func incrementBadgeCount(by increment: Int, appGroup: String) -> Int? {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        badgeLock.lock(); defer { badgeLock.unlock() }
        let current = max(0, defaults.integer(forKey: badgeCountKey))
        let (sum, overflow) = current.addingReportingOverflow(increment)
        let next = overflow ? Int.max : max(0, sum)
        defaults.set(next, forKey: badgeCountKey)
        return next
    }
}
