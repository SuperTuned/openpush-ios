# Public API — 1.2.2

The receive-side surface of the SDK: setup, identity, tags, aliases, phone
numbers and phone codes, email addresses, push-subscription accessors with
opt-in control, notification permission and lifecycle listeners, launch-URL
handling, badge increments, in-app messages, Live Activity token forwarding,
VoIP pushes, persisted Custom Events for journey entry and exits, and the
Notification Service Extension handler. There is no notification-send or
console-management surface.

## OpenPush — setup

- `defaultServerURL` — the hosted OpenPush endpoint.
- `sdkVersion` — the SDK release version.
- `isInitialized` — whether `initialize` or `attach` has configured this process.
- `sdkKeyInfoKey` / `appIDInfoKey` (on `OpenPushConfiguration`) — the
  `Info.plist` keys OpenPush reads: `OpenPushSDKKey` and `OpenPushAppID`.
  `suppressLaunchURLsInfoKey` is `OpenPushSuppressLaunchURLs`, the
  boolean that turns launch-URL opening off at `initialize`.
- `initialize(appId:serverURL:appGroup:credential:provisional:transport:)` —
  configures the SDK, reading the public SDK key from `Info.plist` under
  `OpenPushSDKKey`.
  Refuses and leaves the SDK unconfigured when no key is bundled, reporting
  through both `onLog` and `onRegistrationFailed` rather than failing silently.
- `initialize(appId:sdkKey:serverURL:appGroup:credential:provisional:transport:)`
  — the same, with the key supplied in code. An explicit key always wins over the
  bundled one. `serverURL` defaults to `defaultServerURL`, `credential` to a
  closure returning `nil`. `provisional: true` requests provisional
  authorization with no prompt. Otherwise, when authorization already exists,
  initialization asks iOS to re-issue the APNs token without prompting.
  `appGroup` is the group the app shares with its extensions: pass it and
  OpenPush mirrors the app id, server URL, SDK key, APNs token, and subscription
  id into it as `OpenPushSharedState`, so a Notification Service Extension needs
  no hand-plumbed copies. The device credential is never mirrored.
- `attach(configuration:credential:transport:)` — the explicit-configuration
  form. `initialize` wraps it. Tags, aliases, and an identity set before the
  first `attach` of the process are kept and ride its first registration; a
  later `attach` or `initialize` is a workspace switch and clears them, so no
  session state crosses from one workspace to the next.
- `Transport` — injectable asynchronous HTTP transport used by tests and
  specialized hosts.
- `urlSessionTransport` — the default URLSession-backed transport.
- `onLog` — receives bounded SDK diagnostic messages. Do not log credentials
  or full APNs tokens from host code.
- `onRegistered` — called after the subscription endpoint accepts a device.
- `onRegistrationFailed` — called once after registration retries are exhausted,
  for an immediate 4xx rejection, or for a forwarded APNs registration failure.
  APNs diagnostics name missing capabilities and simulator limitations.
- `trackEvent(_:properties:)` — persists a validated Custom Event, attributes it
  to the current external ID or registered subscription, and sends it in batches
  of up to 50. The name must match `^[a-zA-Z0-9_\-. ]+$` and be at most 128
  characters — exactly the server's rule, so a name accepted here is a name
  accepted on the wire; anything else is dropped at the call site with a log
  naming the rule. Pending events survive relaunch. A transient failure (5xx,
  `429`, network) retries on the registration schedule: about 2 then 8 seconds,
  jittered, and a `429`'s `Retry-After` up to 30 seconds. After that the queue is
  held, with no timer, and goes out with the next event or accepted
  registration. Any other 4xx drops that batch with a log rather than retrying a
  refusal forever. At most 500 unsent events are kept; a new event past that
  evicts the oldest, with one log line. Every event carries an `idempotency_key` — a UUID
  generated when the event is recorded and persisted with it — so a batch that is
  retried after a response was lost cannot count the same event twice.
- `trackEvent(_:properties:idempotencyKey:)` — the same, with the key supplied by
  the caller. Two calls with one key are one event, whatever else differs, which
  is how an action that must count once per user or per device is recorded
  without the host keeping its own "already sent" flag. A key that is empty once
  trimmed is refused with a log and a fresh one is minted in its place, because
  sending no key would make the event a repeat of nothing.
- `SDKWrapper(name:version:)` / `wrapper` — identifies a wrapper SDK that
  embeds OpenPush. Set `OpenPush.wrapper` **before** `initialize` and every
  request from both processes adds `X-OP-SDK-Wrapper: <name>/<version>`
  alongside the always-present `X-OP-SDK: openpush/ios/<version>`, and the
  registration body carries `sdk_wrapper`. Both parts are trimmed, and a name or
  version that is empty after trimming leaves the wrapper unset with a log. It is
  not part of the configuration, so `attach` and a workspace switch leave it
  alone; an app integrating OpenPush directly never sets it.
- Attach and foreground transitions automatically POST `{"token":"…"}` to
  `/v1/apps/{app}/sessions`. The timestamp is persisted with the non-secret
  session state, limiting client traffic to one ping per 30 minutes; the server
  independently applies the same gap before counting a new session.
- Foreground time is accumulated until backgrounding and sent to the same route
  as `duration_seconds` with an idempotency key. Unsent time survives relaunch,
  retries keep the same key, and one-day wire chunks retain time accrued while
  an earlier request is in flight.

## Migrating from another push SDK

[`MIGRATING-FROM-ONESIGNAL.md`](MIGRATING-FROM-ONESIGNAL.md) is the whole
migration: the compatibility facade, the four migration overloads on the core
SDK, the delegate forwarding OpenPush requires because it never swizzles, and
tables of every forwarded and every refused symbol.

## In-app messages

`OpenPush.InAppMessages` exposes `paused`, `addTrigger`, `addTriggers`,
`removeTrigger`, `removeTriggers`, and `clearTriggers`. Trigger values may be
strings, numbers, or booleans; a value of any other type is dropped and logged,
rather than silently making a campaign untriggerable. Lifecycle and click
listeners return UUID handles used by the matching remove methods.
`InAppMessageLifecycleEvent` carries a typed `stage`
(`willDisplay`/`didDisplay`/`willDismiss`/`didDismiss`) alongside the `phase`
string, which is that stage's raw value, and the `layout` the message is
presented with (`center`, `top`, `bottom`, `full`, `carousel`);
`InAppMessageClickEvent` carries `firstClick`.

Eligible definitions are fetched after registration and after a new app session
(30 seconds in the background). The SDK renders server-compiled HTML in a
guarded WKWebView, persists dismissal/click/redisplay state, performs native
URL/permission/tag/outcome actions, and posts IAM impression, page-impression
and click receipts.

The engine behaves as follows.

