import Foundation

/// One JSON value from an APNs payload, kept exactly as it arrived.
///
/// APNs hands the app a `[AnyHashable: Any]`, which is neither `Sendable` nor
/// safe to hand to a host closure, and flattening it to strings destroys nested
/// objects. This is the crossing-safe form: every JSON-representable key, nesting
/// intact — non-string keys and non-JSON values are dropped, and every number is
/// a `Double`, so an integer read back from a payload is `1.0` rather than `1`.
/// It round-trips through `Codable`, so the service extension and the app can
/// both read the same shape.
public indirect enum OpenPushJSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OpenPushJSONValue])
    case object([String: OpenPushJSONValue])

    /// Wraps a value produced by `JSONSerialization` or carried in APNs
    /// `userInfo`. Returns `nil` for anything that is not representable in JSON.
    public init?(_ any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // A bridged Swift `Bool` and a bridged `1` are both `NSNumber`, and
            // only the CoreFoundation type id tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let list as [Any]:
            self = .array(list.compactMap(OpenPushJSONValue.init))
        case let map as [AnyHashable: Any]:
            var object: [String: OpenPushJSONValue] = [:]
            for (key, value) in map {
                guard let name = key as? String,
                      let wrapped = OpenPushJSONValue(value) else { continue }
                object[name] = wrapped
            }
            self = .object(object)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    public var objectValue: [String: OpenPushJSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [OpenPushJSONValue]? {
        if case .array(let list) = self { return list }
        return nil
    }

    public subscript(key: String) -> OpenPushJSONValue? { objectValue?[key] }

    /// Back to the Foundation types a host expects, for a call site that still
    /// wants `Any` (a `JSONSerialization` round trip, say).
    public var anyValue: Any {
        switch self {
        case .string(let text): return text
        case .number(let value): return value
        case .bool(let flag): return flag
        case .null: return NSNull()
        case .array(let list): return list.map(\.anyValue)
        case .object(let object): return object.mapValues(\.anyValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let list = try? container.decode([OpenPushJSONValue].self) {
            self = .array(list)
        } else if let object = try? container.decode([String: OpenPushJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .number(let value): try container.encode(value)
        case .bool(let flag): try container.encode(flag)
        case .null: try container.encodeNil()
        case .array(let list): try container.encode(list)
        case .object(let object): try container.encode(object)
        }
    }
}
