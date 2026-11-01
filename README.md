# openpush-ios

Swift package for registering an iOS device with OpenPush.ai, identifying its
user, and posting notification delivery receipts. It intentionally contains no
message creation, campaign management, or send API.

It covers push registration and permission, identity and targeting data,
phone numbers and email addresses, in-app messages, Live Activities, VoIP
pushes, and a Notification Service Extension handler for action buttons, rich
media and delivery receipts. Sending stays on the server and in the OpenPush
console.

## Requirements

- iOS 16 or newer
- Swift 6
- an OpenPush.ai App ID and public SDK key
- Push Notifications enabled for the host app
- a Notification Service Extension for background delivery receipts and rich
  notification processing

## Products

| Product | Purpose |
|---|---|
| `OpenPushCore` | Shared configuration, payload parsing, and Keychain credential storage |
| `OpenPush` | APNs token registration, identity and targeting data, phone numbers and phone codes, email addresses, in-app messages, and app-side delivery receipts |
| `OpenPushLiveActivities` | The extension-safe Live Activity attributes, content state, and widget-URL helpers |
| `OpenPushNSE` | The Notification Service Extension handler: action buttons, media attachments, and delivery receipts |
| `OpenPushOneSignal` | The opt-in compatibility facade for hosts migrating from another push SDK |
| `OpenPushVoIP` | VoIP pushes for calling apps: PushKit registration, the VoIP token, and incoming VoIP pushes |

Link `OpenPush` to the app target and `OpenPushNSE` to the Notification Service
Extension. **Link `OpenPushLiveActivities` — not `OpenPush` — to the widget
extension:** the main product uses UIKit and is not extension-safe, which is why
the attributes live in their own product that both the app and the widget can
link. `OpenPush` re-exports it, so an app that links `OpenPush` already has it.

## Installation

### Swift Package Manager

In Xcode, choose **File → Add Package Dependencies** and enter:

```
https://github.com/SuperTuned/openpush-ios.git
```

Select the `1.2.2` version rule, then link the products to the targets as the
table above describes. Both the app and the extension may also use
`OpenPushCore` directly.

For a `Package.swift` consumer:

```swift
dependencies: [
    .package(
        url: "https://github.com/SuperTuned/openpush-ios.git",
        .upToNextMajor(from: "1.2.2")
    )
]
```

### CocoaPods

The pods are not yet available from the CocoaPods trunk. Until they are, use
Swift Package Manager, or take the pods straight from this repository's `1.2.2`
tag. Every OpenPush pod you use, and every OpenPush pod it depends on, needs
the same `:git` and `:tag`:

```ruby
openpush = { :git => 'https://github.com/SuperTuned/openpush-ios.git', :tag => '1.2.2' }

target 'App' do
  pod 'OpenPushCore', openpush
  pod 'OpenPushLiveActivities', openpush
  pod 'OpenPush', openpush
end

target 'NotificationService' do
  pod 'OpenPushCore', openpush
  pod 'OpenPushNSE', openpush
end

target 'LiveActivityWidget' do
  pod 'OpenPushLiveActivities', openpush
end
```

`OpenPush` depends on `OpenPushCore` and `OpenPushLiveActivities`; add
`pod 'OpenPushOneSignal', openpush` to the app target for the opt-in
compatibility facade, and `pod 'OpenPushVoIP', openpush` for VoIP pushes.
Each product is a pod of its own rather than a subspec of one pod because
CocoaPods compiles a single Swift module per pod, and these products are
separate modules.

## Setup tool

`openpush-ios-setup` adds OpenPush to an existing Xcode project and reuses the
push plumbing the project already has: its App Group, its notification service
extension with that extension's bundle id and provisioning profile, its Keychain
group, and its widget extension. It is a separate Swift package in
`Tools/OpenPushSetup`, so an app that depends on the SDK never resolves the
tool's own dependencies. Run it from a checkout of this repository:

```sh
swift run --package-path Tools/OpenPushSetup openpush-ios-setup scan --project path/to/App.xcodeproj
swift run --package-path Tools/OpenPushSetup openpush-ios-setup apply --project path/to/App.xcodeproj \
    --app-id <app id> --sdk-key <public SDK key>
```

