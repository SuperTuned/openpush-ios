# Migrating from OneSignal v5

> OneSignal is a trademark of OneSignal, Inc. OpenPush is not affiliated with,
> endorsed by, or sponsored by OneSignal, Inc. The OneSignal name appears only
> to describe the optional compatibility layer for apps migrating from the
> OneSignal SDK.

The member names in this guide match the documented public API of the 5.x SDK.

`OpenPushOneSignal` is an **opt-in** SPM product that exposes OneSignal v5's
names over OpenPush. **OpenPush ships for iOS 16 and newer, and for iOS only:
there is no Mac Catalyst and no visionOS support** — check that against your
deployment target before you start. Import it instead of `OneSignalFramework`
and your existing call sites keep compiling — with one exception: OneSignal v5's
**protocol-based** listeners and observers are **closures** here, so a call site
that passes a conforming object (`addClickListener(self)`) is a type error you
rewrite as a closure. See §2 for the affected rows.

It is names only: every supported member is one line of delegation to the
matching `OpenPush` call. There is no OneSignal implementation code, no behavior
and no state in the facade.

> **Do not link `OpenPushOneSignal` and the real OneSignal SDK into the same
> target.** Both define a top-level `OneSignal`, so every reference becomes
> ambiguous. Remove the OneSignal dependency as part of this migration.
>
> Prefer not to keep the OneSignal spelling at all? Skip this product and replace
> `OneSignal.` with `OpenPush.`. Every v5 member this SDK supports keeps its
> name, and compatibility overloads on the core SDK let signatures that would
> otherwise differ compile unchanged:
> `initialize(_:withLaunchOptions:)` (launch options accepted and unused —
> OpenPush installs no delegates), positional `login(_:)`,
> `requestPermission(_:fallbackToSettings:)` in v5's argument order, and
> `pushSubscription.addObserver`/`removeObserver` on the instance as well as
> statically. A v5 member OpenPush does not implement — consent
> gating, `onesignalId`, log levels, and legacy notification-centre methods — has no
> counterpart, so the call fails to compile. Nothing is stubbed: there is no
> method that accepts the call and quietly does nothing. `API.md` maps the
> OpenPush surface itself.

---

## Calls that behave differently from their names

These forwarded calls are worth a second look:

- **`Session.addUniqueOutcome(_:)` counts once per device.** It sends
  `trackEvent(name, idempotencyKey: "unique:<name>:<scope>")`, so the outcome
  counts **once per device** however often it is recorded. The scope is the
  subscription id; before the server has issued one it is a short SHA-256 digest
  of the push token, and before there is a token at all it is a constant — the
  token itself is never part of the key. An outcome recorded before registration
  and one recorded after it are therefore two events: record unique outcomes
  after registration.
- **`Notifications.permissionNative` returns `OpenPush.PermissionStatus`**, not
  the raw `UNAuthorizationStatus` integer the v5 name implies, so a call site
  that switches over it needs the new case names.
- **`LiveActivities.setup` and `setupDefault` take
  `OpenPushLiveActivitySetupOptions?`.** Source-compatible, because the
  `LiveActivitySetupOptions` name remains as a deprecated typealias — you get a
  warning naming the replacement.

---

## 1. What you actually change

Three edits: the import, where the key lives, and the delegate forwarding
OpenPush requires because it never swizzles.

A fourth applies only if you used the protocol-based listener or observer APIs:
`Notifications.addClickListener(_:)`,
`Notifications.addForegroundLifecycleListener(_:)`,
`Notifications.addPermissionObserver(_:)`,
`User.pushSubscription.addObserver(_:)`,
`InAppMessages.addClickListener(_:)`, and
`InAppMessages.addLifecycleListener(_:)` take a **closure** here instead of an
object conforming to `OSNotificationClickListener`,
`OSNotificationLifecycleListener`, `OSPermissionObserver`,
`OSPushSubscriptionObserver`, `OSInAppMessageClickListener`, or
`OSInAppMessageLifecycleListener`, and each returns a `UUID` handle you pass to
the matching `remove…` call. So `OneSignal.Notifications.addClickListener(self)` —
the usual v5 idiom — is a **type error**, not a named refusal;
rewrite it as `OneSignal.Notifications.addClickListener { event in … }` and keep
the returned handle. The tables in §2 flag every affected row.

