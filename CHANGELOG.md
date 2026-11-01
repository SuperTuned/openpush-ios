# Changelog

All notable changes to `openpush-ios` will be documented in this file.

The project uses [Semantic Versioning](https://semver.org/).

## 1.2.2

First public release.

- Push registration: APNs token forwarding, notification permission (including
  provisional authorization), opt-in and opt-out, and a live push subscription
  accessor with change observers.
- Identity and targeting: external ID login with optional identity
  verification, tags, aliases, and custom events for journeys.
- Phone numbers (SMS and WhatsApp) with phone-code verification, and email
  addresses.
- In-app messages: fetch, triggers, presentation, click and lifecycle
  listeners, and persisted redisplay state.
- Notification Service Extension handler: action buttons (each with an
  optional link), rich media attachments, badge increments, and delivery
  receipts, plus a mode that shares an existing extension with another sender.
- Launch URLs open on tap by default, with a code switch and an `Info.plist`
  key to turn that off.
- Live Activities: token observation, push-to-start, and widget click
  tracking, in an extension-safe product.
- VoIP pushes through PushKit in a separate `OpenPushVoIP` product.
- An opt-in compatibility layer for apps migrating from another push SDK, with
  a migration guide and a migrated sample app.
- `openpush-ios-setup`, a command-line tool that adds OpenPush to an existing
  Xcode project and reuses its push setup.
- Observers, listeners and completions run on the main thread, posted after
  the call that caused them. Click and foreground listeners stay on the
  delegate's thread. See Threading in `API.md`.
- Privacy manifests in every product. `OpenPush` declares the data it
  collects, all linked to the user and used for app functionality only: device
  ID, user ID, email address, phone number and product interaction.
  `OpenPushCore` and `OpenPushNSE` declare the App Group reason (`1C8F.1`) for
  the shared `UserDefaults` suite next to `CA92.1`.
- `DeviceCredentialStore` keeps the device credential with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and updates it in place.
  A credential an earlier build stored is still read, and is moved to the new
  accessibility class on first load without changing its value.
- Custom events and Live Activity requests back off on the registration retry
  schedule (jittered, honouring `Retry-After`) and are then held until the next
  event or accepted registration, instead of retrying every 2 or 30 seconds.
  The custom event queue keeps at most 500 events, evicting the oldest; events
  already queued on a device keep their stored format and still send. A Live
  Activity request made before the device has a push token waits for the
  registration rather than polling.

### Deprecated

- `register(token:externalID:)`: call `login(externalId:authHash:)` for the
  identity and `register(token:)` for the token. Existing calls still compile
  and work: a non-empty `externalID` is applied as a login (no auth hash)
  before the token is registered, so it follows the login rules. It no longer
  overrides the identity for a single request, and an identity that is waiting
  for its auth hash is not sent without it.
- Assigning `currentToken`: forward tokens with `register(token:)` or
  `didRegisterForRemoteNotifications(deviceToken:)`. Reading it is unchanged.
  An assigned token is now registered (after `initialize`) instead of only
  being stored; assigning `nil` still clears the stored token.
