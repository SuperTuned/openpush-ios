import Foundation

public struct OpenPushLiveActivityAttributeData: Codable, Hashable, Sendable {
    public var activityId: String
    enum CodingKeys: String, CodingKey { case activityId = "activity_id" }
    public init(activityId: String) { self.activityId = activityId }
    public static func create(activityId: String) -> Self { Self(activityId: activityId) }
}

public struct OpenPushLiveActivityContentStateData: Codable, Hashable, Sendable {
    public var notificationId: String
    enum CodingKeys: String, CodingKey { case notificationId = "notification_id" }
    public init(notificationId: String) { self.notificationId = notificationId }
}

public protocol OpenPushLiveActivityContentState: Codable, Hashable {
    var openpush: OpenPushLiveActivityContentStateData? { get set }
}

public final class OpenPushLiveActivitySetupOptions {
    public var enablePushToStart: Bool
    public var enablePushToUpdate: Bool
    public init(enablePushToStart: Bool = true, enablePushToUpdate: Bool = true) {
        self.enablePushToStart = enablePushToStart
        self.enablePushToUpdate = enablePushToUpdate
    }
}

/// Deprecated alias of `OpenPushLiveActivitySetupOptions`, kept for source compatibility.
@available(*, deprecated, renamed: "OpenPushLiveActivitySetupOptions")
public typealias LiveActivitySetupOptions = OpenPushLiveActivitySetupOptions

// `OpenPushAnyCodable` is derived from AnyCodable by Flight School
// (https://github.com/Flight-School/AnyCodable), Copyright (c) 2018 Read Evaluate
// Press, LLC, used under the MIT License. The full notice is in NOTICE at the
// root of this repository.
@frozen public struct OpenPushAnyCodable: Codable, Hashable, @unchecked Sendable {
    public let value: Any
    public init<T>(_ value: T?) { self.value = value ?? () }
    public func asBool() -> Bool? { value as? Bool }
    public func asInt() -> Int? { value as? Int }
    public func asDouble() -> Double? { value as? Double }
    public func asString() -> String? { value as? String }
    public func asArray() -> [OpenPushAnyCodable]? { value as? [OpenPushAnyCodable] }
    public func asDict() -> [String: OpenPushAnyCodable]? {
        value as? [String: OpenPushAnyCodable]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.init(NSNull()) }
        else if let value = try? container.decode(Bool.self) { self.init(value) }
        else if let value = try? container.decode(Int.self) { self.init(value) }
        else if let value = try? container.decode(Double.self) { self.init(value) }
        else if let value = try? container.decode(String.self) { self.init(value) }
        else if let value = try? container.decode([OpenPushAnyCodable].self) { self.init(value) }
        else if let value = try? container.decode([String: OpenPushAnyCodable].self) {
            self.init(value)
        }
        else { throw DecodingError.dataCorruptedError(in: container,
            debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull, is Void: try container.encodeNil()
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [OpenPushAnyCodable]: try container.encode(value)
        case let value as [String: OpenPushAnyCodable]: try container.encode(value)
        case let value as [Any]: try container.encode(value.map(OpenPushAnyCodable.init))
        case let value as [String: Any]:
            try container.encode(value.mapValues(OpenPushAnyCodable.init))
        default: throw EncodingError.invalidValue(value, .init(
            codingPath: container.codingPath, debugDescription: "unsupported JSON value"))
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull), is (Void, Void): return true
        case let (a as Bool, b as Bool): return a == b
        case let (a as Int, b as Int): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as String, b as String): return a == b
        case let (a as [OpenPushAnyCodable], b as [OpenPushAnyCodable]): return a == b
        case let (a as [String: OpenPushAnyCodable], b as [String: OpenPushAnyCodable]):
            return a == b
        default: return false
        }
    }
    public func hash(into hasher: inout Hasher) {
        switch value {
        case let value as Bool: hasher.combine(value)
        case let value as Int: hasher.combine(value)
        case let value as Double: hasher.combine(value)
        case let value as String: hasher.combine(value)
        case let value as [OpenPushAnyCodable]: hasher.combine(value)
        case let value as [String: OpenPushAnyCodable]: hasher.combine(value)
        default: hasher.combine(0)
        }
    }
    public static func map(_ values: [String: Any]) -> [String: OpenPushAnyCodable] {
        values.mapValues(OpenPushAnyCodable.init)
    }
}

