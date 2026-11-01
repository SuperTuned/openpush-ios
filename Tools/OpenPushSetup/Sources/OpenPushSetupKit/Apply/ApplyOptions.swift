import Foundation

/// Where `OpenPush`, `OpenPushNSE` and `OpenPushLiveActivities` come from when
/// setup links them with Swift Package Manager.
public enum OpenPushPackageSource: Equatable, Sendable {
    case remote(url: String, from: String)
    /// A checkout on disk, for a private copy or for testing the tool itself.
    case local(path: String)

    public static let defaultRemote = OpenPushPackageSource.remote(
        url: "https://github.com/SuperTuned/openpush-ios.git", from: SetupToolVersion.sdk)
}

public enum SetupToolVersion {
    /// The SDK version the setup tool links and writes for.
    public static let sdk = "1.2.2"
}

/// The command-line options of `apply`. Each one answers a choice outright and
/// is stored, so a later run needs none of them.
public struct ApplyOptions: Sendable {
    public var appTarget: String?
    public var appGroup: String?
    public var keychainGroup: String?
    public var nseMode: SetupChoices.ServiceExtensionMode?
    public var nseBundleID: String?
    public var nseProfile: ProvisioningProfiles?
    public var widgetMode: SetupChoices.WidgetMode?
    public var widgetBundleID: String?
    public var widgetProfile: ProvisioningProfiles?
    public var appID: String?
    public var sdkKey: String?
    public var package: OpenPushPackageSource = .defaultRemote
    /// `--yes`: take the Reuse default wherever there is one, without asking.
    public var assumeDefaults = false
    /// Names the backup folder; injectable so tests are deterministic.
    public var timestamp: String = ApplyOptions.now()

    public init() {}

    public static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// Asks the developer one question. The command line answers on a TTY; tests
/// answer from a script.
public protocol ChoicePrompter {
    /// Returns the index of the chosen option.
    func choose(_ question: SetupQuestion) -> Int
}

public struct SetupQuestion: Sendable, Equatable {
    public let choice: String
    public let text: String
    public let options: [String]
    public let defaultIndex: Int?
    /// The option that answers it on the command line, for the error a
    /// non-interactive run gives instead of asking.
    public let flag: String
}
