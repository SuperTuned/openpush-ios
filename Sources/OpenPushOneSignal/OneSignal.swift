import Foundation
import UserNotifications
import OpenPush
import OpenPushCore
#if canImport(UIKit)
import UIKit
#endif

/// Drop-in OneSignal v5 name alias for OpenPush. Import `OpenPushOneSignal`
/// instead of `OneSignalFramework` and existing call sites keep compiling — with
/// one exception: v5's protocol-based listeners and observers
/// (`addClickListener`, `addForegroundLifecycleListener`, `addPermissionObserver`,
/// `pushSubscription.addObserver`) take a closure here rather than a conforming
/// object, so those call sites are a type error until you rewrite them as
/// closures.
///
/// Names only — no state, no OneSignal implementation code. The one behaviour it
/// adds is an opt-out for launch URLs: OpenPush opens a tapped
/// notification's launch URL itself by default, and
/// `initialize` turns that off when the app's Info.plist sets
/// `OneSignal_suppress_launch_urls` to true. Do not link this module and the real
/// OneSignal SDK into one target: both define `OneSignal`.
public enum OneSignal {

    // MARK: - Launch URLs

    /// Info.plist key for leaving launch URLs to the app.
    public static let suppressLaunchURLsInfoKey = "OneSignal_suppress_launch_urls"

    /// Whether the app's Info.plist asks for launch URLs to be left alone. A Bool,
    /// or a string or number that reads as one (`YES`, `true`, `1`).
    static func launchURLsSuppressed(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) -> Bool {
        switch lookup(suppressLaunchURLsInfoKey) {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return (text as NSString).boolValue
        default: return false
        }
    }

    /// Every `initialize` overload applies the Info.plist opt-out before configuring
    /// OpenPush: with the key set, launch URLs are left to the app. Without it the
    /// setting is left as it is — on by default, or whatever the app set.
    /// Setting `OpenPush.Notifications.openLaunchURLs` after `initialize` still
    /// overrides it.
    static func applyLaunchURLDefault(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) {
        if launchURLsSuppressed(lookup: lookup) {
            OpenPush.Notifications.openLaunchURLs = false
        }
    }

    // MARK: - Setup

    /// Keeps the v5 call signature. The SDK key comes from `Info.plist`
    /// (`OpenPushSDKKey`), so an existing OneSignal call site compiles unchanged.
    ///
    /// `launchOptions` is accepted and unused: OpenPush never swizzles, so there
    /// is no delegate to install from it. To handle a cold start from a notification
    /// tap, forward `processClick(_:)` from
    /// `UNUserNotificationCenterDelegate`. The core overload says so
    /// in a log line rather than leaving it to be discovered; this facade only
    /// forwards, so that line lives in exactly one place.
    public static func initialize(
        _ appId: String,
        withLaunchOptions launchOptions: [AnyHashable: Any]? = nil
    ) {
        applyLaunchURLDefault()
        OpenPush.initialize(appId, withLaunchOptions: launchOptions)
    }

    public static func initialize(
        appId: String,
        sdkKey: String,
        serverURL: String = OpenPush.defaultServerURL,
        credential: @escaping @Sendable () -> String? = { nil },
        provisional: Bool = false,
        transport: @escaping OpenPush.Transport = OpenPush.urlSessionTransport
    ) {
        applyLaunchURLDefault()
        OpenPush.initialize(appId: appId, sdkKey: sdkKey, serverURL: serverURL,
                            credential: credential, provisional: provisional,
                            transport: transport)
    }

    /// The app-id-only form with OpenPush's own extras, for hosts that want the
    /// short call plus a custom transport or credential.
    public static func initialize(
        appId: String,
        serverURL: String = OpenPush.defaultServerURL,
        credential: @escaping @Sendable () -> String? = { nil },
        provisional: Bool = false,
        transport: @escaping OpenPush.Transport = OpenPush.urlSessionTransport
    ) {
        applyLaunchURLDefault()
        OpenPush.initialize(appId: appId, serverURL: serverURL, credential: credential,
                            provisional: provisional, transport: transport)
    }

