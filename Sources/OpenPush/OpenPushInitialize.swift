import Foundation
import OpenPushCore

public extension OpenPush {
    /// The hosted OpenPush endpoint. Self-hosted installs pass their own
    /// `serverURL` to `initialize`.
    static let defaultServerURL = OpenPushConfiguration.defaultServerURL

    /// True after `initialize` or `attach` has configured this process.
    static var isInitialized: Bool { state.config != nil }

    /// The single source is `OpenPushSDKVersion.current`, in `OpenPushCore`, so a
    /// Notification Service Extension identifies itself with the same version the
    /// app does. This spelling is the public one and does not change.
    static let sdkVersion = OpenPushSDKVersion.current

    /// The SDK a wrapper is built on top of, when OpenPush is embedded in one.
    /// Both parts are trimmed; a name or version that is empty after trimming
    /// cannot be parsed on the other end and leaves the wrapper unset.
    struct SDKWrapper: Sendable, Equatable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The one spelling that rides both the header and the registration body.
        var wireValue: String { "\(name)/\(version)" }
    }

    /// Set this before `initialize` — a wrapper SDK is what calls `initialize` —
    /// and every request names the wrapper alongside the native SDK. It is not
    /// part of the configuration, so `attach` and a workspace switch both leave
    /// it alone.
    static var wrapper: SDKWrapper? {
        get { state.sdkWrapper }
        set {
            guard let value = newValue else {
                state.setSDKWrapper(nil)
                return
            }
            guard !value.name.isEmpty, !value.version.isEmpty else {
                onLog("\u{2717} wrapper ignored \u{2014} a wrapper needs both a name and a "
                      + "version; nothing will be reported")
                state.setSDKWrapper(nil)
                return
            }
            state.setSDKWrapper(value)
            // The App Group mirror is how an extension learns the wrapper, and a
            // wrapper set after `initialize` would otherwise leave a stale one
            // there until the next token or subscription write.
            if let mirror = state.sharedStateSnapshot() {
                OpenPushSharedState.save(mirror.value, appGroup: mirror.appGroup)
            }
        }
    }

    /// Compatibility entry point. It is exactly `attach` with a flatter
    /// argument list; token forwarding stays host-owned, so the app delegate
    /// still calls `register(token:)` from
    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// It carries the `initialize` signature migrating hosts already wrote, so
    /// the call compiles after a one-word prefix replacement. The SDK key comes
    /// from `Info.plist` under `OpenPushSDKKey`.
    ///
    /// `launchOptions` is accepted and unused: OpenPush installs no delegates, so
    /// there is nothing to build from it. The SDK a host is migrating from also
    /// used it to notice a cold start from a notification tap — forward
    /// `processClick(_:)` from `UNUserNotificationCenterDelegate` to keep that.
    /// The log line says so rather than leaving it to be discovered in
    /// production.
    static func initialize(_ appId: String,
                           withLaunchOptions launchOptions: [AnyHashable: Any]? = nil) {
        if launchOptions != nil {
            onLog("• launchOptions ignored — OpenPush installs no delegates. Forward "
                  + "processClick(_:) to handle a tap that cold-started the app.")
        }
        initialize(appId: appId)
    }

    /// Overridable for tests, exactly like `permissionSeam` and `scheduler`.
    /// Production reads the app bundle.
    internal static var bundledSDKKeySeam: @Sendable () -> String? {
        get { state.bundledSDKKeySeam }
        set { state.setBundledSDKKeySeam(newValue) }
    }

    /// Compatibility-shaped setup with the SDK key in `Info.plist` under
    /// `OpenPushSDKKey`.  An explicit `sdkKey:` argument always wins over it, so
    /// tests, staging and multi-tenant hosts can override without a plist edit.
    ///
    /// Refuses and stays unconfigured when no key can be found anywhere: an SDK
    /// that is half-configured never registers and never says why, which is worse
    /// than one that plainly refused at launch.
    static func initialize(appId: String,
                           serverURL: String = OpenPush.defaultServerURL,
                           appGroup: String? = nil,
                           credential: @escaping @Sendable () -> String? = { nil },
                           provisional: Bool = false,
                           transport: @escaping Transport = urlSessionTransport) {
        guard let key = bundledSDKKeySeam() else {
            let note = "\u{2717} initialize refused \u{2014} no SDK key. Add "
                + "\(OpenPushConfiguration.sdkKeyInfoKey) to your Info.plist, or call "
                + "initialize(appId:sdkKey:)."
            onLog(note)
            fireRegistrationFailed(note)
            return
        }
        initialize(appId: appId, sdkKey: key, serverURL: serverURL,
                   appGroup: appGroup, credential: credential,
                   provisional: provisional, transport: transport)
    }

    /// `appGroup` is the App Group the app and its extensions share. Pass it and
    /// OpenPush mirrors the app id, server, SDK key, APNs token and subscription id
    /// there, so a Notification Service Extension needs no hand-plumbed copies. The
    /// device credential is never mirrored.
    static func initialize(appId: String, sdkKey: String,
                           serverURL: String = OpenPush.defaultServerURL,
                           appGroup: String? = nil,
                           credential: @escaping @Sendable () -> String? = { nil },
                           provisional: Bool = false,
                           transport: @escaping Transport = urlSessionTransport) {
        attach(configuration: OpenPushConfiguration(appID: appId,
                                                    sdkKey: sdkKey,
                                                    serverURL: serverURL,
                                                    appGroup: appGroup),
               credential: credential,
               transport: transport)
        // A refused app id stops here too. `attach` already said no and told the
        // host why; asking iOS for notification authorization afterwards is the
        // loudest possible thing to do on behalf of a configuration that does not
        // exist, and on the non-provisional path it would re-register a previous
        // workspace's token.
        guard appIDRefusal(appId) == nil else { return }
        // `attach` has already refreshed the permission cache, which is all the
        // default path needs.
        if provisional {
            // The quiet-first path: .provisional shows no prompt, so this both
            // authorizes and starts APNs registration without interrupting launch.
            Notifications.request(provisional: true, fallbackToSettings: false, completion: nil)
        } else {
            Notifications.resyncAPNsTokenIfAuthorized()
        }
    }
}
