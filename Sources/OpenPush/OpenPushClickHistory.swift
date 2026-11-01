import Foundation

/// The taps this install has already handled, so one message never runs its
/// click handling twice.
///
/// A push can reach the device twice: the server resends one whose first send
/// had an ambiguous outcome, and iOS can hand the same response to the app more
/// than once. iOS draws an alert push itself, so the SDK cannot drop the second
/// copy before it is shown — but it can make sure a tap on it is not a second
/// open. Listeners, the `clicked` receipt, and whatever a listener opens run once
/// per key.
///
/// The key is the message alone, whatever the action. iOS forwards at most one
/// response for a delivered notification — a body tap or any action button
/// dismisses it — so a second response for the same message, even with a
/// different action, is a tap on another copy of it. A history that cannot
/// read its storage throws, and the caller handles the tap anyway — a repeat
/// that slips through is a smaller failure than a first tap that is swallowed.
protocol OpenPushClickHistory: Sendable {
    /// Whether `key` is already recorded. Reading only: nothing is written.
    func contains(_ key: String, at now: Date) throws -> Bool

    /// Records `key` and answers whether it was new. `false` means the tap was
    /// handled before and must not run again. Check and record are one step, so
    /// two taps racing on the same key cannot both be told they are first.
    func recordIfNew(_ key: String, at now: Date) throws -> Bool
}

extension OpenPush.Notifications {
    /// The history key of one tap: the message id. The action is deliberately
    /// not part of it — see `OpenPushClickHistory`.
    static func clickKey(messageId: String) -> String { messageId }
}

/// The production history: one dictionary of key → first-handled time in
/// `UserDefaults.standard`, under a key of its own rather than one derived from
/// the configuration's `tokenKey`. A tap that cold-starts the app can arrive
/// before `initialize`, and it still has to be recognised; message ids are
/// unique across workspaces, so there is nothing to keep apart.
///
/// Bounded twice over, because it is persisted on every tap: entries older than
/// `retention` are dropped, and past `limit` the oldest go. A resend follows
/// its original within minutes, so a week is generous.
///
/// Modelled on `ReceiptQueue`: `@unchecked Sendable` with one non-recursive
/// `NSLock`, held across the read-modify-write so concurrent taps settle in
/// order.
final class OpenPushUserDefaultsClickHistory: OpenPushClickHistory, @unchecked Sendable {
    static let storageKey = "openpush.handledClicks"
    static let defaultLimit = 200
    static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let retention: TimeInterval

    init(defaults: UserDefaults = .standard,
         key: String = OpenPushUserDefaultsClickHistory.storageKey,
         limit: Int = OpenPushUserDefaultsClickHistory.defaultLimit,
         retention: TimeInterval = OpenPushUserDefaultsClickHistory.defaultRetention) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.retention = retention
    }

    func contains(_ clickKey: String, at now: Date) -> Bool {
        withLock { live(at: now)[clickKey] != nil }
    }

    func recordIfNew(_ clickKey: String, at now: Date) -> Bool {
        withLock {
            var entries = live(at: now)
            guard entries[clickKey] == nil else { return false }
            entries[clickKey] = now.timeIntervalSince1970
            let overflow = entries.count - limit
            if overflow > 0 {
                let oldest = entries.sorted { $0.value < $1.value }.prefix(overflow)
                for (stale, _) in oldest { entries[stale] = nil }
            }
            defaults.set(entries, forKey: key)
            return true
        }
    }

    /// The stored entries still inside the retention window. A value that is
    /// not the dictionary this class writes is treated as empty and is replaced
    /// on the next record: the history fails open rather than staying stuck on
    /// a value it cannot read.
    private func live(at now: Date) -> [String: TimeInterval] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        let horizon = now.timeIntervalSince1970 - retention
        var entries: [String: TimeInterval] = [:]
        for (clickKey, value) in stored {
            guard let handledAt = (value as? NSNumber)?.doubleValue,
                  handledAt > horizon else { continue }
            entries[clickKey] = handledAt
        }
        return entries
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
