import UserNotifications
import RichMedia

@objc(RichPushService)
final class RichPushService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent
        guard let bestAttempt else { return contentHandler(request.content) }
        bestAttempt.title = "[Shop] " + bestAttempt.title
        RichMedia.attach(to: bestAttempt) { contentHandler($0) }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }
}
