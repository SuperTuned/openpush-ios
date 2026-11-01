import Foundation

/// One phone code in flight, as the server last described it.
///
/// Pass it back to `OpenPush.Verify.check` and `resend`. It carries the full
/// number for those calls in memory only: it is not `Codable` and the SDK never
/// stores it, so the number goes no further than the value the app holds.
public struct OpenPushVerification: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable, CaseIterable {
        /// Sent and waiting for a code — also what a wrong code leaves behind.
        case pending
        /// The code matched. The number's SMS and WhatsApp subscriptions are
        /// now subscribed on the server.
        case approved
        case expired
        /// Too many wrong codes. Start a new verification.
        case maxAttempts = "max_attempts"
    }

    /// The server's verification id (`vf_…`).
    public let id: String
    /// The number as the server shows it, with the middle digits hidden.
    public let maskedNumber: String
    public let channel: OpenPushVerifyChannel
    public let status: Status
    /// Codes checked so far.
    public let attempts: Int
    /// When the code stops being accepted; `nil` if the server did not say.
    public let expiresAt: Date?
    /// The E.164 number the code was sent to. In memory only.
    let phoneNumber: String

    init(id: String, maskedNumber: String, channel: OpenPushVerifyChannel, status: Status,
         attempts: Int, expiresAt: Date?, phoneNumber: String) {
        self.id = id
        self.maskedNumber = maskedNumber
        self.channel = channel
        self.status = status
        self.attempts = attempts
        self.expiresAt = expiresAt
        self.phoneNumber = phoneNumber
    }
}

extension OpenPushVerification {
    /// Reads a 2xx body. The server masks `to`, so the full number comes from
    /// the request; a channel this SDK does not know falls back to the one asked
    /// for. A missing id or an unknown status is unreadable, not a guess.
    static func decode(_ body: String, phoneNumber: String,
                       requestedChannel: OpenPushVerifyChannel) -> OpenPushVerification? {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty,
              let statusText = payload["status"] as? String,
              let status = Status(rawValue: statusText) else { return nil }
        let channel = (payload["channel"] as? String).flatMap(OpenPushVerifyChannel.init)
        return OpenPushVerification(
            id: id,
            maskedNumber: payload["to"] as? String ?? "",
            channel: channel ?? requestedChannel,
            status: status,
            attempts: (payload["attempts"] as? NSNumber)?.intValue ?? 0,
            expiresAt: OpenPushTimestamp.date(from: payload["expires_at"]),
            phoneNumber: phoneNumber)
    }
}