A fifth applies only to a mixed-language host: OpenPush is **Swift-only** and
ships no `@objc` wrappers, so Objective-C cannot call it directly the way it
could call the framework you are migrating from. Call it from a Swift file that
exposes a thin `@objc` shim for the handful of entry points your Objective-C
code uses — [**Objective-C** in the README](README.md#objective-c) has the
five-line pattern.

### The import and the key

```diff
-import OneSignalFramework
+import OpenPushOneSignal

 func application(
     _ application: UIApplication,
     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
 ) -> Bool {
-    OneSignal.initialize("your-onesignal-app-id", withLaunchOptions: launchOptions)
+    OneSignal.initialize("your-openpush-app-id", withLaunchOptions: launchOptions)
     return true
 }
```

The signature is unchanged. Put your **public** SDK key in the app's
`Info.plist` under `OpenPushSDKKey` and `initialize` needs only the app id:

```xml
<key>OpenPushSDKKey</key>
<string>your-public-sdk-key</string>
```

To keep the key in code instead, call `OneSignal.initialize(appId:sdkKey:)` — an
explicit key always wins over the bundled one. With no key in either place,
`initialize` refuses loudly and stays unconfigured rather than half-configuring
itself.

`launchOptions` is accepted and ignored: OpenPush installs no delegates, so
there is nothing to build from it. To handle a cold start from a notification
tap, forward `processClick(_:)` (below).

### The delegate forwarding you write yourself

OpenPush never swizzles, so these four forwards are yours to write. This is the
one behavioral difference that is not cosmetic — without them the SDK never
receives a token and never reports a tap.

```diff
 extension AppDelegate {
+    func application(
+        _ application: UIApplication,
+        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
+    ) {
+        OneSignal.didRegisterForRemoteNotifications(deviceToken: deviceToken)
+    }
+
+    func application(
+        _ application: UIApplication,
+        didFailToRegisterForRemoteNotificationsWithError error: Error
+    ) {
+        OneSignal.didFailToRegisterForRemoteNotifications(error: error)
+    }
 }

 extension AppDelegate: UNUserNotificationCenterDelegate {
+    func userNotificationCenter(
+        _ center: UNUserNotificationCenter,
+        willPresent notification: UNNotification,
+        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
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
 }
```

Also call `OneSignal.Notifications.onAppForegrounded()` when the app becomes
active, so a permission change made in Settings is picked up.

---

## 2. Every forwarded symbol

Each row delegates to the `OpenPush` member named in the third column. Every row
compiles unchanged except the six bolded **closure, not an `OS…`** rows below:
those take a closure rather than a conforming object, so those call sites are a
type error until you rewrite them as closures (§1).

| Area | OneSignal v5 call | Delegates to | Notes |
|---|---|---|---|
| Configure | `OneSignal.initialize(_:withLaunchOptions:)` | `OpenPush.initialize(_:withLaunchOptions:)` | Key from `Info.plist` (`OpenPushSDKKey`), so the argument list matches; `launchOptions` accepted and unused |
| Configure | `OneSignal.initialize(appId:sdkKey:)` | `OpenPush.initialize(appId:sdkKey:…)` | Explicit key wins over the bundled one; also takes `serverURL:`, `credential:`, `provisional:`, `transport:` |
| Configure | `OneSignal.initialize(appId:)` | `OpenPush.initialize(appId:…)` | OpenPush addition: the short call plus OpenPush's own extras |
| Forward the APNs token | `OneSignal.didRegisterForRemoteNotifications(deviceToken:)` | same name on `OpenPush` | Same shape; host-owned, never swizzled |
| Forward an APNs failure | `OneSignal.didFailToRegisterForRemoteNotifications(error:)` | same name on `OpenPush` | Same shape; OpenPush names the cause |
| Identify | `OneSignal.login(_:)` | `OpenPush.login(externalId:)` | v5's positional form |
| Identify | `OneSignal.login(externalId:token:)` | `OpenPush.login(externalId:authHash:)` | The token is the identity proof |
| Identify | `OneSignal.login(externalId:authHash:completion:)` | same name on `OpenPush` | OpenPush addition with a result callback |
| Detach | `OneSignal.logout(completion:)` | same name on `OpenPush` | Sends an explicit empty `external_id` |
| Tags | `OneSignal.User.addTag(key:value:)` / `addTags(_:)` / `removeTag(_:)` / `removeTags(_:)` / `getTags()` | same names on `OpenPush.User` | Same shape; the session map rides every registration |
| Aliases | `OneSignal.User.addAlias(label:id:)` / `addAliases(_:)` / `removeAlias(_:)` / `removeAliases(_:)` | same names on `OpenPush.User` | Same shape; `external_id` is refused as a label |
| External id | `OneSignal.User.externalId` | `OpenPush.User.externalId` | The id you set, or `nil` when anonymous |
| SMS number | `OneSignal.User.addSms(_:)` / `removeSms(_:)` | same names on `OpenPush.User` | Separators are removed and a leading `00` is read as `+`; the result must be `+` and 8–15 digits not starting with `0`, or the call is refused with a log line. v5's `Void` signature is kept: OpenPush's `Bool` result is discarded. A new number is added **not verified** and receives nothing until a code sent with `OpenPush.Verify.start` is approved. `removeSms` opts the number out. WhatsApp numbers (`OpenPush.User.addWhatsApp`) have no v5 counterpart, so the facade does not carry them |
| Email address | `OneSignal.User.addEmail(_:)` / `removeEmail(_:)` | same names on `OpenPush.User` | addEmail subscribes the address at once, unless this app's suppression list has it. removeEmail removes the subscription; it is not an unsubscribe. The address is trimmed and lower-cased; one without a single `@`, a local part and a dot in the domain is refused with a log line. v5's `Void` signature is kept: OpenPush's `Bool` result is discarded |
| Custom Events | `OneSignal.User.trackEvent(name:properties:)` | `OpenPush.trackEvent(_:properties:)` | Properties default to an empty dictionary |
| Subscription | `OneSignal.User.pushSubscription` | `OpenPush.User.pushSubscription` | A property, as in v5 — a live view computed on read |
| Opt in / out | `OneSignal.User.pushSubscription.optIn()` / `optOut()` | same on `OpenPush.User.pushSubscription` | Same shape; `optIn` prompts first when authorization is missing |
| Subscription state | `OneSignal.User.pushSubscription.id` / `.token` / `.optedIn` | same on `OpenPush.User.pushSubscription` | Live accessor |
| Subscription state | `OneSignal.User.pushSubscription.status` / `snapshot()` | same on `OpenPush.User.pushSubscription` | OpenPush additions: this install's `notification_types`, and an immutable `PushSubscriptionState` |
| Observe the subscription | `OneSignal.User.pushSubscription.addObserver(_:)` / `removeObserver(_:)` | `OpenPush.PushSubscription.addObserver(_:)` / `removeObserver(_:)` | v5 hangs these off the instance; **closure, not an `OSPushSubscriptionObserver`**, returning a `UUID` handle |
| Permission state | `OneSignal.Notifications.permission` | same name on `OpenPush.Notifications` | Cached authorization state; reading never blocks |
| Permission state | `OneSignal.Notifications.permissionNative` | `OpenPush.Notifications.permissionStatus` | The same cache unflattened: `.notDetermined` / `.denied` / `.granted` / `.provisional` / `.ephemeral`. The enum is `OpenPush.PermissionStatus`, not `OSNotificationPermission`, so a call site that switches over it needs the new case names |
| Permission state | `OneSignal.Notifications.canRequestPermission` | same name on `OpenPush.Notifications` | True while authorization is undetermined or provisional; quiet authorization does not consume the standard prompt |
| Ask quietly | `OneSignal.Notifications.requestProvisionalPermission()` | same name on `OpenPush.Notifications` | OpenPush addition: no prompt, quiet delivery to the notification centre, never routes to Settings |
| Ask quietly | `OneSignal.Notifications.registerForProvisionalAuthorization(_:)` | `OpenPush.Notifications.requestProvisionalPermission(completion:)` | Current v5 spelling |
| Ask for permission | `OneSignal.Notifications.requestPermission(_:fallbackToSettings:)` | `OpenPush.Notifications.requestPermission(fallbackToSettings:completion:)` | v5's argument order — response block first |
| Observe permission | `OneSignal.Notifications.addPermissionObserver(_:)` / `removePermissionObserver(_:)` | same names on `OpenPush.Notifications` | **Closure, not an `OSPermissionObserver`**; returns a `UUID` handle |
| Taps | `OneSignal.Notifications.addClickListener(_:)` / `removeClickListener(_:)` | same names on `OpenPush.Notifications` | **Closure, not an `OSNotificationClickListener`**; returns a `UUID` handle; the closure takes an `OpenPush.ClickEvent` |
| Foreground arrivals | `OneSignal.Notifications.addForegroundLifecycleListener(_:)` / `removeForegroundLifecycleListener(_:)` | same names on `OpenPush.Notifications` | **Closure, not an `OSNotificationLifecycleListener`**; returns a `UUID` handle; `preventDefault()` on the `OpenPush.ForegroundEvent` suppresses presentation |
| Notification centre | `OneSignal.Notifications.clearAll()` / `setBadgeCount(_:)` | same names on `OpenPush.Notifications` | Removes delivered notifications and manages the badge |
| Manual integration | `didRegisterForRemoteNotifications(deviceToken:)` / `didFailToRegisterForRemoteNotifications(error:)` / `didReceiveRemoteNotification(userInfo:completionHandler:)` / `willPresentNotification(payload:completion:)` / `didReceiveNotificationResponse(_:)` on `OneSignal.Notifications` | The corresponding OpenPush token, background, foreground, and click adapters | OpenPush never swizzles, so these calls always forward |
| Delegate adapters | `OneSignal.Notifications.processForeground(_:)` / `processClick(_:)` / `onAppForegrounded()` | same names on `OpenPush.Notifications` | OpenPush additions: OpenPush never swizzles, so you forward these yourself — see §1 |
| Background pushes | — | `OpenPush.didReceiveRemoteNotification(userInfo:)` | OpenPush addition: forward `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, the only callback a `content-available` push reaches. Call your own completion handler as before |
| In-app triggers | `OneSignal.InAppMessages.addTrigger(_:withValue:)` / `addTriggers(_:)` / `removeTrigger(_:)` / `removeTriggers(_:)` / `clearTriggers()` | same names on `OpenPush.InAppMessages` | Same shape; triggers are process-local and re-evaluate the queue |
| In-app pause | `OneSignal.InAppMessages.paused` | same name on `OpenPush.InAppMessages` | A paused message keeps its impression and returns to the front of the queue |
| In-app clicks | `OneSignal.InAppMessages.addClickListener(_:)` / `removeClickListener(_:)` | same names on `OpenPush.InAppMessages` | **Closure, not an `OSInAppMessageClickListener`**; returns a `UUID` handle; the closure takes an `OpenPush.InAppMessageClickEvent` |
| In-app lifecycle | `OneSignal.InAppMessages.addLifecycleListener(_:)` / `removeLifecycleListener(_:)` | same names on `OpenPush.InAppMessages` | **Closure, not an `OSInAppMessageLifecycleListener`**; returns a `UUID` handle; the closure takes an `OpenPush.InAppMessageLifecycleEvent` |
| Service extension | `OneSignalExtension.didReceiveNotificationExtensionRequest(_:with:withContentHandler:)` + `serviceExtensionTimeWillExpire(_:with:)` | `OpenPushNotificationServiceHandler.didReceive(_:withContentHandler:)` + `serviceExtensionTimeWillExpire()` | One object instead of two class methods: hold an `OpenPushNotificationServiceHandler(options:)` and forward both entry points. It applies the action buttons, fetches `image_url`, and posts the receipt, and calls the content handler exactly once on every path. Link `OpenPushNSE`, and give it the App Group and the shared-Keychain credential store |
| Live Activities — setup | `OneSignal.LiveActivities.setup(_:options:)` / `setupDefault(options:)` / `startDefault(_:attributes:content:)` | same names on `OpenPush.LiveActivities` | Use the `openpush`-branded attributes with `OpenPushAnyCodable` and `OpenPushLiveActivitySetupOptions`, or import `OpenPushOneSignal` and keep the `onesignal` spelling. `DefaultLiveActivityAttributes` keeps its unprefixed name because it is the ActivityKit `attributes-type` |
| Live Activities — tokens | `enter(_:withToken:)` / `exit(_:)` / `setPushToStartToken(_:withToken:)` / `removePushToStartToken(_:)` | same names and labels on `OpenPush.LiveActivities` | Each takes an optional completion; the 1.0 labelled overloads remain deprecated |
| Live Activities — clicks | `.onesignalWidgetURL(_:context:)` / `trackClickAndReturnOriginal(_:)` | `.openpushWidgetURL(_:context:)` / same tracking method | The tracking URL contains the activity topic and injected notification ID |
| Live Activities — widget linking | Link `OneSignalLiveActivities` | Link `OpenPushLiveActivities` | Both are split because the main SDK is not extension-safe |
| Live Activities — receipts | Automatic | Automatic on iOS 16.2+ | The server-injected notification ID is reported through the normal receipt route |
| Outcomes | `OneSignal.Session.addOutcome(_:)` | `OpenPush.trackEvent(_:)` | Recorded as a Journey Custom Event |
| Outcomes | `OneSignal.Session.addUniqueOutcome(_:)` | `OpenPush.trackEvent(_:idempotencyKey:)` | Deduplicated by the key `unique:<name>:<subscription id>`, so the same outcome on one device is one event; the push token is never part of the key (before the server issues a subscription id the scope is a short SHA-256 digest of the token, and before there is a token at all, a constant), so record it after registration |
| Outcomes | `OneSignal.Session.addOutcomeWithValue(_:_:)` | `OpenPush.trackEvent(_:properties:)` | With a numeric `value` property |

Six behavior differences carry over from the core SDK and matter during
migration:

1. Tags, aliases, external identity, and opt-out intent set before
   initialization are kept and ride the first registration. Non-secret state is
   durable across a cold start; the identity authentication hash is memory-only.
2. Every registration rebuilds one idempotent body from the current tag and
   alias maps. There is no per-delta operation queue to strand.
3. OpenPush never swizzles. The forwards in §1 are the complete set.
4. Tags and aliases are scoped to the identity that set them. `login` with a
   different external ID, and `logout`, clear this device's tags and aliases
   before the next registration — including ones staged while anonymous — so
   one person's targeting data is never written onto another. Re-add what the
   new user should carry after the switch.
5. A swipe-to-dismiss is not a click. When a category opts into custom dismiss
   actions, that response reaches the delegate too; OpenPush posts no `clicked`
   receipt and fires no click listener for it, so dismissals never inflate
   click counts.
6. Calling `initialize` again with the same configuration is a no-op that keeps
   identity, tags, aliases, opt-out, Live Activity state, and queued Custom
   Events. A host that initializes from more than one entry point does not lose
   state to the second call.
7. The service extension holds its content back until the receipt has been sent,
   rather than delivering first and posting in the background: calling the
   content handler lets iOS suspend the extension, and a request still in flight
   dies with it. The wait is bounded well inside the extension's budget, and an
   expiry delivers whatever is ready.

---

## 3. Every refused symbol

In-app trigger, pause, lifecycle, and click APIs are forwarded to the native
OpenPush in-app message engine, so they are not in this refusal table; nor are
`canRequestPermission`, `permissionNative`, `User.addSms(_:)`,
`User.removeSms(_:)`, `User.addEmail(_:)` and `User.removeEmail(_:)`, which
forward too (§2).

These are declared and marked `unavailable`, so a migrating host learns the whole
gap from **one build** with the replacement named at the call site. Nothing is
stubbed: there is no member that accepts the call and quietly does nothing.

| OneSignal v5 symbol | Why, and what to do instead |
|---|---|
| `OneSignal.consentRequired` | OpenPush has no runtime consent gate. Do not call initialize until the user has consented; to withdraw afterwards call `OpenPush.User.pushSubscription.optOut()` and `OpenPush.logout()` — a full stop requires not initializing on the next launch. |
| `OneSignal.consentGiven` | OpenPush has no runtime consent gate. Do not call initialize until the user has consented; to withdraw afterwards call `OpenPush.User.pushSubscription.optOut()` and `OpenPush.logout()` — a full stop requires not initializing on the next launch. |
| `OneSignal.Debug.logLevel` | OpenPush has one diagnostic sink instead of log levels: set `OpenPush.onLog` to receive bounded messages, and filter them yourself. |
| `OneSignal.Debug.alertLevel` | OpenPush never shows alerts for diagnostics. Set `OpenPush.onLog` and surface what you want. |
| `OneSignal.Location.isShared` | OpenPush never collects location. Send a tag or alias you compute yourself if you need geo targeting. |
| `OneSignal.Location.requestPermission()` | OpenPush never collects location. |
| `OneSignal.User.onesignalId` | OpenPush does not yet return the server's user id to the SDK (the server has it; a future release will expose it). Use `externalId` for the id you set, or `pushSubscription.id` for this installation. |
| `OneSignal.User.setLanguage(_:)` | OpenPush sends the device's full language tag (for example `zh-Hant-TW`) with every registration; the server falls back from a regional tag to its base language when choosing localized copy. To force a different language, set a tag your segments can read. |
| `OneSignal.User.addObserver(_:)` | There is no user-state observer. Observe the push subscription instead: `OneSignal.User.pushSubscription.addObserver { state in … }`. |
| `OneSignal.User.removeObserver(_:)` | There is no user-state observer. Observe the push subscription instead. |
| `OneSignal.User.onJwtExpired(expiredHandler:)` | Use `OpenPush.onIdentityVerificationRequired` and call `login(externalId:authHash:)` with the refreshed proof. |
| `OneSignal.setProvidesNotificationSettingsView(_:)` | OpenPush installs no notification-centre delegate. Implement `userNotificationCenter(_:openSettingsFor:)` in your own delegate. |
| `OneSignal.Notifications.clearAllNotifications()` | Use the current `OneSignal.Notifications.clearAll()` spelling. |
| `OneSignal.Notifications.removeNotification(_:)` | OpenPush does not manage the notification centre. Call `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:)` directly. |
| `OneSignal.Notifications.removeGroupedNotifications(_:)` | OpenPush does not manage the notification centre. Use `UNUserNotificationCenter` directly. |

The second column is copied from the `unavailable` messages in
`Sources/OpenPushOneSignal/OneSignalUnavailable.swift`, so the compiler tells you
exactly what this table says.

### Behavior notes

These members compile and forward, so no build error will raise them. They behave
differently enough to be worth reading once before you ship.

- **`pushSubscription.optedIn` requires a token.** It is three things at once:
  authorization granted, an APNs token in hand, and no opt-out on record. A
  device that has been granted permission but has not yet received its token
  reads `false`, so a UI that treats `optedIn` as "the user said yes" will flicker
  through the first launch. Read `Notifications.permission` for the user's
  answer, and `optedIn` for whether a message can actually arrive.
- **Launch URLs open by default.** OpenPush opens a tapped
  notification's launch URL itself: any URL that parses,
  whatever its scheme, with `UIApplication.open`, shortly after the click
  listeners are told. **`OneSignal_suppress_launch_urls` keeps working:** set it
  to `YES` in the app's Info.plist and `OneSignal.initialize` turns opening off,
  so routing stays in your click listener (the key's name is also
  `OneSignal.suppressLaunchURLsInfoKey`). OpenPush's own key,
  `OpenPushSuppressLaunchURLs`, and `OpenPush.Notifications.openLaunchURLs = false`
  do the same. `event.launchURLOpened` tells a listener whether the SDK opened
  one. One addition: a button with a `url` of its own opens that URL (reported as
  `event.actionURL`); a button without one opens the push's launch URL.
  OpenPush always uses `UIApplication.open`, never an in-app browser.
- **Legacy notification removal calls stay unavailable.** The current
  `setBadgeCount` and `clearAll` calls forward. Older
  `clearAllNotifications`, `removeNotification`, and
  `removeGroupedNotifications` spellings remain compile-time errors; call
  `UNUserNotificationCenter` directly for identifier or group removal.
- **Language is the full tag.** Registrations send the device's preferred
  language as a complete BCP-47 tag — `zh-Hant-TW`, not `zh` — and the server
  falls back from a regional tag to its base language when it chooses localized
  copy. A segment or template keyed on the two-letter code still matches through
  that fallback; one keyed on an exact string match does not, so check any
  language condition you wrote against a truncated code.

---

## 4. Other platforms

The OpenPush Android and Unity SDKs carry compatibility layers of their own, each
with a migration guide that lists that platform's forwarded and refused symbols.
§2 and §3 above are the verdicts for iOS.

`Examples/MigratedFromOneSignal/README.md` shows an entire app migrating, as a diff
you can regenerate.