- The message is presented in a window of its own, one level below the system
  alert level, so the app is free to push, present and dismiss underneath
  without the message riding along or being torn off with the view it was
  attached to, and so it never covers a system alert or the keyboard. That
  window's root view controller answers the rotation question with the host
  app's own answer, and its overlay is `accessibilityViewIsModal`, so assistive
  technology cannot reach past a message into the app behind it. Nothing is
  drawn until the document renders; the window fades in then and fades out on
  the way down. The slot is handed on synchronously, so the fade-out can never
  delay the message that replaces this one.
- A `top` or `bottom` banner is sized to its document — the height reported at
  the render and at any later re-measure — capped at 60% of the screen, so a
  runaway document cannot quietly become a full-screen message. The rest of the
  screen is still the app's: touches outside the banner's strip fall through to
  the app's own window underneath, and while nothing is drawn yet every touch
  does. A banner whose document never reports a height is the exception — it
  keeps the full frame it loaded with, and owns it, so the document's own close
  button still works. `center`, `full` and `carousel` keep the full safe-area
  frame.
- `paused = true` takes the message on screen down without counting a display.
  It returns to the front of the queue and is presented again on unpause.
  Pausing interrupts one presentation: a message that had already rendered keeps
  its impression and is not counted a second time when it returns; a message
  paused before rendering posts its impression when it first renders.
- `didDisplay` and the impression receipt fire only once the document has
  actually rendered. `willDisplay` is a request to show; it counts nothing.
- A document that fails to load — no window, an HTTP error, a navigation
  failure — counts nothing and is skipped for the rest of the session, so a
  broken message cannot take the slot repeatedly. The slot goes to the next
  eligible message.
- A successful fetch replaces the queue: a definition the server no longer
  returns can no longer be shown, and a message that comes back comes back with
  the fields the server sent last. A definition whose `end_time` has passed is
  not eligible. `end_time` is read as epoch seconds or as ISO-8601.
- A fetch that fails transiently is retried after 2 s and then 8 s. Anything
  else waits for the next session.
- A `session_time` or `min_time_since` condition wakes the engine on its own:
  a message waiting only on the clock is presented at its deadline rather than
  at the next unrelated re-evaluation.
- A carousel reports each page it reaches. The engine counts a page once per
  display and only after the document has rendered, so swiping back to a card
  already seen is not a second page impression; a message with a redisplay
  budget re-arms its pages for the next display.
- A click is persisted at click time, not at dismissal, so a process that dies
  mid-message does not re-report it. Each receipt carries `first_click`, true
  only for the first click on that message however many times it is shown — the
  same answer the click event's `firstClick` gives the host; a message with a
  redisplay budget re-arms its click ids for the next display.
- An action that asks for the push permission holds the queue. The next message
  waits until the prompt has been answered — granted, denied, or never raised at
  all — instead of arriving underneath an alert nobody has answered yet and being
  dismissed blind. The engine is told before the prompt goes up, so an action
  that also closes its message cannot release the slot in between. If no answer
  is ever reported — the person was sent to Settings and did not come back — the
  hold expires after 60 seconds and the queue moves on.
- The `in` operator reads the trigger's own value. A value that carries commas
  is a list: `tiers = "gold, silver"` is `in` `silver`, and is not `in` `sil`.
  Members and the value looked for are compared trimmed. A value with no comma
  has no list to read, so `in` stays a substring test. A condition value that
  itself carries a comma can never match a member of a list, since a member
  never contains one.
- A link to an origin other than the message's own opens in the system browser,
  and a link-activated navigation to another host with no target frame is
  treated the same way; same-host links load in place. Everything the document does for
  itself — the initial request, redirects, sub-frames, script-driven navigation
  — stays inside the web view. A `url_target` of `webview` opens an in-app
  Safari view controller instead.
- A presentation waits at most 10 seconds for an active key window (20 tries at
  half a second; time spent backgrounded does not count), then gives up and
  hands the slot on.

Three deliberate behavior differences matter during migration:

1. Tags, aliases, external identity, and opt-out intent set before initialization
   are kept and ride the first registration. Non-secret state is durable across a
   cold start; the identity authentication hash is memory-only.
2. Every registration rebuilds one idempotent body from the current tag and alias
   maps. There is no per-delta operation queue to strand.
3. OpenPush never swizzles. The two APNs forwarding entries above are the complete
   delegate integration.

## OpenPush — registration and receipts

- `currentToken` — the current APNs token, cached using the configured key.
  Read-only in practice: assigning it is deprecated. An assigned token is
  registered as `register(token:)` would register it, and `nil` clears it.
- `hexToken(_:)` — converts APNs token data to its lowercase hexadecimal form.
- `register(token:)` — registers the installation. The body carries the
  identity set with `login`, tags, aliases, and subscription intent. Transport
  errors and 5xx responses retry after 2 and 8 seconds (three attempts total). A newer
  registration supersedes a pending retry; 4xx responses never retry.
  An accepted registration stores the returned subscription id, persists it so
  `pushSubscription.id` survives a cold start, notifies subscription observers,
  and adopts a server-reported opt-out.
- `register(token:externalID:)` — deprecated. A non-empty `externalID` is
  applied as `login(externalId:)` without an auth hash, then the token is
  registered. Use `login(externalId:authHash:)` and `register(token:)`.
- `didRegisterForRemoteNotifications(deviceToken:)` — lowercases the forwarded
  APNs token and registers it.
- `didFailToRegisterForRemoteNotifications(error:)` — reports a named APNs setup
  diagnostic through `onRegistrationFailed`.