    // MARK: - Identity

    /// OneSignal v5's positional form, so `OneSignal.login("player-9")` compiles
    /// unchanged.
    public static func login(_ externalId: String) {
        OpenPush.login(externalId: externalId)
    }

    public static func login(externalId: String, authHash: String? = nil,
                             completion: (@Sendable (OpenPush.IdentityResult) -> Void)? = nil) {
        OpenPush.login(externalId: externalId, authHash: authHash, completion: completion)
    }

    /// Current v5 spelling for an identity-verification token.
    public static func login(externalId: String, token: String?) {
        OpenPush.login(externalId: externalId, authHash: token)
    }

    public static func logout(
        completion: (@Sendable (OpenPush.IdentityResult) -> Void)? = nil
    ) {
        OpenPush.logout(completion: completion)
    }

    // MARK: - APNs forwarding (host-owned; OpenPush never swizzles)

    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        OpenPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    public static func didFailToRegisterForRemoteNotifications(error: Error) {
        OpenPush.didFailToRegisterForRemoteNotifications(error: error)
    }

    // MARK: - User

    public enum User {
        public static func addTag(key: String, value: String) {
            OpenPush.User.addTag(key: key, value: value)
        }
        public static func addTags(_ tags: [String: String]) { OpenPush.User.addTags(tags) }
        public static func removeTag(_ key: String) { OpenPush.User.removeTag(key) }
        public static func removeTags(_ keys: [String]) { OpenPush.User.removeTags(keys) }
        public static func getTags() -> [String: String] { OpenPush.User.getTags() }
        public static func addAlias(label: String, id: String) {
            OpenPush.User.addAlias(label: label, id: id)
        }
        public static func addAliases(_ aliases: [String: String]) {
            OpenPush.User.addAliases(aliases)
        }
        public static func removeAlias(_ label: String) { OpenPush.User.removeAlias(label) }
        public static func removeAliases(_ labels: [String]) {
            OpenPush.User.removeAliases(labels)
        }
        public static var externalId: String? { OpenPush.User.externalId }
        /// The number is added unverified: it receives nothing until a code sent
        /// with `OpenPush.Verify` is approved. A number that is not E.164 is
        /// refused with a log line and nothing is sent. v5's signature returns
        /// nothing, so OpenPush's `Bool` is discarded here.
        public static func addSms(_ number: String) { OpenPush.User.addSms(number) }
        public static func removeSms(_ number: String) { OpenPush.User.removeSms(number) }
        /// The address is subscribed at once, unless this app's suppression list
        /// has it. An address that is not valid is refused with a log line and
        /// nothing is sent. `removeEmail` removes the subscription; it is not an
        /// unsubscribe. OpenPush's `Bool` is discarded, as for `addSms`.
        public static func addEmail(_ email: String) { OpenPush.User.addEmail(email) }
        public static func removeEmail(_ email: String) { OpenPush.User.removeEmail(email) }
        public static func trackEvent(name: String, properties: [String: Any]? = nil) {
            OpenPush.trackEvent(name, properties: properties ?? [:])
        }
        /// A property, exactly as in v5 — a live view computed on read.
        public static var pushSubscription: OneSignal.PushSubscription {
            OneSignal.PushSubscription()
        }
    }

    // MARK: - Push subscription

