import Foundation

public enum OpenPushLiveActivitiesError: Error, Equatable {
    case invalidActivityType(String)
}

// MARK: - S4 CONTRACT (RECONCILED 2026-08-17 — authoritative)
//
//   enter  → POST /v1/apps/{app}/live-activities
//            {token, activity_id, activity_type, update_token}
//   exit   → POST /v1/apps/{app}/live-activities/{activity_id}/end   {token}
//   PTS    → POST /v1/apps/{app}/live-activities/push-to-start
//            {token, activity_type, push_to_start_token}
//
// Two consequences that are NOT cosmetic:
//  1. `token` is the DEVICE's APNs token — the server resolves the subscription
//     by it (404 "unknown device token" otherwise). The Live Activity's own
//     token travels as `update_token` / `push_to_start_token`. So every call
//     here requires `OpenPush.currentToken` and must refuse without it.
//  2. Removal is a dedicated route, not an empty token: S4 answers an unknown
//     activity id with 404 rather than a silent 200, so `exit` cannot be a
//     "present and empty" write the way `logout` and `removeAlias` are.
extension OpenPush {
    static func liveActivityPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? value
    }

    static func liveActivityPath(appID: String) -> String {
        "/v1/apps/\(appID)/live-activities"
    }

    static func liveActivityEndPath(appID: String, activityId: String) -> String {
        "/v1/apps/\(appID)/live-activities/\(liveActivityPathSegment(activityId))/end"
    }

    static func liveActivityStartTokenPath(appID: String) -> String {
        "/v1/apps/\(appID)/live-activities/push-to-start"
    }

    static func liveActivityStartTokenRemovePath(appID: String) -> String {
        "/v1/apps/\(appID)/live-activities/push-to-start/remove"
    }

    static func liveActivityClickPath(appID: String, activityId: String) -> String {
        "/v1/apps/\(appID)/live-activities/\(liveActivityPathSegment(activityId))/click"
    }

    static func looksLikeLiveActivityToken(_ value: String) -> Bool {
        !value.isEmpty && value.count % 2 == 0 && value.allSatisfy { $0.isHexDigit }
    }
}

public extension OpenPush {
    /// Compatibility shape: the host owns ActivityKit and forwards tokens here.
    /// `LiveActivities.setup(_:activityType:)` (iOS 16.1+) does the forwarding
    /// automatically for one `ActivityAttributes` type.
    enum LiveActivities {
        /// The ActivityKit `attributes-type` of the default attributes type: a
        /// wire value that must not change.
        public static let defaultActivityTypeName = "DefaultLiveActivityAttributes"
        public static let activitiesEnabledTagKey = "device_live_activities_enabled"
        public static let frequentPushesTagKey = "device_frequent_pushes"

        public static func derivedActivityType<T>(_ type: T.Type) -> String {
            OpenPushLiveActivityTypeName.derived(type)
        }

        public static func recordFrequentPushes(_ enabled: Bool) {
            OpenPush.User.addTag(key: frequentPushesTagKey,
                                 value: enabled ? "true" : "false")
        }

        static func recordActivitiesEnabled(_ enabled: Bool) {
            OpenPush.User.addTag(key: activitiesEnabledTagKey,
                                 value: enabled ? "true" : "false")
        }

        static func recordAuthorization(activitiesEnabled: Bool,
                                        frequentPushesEnabled: Bool) {
            OpenPush.User.addTags([
                activitiesEnabledTagKey: activitiesEnabled ? "true" : "false",
                frequentPushesTagKey: frequentPushesEnabled ? "true" : "false",
            ])
        }
        /// Register the push token of a running Live Activity so the server can
        /// update it, naming the activity type the server needs to route it. Call
        /// this again whenever ActivityKit hands out a new token for the same
        /// activity — the server keeps the newest.
        ///
        /// This is the entry point for a host that owns its own ActivityKit
        /// observation instead of calling `setup(_:activityType:)`: nothing else
        /// could have told the SDK what type this id is, and S4 requires
        /// `activity_type` on every update-token write.
        public static func enter(_ activityId: String, withToken token: String,
                                 activityType: String,
                                 completion: (@Sendable (Bool) -> Void)? = nil) {
            let completion = OpenPush.onMain(completion)
            guard !token.isEmpty else {
                refuseEmptyToken(activityId, completion)
                return
            }
            // Both checked before the type is recorded: an empty id would file the
            // type under a key nothing can retrieve, and an empty type would erase
            // a good one an earlier accepted call recorded for this id.
            guard !activityId.isEmpty else {
                OpenPush.onLog("✗ live activity token dropped — the activity id is empty")
                completion?(false)
                return
            }
            guard !activityType.isEmpty else {
                OpenPush.onLog("✗ live activity \(activityId): the activity type cannot be " +
                               "empty — it is the template name the OpenPush console and the " +
                               "server share")
                completion?(false)
                return
            }
            OpenPush.state.setLiveActivityType(activityType, for: activityId)
            forward(activityId: activityId, activityType: activityType, token: token,
                    completion: completion)
        }

