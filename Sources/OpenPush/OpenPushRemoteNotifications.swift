import Foundation

public extension OpenPush {
    /// Forward from the app delegate's successful remote-registration callback.
    static func didRegisterForRemoteNotifications(deviceToken: Data) {
        register(token: hexToken(deviceToken))
    }

    /// Forward from the app delegate's
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, and
    /// go on calling your own completion handler exactly as before — this never
    /// calls it for you, and never waits for the receipt it posts.
    ///
    /// A background (`content-available`) push never reaches
    /// `UNUserNotificationCenterDelegate`, so without this entry point a silent
    /// delivery leaves no record at all.
    ///
    /// Returns whether the payload was one OpenPush sent. `false` means another
    /// provider's push, or your own: nothing was posted and it is yours to handle.
    /// Delivery only — no click or foreground listener is ever called from here.
    @discardableResult
    static func didReceiveRemoteNotification(userInfo: [AnyHashable: Any]) -> Bool {
        let notification = Notification(userInfo: userInfo)
        guard notification.isOpenPush else { return false }
        // The extension and the app may each post `received` for the same message:
        // they are separate processes, and this process's dedupe cannot see the
        // extension's receipt. The server keeps the first timestamp, so the
        // duplicate is harmless.
        receipt("received", messageID: notification.messageId)
        return true
    }

    /// Forward from the app delegate's failed remote-registration callback.
    static func didFailToRegisterForRemoteNotifications(error: Error) {
        let message = apnsRegistrationDiagnostic(error)
        onLog("✗ \(message)")
        fireRegistrationFailed(message)
    }
}

extension OpenPush {
    static func apnsRegistrationDiagnostic(_ error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, 3000):
            return "APNs registration failed — this build has no 'aps-environment' " +
                   "entitlement. Add the Push Notifications capability to the app target " +
                   "and sign with a provisioning profile that includes it."
        case (NSCocoaErrorDomain, 3010):
            return "APNs registration failed — this simulator cannot issue a device token. " +
                   "Remote notifications in the simulator need iOS 16 or newer on macOS 13 " +
                   "or newer; otherwise test delivery on a physical device."
        case (NSURLErrorDomain, _):
            return "APNs registration failed — this device could not reach Apple's push " +
                   "service (\(error.localizedDescription)). iOS retries on its own once " +
                   "connectivity returns."
        default:
            return "APNs registration failed — \(error.localizedDescription)"
        }
    }
}
