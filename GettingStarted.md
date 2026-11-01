# Getting started

From a fresh clone to a running sample, then to your own app. Everything here
runs on the Simulator; the pieces that need a real device or a signed build are
called out where they matter.

## Prerequisites

| You need | Why | Check it with |
|---|---|---|
| Xcode 16 or newer | The package is `swift-tools-version: 6.0` and the sources use Swift 6 concurrency | `xcodebuild -version` |
| An iOS 16 or newer Simulator | `platforms: [.iOS(.v16), …]` in `Package.swift` is the floor. iOS 16.1+ for Live Activities, 17.2+ for push-to-start tokens | `xcrun simctl list devices available` |
| XcodeGen | Both sample projects are generated from a `project.yml`, so the `.xcodeproj` is disposable | `brew install xcodegen` |
| An OpenPush App ID and public SDK key | Only for Live mode. The samples run in Demo mode without them | the OpenPush console |
| An Apple Developer team | Only for a signed build: entitlements, App Groups, shared Keychain, real pushes | Xcode → Settings → Accounts |

The package itself needs none of this to build and test:

```sh
swift build
swift test
```

`swift test` runs on the macOS host, where the UIKit and WebKit paths are
compiled out. To exercise those too, run the package suite on a Simulator
destination, as CI does:

```sh
xcodebuild test \
  -scheme openpush-ios-Package \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation
```

Name a Simulator whose runtime you actually have installed — `xcodebuild
-showdestinations -scheme openpush-ios-Package` lists the ones that resolve on
this machine. A name with no matching runtime fails with "Unable to find a
device matching the provided destination specifier" before any test runs.

## The two samples

| Path | What it is |
|---|---|
| `Examples/ReceiveOnlyExample` | The **Feature Lab** — an app, a Notification Service Extension, and a Live Activity widget, with a control beside every piece of SDK state. Start here |
| `Examples/MigratedFromOneSignal` | The **compatibility-facade sample** — the same app written entirely against the opt-in facade, for hosts migrating from another push SDK. It links `OpenPushOneSignal` and nothing else |

Neither project's `.xcodeproj` is meant to be edited by hand: `project.yml` is
the source, and `xcodegen generate` rewrites the project from it.

### Run the Feature Lab

```sh
cd Examples/ReceiveOnlyExample
xcodegen generate
open ReceiveOnlyExample.xcodeproj
```

Choose the `ReceiveOnlyExample` scheme and any iOS 16-or-newer Simulator. To
build it from the command line the way CI does:

```sh
cd Examples/ReceiveOnlyExample
xcodegen generate
xcodebuild build \
  -project ReceiveOnlyExample.xcodeproj \
  -scheme ReceiveOnlyExample \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Its five workspaces are **Status** (registration, subscription, credential, and
the extension's telemetry), **User** (identity, tags, aliases), **Events**
(observers, the custom-event control, and the event stream), **Activity** (Live
Activities), and **In-app** (triggers, pause, lifecycle). The settings button on
any tab opens the runtime-configuration sheet.

### Run the migration sample

```sh
cd Examples/MigratedFromOneSignal
xcodegen generate
xcodebuild build \
  -project MigratedFromOneSignal.xcodeproj \
  -scheme MigratedFromOneSignal \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Its README shows the whole migration as a regenerable diff.

## Demo mode and Live mode

The Feature Lab picks its mode from its build settings, so there is nothing to
toggle in the UI.

**Demo mode** is what a fresh checkout builds. `Build.xcconfig` ships
placeholder credentials (`OPENPUSH_APP_ID = replace-with-app-id`), and while
they are placeholders the app uses clearly labelled synthetic subscription data
and never talks to a server. Native iOS behaviour stays real: permission
prompts, local notifications, the foreground and click delegate callbacks, and
ActivityKit all run for real on the Simulator or device.

**Live mode** unlocks once real credentials are configured and the app is
relaunched. Every identifier lives in one git-ignored file:

1. `cp Local.xcconfig.example Local.xcconfig`
2. Fill in `DEVELOPMENT_TEAM`, `OPENPUSH_BUNDLE_PREFIX`, `OPENPUSH_APP_GROUP`,
   `OPENPUSH_KEYCHAIN_GROUP`, and the `OPENPUSH_APP_ID` and public
   `OPENPUSH_SDK_KEY` from the OpenPush console. Delete or comment out a line to
   keep its Demo-mode default from `Build.xcconfig`; an empty value overrides that
   default rather than falling back to it.