        /// The "type already known" overload: use it for a later token of an
        /// activity whose type `setup(_:activityType:)` or
        /// `enter(_:withToken:activityType:)` has already recorded. It refuses when
        /// no type is known, because S4 cannot route an update token without one.
        public static func enter(_ activityId: String, withToken token: String,
                                 completion: (@Sendable (Bool) -> Void)? = nil) {
            let completion = OpenPush.onMain(completion)
            guard !token.isEmpty else {
                refuseEmptyToken(activityId, completion)
                return
            }
            forward(activityId: activityId,
                    activityType: OpenPush.state.liveActivityType(for: activityId),
                    token: token, completion: completion)
        }

        private static func refuseEmptyToken(_ activityId: String,
                                             _ completion: (@Sendable (Bool) -> Void)?) {
            OpenPush.onLog("✗ live activity \(activityId): an empty update token cannot be " +
                           "registered — use exit(_:) to remove one")
            completion?(false)
        }

        /// Stop updating a Live Activity: the server drops its update token. The
        /// activity itself is ended by the host through ActivityKit, or by the
        /// server's own end event.
        public static func exit(_ activityId: String,
                                completion: (@Sendable (Bool) -> Void)? = nil) {
            let completion = OpenPush.onMain(completion)
            guard !activityId.isEmpty, !activityId.contains("/") else {
                OpenPush.onLog("✗ live activity exit dropped — invalid activity id")
                completion?(false)
                return
            }
            executor.append(OpenPush.LiveActivityRequest(
                kind: .removeUpdateToken, key: activityId, activityId: activityId
            )) { succeeded in
                if succeeded { OpenPush.state.setLiveActivityType(nil, for: activityId) }
                completion?(succeeded)
            }
        }

        /// iOS 17.2+ push-to-start: the token that lets the server start an
        /// activity of this type with the app closed. The host harvests it through
        /// ActivityKit and forwards it here.
        public static func setPushToStartToken(activityType: String, token: String,
                                               completion: (@Sendable (Bool) -> Void)? = nil) {
            let completion = OpenPush.onMain(completion)
            guard !activityType.isEmpty, OpenPush.looksLikeLiveActivityToken(token) else {
                OpenPush.onLog("✗ push-to-start token dropped — activity type and token are " +
                               "both required")
                completion?(false)
                return
            }
            executor.append(OpenPush.LiveActivityRequest(
                kind: .setStartToken, key: activityType,
                activityType: activityType, token: token
            ), completion: completion)
        }

        @available(iOS 17.2, *)
        public static func setPushToStartToken(_ activityType: String,
                                               withToken token: String) throws {
            guard activityType.addingPercentEncoding(
                withAllowedCharacters: .urlUserAllowed) != nil else {
                throw OpenPushLiveActivitiesError.invalidActivityType(activityType)
            }
            guard !activityType.isEmpty, OpenPush.looksLikeLiveActivityToken(token) else { return }
            executor.append(OpenPush.LiveActivityRequest(
                kind: .setStartToken, key: activityType,
                activityType: activityType, token: token))
        }

        @available(iOS 17.2, *)
        public static func removePushToStartToken(_ activityType: String) throws {
            guard activityType.addingPercentEncoding(
                withAllowedCharacters: .urlUserAllowed) != nil else {
                throw OpenPushLiveActivitiesError.invalidActivityType(activityType)
            }
            guard !activityType.isEmpty else { return }
            executor.append(OpenPush.LiveActivityRequest(
                kind: .removeStartToken, key: activityType,
                activityType: activityType))
        }
    }
}

extension OpenPush.LiveActivities {
    /// Every public entry point and the ActivityKit adapter land here, so the
    /// path, the body shape, and the logging exist exactly once.
    static func forward(activityId: String, activityType: String?, token: String,
                        completion: (@Sendable (Bool) -> Void)?) {
        guard !activityId.isEmpty else {
            OpenPush.onLog("✗ live activity token dropped — the activity id is empty")
            completion?(false)
            return
        }
        guard !activityId.contains("/") else {
            OpenPush.onLog("✗ live activity id cannot contain '/'")
            completion?(false)
            return
        }
        guard OpenPush.looksLikeLiveActivityToken(token) else {
            OpenPush.onLog("✗ live activity token is not hex-shaped")
            completion?(false)
            return
        }
        executor.append(OpenPush.LiveActivityRequest(
            kind: .setUpdateToken, key: activityId, activityId: activityId,
            activityType: activityType ?? "", token: token
        ), completion: completion)
    }