    /// v5 puts `addObserver` on the instance while OpenPush declares it
    /// statically; this wrapper only presents the instance shape.
    public struct PushSubscription: Sendable {
        init() {}
        public var id: String? { OpenPush.User.pushSubscription.id }
        public var token: String? { OpenPush.User.pushSubscription.token }
        public var optedIn: Bool { OpenPush.User.pushSubscription.optedIn }
        /// OpenPush addition: this install's `notification_types`.
        public var status: Int? { OpenPush.User.pushSubscription.status }
        public func optIn() { OpenPush.User.pushSubscription.optIn() }
        public func optOut() { OpenPush.User.pushSubscription.optOut() }
        /// Returns a `UUID` handle instead of taking an `OSPushSubscriptionObserver`.
        public func addObserver(
            _ observer: @escaping @Sendable (OpenPush.PushSubscriptionState) -> Void
        ) -> UUID { OpenPush.PushSubscription.addObserver(observer) }
        public func removeObserver(_ id: UUID) { OpenPush.PushSubscription.removeObserver(id) }
        public func snapshot() -> OpenPush.PushSubscriptionState {
            OpenPush.User.pushSubscription.snapshot()
        }
    }

    // MARK: - Notifications

    public enum Notifications {
        public static var permission: Bool { OpenPush.Notifications.permission }

        public static var canRequestPermission: Bool {
            OpenPush.Notifications.canRequestPermission
        }

        /// v5 reports a raw `UNAuthorizationStatus`; this reports OpenPush's own
        /// enum, so `.provisional` and `.ephemeral` stay legible instead of being
        /// integers the call site has to decode.
        public static var permissionNative: OpenPush.PermissionStatus {
            OpenPush.Notifications.permissionStatus
        }

        public static func requestProvisionalPermission(
            completion: (@Sendable (Bool) -> Void)? = nil
        ) {
            OpenPush.Notifications.requestProvisionalPermission(completion: completion)
        }

        /// Current v5 spelling for provisional authorization.
        public static func registerForProvisionalAuthorization(
            _ block: (@Sendable (Bool) -> Void)? = nil
        ) {
            OpenPush.Notifications.requestProvisionalPermission(completion: block)
        }

        /// v5's argument order: the response block first.
        public static func requestPermission(
            _ block: (@Sendable (Bool) -> Void)? = nil,
            fallbackToSettings: Bool = false
        ) {
            OpenPush.Notifications.requestPermission(fallbackToSettings: fallbackToSettings,
                                                     completion: block)
        }

        public static func addClickListener(
            _ listener: @escaping @Sendable (OpenPush.ClickEvent) -> Void
        ) -> UUID { OpenPush.Notifications.addClickListener(listener) }
        public static func removeClickListener(_ id: UUID) {
            OpenPush.Notifications.removeClickListener(id)
        }

        public static func addForegroundLifecycleListener(
            _ listener: @escaping @Sendable (OpenPush.ForegroundEvent) -> Void
        ) -> UUID { OpenPush.Notifications.addForegroundLifecycleListener(listener) }
        public static func removeForegroundLifecycleListener(_ id: UUID) {
            OpenPush.Notifications.removeForegroundLifecycleListener(id)
        }

        public static func addPermissionObserver(
            _ observer: @escaping @Sendable (Bool) -> Void
        ) -> UUID { OpenPush.Notifications.addPermissionObserver(observer) }
        public static func removePermissionObserver(_ id: UUID) {
            OpenPush.Notifications.removePermissionObserver(id)
        }

        public static func clearAll() { OpenPush.Notifications.clearAll() }
        public static func setBadgeCount(_ count: Int) {
            OpenPush.Notifications.setBadgeCount(count)
        }

        // Current manual-integration entry points. OpenPush is always manually
        // integrated, so these forward directly.
        public static func didRegisterForRemoteNotifications(deviceToken: Data) {
            OpenPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }

        public static func didFailToRegisterForRemoteNotifications(error: Error) {
            OpenPush.didFailToRegisterForRemoteNotifications(error: error)
        }

        #if canImport(UIKit)
        public static func didReceiveRemoteNotification(
            userInfo: [AnyHashable: Any],
            completionHandler: @escaping @Sendable (UIBackgroundFetchResult) -> Void
        ) {
            _ = OpenPush.didReceiveRemoteNotification(userInfo: userInfo)
            completionHandler(.newData)
        }
        #endif

