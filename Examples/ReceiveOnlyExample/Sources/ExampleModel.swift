import ActivityKit
import Foundation
import OpenPush
import OpenPushCore
import OpenPushLiveActivities
import Security
import UserNotifications

enum NotificationExample: String, CaseIterable, Identifiable {
    case simple
    case image
    case button
    case custom
    case sound

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .simple: "Baseline title and body payload"
        case .image: "Rich notification attachment"
        case .button: "Open and Save notification actions"
        case .custom: "Additional app-defined payload data"
        case .sound: "Default iOS notification sound"
        }
    }

    var symbol: String {
        switch self {
        case .simple: "bell"
        case .image: "photo"
        case .button: "rectangle.and.hand.point.up.left"
        case .custom: "curlybraces"
        case .sound: "speaker.wave.2"
        }
    }
}

struct CustomNotificationDraft: Equatable {
    static let titleLimit = 80
    static let descriptionLimit = 240
    static let dataKeyLimit = 50
    static let dataValueLimit = 120

    static let example = CustomNotificationDraft(
        title: "OpenPush · Custom",
        description: "Open this notification to inspect app-defined payload data.",
        dataKey: "screen",
        dataValue: "order_detail"
    )

    let title: String
    let description: String
    let dataKey: String
    let dataValue: String

    var normalized: CustomNotificationDraft {
        CustomNotificationDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            dataKey: dataKey.trimmingCharacters(in: .whitespacesAndNewlines),
            dataValue: dataValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var isValid: Bool {
        let value = normalized
        return !value.title.isEmpty
            && !value.description.isEmpty
            && !value.dataKey.isEmpty
            && !value.dataValue.isEmpty
    }
}

/// What the sample decides when a notification arrives while it is on screen.
///
/// Two readers need it before the main actor could answer: the foreground
/// listener, which runs synchronously inside `processForeground` and whose
/// `preventDefault()` has to be visible by the time that call returns, and the
/// app delegate's `willPresent`, which has to pick the synchronous or the
/// asynchronous spelling before either has run. So the model mirrors its two
/// toggles into this lock-guarded box, and both read it inline.
final class ForegroundPresentationChoice: @unchecked Sendable {
    struct Value: Sendable {
        var prevent = false
        var displayAfterDelay = false
    }

    /// How long the sample waits before calling `display()`. Short enough to
    /// watch, long enough to see the notification was genuinely held back.
    static let displayDelay: TimeInterval = 2

    static let shared = ForegroundPresentationChoice()

    private let lock = NSLock()
    private var value = Value()
    private var outcomeSink: (@Sendable (UNNotificationPresentationOptions) -> Void)?

    var current: Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(prevent: Bool, displayAfterDelay: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = Value(prevent: prevent, displayAfterDelay: displayAfterDelay)
    }

    /// Where the asynchronous spelling's answer is reported. Only
    /// `processForeground(_:completion:)` knows whether the deferred `display()`
    /// landed inside the SDK's window or the window closed on it first, so the
    /// log line is written from there — with the options iOS was actually given —
    /// rather than guessed at the moment `display()` is called.
    func onOutcome(_ sink: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        lock.lock(); defer { lock.unlock() }
        outcomeSink = sink
    }

    func reportOutcome(_ options: UNNotificationPresentationOptions) {
        let sink: (@Sendable (UNNotificationPresentationOptions) -> Void)? = {
            lock.lock(); defer { lock.unlock() }
            return outcomeSink
        }()
        sink?(options)
    }
}

/// The three value types `OpenPush.InAppMessages.addTrigger(_:withValue:)`
/// accepts. The lab types every value as text, so the kind says how to read it.
enum TriggerValueKind: String, CaseIterable, Identifiable {
    case string
    case number
    case bool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .string: "String"
        case .number: "Number"
        case .bool: "Bool"
        }
    }

    var prompt: String {
        switch self {
        case .string: "gold"
        case .number: "42"
        case .bool: "true"
        }
    }
}

struct LabEvent: Identifiable, Equatable {
    enum Kind: String {
        case sdk
        case permission
        case subscription
        case foreground
        case click
        case identity
        case data
        case activity
        case inApp
        case error

        var symbol: String {
            switch self {
            case .sdk: "terminal"
            case .permission: "bell.badge"
            case .subscription: "antenna.radiowaves.left.and.right"
            case .foreground: "rectangle.inset.filled.and.person.filled"
            case .click: "hand.tap"
            case .identity: "person.crop.circle.badge.checkmark"
            case .data: "tag"
            case .activity: "livephoto"
            case .inApp: "rectangle.on.rectangle.angled"
            case .error: "exclamationmark.triangle"
            }
        }
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
}

@MainActor
final class ExampleModel: ObservableObject {
    @Published private(set) var mode: RuntimeMode
    @Published private(set) var permissionGranted = false
    @Published private(set) var subscriptionID: String?
    @Published private(set) var token: String?
    @Published private(set) var pushEnabled = false
    @Published private(set) var subscriptionStatus: Int?
    @Published private(set) var externalID: String?
    @Published private(set) var tags: [String: String] = [:]
    @Published private(set) var aliases: [String: String] = [:]
    @Published private(set) var events: [LabEvent] = []
    @Published private(set) var liveActivityID: String?
    @Published private(set) var liveActivityStage = "Preparing"
    @Published private(set) var liveActivityETA = 18
    @Published private(set) var liveActivitiesEnabled: Bool?
    @Published private(set) var frequentLiveActivityUpdatesEnabled: Bool?
    /// The destination a Live Activity tap resolved to, after the SDK recorded
    /// the click. `onOpenURL` is the only thing that writes it.
    @Published private(set) var lastWidgetDeepLink = "No Live Activity tap routed yet"
    /// The two `OpenPushLiveActivitySetupOptions` switches, read when the
    /// default-attributes setup call is made rather than applied live: `setup`
    /// decides what it observes once, at the call.
    @Published var defaultActivityPushToStart = true
    @Published var defaultActivityPushToUpdate = true
    @Published private(set) var defaultActivityStatus = "setupDefault() not called in this session"
    /// The id of the last activity `startDefault` was asked for. The SDK owns
    /// the ActivityKit handle, so this is the sample's only record of it.
    @Published private(set) var defaultActivityID: String?
    /// Whether the shared Keychain holds this install's credential, kept as
    /// state so the Credential panel redraws after a save or a wipe.
    @Published private(set) var deviceCredentialAvailable = ExampleConfiguration.hasDeviceCredential
    @Published private(set) var credentialStatus = "No credential write in this session"
    @Published private(set) var notificationExtensionActions = "No extension run recorded"
    @Published private(set) var notificationExtensionAttachment = "No attachment attempt recorded"
    @Published private(set) var notificationExtensionReceipt = "No receipt attempt recorded"
    /// The unflattened authorization iOS reports, and whether this SDK may still
    /// raise the prompt. Both are snapshots of the SDK's caches, refreshed
    /// wherever `permissionGranted` is.
    @Published private(set) var permissionStatus = OpenPush.Notifications.permissionStatus
    @Published private(set) var canRequestPermission = OpenPush.Notifications.canRequestPermission
    @Published private(set) var lastNotificationReceipt = "No local fixture scheduled"
    /// The `op_message_id` of the last notification this process scheduled, saw
    /// in the foreground, or had clicked. An app-side receipt is keyed on it, so
    /// with none there is nothing to report.
    @Published private(set) var lastMessageID: String?
    /// The last `PushSubscriptionChange`, rendered previous → current. The plain
    /// observer hands over only the new state; this one also carries the one it
    /// replaced, so the workspace can show what actually moved.
    @Published private(set) var lastSubscriptionChange = "No subscription change observed"
    @Published private(set) var consentRequired: Bool
    @Published private(set) var consentGranted: Bool
    @Published private(set) var triggers: [String: String] = [:]
    /// The typed stage of the last lifecycle event, shown as a badge. `nil`
    /// until one arrives — an absent stage is not a stage named "none".
    @Published private(set) var lastInAppStage: OpenPush.InAppMessageLifecycleEvent.Stage?
    @Published private(set) var lastInAppMessage = "No lifecycle event recorded"
    /// How the last message was presented. The lifecycle event carries it, so
    /// the host can tell a banner from a centred message without a fetch.
    @Published private(set) var lastInAppLayout = "No message presented yet"
    @Published private(set) var lastInAppClick = "No in-app click recorded"
    @Published var appearance: AppAppearance
    @Published var preventForegroundPresentation = false {
        didSet { mirrorForegroundPresentationChoice() }
    }
    /// The second half of the suppression story: having prevented the system
    /// banner, present it after all. Only the asynchronous `processForeground`
    /// can honor that, so this also decides which spelling `willPresent` uses.
    @Published var displayAfterDeferral = false {
        didSet { mirrorForegroundPresentationChoice() }
    }
    /// Delivery receipts this install still owes the server, read back from
    /// `OpenPush.pendingReceiptCount`. A number that stays above zero is what a
    /// failing receipt looks like from the outside.
    @Published private(set) var pendingReceipts = 0
    /// Mirrors `OpenPush.InAppMessages.paused`. Writes reach the SDK unless a
    /// snapshot is being installed, where the value is only being read back.
    @Published var inAppPaused = false {
        didSet {
            guard !applyingSnapshot, inAppPaused != oldValue else { return }
            OpenPush.InAppMessages.paused = inAppPaused
            append(
                .inApp,
                title: inAppPaused ? "In-app messages paused" : "In-app messages resumed",
                detail: inAppPaused
                    ? "A message on screen comes down without counting a display and returns to the front of the queue."
                    : "The engine re-evaluates the queue and presents the next eligible message."
            )
        }
    }