`scan` lists what the project already has, and changes nothing:
notification service, content and widget extensions (classified by their
`NSExtensionPointIdentifier`, generated Info.plists included), App Groups,
Keychain groups and `aps-environment` per target and configuration with
`$(VARIABLES)` expanded through xcconfig files, the `remote-notification`
background mode, and the push SDKs linked into the extensions. `--json` prints
it as the setup answer file; `--write` stores it in `.openpush/setup.json`.

`apply` asks once for each thing it found, **Reuse** being the default, and
stores the answers in `.openpush/setup.json`. Commit that file: a later run, and
CI, then never asks. With `--yes` it takes the Reuse defaults without asking; a
choice with no safe default (an App Group on the app alone, or two candidate
groups) fails with the option to pass instead of guessing. Then it applies,
idempotently:

- Push Notifications and the `remote-notification` background mode;
- the chosen App Group (and Keychain group, when there is one) on the app and
  the extension, merged into the entitlements file each target already uses;
- `OpenPushAppID` and `OpenPushSDKKey` in the app's Info.plist and the
  extension's;
- `OpenPush` linked to the app, `OpenPushNSE` to the extension and
  `OpenPushLiveActivities` to the widget, as Swift packages. A CocoaPods project
  gets the Podfile lines to add instead; the Podfile is never edited.

The service extension is handled in one of four modes (`--nse-mode`):

| Mode | Default when | What it does |
|---|---|---|
| `take_over` | the extension is a known vendor's template | rewrites its principal class as OpenPush's handler, keeping the class name its Info.plist names, its bundle id, team, entitlements and profile; removes the vendor's dependency from it |
| `share` | the extension is your own code | inserts the two lines from [Existing extension](#existing-extension) and a handler property; if it cannot place them, it writes them to `.openpush/share.patch` and stops |
| `inject` | there is no extension | creates `OpenPushNotificationService` |
| `off` | only when asked | changes nothing, and says what is lost |

A target the tool creates (`inject`, or `--widget-mode new`) copies the app's
`DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE` and `CODE_SIGN_IDENTITY` per configuration.
Its bundle id defaults to `<app bundle id>.OpenPushNotificationService` (or
`.LiveActivityWidget`), and its App Group to `group.<app bundle id>.openpush`;
`--nse-bundle-id`, `--widget-bundle-id` and `--app-group` change them. Under
manual signing it refuses to finish until `--nse-profile` (or `--widget-profile`)
names a profile, either one for every configuration or
`"Debug=<name>,Release=<name>"`. The signing values a target already has —
`PROVISIONING_PROFILE_SPECIFIER`, `PROVISIONING_PROFILE`, `CODE_SIGN_STYLE`,
`CODE_SIGN_IDENTITY` — are never changed, and the report lists what was kept.

Every file is backed up to `.openpush/backup/<timestamp>/` before it changes.
Nothing is written until every step has succeeded; if writing then fails part
way, the files already written are put back from that backup.

## App setup

Configure the receive client during app launch. The device credential closure
must return the credential belonging to the currently linked installation, or
`nil` before the device is linked.

```swift
import OpenPush

OpenPush.initialize(
    appId: "your-app-id",
    credential: { DeviceSession.currentCredential }
)
```

Put your public SDK key in the app's `Info.plist` under `OpenPushSDKKey`, and
`initialize` needs only the app id. To keep it in code instead, call
`initialize(appId:sdkKey:)` — an explicit key always wins over the bundled one.

`initialize` defaults to `OpenPush.defaultServerURL`; pass `serverURL:` to point
at a staging endpoint or a proxy you run in front of OpenPush,
`provisional: true` to request quiet authorization with no prompt, and
`appGroup:` to mirror what a Notification Service Extension needs (below).
`attach(configuration:credential:transport:)` remains available for hosts that
build their own `OpenPushConfiguration`.

Coming from another push SDK? There are two routes, and both refuse a call
OpenPush does not implement at compile time rather than silently doing nothing:

- Keep the spelling your call sites already use: add the opt-in
  `OpenPushOneSignal` compatibility facade and change one import line. The
  exception is the protocol-based listeners and observers (`addClickListener`,
  `addForegroundLifecycleListener`, `addPermissionObserver`,
  `pushSubscription.addObserver`): they take a closure here rather than a
  conforming object, so those call sites are a type error until you rewrite them
  as closures. Do not link the facade and the SDK it replaces into one target —
  both define the same top-level enum.

- Or drop the spelling: adopt `OpenPush.` directly. Every member the
  compatibility surface maps keeps its name, and four overloads exist so the four
  signatures that would otherwise differ compile too.

[`MIGRATING-FROM-ONESIGNAL.md`](MIGRATING-FROM-ONESIGNAL.md) walks the whole
migration — the import change, the delegate forwarding OpenPush requires because
it never swizzles, and tables of every forwarded and every refused symbol.
`API.md` maps the OpenPush surface itself.

When authorization already exists, a normal initialize asks iOS to re-issue the
APNs token without prompting, so a rotated token is re-synchronized.

## In-app messages

No extra initialization is required. After a subscription registers, OpenPush
fetches eligible definitions and presents them in a safe-area-aware WKWebView.
Later sessions begin after at least 30 seconds in the background.

```swift
OpenPush.InAppMessages.addTrigger("level", withValue: 12)
OpenPush.InAppMessages.addTriggers(["plan": "pro", "onboarded": true])

let lifecycle = OpenPush.InAppMessages.addLifecycleListener { event in
    print(event.messageId, event.phase)
}
let clicks = OpenPush.InAppMessages.addClickListener { event in
    print(event.messageId, event.actionId ?? "")
}
```

Dismissals, stable click ids, last-dismissal time, and redisplay counters persist
across launches. URL, notification-permission, tag, outcome/custom-event, and
custom-id actions are bridged to native code. Set
`OpenPush.InAppMessages.paused` to temporarily suppress presentation.

Forward the APNs device token from the application delegate:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    OpenPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
}

