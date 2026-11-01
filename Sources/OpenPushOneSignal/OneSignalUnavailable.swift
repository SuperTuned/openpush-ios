import CryptoKit
import Foundation
import OpenPush

// Every OneSignal v5 symbol OpenPush does not implement is declared here and
// refused by the compiler. A migrating host therefore learns the entire gap from
// one build, with the replacement named at the call site. Nothing in this file
// runs: `unavailable` is a compile-time diagnostic, and the bodies exist only
// because Swift requires them.

public extension OneSignal {

    // NOTE: `initialize(_:withLaunchOptions:)` is NOT refused — Task I0 made it
    // work by moving the SDK key into Info.plist. It is implemented in
    // OneSignal.swift. Do not add a refusal for it here.

    @available(*, unavailable,
               message: "OpenPush has no runtime consent gate. Do not call initialize until the user has consented; to withdraw afterwards call OpenPush.User.pushSubscription.optOut() and OpenPush.logout() — a full stop requires not initializing on the next launch.")
    static var consentRequired: Bool { fatalError("unavailable") }

    @available(*, unavailable,
               message: "OpenPush has no runtime consent gate. Do not call initialize until the user has consented; to withdraw afterwards call OpenPush.User.pushSubscription.optOut() and OpenPush.logout() — a full stop requires not initializing on the next launch.")
    static var consentGiven: Bool { fatalError("unavailable") }

    enum Debug {
        @available(*, unavailable,
                   message: "OpenPush has one diagnostic sink instead of log levels: set OpenPush.onLog to receive bounded messages, and filter them yourself.")
        public static var logLevel: Int { fatalError("unavailable") }

        @available(*, unavailable,
                   message: "OpenPush never shows alerts for diagnostics. Set OpenPush.onLog and surface what you want.")
        public static var alertLevel: Int { fatalError("unavailable") }
    }

    enum InAppMessages {
        public static var paused: Bool {
            get { OpenPush.InAppMessages.paused }
            set { OpenPush.InAppMessages.paused = newValue }
        }

        public static func addTrigger(_ key: String, withValue value: String) {
            OpenPush.InAppMessages.addTrigger(key, withValue: value)
        }
        public static func addTriggers(_ values: [String: String]) {
            OpenPush.InAppMessages.addTriggers(values)
        }
        public static func removeTrigger(_ key: String) {
            OpenPush.InAppMessages.removeTrigger(key)
        }
        public static func removeTriggers(_ keys: [String]) {
            OpenPush.InAppMessages.removeTriggers(keys)
        }
        public static func clearTriggers() { OpenPush.InAppMessages.clearTriggers() }

        /// The v5 protocol-object form — a type conforming to the listener
        /// protocol — is a type error here. Pass a closure and keep the handle,
        /// the same convention as the notification listeners.
        @discardableResult
        public static func addClickListener(
            _ listener: @escaping @Sendable (OpenPush.InAppMessageClickEvent) -> Void
        ) -> UUID { OpenPush.InAppMessages.addClickListener(listener) }
        public static func removeClickListener(_ handle: UUID) {
            OpenPush.InAppMessages.removeClickListener(handle)
        }

        /// The v5 protocol-object form is a type error here. Pass a closure and
        /// keep the handle, the same convention as the notification listeners.
        @discardableResult
        public static func addLifecycleListener(
            _ listener: @escaping @Sendable (OpenPush.InAppMessageLifecycleEvent) -> Void
        ) -> UUID { OpenPush.InAppMessages.addLifecycleListener(listener) }
        public static func removeLifecycleListener(_ handle: UUID) {
            OpenPush.InAppMessages.removeLifecycleListener(handle)
        }
    }

    enum Session {
        /// Every call is its own event, which is what a counted outcome means.
        public static func addOutcome(_ name: String) { OpenPush.trackEvent(name) }

        /// Counted once per device however often it is recorded: the event
        /// carries an idempotency key derived from the name and this
        /// installation, and the server keeps the first one.
        ///
        /// The installation is named by its subscription id. Before the server
        /// has issued one the key falls back to a short digest of the push token
        /// — never the token itself, which is a credential and has no business in
        /// an analytics store — and before there is even a token, to a constant.
        /// So an outcome recorded in one of those windows and one recorded after
        /// it are two events: record unique outcomes after registration.
        public static func addUniqueOutcome(_ name: String) {
            OpenPush.trackEvent(name, idempotencyKey: "unique:\(name):\(uniqueScope())")
        }

