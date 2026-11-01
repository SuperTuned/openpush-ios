import Foundation

public extension OpenPush.User {
    /// Add `address` as this user's email address. Returns `true` when the
    /// address is valid and the write was queued.
    ///
    /// The address is trimmed and lower-cased, and must then be at most 254
    /// characters with one `@`, something before it and a dot in the domain.
    /// An invalid address, or a call before `initialize`, returns `false` with a
    /// log line (`invalidEmail`) and sends nothing. The address is subscribed at
    /// once, unless this app's suppression list has it (it unsubscribed, bounced
    /// or complained): then it is stored but never emailed, and the log says so.
    /// The write is persisted and retried like tag writes, and the logged-in
    /// user at the time of the call owns it.
    @discardableResult
    static func addEmail(_ address: String) -> Bool { writeAddress(address, on: .email, .add) }

    /// Remove the subscription for `address`. This is not an unsubscribe: no
    /// suppression is written, and a later `addEmail(_:)` subscribes it again.
    /// Returns `false` on the same terms as `addEmail(_:)`.
    @discardableResult
    static func removeEmail(_ address: String) -> Bool {
        writeAddress(address, on: .email, .remove)
    }
}
