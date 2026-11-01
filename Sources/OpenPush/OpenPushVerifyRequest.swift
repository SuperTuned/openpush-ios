import Foundation

/// The one request path the three `Verify` calls share: same headers and base
/// URL as every other SDK request, a typed error for anything but a readable
/// 2xx.
enum VerifyRequest {
    static func send(path: String, body: [String: String], phoneNumber: String,
                     channel: OpenPushVerifyChannel) async throws(OpenPushVerifyError)
        -> OpenPushVerification {
        guard let config = OpenPush.state.config else {
            throw OpenPushVerifyError(code: .refused,
                                      message: "OpenPush is not initialized — call " +
                                      "initialize before sending a phone code")
        }
        let (status, response) = await post("/v1/apps/\(config.appID)/\(path)", body)
        guard (200...299).contains(status) else {
            let error = OpenPushVerifyError.from(status: status, body: response)
            OpenPush.onLog("✗ phone code request failed (\(status)): \(error)")
            throw error
        }
        guard let verification = OpenPushVerification.decode(
            response, phoneNumber: phoneNumber, requestedChannel: channel) else {
            throw OpenPushVerifyError(code: .network,
                                      message: "the server's answer could not be read: " +
                                      OpenPush.boundedLog(response))
        }
        OpenPush.onLog("• phone code \(verification.id) is \(verification.status.rawValue)")
        return verification
    }

    /// A verification id goes into the path, so a stray `/` or `?` in one must
    /// not change which endpoint is called.
    static func pathComponent(_ id: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private static func post(_ path: String,
                             _ body: [String: String]) async -> (Int, String) {
        await withCheckedContinuation { continuation in
            OpenPush.post(path, body) { status, response in
                continuation.resume(returning: (status, response))
            }
        }
    }
}
