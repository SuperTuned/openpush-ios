import Foundation

/// The one place a phone number is checked before it travels.
///
/// The rules are the server's own (`normalise_e164`), step for step, so a number
/// the client accepts is the number the server stores: every character that is
/// not a digit or `+` is removed, so `+1 (415) 555-0123` is `+14155550123`; a
/// leading `00` then becomes `+`; and what is left must be `+` followed by 8 to
/// 15 digits, the first of which is not `0`. Anything else is refused here,
/// where the app can still see why, rather than sent and refused there. The
/// refusal never repeats the number: it reaches logs.
enum OpenPushPhoneNumber {
    static let minimumDigits = 8
    static let maximumDigits = 15

    static func normalized(_ raw: String) throws(OpenPushVerifyError) -> String {
        var number = raw.filter { $0 == "+" || ($0.isASCII && $0.isNumber) }
        if number.hasPrefix("00") { number = "+" + number.dropFirst(2) }
        guard number.hasPrefix("+") else {
            throw invalid(because: "it must start with + (or 00) and the country code")
        }
        let digits = number.dropFirst()
        guard !digits.contains("+") else {
            throw invalid(because: "only digits may follow the +")
        }
        guard (minimumDigits...maximumDigits).contains(digits.count) else {
            throw invalid(because: "it must have \(minimumDigits) to \(maximumDigits) " +
                          "digits; this one has \(digits.count)")
        }
        guard digits.first != "0" else {
            throw invalid(because: "a country code never starts with 0")
        }
        return number
    }

    private static func invalid(because reason: String) -> OpenPushVerifyError {
        OpenPushVerifyError(code: .invalidNumber,
                            message: "not an E.164 phone number — \(reason)")
    }
}
