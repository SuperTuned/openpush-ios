# OpenPush shared extension example

An app that already ships its own Notification Service Extension, with OpenPush
added to that extension rather than beside it. A push carrying `op_message_id`
is OpenPush's; every other push runs the extension's existing code unchanged.

## The existing extension

Before OpenPush, `NotificationService` did one thing of its own: a push carrying
`host_message_id` gets " (host)" appended to its title, and every other push is
delivered as it arrived.

```swift
import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
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
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
```

## What OpenPush added

`import OpenPushNSE`, a stored handler property at the top of the class, and
one line at the top of each override — the two lines from the main README's
[Existing extension](../../README.md#existing-extension) section:

```swift
private let openPush = OpenPushNotificationServiceHandler(options: {
    var options = OpenPushNotificationServiceHandler.Options()
    options.appGroup = Bundle.main.object(forInfoDictionaryKey: "SharedExtensionAppGroup") as? String
    return options
}())

// first line of didReceive(_:withContentHandler:)
if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }

// first line of serviceExtensionTimeWillExpire()
if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
```

`handleIfOpenPush` returns `false` for a push OpenPush did not send and never
touches its content handler, so the host's code below it runs exactly as before.
For an OpenPush push it applies the action buttons, fetches `image_url`, posts
the delivery receipt and calls the content handler exactly once.

This is what `openpush-ios-setup apply --nse-mode share` produces from the
extension above, line for line, with one difference: the tool writes the App
Group as a string literal, and this sample reads it from the extension's
Info.plist so it comes from the same `Build.xcconfig` as both entitlements files.
The only other change to the extension target is linking `OpenPushNSE`.

The app initializes OpenPush with the same App Group,
`OpenPush.initialize(appId:appGroup:)`, which mirrors the app id, server, SDK
key, APNs token and subscription id into it for the extension. No device
credential is shared: the receipt is authenticated on the SDK key.

## Identifiers

| | |
|---|---|
| Scheme | `SharedExtensionExample` |
| App bundle id | `ai.openpush.example.sharedextension` |
| Extension bundle id | `ai.openpush.example.sharedextension.NotificationService` |
| App Group | `group.ai.openpush.example.sharedextension` |

All of them come from `Build.xcconfig`. To run on a device, copy
`Local.xcconfig.example` to `Local.xcconfig`, set your team, a bundle prefix and
App Group your team owns, and the app id and public SDK key from the OpenPush
console, then generate again. `Local.xcconfig` is git-ignored. With the
placeholder credentials OpenPush is not initialized; the app still registers for
push and shows its APNs token, and the extension still runs.

## Run it

```sh
xcodegen generate
open SharedExtensionExample.xcodeproj
```

Run the `SharedExtensionExample` scheme and tap **Allow notifications**. The
screen shows the APNs token and, once OpenPush has registered, the subscription
id — the two values a device tester needs to target this install.

## Try it on the Simulator

With the app installed on a booted Simulator and notifications allowed, send
each payload in `Payloads/`. Both carry `"mutable-content": 1`, which is what
routes a push through the service extension.

```sh
xcrun simctl push booted ai.openpush.example.sharedextension Payloads/openpush-push.apns
xcrun simctl push booted ai.openpush.example.sharedextension Payloads/host-push.apns
```

- `openpush-push.apns` carries `op_message_id`: OpenPush's handler delivers it
  and its title is unchanged. With placeholder credentials the receipt is
  skipped, because nothing was mirrored into the App Group.
- `host-push.apns` carries `host_message_id`: the extension's own code delivers
  it as "Host push (host)".

The bundle id argument can be left out: each file also names the app under
`Simulator Target Bundle`.