- `didReceiveRemoteNotification(userInfo:)` — forward from
  `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, the only
  callback a background (`content-available`) push reaches. It posts a `received`
  receipt and returns `@discardableResult` whether the payload was one OpenPush
  sent; `false` means another provider's push, or your own, and nothing was
  posted. It never calls your completion handler, never waits for the receipt,
  and never fires a click or foreground listener. The extension and the app may
  each post `received` for the same message — they are separate processes, and
  the app's in-memory dedupe cannot see the extension's receipt. The server keeps
  the first timestamp, so the duplicate is harmless.
- `receipt(_:messageID:then:)` — queues a received, confirmed, or clicked
  receipt and posts it. The queue is persisted per token key, so a receipt the
  server did not accept survives a relaunch instead of being lost with the
  process: it is retried after 2, 8, and 30 seconds, and when that table runs out
  it stays queued and is tried again on the next foreground or completed
  registration. A `429` is a wait; every other 4xx says the receipt will never be
  accepted, so it is dropped with a log rather than retried for the life of the
  install. The queue holds at most 500 unsent receipts, dropping the oldest past
  that with a log, and a backlog goes out in batches of up to 50 receipts per
  `/v1/ingest` request — the contract's `events` array, with each member carrying
  the keys a single receipt carries. A batch is cleared, dropped, or retried as
  one. Accepted receipts are deduplicated on type and message ID **across
  relaunches** — the last 500 accepted ids are persisted — but only within this
  process's world: an extension's receipt for the same message is in another
  process and is not seen here. A workspace switch discards both, so no receipt
  crosses workspaces. It needs an initialized SDK, a non-empty message ID, and a
  token: with any of the three missing it calls `then` and returns without a
  request. `then` fires exactly once per call, reporting that call's own outcome
  — it does not wait for a retry that may only complete in a later process.
- `pendingReceiptCount` — how many receipts are still owed to the server, read
  through to the persisted queue, for a host's own diagnostics screen. It is `0`
  before `initialize`, never exceeds the queue's 500-item bound, and it does not
  count an extension's receipts.
- `messageID(from:)` — extracts `op_message_id` from an APNs payload.
- `actions(from:)` — parses the composer’s ordered notification actions.
- `shortToken(_:)` — creates a display-safe abbreviated token.
- `deviceModel()` — returns the device machine identifier, and never names a
  device this install is not: a Simulator reports `Simulator <model id>` rather
  than the Mac's own hardware, Mac Catalyst reports `Mac`, and an unreadable
  machine string reports `unknown`.

Every registration also carries the device's preferred language as a full BCP-47
tag, script and region included (`zh-Hant-TW`, not `zh`); the server falls back
from a regional tag to its base language when it chooses localized copy. The APNs
environment is read from the provisioning profile once per process, not once per
registration.

## OpenPush — identity

- `IdentityResult` — `success`, `identityRejected(String)`, `failed(String)`.
  `identityRejected` means the server accepted the device and removed the
  identity: the installation is registered and anonymous, `User.externalId`
  reads `nil` from that point, later registrations stop re-asserting the refused
  id, and the string explains why.
- `login(externalId:authHash:completion:)` — identifies the installation. With
  a token already present the identity is sent immediately; otherwise it is
  stored and sent with the next registration, and the completion reports
  `success` with a log line noting the deferral. `authHash` is computed by the
  host's server, never on the device. The external ID persists; `authHash` is a
  bearer identity proof and is never written to `UserDefaults`. Logging in as
  a different external ID clears this device's tags and aliases first, so the
  previous user's targeting data is never written onto the new one. Logging in
  again as the *same* external ID with no hash, or an empty one, is a no-op that
  completes `success` and sends nothing — there is nothing to change. A rotated
  or different hash for that id still registers, and so does a hash-less call
  while `onIdentityVerificationRequired` is awaiting its proof. The no-op needs
  the identity to have been carried by a registration the server accepted: after
  a login whose registration failed, calling it again registers rather than
  reporting a success that only happened on the device.
- `logout(completion:)` — detaches the installation from its identified user.
  Every later registration carries an explicit empty `external_id`, and the
  tags and aliases this device staged — including those set while anonymous —
  are cleared locally, cancelling the open write window with them. On an install
  that was never identified, or whose detach a registration has already
  delivered, it sends nothing and completes `success` — and still clears those
  staged tags and aliases, because a logout always leaves the install holding
  nobody's data. A detach whose registration failed is not treated as delivered:
  calling `logout()` again sends it.
- `onIdentityVerificationRequired` — fires once per process, with the external
  ID, when a previously verified identity was restored without its hash.
  Registrations omit `external_id` until `login(externalId:authHash:)` runs
  again, so the server keeps the existing link instead of stripping it. Assign
  it before or after `initialize`: a request raised while no hook was installed
  waits and is delivered the moment one is assigned.

## OpenPush.User

- `addTag(key:value:)` / `addTags(_:)` — update the session map and join a fixed
  300 ms write window measured from the first unflushed write. A key or value the
  server would refuse is dropped here instead, one log line per key naming the
  rule it broke: an empty key, a key containing whitespace, a key over 60
  characters, or a value over 300. The rest of the batch still travels — one
  malformed tag must not cost the app the other tags, the identity, and the token
  in the same body. An empty *value* is not malformed: it is `removeTag`'s
  deletion signal.
- `removeTag(_:)` — deletes one tag by sending an empty value for its key. It
  accepts keys the validator above would refuse — with one exception: an empty
  key is refused on this path too, because there is no such tag to clear. The
  other rules are relaxed because an install from an earlier SDK build may have
  put such a key on the server and a tombstone is the only way to clear it.
- `removeTags(_:)` — deletes several keys in one coalesced write.
- `getTags()` — the tags this user holds. A deletion that has not reached the
  server yet is still in the registration body as an empty value, but it is not a
  tag any more, so it is not reported here. Once the registration carrying it is
  accepted, the tombstone is pruned from the body too.
- `externalId` — the identified external ID, or `nil` when anonymous/detached.
- `pushSubscription` — a live `PushSubscription` accessor.

The session tag map is sent with every registration while it is non-empty; the
server merges it.

- `addAlias(label:id:)` / `addAliases(_:)` — update aliases and join the same
  fixed 300 ms window as tag writes. An empty label or an empty id is refused
  with a log rather than merged: through this path an empty id is a typo, not a
  deletion.
- `removeAlias(_:)` — deletes one alias by sending an empty value for its label.
- `removeAliases(_:)` — deletes several labels in one coalesced write.

Aliases are additional lookup labels (`label: id`) for the user. They are for
lookup and targeting only: adding one never merges two users. The server keeps
at most ten labels per user, and `external_id` is not one of them — it belongs
to `login`/`logout`. Like tags, the session alias map is sent with every
registration while it is non-empty, and an alias change on an app with identity
verification enabled can come back with the identity rejected.

## Phone numbers

Each of the four is `@discardableResult` and returns `Bool`: `true` when the
number is valid and the write was queued, `false` for an invalid number or a
call before `initialize` (with a log line; nothing is sent).

- `User.addSms(_:)` / `User.addWhatsApp(_:)` — add a number on that channel.
  It is registered through `POST /v1/apps/{app_id}/subscriptions` with
  `platform` `sms` or `whatsapp`, the number as `token`, the logged-in user's
  `external_id` (and auth hash, when this install holds one for that user), and
  **no `status`**: a new number is *Not verified* and receives nothing until a
  phone code for it is approved through `OpenPush.Verify`.
- `User.removeSms(_:)` / `User.removeWhatsApp(_:)` — opt the number out: the
  same body with `status: -2`, the only status a device may send for a number.

A number is normalised exactly as the server's `normalise_e164` does it: every
character that is not a digit or `+` is removed, a leading `00` becomes `+`, and
the result must be `+` followed by 8 to 15 digits, the first not `0`.
`+1 (415) 555-0123`, `+1-415-555-0123` and `0014155550123` all become
`+14155550123`; `415`, `+0123456789` and a second `+` are invalid. The user who owns a
number is the one logged in when the call is made. Writes are persisted under
the configuration's token key and sent one at a time, in order; a later write
for the same number replaces one still waiting. A transport failure, `429` or
`5xx` is retried on the registration schedule (2 s, 8 s, `Retry-After` honoured
up to 30 s), then held until the next number write or accepted registration;
any other refusal is logged and dropped. The subscription id an add returns is
kept per channel and number and forgotten on remove. Log lines show only the
last four digits.

## OpenPush.Verify

```swift
static func start(_ phone: String, channel: OpenPushVerifyChannel = .auto,
                  locale: String? = nil) async throws -> OpenPushVerification
