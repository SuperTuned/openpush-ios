import Foundation
import OpenPushCore

extension OpenPush {
    enum LiveActivityCache: String, Codable, Sendable, CaseIterable {
        case updateTokens, startTokens, clicks, receipts
        var ttl: TimeInterval {
            switch self {
            case .updateTokens, .receipts: return 60 * 60 * 24
            case .startTokens: return 60 * 60 * 24 * 365
            case .clicks: return 60 * 60 * 24 * 30
            }
        }
    }

    struct LiveActivityRequest: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case setUpdateToken, removeUpdateToken, setStartToken, removeStartToken
            case click, receipt
        }
        var kind: Kind
        var key: String
        var activityId: String = ""
        var activityType: String = ""
        var token: String = ""
        var notificationId: String = ""
        var timestamp: Date = Date()
        var succeeded = false

        var cache: LiveActivityCache {
            switch kind {
            case .setUpdateToken, .removeUpdateToken: return .updateTokens
            case .setStartToken, .removeStartToken: return .startTokens
            case .click: return .clicks
            case .receipt: return .receipts
            }
        }
        var forgetWhenSuccessful: Bool {
            switch kind {
            case .removeUpdateToken, .removeStartToken, .click: return true
            default: return false
            }
        }
        var label: String {
            switch kind {
            case .setUpdateToken: return "update token for \(activityId)"
            case .removeUpdateToken: return "end of live activity \(activityId)"
            case .setStartToken: return "push-to-start token for \(activityType)"
            case .removeStartToken: return "push-to-start removal for \(activityType)"
            case .click: return "live activity click for \(activityId)"
            case .receipt: return "live activity receipt for \(notificationId)"
            }
        }
        func supersedes(_ existing: LiveActivityRequest) -> Bool {
            // A cached receipt — in flight, awaiting retry, or already sent — is
            // never replaced; the cache entry is the dedup marker for the TTL.
            if kind == .receipt { return false }
            if kind == existing.kind,
               kind == .setUpdateToken || kind == .setStartToken,
               token == existing.token { return false }
            return timestamp >= existing.timestamp
        }
    }

    final class LiveActivityExecutor: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LiveActivityCache: [String: LiveActivityRequest]] = [:]
        private var completions: [String: @Sendable (Bool) -> Void] = [:]
        private var storageKey: String?
        /// The one retry timer for every pending request.
        private var retry: OpenPush.ScheduledWork?
        /// The attempt the next armed retry counts as, on the shared schedule.
        /// Reset by an accepted request and by every accepted registration.
        private var retryAttempt = 1
        private var lastSubscriptionID: String?

        static func storageKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".liveActivityQueue"
        }

        func attach(tokenKey: String, isFirstAttach: Bool) {
            let previous = lock.withLock { () -> String? in
                let previous = storageKey
                storageKey = Self.storageKey(forTokenKey: tokenKey)
                return previous
            }
            if isFirstAttach {
                load()
                drivePending()
            } else {
                lock.withLock {
                    items.removeAll(); completions.removeAll(); lastSubscriptionID = nil
                }
                for key in Set([previous, Self.storageKey(forTokenKey: tokenKey)].compactMap { $0 }) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        func append(_ request: LiveActivityRequest,
                    completion: (@Sendable (Bool) -> Void)? = nil) {
            // A rejected request still owes its caller an answer: the cached entry
            // already carries the outcome, so report it instead of dropping the
            // completion and leaving the caller waiting forever.
            let verdict: (accepted: Bool, existingSucceeded: Bool) = lock.withLock {
                var cache = items[request.cache] ?? [:]
                if let existing = cache[request.key], !request.supersedes(existing) {
                    return (false, existing.succeeded)
                }
                cache[request.key] = request
                items[request.cache] = cache
                if let completion { completions[completionKey(request)] = completion }
                return (true, false)
            }
            guard verdict.accepted else {
                completion?(verdict.existingSucceeded)
                return
            }
            save()
            execute(request)
        }

        func registrationCompleted(subscriptionID: String?) {
            let changed = lock.withLock { () -> Bool in
                retryAttempt = 1
                guard lastSubscriptionID != subscriptionID else { return false }
                lastSubscriptionID = subscriptionID
                return true
            }
            if changed {
                lock.withLock {
                    // Receipts are exempt: the server counts a confirmation against
                    // the message, not the subscription, so re-sending one on every
                    // subscription-id change double-counts it. Token registrations
                    // ARE resolved per subscription and must be sent again.
                    for (cache, entries) in items where cache != .receipts {
                        items[cache] = entries.mapValues { value in
                            var value = value; value.succeeded = false; return value
                        }
                    }
                }
                save()
            }
            drivePending()
        }

        private func completionKey(_ request: LiveActivityRequest) -> String {
            "\(request.cache.rawValue)|\(request.key)"
        }

        private func drivePending() {
            let pending = lock.withLock {
                items.values.flatMap(\.values).filter { !$0.succeeded }
            }
            pending.forEach(execute)
        }

        private func execute(_ request: LiveActivityRequest) {
            guard let config = OpenPush.state.config, let device = OpenPush.currentToken else {
                // Nothing to post against yet. The request stays queued and is
                // sent by `registrationCompleted`, which every accepted
                // registration calls; a timer would only wake the app to find
                // the same missing token.
                return
            }
            let wire: (String, [String: Any])
            switch request.kind {
            case .setUpdateToken:
                var body: [String: Any] = ["token": device, "activity_id": request.activityId,
                                           "update_token": request.token]
                if !request.activityType.isEmpty { body["activity_type"] = request.activityType }
                wire = (OpenPush.liveActivityPath(appID: config.appID), body)
            case .removeUpdateToken:
                wire = (OpenPush.liveActivityEndPath(appID: config.appID,
                                                     activityId: request.activityId),
                        ["token": device])
            case .setStartToken:
                wire = (OpenPush.liveActivityStartTokenPath(appID: config.appID),
                        ["token": device, "activity_type": request.activityType,
                         "push_to_start_token": request.token])
            case .removeStartToken:
                wire = (OpenPush.liveActivityStartTokenRemovePath(appID: config.appID),
                        ["token": device, "activity_type": request.activityType])
            case .click:
                var body: [String: Any] = ["token": device]
                if !request.notificationId.isEmpty { body["notification_id"] = request.notificationId }
                if !request.activityType.isEmpty { body["activity_type"] = request.activityType }
                wire = (OpenPush.liveActivityClickPath(appID: config.appID,
                                                       activityId: request.activityId), body)
            case .receipt:
                wire = ("/v1/ingest", OpenPushPayload.receiptBody(
                    types: ["confirmed"], messageID: request.notificationId,
                    token: device, appID: config.appID, surface: "ios"))
            }
            OpenPush.postLiveActivity(path: wire.0, body: wire.1,
                                      label: request.label) { [weak self] code in
                // Always taken, so a header is never spent on another request.
                let retryAfter = OpenPush.lastRetryAfter.take()
                self?.finish(request, code: code, retryAfter: retryAfter)
            }
        }

        private func finish(_ request: LiveActivityRequest, code: Int, retryAfter: Double?) {
            let succeeded = (200...299).contains(code)
            let completion = lock.withLock { completions.removeValue(forKey: completionKey(request)) }
            completion?(succeeded)
            if succeeded {
                lock.withLock {
                    retryAttempt = 1
                    guard var cache = items[request.cache], cache[request.key] == request else { return }
                    if request.forgetWhenSuccessful { cache.removeValue(forKey: request.key) }
                    else { var value = request; value.succeeded = true; cache[request.key] = value }
                    items[request.cache] = cache
                }
                save()
            } else if request.isTokenRegistration && (code == 401 || code == 404) {
                // A cached APNs token can let ActivityKit's observer run before the
                // sample app has restored its linked-device credential, or before a
                // newly rotated APNs token has been registered as a subscription.
                // The server then answers 401/404 even though the ActivityKit token
                // itself is valid. Keep the request: performRegistration() calls
                // registrationCompleted(), which retries it with the current device
                // token and credential. Dropping it here leaves push-to-start at zero
                // until ActivityKit happens to rotate the token.
                save()
            } else if OpenPush.isRetryableRegistrationFailure(code) {
                scheduleRetry(code: code, retryAfter: retryAfter)
            } else {
                forget(request)
            }
        }

        private func forget(_ request: LiveActivityRequest) {
            lock.withLock {
                var cache = items[request.cache] ?? [:]
                cache.removeValue(forKey: request.key)
                items[request.cache] = cache
                completions.removeValue(forKey: completionKey(request))
            }
            save()
        }

        /// Arms the one retry timer on the shared schedule (jittered, honouring
        /// `Retry-After` up to its cap). Failures in the same drain share it, so
        /// they advance the attempt once. When the schedule is spent the queue
        /// is held, with no timer, until the next accepted registration.
        private func scheduleRetry(code: Int, retryAfter: Double?) {
            let attempt: Int? = lock.withLock {
                guard retry == nil else { return nil }
                let attempt = retryAttempt
                retryAttempt += 1
                return attempt
            }
            guard let attempt else { return }
            guard let delay = OpenPush.retryDelay(afterAttempt: attempt, code: code,
                                                  retryAfter: retryAfter) else {
                OpenPush.onLog("• live activity requests held (\(code)) — sent with the next " +
                               "registration")
                return
            }
            let handle = OpenPush.scheduler.run(delay) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.retry = nil }
                self.drivePending()
            }
            lock.withLock {
                if retry == nil { retry = handle } else { handle.cancel() }
            }
        }

        private func save() {
            let snapshot = lock.withLock { () -> ([LiveActivityCache: [String: LiveActivityRequest]], String?) in
                let at = Date()
                for (cache, entries) in items {
                    items[cache] = entries.filter { at.timeIntervalSince($0.value.timestamp) <= cache.ttl }
                }
                return (items, storageKey)
            }
            guard let key = snapshot.1 else { return }
            let payload = snapshot.0.reduce(into: [String: [String: LiveActivityRequest]]()) {
                $0[$1.key.rawValue] = $1.value
            }
            if payload.allSatisfy({ $0.value.isEmpty }) { UserDefaults.standard.removeObject(forKey: key) }
            else if let data = try? JSONEncoder().encode(payload) { UserDefaults.standard.set(data, forKey: key) }
        }

        private func load() {
            guard let key = lock.withLock({ storageKey }),
                  let data = UserDefaults.standard.data(forKey: key),
                  let payload = try? JSONDecoder().decode(
                    [String: [String: LiveActivityRequest]].self, from: data) else { return }
            let at = Date()
            lock.withLock {
                items.removeAll()
                for (raw, entries) in payload {
                    guard let cache = LiveActivityCache(rawValue: raw) else { continue }
                    items[cache] = entries.filter { at.timeIntervalSince($0.value.timestamp) <= cache.ttl }
                }
            }
        }

        func pendingKeys(in cache: LiveActivityCache) -> [String] {
            lock.withLock { (items[cache] ?? [:]).values.filter { !$0.succeeded }.map(\.key).sorted() }
        }
        func resetForTests() {
            let handle = lock.withLock { () -> OpenPush.ScheduledWork? in
                let handle = retry; retry = nil; items.removeAll(); completions.removeAll()
                lastSubscriptionID = nil; retryAttempt = 1; return handle
            }
            handle?.cancel()
        }
    }
}

private extension OpenPush.LiveActivityRequest {
    var isTokenRegistration: Bool {
        kind == .setUpdateToken || kind == .setStartToken
    }
}

public extension OpenPush.LiveActivities {
    internal static let executor = OpenPush.LiveActivityExecutor()
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
