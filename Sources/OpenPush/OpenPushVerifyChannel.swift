import Foundation

/// How a phone code reaches the person.
public enum OpenPushVerifyChannel: String, Sendable, Equatable, CaseIterable {
    /// The server picks among the channels the app has enabled.
    case auto
    case sms
    case whatsapp
    /// A voice call that reads the code out.
    case call
}