func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
) {
    OpenPush.didFailToRegisterForRemoteNotifications(error: error)
}
```

Ask for authorization when the user has a reason to say yes:

```swift
OpenPush.Notifications.requestPermission(fallbackToSettings: true) { granted in
    // A grant also starts APNs registration.
}
```

The SDK asks iOS for a push token only once notification permission is granted
(fully or provisionally). Until then there is no token and so no subscription:
no in-app messages, no Live Activity tokens, and no custom events attributed to
this install (they wait on the device unless the user is logged in). Show your own
screen explaining what notifications are for before you call
`requestPermission`, so the system prompt appears when the user is ready to
accept it.

`OpenPush.Notifications.permissionStatus` reports the authorization iOS actually
gave — `.notDetermined`, `.denied`, `.granted`, `.provisional`, or `.ephemeral` —
rather than the boolean `permission` flattens it to. Read
`canRequestPermission` before deciding to explain yourself first: it is true
only while authorization is undetermined **and** this SDK has never raised the
prompt, so it answers for this SDK rather than for iOS.

`OpenPush.Notifications.requestProvisionalPermission()` asks for quiet
authorization: no prompt at all, delivery straight to the notification centre,
and the user promotes or silences it from the notification itself. It never
routes to Settings, because nothing was refused.

OpenPush reports iOS `notification_types` on every registration and recomputes
it at launch and whenever the app enters the foreground. A permission change in
Settings therefore reaches the server on the next launch/foreground, and only a
changed value causes another registration. UIKit apps are observed automatically;
a host without UIKit should call `OpenPush.Notifications.onAppForegrounded()`
from its own lifecycle callback.

Identify the user after sign-in, and detach on sign-out:

```swift
OpenPush.login(externalId: user.id, authHash: user.openPushAuthHash) { result in
    if case .identityRejected(let note) = result {
        // The device is registered but anonymous. Do not show it as identified.
        Diagnostics.record("openpush identity rejected: \(note)")
    }
}

