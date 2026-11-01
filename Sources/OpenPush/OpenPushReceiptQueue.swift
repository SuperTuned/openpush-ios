import Foundation
import OpenPushCore

extension OpenPush {
    /// Delivery receipts, kept until the server has them.
    ///
    /// A receipt is the only evidence a message arrived, and it is posted from the
    /// least reliable moment in the app's life — a push waking a process that may
    /// be offline, unregistered, or about to be suspended. Holding it in memory
    /// loses it on the next launch and re-sends it on the one after, so the queue
    /// is persisted twice over: the unsent items under `tokenKey + ".receipts"`,
    /// and a bounded ring of the ids already accepted under
    /// `tokenKey + ".receiptsSent"`, which is what keeps a relaunch from
    /// reporting the same delivery twice.
    ///
    /// Both stores are bounded, because both are persisted: a device that spends
    /// a month offline under a firehose of pushes must not grow one UserDefaults
    /// string without limit, and the backlog it does keep goes out in batches
    /// rather than as one request per receipt.
    ///
    /// Modelled on `CustomEvents`: `@unchecked Sendable` with one non-recursive
    /// `NSLock`, keyed by token key so a workspace switch cannot leak one
    /// workspace's receipts into another, and retried through the scheduler seam
    /// so tests drive the clock.
    final class ReceiptQueue: @unchecked Sendable {
        static let shared = ReceiptQueue()

        /// Waits between automatic attempts. After the last one nothing is
        /// dropped — the items simply stay queued for the next `drain()`, which
        /// is a foreground or a completed registration.
        static let retryDelays: [Double] = [2, 8, 30]

        /// How many accepted ids the dedupe ring remembers. Bounded because it is
        /// persisted and a long-lived install would otherwise grow it forever.
        static let sentLimit = 500

        /// How many unsent receipts the queue keeps. The same bound and the same
        /// reason as the sent ring: past this the oldest are dropped, because a
        /// backlog no server will ever be shown is only a growing write on every
        /// receipt.
        static let pendingLimit = 500

        /// How many receipts ride in one `/v1/ingest` request. The contract's
        /// `events` array already carries a list, so a backlog costs a few
        /// requests instead of one per item.
        static let batchSize = 50

        /// The key of the one shared retry timer. A receipt identifier is
        /// `type|message_id`, so a key that is neither cannot collide with one.
        private static let drainRetryKey = "\u{0}drain"

        /// One scheduled retry. The scheduler may run the work before `run` has
        /// returned its handle, so the slot is registered *before* scheduling and
        /// the closure marks it spent: a handle that arrives after that is
        /// cancelled instead of being parked where a dead entry would suppress
        /// every later timer. Every field is read and written under the queue's
        /// lock, which is what makes the unchecked conformance true.
        private final class RetrySlot: @unchecked Sendable {
            var work: ScheduledWork?
            var spent = false
        }

        private let lock = NSLock()
        private var loadedTokenKey: String?
        private var pending: [[String: Any]] = []
        private var sent: [String] = []
        private var inFlight = Set<String>()
        private var retrySlots: [String: RetrySlot] = [:]

        static func storageKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".receipts"
        }

        static func sentKey(forTokenKey tokenKey: String) -> String {
            tokenKey + ".receiptsSent"
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        /// The dedupe key: one receipt is one type reported for one message.
        private static func identifier(type: String, messageID: String) -> String {
            "\(type)|\(messageID)"
        }

        private static func identifier(_ row: [String: Any]) -> String {
            identifier(type: (row["type"] as? String) ?? "",
                       messageID: (row["message_id"] as? String) ?? "")
        }

        /// How many receipts are still owed to the server. Reads through to the
        /// persisted queue so a caller on a fresh launch sees the real number.
        var pendingCount: Int {
            guard let config = OpenPush.state.config else { return 0 }
            load(config)
            return withLock { pending.count }
        }

        private func load(_ config: OpenPushConfiguration) {
            let stale: [ScheduledWork] = withLock {
                guard loadedTokenKey != config.tokenKey else { return [] }
                let cancelled = clearRetriesLocked()
                inFlight.removeAll()
                loadedTokenKey = config.tokenKey
                pending = Self.storedRows(
                    forKey: Self.storageKey(forTokenKey: config.tokenKey))
                sent = Self.storedIdentifiers(
                    forKey: Self.sentKey(forTokenKey: config.tokenKey))
                return cancelled
            }
            // Never under the lock: cancelling reaches into the scheduler, which
            // takes a lock of its own.
            stale.forEach { $0.cancel() }
        }

        private static func storedRows(forKey key: String) -> [[String: Any]] {
            guard let text = UserDefaults.standard.string(forKey: key),
                  let data = text.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return rows
        }

        private static func storedIdentifiers(forKey key: String) -> [String] {
            guard let text = UserDefaults.standard.string(forKey: key),
                  let data = text.data(using: .utf8),
                  let ids = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return [] }
            return ids
        }

