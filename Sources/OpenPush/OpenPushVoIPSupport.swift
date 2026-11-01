import Foundation
import OpenPushCore

/// What the `OpenPushVoIP` product needs from this module, and nothing else.
///
/// It is SPI rather than public: a host has no use for these, and they exist only
/// so the separate VoIP product — kept apart so an app without calls never links
/// PushKit — talks to the server through the same request path, SDK key, device
/// credential and identifying headers as every other request this SDK makes.
@_spi(OpenPushVoIP)
public extension OpenPush {
    /// The configured app id, or nil before `initialize`.
    static var voipAppID: String? { state.config?.appID }

    /// The signed APNs environment of this build: true for a development
    /// (sandbox) profile, false for production — including App Store builds, which
    /// carry no embedded profile at all.
    static var voipSandbox: Bool {
        sandboxFlag(forAPNsEnvironment: cachedAPNsEnvironment) ?? false
    }

    /// POSTs `body` to `path` on the configured server, exactly as the SDK's own
    /// requests are sent. `done` gets the HTTP status (-1 when there was none) and
    /// the response body.
    static func voipPost(_ path: String, body: [String: Any],
                         done: @escaping @Sendable (Int, String) -> Void) {
        post(path, body, done: done)
    }
}