OpenPush.logout()
```

Compute `authHash` on your server. A login before the APNs token arrives is
kept and sent with the next registration. The external ID persists across a
cold start, but the authentication hash is a bearer identity proof and remains
memory-only; supply it again by calling `login` at launch.

Because the hash is memory-only, a relaunch restores the external ID without its
proof. OpenPush will not assert an identity it cannot prove: until `login` runs
again with the hash, registrations omit `external_id` entirely, so the server
keeps the existing link rather than stripping it. Install a hook to learn when
that happens — assign it before or after `initialize`, and a request raised
before it existed is delivered as soon as it is:

```swift
OpenPush.onIdentityVerificationRequired = { externalId in
    // Fetch a fresh hash for this user, then call login again.
    Backend.openPushAuthHash(for: externalId) { hash in
        OpenPush.login(externalId: externalId, authHash: hash)
    }
}
```

It fires once per process. Logging in as a different user, or logging out,
clears the tags and aliases this device staged, so one person's targeting data
is never written onto another.

Attach tags and read the subscription state:

```swift
OpenPush.User.addTags(["plan": "pro", "locale": "en-GB"])
OpenPush.User.removeTags(["trial_expiry", "old_segment"])

let subscription = OpenPush.User.pushSubscription
```

Tag and alias writes persist immediately and share a fixed 300 ms window, so a
burst becomes one whole-map registration. Pending writes flush when the app
backgrounds. `getTags()` returns the tags this user holds: a deletion staged for
the next registration is still in the body as an empty value, but it is not a tag
any more, so it is not reported.

Record events that can enter or exit a Journey:

```swift
OpenPush.trackEvent("onboarding_started", properties: ["source": "welcome"])
```

Events are validated locally, persisted while offline, and sent in batches of
up to 50 after the same 300 ms coalescing window. Call `initialize` first; the
event is attributed to the current external ID or registered subscription.
Switching workspaces clears queued events so one account's activity cannot be
reported in another workspace.

Let the user turn push off without losing their installation, and back on again:

```swift
OpenPush.User.pushSubscription.optOut()
OpenPush.User.pushSubscription.optIn()   // prompts first if authorization is missing

let state = OpenPush.User.pushSubscription
// state.optedIn is false while the user is opted out, even with
// authorization granted and a token in hand.
```

The subscription accessor is live: a value stored before registration reflects
the later `id`, `token`, and status. Call `snapshot()` when an immutable,
equatable value is needed. Opt-out intent persists across process death.

Add lookup labels beside the external ID:

```swift
OpenPush.User.addAliases(["player_id": "p-1042", "crm_id": "c-88"])
OpenPush.User.removeAlias("crm_id")
```

Define one shared attributes type for the app and widget, using the `openpush`
field as your server-addressable fan-out topic:

```swift
struct DeliveryAttributes: OpenPushLiveActivityAttributes {
    struct ContentState: OpenPushLiveActivityContentState {
        var status: String
        var openpush: OpenPushLiveActivityContentStateData?
    }
    var orderNumber: String
    var openpush: OpenPushLiveActivityAttributeData
}

if #available(iOS 16.1, *) {
    OpenPush.LiveActivities.setup(DeliveryAttributes.self)
}
```

`setup` observes ActivityKit tokens, dismissals and confirmed receipts for you.
A host that manages tokens itself can use `enter(_:withToken:)`, `exit(_:)`,
`setPushToStartToken(_:withToken:)`, and `removePushToStartToken(_:)` directly.
Every request is queued on disk until registration or a transient outage clears.

```swift
OpenPush.LiveActivities.enter(activity.id, withToken: hexToken)
```

Link `OpenPushLiveActivities`—not `OpenPush`—to the widget-extension target, add
`NSSupportsLiveActivities` to the app plist, and use `.openpushWidgetURL` in the
widget. For activity types that need a higher remote-update budget, also add
`NSSupportsLiveActivitiesFrequentUpdates`; OpenPush observes both ActivityKit
authorization settings and synchronizes their values as device tags. Unwrap and
count widget URLs from the app's URL handler:

```swift
.onOpenURL { url in
    let original = OpenPush.LiveActivities.trackClickAndReturnOriginal(url)
    if let original { /* route original */ }
}
```

Forward the notification-center callbacks so foreground listeners fire and
app-side receipts are posted:

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
) {
    completionHandler(OpenPush.Notifications.processForeground(notification))
}

func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    OpenPush.Notifications.processClick(response)
    completionHandler()
}
```

A background (`content-available`) push never reaches
`UNUserNotificationCenterDelegate`, so forward it separately to leave a delivery
record. OpenPush never calls your completion handler for you, and never waits
for the receipt it posts:

