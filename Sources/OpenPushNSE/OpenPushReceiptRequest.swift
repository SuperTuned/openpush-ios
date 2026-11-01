import Foundation
import OpenPushCore

/// Extension-safe request construction. It imports Foundation only and exposes
/// no registration, console-management, or send API.
public enum OpenPushReceiptRequest {
    /// The server authenticates a receipt on the SDK key, so `deviceCredential`
    /// is optional: with nil the `X-OP-Device-Key` header is left off entirely,
    /// never sent empty. Pass the credential when the extension can read it.
    public static func make(configuration: OpenPushConfiguration,
                            deviceCredential: String?,
                            token: String, messageID: String,
                            types: [String],
                            sdkWrapper: String? = nil) -> URLRequest? {
        guard let url = URL(string: configuration.serverURL + "/v1/ingest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.sdkKey, forHTTPHeaderField: "X-OP-SDK-Key")
        if let deviceCredential, !deviceCredential.isEmpty {
            request.setValue(deviceCredential, forHTTPHeaderField: "X-OP-Device-Key")
        }
        // The extension's receipts are the SDK's highest-volume request. They name
        // the same SDK — and the same wrapper — as the app's own, or triage cannot
        // attribute them to a client version at all.
        request.setValue(OpenPushSDKVersion.headerValue,
                         forHTTPHeaderField: OpenPushSDKVersion.headerField)
        if let sdkWrapper, !sdkWrapper.isEmpty {
            request.setValue(sdkWrapper,
                             forHTTPHeaderField: OpenPushSDKVersion.wrapperHeaderField)
        }
        let body = OpenPushPayload.receiptBody(
            types: types, messageID: messageID, token: token,
            appID: configuration.appID)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
