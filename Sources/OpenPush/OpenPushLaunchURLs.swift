import Foundation
import OpenPushCore
#if canImport(UIKit)
import UIKit
#endif

public extension OpenPush.Notifications {
    /// When true, tapping a notification opens its launch URL (the composer's
    /// `deep_link`) with `UIApplication.open`, shortly after the click listeners
    /// have been told — or, for a tap on an action button that has a link of its
    /// own, that link. The click event's `launchURLOpened` says whether it did.
    ///
    /// **On by default**, as on Android and Unity. Any URL that
    /// parses is opened, whatever its scheme: a web link, the app's own scheme,
    /// `tel:`, another app's scheme. A repeated tap on a message already handled
    /// opens nothing, exactly as it reaches no listener.
    ///
    /// To route URLs yourself, either set this to false — in code at any time, or
    /// with the Info.plist boolean `OpenPushSuppressLaunchURLs` set to true, read
    /// once at `initialize` — or skip a click whose event has `launchURLOpened`
    /// true. It applies to the next tap.
    static var openLaunchURLs: Bool {
        get { OpenPush.launchURLs.opensLaunchURLs }
        set { OpenPush.launchURLs.setOpensLaunchURLs(newValue) }
    }
}

extension OpenPush {
    /// The launch-URL setting and the seams behind it. Kept out of `State`: none
    /// of it is session state, and none of it is cleared by a workspace switch.
    final class LaunchURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true
        private var open: @Sendable (URL) -> Void = LaunchURLs.systemOpen
        private var plist: @Sendable (String) -> Any? = LaunchURLs.bundleLookup

        var opensLaunchURLs: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        func setOpensLaunchURLs(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }

        var opener: @Sendable (URL) -> Void { lock.lock(); defer { lock.unlock() }; return open }
        func setOpener(_ value: @escaping @Sendable (URL) -> Void) {
            lock.lock(); open = value; lock.unlock()
        }

        var infoLookup: @Sendable (String) -> Any? {
            lock.lock(); defer { lock.unlock() }; return plist
        }
        func setInfoLookup(_ value: @escaping @Sendable (String) -> Any?) {
            lock.lock(); plist = value; lock.unlock()
        }

        func resetForTests() {
            lock.lock()
            enabled = true
            open = LaunchURLs.systemOpen
            plist = LaunchURLs.bundleLookup
            lock.unlock()
        }

        /// Called from `attach`: an Info.plist that asks for launch URLs to be
        /// left alone turns the setting off. Without the key the setting is left
        /// as it is — on by default, or whatever the app set in code.
        func applyInfoPlistOptOut() {
            let lookup = infoLookup
            guard Self.isTrue(lookup(OpenPushConfiguration.suppressLaunchURLsInfoKey)) else { return }
            setOpensLaunchURLs(false)
            OpenPush.onLog("• launch URLs are left to the app — Info.plist sets " +
                           "\(OpenPushConfiguration.suppressLaunchURLsInfoKey)")
        }

        /// A plist boolean, or a string or number that reads as one.
        static func isTrue(_ value: Any?) -> Bool {
            switch value {
            case let flag as Bool: return flag
            case let number as NSNumber: return number.boolValue
            case let text as String: return (text as NSString).boolValue
            default: return false
            }
        }

        static let bundleLookup: @Sendable (String) -> Any? = {
            Bundle.main.object(forInfoDictionaryKey: $0)
        }

        /// iOS foregrounds the app on any tap; the delay lets that transition
        /// settle, since an open issued during it can be dropped.
        static let systemOpen: @Sendable (URL) -> Void = { url in
            #if canImport(UIKit)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                MainActor.assumeIsolated {
                    UIApplication.shared.open(url, options: [:]) { opened in
                        if !opened {
                            OpenPush.onLog("• launch URL could not be opened: \(url.absoluteString)")
                        }
                    }
                }
            }
            #else
            OpenPush.onLog("• launch URL not opened — opening URLs needs an iOS app")
            #endif
        }
    }

    static let launchURLs = LaunchURLs()

    /// Overridable for tests, like `permissionSeam`.
    static var launchURLOpener: @Sendable (URL) -> Void {
        get { launchURLs.opener }
        set { launchURLs.setOpener(newValue) }
    }
}

extension OpenPush.Notifications {
    /// The URL a tap should open, or nil when the setting is off or the push has
    /// no URL that parses. A tapped button with a link of its own opens that link
    /// instead of the push's `deep_link`; a button without one opens the
    /// `deep_link`, as any tap does.
    static func launchURLToOpen(for notification: OpenPush.Notification,
                                actionId: String?) -> URL? {
        guard OpenPush.launchURLs.opensLaunchURLs else { return nil }
        let buttonURL = actionId.flatMap { id in
            notification.actions.first { $0.id == id }?.url
        }
        return buttonURL ?? notification.launchURL
    }
}
