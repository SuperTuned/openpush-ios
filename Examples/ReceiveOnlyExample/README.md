# OpenPush iOS feature lab

This example is a runnable workbench for the `openpush-ios` client surface a
host app integrates: permissions and push subscriptions, identity and targeting
data, the observers and listeners, notification fixtures, Live Activities, and
the in-app message engine. It uses the OpenPush console design language and
keeps every action next to the state or event it changes.

## What you can test

- notification permission and push opt-in/opt-out;
- subscription ID, APNs token, status, and registration callbacks;
- `pushSubscription.snapshot()` and `OpenPush.currentToken` read live, beside the
  observed state, an app-side `OpenPush.receipt` for the last message seen, and
  the receipt queue's depth as `OpenPush.pendingReceiptCount`;
- login, logout, and plural tag and alias writes — several pairs per call, and
  multi-select removal;
- permission, subscription, subscription-change, foreground, click, and SDK-log
  observers;
- both spellings of the foreground presentation decision: the synchronous
  `processForeground(_:)`, and the asynchronous
  `processForeground(_:completion:)` that lets a listener take `preventDefault()`
  back with `display()`;
- local notifications through the real `UNUserNotificationCenterDelegate`
  forwarding path, with Simple, Image, Button, Custom, and Sound fixtures;
- a rendered ActivityKit Lock Screen/Dynamic Island experience;
- automatic and manual Live Activity update-token, push-to-start-token, and
  exit forwarding;
- a tracked tap on the Live Activity: the widget's `openpushWidgetURL`, the
  app's `onOpenURL`, and `trackClickAndReturnOriginal(_:)`;
- the default attributes path — `setupDefault(options:)`, `startDefault(_:attributes:content:)`,
  and push-to-start token removal — for an app with no attributes type of its own;
- the device credential's whole lifecycle through `DeviceCredentialStore`: save,
  wipe, and the one-release migration out of the App Group;
- the native Live Activities and More Frequent Updates authorization states,
  including live changes made in iOS Settings;
- a Notification Service Extension built from the one-call handler: action
  parsing, rich-media attachment, and delivery-receipt telemetry, all visible in
  the Status workspace;
- provisional authorization, the unflattened permission status, and whether this
  SDK may still raise the prompt;
- an optional host-app privacy consent gate that delays SDK initialization and
  automatic Live Activity token observation until consent is granted;
- in-app message triggers of every value kind, the pause switch, and the
  lifecycle and click listeners;
- `OpenPush.trackEvent` from the Events workspace's **Custom events** panel.

OpenPush's iOS SDK is receive-only. Notification creation and sending stay in
the OpenPush console, so the app does not pretend to offer a client-side send
API. Location is the only thing the SDK leaves out; phone numbers, phone codes
and email addresses are in the SDK but not yet in the Feature Lab. In-app
messaging is demonstrated in the In-app workspace, which drives the real
`OpenPush.InAppMessages` trigger, pause, and listener APIs, and the Events
workspace's **Custom events** panel calls `OpenPush.trackEvent` directly.

## Demo mode

Demo mode is selected automatically while the App ID and SDK key are still
placeholders, which is what a fresh checkout builds: every identifier and
credential comes from `Build.xcconfig`, whose defaults are placeholders, unless
a git-ignored `Local.xcconfig` overrides them (see **Connect Live mode**). Demo
mode uses clearly labelled synthetic subscription data and never writes to
OpenPush. Native iOS behavior remains real: permission prompts, local
notifications, foreground/click delegate callbacks, and ActivityKit all use
the Simulator or device.

Use the settings button on any tab to switch appearance or inspect runtime
configuration. Live mode unlocks automatically after valid credentials are
configured and the app is relaunched.

Its **Request identification** section shows the two headers every OpenPush
request carries its identity in. `X-OP-SDK` is always `openpush/ios/<version>`,
from the same constant the app and the service extension both build from, so the
two processes can never claim different versions. `X-OP-SDK-Wrapper` is sent only
by a wrapper SDK that set `OpenPush.wrapper` before `initialize`; this sample
integrates OpenPush directly, so it reads **none**.

## Host-controlled consent

OpenPush does not expose a consent property of its own. The Privacy
consent panel demonstrates the integration boundary instead: the sample stores
the host app's decision and does not call `OpenPush.initialize` or
`OpenPush.LiveActivities.setup` until the decision permits SDK startup.

Enable **Require consent before SDK start**, then relaunch to verify the waiting
state. Granting consent starts the SDK in the current process. Resetting saved
consent after initialization only affects the next launch because OpenPush has
no runtime shutdown API; it cannot undo data already transmitted. Production
apps should connect this gate to their own consent policy and persistence.

## Identity and targeting data

