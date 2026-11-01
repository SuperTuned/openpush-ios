# MigratedFromOneSignal (iOS)

> OneSignal is a trademark of OneSignal, Inc. OpenPush is not affiliated with,
> endorsed by, or sponsored by OneSignal, Inc. The OneSignal name appears only
> to describe the optional compatibility layer for apps migrating from the
> OneSignal SDK.

A receive-only app that ran on OneSignal v5 and now runs on OpenPush. It exists to
answer one question with a diff instead of a promise: **how much of an app has to
change?**

`Before/` holds the pre-migration version of this sample app, so the diff below is
not a hand-written illustration — it is output you can regenerate:

```sh
diff -u Before/MigratedApp.swift.onesignal Sources/MigratedApp.swift
```

`Before/MigratedApp.swift.onesignal` is deliberately not a `.swift` file: it
references `OneSignalFramework`, which this repo does not depend on, so it must
not be compiled. `project.yml` builds `Sources/` only.

## The whole migration

Three edits, plus one documented exception.

1. **One import.** `import OneSignalFramework` → `import OpenPushOneSignal`.
2. **The provider forwarding OpenPush requires**, because it never swizzles:
   `didRegisterForRemoteNotifications(deviceToken:)`,
   `Notifications.processForeground(_:)` and `Notifications.processClick(_:)`.
   Becoming `UNUserNotificationCenter`'s delegate, and importing the framework
   that declares that protocol, are part of this edit — OpenPush never
   swizzles, and the two `processFor…` forwards have nowhere to be
   called from until the app owns the delegate.
3. **One non-code configuration entry**: `OpenPushSDKKey` in
   `Support/Info.plist`. That is the only reason `initialize` can keep the v5
   signature.

**The exception**, ruled and documented in
[`MIGRATING-FROM-ONESIGNAL.md` §1](../../MIGRATING-FROM-ONESIGNAL.md) as "the
fourth edit": OneSignal v5's listeners and observers take a **conforming object**,
and OpenPush's take a **closure**. So `addClickListener(self)` — the usual v5
idiom — is a type error, and the `OSNotificationClickListener`
conformance is rewritten as a closure returning a handle. It is labelled in the
diff below, and it is the only code change there that is not one of the three
edits.

**No call site changed.** Not one line of `ExampleModel` — permission,
`login`/`logout`, tags, aliases, opt-in/opt-out, the subscription and permission
accessors, the three `Session` outcome forms, the in-app trigger and `paused` —
is touched by the diff, and neither is `initialize`. That is the claim this
example exists to make checkable.

## The diff

```diff
--- Before/MigratedApp.swift.onesignal
+++ Sources/MigratedApp.swift
@@ -8,9 +8,10 @@
 //
 // See README.md for that diff, annotated.
 
-import OneSignalFramework                               # EDIT 1
+import OpenPushOneSignal                                # EDIT 1
 import SwiftUI
 import UIKit
+import UserNotifications                                # EDIT 2
 
 @MainActor
 final class ExampleModel: ObservableObject {
@@ -32,6 +33,7 @@
         OneSignal.login("demo-user")
         OneSignal.User.addTag(key: "example_build", value: "migrated-from-onesignal")
         identity = "identified as demo-user"
+        // OneSignal.User.setLanguage("en")  // compile-time refusal: OpenPush sends the device language
     }
 
     func signOut() {
@@ -101,6 +103,11 @@
 }
 
 final class AppDelegate: NSObject, UIApplicationDelegate {
+    /// The compat facade takes a closure and hands back a handle, so keep it if
+    /// you ever want to remove the listener; v5's protocol object has no
+    /// equivalent here.
+    private var inAppClickHandle: UUID?
+
     func application(
         _ application: UIApplication,
         didFinishLaunchingWithOptions launchOptions: [
@@ -108,22 +115,55 @@
         ]? = nil
     ) -> Bool {
         OneSignal.initialize("replace-with-app-id", withLaunchOptions: launchOptions)
-        OneSignal.Notifications.addClickListener(self)  # THE EXCEPTION
+        UNUserNotificationCenter.current().delegate = self  # EDIT 2
+        _ = OneSignal.Notifications.addClickListener { event in
+            print("example · notification click \(event.messageId ?? "—")")
+        }
+        inAppClickHandle = OneSignal.InAppMessages.addClickListener { _ in
+            print("example · in-app click")
+        }
+        _ = OneSignal.InAppMessages.addLifecycleListener { event in
+            print("example · in-app lifecycle \(event.phase) \(event.messageId)")
+        }
         if #available(iOS 16.1, *) {
             // Live Activity push updates with no ActivityAttributes type of your
             // own: the facade registers for the default activity's tokens.
             OneSignal.LiveActivities.setupDefault()
         }
+        // OneSignal.Notifications.setBadgeCount(0)  // compile-time refusal: manage the badge with UNUserNotificationCenter
         return true
     }
 }
 
-extension AppDelegate: OSNotificationClickListener {    # THE EXCEPTION
-    func onClick(event: OSNotificationClickEvent) {
-        print("example · notification click \(event.notification.notificationId ?? "—")")
+extension AppDelegate {                                 # EDIT 2
+    func application(
+        _ application: UIApplication,
+        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
+    ) {
+        OneSignal.didRegisterForRemoteNotifications(deviceToken: deviceToken)
     }
 }
 
+extension AppDelegate: UNUserNotificationCenterDelegate {  # EDIT 2
+    func userNotificationCenter(
+        _ center: UNUserNotificationCenter,
+        willPresent notification: UNNotification,
+        withCompletionHandler completionHandler:
+            @escaping (UNNotificationPresentationOptions) -> Void
+    ) {
+        completionHandler(OneSignal.Notifications.processForeground(notification))
+    }
+
+    func userNotificationCenter(
+        _ center: UNUserNotificationCenter,
+        didReceive response: UNNotificationResponse,
+        withCompletionHandler completionHandler: @escaping () -> Void
+    ) {
+        OneSignal.Notifications.processClick(response)
+        completionHandler()
+    }
+}
+
 @main
 struct MigratedFromOneSignalApp: App {
     @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

The `# EDIT n` markers are annotation for this README; they are not in the
source. Four hunks, 42 added lines and 5 removed. Everything removed is the
import, the protocol-object listener registration and its conformance — nothing
else. Two of the added lines are commented-out refusals, and the in-app click
and lifecycle registrations are new demonstration calls, written in the closure
form the exception describes rather than converted from anything.