        public static func willPresentNotification(
            payload: [AnyHashable: Any],
            completion: @escaping @Sendable (OpenPush.Notification?) -> Void
        ) {
            let notification = OpenPush.Notification(userInfo: payload)
            OpenPush.Notifications.processForeground(userInfo: payload) { options in
                completion(options.isEmpty ? nil : notification)
            }
        }

        public static func didReceiveNotificationResponse(
            _ response: UNNotificationResponse
        ) {
            OpenPush.Notifications.processClick(response)
        }

        // OpenPush additions: OpenPush never swizzles, so the app forwards these.
        public static func processForeground(
            _ notification: UNNotification
        ) -> UNNotificationPresentationOptions {
            OpenPush.Notifications.processForeground(notification)
        }
        public static func processClick(_ response: UNNotificationResponse) {
            OpenPush.Notifications.processClick(response)
        }
        public static func onAppForegrounded() { OpenPush.Notifications.onAppForegrounded() }
    }

    // MARK: - Live Activities

    public enum LiveActivities {
        public static func enter(_ activityId: String, withToken token: String,
                                 completion: (@Sendable (Bool) -> Void)? = nil) {
            OpenPush.LiveActivities.enter(activityId, withToken: token, completion: completion)
        }
        public static func exit(_ activityId: String,
                                completion: (@Sendable (Bool) -> Void)? = nil) {
            OpenPush.LiveActivities.exit(activityId, completion: completion)
        }
        @available(iOS 17.2, *)
        public static func setPushToStartToken(_ activityType: String,
                                               withToken token: String) throws {
            try OpenPush.LiveActivities.setPushToStartToken(activityType, withToken: token)
        }
        @available(iOS 17.2, *)
        public static func removePushToStartToken(_ activityType: String) throws {
            try OpenPush.LiveActivities.removePushToStartToken(activityType)
        }
        @discardableResult
        public static func trackClickAndReturnOriginal(_ url: URL) -> URL? {
            OpenPush.LiveActivities.trackClickAndReturnOriginal(url)
        }
        @available(*, deprecated, renamed: "enter(_:withToken:)")
        public static func enter(_ activityId: String, withToken token: String,
                                 activityType: String,
                                 completion: (@Sendable (Bool) -> Void)? = nil) {
            OpenPush.LiveActivities.enter(activityId, withToken: token,
                                          activityType: activityType, completion: completion)
        }
        @available(*, deprecated, renamed: "setPushToStartToken(_:withToken:)")
        public static func setPushToStartToken(
            activityType: String, token: String,
            completion: (@Sendable (Bool) -> Void)? = nil
        ) {
            OpenPush.LiveActivities.setPushToStartToken(activityType: activityType,
                                                        token: token, completion: completion)
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public extension OneSignal.LiveActivities {
    static func setup<T: OneSignalLiveActivityAttributes>(
        _ activityType: T.Type, options: OpenPushLiveActivitySetupOptions? = nil
    ) where T: Sendable {
        OpenPush.LiveActivities.setup(
            activityType,
            activityType: OpenPush.LiveActivities.derivedActivityType(activityType),
            options: options, topicKey: { $0.onesignal.activityId },
            notificationId: { $0.onesignal?.notificationId })
    }
    static func setupDefault(options: OpenPushLiveActivitySetupOptions? = nil) {
        OpenPush.LiveActivities.setupDefault(options: options)
    }
    static func startDefault(_ activityId: String, attributes: [String: Any],
                             content: [String: Any]) {
        OpenPush.LiveActivities.startDefault(activityId, attributes: attributes,
                                             content: content)
    }
}

@available(iOS 17.2, *)
public extension OneSignal.LiveActivities {
    static func setPushToStartToken<T: ActivityAttributes>(_ activityType: T.Type,
                                                           withToken token: String) {
        OpenPush.LiveActivities.setPushToStartToken(activityType, withToken: token)
    }
    static func removePushToStartToken<T: ActivityAttributes>(_ activityType: T.Type) {
        OpenPush.LiveActivities.removePushToStartToken(activityType)
    }
}
#endif
