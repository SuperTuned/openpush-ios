import Foundation

/// Reads a property list (Info.plist, entitlements) into JSON values, with every
/// string expanded through the target's build settings, since both files are
/// preprocessed that way at build time.
enum PropertyListFile {
    static func read(_ url: URL, settings: ResolvedBuildSettings) -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              case .object(let dictionary) = convert(object, settings: settings) else { return nil }
        return dictionary
    }

    private static func convert(_ object: Any, settings: ResolvedBuildSettings) -> JSONValue {
        switch object {
        case let string as String: return .string(settings.expand(string))
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .int(number.intValue)
        case let array as [Any]: return .array(array.map { convert($0, settings: settings) })
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues { convert($0, settings: settings) })
        default: return .string(String(describing: object))
        }
    }
}