static func check(_ verification: OpenPushVerification,
                  code: String) async throws -> OpenPushVerification
static func resend(_ verification: OpenPushVerification,
                   channel: OpenPushVerifyChannel) async throws -> OpenPushVerification
```

`start` posts `{"to", "channel", "locale"?}` to `/v1/apps/{app_id}/verify`;
`check` posts `{"to", "code"}` to `/verify/{id}/check`; `resend` posts
`{"to", "channel"}` to `/verify/{id}/resend`, which the server allows 30
seconds after the last send. `start` checks the number as above first and
throws `invalidNumber` without a request. An approved check marks the number's
SMS and WhatsApp subscriptions subscribed on the server. Each call is one
request and is not retried.

- `OpenPushVerifyChannel` — `auto`, `sms`, `whatsapp`, `call`.
- `OpenPushVerification` — `id`, `maskedNumber`, `channel` (the one the server
  used), `status` (`pending` — also after a wrong code — `approved`, `expired`,
  `maxAttempts`), `attempts`, `expiresAt` (`Date?`). It keeps the full number
  in memory only for `check` and `resend`; it is not `Codable` and the SDK never
  stores it.
- `OpenPushVerifyError` — `code` and `message`. `rateLimited`, `tooSoon`,
  `notPending`, `provider`, `optedOut` (`opted_out`, 409: the number replied
  STOP or opted out; never retry), `noCredit` (`credit`, 402: the workspace has
  no text credit left), `noRate` (`no_rate`, 409: texts to this number's
  country are not priced or allowed) and `refused` come from the server's
  `{"detail": {"code", "message"}}`; a plain-string `detail`, an unknown code,
  any other status without a code, or a call before `initialize` is `refused`,
  and a `429` without a code is `rateLimited`. `invalidNumber` (and, for email addresses, `invalidEmail`) is
  raised before sending. `network` covers a
  transport failure, a `5xx`, and a 2xx body that cannot be read.

Give the code field the `.oneTimeCode` text content type so iOS offers an SMS
code above the keyboard.

## Email addresses

Both are `@discardableResult` and return `Bool` on the same terms as the phone
number calls: `true` when the address is valid and the write was queued,
`false` for an invalid address or a call before `initialize` (with a log line;
nothing is sent).

- `User.addEmail(_:)` — `POST /v1/apps/{app_id}/subscriptions` with
  `platform` `email`, the address as `token`, the logged-in user's
  `external_id` (and auth hash, when this install holds one for that user), and
  no `status`. The server answers `{"id", "status", "status_name", "created"}`:
  status `1` for a new or re-added address, `-2` when this app's suppression
  list has it. A `-2` is logged as suppressed and not retried.
- `User.removeEmail(_:)` — the same body with `status: -2`, which removes the
  subscription. It is not an unsubscribe: no suppression is written, and a
  later `addEmail` subscribes the address again.

The address is trimmed and lower-cased; it must then be at most 254 characters
with exactly one `@`, a non-empty local part and a dot in the domain, or the
call fails locally with `OpenPushVerifyError.Code.invalidEmail` (logged, never
sent). Writes share the phone numbers' persisted queue, keyed `email:<address>`:
in order, a later write for the same address replaces one still waiting,
transport failures, `429` and `5xx` are retried on the registration schedule
and then held, and a `400` is final — its words are logged as a `refused`
error and the write dropped. The subscription id an add returns is kept per
address and forgotten on remove. Log lines show only the domain.

## OpenPush.PushSubscriptionState

`id` (the subscription identifier from the last accepted registration), `token`
(the current APNs token), `optedIn` (a positive device status, a token present,
and no opt-out on record), and `status` (the resolved `notification_types`
value). `status` remains optional for source compatibility but is never `nil`.

## OpenPush.PushSubscription

- `id`, `token`, `optedIn`, and `status` — computed live whenever read.
- `optIn()` — clears the retained opt-out and restores the device's real status.
  It requests authorization when possible and falls back to Settings after iOS's
  prompt limit.
- `optOut()` — opts this installation out with status `-2`. The device stays
  registered and keeps its token; the server stops selecting it.
- `snapshot()` — captures the live values as an equatable
  `PushSubscriptionState`.
- `addObserver(_:)` / `removeObserver(_:)` — change-only subscription-state
  observers keyed by the returned `UUID`.
- `addChangeObserver(_:)` / `removeChangeObserver(_:)` — the diffing form. The
  same moments reach both, but this one hands over an
  `OpenPush.PushSubscriptionChange`, so a host can act on what actually moved
  without keeping its own copy. Change observers keep their own list: an id from
  `addObserver` means nothing here, and one from `addChangeObserver` means
  nothing to `removeObserver` — either mismatch is a no-op.

Both pairs are declared statically and are also available on the instance
(`OpenPush.User.pushSubscription.addChangeObserver { … }`); both spellings reach
the same list.

## OpenPush.PushSubscriptionChange

`previous` (the state that was replaced, `nil` for the first change the SDK
reports, because there is no earlier state to name) and `current`. The chain is
continuous: each change's `previous` is the `current` of the one before it.

## Subscription status (`notification_types`)

Every registration carries `status`. Any positive value is subscribed. On iOS,
the value is the OR of the authorization surfaces Apple reports:

| Bit | Authorization |
|---:|---|
| 1 | Badge |
| 2 | Sound |
| 4 | Alert |
| 8 | CarPlay |
| 16 | Critical Alert |
| 32 | App Notification Settings |
| 64 | Provisional |
| 128 | Announcement |
| 256 | Time Sensitive |

An authorized device with every exposed surface disabled reports `1` as the
Subscribed floor. `0` means permission denied, `-18` means never prompted,
`-19` means prompted but unanswered, and `-2` is the user's retained opt-out.
The server owns `-10`, `-22`, and `-31`; the SDK never claims them. Provisional
authorization is a positive mask containing bit 64, never `-50`.

The opt-out and underlying device status persist together. `-2` wins while the
user is opted out, and `optIn()` restores the retained device value rather than
guessing `1`.

A device that was denied notifications becomes targetable again automatically —
the SDK recomputes at launch and on every foreground and updates the subscription
when the value changed. There is no out-of-app mechanism: the change reaches
OpenPush on the next launch or foreground.

## OpenPush.LiveActivities

Every call is queued on disk and retried. Update tokens are retained for a day,
push-to-start tokens for a year, and clicks for a month. A call made before the
device has a push token waits for the registration that brings one. A transient
failure retries on the registration schedule (about 2 then 8 seconds, jittered)
and is then held until the next accepted registration.

- `setup(_:options:)` — observes a type conforming to
  `OpenPushLiveActivityAttributes`, including update/push-to-start tokens,
  dismissals, and confirmed receipts. The type name is derived from the Swift
  struct and the topic comes from `attributes.openpush.activityId`.
- `setupDefault(options:)` / `startDefault(_:attributes:content:)` — setup and
  locally start the dictionary-backed default attributes type.
- `enter(_:withToken:completion:)` / `exit(_:completion:)` — register or remove
  an update token. Enter can queue before the SDK learns an activity type.
- `setPushToStartToken(_:withToken:)` / `removePushToStartToken(_:)` — iOS 17.2+
  string or `T.Type` forms.
- `trackClickAndReturnOriginal(_:)` — records an OpenPush widget click and
  returns the original deep link.
- `setup(_:activityType:)` and the labelled token methods remain as deprecated
  source-compatible 1.0 APIs.

The extension-safe `OpenPushLiveActivities` product contains
`OpenPushLiveActivityAttributes`, `OpenPushLiveActivityContentState`,
`DefaultLiveActivityAttributes`, `OpenPushAnyCodable`,
`OpenPushLiveActivitySetupOptions`, and `.openpushWidgetURL`. Link that product
to widget extensions; `OpenPush` itself uses app-only APIs. `AnyCodable` and
`LiveActivitySetupOptions` remain as deprecated typealiases for the two prefixed
types. `DefaultLiveActivityAttributes` keeps its unprefixed name on purpose: the
Swift type name is the ActivityKit `attributes-type` that push-to-start payloads
must match, so it is a wire value. Activity IDs may not contain `/`, and tokens
must be hex.

## OpenPush.Notifications

- `permission` — the cached authorization state, refreshed at `attach`,
  `initialize`, actual app foreground transitions, and `requestPermission`.
  Receiving a notification does not refresh authorization or rewrite the
  subscription status.
- `permissionStatus` — the same cache unflattened: `OpenPush.PermissionStatus`
  is `.notDetermined`, `.denied`, `.granted`, `.provisional`, or `.ephemeral`,
  and `isGranted` is true for the last three because all three deliver. Refreshed
  on exactly the same occasions as `permission`.
- `canRequestPermission` — true while authorization is undetermined or
  provisional. Quiet authorization does not consume the standard prompt; a
  denial, full grant, or App Clip grant does.
- `requestProvisionalPermission(completion:)` — requests provisional
  authorization: no prompt, delivery straight to the notification centre, and
  the user promotes or silences it from the notification itself. It never routes
  to Settings, because nothing was refused. A grant starts APNs registration.
- `requestPermission(fallbackToSettings:completion:)` — requests alert, sound,
  and badge authorization, and starts APNs registration on a grant. iOS cannot
  prompt again after a denial; with `fallbackToSettings` this opens the app's
  notification settings and reports `false`.
- `addPermissionObserver(_:)` / `removePermissionObserver(_:)` — change-only
  permission observers keyed by the returned `UUID`.
- `onAppForegrounded()` — recomputes authorization and re-registers only when
  `notification_types` changed. UIKit apps receive this automatically; hosts
  without UIKit can forward their own lifecycle event.
- `addClickListener(_:)` / `removeClickListener(_:)` — notification-open
  listeners, keyed by the returned `UUID`. A tap that arrived before any
  listener existed is held and replayed to the first listener added, on the
  main thread, after `addClickListener(_:)` has returned its handle. Held
  clicks are in memory only, are capped at the ten most recent, and reach only
  that first listener.
- `addForegroundLifecycleListener(_:)` /
  `removeForegroundLifecycleListener(_:)` — foreground-arrival listeners.
- `processForeground(_:)` — forward from
  `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)`
  and return the result. It fires foreground listeners, posts `received`, posts
  `confirmed` when the returned presentation options are non-empty, and returns
  no presentation options if a listener called `preventDefault()`.
- `processForeground(_:completion:)` — the same work, for a host that wants to
  decide later: hand it that delegate method's completion handler instead of
  returning a value. A listener that called `preventDefault()` may still call the
  event's `display()` to present after all, and the answer is held until it does
  — for at most 25 seconds, after which the notification is suppressed as asked.
  The completion handler runs exactly once on every path. A notification that is
  not OpenPush's, or that no listener suppressed, is answered immediately and
  nothing is held. `confirmed` is posted only when the final options passed to
  that completion handler are non-empty, including a later `display()`.
- `processForeground(userInfo:completion:)` — the same asynchronous decision
  path when a delegate adapter already has the APNs payload dictionary.
- `processClick(_:)` — forward from
  `userNotificationCenter(_:didReceive:withCompletionHandler:)`. It posts a
  `clicked` receipt and fires click listeners. A dismissal — the
  `UNNotificationDismissActionIdentifier` response that a category registered
  with `.customDismissAction` delivers here — is not an open: it posts no
  receipt and fires no listener. A tap is handled once per message: any
  response, whatever its action, for a message this install already handled —
  a resent copy, or iOS delivering the response again, even across a relaunch —
  is logged through `onLog` and ignored, with no receipt and no listener. iOS
  forwards at most one response per delivered notification, so a second one is
  a tap on another copy.
  Handled taps are kept in `UserDefaults` for seven days, at most 200. A
  notification OpenPush did not send is never recorded, and if the history
  cannot be read the tap is handled anyway.
- `isRepeatClick(_:)` — whether `processClick(_:)` would ignore this response
  as a repeat. Reading only; for a bridge that acts on a tap itself, such as
  opening its launch URL, before forwarding it. A dismissal and a notification
  OpenPush did not send answer `false`.
- `recordClick(userInfo:)` — records a tap a bridge handles itself, without
  `processClick(_:)`, and answers whether it is the first for its message;
  `false` means skip its listeners and receipt. Shares the history with
  `processClick(_:)`, so the two paths never handle one message twice.
- `openLaunchURLs` — `Bool`, **default `true`**. A tap opens the
  notification's `launchURL` — or the tapped button's own `url` — with
  `UIApplication.open` shortly after the click listeners are told, and the
  event's `launchURLOpened` is `true`. Any URL that parses is opened, whatever its
  scheme. A cold-start tap opens without waiting for a listener; a repeated tap
  and a background push open nothing. Set it to `false` to route URLs yourself, at
  any time; the Info.plist boolean `OpenPushSuppressLaunchURLs`
  (`OpenPushConfiguration.suppressLaunchURLsInfoKey`) set to true turns it off at
  `initialize`. An app that keeps it on and also routes URLs should skip a click
  whose `launchURLOpened` is `true`.
- `clearAll()` — removes every delivered notification and clears the app badge.
  The stored badge count goes back to 0 with it.
- `setBadgeCount(_:)` — sets the app badge through `UNUserNotificationCenter`.
  It also stores the count in the App Group passed to `initialize`,
  so the next push with a badge increment counts up from it. Without an App
  Group only the icon changes.
- `badgeCount` — `Int?`, the stored badge count: what `setBadgeCount(_:)`
  set, or what the service extension raised it to for a push with a badge
  increment. `nil` without an App Group.

Without this forwarding, listeners never fire and app-side receipts are never
posted.

## OpenPush.ClickEvent and OpenPush.ForegroundEvent

`ClickEvent` carries `messageId`, `notification`, and `actionId` (`nil` for the
default open action), `launchURLOpened` — `true` when the SDK
opened a URL for this tap (`Notifications.openLaunchURLs` is on by default and
the tap had a URL), `false` otherwise — and `actionURL`, the tapped button's own
link (`nil` for the default open and for a button without one). A button's link
is opened in place of the push's `launchURL`; a button without one opens
`launchURL` as any tap does. `ForegroundEvent` carries `messageId` and `notification`,
and `preventDefault()` suppresses the system presentation for that notification.

`ForegroundEvent.display()` takes that back: having prevented the default,
present the notification after all — for when the in-app surface you meant to
show instead could not be shown, so the notification is not simply lost. Only
`processForeground(_:completion:)` can honor it. Under the synchronous
`processForeground(_:)` the answer has already gone back to iOS and `display()`
does nothing, and it also does nothing without a preceding `preventDefault()`,
after the 25-second window, or on a second call.

`payload` — the top level of the APNs `userInfo` coerced to strings — remains on
both, **deprecated**: it flattens nested objects and loses their types. Read
`notification` instead.

## OpenPush.Notification and OpenPush.JSONValue

`OpenPush.Notification` (`OpenPushNotification` in `OpenPushCore`) is one APNs
payload parsed into the fields a host reads. Both event types carry it, and the
service extension builds the same value. Construct one anywhere with
`OpenPush.Notification(userInfo:)`.

Every field is optional because APNs only guarantees `aps`:

- `messageId`, and `isOpenPush` — `messageId != nil`. It is `false` for a local
  notification the host scheduled or another provider's push, which is what the
  SDK checks before reporting anything.
- `title`, `subtitle`, `body` — from `aps.alert`, whether it is an object or a
  bare string, falling back to top-level `title` / `body`.
- `launchURL` — the composer's **`deep_link`** key, when it parses as a URL.
  The SDK opens it on a tap unless `Notifications.openLaunchURLs` is off (on by
  default); with it off, routing is the app's decision.
- `imageURL` — the composer's **`image_url`** key. The service extension fetches
  it; the app process does not.
- `badge`, `sound`, `category`, `threadId`, `interruptionLevel`,
  `relevanceScore`, `contentAvailable`, `mutableContent` — the `aps` fields.
- `badgeIncrement` — the push's `op_badge_increment`, a positive integer
  the service extension adds to the stored badge count; `nil` otherwise.
- `actions` — the composer's ordered `[OpenPushPayload.Action]`: `id`, `label`,
  `icon`, `systemIcon`, and `url`, the button's own link when it has
  one.
- `additionalData` — every top-level key that is not `aps`, not a rendered field
  (`title`, `body`, `image_url`, `deep_link`), and not `op_`-prefixed: the
  composer's own custom data, nesting intact.
- `rawPayload` — the whole `userInfo` in the same form, so nothing is hidden by
  the fields this type happens to name.

`OpenPush.JSONValue` (`OpenPushJSONValue`) is what those two dictionaries hold:
a `Sendable`, `Equatable`, `Codable` enum of `.string`, `.number`, `.bool`,
`.null`, `.array`, `.object`. APNs hands the app a `[AnyHashable: Any]`, which is
neither `Sendable` nor safe to give a host closure. Conversion keeps every
JSON-representable key with its nesting intact; non-string keys and non-JSON
values are dropped, and **every number is a `Double`**, so an integer read back
is `1.0`. Read it with `stringValue`, `numberValue`, `boolValue`, `objectValue`,
`arrayValue`, the `[key]` subscript, or `anyValue` for a Foundation round trip.

## OpenPushCore

### OpenPushConfiguration

Holds `serverURL`, `appID`, public `sdkKey`, `platform`, the `tokenKey` used for
the APNs-token cache, and the optional `appGroup` the app and its extensions
share — the group `OpenPushSharedState` is mirrored into, and `nil` when the host
configured none. Initialize with
`OpenPushConfiguration(appID:sdkKey:serverURL:platform:tokenKey:appGroup:)`;
`serverURL` defaults to `OpenPushConfiguration.defaultServerURL`. Explicit URLs
have trailing slashes removed, and a blank `appGroup` is read as none.

### OpenPushPayload

- `messageID(from:)` — extracts a string or numeric OpenPush message ID.
- `actions(from:)` — accepts structured APNs actions or the JSON string used by FCM.
  Each `Action` carries `url` when its row has one;
  `Action(id:label:icon:systemIcon:url:)` defaults it to `nil`.
- `actionCategory(from:)` — extracts the stable server-generated category ID.
- `badgeIncrement(from:)` — the `op_badge_increment` value
  (`badgeIncrementKey`) as a positive integer, or `nil`.
- `receiptBody(types:messageID:token:appID:)` — constructs an ingest payload.

### OpenPushSharedState

What a Notification Service (or Content) Extension needs to talk to OpenPush,
mirrored into the App Group the host configured. An extension runs in its own
process with its own container: it cannot read the app's `UserDefaults.standard`
and does not have the app's `Info.plist`.

- `appID`, `serverURL`, `sdkKey`, `token`, `subscriptionID`, `appGroup` — the
  mirrored values. **The device credential is never among them**: it
  authenticates this install, and an App Group is readable by every extension the
  app ships, so it stays in the shared Keychain.
- `save(_:appGroup:)` — writes the mirror. `OpenPush` calls it on `attach` and
  whenever the token or subscription id changes; a host does not call it.
- `load(appGroup:)` — reads it back, or `nil` when the group holds no mirror yet,
  so an extension that runs before the app ever initialized OpenPush can tell
  that apart from a half-written configuration.
- `clear(appGroup:)` — removes the SDK's own keys and nothing else; the host's
  values in the same group are untouched.
- `configuration` — an `OpenPushConfiguration` an extension can send receipts
  with.
- `keyPrefix` — `openpush.shared.`; every key is namespaced, because the App
  Group belongs to the host and the SDK is a guest in it.
- `badgeCount(appGroup:)`, `setBadgeCount(_:appGroup:)`,
  `incrementBadgeCount(by:appGroup:)` — the stored badge count the app
  and the service extension share, under `badgeCountKey`. It is kept outside the
  mirror, so `save` and `clear` never touch it, and it never goes below 0.

### DeviceCredentialStore

Shared-Keychain credential storage for an app and its Notification Service
Extension:

- `save(_:)` — writes the credential with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, updating an existing item
  in place (`SecItemUpdate`, falling back to `SecItemAdd`). It never deletes
  first, so a failed write leaves the stored credential as it was.
- `load()` — reads the credential. An item stored with an older accessibility
  class is moved to the one above in place, keeping its value.
- `wipe()`
- `migrateLegacy(defaults:key:)`

The configured Keychain access group must appear in both targets' signed
entitlements. Because the class is "this device only", the credential is not
restored onto another device from a backup; the new device registers as its
own install.

## OpenPushNSE

### OpenPushNotificationServiceHandler

A whole Notification Service Extension in one object: action buttons, media
attachment, and delivery receipt, driven from `didReceive`.

- `init(options:categories:download:transport:scheduler:random:)` — every
  argument after `options` is a test seam with a working default, so a host
  writes `OpenPushNotificationServiceHandler(options: …)`.
- `didReceive(_:withContentHandler:)` and `serviceExtensionTimeWillExpire()` —
  forward both from `UNNotificationServiceExtension`. That is the whole
  integration.
- `handleIfOpenPush(_:withContentHandler:) -> Bool` — for an extension that
  already handles another sender's pushes. Returns `false`, and never calls the
  content handler, when the payload has no `op_message_id`; otherwise behaves
  exactly like `didReceive` and returns `true`.
- `serviceExtensionTimeWillExpireIfHandling() -> Bool` — its expiry counterpart:
  `true`, after delivering what is ready, while OpenPush still holds a request
  it has not delivered; `false` otherwise, so the caller's own expiry code runs.

The content handler is called **exactly once on every path**, including the
expiry path and a payload OpenPush did not send — that one is handed straight
back untouched.

Delivery is gated on all three pieces of work: the action category registered,
the attachment finished or skipped, and the receipt completed (with any status,
or an error) or skipped. The receipt is not fire-and-forget, because calling the
content handler lets iOS suspend the extension and a request still in flight —
or a jittered one not yet fired — dies with it. That reliability costs latency,
so the jitter is short and the work overlaps: the receipt and the image fetch
both start in `didReceive`, and the worst case is ~2 s of jitter plus the
request, against a 12 s image fetch alongside it.
`serviceExtensionTimeWillExpire` delivers immediately whatever is ready; the
category is set on the content synchronously in `didReceive`, so the buttons
survive an expiry even when the image and the receipt do not. Once the content
has been handed over it is the system's: the handler drops its reference under
its lock, so a download or receipt that lands afterwards has nothing to mutate.

`Options`:

- `appGroup` — the group the app mirrors `OpenPushSharedState` into. Without one
  the extension cannot read the APNs token, so no receipt can be sent, and a push
  with `op_badge_increment` leaves the badge unchanged (logged once). With one, the
  increment is added to the stored badge count and the sum is shown, and an
  absolute `aps.badge` is recorded as the stored count. It is also
  where the action-category recency ledger is kept, so the app and every
  extension agree on which categories are the recent ones.
- `credentialStore` — optional. The shared-Keychain `DeviceCredentialStore`
  holding this install's device credential, which is never mirrored into the App
  Group. When it yields a credential the receipt carries `X-OP-Device-Key`;
  without one the receipt is still posted, authenticated on the SDK key.
- `configuration` — explicit configuration. When `nil`, the App Group mirror is
  used, and the bundled `OpenPushAppID` / `OpenPushSDKKey` keys after that.
- `receiptTypes` — defaults to `["received", "confirmed"]`.
- `receiptJitter` — the random delay range before the receipt, `0...2` seconds,
  so a broadcast does not turn every device's wake-up into one spike. Delivery
  waits for the receipt; the default jitter of 0–2 s spreads a large campaign's
  receipts, and it is added to how long the notification takes to appear. Raise it
  only if your server asks for it.
- `loadAttachments` — set `false` to render text only and never fetch
  `image_url`; `attachments` is the `OpenPushAttachmentLoader.Options` used when
  it is `true`.
- `onEvent` — `(@Sendable (String) -> Void)?`, one short line per piece of work:
  `"actions: <n>"` (the number of buttons actually registered — `0` when a category
  the host owns was left alone), `"attachment: ok|skipped|failed"`, `"receipt: HTTP <code>"`,
  or `"receipt: skipped (<reason>)"`, and for a push with a badge increment
  `"badge: <count>"` or `"badge: skipped (<reason>)"`. It may be called from any thread. It is a
  debug surface; diagnostics also go to `NSLog`, because an extension is a
  separate process with no access to the app's `onLog` hook.

`urlSessionTransport` and `dispatchAfter` are the public defaults behind the
`Transport` and `Scheduler` seams.

### OpenPushAttachmentLoader

Downloads the media a push refers to and turns it into a
`UNNotificationAttachment`. The handler uses it; a host driving its own
extension can call it directly.

- `load(_:options:download:completion:)` — completes with an attachment, or with
  `nil` when the media is unusable for any reason. Nothing throws and nothing
  traps: `completion` runs exactly once, so a notification still renders as text.
- `fileExtension(for:mimeType:allowed:)` — the extension the file should be stored
  under. The URL's own path extension wins when it is on `allowed` (which defaults
  to the standard allowlist, and is the caller's `Options.allowedExtensions` when
  the loader asks); otherwise the response's MIME type is mapped.
- `attachmentIdentifier` — `"openpush-image"`, carried by every attachment it
  produces.
- `Options` — `timeout` (12 s, bounding the whole fetch), `maxBytes` (20 MB), and
  `allowedExtensions`.

It is deliberately strict, because it runs inside an extension with a short
budget and hands a file to the system to render: `https` only, never a cleartext
URL; the type must be allowlisted (jpg, jpeg, png, gif, heic, mp4, m4v, mov,
mp3, m4a, wav, aiff); a URL whose path extension is present but not allowlisted
is refused without being fetched; and the size is refused on the declared length
before anything is read, and again on the bytes that actually landed. The body
never enters memory: the `Download` seam hands over a **file** (the default is a
`URLSessionDownloadTask`), the staged file's own size is what the ceiling is
checked against — the only thing that can catch a chunked response that declared
no length — and the file is then moved into place. A refused download is deleted
rather than left in the container. It stays out of UIKit so it remains
extension-safe.

### OpenPushReceiptRequest and OpenPushNotificationActions

`OpenPushReceiptRequest.make(configuration:deviceCredential:token:messageID:types:)`
constructs a bounded `POST /v1/ingest` request suitable for a Notification
Service Extension. `deviceCredential` is `String?`: with `nil` (or empty) the
`X-OP-Device-Key` header is omitted.

`OpenPushNotificationActions.apply(from:to:categories:ledger:completion:)`
registers and applies the exact action category configured for the incoming
notification, and completes after the write so an extension can hold its content
back until the buttons it is about to show exist. The completion is given the
number of actions registered, which is `0` on every path that registers nothing,
so a caller reports what happened rather than what the payload asked for. It
completes exactly once on every path, including the ones that register nothing: a `categoryIdentifier` the
host set itself is left alone, and a payload with no actions, or with no category
to register them under, completes without touching the store at all. OpenPush-owned categories are
bounded to the 32 most recently used, tracked in `ledger` (pass the App Group's
suite so the order is shared with the app). `apply(from:to:)` is the
fire-and-forget form.

## OpenPushVoIP

A separate product, so an app without calls never links PushKit. It depends on
`OpenPush` and sends through the same request path, SDK key and headers.

- `start(handler:)` — registers `PKPushRegistry` for `.voIP` and posts the VoIP
  token to `POST /v1/apps/{app_id}/voip-tokens` with this device's push
  subscription id and `sandbox` (the build's signed APNs environment; `false`
  without an embedded profile). It posts again when the token or the
  subscription id changes, and retries a failed post when the app next comes
  forward. Calling it again replaces the handler.
- `stop()` — unregisters from PushKit and removes the token with
  `POST /v1/apps/{app_id}/voip-tokens/remove`.
- `token` — the current PushKit VoIP token, hex-encoded, or `nil`.
- `isStarted` — whether `start` was called without a later `stop`.
- `Handler` — `@Sendable (Push, @escaping @Sendable () -> Void) -> Void`, called
  on the main queue for every incoming VoIP push with PushKit's completion.
- `Push` — `messageId`, `data` (every top-level key that is not `aps` and not
  `op_`-prefixed), `rawPayload`, and `isOpenPush` (`op_voip` is `"1"`).
  `Push(payload:)` builds one from a payload dictionary.

**iOS requires every VoIP push to be reported to CallKit** with
`CXProvider.reportNewIncomingCall(with:update:completion:)` before the handler
returns; an app that does not is terminated, and after repeated failures iOS
stops delivering VoIP pushes to it. With no handler (`stop` raced the push) the
completion is called at once and the miss is logged.

## OpenPushOneSignal — the compatibility facade

An **opt-in** product that exposes over OpenPush the names a host migrating from
another push SDK already wrote, so that host changes one import line and its
existing call sites keep compiling. The exception is that SDK's protocol-based
listeners and observers (`addClickListener`, `addForegroundLifecycleListener`,
`addPermissionObserver`, `pushSubscription.addObserver`): they take a closure
here rather than a conforming object, so those call sites are a type error until
you rewrite them as closures. Add the product to a target explicitly — it is not
part of the `OpenPush` product, so a host that does not want the foreign
spelling never sees it.

It is names only: every supported member is one line of delegation to the
matching `OpenPush` call. No state, and no foreign implementation code. The one
behaviour it adds is the replaced SDK's launch-URL opt-out: its
`initialize` turns `OpenPush.Notifications.openLaunchURLs` off when the app's
Info.plist sets that SDK's suppress-launch-URLs key (named in the migration
guide) to true. `suppressLaunchURLsInfoKey` holds the key's name.

**Mutually exclusive with the SDK it replaces.** Both define the same top-level
enum, so linking them into one target makes every reference ambiguous.

Nothing is stubbed: there is no member that accepts the call and quietly does
nothing. The symbols enumerated in
[`MIGRATING-FROM-ONESIGNAL.md`](MIGRATING-FROM-ONESIGNAL.md) §3 — consent
gating, the server-side user id, `setLanguage`, the user-state
observer, location, log levels, and the remaining legacy
notification-centre methods — are **declared and marked `unavailable`**, so each
of those calls is a compile error that names its replacement. A mapped symbol
outside that enumeration is not declared at all and fails as an unresolved
reference instead — still a compile error, but you read the replacement out of
§3 rather than off the error. `initialize(_:withLaunchOptions:)` is deliberately
not refused — it is implemented, with `launchOptions` accepted and unused.

[`MIGRATING-FROM-ONESIGNAL.md`](MIGRATING-FROM-ONESIGNAL.md) tables every
forwarded and every refused symbol.

## Threading

Every observer, listener, completion and hook the SDK calls runs on the main
thread. That covers push subscription and permission observers,
`requestPermission` and `requestProvisionalPermission` completions, `login` and
`logout` completions, `onRegistered`, `onRegistrationFailed`,
`onIdentityVerificationRequired`, Live Activity `enter`, `exit` and
push-to-start completions, the `then` of `receipt`, in-app lifecycle and click
listeners, and held notification clicks replayed to the first click listener.
The compatibility facade forwards to these, so it behaves the same.

These callbacks are always posted to the main queue, even when the SDK is
already on the main thread. A callback never runs inside the call that caused
it, so an observer does not fire before `optOut()` returns. Callbacks arrive in
the order the SDK raised them.

Two kinds stay on the thread that called the SDK:

- Notification click listeners and foreground listeners run inline inside
  `processClick` and `processForeground`, because the foreground decision has to
  be known before the call returns. Call both from your
  `UNUserNotificationCenterDelegate` methods, on the main thread. Debug builds
  assert this.
- `onLog` runs on the thread that wrote the line.

Other notes:

- `OpenPushVoIP` handlers run on the main queue, where PushKit delivers them.
- `OpenPush.Verify` is `async`; it resumes wherever your task runs.
- The `credential` provider and a custom `Transport` are asked for values, not
  told about events. The SDK calls them from whichever thread needs the value,
  so answer without waiting on the main thread.
- Only the call to your code is moved to the main thread. The SDK never
  blocks the main thread on its own network work, and never blocks waiting for
  a callback it posted.

Move heavy work off the main thread inside your callback.

## Concurrency and platform notes

Callbacks and mutable state are synchronized for Swift 6 concurrency. Tag and
alias writes persist immediately, share a cancellable fixed write window, and
flush when the app backgrounds. That background flush, and the Custom Events
request, run under a background task assertion, so iOS does not suspend the
process with the request in flight. A registration refused with `429` is retried
after the server's `Retry-After` (integer seconds only, capped at 30), and every
registration retry delay carries ±25 % jitter so a fleet woken by the same push
does not come back in lockstep. Fields a registration response names in
`not_collected` are logged, so a value that was sent but not stored is visible
rather than silently assumed. Registration retries use separate cancellable
handles. Initializing before the device's first unlock does not
overwrite the persisted session: what could not be read is not written over, and
the restore happens when protected data becomes available, or at the next
foreground if that notification was missed. A login or logout made while the
store was still locked wins: the restore keeps the device's own state and drops
the stored user's identity, tags and aliases rather than merging them onto the
person now holding the install. A
registration response is discarded if the device credential changed since the
request began. UIKit is used only inside the `OpenPush` product, never in
`OpenPushCore` or `OpenPushNSE`, so both stay extension-safe.
`OpenPushCore` touches no system notification API at all; `OpenPushNSE` uses
`UserNotifications` alone, which is what an extension is allowed.

## Not included

Inbox is not in this release because its server capability does not exist yet.
Custom Events are available through `trackEvent`.
