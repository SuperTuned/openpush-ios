import Foundation

/// How this SDK names itself on the wire, in one place.
///
/// The app and a Notification Service Extension are separate processes built
/// from separate modules, and both send requests. Keeping the version and the
/// header spellings here is what stops an extension's receipts from claiming a
/// different client version — or a different header name — than the app's own
/// requests.
///
/// `OpenPush.sdkVersion` forwards to `current`; that public spelling is the one
/// hosts read, and it does not change.
public enum OpenPushSDKVersion {
    /// Bumped by a release, together with the newest CHANGELOG heading.
    public static let current = "1.2.2"

    /// `X-OP-SDK`, on every request the SDK makes from either process.
    public static let headerField = "X-OP-SDK"

    /// `X-OP-SDK-Wrapper`, present only when OpenPush is embedded in a wrapper
    /// SDK. The value is the wrapper's own `"<name>/<version>"`.
    public static let wrapperHeaderField = "X-OP-SDK-Wrapper"

    /// The value `headerField` carries.
    public static let headerValue = "openpush/ios/" + current
}