        /// What "once per device" is scoped to, in order of preference.
        private static func uniqueScope() -> String {
            if let subscriptionID = OpenPush.User.pushSubscription.id,
               !subscriptionID.isEmpty {
                return subscriptionID
            }
            guard let token = OpenPush.currentToken, !token.isEmpty else { return "device" }
            // Stable for this token and useless to anyone who reads it back: 64
            // bits of SHA-256 is far beyond what a per-device key needs, and the
            // token cannot be recovered from it.
            let digest = SHA256.hash(data: Data(token.utf8))
            return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
        }

        /// The value rides along as a `value` property. To see it summed rather
        /// than counted, define a conversion metric over this event in the
        /// console with `tracking = value` and `value_property = "value"`.
        public static func addOutcomeWithValue(_ name: String, _ value: NSNumber) {
            OpenPush.trackEvent(name, properties: ["value": value])
        }
    }

    enum Location {
        @available(*, unavailable,
                   message: "OpenPush never collects location. Send a tag or alias you compute yourself if you need geo targeting.")
        public static var isShared: Bool { fatalError("unavailable") }

        @available(*, unavailable,
                   message: "OpenPush never collects location.")
        public static func requestPermission() { fatalError("unavailable") }
    }
}

public extension OneSignal.User {

    @available(*, unavailable,
               message: "OpenPush does not yet return the server's user id to the SDK (the server has it; a future release will expose it). Use externalId for the id you set, or pushSubscription.id for this installation.")
    static var onesignalId: String? { fatalError("unavailable") }

    @available(*, unavailable,
               message: "OpenPush sends the device's full language tag (for example zh-Hant-TW) with every registration; the server falls back from a regional tag to its base language when choosing localized copy. To force a different language, set a tag your segments can read.")
    static func setLanguage(_ language: String) { fatalError("unavailable") }

    // NOTE: `addSms(_:)`, `removeSms(_:)`, `addEmail(_:)` and `removeEmail(_:)`
    // are NOT refused — they forward to OpenPush's phone numbers and email
    // addresses and are implemented in OneSignal.swift. Do not add
    // refusals for them here.

    @available(*, unavailable,
               message: "There is no user-state observer. Observe the push subscription instead: OneSignal.User.pushSubscription.addObserver { state in … }.")
    static func addObserver(_ observer: Any) { fatalError("unavailable") }

    @available(*, unavailable,
               message: "There is no user-state observer. Observe the push subscription instead: OneSignal.User.pushSubscription.addObserver { state in … }.")
    static func removeObserver(_ observer: Any) { fatalError("unavailable") }

    @available(*, unavailable,
               message: "OpenPush identity verification is requested through OpenPush.onIdentityVerificationRequired; call login(externalId:authHash:) with the refreshed proof.")
    static func onJwtExpired(
        expiredHandler: @escaping (_ externalId: String,
                                   _ completion: @escaping (String) -> Void) -> Void
    ) { fatalError("unavailable") }
}

public extension OneSignal.Notifications {

    // NOTE: `canRequestPermission` and `permissionNative` are NOT refused — they
    // are implemented in OneSignal.swift. Do not add refusals for them here.

    @available(*, unavailable,
               message: "Use OneSignal.Notifications.clearAll(); the legacy clearAllNotifications spelling is not supported.")
    static func clearAllNotifications() { fatalError("unavailable") }

    @available(*, unavailable,
               message: "OpenPush does not manage the notification centre. Call UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:) directly.")
    static func removeNotification(_ id: Int) { fatalError("unavailable") }

    @available(*, unavailable,
               message: "OpenPush does not manage the notification centre. Use UNUserNotificationCenter directly.")
    static func removeGroupedNotifications(_ group: String) { fatalError("unavailable") }
}

public extension OneSignal {
    @available(*, unavailable,
               message: "OpenPush installs no notification-center delegate. Implement userNotificationCenter(_:openSettingsFor:) in your own delegate when the app provides notification settings.")
    static func setProvidesNotificationSettingsView(_ providesView: Bool) {
        fatalError("unavailable")
    }
}