/// Deprecated alias of `OpenPushAnyCodable`, kept for source compatibility.
@available(*, deprecated, renamed: "OpenPushAnyCodable")
public typealias AnyCodable = OpenPushAnyCodable

public enum OpenPushLiveActivityTypeName {
    public static func derived<T>(_ type: T.Type) -> String { "\(type)" }
}

private struct OpenPushLiveActivityCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public protocol OpenPushLiveActivityAttributes: ActivityAttributes
where ContentState: OpenPushLiveActivityContentState {
    var openpush: OpenPushLiveActivityAttributeData { get set }
}

@available(iOS 16.1, *)
public struct DefaultLiveActivityAttributes: OpenPushLiveActivityAttributes, Sendable {
    public struct ContentState: OpenPushLiveActivityContentState, Sendable {
        public var data: [String: OpenPushAnyCodable]
        public var openpush: OpenPushLiveActivityContentStateData?
        public init(data: [String: OpenPushAnyCodable],
                    openpush: OpenPushLiveActivityContentStateData? = nil) {
            self.data = data; self.openpush = openpush
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: OpenPushLiveActivityCodingKey.self)
            openpush = try values.decodeIfPresent(
                OpenPushLiveActivityContentStateData.self,
                forKey: OpenPushLiveActivityCodingKey(stringValue: "openpush")!)
            data = [:]
            for key in values.allKeys where key.stringValue != "openpush"
                && key.stringValue != "onesignal" {
                if key.stringValue == "data",
                   let nested = try? values.decode(
                       [String: OpenPushAnyCodable].self, forKey: key) {
                    data.merge(nested) { _, new in new }
                } else {
                    data[key.stringValue] = try values.decode(OpenPushAnyCodable.self, forKey: key)
                }
            }
        }
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: OpenPushLiveActivityCodingKey.self)
            if let openpush {
                try values.encode(openpush,
                                  forKey: OpenPushLiveActivityCodingKey(stringValue: "openpush")!)
            }
            for (name, value) in data where name != "openpush" && name != "onesignal" {
                try values.encode(value,
                                  forKey: OpenPushLiveActivityCodingKey(stringValue: name)!)
            }
        }
    }
    public var data: [String: OpenPushAnyCodable]
    public var openpush: OpenPushLiveActivityAttributeData
    public init(data: [String: OpenPushAnyCodable], openpush: OpenPushLiveActivityAttributeData) {
        self.data = data; self.openpush = openpush
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: OpenPushLiveActivityCodingKey.self)
        openpush = try values.decode(
            OpenPushLiveActivityAttributeData.self,
            forKey: OpenPushLiveActivityCodingKey(stringValue: "openpush")!)
        data = [:]
        for key in values.allKeys where key.stringValue != "openpush"
            && key.stringValue != "onesignal" {
            if key.stringValue == "data",
               let nested = try? values.decode([String: OpenPushAnyCodable].self, forKey: key) {
                data.merge(nested) { _, new in new }
            } else {
                data[key.stringValue] = try values.decode(OpenPushAnyCodable.self, forKey: key)
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: OpenPushLiveActivityCodingKey.self)
        try values.encode(openpush,
                          forKey: OpenPushLiveActivityCodingKey(stringValue: "openpush")!)
        for (name, value) in data where name != "openpush" && name != "onesignal" {
            try values.encode(value,
                              forKey: OpenPushLiveActivityCodingKey(stringValue: name)!)
        }
    }
}
#endif
