import Foundation

/// Server timestamps arrive as ISO 8601 text, with or without fractional
/// seconds (Python writes six digits), or as epoch seconds.
enum OpenPushTimestamp {
    static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let text as String:
            return date(fromISO8601: text)
        default:
            return nil
        }
    }

    static func date(fromISO8601 text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        // Fractional seconds are dropped rather than parsed: the formatter's
        // support for more than three digits varies by OS release, and a code's
        // expiry does not need sub-second precision.
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "",
                                                options: .regularExpression)
        return plain.date(from: trimmed)
    }
}
