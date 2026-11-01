import Foundation
import OpenPushCore

/// The identifiers the app and its Notification Service Extension have to agree
/// on, in the one file both targets compile.
///
/// An extension runs in its own process with its own container. It reaches the
/// app's world only through the App Group (the mirrored OpenPush configuration
/// and APNs token) and the shared Keychain access group (this install's device
/// credential). A copy of either string that drifts is the classic silent
/// failure: the extension runs, finds nothing, and posts no receipt.
///
/// Neither string is written here. Both come from `Build.xcconfig`, which also
/// feeds the two entitlements files, so the build settings, the entitlements,
/// and the code cannot disagree. Each target's Info.plist carries the resolved
/// value, and `Bundle.main` in an extension is the extension's own bundle.
///
/// `Sources/ExampleConfiguration.swift` extends this enum with everything that
/// only the app needs.
enum ExampleConfiguration {
    /// `OPENPUSH_APP_GROUP`; also `com.apple.security.application-groups` in
    /// both entitlements.
    static let appGroup = infoString("OpenPushExampleAppGroup")
        ?? "group.ai.openpush.example"

    /// `OPENPUSH_KEYCHAIN_GROUP`; also `keychain-access-groups` in both
    /// entitlements. A Live build resolves `TEAMID` to your team identifier.
    static let keychainGroup = infoString("OpenPushExampleKeychainGroup")
        ?? "TEAMID.ai.openpush.example.shared"

    /// The Keychain service the device credential is stored under.
    static let credentialService = "ai.openpush.example.device"

    static let credentialStore = DeviceCredentialStore(
        service: credentialService,
        accessGroup: keychainGroup
    )

    /// An Info.plist key whose build setting was left empty reaches the bundle
    /// as an empty string, which is not an identifier — treat it as absent so
    /// Demo mode falls back to the placeholder above.
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
