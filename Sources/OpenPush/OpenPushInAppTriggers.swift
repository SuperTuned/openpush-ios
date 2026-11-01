import Foundation

extension OpenPush {
    enum IamTriggerValue: Sendable, Equatable {
        case string(String), number(Double), boolean(Bool)

        init?(_ value: Any) {
            if let value = value as? Bool { self = .boolean(value); return }
            if let value = value as? NSNumber { self = .number(value.doubleValue); return }
            if let value = value as? String { self = .string(value); return }
            return nil
        }

        /// A whole number reads as "42", not "42.0" — but only while it really is
        /// a whole number. Past 2^53 a `Double` no longer represents integers
        /// exactly, and past `Int.max` the conversion traps outright: the
        /// "nothing has ever been dismissed" sentinel handed to a
        /// `min_time_since` comparison is `Double.greatestFiniteMagnitude`, so
        /// that trap was one trigger away on every fresh install.
        static let exactIntegerLimit = 9_007_199_254_740_992.0   // 2^53

        var text: String {
            switch self {
            case .string(let value): return value
            case .number(let value):
                return value.rounded() == value && abs(value) < Self.exactIntegerLimit
                    ? String(Int(value)) : String(value)
            case .boolean(let value): return value ? "true" : "false"
            }
        }

        /// A number answers with the value it stores. Only the other cases are
        /// parsed, and `text` stays what it is: a rendering.
        var numeric: Double? {
            if case .number(let value) = self { return value }
            return Double(text)
        }
    }

    struct IamCondition: Sendable {
        let id: String
        let kind: String
        let property: String?
        let op: String
        let value: IamTriggerValue?
    }

    /// Seconds until the earliest time-based condition could become true, so the
    /// engine can wake itself instead of waiting for an unrelated re-evaluation.
    /// `nil` means nothing in these groups is merely waiting on the clock.
    static func iamNextDynamicDeadline(_ groups: [[IamCondition]],
                                       triggers: [String: IamTriggerValue],
                                       sessionAge: Double,
                                       timeSinceLast: Double) -> Double? {
        var best: Double?
        for group in groups {
            for condition in group {
                let actual: Double
                switch condition.kind {
                case "session_time": actual = sessionAge
                case "min_time_since": actual = timeSinceLast
                default: continue
                }
                guard let target = condition.value?.numeric,
                      ["greater", "greater_or_equal", "equal"].contains(condition.op) else { continue }
                let remaining = target - actual
                guard remaining > 0, remaining < .greatestFiniteMagnitude else { continue }
                best = min(best ?? remaining, remaining)
            }
        }
        return best
    }

    /// `in` asks whether the trigger's own value holds what the condition
    /// looks for. A value carrying commas is a list — "gold, silver" holds
    /// "silver" and does not hold "sil" — and members are compared trimmed.
    /// Anything else has no list to read, so `in` stays a substring test.
    static func iamValueHolds(_ actual: IamTriggerValue, _ expected: IamTriggerValue) -> Bool {
        let haystack = actual.text
        guard haystack.contains(",") else { return haystack.contains(expected.text) }
        let needle = expected.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return haystack.split(separator: ",", omittingEmptySubsequences: false).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }
    }

    static func iamConditionsMatch(_ groups: [[IamCondition]],
                                   triggers: [String: IamTriggerValue],
                                   sessionAge: Double,
                                   timeSinceLast: Double) -> Bool {
        if groups.isEmpty { return true }
        return groups.contains { group in
            !group.isEmpty && group.allSatisfy { condition in
                let actual: IamTriggerValue?
                switch condition.kind {
                case "session_time": actual = .number(sessionAge)
                case "min_time_since": actual = .number(timeSinceLast)
                default: actual = condition.property.flatMap { triggers[$0] }
                }
                if condition.op == "exists" { return actual != nil }
                if condition.op == "not_exists" { return actual == nil }
                guard let actual, let expected = condition.value else { return false }
                if let lhs = actual.numeric, let rhs = expected.numeric {
                    switch condition.op {
                    case "equal": return lhs == rhs
                    case "not_equal": return lhs != rhs
                    case "greater": return lhs > rhs
                    case "greater_or_equal": return lhs >= rhs
                    case "less": return lhs < rhs
                    case "less_or_equal": return lhs <= rhs
                    case "in": return iamValueHolds(actual, expected)
                    default: return false
                    }
                }
                switch condition.op {
                case "equal": return actual.text == expected.text
                case "not_equal": return actual.text != expected.text
                case "in": return iamValueHolds(actual, expected)
                default: return false
                }
            }
        }
    }
}
