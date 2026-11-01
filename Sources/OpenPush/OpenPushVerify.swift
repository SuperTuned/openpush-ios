import Foundation

public extension OpenPush {
    /// Phone codes: send a one-time code to a number, then check what the person
    /// typed. An approved code marks the number's SMS and WhatsApp subscriptions
    /// subscribed on the server, which is the only way they become subscribed.
    ///
    /// Each call is one request and is not retried: the person is waiting on
    /// the answer, so a failure is thrown as an `OpenPushVerifyError` for the
    /// app to show or retry. Give the code field `.oneTimeCode` as its text
    /// content type and iOS offers an SMS code from the keyboard.
    enum Verify {
        /// Send a code to `phone`. The number is normalised first, exactly as
        /// `User.addSms(_:)` does it, and an invalid one throws
        /// `invalidNumber` without a request. `locale` picks the message's
        /// language, such as `"en"`; `nil` leaves it to the server.
        public static func start(_ phone: String, channel: OpenPushVerifyChannel = .auto,
                                 locale: String? = nil) async throws -> OpenPushVerification {
            let number = try OpenPushPhoneNumber.normalized(phone)
            var body: [String: String] = ["to": number, "channel": channel.rawValue]
            if let locale = locale?.trimmingCharacters(in: .whitespacesAndNewlines),
               !locale.isEmpty {
                body["locale"] = locale
            }
            return try await VerifyRequest.send(path: "verify", body: body,
                                                phoneNumber: number, channel: channel)
        }

        /// Check the code the person typed. A wrong code comes back `pending`
        /// with `attempts` raised; `approved`, `expired` and `maxAttempts` are
        /// final.
        public static func check(_ verification: OpenPushVerification,
                                 code: String) async throws -> OpenPushVerification {
            let body = ["to": verification.phoneNumber,
                        "code": code.trimmingCharacters(in: .whitespacesAndNewlines)]
            return try await VerifyRequest.send(
                path: "verify/\(VerifyRequest.pathComponent(verification.id))/check",
                body: body, phoneNumber: verification.phoneNumber,
                channel: verification.channel)
        }

        /// Send the code again, on `channel`. The server refuses a resend
        /// within 30 seconds of the last send with `tooSoon`.
        public static func resend(_ verification: OpenPushVerification,
                                  channel: OpenPushVerifyChannel) async throws
            -> OpenPushVerification {
            let body = ["to": verification.phoneNumber, "channel": channel.rawValue]
            return try await VerifyRequest.send(
                path: "verify/\(VerifyRequest.pathComponent(verification.id))/resend",
                body: body, phoneNumber: verification.phoneNumber, channel: channel)
        }
    }
}
