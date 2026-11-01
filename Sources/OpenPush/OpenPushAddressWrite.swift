import Foundation

extension OpenPush {
    /// The channels an address can be added on. The raw value is the wire's
    /// `platform`.
    enum AddressChannel: String, Codable, Sendable, Equatable {
        case sms
        case whatsapp
        case email

        /// How a log line names an address on this channel.
        var noun: String {
            switch self {
            case .sms: return "SMS number"
            case .whatsapp: return "WhatsApp number"
            case .email: return "email address"
            }
        }

        /// `raw` in the spelling the server stores, or why it is not an address
        /// on this channel.
        func normalized(_ raw: String) throws(OpenPushVerifyError) -> String {
            switch self {
            case .sms, .whatsapp: return try OpenPushPhoneNumber.normalized(raw)
            case .email: return try OpenPushEmailAddress.normalized(raw)
            }
        }
    }

    /// One add or remove of one address, as queued and persisted until the
    /// server has it.
    struct AddressWrite: Codable, Sendable, Equatable {
        enum Action: String, Codable, Sendable, Equatable {
            case add
            case remove
        }

        let channel: AddressChannel
        /// Already normalised: E.164 for a phone number, trimmed and lower-cased
        /// for an email address.
        let address: String
        let action: Action
        /// The user logged in when the call was made, captured then so a later
        /// login cannot attribute this address to someone else.
        let externalID: String?

        /// One address on one channel: the identity a later write replaces and
        /// the key its subscription id is stored under.
        var key: String { "\(channel.rawValue):\(address)" }

        /// What a log line shows instead of the address: a number's last four
        /// digits, an email address's domain.
        var maskedAddress: String {
            switch channel {
            case .sms, .whatsapp:
                return "•••" + address.suffix(4)
            case .email:
                let domain = address.firstIndex(of: "@").map { String(address[$0...]) }
                return "•••" + (domain ?? "")
            }
        }

        /// The subscription body. A device may only ever send status −2, so an
        /// add carries no `status` at all: the server decides it. That keeps a
        /// new number "Not verified" until a phone code for it is approved, and
        /// subscribes a new email address at once unless it is suppressed. On
        /// email, −2 removes the subscription; it is not an unsubscribe.
        func body(authHash: String?) -> [String: Any] {
            var body: [String: Any] = ["token": address, "platform": channel.rawValue]
            if let externalID {
                body["external_id"] = externalID
                if let authHash { body["external_id_auth_hash"] = authHash }
            }
            if action == .remove { body["status"] = OpenPush.optedOutStatus }
            return body
        }
    }
}

extension OpenPush.User {
    /// The one path every phone number and email address call takes: normalise,
    /// or log why not and send nothing; then queue the write for the user
    /// logged in now.
    static func writeAddress(_ raw: String, on channel: OpenPush.AddressChannel,
                             _ action: OpenPush.AddressWrite.Action) -> Bool {
        let normalized: String
        do {
            normalized = try channel.normalized(raw)
        } catch {
            OpenPush.onLog("✗ \(channel.noun) not \(action == .add ? "added" : "removed")"
                           + " — \(error.message)")
            return false
        }
        return OpenPush.AddressSubscriptions.shared.enqueue(
            OpenPush.AddressWrite(channel: channel, address: normalized, action: action,
                                  externalID: externalId))
    }
}
