import Foundation

/// Why a phone-code call, a phone number or an email address was refused.
///
/// `code` is what to switch on; `message` is the server's own sentence when it
/// sent one, and the SDK's otherwise, fit to log but not written for end users.
public struct OpenPushVerifyError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable, CaseIterable {
        /// Too many codes for this number or this app in the server's window.
        case rateLimited = "rate_limited"
        /// A resend inside 30 seconds of the last send.
        case tooSoon = "too_soon"
        /// The verification is no longer pending: approved, expired, or out of
        /// attempts. Start a new one.
        case notPending = "not_pending"
        /// The SMS, WhatsApp or voice provider failed to deliver the code.
        case provider
        /// The number replied STOP or was otherwise opted out of texts. Never
        /// retry: the server refuses every code to it until it opts back in.
        case optedOut = "opted_out"
        /// The workspace has no text credit left (HTTP 402).
        case noCredit = "credit"
        /// Texts to this number's country are not priced or not allowed.
        case noRate = "no_rate"
        /// The server refused the request for any other reason — validation, an
        /// unknown verification id, a channel the app has not enabled, or a
        /// refusal code this SDK does not know. Also used when OpenPush has not
        /// been initialized.
        case refused
        /// Once separators are removed, the number is not `+` and 8–15 digits
        /// with a first digit other than `0`. Raised before anything is sent.
        case invalidNumber = "invalid_number"
        /// Once trimmed and lower-cased, the address is not one `@` between a
        /// non-empty local part and a domain with a dot, in at most 254
        /// characters. Raised before anything is sent.
        case invalidEmail = "invalid_email"
        /// No usable answer: the request failed in transport, the server failed
        /// (5xx), or the response could not be read.
        case network
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

extension OpenPushVerifyError {
    /// The error a non-2xx response stands for.
    ///
    /// The server's refusals are `{"detail": {"code", "message"}}`; a validation
    /// failure may carry a plain string `detail` (or a list of them) instead.
    /// A code this SDK does not know is still a refusal, so a newer server
    /// cannot make an older SDK report a transport failure.
    static func from(status: Int, body: String) -> OpenPushVerifyError {
        guard status > 0 else {
            return OpenPushVerifyError(code: .network,
                                       message: body.isEmpty ? "the request failed" : body)
        }
        if (500...599).contains(status) {
            return OpenPushVerifyError(code: .network,
                                       message: "the server failed (\(status))")
        }
        let detail = Self.detail(in: body)
        let code = detail.code.flatMap(Code.init(rawValue:)) ?? Self.fallbackCode(status)
        let message = detail.message ?? "the server refused the request (\(status))"
        return OpenPushVerifyError(code: code, message: message)
    }

    /// Without a code in the body, a 429 is still a rate limit.
    private static func fallbackCode(_ status: Int) -> Code {
        status == 429 ? .rateLimited : .refused
    }

    private static func detail(in body: String) -> (code: String?, message: String?) {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        switch payload["detail"] {
        case let object as [String: Any]:
            return (object["code"] as? String, object["message"] as? String)
        case let text as String:
            return (nil, text)
        case let list as [[String: Any]]:
            let messages = list.compactMap { $0["msg"] as? String }
            return (nil, messages.isEmpty ? nil : messages.joined(separator: "; "))
        default:
            return (nil, nil)
        }
    }
}