`ExampleModel` has no hunk at all. Every facade area the sample exercises there
— permission, identity, tags, aliases, opt-in/opt-out, the subscription and
permission accessors, all three `Session` outcome forms, in-app triggers and
`paused` — is byte-for-byte the code that ran on v5.

And the configuration entry, in `Support/Info.plist`:

```diff
+    <key>OpenPushSDKKey</key>
+    <string>replace-with-public-sdk-key</string>
```

## Seeing a refusal for yourself

The two commented-out lines in the diff are calls OpenPush refuses at compile
time — `OneSignal.User.setLanguage` in `signIn()` and
`OneSignal.Notifications.setBadgeCount` in `didFinishLaunchingWithOptions`.
They are commented out so this app builds; uncomment either one and build:

```sh
xcodegen generate
xcodebuild build -project MigratedFromOneSignal.xcodeproj \
  -scheme MigratedFromOneSignal -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

The build fails, and the error is the documentation:

```
Sources/MigratedApp.swift:36:24: error: 'setLanguage' is unavailable: OpenPush sends the device's full language tag (for example zh-Hant-TW) with every registration; the server falls back from a regional tag to its base language when choosing localized copy. To force a different language, set a tag your segments can read.
```

Every refused v5 symbol carries a message shaped like that, naming what to do
instead at the call site where you tried it — that is how a migrating host
learns the whole gap from one build rather than from a table. Re-comment the
line for a green build.

## What did *not* need to change, and why that is the point

| Left alone | Why it survived |
|---|---|
| `OneSignal.initialize("…", withLaunchOptions:)` | The public SDK key moved into `Info.plist`, so the argument list is still v5's. `launchOptions` is accepted and ignored — OpenPush installs no delegates. |
| `OneSignal.Notifications.requestPermission({ … }, fallbackToSettings:)` | The facade keeps v5's argument order: response block first. |
| `OneSignal.login("demo-user")` / `logout()` | v5's positional `login` is a declared overload. |
| `User.addTag` / `addAlias` / `externalId` | Same names, same shapes. |
| `User.pushSubscription.optOut()` / `.optIn()` / `.id` / `.token` / `.optedIn` | v5 hangs these off an instance property; the facade presents the same instance shape. |
| `Notifications.canRequestPermission` / `permissionNative` | Same names, and both read the same way. `permissionNative` reports OpenPush's own `PermissionStatus` rather than v5's raw status, so interpolating or comparing it is unchanged but a `switch` over it needs OpenPush's cases. |
| `InAppMessages.addTrigger(_:withValue:)` / `.paused` | Same names, same shapes; `paused` is a readable and writable property in both. The in-app *listeners* are the documented exception above — closures, not conforming objects. |
| `LiveActivities.setupDefault()` behind `#available(iOS 16.1, *)` | Same name and the same availability gate. The facade registers for the default activity's tokens without an `ActivityAttributes` type of your own. |
| `Session.addUniqueOutcome("demo")` | Same name, same shape. It becomes a Custom Event carrying an idempotency key derived from the outcome name and this installation's subscription id — never the push token — so the server counts it once per device however often it is recorded. `addOutcome` counts every call, and `addOutcomeWithValue` sends the number as a `value` property. |

## Running it

1. Replace `ai.openpush.example.migrated` in `project.yml` with your bundle id,
   and set your team's `aps-environment` in `Support/App.entitlements`.
2. Replace `replace-with-app-id` in `Sources/MigratedApp.swift` and
   `replace-with-public-sdk-key` in `Support/Info.plist` with the values from your
   OpenPush app settings. The SDK key is public and may ship in the app; a device
   credential is not.
3. `xcodegen generate`, then enable Push Notifications for the target.

Verified on this checkout with:

```sh
xcodegen generate
xcodebuild -project MigratedFromOneSignal.xcodeproj -scheme MigratedFromOneSignal \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

`project.yml` links **`OpenPushOneSignal` and nothing else**. That is the
machine-checked half of "no call site changed": if any line in this app still
needed a member the facade does not carry, the build would fail rather than quietly
reach past the facade into `OpenPush`.

## See also

- [`MIGRATING-FROM-ONESIGNAL.md`](../../MIGRATING-FROM-ONESIGNAL.md) — every
  forwarded symbol, and every refused one with its message.
- [`../ReceiveOnlyExample`](../ReceiveOnlyExample) — the same app written natively
  against `OpenPush`, with the NSE and Live Activity wiring this one leaves out.