3. `xcodegen generate` again. The bundle ids, both entitlements files, and the
   app's and the extension's `Info.plist`s are all built from those settings, so
   the code, the entitlements and the project cannot disagree.
4. Store the linked installation's device credential with
   `DeviceCredentialStore`, and enable Push Notifications, App Groups and
   Keychain Sharing — with matching values — on both the app and the extension.

`Build.xcconfig` ends with `#include? "Local.xcconfig"`, so a checkout without
that file still generates and builds. `Local.xcconfig.example` is the tracked
template; `Local.xcconfig` is git-ignored, so your team id and SDK key stay out
of the repository.

## Integrate it into your own app

1. Add the package (`https://github.com/SuperTuned/openpush-ios.git`) and link
   the products as [README.md](README.md#products) describes — `OpenPush` to the
   app, `OpenPushNSE` to the Notification Service Extension,
   `OpenPushLiveActivities` to the widget extension.
2. Put your **public** SDK key in the app's `Info.plist` under `OpenPushSDKKey`
   and call `OpenPush.initialize(appId:)` at launch.
3. Forward the four delegate callbacks OpenPush needs — it never swizzles:
   `didRegisterForRemoteNotificationsWithDeviceToken`,
   `didFailToRegisterForRemoteNotificationsWithError`, and
   `UNUserNotificationCenterDelegate`'s `willPresent` and `didReceive`. Forward
   `didReceiveRemoteNotification` too if you send `content-available` pushes.
4. Ask for authorization when the user has a reason to say yes, with
   `OpenPush.Notifications.requestPermission(fallbackToSettings:completion:)`.
   The SDK requests a push token only after permission is granted, so until
   then the install has no subscription: no in-app messages, no Live Activity
   tokens, and no attributed events. Show your own screen explaining what
   notifications are for before you call it.

[README.md](README.md) has the code for each of those, [API.md](API.md) is the
complete public surface, and
[MIGRATING-FROM-ONESIGNAL.md](MIGRATING-FROM-ONESIGNAL.md) is the guide for a
host coming from another push SDK.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `xcodegen: command not found` | XcodeGen is not installed; the samples have no checked-in project to fall back on | `brew install xcodegen`, then `xcodegen generate` in the sample's directory |
| The sample builds but stays in Demo mode, and signing fails with no team | No `Local.xcconfig`, so `Build.xcconfig`'s placeholders are in force | `cp Local.xcconfig.example Local.xcconfig`, fill it in, `xcodegen generate` again |
| No remote push ever arrives on the Simulator | A Simulator has no APNs connection, so there is no real device token | Inject the bundled fixture instead: `xcrun simctl push booted ai.openpush.example Support/demo-notification.apns`. Use a real device for end-to-end APNs |
| The extension runs but `receipt: skipped (…)` | Receipts need a *signed* build: the App Group the app mirrors its token into, and the shared-Keychain device credential, only resolve with a real team id and matching entitlements | Configure `Local.xcconfig`, enable App Groups and Keychain Sharing on both targets, and run on a device |
| The notification renders as text with no image | The attachment loader is strict: `https` only, an allowlisted media type, and a bounded size | Check the Status workspace's **Attachment** row and the `NotificationService` process in Console.app |
| `status` on the wire is `-18`, and nothing was ever asked | `-18` is "permission never requested" — this SDK has not raised the prompt yet, so there is no authorization to report | Call `requestPermission(fallbackToSettings:)` (or `requestProvisionalPermission()`), or read `Notifications.canRequestPermission` first, which is true only while authorization is undetermined **and** this SDK has never prompted |
| A release build logs nothing | The default log sink is silent outside `DEBUG` by design | Set `OpenPush.onLog` to route SDK diagnostics into whatever your app already logs |
| `initialize` refuses with an app-id message | The app id is empty, or holds whitespace, `/` or `?` — spliced into a path, those retarget the request | Fix the id. Note that an id still wearing the `replace-with-` placeholder is warned about but allowed, which is what keeps Demo mode working |
