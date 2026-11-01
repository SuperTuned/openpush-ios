import Foundation
import OpenPush
import OpenPushCore
import SwiftUI

enum RuntimeMode: String, CaseIterable, Identifiable {
    case demo
    case live

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The app-only half of the configuration. The App Group, Keychain group, and
/// credential service live in `Shared/ExampleIdentifiers.swift`, which the
/// Notification Service Extension compiles too.
extension ExampleConfiguration {
    static let activityType = "delivery"

    /// Where an older build of this sample mirrored the device credential in
    /// plaintext. Nothing writes it any more; it exists so the Credential panel
    /// can demonstrate `DeviceCredentialStore.migrateLegacy(defaults:key:)`.
    static let legacyCredentialDefaultsKey = "openpush.example.device-credential"

    static var appID: String {
        Bundle.main.object(forInfoDictionaryKey: OpenPushConfiguration.appIDInfoKey)
            as? String ?? "replace-with-app-id"
    }

    static var sdkKey: String {
        Bundle.main.object(forInfoDictionaryKey: OpenPushConfiguration.sdkKeyInfoKey)
            as? String ?? "replace-with-public-sdk-key"
    }

    static var hasLiveCredentials: Bool {
        !isPlaceholder(appID) && !isPlaceholder(sdkKey)
    }

    static var hasDeviceCredential: Bool {
        credentialStore.load()?.isEmpty == false
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        value.isEmpty || value.hasPrefix("replace-with-")
    }
}

/// App-owned privacy state used to demonstrate delayed SDK initialization.
/// OpenPush intentionally does not persist or interpret legal consent itself.
enum ExampleConsentGate {
    private static let requiredKey = "example.consent.required"
    private static let grantedKey = "example.consent.granted"

    static var isRequired: Bool {
        UserDefaults.standard.bool(forKey: requiredKey)
    }

    static var isGranted: Bool {
        UserDefaults.standard.bool(forKey: grantedKey)
    }

    static var permitsSDKStart: Bool {
        !isRequired || isGranted
    }

    static func setRequired(_ required: Bool) {
        UserDefaults.standard.set(required, forKey: requiredKey)
        if required {
            // Enabling the lab resets the decision so the waiting state is
            // reproducible instead of silently reusing an older grant.
            UserDefaults.standard.set(false, forKey: grantedKey)
        }
    }

    static func setGranted(_ granted: Bool) {
        UserDefaults.standard.set(granted, forKey: grantedKey)
    }

}

enum ExampleSDKBootstrap {
    private static var didConfigureLiveActivities = false

    /// Starts every SDK-owned integration point only after the host app's gate
    /// permits it. This is the behavior integrators should copy—not a claim that
    /// OpenPush provides a consent API.
    @discardableResult
    static func startIfPermitted() -> Bool {
        guard ExampleConfiguration.hasLiveCredentials,
              ExampleConsentGate.permitsSDKStart else {
            return false
        }

        if !OpenPush.isInitialized {
            // `appGroup` is what makes the extension work: OpenPush mirrors the
            // app id, server, SDK key, APNs token, and subscription id into the
            // group, so NotificationService needs no hand-plumbed copies.
            OpenPush.initialize(
                appId: ExampleConfiguration.appID,
                appGroup: ExampleConfiguration.appGroup,
                credential: { ExampleConfiguration.credentialStore.load() }
            )
        }

        if #available(iOS 16.1, *), OpenPush.isInitialized, !didConfigureLiveActivities {
            OpenPush.LiveActivities.setup(ExampleDeliveryAttributes.self)
            didConfigureLiveActivities = true
        }
        return OpenPush.isInitialized
    }
}
