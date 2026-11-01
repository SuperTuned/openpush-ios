import Foundation
import OpenPushCore

public extension OpenPush {
    /// Record a case-sensitive event for Journey entry, waits, and exits.
    /// Nearby calls share one request; failed requests stay persisted and retry.
    ///
    /// Every call is stamped with a fresh idempotency key at the moment it is
    /// made, so the retry of a batch the server never acknowledged is recognised
    /// as the same events rather than counted a second time. Two calls with the
    /// same name and properties are still two events.
    static func trackEvent(_ name: String, properties: [String: Any] = [:]) {
        CustomEvents.shared.track(name: name, properties: properties,
                                  idempotencyKey: UUID().uuidString)
    }

    /// The same, with an idempotency key you choose. Events sharing a key are one
    /// event on the server however often they are sent — from this launch, a
    /// later launch, or another device — so this is how to record something that
    /// must count once: scope the key to whatever "once" means to you.
    ///
    /// A key that is empty once trimmed is refused and a fresh one is minted in
    /// its place, because silently sending no key would make the event a repeat
    /// of nothing.
    static func trackEvent(_ name: String, properties: [String: Any] = [:],
                           idempotencyKey: String) {
        let clean = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            OpenPush.onLog("custom event — empty idempotency key ignored; a fresh one was minted")
        }
        CustomEvents.shared.track(
            name: name, properties: properties,
            idempotencyKey: clean.isEmpty ? UUID().uuidString : clean)
    }
}

extension OpenPush {
    final class CustomEvents: @unchecked Sendable {
        static let shared = CustomEvents()

        /// Exactly the characters the server's `^[a-zA-Z0-9_\-. ]+$` admits —
        /// ASCII only, so a name the client accepts can never be one the server
        /// refuses. Written out rather than derived from `CharacterSet`, whose
        /// `alphanumerics` is the whole of Unicode and would let an accented or
        /// CJK name through to a 4xx.
        static let allowedNameCharacters: Set<Character> = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. ")
        private let lock = NSLock()
        private var loadedKey: String?
        private var pending: [[String: Any]] = []
        private var flushWork: ScheduledWork?
        private var retryWork: ScheduledWork?
        private var inFlightKey: String?
        /// How many rows the request in flight carries, so an eviction made
        /// while it is out never removes a row the response will settle.
        private var inFlightCount = 0
        /// The attempt the next failed send counts as. Reset by an accepted
        /// send and by every accepted registration, which proves the network
        /// is back.
        private var attempt = 1
        /// The cap is logged once per process, not once per evicted event.
        private var capLogged = false

        /// The most events kept on the device. A new event past it evicts the
        /// oldest queued one. A larger queue written by an earlier build is
        /// never trimmed on load; it only stops growing and drains as it sends.
        static let queueCap = 500

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        private func storageKey(_ config: OpenPushConfiguration) -> String {
            config.tokenKey + ".customEvents"
        }

        private func load(_ config: OpenPushConfiguration) {
            withLock {
                let key = storageKey(config)
                guard loadedKey != key else { return }
                flushWork?.cancel(); retryWork?.cancel()
                flushWork = nil; retryWork = nil; inFlightKey = nil
                inFlightCount = 0; attempt = 1
                loadedKey = key; pending = []
                guard let text = UserDefaults.standard.string(forKey: key),
                      let data = text.data(using: .utf8),
                      let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return }
                pending = rows
            }
        }