        private func persistLocked() {
            guard let tokenKey = loadedTokenKey else { return }
            write(pending, forKey: Self.storageKey(forTokenKey: tokenKey),
                  isEmpty: pending.isEmpty)
            write(sent, forKey: Self.sentKey(forTokenKey: tokenKey), isEmpty: sent.isEmpty)
        }

        private func write(_ value: Any, forKey key: String, isEmpty: Bool) {
            if isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else if let data = try? JSONSerialization.data(withJSONObject: value),
                      let text = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(text, forKey: key)
            }
        }

        /// Empties the slot table and hands back the handles to cancel, which the
        /// caller must do outside the lock. A slot whose handle has not arrived
        /// yet is marked spent, so the handle is cancelled where it is assigned.
        private func clearRetriesLocked() -> [ScheduledWork] {
            let slots = Array(retrySlots.values)
            retrySlots.removeAll()
            return slots.compactMap { slot in
                slot.spent = true
                let work = slot.work
                slot.work = nil
                return work
            }
        }

        private enum Admission {
            case queued(evicted: Int), alreadyQueued, alreadySent
        }

        /// Records one receipt. It is posted immediately when there is a token to
        /// report against, and kept until the server accepts it or refuses it.
        ///
        /// `then` fires exactly once per call and never waits past this call's own
        /// outcome: at once when there is nothing to send (no configuration, no
        /// message id, a duplicate, or no token yet), and otherwise when the
        /// response says the receipt was accepted, dropped, or queued for retry.
        /// A caller is told what happened to its call; it is not left waiting on a
        /// retry that may only complete in a later process.
        func enqueue(type: String, messageID: String?, then: (@Sendable () -> Void)?) {
            guard let config = OpenPush.state.config,
                  let messageID, !messageID.isEmpty else { then?(); return }
            load(config)
            let identifier = Self.identifier(type: type, messageID: messageID)
            let admission: Admission = withLock {
                if sent.contains(identifier) { return .alreadySent }
                if pending.contains(where: { Self.identifier($0) == identifier }) {
                    return .alreadyQueued
                }
                pending.append(["type": type, "message_id": messageID, "attempts": 0])
                let evicted = max(0, pending.count - Self.pendingLimit)
                if evicted > 0 { pending.removeFirst(evicted) }
                persistLocked()
                return .queued(evicted: evicted)
            }
            switch admission {
            case .alreadySent:
                OpenPush.onLog("• \(type) receipt for \(messageID) was already accepted — not sent again")
                then?()
            case .alreadyQueued:
                then?()
            case .queued(let evicted):
                if evicted > 0 {
                    OpenPush.onLog("✗ receipt queue full — dropped the \(evicted) oldest " +
                                   "unsent receipt(s); it holds \(Self.pendingLimit)")
                }
                send(identifiers: [identifier], then: then)
            }
        }

        /// Sends everything still owed, in batches. Called when a registration
        /// completes and on every foreground, which is what picks up an item whose
        /// retries ran out.
        func drain() {
            guard let config = OpenPush.state.config else { return }
            load(config)
            guard OpenPush.currentToken != nil else { return }
            let due: [String] = withLock {
                pending.map(Self.identifier).filter { !inFlight.contains($0) }
            }
            for start in stride(from: 0, to: due.count, by: Self.batchSize) {
                let end = min(start + Self.batchSize, due.count)
                send(identifiers: Array(due[start..<end]), then: nil)
            }
        }

        func registrationCompleted() {
            drain()
        }

        /// Only the workspace being left has its receipts erased. Where the host
        /// gave each workspace a token key of its own, the delivery evidence the
        /// workspace being entered has not yet posted is still owed to it.
        func workspaceSwitched(previousTokenKey: String?) {
            let stale: [ScheduledWork] = withLock {
                let cancelled = clearRetriesLocked()
                inFlight.removeAll()
                loadedTokenKey = nil
                pending = []
                sent = []
                if let previousTokenKey {
                    UserDefaults.standard.removeObject(
                        forKey: Self.storageKey(forTokenKey: previousTokenKey))
                    UserDefaults.standard.removeObject(
                        forKey: Self.sentKey(forTokenKey: previousTokenKey))
                }
                return cancelled
            }
            stale.forEach { $0.cancel() }
        }

        /// In-memory only, exactly like `CustomEvents.resetForTests()`: a test that
        /// simulates a relaunch keeps what UserDefaults holds and throws away what
        /// only this process knew.
        func resetForTests() {
            let stale: [ScheduledWork] = withLock {
                let cancelled = clearRetriesLocked()
                inFlight.removeAll()
                loadedTokenKey = nil
                pending = []
                sent = []
                return cancelled
            }
            stale.forEach { $0.cancel() }
        }

        /// One request for one batch of receipts. A batch of one is what `enqueue`
        /// posts, so both paths share every rule below.
        private func send(identifiers: [String], then: (@Sendable () -> Void)?) {
            guard let config = OpenPush.state.config,
                  let token = OpenPush.currentToken else { then?(); return }
            let claimed: (receipts: [(type: String, messageID: String)],
                          ids: [String], tokenKey: String?, stale: [ScheduledWork]) =
                withLock {
                    var receipts: [(type: String, messageID: String)] = []
                    var ids: [String] = []
                    var stale: [ScheduledWork] = []
                    for identifier in identifiers {
                        guard !inFlight.contains(identifier),
                              let row = pending.first(where: {
                                  Self.identifier($0) == identifier
                              })
                        else { continue }
                        inFlight.insert(identifier)
                        ids.append(identifier)
                        receipts.append((type: (row["type"] as? String) ?? "",
                                         messageID: (row["message_id"] as? String) ?? ""))
                        if let slot = retrySlots.removeValue(forKey: identifier) {
                            slot.spent = true
                            if let work = slot.work { stale.append(work) }
                        }
                    }
                    return (receipts, ids, loadedTokenKey, stale)
                }
            claimed.stale.forEach { $0.cancel() }
            guard !claimed.ids.isEmpty else { then?(); return }
            let receipts = claimed.receipts
            let ids = claimed.ids
            let tokenKey = claimed.tokenKey
            let body = OpenPushPayload.receiptBody(receipts: receipts, token: token,
                                                   appID: config.appID)
            // A receipt is routinely posted from a process that is about to be
            // suspended — a background delivery, or a tap that is still being
            // handled as the app goes away. Without an assertion the request dies
            // with the process and the item is replayed on the next launch.
            let assertion = OpenPush.backgroundAssertion
            let handle = assertion.begin("openpush.receipts")
            OpenPush.post("/v1/ingest", body) { [weak self] code, response in
                defer { assertion.end(handle) }
                self?.finish(identifiers: ids, receipts: receipts, tokenKey: tokenKey,
                             code: code, response: response)
                then?()
            }
        }

        /// How a log line names what the request carried: the type for a single
        /// receipt, a count for a batch.
        private static func subject(_ receipts: [(type: String, messageID: String)],
                                    count: Int) -> String {
            receipts.count == 1 ? "\(receipts[0].type) receipt" : "\(count) receipts"
        }

        private func finish(identifiers: [String],
                            receipts: [(type: String, messageID: String)],
                            tokenKey: String?, code: Int, response: String) {
            if (200...299).contains(code) {
                withLock {
                    identifiers.forEach { inFlight.remove($0) }
                    guard loadedTokenKey == tokenKey else { return }
                    let accepted = Set(identifiers)
                    pending.removeAll { accepted.contains(Self.identifier($0)) }
                    sent.removeAll { accepted.contains($0) }
                    sent.append(contentsOf: identifiers)
                    if sent.count > Self.sentLimit {
                        sent.removeFirst(sent.count - Self.sentLimit)
                    }
                    persistLocked()
                }
                return
            }
            // 429 is a wait, not a refusal. Every other 4xx says these receipts
            // will never be accepted — an unknown message, a rejected key — and
            // keeping them would retry them on every foreground for the life of
            // the install.
            if (400...499).contains(code) && code != 429 {
                let dropped = withLock { () -> Int in
                    identifiers.forEach { inFlight.remove($0) }
                    guard loadedTokenKey == tokenKey else { return 0 }
                    let before = pending.count
                    let refused = Set(identifiers)
                    pending.removeAll { refused.contains(Self.identifier($0)) }
                    persistLocked()
                    return before - pending.count
                }
                guard dropped > 0 else { return }
                OpenPush.onLog("✗ \(Self.subject(receipts, count: dropped)) dropped " +
                               "(4xx): \(code) " + OpenPush.boundedLog(response))
                return
            }
            // Every member's own attempt count advances, and the batch waits the
            // shortest delay any of them is still owed — so one long-failing
            // receipt cannot starve a fresh one that rode along with it. The
            // timer stops only when every member has exhausted the table.
            let outcome: (held: Int, delay: Double?) = withLock {
                identifiers.forEach { inFlight.remove($0) }
                guard loadedTokenKey == tokenKey else { return (0, nil) }
                var held = 0
                var lowestAttempts: Int?
                for identifier in identifiers {
                    guard let index = pending.firstIndex(where: {
                        Self.identifier($0) == identifier
                    }) else { continue }
                    let attempts = ((pending[index]["attempts"] as? Int) ?? 0) + 1
                    pending[index]["attempts"] = attempts
                    held += 1
                    lowestAttempts = min(lowestAttempts ?? attempts, attempts)
                }
                guard held > 0 else { return (0, nil) }
                persistLocked()
                guard let lowestAttempts, lowestAttempts <= Self.retryDelays.count
                else { return (held, nil) }
                return (held, Self.retryDelays[lowestAttempts - 1])
            }
            guard outcome.held > 0 else { return }
            OpenPush.onLog("✗ \(Self.subject(receipts, count: outcome.held)) queued " +
                           "for retry (\(code)): " + OpenPush.boundedLog(response))
            // The table is not the last word: when it runs out the items stay
            // queued and the next foreground or registration tries again.
            guard let delay = outcome.delay else { return }
            scheduleDrainRetry(after: delay)
        }

        /// One timer for the whole queue: it re-drains, which re-batches whatever
        /// is due by then. A retry already scheduled is left alone rather than
        /// replaced, so a burst of failures cannot stack up timers.
        private func scheduleDrainRetry(after delay: Double) {
            let key = Self.drainRetryKey
            let slot = RetrySlot()
            let registered: Bool = withLock {
                guard retrySlots[key] == nil else { return false }
                retrySlots[key] = slot
                return true
            }
            guard registered else { return }
            let work = OpenPush.state.schedulerSeam.run(delay) { [weak self] in
                guard let self else { return }
                self.withLock {
                    slot.spent = true
                    if self.retrySlots[key] === slot { self.retrySlots.removeValue(forKey: key) }
                }
                self.drain()
            }
            // The slot was registered before the work existed, so a closure that
            // already ran leaves nothing behind: this handle is cancelled instead
            // of being stored where it would block the next timer.
            let dead: ScheduledWork? = withLock {
                guard !slot.spent else { return work }
                slot.work = work
                return nil
            }
            dead?.cancel()
        }
    }
}

public extension OpenPush {
    /// How many delivery receipts are still owed to the server from this process.
    ///
    /// Hosts put this on a diagnostics screen: a number that stays above zero is
    /// the visible form of receipts that are failing, where the queue's whole
    /// point is that a failure is not lost. It reads through to the persisted
    /// queue, so a fresh launch reports what the last one left behind rather than
    /// zero, and it is `0` before `initialize`. It never exceeds
    /// `ReceiptQueue.pendingLimit`, the bound past which the oldest unsent
    /// receipts are dropped. An extension's receipts are in another process and
    /// are not counted here.
    static var pendingReceiptCount: Int { ReceiptQueue.shared.pendingCount }
}