    private var permissionObserver: UUID?
    private var subscriptionObserver: UUID?
    private var subscriptionChangeObserver: UUID?
    private var foregroundListener: UUID?
    private var clickListener: UUID?
    private var inAppLifecycleListener: UUID?
    private var inAppClickListener: UUID?
    private var applyingSnapshot = false
    private var activityEnablementTask: Task<Void, Never>?
    private var frequentPushEnablementTask: Task<Void, Never>?
    private var didBecomeReady = false
    private var sdkObserversInstalled = false

    init() {
        mode = ExampleConfiguration.hasLiveCredentials ? .live : .demo
        consentRequired = ExampleConsentGate.isRequired
        consentGranted = ExampleConsentGate.isGranted
        appearance = AppAppearance(
            rawValue: UserDefaults.standard.string(forKey: "example.appearance") ?? "system"
        ) ?? .system
        if mode == .demo {
            installSDKObservers()
            installDemoSnapshot()
        } else if OpenPush.isInitialized {
            installSDKObservers()
            refreshFromSDK()
        } else {
            installWaitingForConsentSnapshot()
        }
        installActivityAuthorizationObservers()
    }

    deinit {
        if let permissionObserver {
            OpenPush.Notifications.removePermissionObserver(permissionObserver)
        }
        if let subscriptionObserver {
            OpenPush.PushSubscription.removeObserver(subscriptionObserver)
        }
        // The two observer lists are separate: an id from one means nothing to
        // the other, so each is removed through the call that issued it.
        if let subscriptionChangeObserver {
            OpenPush.PushSubscription.removeChangeObserver(subscriptionChangeObserver)
        }
        if let foregroundListener {
            OpenPush.Notifications.removeForegroundLifecycleListener(foregroundListener)
        }
        if let clickListener {
            OpenPush.Notifications.removeClickListener(clickListener)
        }
        if let inAppLifecycleListener {
            OpenPush.InAppMessages.removeLifecycleListener(inAppLifecycleListener)
        }
        if let inAppClickListener {
            OpenPush.InAppMessages.removeClickListener(inAppClickListener)
        }
        activityEnablementTask?.cancel()
        frequentPushEnablementTask?.cancel()
    }

    var liveAvailable: Bool { ExampleConfiguration.hasLiveCredentials }
    var shortToken: String { token.map(OpenPush.shortToken) ?? "Not issued" }
    var shortSubscriptionID: String { subscriptionID ?? "Pending registration" }
    var identityLabel: String { externalID ?? "Anonymous" }
    var permissionLabel: String { permissionGranted ? "Authorized" : "Not authorized" }
    /// `permissionStatus` keeps what `permission` flattens away: provisional and
    /// ephemeral both deliver, so both read as authorized in `permissionLabel`.
    var permissionStatusLabel: String {
        switch permissionStatus {
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .granted: "Granted"
        case .provisional: "Provisional · quiet delivery"
        case .ephemeral: "Ephemeral · App Clip"
        }
    }
    /// It answers for this SDK, not for iOS: a provisional install reads `No`
    /// even though iOS would still show the standard prompt.
    var canRequestPermissionLabel: String { canRequestPermission ? "Yes" : "No" }
    var subscriptionLabel: String { pushEnabled ? "Subscribed" : "Not subscribed" }
    var liveActivitiesAuthorizationLabel: String {
        authorizationLabel(liveActivitiesEnabled, unavailable: "Requires iOS 16.1")
    }
    var frequentLiveActivityUpdatesLabel: String {
        authorizationLabel(
            frequentLiveActivityUpdatesEnabled,
            unavailable: "Requires iOS 16.2"
        )
    }
    /// `pushSubscription.snapshot()` read at this moment: one equatable value of
    /// all four fields. The rows above are the *observed* state — what the
    /// observer last handed over, and in Demo mode a synthetic stand-in — so a
    /// snapshot taken with no SDK running honestly reports empty.
    var subscriptionSnapshotLabel: String {
        Self.describe(OpenPush.User.pushSubscription.snapshot())
    }
    /// `OpenPush.currentToken`, the process-wide accessor an app-side receipt
    /// needs before it will post anything.
    var currentTokenLabel: String {
        guard let token = OpenPush.currentToken else {
            return mode == .demo ? "Not issued · the demo token is synthetic" : "Not issued"
        }
        return OpenPush.shortToken(token)
    }
    var canPostReceipt: Bool { lastMessageID != nil }
    var liveActionsBlocked: Bool { mode == .live && !OpenPush.isInitialized }
    var consentStatusLabel: String {
        guard consentRequired else { return "Not required" }
        return consentGranted ? "Granted" : "Not granted"
    }
    /// The `X-OP-SDK-Wrapper` value this process would send. A wrapper SDK sets
    /// `OpenPush.wrapper` before `initialize`; a host using OpenPush directly, as
    /// this sample does, never sends it.
    var wrapperHeaderLabel: String {
        guard let wrapper = OpenPush.wrapper else { return "none" }
        return "\(wrapper.name)/\(wrapper.version)"
    }
    var sdkStartupLabel: String {
        guard ExampleConfiguration.hasLiveCredentials else { return "Demo · no network" }
        if OpenPush.isInitialized {
            return consentRequired && !consentGranted ? "Active until relaunch" : "Initialized"
        }
        return consentRequired && !consentGranted ? "Waiting for consent" : "Not initialized"
    }
    var consentChangeNeedsRelaunch: Bool {
        ExampleConfiguration.hasLiveCredentials
            && OpenPush.isInitialized
            && consentRequired
            && !consentGranted
    }

