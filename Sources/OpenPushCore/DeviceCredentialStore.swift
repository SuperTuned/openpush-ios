import Foundation
import Security

/// Shared-Keychain storage usable by both an app and its notification service
/// extension. The access group must be present in both signed entitlements.
public struct DeviceCredentialStore: Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?

    /// The four Keychain calls, a seam so the in-place update and the migration
    /// can be tested where a test process has no Keychain entitlement.
    let keychain: Keychain

    public init(service: String, account: String = "device-key",
                accessGroup: String? = nil) {
        self.init(service: service, account: account, accessGroup: accessGroup,
                  keychain: .system)
    }

    init(service: String, account: String = "device-key", accessGroup: String? = nil,
         keychain: Keychain) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.keychain = keychain
    }

    struct Keychain: Sendable {
        var copyMatching: @Sendable (_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
        var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
        var update: @Sendable (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
        var delete: @Sendable (_ query: [String: Any]) -> OSStatus

        static let system = Keychain(
            copyMatching: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            delete: { SecItemDelete($0 as CFDictionary) })
    }

    /// The Keychain class every credential is written with: readable once the
    /// device has been unlocked after a restart (an extension runs in the
    /// background), and never restored onto another device from a backup, where
    /// it would make two installs share one subscription.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// Writes the credential in place. An existing item is updated, never
    /// deleted first, so a failed write cannot leave the install without its
    /// credential (losing it makes the server create a second subscription).
    @discardableResult
    public func save(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
        ]
        let status = keychain.update(baseQuery, update)
        guard status == errSecItemNotFound else { return status }
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = Self.accessibility
        return keychain.add(attrs)
    }

    /// Reads the credential. An item written with an older accessibility class
    /// is moved to the current one in place: same value, same item, only its
    /// accessibility attribute changes. If that update fails the value is still
    /// returned and the move is tried again on the next load.
    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        if let current = item[kSecAttrAccessible as String] as? String,
           current != Self.accessibility as String {
            migrateAccessibility()
        }
        return value
    }

    @discardableResult
    func migrateAccessibility() -> OSStatus {
        let update: [String: Any] = [kSecAttrAccessible as String: Self.accessibility]
        return keychain.update(baseQuery, update)
    }

    @discardableResult
    public func wipe() -> OSStatus {
        keychain.delete(baseQuery)
    }

    /// One-release migration from the former App Group defaults mirror. The
    /// plaintext is removed only after the shared Keychain write succeeds.
    @discardableResult
    public func migrateLegacy(defaults: UserDefaults?, key: String) -> Bool {
        guard load() == nil,
              let value = defaults?.string(forKey: key), !value.isEmpty else {
            if load() != nil { defaults?.removeObject(forKey: key) }
            return false
        }
        guard save(value) == errSecSuccess else { return false }
        defaults?.removeObject(forKey: key)
        return true
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