        private func persistLocked() {
            guard let key = loadedKey else { return }
            if pending.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else if let data = try? JSONSerialization.data(withJSONObject: pending),
                      let text = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(text, forKey: key)
            }
        }

        func track(name: String, properties: [String: Any], idempotencyKey: String) {
            guard let config = OpenPush.state.config else {
                OpenPush.onLog("custom event dropped — initialize OpenPush first")
                return
            }
            load(config)
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // `allowedNameCharacters` spells out the server's event-name rule
            // character for character, so the two sets are
            // identical by construction: a name this accepts is a name the
            // server accepts. Refusing here means the host hears about a typo
            // at the call site instead of losing a whole batch to a 4xx later.
            guard !clean.isEmpty, clean.count <= 128,
                  clean.allSatisfy({ Self.allowedNameCharacters.contains($0) }) else {
                OpenPush.onLog("custom event dropped — name must match ^[a-zA-Z0-9_\\-. ]+$ (ASCII letters, digits, space, underscore, hyphen, dot) and be at most 128 characters")
                return
            }
            guard JSONSerialization.isValidJSONObject(properties),
                  let encoded = try? JSONSerialization.data(withJSONObject: properties),
                  encoded.count <= 2_048 else {
                OpenPush.onLog("custom event '\(clean)' dropped — properties must be JSON and at most 2048 bytes")
                return
            }
            // The key is persisted with the event, not minted at send time, so
            // every attempt at this row carries the key the call was given.
            var event: [String: Any] = ["name": clean, "properties": properties,
                                        "timestamp": Date().timeIntervalSince1970,
                                        "idempotency_key": idempotencyKey]
            if let externalID = OpenPush.User.externalId { event["external_id"] = externalID }
            else if let subscriptionID = OpenPush.state.currentSubscriptionID {
                event["subscription_id"] = subscriptionID
            }
            let evicted: Bool = withLock {
                // Never a row of the batch in flight: its response removes rows
                // from the head by count.
                let protected = inFlightKey != nil ? min(inFlightCount, pending.count) : 0
                var evicted = false
                if pending.count >= Self.queueCap, pending.count > protected {
                    pending.remove(at: protected)
                    evicted = true
                }
                pending.append(event)
                persistLocked()
                guard evicted, !capLogged else { return false }
                capLogged = true
                return true
            }
            if evicted {
                OpenPush.onLog("custom events — the queue holds \(Self.queueCap) unsent events, " +
                               "so the oldest is dropped for each new one (logged once)")
            }
            schedule(after: OpenPush.writeCoalescingWindow)
        }

        func registrationCompleted() {
            guard let config = OpenPush.state.config else { return }
            load(config)
            // A held queue gets a fresh set of retries once the server answers
            // again. A retry already waiting keeps its slot.
            withLock { attempt = 1 }
            schedule(after: 0)
        }

        /// Only the workspace being left has its queue erased. The two keys are
        /// the same string unless the host gave each workspace one of its own,
        /// and where it did, the events the workspace being entered queued
        /// before are still its own to send.
        func workspaceSwitched(previousTokenKey: String?) {
            withLock {
                flushWork?.cancel()
                retryWork?.cancel()
                flushWork = nil
                retryWork = nil
                inFlightKey = nil
                inFlightCount = 0
                attempt = 1
                loadedKey = nil
                pending = []
                if let previousTokenKey {
                    UserDefaults.standard.removeObject(
                        forKey: previousTokenKey + ".customEvents")
                }
            }
        }

        func resetForTests() {
            withLock {
                flushWork?.cancel()
                retryWork?.cancel()
                flushWork = nil
                retryWork = nil
                inFlightKey = nil
                inFlightCount = 0
                attempt = 1
                capLogged = false
                loadedKey = nil
                pending = []
            }
        }

        var pendingCount: Int { withLock { pending.count } }

        private func schedule(after seconds: Double) {
            // Read before this class's lock is taken, never under it: the seam
            // takes `State`'s lock, and `attach` holds `State`'s lock while it
            // decides a workspace switch. Nesting them in both orders is a
            // deadlock, and this is the side that gives way.
            let scheduler = OpenPush.state.schedulerSeam
            let due: Bool = withLock {
                guard !pending.isEmpty, flushWork == nil, retryWork == nil,
                      inFlightKey == nil else { return false }
                return true
            }
            guard due else { return }
            let work = scheduler.run(seconds) { [weak self] in self?.flush() }
            withLock { if flushWork == nil { flushWork = work } }
        }

        private func flush() {
            let claimed: (String?, [[String: Any]]) = withLock {
                flushWork?.cancel(); flushWork = nil
                guard inFlightKey == nil else { return (nil, []) }
                inFlightKey = loadedKey
                let batch = Array(pending.prefix(50))
                inFlightCount = batch.count
                return (loadedKey, batch)
            }
            let batchKey = claimed.0
            let snapshot = claimed.1
            guard !snapshot.isEmpty, let config = OpenPush.state.config else {
                withLock { if inFlightKey == batchKey { inFlightKey = nil } }
                return
            }
            let externalID = OpenPush.User.externalId
            let subscriptionID = OpenPush.state.currentSubscriptionID
            guard externalID != nil || subscriptionID != nil else {
                withLock { if inFlightKey == batchKey { inFlightKey = nil } }
                OpenPush.onLog("custom events held — register or log in before they can be attributed")
                return
            }
            let batch = snapshot.map { stored -> [String: Any] in
                var event = stored
                if event["external_id"] == nil && event["subscription_id"] == nil {
                    if let externalID { event["external_id"] = externalID }
                    else if let subscriptionID { event["subscription_id"] = subscriptionID }
                }
                return event
            }
            let batchCount = batch.count
            // Custom events have no background hook of their own: the coalescing
            // window expires wherever the app happens to be, which is routinely
            // just after it was backgrounded. Without an assertion the process can
            // be suspended mid-request and the batch is replayed on the next launch.
            let assertion = OpenPush.backgroundAssertion
            let handle = assertion.begin("openpush.events")
            OpenPush.post("/v1/apps/\(config.appID)/events", ["events": batch]) {
                [weak self] code, _ in
                defer { assertion.end(handle) }
                // Always taken, so a header is never spent on another request.
                let retryAfter = OpenPush.lastRetryAfter.take()
                guard let self else { return }
                if (200...299).contains(code) {
                    let accepted = self.withLock {
                        guard self.loadedKey == batchKey,
                              self.inFlightKey == batchKey else { return false }
                        self.pending.removeFirst(min(batchCount, self.pending.count))
                        self.persistLocked()
                        self.inFlightKey = nil
                        self.inFlightCount = 0
                        self.attempt = 1
                        return true
                    }
                    guard accepted else { return }
                    OpenPush.onLog("✓ custom events sent (\(batchCount))")
                    self.schedule(after: 0)
                } else if (400...499).contains(code) && code != 429 {
                    // 429 is a wait, not a refusal. Every other 4xx says this
                    // batch will never be accepted — a name the server rejects,
                    // a malformed property — and retrying it every two seconds
                    // would wedge every later event behind it forever. The same
                    // reasoning, and the same handling, as `ReceiptQueue`.
                    let dropped = self.withLock { () -> Bool in
                        guard self.loadedKey == batchKey,
                              self.inFlightKey == batchKey else { return false }
                        self.pending.removeFirst(min(batchCount, self.pending.count))
                        self.persistLocked()
                        self.inFlightKey = nil
                        self.inFlightCount = 0
                        return true
                    }
                    guard dropped else { return }
                    OpenPush.onLog("✗ custom events dropped (\(code)) — the server " +
                                   "refused this batch (\(batchCount)); it is not retried")
                    // Whatever the refusal was about, it was about this batch:
                    // anything queued behind it still gets its turn.
                    self.schedule(after: 0)
                } else {
                    // 5xx, 429 and transport failures: back off on the shared
                    // retry schedule (jittered, honouring Retry-After up to its
                    // cap). Once the schedule is spent the queue is held, with no
                    // timer, until the next event or accepted registration.
                    let decision: (current: Bool, attempt: Int) = self.withLock {
                        guard self.loadedKey == batchKey,
                              self.inFlightKey == batchKey else { return (false, 0) }
                        self.inFlightKey = nil
                        self.inFlightCount = 0
                        let attempt = self.attempt
                        self.attempt += 1
                        return (true, attempt)
                    }
                    guard decision.current else { return }
                    guard let delay = OpenPush.retryDelay(afterAttempt: decision.attempt,
                                                          code: code,
                                                          retryAfter: retryAfter) else {
                        OpenPush.onLog("✗ custom events failed (\(code)); kept, and sent with " +
                                       "the next event or registration")
                        return
                    }
                    OpenPush.onLog("✗ custom events failed (\(code)); retained for retry in " +
                                   "\(Int(delay.rounded()))s")
                    let retry = OpenPush.state.schedulerSeam.run(delay) { [weak self] in
                        guard let self else { return }
                        self.withLock { self.retryWork = nil }
                        self.schedule(after: 0)
                    }
                    self.withLock {
                        if self.retryWork == nil { self.retryWork = retry }
                        else { retry.cancel() }
                    }
                }
            }
        }
    }
}