    func appDidBecomeReady() {
        guard !didBecomeReady else { return }
        didBecomeReady = true
        if mode == .live, OpenPush.isInitialized {
            installSDKObservers()
            refreshFromSDK()
        }
        let waitingForConsent = mode == .live && !OpenPush.isInitialized
        append(
            .sdk,
            title: waitingForConsent
                ? "Live workspace waiting for consent"
                : (mode == .demo ? "Demo workspace ready" : "Live workspace ready"),
            detail: waitingForConsent
                ? "The host app has not called OpenPush.initialize; no OpenPush network work has started."
                : (mode == .demo
                    ? "Synthetic subscription data is active; native notifications and Live Activities remain real."
                    : "SDK observers are armed and connected to the configured OpenPush app.")
        )
        refreshPermissionSnapshot()
        refreshNotificationExtensionTelemetry()
        refreshDeviceCredential()
    }

    func setMode(_ requestedMode: RuntimeMode) {
        guard requestedMode != mode else { return }
        guard requestedMode != .live || ExampleConfiguration.hasLiveCredentials else {
            append(
                .error,
                title: "Live mode needs credentials",
                detail: "Set OpenPushAppID and OpenPushSDKKey in Info.plist, then relaunch."
            )
            return
        }
        mode = requestedMode
        if requestedMode == .demo {
            installSDKObservers()
            installDemoSnapshot()
        } else if OpenPush.isInitialized {
            installSDKObservers()
            refreshFromSDK()
        } else {
            installWaitingForConsentSnapshot()
        }
        append(
            .sdk,
            title: "Switched to \(requestedMode.label) mode",
            detail: requestedMode == .demo
                ? "SDK writes are simulated; local iOS surfaces still run on the device."
                : (OpenPush.isInitialized
                    ? "Actions now call the configured OpenPush SDK."
                    : "Live actions are paused until host consent starts the SDK.")
        )
    }

    func setConsentRequired(_ required: Bool) {
        guard required != consentRequired else { return }
        ExampleConsentGate.setRequired(required)
        consentRequired = required
        consentGranted = ExampleConsentGate.isGranted

        if required {
            append(
                .sdk,
                title: "Host consent gate enabled",
                detail: OpenPush.isInitialized
                    ? "This SDK session is already active. Relaunch to test startup waiting for consent."
                    : "OpenPush initialization will wait until consent is granted."
            )
        } else {
            startSDKAfterConsentChange(
                eventTitle: "Host consent gate disabled",
                eventDetail: "Consent is no longer required before SDK initialization."
            )
        }
    }

    func grantConsent() {
        guard consentRequired, !consentGranted else { return }
        ExampleConsentGate.setGranted(true)
        consentGranted = true
        startSDKAfterConsentChange(
            eventTitle: "Host consent granted",
            eventDetail: mode == .live
                ? "The app may now initialize OpenPush and begin live SDK work."
                : "The decision is stored locally; Demo mode still performs no OpenPush network work."
        )
    }