The **User** workspace writes tags and aliases the way the SDK is built to take
them: **Add tags** and **Add aliases** open an editor with an **Add another row**
affordance, and every complete row travels in one `OpenPush.User.addTags(_:)` or
`addAliases(_:)` call. Blank rows are ignored. Because both kinds of write share
one fixed 300 ms window, a batch of tags and a batch of aliases set together
become a single registration rather than one per pair.

Removal is plural too. Each row carries a selection control; selecting rows
reveals **Remove N selected**, which calls `removeTags(_:)` or
`removeAliases(_:)`. The per-row trash is still there for the singular
`removeTag(_:)`/`removeAlias(_:)` path. A deletion keeps the key in the next
registration body with an empty value — that is the server's delete signal, and
omitting the key would leave the old value in place — but `getTags()` stops
reporting it immediately, because a staged deletion is not a tag.

## Subscription state, live

The Status workspace's **Device registration** panel separates two things hosts
routinely conflate. The Subscription ID, APNs token, and Credential rows show the
state the observer last handed over, which in Demo mode is synthetic. The
**currentToken** and **snapshot()** rows read the SDK itself at the moment they
are drawn: `OpenPush.currentToken` is the process-wide accessor, and
`pushSubscription.snapshot()` captures id, token, `optedIn`, and `status` as one
equatable `PushSubscriptionState` you can diff or store.

**App-side receipt** posts `OpenPush.receipt("received", messageID:)` or
`OpenPush.receipt("clicked", messageID:)` for the last message id this process
saw — a scheduled fixture, a foreground delivery, or a click. The menu is
disabled until there is one. The service extension posts for a message it
handled and the app posts for one it saw itself; the two processes cannot see
each other's receipts, and the server keeps the first timestamp, so a duplicate
is harmless. A receipt needs an initialized SDK and an APNs token: with either
missing the call returns without a request, and the workspace says so instead of
reporting a send that never happened.

**Receipts pending** is `OpenPush.pendingReceiptCount`: how many receipts this
install still owes the server. The queue is persisted, so a receipt the server
did not accept outlives the process and is retried — after 2, 8, and 30 seconds,
and then on every foreground or completed registration. A count that stays above
zero is what a failing receipt looks like from the outside, which is why the SDK
exposes it: a host's own diagnostics screen can show the same number. Receipts
the service extension posts are in another process and are not counted here.

The Events workspace runs `addObserver` and `addChangeObserver` side by side.
The plain observer reports the new state; the change observer reports the state
it replaced next to it, rendered **previous → current** in the **Last
subscription change** row. The chain is continuous — each change's `previous` is
the one before it, and the first has none. The two observer lists are separate,
so an id from one cannot remove from the other.

## Foreground presentation, decided twice

A notification that arrives while the app is on screen is the host's decision,
and the SDK offers two ways to make it. The Events workspace's **Listener
controls** panel runs both.

**Suppress foreground presentation** on its own is the synchronous path: the app
delegate returns `OpenPush.Notifications.processForeground(notification)`, the
foreground listener calls `preventDefault()` while it runs, and no banner is
shown. This is the default, and it is the right shape when the host always knows
its answer immediately.

Add **…then display after 2 s** and the delegate switches to
`processForeground(_:completion:)`, which does not return an answer: it holds
iOS's completion handler while the listener calls `preventDefault()` and then,
two seconds later, `event.display()` — which releases the banner after all. Use
it when the in-app surface you meant to show instead might not be showable, so
the notification is not simply lost. The synchronous spelling cannot honor
`display()`, because it has already answered; there it is a no-op. A
`preventDefault()` that is never followed by a `display()` resolves to suppressed
after 25 seconds, so the delegate is always answered exactly once.

Because a listener runs inside `processForeground` and its decision has to be
visible by the time that call returns, the sample keeps both switches in a small
lock-guarded value both the listener and the delegate read inline
(`ForegroundPresentationChoice`) rather than reading them off the main-actor
model. A host with the same shape needs the same care.

## In-app messages

The **In-app** workspace drives `OpenPush.InAppMessages` directly. Triggers are
process-local: **Add trigger** takes a key, a value, and a value kind (String,
Number, or Bool) and calls `addTrigger(_:withValue:)`, each row removes one key,
and **Clear triggers** empties the set. Every change re-evaluates the queue, so
a message whose conditions have just become true is presented immediately. The
calls are identical in Demo mode—the engine simply has no definitions to match,
because Demo mode never fetches.

The **Paused** switch mirrors `OpenPush.InAppMessages.paused`. Pausing takes the
message on screen down without counting a display: it returns to the front of
the queue and is shown again when you resume.

