import Foundation
import OpenPushCore

extension OpenPush {
    /// Phone number and email address adds and removes, kept until the server
    /// has them.
    ///
    /// Modelled on `CustomEvents`: one non-recursive lock, the queue persisted
    /// under the configuration's token key so a workspace switch cannot carry
    /// one app's addresses into another, and the scheduler seam for retries so
    /// tests drive the clock. Writes go one at a time, in order. A failure the
    /// server may recover from (transport, 429, 5xx) is retried on the
    /// registration schedule; once that is spent the write is held for the next
    /// write or accepted registration. Any other refusal drops the write, so one
    /// bad address cannot wedge the ones behind it.
    ///
    /// The subscription id an add comes back with is stored per channel and
    /// address, and forgotten when the address is removed.
    final class AddressSubscriptions: @unchecked Sendable {
        static let shared = AddressSubscriptions()

        static func pendingKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".addressWrites"
        }

        static func idsKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".addressSubscriptionIDs"
        }

        /// The write on the wire, and which queue it was taken from.
        private struct Claim: Sendable {
            let tokenKey: String
            let write: AddressWrite
            let attempt: Int
        }

        private let lock = NSLock()
        private var loadedTokenKey: String?
        private var pending: [AddressWrite] = []
        private var ids: [String: String] = [:]
        private var inFlight = false
        private var attempt = 1
        /// Set before a retry is scheduled and cleared when it fires, so a
        /// scheduler that runs the work before handing back its handle cannot
        /// leave a dead timer blocking every later flush.
        private var armedRetry: UUID?
        private var retryWork: ScheduledWork?

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        // MARK: - Entry points

        /// `false` when OpenPush is not initialized: there is no workspace to
        /// queue the write under, so it is dropped with a log line.
        @discardableResult
        func enqueue(_ write: AddressWrite) -> Bool {
            guard let config = OpenPush.state.config else {
                OpenPush.onLog("✗ \(write.channel.noun) \(write.maskedAddress) dropped — " +
                               "initialize OpenPush first")
                return false
            }
            load(config)
            let cancelled: ScheduledWork? = withLock {
                // A newer write for the same address supersedes one still waiting.
                // The one already on the wire is left alone; this follows it.
                let kept = inFlight ? 1 : 0
                pending = Array(pending.prefix(kept))
                    + pending.dropFirst(kept).filter { $0.key != write.key }
                pending.append(write)
                persistLocked()
                return disarmRetryLocked()
            }
            cancelled?.cancel()
            flush()
            return true
        }

        /// An accepted registration is the moment a held write is worth trying
        /// again: the server is evidently reachable.
        func registrationCompleted() {
            guard let config = OpenPush.state.config else { return }
            load(config)
            withLock { disarmRetryLocked() }?.cancel()
            flush()
        }

        /// Only the workspace being left has its queue and ids erased, the same
        /// rule as `CustomEvents`.
        func workspaceSwitched(previousTokenKey: String?) {
            withLock {
                let cancelled = clearLocked()
                if let previousTokenKey {
                    UserDefaults.standard.removeObject(
                        forKey: Self.pendingKey(forTokenKey: previousTokenKey))
                    UserDefaults.standard.removeObject(
                        forKey: Self.idsKey(forTokenKey: previousTokenKey))
                }
                return cancelled
            }?.cancel()
        }

        func resetForTests() {
            withLock { clearLocked() }?.cancel()
        }

        /// The subscription id the server gave this address on this channel.
        func subscriptionID(channel: AddressChannel, address: String) -> String? {
            guard let config = OpenPush.state.config else { return nil }
            load(config)
            return withLock { ids["\(channel.rawValue):\(address)"] }
        }

        /// The writes the server has not accepted yet, oldest first.
        var pendingWrites: [AddressWrite] {
            guard let config = OpenPush.state.config else { return [] }
            load(config)
            return withLock { pending }
        }

        // MARK: - Sending

        private func flush() {
            let claim: Claim? = withLock {
                guard !inFlight, armedRetry == nil, let tokenKey = loadedTokenKey,
                      let head = pending.first else { return nil }
                inFlight = true
                return Claim(tokenKey: tokenKey, write: head, attempt: attempt)
            }
            guard let claim else { return }
            guard let config = OpenPush.state.config else {
                withLock { inFlight = false }
                return
            }
            let body = claim.write.body(authHash: Self.authHash(for: claim.write.externalID))
            // Addresses are often added from a sign-up screen the person is about to
            // leave; without an assertion the request dies with the suspension.
            let assertion = OpenPush.backgroundAssertion
            let handle = assertion.begin("openpush.phone")
            OpenPush.post("/v1/apps/\(config.appID)/subscriptions", body) {
                [weak self] code, response in
                defer { assertion.end(handle) }
                let retryAfter = OpenPush.lastRetryAfter.take()
                self?.finish(claim, code: code, response: response, retryAfter: retryAfter)
            }
        }

        private func finish(_ claim: Claim, code: Int, response: String, retryAfter: Double?) {
            let write = claim.write
            let name = "\(write.channel.noun) \(write.maskedAddress)"
            if (200...299).contains(code) {
                let id = Self.subscriptionID(in: response)
                guard settle(claim, removingHead: true, { ids in
                    switch write.action {
                    case .add: if let id { ids[write.key] = id }
                    case .remove: ids[write.key] = nil
                    }
                }) else { return }
                OpenPush.onLog(Self.acceptedLine(write, name: name, response: response))
                flush()
            } else if let delay = OpenPush.retryDelay(afterAttempt: claim.attempt, code: code,
                                                      retryAfter: retryAfter) {
                retry(claim, after: delay, code: code)
            } else if OpenPush.isRetryableRegistrationFailure(code) {
                guard settle(claim, removingHead: false) else { return }
                OpenPush.onLog("✗ \(name) not sent yet (\(code)) — held for the next write " +
                               "or registration")
            } else {
                guard settle(claim, removingHead: true) else { return }
                // A refusal is final: the server said in words why, and sending
                // it again would only be refused again.
                let error = OpenPushVerifyError.from(status: code, body: response)
                OpenPush.onLog("✗ \(name) refused (\(code)) and dropped — " +
                               OpenPush.boundedLog(error.description))
                flush()
            }
        }

        /// Ends the claim if its queue is still the loaded one. A workspace
        /// switch during the request already threw that queue away.
        private func settle(_ claim: Claim, removingHead: Bool,
                            _ updateIDs: (inout [String: String]) -> Void = { _ in }) -> Bool {
            withLock {
                guard loadedTokenKey == claim.tokenKey, inFlight else { return false }
                inFlight = false
                attempt = 1
                if removingHead, pending.first == claim.write { pending.removeFirst() }
                updateIDs(&ids)
                persistLocked()
                return true
            }
        }

        private func retry(_ claim: Claim, after delay: Double, code: Int) {
            let token = UUID()
            let current: Bool = withLock {
                guard loadedTokenKey == claim.tokenKey, inFlight else { return false }
                inFlight = false
                attempt = claim.attempt + 1
                armedRetry = token
                return true
            }
            guard current else { return }
            OpenPush.onLog("• \(claim.write.channel.noun) \(claim.write.maskedAddress) " +
                           "attempt \(claim.attempt) failed (\(code)); retrying in " +
                           "\(Int(delay.rounded()))s")
            // Read outside this class's lock: the seam takes `State`'s.
            let work = OpenPush.state.schedulerSeam.run(delay) { [weak self] in
                self?.retryFired(token)
            }
            let spent = withLock { () -> Bool in
                guard armedRetry == token else { return true }
                retryWork = work
                return false
            }
            if spent { work.cancel() }
        }

        private func retryFired(_ token: UUID) {
            let due = withLock { () -> Bool in
                guard armedRetry == token else { return false }
                armedRetry = nil
                retryWork = nil
                return true
            }
            if due { flush() }
        }

        // MARK: - State

        /// The proof for `externalID`, when this install holds one for that user.
        private static func authHash(for externalID: String?) -> String? {
            guard let externalID,
                  case .identified(let current, let hash) = OpenPush.state.currentIdentity,
                  current == externalID else { return nil }
            return hash
        }

        /// What an accepted write is reported as. An email address the app's
        /// suppression list has comes back at −2: stored, never emailed, and
        /// not retried, because asking again cannot change the answer. Under
        /// identity verification the server stores an add whose auth hash it
        /// refused without the user, and says so in `identity_rejected` — read
        /// the same way as on push registration.
        private static func acceptedLine(_ write: AddressWrite, name: String,
                                         response: String) -> String {
            if write.action == .add,
               let note = OpenPush.parseRegistration(response).identityRejected {
                return "✗ \(name) stored without a user — the identity hash was refused: " +
                    OpenPush.boundedLog(note)
            }
            switch (write.channel, write.action) {
            case (_, .remove):
                return "✓ \(name) removed"
            case (.email, .add):
                if status(in: response) == OpenPush.optedOutStatus {
                    return "✗ \(name) is on this app's suppression list (it unsubscribed, " +
                        "bounced or complained) — stored, never emailed"
                }
                return "✓ \(name) subscribed"
            case (.sms, .add), (.whatsapp, .add):
                return "✓ \(name) added — not verified until a phone code for it is approved"
            }
        }

        private static func status(in response: String) -> Int? {
            guard let data = response.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (payload["status"] as? NSNumber)?.intValue
        }

        private static func subscriptionID(in response: String) -> String? {
            guard let data = response.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = payload["id"] as? String, !id.isEmpty else { return nil }
            return id
        }

        private func disarmRetryLocked() -> ScheduledWork? {
            let work = retryWork
            armedRetry = nil
            retryWork = nil
            attempt = 1
            return work
        }

        private func clearLocked() -> ScheduledWork? {
            let work = disarmRetryLocked()
            inFlight = false
            loadedTokenKey = nil
            pending = []
            ids = [:]
            return work
        }

        private func load(_ config: OpenPushConfiguration) {
            let stale: ScheduledWork? = withLock {
                guard loadedTokenKey != config.tokenKey else { return nil }
                let work = clearLocked()
                loadedTokenKey = config.tokenKey
                let defaults = UserDefaults.standard
                pending = Self.decoded([AddressWrite].self,
                                       defaults.data(forKey: Self.pendingKey(
                                        forTokenKey: config.tokenKey))) ?? []
                ids = Self.decoded([String: String].self,
                                   defaults.data(forKey: Self.idsKey(
                                    forTokenKey: config.tokenKey))) ?? [:]
                return work
            }
            // Never under the lock: cancelling reaches into the scheduler.
            stale?.cancel()
        }

        private func persistLocked() {
            guard let tokenKey = loadedTokenKey else { return }
            Self.store(pending.isEmpty ? nil : pending,
                       forKey: Self.pendingKey(forTokenKey: tokenKey))
            Self.store(ids.isEmpty ? nil : ids, forKey: Self.idsKey(forTokenKey: tokenKey))
        }

        private static func decoded<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
            guard let data else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }

        private static func store<T: Encodable>(_ value: T?, forKey key: String) {
            guard let value, let data = try? JSONEncoder().encode(value) else {
                UserDefaults.standard.removeObject(forKey: key)
                return
            }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