```swift
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    OpenPush.didReceiveRemoteNotification(userInfo: userInfo)
    completionHandler(.noData)
}
```

It returns whether the payload was one OpenPush sent, so `false` means the push
is yours to handle. No click or foreground listener is ever called from there.

Call `register` only after the installation has a device credential for its
current workspace. Registration callbacks are scoped to the credential that
started the request, so a response that arrives after sign-out, reset, or an
account switch is ignored instead of changing the new session's UI state.

Use `OpenPush.onRegistered` to advance registration-dependent UI and
`OpenPush.onRegistrationFailed` to show a retry or recovery action. A
`scope_conflict` response is rendered as an instruction to reset the device,
not as a misleading connection failure. Transport errors and 5xx responses are
retried after 2 and 8 seconds; the failure hook fires only after the final
attempt. Forwarded APNs failures also use this hook, with diagnostics that name
missing Push Notifications capability and simulator limitations.

Post receipts from the app when a notification arrives or is opened:

```swift
let messageID = OpenPush.messageID(from: userInfo)
OpenPush.receipt("received", messageID: messageID)
OpenPush.receipt("clicked", messageID: messageID)
```

Action buttons, rich media, and background receipts belong in the Notification
Service Extension instead — see below.

See [API.md](API.md) for the complete public surface, and
[GettingStarted.md](GettingStarted.md) to build and run a sample end to end.
Callbacks run on the main thread; [API.md](API.md#threading) lists the
exceptions.

## Phone numbers and codes

A user's phone numbers, for SMS and WhatsApp messages, and the phone codes that
confirm them. Both use the app's SDK key and server, like every
other request the SDK makes.

```swift
OpenPush.User.addSms("+1 (415) 555-0123")  // or addWhatsApp(_:); true when queued
OpenPush.User.removeSms("+14155550123")    // or removeWhatsApp(_:): opts the number out
```

The number is read exactly as the server reads it: every character that is not
a digit or `+` is removed, a leading `00` becomes `+`, and what is left must be
`+` and 8 to 15 digits whose first digit is not `0`. So `+1 (415) 555-0123`,
`+1-415-555-0123` and `0014155550123` are all `+14155550123`, while `415`,
`+0123456789` and a number with a second `+` are invalid. Each call returns
`true` when the number is valid and the write was queued, and `false` — with a
log line that never carries the full number, and nothing sent — for an invalid
number or a call before `initialize`; the result is discardable. The number
belongs to the user logged in when the call is made. Writes are stored and retried like tag writes:
a transport failure, `429` or `5xx` is retried after 2 and 8 seconds, then held
until the next number write or accepted registration; any other refusal is
logged and dropped.

**A new number is added not verified, and receives nothing until it is
confirmed** with a phone code. An approved code marks the number's SMS and
WhatsApp subscriptions subscribed on the server:

```swift
do {
    var verification = try await OpenPush.Verify.start("+14155550123")  // channel: .auto
    // … the person types the code …
    verification = try await OpenPush.Verify.check(verification, code: typedCode)
    switch verification.status {
    case .approved: break                                  // subscribed
    case .pending: break                                   // wrong code; try again
    case .expired, .maxAttempts: break                     // start a new one
    }
} catch let error as OpenPushVerifyError {
    // error.code: .rateLimited, .tooSoon, .notPending, .provider, .optedOut
    // (replied STOP; never retry), .noCredit (no text credit left), .noRate
    // (country not priced or allowed), .refused, .invalidNumber or .network;
    // error.message says why.
}
```

`start(_:channel:locale:)` sends the code by `.auto`, `.sms`, `.whatsapp` or
`.call`, in the language `locale` names. `resend(_:channel:)` sends it again —
the server refuses a resend within 30 seconds of the last send with `.tooSoon`.
`OpenPushVerification` carries the server's `id`, the masked number
(`maskedNumber`), `channel`, `status`, `attempts` and `expiresAt`; it holds the
full number in memory only, for `check` and `resend`, and the SDK never stores
it. The calls are not retried: the person is waiting, so the error is the
app's to show.

Give the code field `.textContentType(.oneTimeCode)` (SwiftUI) or
`textContentType = .oneTimeCode` (UIKit), and iOS offers a code it received by
SMS above the keyboard. WhatsApp and voice codes are typed by hand.

## Email addresses

A user's email addresses use the same subscriptions endpoint and SDK key as
phone numbers.

```swift
OpenPush.User.addEmail(" Ana@Example.com ")  // true when queued; sent as ana@example.com
OpenPush.User.removeEmail("ana@example.com")  // removes the subscription
```

The address is trimmed and lower-cased, and must then be at most 254
characters with one `@`, something before it and a dot in the domain after it.
Anything else returns `false` with an `invalidEmail` log line, and nothing is
sent; so does a call before `initialize`. The result is discardable. The
address belongs to the user logged in when the call is made, and log lines show
only its domain.

**A new address is subscribed at once**, unless this app's suppression list has
it (it unsubscribed, bounced or complained): then the server stores it but
never emails it, and the log says so. That answer is final, so it is not
retried. **`removeEmail` is not an unsubscribe**: it removes the subscription
without adding the address to the suppression list, and a later `addEmail`
subscribes it again. To stop email to someone for good, suppress the address on
the server.

Writes are stored and retried like tags and phone numbers, in one queue with
them: a transport failure, `429` or `5xx` is retried after 2 and 8 seconds,
then held until the next write or accepted registration. A `400` — not an
address, or email is off for this app — is final: the server's words are logged
as a `refused` error and the write is dropped.

## Examples

Three runnable sample projects ship in this repository. All are generated with
XcodeGen — `xcodegen generate` in the sample's directory, then open the
`.xcodeproj`.

- [Examples/ReceiveOnlyExample](Examples/ReceiveOnlyExample) — the **Feature
  Lab**: a sanitized app, Notification Service Extension, and Live Activity
  widget that exercise the whole client surface, with every control next to the
  state it changes. It runs in Demo mode out of a fresh checkout and switches to
  Live mode from a git-ignored `Local.xcconfig`.
- [Examples/MigratedFromOneSignal](Examples/MigratedFromOneSignal) — the
  **compatibility-facade sample** for hosts migrating from another push SDK: the
  same app written entirely against the opt-in facade, so it links
  `OpenPushOneSignal` and nothing else. CI builds it, which is what proves the
  facade still carries every call site a migrating host already wrote.
- [Examples/SharedExtensionExample](Examples/SharedExtensionExample) — an app
  whose own Notification Service Extension already handles another sender's
  pushes, with OpenPush added by the two lines from
  [Existing extension](#existing-extension). It shows the APNs token and
  subscription id on screen, and carries one OpenPush and one host payload to
  try with `xcrun simctl push`.

## Not included

> Inbox is not in this release because its server capability does not exist yet.
> Custom Events are available through `trackEvent`.

## Sign-out, reset, and workspace switching

The host app owns account linking and unlinking; the receive-only package does
not expose an account-management API. To move one installation safely between
workspaces:

1. Authenticated sign-out must retire the server-side delivery address and
   revoke its device credential before local account data is cleared.
2. If unlink cannot be confirmed, keep that credential in secure storage and
   block a new link until the pending unlink succeeds.
3. Clear the local credential, cached identity, per-account arrival history,
   and external ID only after the unlink is completed or safely queued.
4. Treat a user-facing reset as the same authenticated unlink flow, not as a
   local-only wipe. A local-only reset leaves the provider token owned by the
   previous workspace and causes the next registration to fail with a conflict.

## Notification Service Extension

A whole extension is three lines. `OpenPushNotificationServiceHandler` applies
the payload's action buttons, turns `image_url` into an attachment, and posts
the delivery receipt:

```swift
import OpenPushCore
import OpenPushNSE
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let openPush = OpenPushNotificationServiceHandler(options: {
        var options = OpenPushNotificationServiceHandler.Options()
        options.appGroup = "group.com.example.app"
        return options
    }())

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

The content handler is called **exactly once** on every path, including the
expiry path and a payload OpenPush did not send — that one is handed straight
back untouched. Delivery waits for all three pieces of work: the action category
registered, the image finished or skipped, and the receipt completed with any
status, errored, or skipped. The receipt is not fire-and-forget, because calling
the content handler lets iOS suspend the extension and a request still in
flight — or a jittered one not yet fired — dies with it. That reliability costs
latency, so the jitter is short and the work overlaps: the receipt and the image
fetch both start in `didReceive`, and the worst case is ~2 s of receipt jitter
plus the request, against a 12 s image fetch running alongside. On expiry the
handler delivers what is ready; the buttons are set on the content synchronously,
so they survive an expiry even when the image and the receipt do not. Once the
content is handed over it belongs to the system, and a download or receipt that
lands afterwards has nothing left to mutate.

`Options.onEvent` reports what the extension did, one short line at a time
(`actions: <n>` — the number of buttons actually registered — `attachment:
ok|skipped|failed`, `receipt: HTTP <code>`, or
`receipt: skipped (<reason>)`, and `badge: <count>` or `badge: skipped (<reason>)`
for a push with a badge increment), from whichever thread finished that work. It is
for a debug surface; a shipping app needs nothing beyond `appGroup`. Set `loadAttachments = false` to render text only, and use
`attachments` to change the 12 s timeout, the 20 MB ceiling, or the allowed
media types. The loader is strict on purpose: `https` only, an allowlisted type
decided by the URL's path extension or the response's MIME type, and a size
refused on the declared length before anything is read and again on the bytes
that landed. The body is streamed to disk and never held in memory, which is what
keeps a chunked response from blowing the extension's memory ceiling before any
limit applies. A refused image still delivers the notification as text.

### Existing extension

An app that already ships a Notification Service Extension for another sender
keeps it. Give the extension a handler and insert two lines, one at the top of
each override; OpenPush takes only its own pushes (those carrying
`op_message_id`) and every other push runs the extension's existing code
unchanged:

```swift
import OpenPushNSE

final class NotificationService: UNNotificationServiceExtension {
    private let openPush = OpenPushNotificationServiceHandler(options: {
        var options = OpenPushNotificationServiceHandler.Options()
        options.appGroup = "group.com.example.app"
        return options
    }())

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if openPush.handleIfOpenPush(request, withContentHandler: contentHandler) { return }
        // the extension's existing code
    }

    override func serviceExtensionTimeWillExpire() {
        if openPush.serviceExtensionTimeWillExpireIfHandling() { return }
        // the extension's existing code
    }
}
```

`handleIfOpenPush` returns `false` and never touches the content handler for a
push OpenPush did not send. For its own pushes it behaves exactly like
`didReceive`, calling the content handler exactly once. Link `OpenPushNSE` to the
extension target and raise its deployment target to iOS 16 if it is lower.

The [setup tool](#setup-tool) makes this edit for you (`--nse-mode share`),
inserting whole lines only, so every other line of the extension stays as it
was. [Examples/SharedExtensionExample](Examples/SharedExtensionExample) is an
extension edited this way, with a payload of each kind to try on the Simulator.

### The App Group

Pass the same App Group to `OpenPush.initialize(… appGroup:)` and to the
handler's options. An extension runs in its own process, cannot read the app's
`UserDefaults.standard`, and does not have the app's `Info.plist`; with the
group, OpenPush mirrors the app id, server URL, SDK key, APNs token, and
subscription id into it, so no copy has to be plumbed into the extension target
by hand. Without an App Group the extension has no APNs token and the receipt is
skipped — `onEvent` says exactly that. The group must be in **both** targets'
entitlements, and `OpenPushSharedState` is the type that reads and writes it.

The receipt needs no device credential: the server authenticates it on the SDK
key, and without one the request simply carries no `X-OP-Device-Key` header.
`credentialStore` is optional. Set it when the app already shares its credential
through a Keychain access group, and the receipt carries it:

```swift
options.credentialStore = DeviceCredentialStore(
    service: "com.example.app.device",
    accessGroup: "TEAMID.com.example.shared")
```

The device credential is deliberately **not** mirrored: it authenticates this
install, and an App Group is readable by every extension the app ships. It stays
in the shared Keychain, which is why `credentialStore` is configured separately
and why using it needs the Keychain access group in the extension's own
entitlements. Do not copy a device credential into `UserDefaults` or an App
Group plist.

`OpenPushReceiptRequest.make(...)` and
`OpenPushNotificationActions.apply(from:to:)` remain public for a host that
drives its own extension.

### Badge increments

A push sent with a badge increment carries `op_badge_increment` instead of
`aps.badge`. iOS cannot tell an extension what the icon shows now, so the
extension keeps the count in the App Group: it adds the increment to the stored
count, shows the sum, and stores it back. A push with an absolute badge is
recorded as the stored count too, so increments count up from what the icon
actually shows.

The app resets the stored count whenever it sets the badge itself:
`OpenPush.Notifications.setBadgeCount(_:)` and `clearAll()` both write it, and
`OpenPush.Notifications.badgeCount` reads it back. Pass the same App Group to
`initialize` and to the handler's options.

Without an App Group, or without the service extension, an increment leaves the
badge unchanged and the notification is still shown; the extension logs that
once.

### The notification model

`OpenPush.Notification` is the payload parsed once into the fields a host
actually reads. It arrives on every click and foreground event as
`event.notification`, and the service extension builds the same value:

```swift
OpenPush.Notifications.addClickListener { event in
    let notification = event.notification
    print(notification.title ?? "", notification.additionalData.keys)
}
```

Everything is optional because APNs only guarantees `aps`. `isOpenPush` is
`false` for a local notification the host scheduled or another provider's push.
`launchURL` is the composer's **`deep_link`** key and `imageURL` is `image_url`;
`additionalData` is every other top-level key that is not `aps`, not a rendered
field, and not `op_`-prefixed — the composer's own data, nesting intact, as
`OpenPush.JSONValue`. `rawPayload` is the whole `userInfo` in the same form.

### Opening launch URLs

**The SDK opens a tapped notification's launch URL itself, by default** — as the
Android and Unity SDKs do. A tap opens `launchURL` with `UIApplication.open`
shortly after the click listeners have been told, and `event.launchURLOpened` is
`true`. Any URL that parses (after surrounding whitespace is trimmed) is opened,
whatever its scheme: a web link, the app's own scheme, `tel:`, another app's
scheme. A cold-start tap opens without waiting for a listener, a repeated tap on
a message already handled opens nothing, and a background push never opens
anything.

Each action button may carry a link of its own. A tap on that button
opens its link instead of the push's `deep_link`, and reports it as
`event.actionURL`. A button without a link opens the push's `deep_link`, as a tap
on the notification itself does.

**An app that routes `launchURL` itself** has two choices. Turn the SDK's opening
off, in code:

```swift
OpenPush.Notifications.openLaunchURLs = false
```

or without code, with the Info.plist boolean `OpenPushSuppressLaunchURLs` set to
`YES` (read once at `initialize`). Or keep it on and skip what the SDK already
opened:

```swift
OpenPush.Notifications.addClickListener { event in
    guard !event.launchURLOpened else { return }
    if let url = event.actionURL ?? event.notification.launchURL { Router.open(url) }
}
```

The compatibility facade opens launch URLs too, and also honours the Info.plist
key of the SDK it replaces; see
[`MIGRATING-FROM-ONESIGNAL.md`](MIGRATING-FROM-ONESIGNAL.md).


## UTM link tracking

Link tracking is configured on the OpenPush server. After personalization, it adds
missing `utm_source`, `utm_medium`, and `utm_campaign` parameters to HTTP(S)
`deep_link` URLs. Existing values (including blank values), query parameters and
fragments are preserved; custom app schemes are unchanged.

The SDK already delivers the complete URL through `event.notification.launchURL`.
Use that URL as received when routing a click: do not rebuild it from its host/path,
decode and re-encode its query, or append another set of UTM tags. The SDK opens
a tapped launch URL as received unless the app opts out (see
[Opening launch URLs](#opening-launch-urls)); it does not send UTM fields as
separate custom events. HTTPS is recommended for
web destinations; the store samples intentionally reject plain HTTP.

The Feature Lab custom notification demonstrates a tagged web link with a
fragment. Regression tests cover encoded query values, duplicate/blank parameters
and click forwarding.

## License and brand

The source is licensed under the [Apache License 2.0](LICENSE). Attributions
and trademark notices are in [NOTICE](NOTICE). The license does not grant
permission to use the OpenPush name, marks, or branding; forks and derivatives
must use their own name and branding.

Contributions are covered by [CONTRIBUTING.md](CONTRIBUTING.md).
