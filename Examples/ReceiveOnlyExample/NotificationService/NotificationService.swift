import OpenPushNSE
import UserNotifications

/// A whole Notification Service Extension. The handler applies the payload's
/// action buttons, fetches `image_url` as an attachment, posts the delivery
/// receipt, and calls the content handler exactly once on every path — including
/// the expiry path and a payload OpenPush did not send.
final class NotificationService: UNNotificationServiceExtension {
    private let openPush = OpenPushNotificationServiceHandler(
        options: ExampleNSEOptions.make()
    )

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        openPush.didReceive(request, withContentHandler: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        openPush.serviceExtensionTimeWillExpire()
    }
}