    func resetSavedConsent() {
        guard consentRequired, consentGranted else { return }
        ExampleConsentGate.setGranted(false)
        consentGranted = false
        append(
            .sdk,
            title: "Saved consent reset",
            detail: OpenPush.isInitialized
                ? "OpenPush has no runtime shutdown API. This session remains active; relaunch to restore the startup gate."
                : "OpenPush initialization is waiting for a new host consent decision."
        )
    }

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: "example.appearance")
    }

    func requestPermission() {
        if mode == .demo {
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            ) { [weak self] granted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionGranted = granted
                    self.refreshPermissionSnapshot()
                    if granted {
                        self.pushEnabled = true
                        self.subscriptionStatus = 7
                    }
                    self.append(
                        error == nil ? .permission : .error,
                        title: granted ? "Notification permission granted" : "Permission not granted",
                        detail: error?.localizedDescription
                            ?? "The Simulator authorization response was captured without contacting OpenPush."
                    )
                }
            }
            return
        }

        guard ensureLiveSDKReady(for: "request notification permission") else { return }
        OpenPush.Notifications.requestPermission(
            fallbackToSettings: true,
            completion: { [weak self] granted in
            Task { @MainActor in
                self?.permissionGranted = granted
                self?.refreshFromSDK()
            }
        })
    }

    /// Provisional authorization shows no prompt at all: notifications begin
    /// arriving quietly, in the notification centre only, and the user promotes
    /// or silences them from the notification itself.
    func requestProvisionalPermission() {
        guard mode != .demo else {
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.provisional, .alert, .badge, .sound]
            ) { [weak self] granted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionGranted = granted
                    self.append(
                        error == nil ? .permission : .error,
                        title: granted
                            ? "Provisional authorization granted"
                            : "Provisional authorization not granted",
                        detail: error?.localizedDescription
                            ?? "No prompt was shown; delivery is quiet until the user promotes it."
                    )
                }
            }
            return
        }

        guard ensureLiveSDKReady(for: "request provisional authorization") else { return }
        OpenPush.Notifications.requestProvisionalPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.permissionGranted = granted
                self.refreshFromSDK()
                self.append(
                    .permission,
                    title: granted
                        ? "Provisional authorization granted"
                        : "Provisional authorization not granted",
                    detail: "No prompt is shown; iOS delivers quietly to the notification centre."
                )
            }
        }
    }

    func setPushEnabled(_ enabled: Bool) {
        if mode == .demo {
            if enabled && !permissionGranted {
                requestPermission()
                return
            }
            pushEnabled = enabled
            subscriptionStatus = enabled ? 7 : -2
            append(
                .subscription,
                title: enabled ? "Push subscription opted in" : "Push subscription opted out",
                detail: enabled
                    ? "Demo subscription is eligible for delivery."
                    : "The token stays registered, but the subscription is excluded from sends."
            )
        } else {
            guard ensureLiveSDKReady(for: enabled ? "opt in" : "opt out") else { return }
            enabled ? OpenPush.PushSubscription.optIn() : OpenPush.PushSubscription.optOut()
            refreshFromSDK()
        }
    }

    /// The parsed notification, not the deprecated string-coerced `payload`:
    /// `launchURL` is the composer's `deep_link` (the SDK opens it on a tap
    /// unless `OpenPush.Notifications.openLaunchURLs` is off), and
    /// `additionalData` is the composer's own custom data
    /// with its nesting intact.
    private static func describe(_ notification: OpenPush.Notification) -> String {
        let title = notification.title ?? "—"
        let link = notification.launchURL?.absoluteString ?? "no deep_link"
        let keys = notification.additionalData.keys.sorted()
        let data = keys.isEmpty ? "no additionalData" : keys.joined(separator: ", ")
        return "message = \(notification.messageId ?? "—") · title = \(title)"
            + " · launchURL = \(link) · additionalData = \(data)"
    }

    /// The two fields a change is usually about, short enough for a row.
    private static func summarize(optedIn: Bool, status: Int?) -> String {
        "optedIn = \(optedIn) · status = \(status.map(String.init) ?? "—")"
    }

    private static func summarize(_ state: OpenPush.PushSubscriptionState?) -> String {
        guard let state else { return "none" }
        return summarize(optedIn: state.optedIn, status: state.status)
    }

    /// What the listener did with the presentation, in the event stream's voice.
    private static func describePresentationChoice(
        _ choice: ForegroundPresentationChoice.Value
    ) -> String {
        guard choice.prevent else { return "presented by iOS" }
        guard choice.displayAfterDelay else { return "preventDefault() — suppressed" }
        return "preventDefault(), then display() in \(Int(ForegroundPresentationChoice.displayDelay))s"
    }

    /// The answer iOS was given, spelled out — the options are a bit set, and
    /// an empty one is the whole point of a suppression.
    private static func describe(_ options: UNNotificationPresentationOptions) -> String {
        var parts: [String] = []
        if options.contains(.banner) { parts.append("banner") }
        if options.contains(.list) { parts.append("list") }
        if options.contains(.sound) { parts.append("sound") }
        if options.contains(.badge) { parts.append("badge") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " + ")
    }

    /// The whole state, for the event stream and the snapshot row.
    private static func describe(_ state: OpenPush.PushSubscriptionState) -> String {
        "id = \(state.id ?? "—") · token = \(state.token.map(OpenPush.shortToken) ?? "none")"
            + " · " + summarize(optedIn: state.optedIn, status: state.status)
    }

    /// Reads the SDK's permission caches back. They are caches, not live reads:
    /// OpenPush refreshes them at `attach`, `initialize`, a permission request,
    /// and every foreground.
    func refreshPermissionSnapshot() {
        permissionStatus = OpenPush.Notifications.permissionStatus
        canRequestPermission = OpenPush.Notifications.canRequestPermission
        refreshPendingReceipts()
    }

    /// The queue depth, read through to what the last launch left behind. It is
    /// `0` while the SDK is unconfigured, which is Demo mode's honest answer: the
    /// sample posts no receipts there.
    func refreshPendingReceipts() {
        pendingReceipts = OpenPush.pendingReceiptCount
    }

    /// Keeps the lock-guarded copy the notification path reads in step with the
    /// toggles. "Display after 2 s" means nothing without a suppression to undo,
    /// so it is reported as off while the suppression is.
    private func mirrorForegroundPresentationChoice() {
        ForegroundPresentationChoice.shared.set(
            prevent: preventForegroundPresentation,
            displayAfterDelay: preventForegroundPresentation && displayAfterDeferral)
    }

    func refreshFromSDK() {
        guard mode == .live, OpenPush.isInitialized else { return }
        permissionGranted = OpenPush.Notifications.permission
        refreshPermissionSnapshot()
        let subscription = OpenPush.User.pushSubscription
        subscriptionID = subscription.id
        token = subscription.token
        pushEnabled = subscription.optedIn
        subscriptionStatus = subscription.status
        externalID = OpenPush.User.externalId
        // `getTags()` already excludes a staged deletion: the key rides the next
        // registration body as an empty value, but it is not a tag any more.
        tags = OpenPush.User.getTags()
        readInAppPausedFromSDK()
        refreshNotificationExtensionTelemetry()
    }

    private func installActivityAuthorizationObservers() {
        guard #available(iOS 16.1, *) else { return }
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        activityEnablementTask = Task { [weak self] in
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard !Task.isCancelled else { return }
                self?.liveActivitiesEnabled = enabled
            }
        }

        guard #available(iOS 16.2, *) else { return }
        frequentLiveActivityUpdatesEnabled = ActivityAuthorizationInfo().frequentPushesEnabled
        frequentPushEnablementTask = Task { [weak self] in
            for await enabled in ActivityAuthorizationInfo().frequentPushEnablementUpdates {
                guard !Task.isCancelled else { return }
                self?.frequentLiveActivityUpdatesEnabled = enabled
            }
        }
    }

    private func authorizationLabel(_ value: Bool?, unavailable: String) -> String {
        guard let value else { return unavailable }
        return value ? "Allowed" : "Disabled"
    }

    func login(externalID value: String, authHash: String = "") {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = authHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            append(.error, title: "External ID is required", detail: "Enter the ID your backend uses for this user.")
            return
        }
        if mode == .demo {
            externalID = value
            append(.identity, title: "User identified", detail: "Demo install is now linked to \(value).")
            if !hash.isEmpty {
                append(
                    .identity,
                    title: "Auth hash supplied (demo: not sent)",
                    detail: "Your server computes this hash; demo mode keeps it on the device."
                )
            }
            return
        }
        guard ensureLiveSDKReady(for: "log in") else { return }
        OpenPush.login(externalId: value, authHash: hash.isEmpty ? nil : hash) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.externalID = value
                    self.append(.identity, title: "User identified", detail: "OpenPush accepted \(value).")
                case .identityRejected(let note):
                    self.externalID = nil
                    self.append(.error, title: "Identity rejected", detail: note)
                case .failed(let message):
                    self.append(.error, title: "Login failed", detail: message)
                }
            }
        }
    }

    func logout() {
        if mode == .demo {
            externalID = nil
            append(.identity, title: "Install is anonymous", detail: "The demo identity was detached.")
            return
        }
        guard ensureLiveSDKReady(for: "log out") else { return }
        OpenPush.logout { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.externalID = nil
                    self.append(.identity, title: "Install is anonymous", detail: "OpenPush detached the external ID.")
                case .identityRejected(let note), .failed(let note):
                    self.append(.error, title: "Logout not applied", detail: note)
                }
            }
        }
    }

    func addTag(key: String, value: String) {
        addTags([(key: key, value: value)])
    }

    /// The plural write, which is the one the SDK is built around: several pairs
    /// merged in a single call, so the coalesced registration carries them all in
    /// one body instead of one body per pair.
    func addTags(_ pairs: [(key: String, value: String)]) {
        let accepted = cleanedPairs(pairs)
        guard !accepted.isEmpty else { return }
        let previous = tags
        tags.merge(accepted) { _, new in new }
        if mode == .live {
            guard ensureLiveSDKReady(for: "add tags") else {
                tags = previous
                return
            }
            OpenPush.User.addTags(accepted)
        }
        append(.data, title: accepted.count == 1 ? "Tag updated" : "Tags updated",
               detail: describePairs(accepted))
    }

    func removeTag(_ key: String) {
        removeTags([key])
    }

    /// Several deletions in one coalesced write. Each key stays in the body with
    /// an empty value — the server's delete signal — and `getTags()` stops
    /// reporting it straight away.
    func removeTags(_ keys: [String]) {
        let keys = keys.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return }
        if mode == .live, !ensureLiveSDKReady(for: "remove tags") { return }
        for key in keys { tags.removeValue(forKey: key) }
        if mode == .live { OpenPush.User.removeTags(keys) }
        append(.data, title: keys.count == 1 ? "Tag removed" : "Tags removed",
               detail: keys.sorted().joined(separator: ", "))
    }

    func addAlias(label: String, id: String) {
        addAliases([(key: label, value: id)])
    }

    /// Aliases take the same plural shape as tags, and share the same 300 ms
    /// write window, so a tag write and an alias write made together travel in
    /// one registration.
    func addAliases(_ pairs: [(key: String, value: String)]) {
        let accepted = cleanedPairs(pairs)
        guard !accepted.isEmpty else { return }
        let previous = aliases
        aliases.merge(accepted) { _, new in new }
        if mode == .live {
            guard ensureLiveSDKReady(for: "add aliases") else {
                aliases = previous
                return
            }
            OpenPush.User.addAliases(accepted)
        }
        append(.data, title: accepted.count == 1 ? "Alias updated" : "Aliases updated",
               detail: describePairs(accepted))
    }

    func removeAlias(_ label: String) {
        removeAliases([label])
    }

    func removeAliases(_ labels: [String]) {
        let labels = labels.filter { !$0.isEmpty }
        guard !labels.isEmpty else { return }
        if mode == .live, !ensureLiveSDKReady(for: "remove aliases") { return }
        for label in labels { aliases.removeValue(forKey: label) }
        if mode == .live { OpenPush.User.removeAliases(labels) }
        append(.data, title: labels.count == 1 ? "Alias removed" : "Aliases removed",
               detail: labels.sorted().joined(separator: ", "))
    }

    /// `receipt(_:messageID:)` is the app's own half of delivery reporting: the
    /// service extension posts for a message it handled, and the app posts for
    /// one it saw itself. It needs an initialized SDK and a token — with either
    /// missing it returns without a request, so this says so rather than
    /// claiming a send that never happened.
    func postReceipt(_ type: String) {
        guard let messageID = lastMessageID else {
            append(
                .error,
                title: "No message to report",
                detail: "Schedule a fixture or receive a push first: a receipt is keyed on op_message_id."
            )
            return
        }
        guard OpenPush.isInitialized, OpenPush.currentToken != nil else {
            append(
                .sdk,
                title: "\(type) receipt not posted",
                detail: "OpenPush.receipt(\"\(type)\", messageID: \"\(messageID)\") needs an "
                    + "initialized SDK and an APNs token; with either missing it returns without a request."
            )
            return
        }
        append(.sdk, title: "\(type) receipt posted", detail: "message = \(messageID)")
        OpenPush.receipt(type, messageID: messageID) { [weak self] in
            Task { @MainActor in
                self?.append(
                    .sdk,
                    title: "\(type) receipt settled",
                    detail: "message = \(messageID) · an accepted receipt is never sent again, "
                        + "even after a relaunch; a failed one stays queued and retries."
                )
                self?.refreshPendingReceipts()
            }
        }
        refreshPendingReceipts()
    }

    /// Triggers never leave the process: the engine holds them in memory and
    /// re-evaluates the queue on every change, so these calls are as real in
    /// Demo mode as in Live mode — there is simply nothing queued to match.
    func addTrigger(key: String, value: String, kind: TriggerValueKind) {
        guard let pair = cleanedPair(key: key, value: value) else { return }
        let resolved: Any
        let display: String
        switch kind {
        case .string:
            resolved = pair.value
            display = pair.value
        case .number:
            guard let number = Double(pair.value) else {
                append(
                    .error,
                    title: "Number trigger needs a numeric value",
                    detail: "\(pair.value) is not a number. Use the String kind for text."
                )
                return
            }
            resolved = number
            display = pair.value
        case .bool:
            guard let flag = Self.boolValue(pair.value) else {
                append(
                    .error,
                    title: "Bool trigger needs true or false",
                    detail: "\(pair.value) is not a boolean. Accepted values: true, false, yes, no, 1, 0."
                )
                return
            }
            resolved = flag
            display = flag ? "true" : "false"
        }
        OpenPush.InAppMessages.addTrigger(pair.key, withValue: resolved)
        triggers[pair.key] = display
        append(.inApp, title: "Trigger set", detail: "\(pair.key) = \(display) · \(kind.title)")
    }

    func removeTrigger(_ key: String) {
        triggers.removeValue(forKey: key)
        OpenPush.InAppMessages.removeTrigger(key)
        append(.inApp, title: "Trigger removed", detail: key)
    }

    func clearTriggers() {
        triggers.removeAll()
        OpenPush.InAppMessages.clearTriggers()
        append(
            .inApp,
            title: "Triggers cleared",
            detail: "The engine holds no trigger values for this install."
        )
    }

    /// The four lifecycle stages a real presentation emits, and the click event
    /// one of its buttons would report, without a server or a document. Demo
    /// mode has no queue, so this is the only way to see the shape of what the
    /// listeners receive.
    func previewInAppLifecycle() {
        let messageID = "demo-iam-a41f"
        let layout = "center"
        let stages: [OpenPush.InAppMessageLifecycleEvent.Stage] = [
            .willDisplay, .didDisplay, .willDismiss, .didDismiss
        ]
        for stage in stages {
            append(
                .inApp,
                title: "In-app \(stage.rawValue)",
                detail: "Synthetic preview · message \(messageID) · layout = \(layout)"
            )
        }
        lastInAppStage = stages[stages.count - 1]
        lastInAppMessage = messageID
        lastInAppLayout = layout
        // The click a real primary button would report. `firstClick` is true
        // only once per message however often it is shown, so a preview that
        // never says so would leave the interesting half of the event unseen.
        lastInAppClick = "cta_primary · https://example.com/offer · closing = true · first = true"
        append(
            .inApp,
            title: "In-app click",
            detail: "message = \(messageID) · action = cta_primary"
                + " · url = https://example.com/offer · target = browser"
                + " · closing = true · first = true"
        )
    }

    private static func boolValue(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: nil
        }
    }

    func scheduleLocalNotification() {
        scheduleNotification(.simple)
    }

    func scheduleNotification(
        _ example: NotificationExample,
        customDraft: CustomNotificationDraft? = nil
    ) {
        let custom = (customDraft ?? .example).normalized
        if example == .custom, !custom.isValid {
            append(
                .error,
                title: "Custom notification is incomplete",
                detail: "Add a title, description, data key, and data value before scheduling."
            )
            return
        }
        let content = UNMutableNotificationContent()
        content.title = example == .custom ? custom.title : "OpenPush · \(example.title)"
        content.body = example == .custom ? custom.description : notificationBody(for: example)
        let messageID = "local-\(Int(Date().timeIntervalSince1970))"
        content.userInfo = [
            "op_message_id": messageID,
            "source": "feature-lab",
            "example": example.rawValue,
            // UTM tags arrive from the server; hosts use this URL as received.
            "deep_link": example == .custom
                ? "https://openpush.ai/?utm_source=openpush&utm_medium=push&utm_campaign=Feature+Lab#overview"
                : "openpush://feature-lab/\(example.rawValue)"
        ]

        switch example {
        case .simple:
            break
        case .image:
            do {
                content.attachments = [try makeImageAttachment()]
            } catch {
                append(.error, title: "Image fixture unavailable", detail: error.localizedDescription)
                return
            }
        case .button:
            content.categoryIdentifier = "openpush_example_actions"
            registerNotificationActions()
        case .custom:
            content.userInfo["openpush_custom"] = [
                custom.dataKey: custom.dataValue
            ]
        case .sound:
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.append(.error, title: "Local notification failed", detail: error.localizedDescription)
                } else {
                    self.lastNotificationReceipt = "\(example.title) scheduled"
                    // The fixture carries an `op_message_id`, so the app-side
                    // receipt menu has something to report even before a real
                    // push arrives.
                    self.lastMessageID = messageID
                    self.append(
                        .sdk,
                        title: "\(example.title) notification scheduled",
                        detail: "Keep the app open for a foreground event, or leave it and interact with the notification for a click event."
                    )
                }
            }
        }
    }

    private func notificationBody(for example: NotificationExample) -> String {
        switch example {
        case .simple:
            "A baseline notification for foreground and click listener testing."
        case .image:
            "Expand this notification to inspect the bundled OpenPush image attachment."
        case .button:
            "Use Open or Save to verify that action identifiers reach the click listener."
        case .custom:
            "The payload includes screen, order_id, and campaign fields for app routing."
        case .sound:
            "This fixture requests the default iOS notification sound."
        }
    }

    private func registerNotificationActions() {
        let category = UNNotificationCategory(
            identifier: "openpush_example_actions",
            actions: [
                UNNotificationAction(identifier: "open", title: "Open", options: [.foreground]),
                UNNotificationAction(identifier: "save", title: "Save", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { categories in
            var updated = categories.filter { $0.identifier != category.identifier }
            updated.insert(category)
            center.setNotificationCategories(updated)
        }
    }

    private func makeImageAttachment() throws -> UNNotificationAttachment {
        guard let url = Bundle.main.url(
            forResource: "feature-announcement",
            withExtension: "jpg"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try UNNotificationAttachment(identifier: "feature-announcement", url: url)
    }

    func previewListenerEvent(_ kind: LabEvent.Kind) {
        switch kind {
        case .foreground:
            append(.foreground, title: "Foreground listener fired", detail: "Synthetic preview · message local-preview")
        case .click:
            append(.click, title: "Click listener fired", detail: "Synthetic preview · default action")
        case .permission:
            append(.permission, title: "Permission observer fired", detail: "Synthetic preview · authorized = \(permissionGranted)")
        case .subscription:
            append(.subscription, title: "Subscription observer fired", detail: "Synthetic preview · optedIn = \(pushEnabled)")
        default:
            break
        }
    }

    /// The change observer's shape, without a registration. A real change would
    /// arrive with the state it replaced attached; this writes the same
    /// previous → current pair so the difference from the plain observer is
    /// visible in Demo mode too.
    func previewSubscriptionChange() {
        let flipped = !pushEnabled
        recordSubscriptionChange(
            previous: Self.summarize(optedIn: pushEnabled, status: subscriptionStatus),
            current: Self.summarize(optedIn: flipped, status: flipped ? 7 : -2),
            detail: "Synthetic preview · the plain observer would report only the right-hand side.",
            synthetic: true
        )
    }

    private func recordSubscriptionChange(
        previous: String,
        current: String,
        detail: String,
        synthetic: Bool
    ) {
        lastSubscriptionChange = "\(previous) → \(current)"
        append(
            .subscription,
            title: synthetic
                ? "Subscription change observer fired (preview)"
                : "Subscription change observer fired",
            detail: "\(lastSubscriptionChange) · \(detail)"
        )
    }

    /// `OpenPush.trackEvent(_:properties:)` is the Journey entry/wait/exit
    /// signal, and it is the one write on this workspace that leaves nothing
    /// visible on the device — the batch is persisted and flushed in the
    /// background. The stream row is what makes the call observable here.
    func trackCustomEvent(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            append(.error, title: "Event name is required", detail: "Name the event your Journey listens for.")
            return
        }
        if mode == .live {
            guard ensureLiveSDKReady(for: "track an event") else { return }
            OpenPush.trackEvent(name, properties: ["source": "feature-lab"])
        }
        append(
            .sdk,
            title: "Custom event tracked",
            detail: mode == .live
                ? "\(name) · queued for the next custom-event batch"
                : "\(name) · demo mode records the call without sending it"
        )
    }

    func clearEvents() {
        events.removeAll()
    }

    func refreshNotificationExtensionTelemetry() {
        guard let defaults = UserDefaults(suiteName: ExampleConfiguration.appGroup) else { return }
        notificationExtensionActions = defaults.string(forKey: "openpush.example.nse.actions")
            ?? "No extension run recorded"
        notificationExtensionAttachment = defaults.string(forKey: "openpush.example.nse.attachment")
            ?? "No attachment attempt recorded"
        notificationExtensionReceipt = defaults.string(forKey: "openpush.example.nse.receipt")
            ?? "No receipt attempt recorded"
    }

    func startLocalActivity(orderNumber: String) {
        guard #available(iOS 16.1, *) else {
            append(.error, title: "Live Activities unavailable", detail: "This feature requires iOS 16.1 or newer.")
            return
        }
        let order = orderNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !order.isEmpty else {
            append(.error, title: "Order number is required", detail: "Use a stable identifier for the activity attributes.")
            return
        }
        do {
            let activity = try Activity<ExampleDeliveryAttributes>.request(
                attributes: ExampleDeliveryAttributes(orderNumber: order),
                contentState: .init(stage: "Preparing", etaMinutes: liveActivityETA),
                pushType: .token
            )
            liveActivityID = activity.id
            liveActivityStage = "Preparing"
            append(.activity, title: "Live Activity started", detail: "ActivityKit ID \(activity.id)")
        } catch {
            append(.error, title: "Live Activity could not start", detail: error.localizedDescription)
        }
    }

    func updateLocalActivity(stage: String, eta: Int) {
        guard #available(iOS 16.1, *),
              let activity = currentActivity() else {
            append(.error, title: "No running activity", detail: "Start a Live Activity before sending an update.")
            return
        }
        let cleanStage = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        liveActivityStage = cleanStage.isEmpty ? "On the way" : cleanStage
        liveActivityETA = max(0, eta)
        let state = ExampleDeliveryAttributes.ContentState(
            stage: liveActivityStage,
            etaMinutes: liveActivityETA
        )
        Task {
            await activity.update(using: state)
            append(.activity, title: "Live Activity updated", detail: "\(state.stage) · \(state.etaMinutes) min")
        }
    }

    func endLocalActivity() {
        guard #available(iOS 16.1, *),
              let activity = currentActivity() else {
            append(.error, title: "No running activity", detail: "There is no local ActivityKit session to end.")
            return
        }
        let state = ExampleDeliveryAttributes.ContentState(stage: "Delivered", etaMinutes: 0)
        Task {
            await activity.end(using: state, dismissalPolicy: .immediate)
            liveActivityID = nil
            liveActivityStage = "Delivered"
            liveActivityETA = 0
            append(.activity, title: "Live Activity ended", detail: "The Lock Screen and Dynamic Island presentation was dismissed.")
        }
    }

    func forwardActivityToken(activityID: String, activityType: String, token: String) {
        let values = [activityID, activityType, token].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            append(.error, title: "Three values are required", detail: "Activity ID, type, and update token must all be present.")
            return
        }
        if mode == .demo {
            append(.activity, title: "Update token forwarded", detail: "Simulated · \(values[1]) / \(values[0])")
            return
        }
        guard ensureLiveSDKReady(for: "forward an activity token") else { return }
        OpenPush.LiveActivities.enter(
            values[0],
            withToken: values[2],
            activityType: values[1]
        ) { [weak self] succeeded in
            Task { @MainActor in
                self?.append(
                    succeeded ? .activity : .error,
                    title: succeeded ? "Update token forwarded" : "Token forwarding failed",
                    detail: values[0]
                )
            }
        }
    }

    func forwardPushToStartToken(activityType: String, token: String) {
        let type = activityType.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, !token.isEmpty else {
            append(.error, title: "Type and token are required", detail: "Push-to-start routing needs both values.")
            return
        }
        if mode == .demo {
            append(.activity, title: "Push-to-start token forwarded", detail: "Simulated · \(type)")
            return
        }
        guard ensureLiveSDKReady(for: "forward a push-to-start token") else { return }
        OpenPush.LiveActivities.setPushToStartToken(activityType: type, token: token) { [weak self] succeeded in
            Task { @MainActor in
                self?.append(
                    succeeded ? .activity : .error,
                    title: succeeded ? "Push-to-start token forwarded" : "Token forwarding failed",
                    detail: type
                )
            }
        }
    }

    func exitForwardedActivity(_ activityID: String) {
        let id = activityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            append(.error, title: "Activity ID is required", detail: "Enter the server-tracked activity to exit.")
            return
        }
        if mode == .demo {
            append(.activity, title: "Forwarded activity exited", detail: "Simulated · \(id)")
            return
        }
        guard ensureLiveSDKReady(for: "exit a forwarded activity") else { return }
        OpenPush.LiveActivities.exit(id) { [weak self] succeeded in
            Task { @MainActor in
                self?.append(
                    succeeded ? .activity : .error,
                    title: succeeded ? "Forwarded activity exited" : "Activity exit failed",
                    detail: id
                )
            }
        }
    }

    /// The app end of the Live Activity click: `onOpenURL` hands the tracking
    /// URL to `trackClickAndReturnOriginal(_:)`, which posts the click and
    /// returns the destination that was folded into it — `nil` when the widget
    /// carried none. Routing stays the host's decision, so this records the
    /// destination rather than navigating to it.
    func handleWidgetURL(_ url: URL?) {
        guard let url else {
            lastWidgetDeepLink = "Click recorded · no destination in the tracking URL"
            append(
                .activity,
                title: "Live Activity click recorded",
                detail: "The tracking URL carried no destination of its own."
            )
            return
        }
        lastWidgetDeepLink = url.absoluteString
        append(
            .activity,
            title: "Live Activity click routed",
            detail: url.absoluteString
        )
    }

    /// `setupDefault(options:)`: the same automatic token observation
    /// `setup(_:)` installs, for the SDK's own `DefaultLiveActivityAttributes`,
    /// so an app that does not define an attributes type still gets remote
    /// Live Activities. The options decide which of the two token streams is
    /// observed and are read here, at the call.
    func setupDefaultLiveActivities() {
        guard #available(iOS 16.1, *) else {
            append(
                .error,
                title: "Live Activities unavailable",
                detail: "This feature requires iOS 16.1 or newer."
            )
            return
        }
        OpenPush.LiveActivities.setupDefault(
            options: OpenPushLiveActivitySetupOptions(
                enablePushToStart: defaultActivityPushToStart,
                enablePushToUpdate: defaultActivityPushToUpdate
            )
        )
        let summary = "push-to-start \(defaultActivityPushToStart ? "on" : "off")"
            + " · push-to-update \(defaultActivityPushToUpdate ? "on" : "off")"
        defaultActivityStatus = "Observing \(OpenPush.LiveActivities.defaultActivityTypeName)"
            + " · " + summary
        append(
            .activity,
            title: "Default attributes observed",
            detail: summary
        )
    }

    /// `startDefault(_:attributes:content:)` requests the activity through
    /// ActivityKit for you: no attributes type to declare, and the dictionaries
    /// are what a remote update later replaces.
    func startDefaultLiveActivity() {
        guard #available(iOS 16.1, *) else {
            append(
                .error,
                title: "Live Activities unavailable",
                detail: "This feature requires iOS 16.1 or newer."
            )
            return
        }
        let activityID = "demo-\(UUID())"
        OpenPush.LiveActivities.startDefault(
            activityID,
            attributes: ["title": "Demo"],
            content: ["progress": 0.4]
        )
        defaultActivityID = activityID
        append(
            .activity,
            title: "Default activity requested",
            detail: activityID
        )
    }

    /// The counterpart to the push-to-start token `setupDefault` forwards: it
    /// tells the server to stop starting activities of this type for this
    /// device. iOS 17.2 is where push-to-start exists at all.
    func removeDefaultPushToStartToken() {
        guard #available(iOS 17.2, *) else {
            append(
                .error,
                title: "Push-to-start unavailable",
                detail: "Push-to-start tokens require iOS 17.2 or newer."
            )
            return
        }
        OpenPush.LiveActivities.removePushToStartToken(DefaultLiveActivityAttributes.self)
        append(
            .activity,
            title: "Push-to-start token removal queued",
            detail: OpenPush.LiveActivities.defaultActivityTypeName
        )
    }

    /// `DeviceCredentialStore.save(_:)`. The store writes to the shared
    /// Keychain access group, which is what lets the Notification Service
    /// Extension post receipts with the same credential.
    func saveDeviceCredential(_ value: String) {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            append(
                .error,
                title: "A credential is required",
                detail: "Paste this install's linked credential before saving it."
            )
            return
        }
        report(keychain: ExampleConfiguration.credentialStore.save(credential),
               succeeded: "Credential stored in the shared Keychain",
               failed: "Credential could not be stored")
    }

    /// `DeviceCredentialStore.wipe()`. `errSecItemNotFound` is the honest answer
    /// when there was nothing to remove, so it is reported as such rather than
    /// as a failure.
    func wipeDeviceCredential() {
        let status = ExampleConfiguration.credentialStore.wipe()
        if status == errSecItemNotFound {
            refreshDeviceCredential()
            credentialStatus = "Nothing stored to wipe"
            append(
                .sdk,
                title: "No credential to wipe",
                detail: "The shared Keychain held no credential for this install."
            )
            return
        }
        report(keychain: status,
               succeeded: "Credential wiped from the shared Keychain",
               failed: "Credential could not be wiped")
    }

    /// `DeviceCredentialStore.migrateLegacy(defaults:key:)`: the one-release
    /// move of a credential that an older build mirrored into the App Group in
    /// plaintext. It reports `false` when there was nothing to move, which is
    /// the normal answer on a fresh install.
    func migrateLegacyDeviceCredential() {
        let defaults = UserDefaults(suiteName: ExampleConfiguration.appGroup)
        let migrated = ExampleConfiguration.credentialStore.migrateLegacy(
            defaults: defaults,
            key: ExampleConfiguration.legacyCredentialDefaultsKey
        )
        refreshDeviceCredential()
        credentialStatus = migrated
            ? "Legacy credential migrated out of the App Group"
            : "No legacy credential to migrate"
        append(
            .sdk,
            title: migrated ? "Legacy credential migrated" : "No legacy credential found",
            detail: migrated
                ? "The plaintext copy was removed only after the Keychain write succeeded."
                : "The App Group holds no plaintext credential under \(ExampleConfiguration.legacyCredentialDefaultsKey)."
        )
    }

    private func report(keychain status: OSStatus, succeeded: String, failed: String) {
        refreshDeviceCredential()
        let ok = status == errSecSuccess
        credentialStatus = ok ? succeeded : "\(failed) · OSStatus \(status)"
        append(
            ok ? .sdk : .error,
            title: ok ? succeeded : failed,
            detail: "OSStatus \(status)"
        )
    }

    private func refreshDeviceCredential() {
        deviceCredentialAvailable = ExampleConfiguration.hasDeviceCredential
    }

    private func installDemoSnapshot() {
        permissionGranted = false
        subscriptionID = "demo-sub-a41f"
        token = "7f91c0a84bd94c11b8af47e92c45a6237f91c0a84bd94c11b8af47e92c45a623"
        pushEnabled = false
        subscriptionStatus = -18
        externalID = nil
        tags = ["example_build": "feature-lab"]
        aliases = [:]
        readInAppPausedFromSDK()
    }

    private func installWaitingForConsentSnapshot() {
        permissionGranted = false
        subscriptionID = nil
        token = nil
        pushEnabled = false
        subscriptionStatus = nil
        externalID = nil
        tags = [:]
        aliases = [:]
        readInAppPausedFromSDK()
    }

    /// The pause switch is a mirror, not a store: a snapshot reads the engine's
    /// own value back instead of writing a redundant one into it.
    private func readInAppPausedFromSDK() {
        applyingSnapshot = true
        inAppPaused = OpenPush.InAppMessages.paused
        applyingSnapshot = false
    }

    private func installSDKObservers() {
        guard !sdkObserversInstalled else { return }
        sdkObserversInstalled = true
        OpenPush.onLog = { [weak self] message in
            Task { @MainActor in
                self?.append(.sdk, title: "SDK log", detail: message)
            }
        }
        OpenPush.onRegistered = { [weak self] in
            Task { @MainActor in
                self?.refreshFromSDK()
                self?.append(.subscription, title: "Device registered", detail: "OpenPush accepted the latest subscription state.")
            }
        }
        OpenPush.onRegistrationFailed = { [weak self] message in
            Task { @MainActor in
                self?.append(.error, title: "Registration failed", detail: message)
            }
        }
        OpenPush.onIdentityVerificationRequired = { [weak self] externalId in
            Task { @MainActor in
                self?.append(
                    .identity,
                    title: "Identity verification required",
                    detail: "\(externalId) — enter the auth hash and log in again. Until then registrations leave the server-side link untouched."
                )
            }
        }
        permissionObserver = OpenPush.Notifications.addPermissionObserver { [weak self] granted in
            Task { @MainActor in
                self?.permissionGranted = granted
                self?.refreshPermissionSnapshot()
                self?.append(.permission, title: "Permission observer fired", detail: "authorized = \(granted)")
            }
        }
        subscriptionObserver = OpenPush.PushSubscription.addObserver { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.subscriptionID = state.id
                self.token = state.token
                self.pushEnabled = state.optedIn
                self.subscriptionStatus = state.status
                self.append(
                    .subscription,
                    title: "Subscription observer fired",
                    detail: "optedIn = \(state.optedIn) · status = \(state.status.map(String.init) ?? "—")"
                )
            }
        }
        // Beside the plain observer, not instead of it: the two lists are
        // independent, and a host that only wants the new state keeps using
        // `addObserver`. This one also carries the state that was replaced.
        subscriptionChangeObserver = OpenPush.PushSubscription.addChangeObserver { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                self.recordSubscriptionChange(
                    previous: Self.summarize(change.previous),
                    current: Self.summarize(change.current),
                    detail: "\(change.previous.map { Self.describe($0) } ?? "none")"
                        + " → \(Self.describe(change.current))",
                    synthetic: false
                )
            }
        }
        // The deferred-display story only ends when iOS has an answer, and the
        // completion handler is the only place that has it: `display()` inside
        // the SDK's window presents the banner, and silence past it suppresses
        // the notification as `preventDefault()` asked.
        ForegroundPresentationChoice.shared.onOutcome { [weak self] options in
            Task { @MainActor in
                self?.append(
                    .foreground,
                    title: options.isEmpty
                        ? "Deferred display suppressed"
                        : "Deferred display presented",
                    detail: options.isEmpty
                        ? "The held answer resolved to no presentation — display() did "
                            + "not arrive inside the SDK's window, so preventDefault() stood."
                        : "display() released the banner preventDefault() was holding "
                            + "back; iOS was answered with \(Self.describe(options))."
                )
            }
        }
        foregroundListener = OpenPush.Notifications.addForegroundLifecycleListener { [weak self] event in
            // This runs synchronously inside `processForeground`, and the answer
            // it is deciding is already on its way back to iOS — so the choice is
            // read from the lock-guarded mirror and acted on here, not after a hop
            // to the main actor, which would arrive too late to suppress anything.
            let choice = ForegroundPresentationChoice.shared.current
            if choice.prevent { event.preventDefault() }
            if choice.prevent, choice.displayAfterDelay {
                let delay = ForegroundPresentationChoice.displayDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // Honored only because `willPresent` chose the asynchronous
                    // `processForeground(_:completion:)`; the synchronous one has
                    // already answered and this is a no-op there. What the call
                    // achieved is not known here — the outcome is logged from the
                    // completion handler, which sees the answer iOS was given.
                    event.display()
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.lastMessageID = event.notification.messageId ?? self.lastMessageID
                self.append(
                    .foreground,
                    title: "Foreground listener fired",
                    detail: Self.describe(event.notification)
                        + " · " + Self.describePresentationChoice(choice)
                )
            }
        }
        clickListener = OpenPush.Notifications.addClickListener { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.lastMessageID = event.notification.messageId ?? self.lastMessageID
                self.append(
                    .click,
                    title: "Click listener fired",
                    detail: "action = \(event.actionId ?? "default") · "
                        + Self.describe(event.notification)
                )
            }
        }
        inAppLifecycleListener = OpenPush.InAppMessages.addLifecycleListener { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.lastInAppStage = event.stage
                self.lastInAppMessage = event.messageId
                self.lastInAppLayout = event.layout
                self.append(
                    .inApp,
                    title: "In-app \(event.stage.rawValue)",
                    detail: "message = \(event.messageId) · layout = \(event.layout)"
                )
            }
        }
        inAppClickListener = OpenPush.InAppMessages.addClickListener { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let action = event.actionId ?? "—"
                let url = event.url ?? "no url"
                self.lastInAppClick = "\(action) · \(url) · closing = \(event.closingMessage)"
                    + " · first = \(event.firstClick)"
                self.append(
                    .inApp,
                    title: "In-app click",
                    detail: "message = \(event.messageId) · action = \(action) · url = \(url)"
                        + " · target = \(event.urlTarget ?? "—") · closing = \(event.closingMessage)"
                        + " · first = \(event.firstClick)"
                )
            }
        }
    }

    private func startSDKAfterConsentChange(eventTitle: String, eventDetail: String) {
        if mode == .live, ExampleConfiguration.hasLiveCredentials, !OpenPush.isInitialized {
            installSDKObservers()
            if ExampleSDKBootstrap.startIfPermitted() {
                refreshFromSDK()
            }
        }
        append(.sdk, title: eventTitle, detail: eventDetail)
    }

    private func ensureLiveSDKReady(for action: String) -> Bool {
        guard mode != .live || OpenPush.isInitialized else {
            append(
                .error,
                title: "SDK waiting for consent",
                detail: "Grant host consent before you \(action)."
            )
            return false
        }
        return true
    }

    private func cleanedPair(key: String, value: String) -> (key: String, value: String)? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            append(.error, title: "Both fields are required", detail: "Keys, labels, and values cannot be empty.")
            return nil
        }
        return (key, value)
    }

    /// Trims a batch and drops the pairs the SDK would refuse anyway, reporting
    /// once for the batch rather than once per blank row: an editor that offers
    /// extra rows will usually hand back some that were never filled in.
    private func cleanedPairs(_ pairs: [(key: String, value: String)]) -> [String: String] {
        var accepted: [String: String] = [:]
        var refused = 0
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty, value.isEmpty { continue }
            guard !key.isEmpty, !value.isEmpty else {
                refused += 1
                continue
            }
            accepted[key] = value
        }
        if refused > 0 {
            append(
                .error,
                title: refused == 1 ? "One row was incomplete" : "\(refused) rows were incomplete",
                detail: "Keys, labels, and values cannot be empty. The complete rows were written."
            )
        } else if accepted.isEmpty, !pairs.isEmpty {
            // Every row was blank, which through the singular wrappers means the
            // one pair was: keep the message the single-pair path used to give.
            append(
                .error,
                title: "Both fields are required",
                detail: "Keys, labels, and values cannot be empty."
            )
        }
        return accepted
    }

    private func describePairs(_ pairs: [String: String]) -> String {
        pairs.keys.sorted().map { "\($0) = \(pairs[$0] ?? "")" }.joined(separator: " · ")
    }

    private func append(_ kind: LabEvent.Kind, title: String, detail: String) {
        events.insert(LabEvent(date: Date(), kind: kind, title: title, detail: detail), at: 0)
        if events.count > 80 { events.removeLast(events.count - 80) }
    }

    @available(iOS 16.1, *)
    private func currentActivity() -> Activity<ExampleDeliveryAttributes>? {
        if let liveActivityID {
            return Activity<ExampleDeliveryAttributes>.activities.first { $0.id == liveActivityID }
        }
        return Activity<ExampleDeliveryAttributes>.activities.first
    }
}
