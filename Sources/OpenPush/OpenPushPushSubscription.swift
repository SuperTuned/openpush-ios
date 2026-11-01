import Foundation

extension OpenPush {
    /// The wire's `notification_types`. Any positive value means Subscribed: on
    /// iOS it is an authorization bitmask. Provider and operator states remain
    /// server-owned.
    static let subscribedStatus = 1
    static let optedOutStatus = -2
    static let notificationTypesNoPermission = 0
    static let notificationTypesNeverPrompted = -18
    static let notificationTypesPromptUnanswered = -19

    struct AuthorizationSnapshot: Sendable, Equatable {
        var status: PermissionStatus
        var badge = false
        var sound = false
        var alert = false
        var carPlay = false
        var critical = false
        var appSettings = false
        var announcement = false
        var timeSensitive = false

        static func derived(from status: OpenPush.PermissionStatus) -> AuthorizationSnapshot {
            AuthorizationSnapshot(status: status,
                                  badge: status.isGranted,
                                  sound: status.isGranted,
                                  alert: status.isGranted)
        }
    }

    static func notificationTypes(from snapshot: AuthorizationSnapshot, prompted: Bool) -> Int {
        switch snapshot.status {
        case .notDetermined:
            return prompted ? notificationTypesPromptUnanswered : notificationTypesNeverPrompted
        case .denied:
            return notificationTypesNoPermission
        case .granted, .provisional, .ephemeral:
            var mask = 0
            if snapshot.badge { mask |= 1 }
            if snapshot.sound { mask |= 2 }
            if snapshot.alert { mask |= 4 }
            if snapshot.carPlay { mask |= 8 }
            if snapshot.critical { mask |= 16 }
            if snapshot.appSettings { mask |= 32 }
            if snapshot.status == .provisional { mask |= 64 }
            if snapshot.announcement { mask |= 128 }
            if snapshot.timeSensitive { mask |= 256 }
            return mask == 0 ? subscribedStatus : mask
        }
    }

    static func wireStatus() -> Int {
        state.isOptedOut ? optedOutStatus : state.currentNotificationTypes
    }
}

public extension OpenPush {
    /// Opt-in control lives on the push subscription rather than on the user,
    /// which is the shape migrating hosts already call.
    struct PushSubscription: Sendable {
        init() {}

        /// Three things at once: authorization granted, a token in hand, and no
        /// opt-out on record. Any one missing means a message cannot arrive.
        public static var optedIn: Bool {
            OpenPush.wireStatus() > 0 && OpenPush.currentToken != nil
        }

        /// Re-subscribe this install. If notification authorization is missing this
        /// prompts first — the order migrating hosts already expect — and registers
        /// only on a grant.
        public static func optIn() { optIn(completion: nil) }

        /// Opt this install out. The device stays registered and keeps its token;
        /// the server stops selecting it.
        public static func optOut() { optOut(completion: nil) }
    }
}

public extension OpenPush {
    /// What the push subscription looked like before it changed, next to what it
    /// looks like now. `previous` is `nil` for the first change the SDK reports,
    /// because there is no earlier state to name.
    struct PushSubscriptionChange: Sendable, Equatable {
        public let previous: PushSubscriptionState?
        public let current: PushSubscriptionState

        public init(previous: PushSubscriptionState?, current: PushSubscriptionState) {
            self.previous = previous
            self.current = current
        }
    }
}

public extension OpenPush.PushSubscription {
    var id: String? { OpenPush.state.currentSubscriptionID }
    var token: String? { OpenPush.currentToken }
    var status: Int? { OpenPush.wireStatus() }
    var optedIn: Bool { Self.optedIn }

    func optIn() { Self.optIn() }
    func optOut() { Self.optOut() }

    static func addObserver(
        _ observer: @escaping @Sendable (OpenPush.PushSubscriptionState) -> Void
    ) -> UUID {
        OpenPush.state.addSubscriptionObserver(observer)
    }