The **Last events** panel shows the most recent lifecycle stage as a badge
(`willDisplay`, `didDisplay`, `willDismiss`, `didDismiss` — the event carries a
typed `stage`, and the `phase` string is that stage's raw value), the message id,
the layout it was presented with, and the most recent click, with its action id,
URL, whether the click closes the message, and whether it was the message's first
click. Both listeners also write into the Events stream. `didDisplay` arrives
only after the document has actually rendered, so a message that fails to load
reports nothing and is skipped for the rest of the session. In Demo mode,
**Preview in-app lifecycle** writes the four stages, and the click one of the
message's buttons would report, into the stream so the event shape is visible
without a server.

Live mode fetches eligible definitions after registration and after a new app
session, and renders them in the SDK's guarded WKWebView. The message gets a
window of its own, one level below the system alert level, and a `top` or
`bottom` banner is sized to its document: touches outside the banner's strip
still reach the app's own window underneath.

## Live Activities

The **Activity** workspace covers three separate things.

**ActivityKit preview** requests a real `ExampleDeliveryAttributes` activity and
the bundled widget extension renders it. Both presentations carry a tap target:
the Lock Screen view and the Dynamic Island's compact and minimal regions call
`openpushWidgetURL(_:context:)` instead of SwiftUI's `widgetURL`. That wrapper
folds the activity id, the activity type, and the update's notification id into
a tracking URL and carries the app's own destination — here
`openpush-example://activity/<activity id>` — inside it. The app's
`CFBundleURLTypes` declares that scheme, `onOpenURL` hands the URL to
`OpenPush.LiveActivities.trackClickAndReturnOriginal(_:)`, and what comes back
is the destination, with the click already recorded. A URL that was never an
OpenPush tracking URL is returned untouched, so unrelated deep links still
route. **The SDK does not navigate** — the **Last tap routed to** row shows the
destination the app was handed and leaves the routing to the app.

**Default attributes** is the path for an app that defines no
`ActivityAttributes` type of its own. **Set up default attributes** calls
`setupDefault(options:)` with the two `OpenPushLiveActivitySetupOptions`
switches above it, which decide whether push-to-start and push-to-update tokens
are observed; they are read at the call, not applied live, because `setup`
chooses once what it watches. **Start default activity** calls
`startDefault(_:attributes:content:)`, which requests the activity through
ActivityKit for you from two dictionaries. **Remove push-to-start token**
(iOS 17.2 and up) tells the server to stop starting activities of this type on
this device.

**Manual token lab** is the opposite end: the app owns ActivityKit observation
and forwards the tokens itself.

## The device credential

The Status workspace's **Credential** panel drives `DeviceCredentialStore`
directly. **Save credential** writes to the shared Keychain access group —
`save(_:)`, whose `OSStatus` is reported as-is — **Wipe credential** removes it
with `wipe()`, and **Migrate legacy credential** runs
`migrateLegacy(defaults:key:)`, the one-release move of a credential an older
build mirrored into the App Group in plaintext. The plaintext copy is removed
only after the Keychain write succeeds, and a fresh install has nothing to move
and says so. The credential never goes into the App Group: an App Group is
readable by every extension the app ships, which is the whole reason the shared
Keychain is used instead.

## Run on Simulator

```sh
cd Examples/ReceiveOnlyExample
xcodegen generate
open ReceiveOnlyExample.xcodeproj
```

Choose the `ReceiveOnlyExample` scheme and any iOS 16-or-newer Simulator. To
inject the bundled remote-push fixture after installing the app:

```sh
xcrun simctl push booted ai.openpush.example Support/demo-notification.apns
```

The fixture includes two action buttons, an `image_url`, and a `deep_link`, and
exercises the same foreground and click listeners as a real OpenPush
notification. The Status workspace reports the extension's parsed actions, the
attachment result, and the last receipt attempt. Receipt delivery needs a signed
Live-mode build with the configured shared App Group and credential; the in-app
**Schedule local notification** action is the credential-free listener
alternative.

## Rich notifications

`NotificationService/NotificationService.swift` is the whole extension:

```swift
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
```

For one notification the handler registers the payload's action category and
sets it on the content, downloads `image_url` into a `UNNotificationAttachment`,
and posts the `received`/`confirmed` receipt after a random delay of up to two
seconds. The download and the receipt start together, so the jitter overlaps the
fetch instead of following it. It delivers once all three have settled, because
calling the content handler lets iOS suspend the extension and a receipt still in
flight would die with it. `serviceExtensionTimeWillExpire` delivers whatever is ready; the
buttons are applied synchronously, so they survive an expiry even when the image
does not. A payload OpenPush did not send is handed straight back untouched.

`NotificationService/ExampleNSEOptions.swift` supplies the two host-specific
values — the App Group and the shared-Keychain credential store — and this
sample's own `onEvent` closure, which writes the handler's one-line reports into
the App Group for the Status workspace to read (`actions: 2` — the number of
buttons actually registered, `0` when a category the app owns was left alone —
`attachment: ok|skipped|failed`, `receipt: HTTP 200` or
`receipt: skipped (<reason>)`). A shipping app does not need `onEvent`.

`Shared/ExampleIdentifiers.swift` holds the App Group, Keychain access group,
and credential service, and both targets compile it, so the app and the
extension cannot drift apart. It does not spell the two groups out: it reads
them from its own bundle's Info.plist, which the build fills in from
`OPENPUSH_APP_GROUP` and `OPENPUSH_KEYCHAIN_GROUP` in `Build.xcconfig` — the
same two settings the entitlements files reference, so the code, the
entitlements, and the project settings cannot disagree. The app passes the same
App Group to `OpenPush.initialize(appId:appGroup:credential:)`, which mirrors
the app id, server URL, SDK key, APNs token, and subscription id into it. The
device credential is never mirrored: an App Group is readable by every
extension the app ships, so the credential stays in the shared Keychain.

### Seeing the image on the Simulator

The attachment is fetched over the network, so the Simulator needs working
connectivity, and `image_url` must be `https` with an allowlisted media type.

```sh
xcrun simctl push booted ai.openpush.example Support/demo-notification.apns
```

Pull the banner down (or open the notification centre) to see the image and the
two buttons. If it renders as text only, the fetch was refused — the Status
workspace's **Attachment** row says `failed`, and the extension's `NSLog` line
appears in Console.app under the `NotificationService` process.

`deep_link` is the launch URL. It arrives on the click event as
`event.notification.launchURL`, and the Events stream prints it. The
SDK also opens it on the tap, by default; set
`OpenPush.Notifications.openLaunchURLs = false`, or the Info.plist boolean
`OpenPushSuppressLaunchURLs`, to leave routing to the app.

## Connect Live mode

Every identifier and credential lives in one file, so there is one copy of each
to change and nothing tracked to edit.

1. Copy `Local.xcconfig.example` to `Local.xcconfig`.
2. Fill in your `DEVELOPMENT_TEAM`, `OPENPUSH_BUNDLE_PREFIX`,
   `OPENPUSH_APP_GROUP`, `OPENPUSH_KEYCHAIN_GROUP`, and the `OPENPUSH_APP_ID`
   and public `OPENPUSH_SDK_KEY` from the OpenPush console. Delete or comment
   out a line to keep its Demo-mode default from `Build.xcconfig`; an empty
   value overrides that default rather than falling back to it.
3. Regenerate the project with `xcodegen generate`. The bundle ids, both
   entitlements files, and the app's and the extension's Info.plists are all
   built from those settings.
4. Store the linked installation credential with `DeviceCredentialStore`.
5. Enable Push Notifications, App Groups, and Keychain Sharing with matching
   values for the app and Notification Service Extension.

`Local.xcconfig` is git-ignored, so your team id and SDK key stay out of the
repository; `Local.xcconfig.example` is the tracked template. A checkout without
a `Local.xcconfig` still generates and builds — the include is optional.

The sample app plist enables both `NSSupportsLiveActivities` and
`NSSupportsLiveActivitiesFrequentUpdates`. The latter makes iOS expose the
separate **More Frequent Updates** setting and permits a higher ActivityKit
remote-push budget; it does not gate individual update-token creation.

The AppDelegate already forwards APNs registration, foreground delivery, click,
and background (`content-available`) push callbacks. The Notification Service
Extension reads its OpenPush configuration from the App Group mirror, falling
back to its own Info.plist, and posts background receipts. The Live
Activity widget shares `ExampleDeliveryAttributes` with the app, while
`OpenPush.LiveActivities.setup` observes and forwards its tokens.

Identity verification hashes must come from your server—never compute them in
the app.

The User screen's **Auth hash (optional)** field stands in for that server call:
in live mode it is passed to `OpenPush.login(externalId:authHash:)`, and in demo
mode it is only acknowledged in the event log and never sent. The sample also
installs `OpenPush.onIdentityVerificationRequired`, which fires when a relaunch
restored an identity without its hash; log in again with the hash to restore it.

## Tests

The `ReceiveOnlyExampleUITests` target verifies all five workspaces are
reachable, demo login, the plural tag and alias writes and the multi-select
removal, the observer controls, the **Custom events** panel, the notification
fixtures and the editable custom fixture, the in-app trigger, pause, and clear
controls, the in-app stage badge and click row rendered from the Demo preview,
the settings sheet's appearance switch, the host consent gate, the Live
Activities authorization readout, and ActivityKit start/end where the selected
Simulator runtime supports Live Activities.
`testDefaultLiveActivityControlsExist` asserts the default-attributes controls
without starting an activity, which would outlive the test.

CI runs this target on a Simulator:

```sh
xcodebuild test \
  -project ReceiveOnlyExample.xcodeproj \
  -scheme ReceiveOnlyExample \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ReceiveOnlyExampleUITests \
  CODE_SIGNING_ALLOWED=NO
```
