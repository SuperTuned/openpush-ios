import Foundation
import OpenPushCore
import OpenPushNSE

/// How this sample configures the one-call service-extension handler.
///
/// Only the App Group is required: the app mirrors its OpenPush configuration and
/// APNs token into it, and the receipt is authenticated on the SDK key. This
/// sample also sets the optional shared-Keychain store holding this install's
/// device credential, which the receipt then carries. The credential is
/// deliberately never mirrored into the App Group, so using it needs the
/// Keychain access group in the extension's own entitlements.
///
/// `onEvent` is this sample's own addition: the handler reports what it did, one
/// short line at a time, and the lines are written into the App Group so the
/// Status workspace can show them. A shipping app does not need it.
enum ExampleNSEOptions {
    static func make() -> OpenPushNotificationServiceHandler.Options {
        var options = OpenPushNotificationServiceHandler.Options()
        options.appGroup = ExampleConfiguration.appGroup
        options.credentialStore = DeviceCredentialStore(
            service: ExampleConfiguration.credentialService,
            accessGroup: ExampleConfiguration.keychainGroup
        )
        options.onEvent = { event in record(event) }
        return options
    }

    /// The Status screen reads one key per kind of work, so each new line
    /// replaces the previous run's.
    private static let telemetryKeys: [(prefix: String, key: String)] = [
        ("actions:", "openpush.example.nse.actions"),
        ("attachment:", "openpush.example.nse.attachment"),
        ("receipt:", "openpush.example.nse.receipt"),
    ]

    /// Called from whichever thread the handler finished that piece of work on.
    /// `UserDefaults` is thread-safe, and an event whose shape this sample does
    /// not recognize is dropped rather than overwriting an unrelated row.
    private static func record(_ event: String) {
        guard let match = telemetryKeys.first(where: { event.hasPrefix($0.prefix) }) else {
            return
        }
        UserDefaults(suiteName: ExampleConfiguration.appGroup)?
            .set(event, forKey: match.key)
    }
}
