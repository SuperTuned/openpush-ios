import Foundation
import UserNotifications
import OpenPushNSE

/// An extension the app already shipped for its own sender, with OpenPush added
/// to it. The app's own work: a push carrying `host_message_id` gets " (host)"
/// appended to its title, and every other push is delivered as it arrived.
///
/// OpenPush added exactly three things, the same three `openpush-ios-setup
/// apply --nse-mode share` inserts: `import OpenPushNSE`, the handler
/// property, and the first line of each override. A push carrying
/// `op_message_id` is OpenPush's, and `handleIfOpenPush` delivers it; for any
/// other push it returns `false` without touching the content handler, and the
/// code below runs exactly as it did before.
final class NotificationService: UNNotificationServiceExtension {
    private let openPush = OpenPushNotificationServiceHandler(options: {
        var options = OpenPushNotificationServiceHandler.Options()
        // Read from this extension's Info.plist, which `Build.xcconfig` fills in,
        // so it cannot drift from the entitlements. The setup tool writes the
        // group as a string literal instead.
        options.appGroup = Bundle.main.object(forInfoDictionaryKey: "SharedExtensionAppGroup") as? String
        return options
    }())

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content
        if request.content.userInfo["host_message_id"] != nil {
            content.title += " (host)"
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
