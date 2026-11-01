import Foundation

extension OpenPush {
    /// The embedded profile cannot change while the process runs, so the parse —
    /// reading and property-list-decoding a file off disk — happens once, not on
    /// every registration. Tests keep using the `in bundle:` overload.
    static let cachedAPNsEnvironment: String? = apnsEnvironment(in: .main)

    /// Reads the signed push environment from the provisioning profile embedded
    /// in development and ad-hoc builds. App Store builds may omit that profile;
    /// in that case registration leaves `sandbox` absent and the server's app
    /// credential remains the fallback.
    static func apnsEnvironment(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else { return nil }
        let xml = String(raw[start.lowerBound..<end.upperBound])
        guard let plistData = xml.data(using: .isoLatin1),
              let parsed = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil),
              let profile = parsed as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["aps-environment"] as? String
    }

    static func sandboxFlag(forAPNsEnvironment environment: String?) -> Bool? {
        switch environment?.lowercased() {
        case "development": true
        case "production": false
        default: nil
        }
    }
}