    static func removeObserver(_ id: UUID) {
        OpenPush.state.removeSubscriptionObserver(id)
    }

    /// Capture the live values for equality checks or a diffing view model.
    /// Migrating hosts hang the observer off the instance while OpenPush declares
    /// it statically. Both spellings add to the SAME observer list, so one
    /// registered here is removable through either.
    func addObserver(
        _ observer: @escaping @Sendable (OpenPush.PushSubscriptionState) -> Void
    ) -> UUID { Self.addObserver(observer) }

    func removeObserver(_ id: UUID) { Self.removeObserver(id) }

    /// The diffing form of `addObserver`: the same moments reach both, but this
    /// one also carries the state that was replaced, so a host can act on what
    /// actually moved without keeping its own copy. The chain is continuous —
    /// each change's `previous` is the `current` of the one before it.
    static func addChangeObserver(
        _ observer: @escaping @Sendable (OpenPush.PushSubscriptionChange) -> Void
    ) -> UUID {
        OpenPush.state.addSubscriptionChangeObserver(observer)
    }

    /// Change observers keep their own list, so an id from `addObserver` means
    /// nothing here, and one from `addChangeObserver` means nothing to
    /// `removeObserver`. Either way the mismatch is a no-op.
    static func removeChangeObserver(_ id: UUID) {
        OpenPush.state.removeSubscriptionChangeObserver(id)
    }

    /// The instance spelling of `addChangeObserver`. Both spellings add to the
    /// SAME change-observer list, so one registered here is removable through
    /// either.
    func addChangeObserver(
        _ observer: @escaping @Sendable (OpenPush.PushSubscriptionChange) -> Void
    ) -> UUID { Self.addChangeObserver(observer) }

    func removeChangeObserver(_ id: UUID) { Self.removeChangeObserver(id) }

    func snapshot() -> OpenPush.PushSubscriptionState {
        OpenPush.PushSubscriptionState(id: id, token: token,
                                       optedIn: optedIn, status: status)
    }
}

extension OpenPush.PushSubscription {
    /// The completion forms are internal: the public surface stays parameterless
    /// for compatibility with the call sites migrating hosts already wrote, and
    /// these are what the tests drive.
    static func optIn(completion: (@Sendable (Bool) -> Void)?) {
        OpenPush.state.setOptedOut(false)
        guard OpenPush.state.currentNotificationTypes > 0 else {
            // The internal entry, not the public one: the public completion is
            // delivered on the main thread, and the registration that follows has
            // no business being started from there.
            OpenPush.Notifications.request(provisional: false, fallbackToSettings: true) { _ in
                apply(completion: completion)
            }
            return
        }
        apply(completion: completion)
    }

    static func optOut(completion: (@Sendable (Bool) -> Void)?) {
        OpenPush.state.setOptedOut(true)
        apply(completion: completion)
    }

    /// One place resolves and re-registers the status, so optIn and optOut cannot
    /// drift apart. The opt-out and underlying device value are durable session
    /// state and ride every registration, including the first after a relaunch.
    static func apply(completion: (@Sendable (Bool) -> Void)?) {
        let status = OpenPush.wireStatus()
        guard let token = OpenPush.currentToken else {
            OpenPush.onLog("• subscription status \(status) stored — no APNs token yet, so it " +
                           "is sent with the next registration")
            completion?(optedIn)
            return
        }
        OpenPush.performRegistration(token: token) { result in
            switch result {
            case .accepted:
                OpenPush.onLog("✓ subscription status \(status) applied")
            case .rejected(_, let message), .dropped(let message):
                // The intent stays stored and rides the next registration, the same
                // way a failed tag change does. Rolling it back would discard the
                // user's choice over one flaky request.
                OpenPush.onLog("✗ subscription status \(status) not applied yet: \(message)")
            }
            OpenPush.notifySubscriptionObservers()
            completion?(optedIn)
        }
    }
}