    /// ActivityKit hands tokens over as `Data`; the wire carries lowercase hex,
    /// the same encoding as an APNs device token. This is the whole payload
    /// contribution of the (untestable) ActivityKit adapter in Task I11b, which is
    /// why it lives here on plain values.
    static func record(activityId: String, activityType: String, tokenData: Data) {
        // Straight through the public overload: the adapter and a self-managing
        // host must not be able to drift apart in what they record or send.
        enter(activityId, withToken: OpenPush.hexToken(tokenData),
              activityType: activityType, completion: nil)
    }

    static func recordPushToStart(activityType: String, tokenData: Data) {
        if #available(iOS 17.2, *) {
            try? setPushToStartToken(activityType, withToken: OpenPush.hexToken(tokenData))
        }
    }

    static func reportReceipt(notificationId: String, activityId: String,
                              activityType: String) {
        guard !notificationId.isEmpty else { return }
        executor.append(OpenPush.LiveActivityRequest(
            kind: .receipt, key: notificationId, activityId: activityId,
            activityType: activityType, notificationId: notificationId))
    }
}

// `os(iOS)` as well as `canImport`: ActivityKit *imports* on the macOS host that
// runs `swift test`, but `Activity` itself is marked unavailable there, so
// canImport alone would break the host build.
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public extension OpenPush.LiveActivities {
    static func setup<T: OpenPushLiveActivityAttributes>(
        _ activityType: T.Type, options: OpenPushLiveActivitySetupOptions? = nil
    ) where T: Sendable {
        setup(activityType, activityType: derivedActivityType(activityType),
              options: options, topicKey: { $0.openpush.activityId },
              notificationId: { $0.openpush?.notificationId })
    }

    static func setup<Attributes: ActivityAttributes & Sendable>(
        _ type: Attributes.Type, activityType: String,
        options: OpenPushLiveActivitySetupOptions? = nil,
        topicKey: (@Sendable (Attributes) -> String)?,
        notificationId: (@Sendable (Attributes.ContentState) -> String?)?
    ) {
        let enableStart = options?.enablePushToStart ?? true
        let enableUpdate = options?.enablePushToUpdate ?? true
        if #available(iOS 16.2, *) {
            let authorizationSource = ActivityKitAuthorizationSource()
            // Setup may run again after the host changes OpenPush workspaces.
            // Seed the current workspace every time, while keeping only one
            // process-wide observer for future iOS Settings changes.
            recordAuthorization(
                activitiesEnabled: authorizationSource.activitiesEnabled,
                frequentPushesEnabled: authorizationSource.frequentPushesEnabled
            )
            authorizationMonitor.start {
                observeAuthorizationUpdates(authorizationSource)
            }
        }
        observe(ActivityKitSource(topicKey: topicKey, notificationId: notificationId),
                activityType: activityType,
                enablePushToStart: enableStart, enablePushToUpdate: enableUpdate)
    }

    static func setupDefault(options: OpenPushLiveActivitySetupOptions? = nil) {
        setup(DefaultLiveActivityAttributes.self, options: options)
    }

    static func startDefault(_ activityId: String, attributes: [String: Any],
                             content: [String: Any]) {
        guard !activityId.isEmpty, !activityId.contains("/") else { return }
        let attributes = DefaultLiveActivityAttributes(
            data: OpenPushAnyCodable.map(attributes),
            openpush: .create(activityId: activityId))
        let state = DefaultLiveActivityAttributes.ContentState(
            data: OpenPushAnyCodable.map(content))
        do {
            _ = try Activity<DefaultLiveActivityAttributes>.request(
                attributes: attributes, contentState: state, pushType: .token)
        } catch {
            OpenPush.onLog("✗ startDefault failed for \(activityId): \(error)")
        }
    }

    static func setup<Attributes: ActivityAttributes & Sendable>(
        _ type: Attributes.Type, activityType: String
    ) {
        setup(type, activityType: activityType, options: nil,
              topicKey: nil, notificationId: nil)
    }
}

@available(iOS 17.2, *)
public extension OpenPush.LiveActivities {
    static func setPushToStartToken<T: ActivityAttributes>(_ activityType: T.Type,
                                                           withToken token: String) {
        try? setPushToStartToken(derivedActivityType(activityType), withToken: token)
    }

    static func removePushToStartToken<T: ActivityAttributes>(_ activityType: T.Type) {
        try? removePushToStartToken(derivedActivityType(activityType))
    }
}
#endif
