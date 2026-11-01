import Foundation

/// The one place an email address is checked before it travels.
///
/// Surrounding whitespace is trimmed and the address lower-cased, the spelling
/// the server stores. What is left must be at most 254 characters with exactly
/// one `@`, a non-empty part before it, and a dot in the domain after it.
/// Anything else is refused here, where the app can still see why. The refusal
/// never repeats the address: it reaches logs.
enum OpenPushEmailAddress {
    static let maximumLength = 254

    static func normalized(_ raw: String) throws(OpenPushVerifyError) -> String {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { throw invalid(because: "it is empty") }
        guard address.count <= maximumLength else {
            throw invalid(because: "it is longer than \(maximumLength) characters")
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw invalid(because: "it must have exactly one @") }
        guard !parts[0].isEmpty else { throw invalid(because: "nothing comes before the @") }
        guard parts[1].contains(".") else {
            throw invalid(because: "the domain after the @ has no dot")
        }
        return address
    }

    private static func invalid(because reason: String) -> OpenPushVerifyError {
        OpenPushVerifyError(code: .invalidEmail, message: "not an email address — \(reason)")
    }
}
