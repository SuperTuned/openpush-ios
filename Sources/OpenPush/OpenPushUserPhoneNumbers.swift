import Foundation

public extension OpenPush.User {
    /// Add `number` as this user's SMS number. Returns `true` when the number is
    /// valid and the write was queued.
    ///
    /// The number is read the way the server reads it: every character that is
    /// not a digit or `+` is removed, a leading `00` becomes `+`, and the result
    /// must be `+` and 8 to 15 digits not starting with `0` — so
    /// `+1 (415) 555-0123` is `+14155550123`. An invalid number, or a call before
    /// `initialize`, returns `false` with a log line and sends nothing. A new
    /// number is added **not verified**: it receives nothing until a phone code
    /// sent to it through `OpenPush.Verify` is approved. The write is persisted
    /// and retried like tag writes, and the logged-in user at the time of the
    /// call owns it.
    @discardableResult
    static func addSms(_ number: String) -> Bool { writeAddress(number, on: .sms, .add) }

    /// Opt `number` out of SMS. The number stays on the user; the server stops
    /// sending to it. Returns `false` on the same terms as `addSms(_:)`.
    @discardableResult
    static func removeSms(_ number: String) -> Bool { writeAddress(number, on: .sms, .remove) }

    /// Add `number` as this user's WhatsApp number, on the same terms as
    /// `addSms(_:)`.
    @discardableResult
    static func addWhatsApp(_ number: String) -> Bool { writeAddress(number, on: .whatsapp, .add) }

    /// Opt `number` out of WhatsApp, on the same terms as `removeSms(_:)`.
    @discardableResult
    static func removeWhatsApp(_ number: String) -> Bool {
        writeAddress(number, on: .whatsapp, .remove)
    }
}
