import SwiftUI
import OpenPush
import UIKit

struct StatusScreen: View {
    @EnvironmentObject private var model: ExampleModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var customEditorPresented = false
    @State private var deviceCredential = ""

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 1), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                LabIntro(
                    summary: "A runnable map of the iOS SDK—state first, actions second, receipts visible.",
                    mode: model.mode
                )

                LazyVGrid(columns: columns, spacing: 1) {
                    MetricCell(
                        label: "Permission",
                        value: model.permissionLabel,
                        detail: "iOS authorization cache",
                        accent: model.permissionGranted
                    )
                    MetricCell(
                        label: "Push",
                        value: model.subscriptionLabel,
                        detail: "status \(model.subscriptionStatus.map(String.init) ?? "—")",
                        accent: model.pushEnabled
                    )
                    MetricCell(
                        label: "Identity",
                        value: model.identityLabel,
                        detail: model.externalID == nil ? "install-level user" : "external ID attached"
                    )
                    MetricCell(
                        label: "SDK",
                        value: OpenPush.sdkVersion,
                        detail: model.mode == .demo ? "simulated service writes" : model.sdkStartupLabel
                    )
                }

                if model.liveActionsBlocked {
                    ConsentGateNotice()
                }

                LabPanel(title: "Notifications", note: "permission + subscription") {
                    TelemetryRow(
                        label: "Authorization",
                        value: model.permissionLabel,
                        valueColor: model.permissionGranted ? OpenPushStyle.signalText : OpenPushStyle.warning
                    )
                    Hairline()
                    TelemetryRow(label: "Status", value: model.permissionStatusLabel)
                        .accessibilityIdentifier("permission-status")
                    Hairline()
                    TelemetryRow(label: "Can request", value: model.canRequestPermissionLabel)
                        .accessibilityIdentifier("can-request-permission")
                    Text("Status is OpenPush's unflattened authorization cache, refreshed at initialize, each permission request, and every foreground; it stays Not determined while the SDK is not initialized. Can request answers for this SDK, not for iOS.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Hairline()
                    Toggle(
                        "Push enabled",
                        isOn: Binding(
                            get: { model.pushEnabled },
                            set: { model.setPushEnabled($0) }
                        )
                    )
                    .font(.body.weight(.medium))
                    Text("Opting out preserves the device token while excluding the subscription from delivery.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)

                    if !model.permissionGranted {
                        Button("Request notification permission") {
                            model.requestPermission()
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        Button("Request provisional authorization") {
                            model.requestProvisionalPermission()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("request-provisional-permission")
                        Text("Provisional authorization shows no prompt: notifications arrive quietly in the notification centre until the user promotes them.")
                            .font(.caption)
                            .foregroundStyle(OpenPushStyle.muted)
                    }
                }
                .disabled(model.liveActionsBlocked)

                LabPanel(title: "PNS examples", note: "5 local fixtures") {
                    Text("Exercise foreground and click delegates with APNs-shaped local notifications. Permission and delivery behavior remain native iOS.")
                        .font(.subheadline)
                        .foregroundStyle(OpenPushStyle.muted)
                    TelemetryRow(label: "Last request", value: model.lastNotificationReceipt)
                        .accessibilityIdentifier("pns-last-request")
                    ForEach(NotificationExample.allCases) { example in
                        NotificationExampleButton(example: example) {
                            if example == .custom {
                                customEditorPresented = true
                            } else {
                                model.scheduleNotification(example)
                            }
                        }
                        if example != NotificationExample.allCases.last { Hairline() }
                    }
                }

                LabPanel(title: "Privacy consent", note: "host-app gate") {
                    Text("OpenPush does not own a consent API. This sample stores the host app's decision and delays OpenPush initialization until consent is granted.")
                        .font(.subheadline)
                        .foregroundStyle(OpenPushStyle.muted)
                    Toggle(
                        "Require consent before SDK start",
                        isOn: Binding(
                            get: { model.consentRequired },
                            set: { model.setConsentRequired($0) }
                        )
                    )
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("consent-required-toggle")
                    Hairline()
                    TelemetryRow(label: "Saved decision", value: model.consentStatusLabel)
                    Hairline()
                    TelemetryRow(label: "SDK startup", value: model.sdkStartupLabel)

                    if model.consentRequired, !model.consentGranted {
                        Button("Grant consent & start SDK") { model.grantConsent() }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .accessibilityIdentifier("grant-consent-button")
                    } else if model.consentRequired {
                        Button("Reset saved consent", role: .destructive) {
                            model.resetSavedConsent()
                        }
                        .buttonStyle(DestructiveActionButtonStyle())
                        .accessibilityIdentifier("reset-consent-button")
                    }

                    if model.consentChangeNeedsRelaunch {
                        Label(
                            "This process already initialized OpenPush. Relaunch to test the waiting state; resetting consent cannot undo data already sent.",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabPanel(title: "Device registration", note: model.mode.label) {
                    TelemetryRow(label: "Subscription ID", value: model.shortSubscriptionID)
                    Hairline()
                    TelemetryRow(label: "APNs token", value: model.shortToken)
                    Hairline()
                    TelemetryRow(
                        label: "Credential",
                        value: model.deviceCredentialAvailable ? "Stored in Keychain" : "Not stored"
                    )
                    Hairline()
                    TelemetryRow(label: "currentToken", value: model.currentTokenLabel)
                        .accessibilityIdentifier("current-token")
                    Hairline()
                    TelemetryRow(label: "snapshot()", value: model.subscriptionSnapshotLabel)
                        .accessibilityIdentifier("subscription-snapshot")
                    Text("The rows above are the state the observer last handed over—synthetic in Demo mode. These two read the SDK itself at this moment: OpenPush.currentToken, and pushSubscription.snapshot(), which captures all four fields as one equatable value you can diff.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    if model.mode == .live {
                        Button("Refresh SDK snapshot") { model.refreshFromSDK() }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .disabled(model.liveActionsBlocked)
                    }
                }

                LabPanel(title: "Credential", note: "shared Keychain") {
                    Text("This install's linked credential lives in the shared Keychain access group, not in the App Group: an App Group is readable by every extension the app ships. DeviceCredentialStore is the only thing that reads or writes it, and OpenPush.initialize takes it as a closure so the value is fetched when a request needs it.")
                        .font(.subheadline)
                        .foregroundStyle(OpenPushStyle.muted)
                    TelemetryRow(
                        label: "Stored",
                        value: model.deviceCredentialAvailable ? "Yes" : "No",
                        valueColor: model.deviceCredentialAvailable
                            ? OpenPushStyle.signalText : OpenPushStyle.warning
                    )
                    .accessibilityIdentifier("credential-stored")
                    Hairline()
                    TelemetryRow(label: "Last write", value: model.credentialStatus)
                        .accessibilityIdentifier("credential-status")
                    LabTextField(
                        label: "Credential",
                        text: $deviceCredential,
                        prompt: "paste the linked credential",
                        identifier: "credential-field"
                    )
                    Button("Save credential") {
                        model.saveDeviceCredential(deviceCredential)
                        deviceCredential = ""
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .accessibilityIdentifier("credential-save")
                    Button("Migrate legacy credential") {
                        model.migrateLegacyDeviceCredential()
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .accessibilityIdentifier("credential-migrate")
                    Text("migrateLegacy(defaults:key:) moves a credential an older build mirrored into the App Group in plaintext, and removes that copy only after the Keychain write succeeds. A fresh install has nothing to move and says so.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Button("Wipe credential", role: .destructive) {
                        model.wipeDeviceCredential()
                    }
                    .buttonStyle(DestructiveActionButtonStyle())
                    .accessibilityIdentifier("credential-wipe")
                }

                LabPanel(title: "App-side receipt", note: "OpenPush.receipt") {
                    TelemetryRow(label: "Last message id", value: model.lastMessageID ?? "None seen yet")
                        .accessibilityIdentifier("last-message-id")
                    Hairline()
                    TelemetryRow(label: "Receipts pending", value: "\(model.pendingReceipts)")
                        .accessibilityIdentifier("receipts-pending")
                    Menu {
                        Button("Post received receipt") { model.postReceipt("received") }
                        Button("Post clicked receipt") { model.postReceipt("clicked") }
                    } label: {
                        Label("App-side receipt", systemImage: "paperplane")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(!model.canPostReceipt)
                    .accessibilityIdentifier("app-side-receipt")
                    Text("The service extension posts for a message it handled; this is the app posting for one it saw itself. Both are keyed on op_message_id, and the two processes cannot see each other's receipts—the server keeps the first timestamp, so the duplicate is harmless. A receipt needs an initialized SDK and an APNs token; with either missing the call returns without a request. Receipts pending is OpenPush.pendingReceiptCount: what this install still owes the server. The queue is persisted, so a receipt that failed outlives the process and is retried on the next foreground or registration—a count that stays above zero is what that looks like from here.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }

                LabPanel(title: "Notification extension", note: "actions + image + receipt") {
                    TelemetryRow(label: "Action parsing", value: model.notificationExtensionActions)
                        .accessibilityIdentifier("nse-actions")
                    Hairline()
                    TelemetryRow(label: "Attachment", value: model.notificationExtensionAttachment)
                        .accessibilityIdentifier("nse-attachment")
                    Hairline()
                    TelemetryRow(label: "Receipt delivery", value: model.notificationExtensionReceipt)
                        .accessibilityIdentifier("nse-receipt")
                    Text("Inject the bundled actionable APNs fixture to run the extension. It reports each piece of work the handler did: the buttons it registered, whether the payload's image_url became an attachment, and the receipt's HTTP status or why it was skipped. Receipt delivery requires Live credentials, the shared App Group, and the Keychain access group.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Button("Refresh extension telemetry") {
                        model.refreshNotificationExtensionTelemetry()
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(OpenPushStyle.paper)
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { SettingsButton() }
        .sheet(isPresented: $customEditorPresented) {
            CustomNotificationEditorSheet { draft in
                model.scheduleNotification(.custom, customDraft: draft)
            }
            .presentationDetents([.large])
        }
    }
}

private struct NotificationExampleButton: View {
    let example: NotificationExample
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: example.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(OpenPushStyle.signalText)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(example.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OpenPushStyle.ink)
                    Text(example.detail)
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OpenPushStyle.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityLabel("Schedule \(example.title) notification")
        .accessibilityHint(example.detail)
    }
}

private struct CustomNotificationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let schedule: (CustomNotificationDraft) -> Void

    @State private var title = CustomNotificationDraft.example.title
    @State private var description = CustomNotificationDraft.example.description
    @State private var dataKey = CustomNotificationDraft.example.dataKey
    @State private var dataValue = CustomNotificationDraft.example.dataValue

    private var draft: CustomNotificationDraft {
        CustomNotificationDraft(
            title: title,
            description: description,
            dataKey: dataKey,
            dataValue: dataValue
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Notification") {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("custom-notification-title")
                        .onChange(of: title) { value in
                            title = String(value.prefix(CustomNotificationDraft.titleLimit))
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $description)
                            .frame(minHeight: 96)
                            .accessibilityLabel("Description")
                            .accessibilityIdentifier("custom-notification-description")
                            .onChange(of: description) { value in
                                description = String(value.prefix(CustomNotificationDraft.descriptionLimit))
                            }
                        Text("\(description.count)/\(CustomNotificationDraft.descriptionLimit)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Section {
                    TextField("Key", text: $dataKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom-notification-key")
                        .onChange(of: dataKey) { value in
                            dataKey = String(value.prefix(CustomNotificationDraft.dataKeyLimit))
                        }
                    TextField("Value", text: $dataValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom-notification-value")
                        .onChange(of: dataValue) { value in
                            dataValue = String(value.prefix(CustomNotificationDraft.dataValueLimit))
                        }
                } header: {
                    Text("Custom data")
                } footer: {
                    Text("This key-value pair is included in the app-defined payload delivered with the notification.")
                }
            }
            .navigationTitle("Custom Notification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        schedule(draft.normalized)
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }
}

struct UserScreen: View {
    enum EditorKind: String, Identifiable {
        case tag
        case alias
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: ExampleModel
    @State private var externalID = "demo-user"
    @State private var authHash = ""
    @State private var editor: EditorKind?
    @State private var selectedTags: Set<String> = []
    @State private var selectedAliases: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                LabIntro(
                    summary: "Attach this install to your user model, then shape targeting data with tags and aliases.",
                    mode: model.mode
                )

                if model.liveActionsBlocked {
                    ConsentGateNotice()
                }

                LabPanel(title: "Identity", note: model.externalID == nil ? "anonymous" : "identified") {
                    TelemetryRow(label: "Current user", value: model.identityLabel)
                    Hairline()
                    LabTextField(label: "External ID", text: $externalID, prompt: "player-1042")
                    LabTextField(label: "Auth hash (optional)", text: $authHash, prompt: "hmac from your server")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { identityActions }
                        VStack(spacing: 10) { identityActions }
                    }
                    Text("Generate identity verification hashes on your server—never in the app.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }
                .disabled(model.liveActionsBlocked)

                LabPanel(title: "Tags", note: "targeting state") {
                    DataRows(
                        values: model.tags,
                        emptyText: "No tags in this session",
                        remove: model.removeTag,
                        selection: $selectedTags
                    )
                    Button("Add tags") { editor = .tag }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("tags-add")
                    if !selectedTags.isEmpty {
                        Button("Remove \(selectedTags.count) selected", role: .destructive) {
                            model.removeTags(Array(selectedTags))
                            selectedTags.removeAll()
                        }
                        .buttonStyle(DestructiveActionButtonStyle())
                        .accessibilityIdentifier("tags-remove-selected")
                    }
                    Text("Both writes are plural: the sheet sends every row through addTags(_:), and selecting rows here deletes them through removeTags(_:). A deletion leaves the key in the next registration body with an empty value, which is the server's delete signal, but getTags() stops reporting it at once.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }
                .disabled(model.liveActionsBlocked)
                .onChange(of: model.tags) { tags in
                    selectedTags.formIntersection(tags.keys)
                }

                LabPanel(title: "Aliases", note: "10 labels max") {
                    DataRows(
                        values: model.aliases,
                        emptyText: "No aliases in this session",
                        remove: model.removeAlias,
                        selection: $selectedAliases
                    )
                    Button("Add aliases") { editor = .alias }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("aliases-add")
                    if !selectedAliases.isEmpty {
                        Button("Remove \(selectedAliases.count) selected", role: .destructive) {
                            model.removeAliases(Array(selectedAliases))
                            selectedAliases.removeAll()
                        }
                        .buttonStyle(DestructiveActionButtonStyle())
                        .accessibilityIdentifier("aliases-remove-selected")
                    }
                    Text("Aliases add lookup keys; they do not merge users. Use login for external_id. addAliases(_:) and removeAliases(_:) share the same write window as tags, so a batch of both travels in one registration.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }
                .disabled(model.liveActionsBlocked)
                .onChange(of: model.aliases) { aliases in
                    selectedAliases.formIntersection(aliases.keys)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(OpenPushStyle.paper)
        .navigationTitle("User")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { SettingsButton() }
        .sheet(item: $editor) { kind in
            KeyValueEditorSheet(
                title: kind == .tag ? "Add Tags" : "Add Aliases",
                keyLabel: kind == .tag ? "Key" : "Label",
                keyPrompt: kind == .tag ? "plan" : "player_id",
                valueLabel: kind == .tag ? "Value" : "ID",
                valuePrompt: kind == .tag ? "pro" : "p-1042",
                allowsMultipleRows: true
            ) { rows, _ in
                let pairs = rows.map { (key: $0.key, value: $0.value) }
                if kind == .tag {
                    model.addTags(pairs)
                } else {
                    model.addAliases(pairs)
                }
            }
            .presentationDetents([.large])
        }
    }

    @ViewBuilder private var identityActions: some View {
        Button("Log in") { model.login(externalID: externalID, authHash: authHash) }
            .buttonStyle(PrimaryActionButtonStyle())
        Button("Log out", role: .destructive) { model.logout() }
            .buttonStyle(DestructiveActionButtonStyle())
    }
}

private struct DataRows: View {
    let values: [String: String]
    let emptyText: String
    let remove: (String) -> Void
    /// When a binding is supplied each row also carries a selection control, and
    /// the owning panel offers the plural removal. The trigger panel passes
    /// nothing and keeps one trash per row: a trigger write never leaves the
    /// process, so batching them buys nothing there, and **Clear triggers**
    /// already covers removing several at once.
    var selection: Binding<Set<String>>?

    private var keys: [String] { values.keys.sorted() }

    var body: some View {
        if values.isEmpty {
            LabEmptyState(
                title: emptyText,
                symbol: "tray",
                detail: "Use the action below to create one."
            )
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ForEach(keys, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let selection {
                        SelectionToggle(key: key, selection: selection)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key)
                            .font(.subheadline.weight(.semibold))
                        Text(values[key] ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(OpenPushStyle.muted)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(role: .destructive) { remove(key) } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Remove \(key)")
                }
                if key != keys.last { Hairline() }
            }
        }
    }
}

private struct SelectionToggle: View {
    let key: String
    @Binding var selection: Set<String>

    private var isSelected: Bool { selection.contains(key) }

    var body: some View {
        Button {
            if isSelected {
                selection.remove(key)
            } else {
                selection.insert(key)
            }
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(isSelected ? OpenPushStyle.signalText : OpenPushStyle.muted)
                .frame(width: 32, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(key)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One row of the editor. Identified rather than indexed so SwiftUI keeps a
/// field's keyboard focus when a row is added above or below it.
struct KeyValueDraft: Identifiable, Equatable {
    let id = UUID()
    var key = ""
    var value = ""

    var isBlank: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isComplete: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct KeyValueEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let keyLabel: String
    let keyPrompt: String
    let valueLabel: String
    let valuePrompt: String
    /// Only the trigger editor needs it: tags and aliases are always strings.
    var showsValueKind = false
    /// Tags and aliases are written in batches — `addTags(_:)` and
    /// `addAliases(_:)` take a whole map, and nearby writes share one
    /// registration, so offering one pair at a time would hide the API that
    /// matters. The trigger editor sets one value at a time and leaves this off.
    var allowsMultipleRows = false
    let save: ([KeyValueDraft], TriggerValueKind) -> Void
    @State private var rows = [KeyValueDraft()]
    @State private var valueKind = TriggerValueKind.string

    private var prompt: String {
        showsValueKind ? valueKind.prompt : valuePrompt
    }

    private var completedRows: [KeyValueDraft] { rows.filter(\.isComplete) }

    private func label(_ base: String, at index: Int) -> String {
        allowsMultipleRows ? "\(base) \(index + 1)" : base
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Section {
                        TextField(keyPrompt, text: binding(for: row.id).key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel(label(keyLabel, at: index))
                            .accessibilityIdentifier("editor-key-\(index)")
                        TextField(prompt, text: binding(for: row.id).value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel(label(valueLabel, at: index))
                            .accessibilityIdentifier("editor-value-\(index)")
                        if showsValueKind {
                            Picker("Value kind", selection: $valueKind) {
                                ForEach(TriggerValueKind.allCases) { kind in
                                    Text(kind.title).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("inapp-trigger-kind")
                        }
                        if allowsMultipleRows, rows.count > 1 {
                            Button("Remove row \(index + 1)", role: .destructive) {
                                rows.removeAll { $0.id == row.id }
                            }
                            .accessibilityIdentifier("editor-remove-row-\(index)")
                        }
                    } footer: {
                        if showsValueKind {
                            Text("The kind decides how the engine compares this value: a Number trigger answers greater/less conditions, a Bool trigger answers equals.")
                        }
                    }
                }

                if allowsMultipleRows {
                    Section {
                        Button("Add another row") { rows.append(KeyValueDraft()) }
                            .accessibilityIdentifier("editor-add-row")
                    } footer: {
                        Text("Every complete row travels in one call, and nearby writes share a single registration. Blank rows are ignored.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        save(rows.filter { !$0.isBlank }, valueKind)
                        dismiss()
                    }
                    .disabled(completedRows.isEmpty)
                }
            }
        }
    }

    /// A binding into the row with this id, so a removal above it cannot make a
    /// held index write into the wrong row.
    private func binding(for id: UUID) -> Binding<KeyValueDraft> {
        Binding(
            get: { rows.first { $0.id == id } ?? KeyValueDraft() },
            set: { updated in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index] = updated
            }
        )
    }
}

struct EventsScreen: View {
    @EnvironmentObject private var model: ExampleModel
    @State private var customEventName = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                LabIntro(
                    summary: "Every SDK observer reports here, in order, with enough context to verify your integration.",
                    mode: model.mode
                )

                if model.liveActionsBlocked {
                    ConsentGateNotice()
                }

                LabPanel(
                    title: "Listener controls",
                    note: model.liveActionsBlocked ? "waiting for consent" : "5 observers armed"
                ) {
                    Toggle("Suppress foreground presentation", isOn: $model.preventForegroundPresentation)
                        .accessibilityIdentifier("suppress-foreground-presentation")
                    Text("When enabled, the foreground listener calls preventDefault() while still recording the event.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Toggle("…then display after 2 s", isOn: $model.displayAfterDeferral)
                        .disabled(!model.preventForegroundPresentation)
                        .accessibilityIdentifier("display-after-deferral")
                    Text("With this on, willPresent forwards to processForeground(_:completion:) instead of returning an answer, and the listener calls event.display() two seconds after preventDefault(). Only the asynchronous spelling can honor that—the synchronous one has already answered iOS, where display() is a no-op. Left un-displayed, the SDK suppresses the notification after 25 seconds.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Button("Schedule real local notification") { model.scheduleLocalNotification() }
                        .buttonStyle(PrimaryActionButtonStyle())
                    Menu {
                        Button("Foreground listener") { model.previewListenerEvent(.foreground) }
                        Button("Click listener") { model.previewListenerEvent(.click) }
                        Button("Permission observer") { model.previewListenerEvent(.permission) }
                        Button("Subscription observer") { model.previewListenerEvent(.subscription) }
                        Button("Subscription change observer") { model.previewSubscriptionChange() }
                    } label: {
                        Label("Preview an observer event", systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Hairline()
                    TelemetryRow(label: "Last subscription change", value: model.lastSubscriptionChange)
                        .accessibilityIdentifier("subscription-last-change")
                    Text("addChangeObserver reports the same moments as addObserver, but hands over the state that was replaced next to the new one, so a host can act on what actually moved without keeping its own copy. The chain is continuous: each change's previous is the one before it, and the first has none. The two observer lists are separate—an id from one means nothing to the other.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }

                LabPanel(
                    title: "Custom events",
                    note: model.liveActionsBlocked ? "waiting for consent" : "Journey signal"
                ) {
                    LabTextField(
                        label: "Event name",
                        text: $customEventName,
                        prompt: "checkout_started",
                        identifier: "custom-event-name"
                    )
                    Button("Track event") {
                        model.trackCustomEvent(named: customEventName)
                        customEventName = ""
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .accessibilityIdentifier("custom-event-track")
                    Text("trackEvent(_:properties:) records a case-sensitive event for Journey entry, waits, and exits. Nearby calls share one request, and a request the server never acknowledged stays persisted and retries, so nothing about the call is visible on the device—only the stream row below says it was made.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }

                LabPanel(
                    title: "Event stream",
                    note: "\(model.events.count) retained · newest first"
                ) {
                    if model.events.isEmpty {
                        LabEmptyState(
                            title: "No events yet",
                            symbol: "waveform.path.ecg",
                            detail: "Run an action or schedule a notification to populate the stream."
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(model.events) { event in
                            EventRow(event: event)
                            if event.id != model.events.last?.id { Hairline() }
                        }
                        Button("Clear event stream", role: .destructive) { model.clearEvents() }
                            .buttonStyle(DestructiveActionButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(OpenPushStyle.paper)
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { SettingsButton() }
    }
}

private struct LabEmptyState: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(OpenPushStyle.muted)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(OpenPushStyle.muted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct EventRow: View {
    let event: LabEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(event.kind == .error ? Color.red : OpenPushStyle.signalText)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        eventTitle
                        Spacer(minLength: 10)
                        eventTime
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        eventTitle
                        eventTime
                    }
                }
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(OpenPushStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var eventTitle: some View {
        Text(event.title).font(.subheadline.weight(.semibold))
    }

    private var eventTime: some View {
        Text(event.date, style: .time)
            .font(.caption2.monospaced())
            .foregroundStyle(OpenPushStyle.muted)
    }
}

struct ActivityScreen: View {
    @EnvironmentObject private var model: ExampleModel
    @Environment(\.openURL) private var openURL
    @State private var orderNumber = "ORD-1234"
    @State private var stage = "On the way"
    @State private var eta = 12
    @State private var manualActivityID = "order-1"
    @State private var activityType = ExampleConfiguration.activityType
    @State private var updateToken = "a1b2c3d4e5f6"
    @State private var pushToStartToken = "f6e5d4c3b2a1"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                LabIntro(
                    summary: "Render a real ActivityKit surface, then inspect the token-forwarding APIs OpenPush uses for remote updates.",
                    mode: model.mode
                )

                if model.liveActionsBlocked {
                    ConsentGateNotice()
                }

                LabPanel(title: "Device authorization", note: "iOS Settings") {
                    TelemetryRow(
                        label: "Live Activities",
                        value: model.liveActivitiesAuthorizationLabel,
                        valueColor: model.liveActivitiesEnabled == true
                            ? OpenPushStyle.signalText : OpenPushStyle.warning
                    )
                    .accessibilityIdentifier("activitykit-live-activities")
                    Hairline()
                    TelemetryRow(
                        label: "Frequent updates",
                        value: model.frequentLiveActivityUpdatesLabel,
                        valueColor: model.frequentLiveActivityUpdatesEnabled == true
                            ? OpenPushStyle.signalText : OpenPushStyle.warning
                    )
                    .accessibilityIdentifier("activitykit-frequent-updates")
                    Text("Live Activities controls whether iOS can display this app’s activity. Frequent updates permits a higher remote-push budget; it is not required to receive an individual update token.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open iOS app settings") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            openURL(settings)
                        }
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }

                LabPanel(title: "ActivityKit preview", note: "Lock Screen + Dynamic Island") {
                    ActivityPreview(
                        orderNumber: orderNumber,
                        stage: model.liveActivityStage,
                        eta: model.liveActivityETA,
                        running: model.liveActivityID != nil
                    )
                    LabTextField(label: "Order number", text: $orderNumber, prompt: "ORD-1234")
                    LabTextField(label: "Stage", text: $stage, prompt: "On the way", capitalization: .sentences)
                    Stepper("ETA · \(eta) min", value: $eta, in: 0...120)
                    if model.liveActivityID == nil {
                        Button("Start Live Activity") { model.startLocalActivity(orderNumber: orderNumber) }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .disabled(model.liveActivitiesEnabled == false)
                    } else {
                        Button("Update Live Activity") { model.updateLocalActivity(stage: stage, eta: eta) }
                            .buttonStyle(PrimaryActionButtonStyle())
                        Button("End Live Activity", role: .destructive) { model.endLocalActivity() }
                            .buttonStyle(DestructiveActionButtonStyle())
                    }
                    Text("The bundled widget extension renders the activity. In Live mode, setup(_:) also forwards ActivityKit tokens automatically. A tap on either presentation opens the SDK's tracking URL, and the app hands it back through trackClickAndReturnOriginal(_:).")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Hairline()
                    TelemetryRow(label: "Last tap routed to", value: model.lastWidgetDeepLink)
                        .accessibilityIdentifier("activity-widget-tap")
                    Text("The SDK records the click and returns the destination the widget carried; routing it is still the app's decision, so the row shows it rather than navigating.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    if model.liveActivitiesEnabled == false {
                        Label(
                            "Live Activities are disabled for this app. Open iOS Settings to allow them before starting a new activity.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabPanel(title: "Default attributes", note: "no attributes type") {
                    Text("An app with no ActivityKit attributes type of its own can use the SDK's. setupDefault(options:) observes DefaultLiveActivityAttributes and startDefault(_:attributes:content:) requests one, so the whole Live Activity path is reachable from two calls.")
                        .font(.subheadline)
                        .foregroundStyle(OpenPushStyle.muted)
                    TelemetryRow(label: "Setup", value: model.defaultActivityStatus)
                        .accessibilityIdentifier("default-activity-status")
                    Hairline()
                    TelemetryRow(label: "Last started", value: model.defaultActivityID ?? "None")
                        .accessibilityIdentifier("default-activity-id")
                    Toggle("Observe push-to-start tokens", isOn: $model.defaultActivityPushToStart)
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("default-activity-push-to-start")
                    Toggle("Observe push-to-update tokens", isOn: $model.defaultActivityPushToUpdate)
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("default-activity-push-to-update")
                    Text("Both switches are OpenPushLiveActivitySetupOptions, read at the setup call rather than applied live: setup decides once which token streams it observes.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Button("Set up default attributes") { model.setupDefaultLiveActivities() }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .accessibilityIdentifier("default-activity-setup")
                    Button("Start default activity") { model.startDefaultLiveActivity() }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("default-activity-start")
                    Button("Remove push-to-start token", role: .destructive) {
                        model.removeDefaultPushToStartToken()
                    }
                    .buttonStyle(DestructiveActionButtonStyle())
                    .accessibilityIdentifier("default-activity-remove-start-token")
                    Text("Removal is iOS 17.2 and up, and tells the server to stop starting activities of this type on this device.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                }
                // setupDefault installs the same token observation setup does,
                // so the host consent gate has to cover it too.
                .disabled(model.liveActionsBlocked)

                LabPanel(title: "Manual token lab", note: "advanced integration") {
                    Text("Use these controls when your app owns ActivityKit observation instead of using automatic setup.")
                        .font(.subheadline)
                        .foregroundStyle(OpenPushStyle.muted)
                    LabTextField(label: "Activity ID", text: $manualActivityID, prompt: "order-1")
                    LabTextField(label: "Activity type", text: $activityType, prompt: "delivery")
                    LabTextField(label: "Update token", text: $updateToken, prompt: "lowercase hex")
                    Button("Forward update token") {
                        model.forwardActivityToken(
                            activityID: manualActivityID,
                            activityType: activityType,
                            token: updateToken
                        )
                    }
                    .buttonStyle(PrimaryActionButtonStyle())

                    Hairline()
                    LabTextField(label: "Push-to-start token", text: $pushToStartToken, prompt: "iOS 17.2+ token")
                    Button("Forward push-to-start token") {
                        model.forwardPushToStartToken(activityType: activityType, token: pushToStartToken)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    Button("Exit forwarded activity", role: .destructive) {
                        model.exitForwardedActivity(manualActivityID)
                    }
                    .buttonStyle(DestructiveActionButtonStyle())
                }
                .disabled(model.liveActionsBlocked)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(OpenPushStyle.paper)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { SettingsButton() }
    }
}

struct InAppScreen: View {
    @EnvironmentObject private var model: ExampleModel
    @State private var triggerEditorPresented = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                LabIntro(
                    summary: "Drive the in-app engine the way your app does: set the triggers it matches, pause the surface, and watch the lifecycle and click events it reports.",
                    mode: model.mode
                )

                LabPanel(
                    title: "Triggers",
                    note: model.triggers.isEmpty ? "none held" : "\(model.triggers.count) held"
                ) {
                    Text("Triggers stay in this process—no network call sets one. Every change re-evaluates the queue, so a message whose conditions have just become true is presented immediately.")
                        .font(.subheadline)
                        .foregroundStyle(OpenPushStyle.muted)
                    DataRows(
                        values: model.triggers,
                        emptyText: "No triggers in this session",
                        remove: model.removeTrigger
                    )
                    Button("Add trigger") { triggerEditorPresented = true }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("inapp-add-trigger")

                    Hairline()
                    Toggle("Paused", isOn: $model.inAppPaused)
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("inapp-paused")
                    Text("Pausing takes the message on screen down without counting a display: it returns to the front of the queue and is shown again when you resume.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)

                    Button("Clear triggers", role: .destructive) { model.clearTriggers() }
                        .buttonStyle(DestructiveActionButtonStyle())
                        .accessibilityIdentifier("inapp-clear")
                }

                LabPanel(title: "Last events", note: "lifecycle + click") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Lifecycle stage")
                            .font(.subheadline)
                            .foregroundStyle(OpenPushStyle.muted)
                        Spacer(minLength: 8)
                        StageBadge(stage: model.lastInAppStage)
                    }
                    TelemetryRow(label: "Message", value: model.lastInAppMessage)
                        .accessibilityIdentifier("inapp-last-message")
                    TelemetryRow(label: "Layout of last message", value: model.lastInAppLayout)
                        .accessibilityIdentifier("inapp-last-layout")
                    Text("The stage is an enum on the event, not a string you parse; the string `phase` is that stage's raw value. The layout rides on the same event, so a host can tell a banner from a centred message without asking the server.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    Hairline()
                    TelemetryRow(label: "Click", value: model.lastInAppClick)
                        .accessibilityIdentifier("inapp-last-click")
                    Text("A display is reported as didDisplay only once the document has rendered; a document that fails to load reports nothing and is skipped for the session. `first` is true only for the first click on a message, however many times it is shown.")
                        .font(.caption)
                        .foregroundStyle(OpenPushStyle.muted)
                    if model.mode == .demo {
                        Button("Preview in-app lifecycle") { model.previewInAppLifecycle() }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .accessibilityIdentifier("inapp-preview-lifecycle")
                        Text("Demo mode has no definitions to queue. This writes the four stages a real presentation emits, and the click one of its buttons would report, into the event stream.")
                            .font(.caption)
                            .foregroundStyle(OpenPushStyle.muted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(OpenPushStyle.paper)
        .navigationTitle("In-app")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { SettingsButton() }
        .sheet(isPresented: $triggerEditorPresented) {
            KeyValueEditorSheet(
                title: "Add Trigger",
                keyLabel: "Key",
                keyPrompt: "tier",
                valueLabel: "Value",
                valuePrompt: "gold",
                showsValueKind: true
            ) { rows, kind in
                guard let row = rows.first else { return }
                model.addTrigger(key: row.key, value: row.value, kind: kind)
            }
            .presentationDetents([.medium])
        }
    }
}

/// The typed lifecycle stage, shown as its raw value and nothing else — the
/// badge is the enum made visible, not a second vocabulary to keep in step with
/// it. The dot separates a fact about what the reader saw (`didDisplay`) from a
/// request the presenter has yet to carry out.
private struct StageBadge: View {
    let stage: OpenPush.InAppMessageLifecycleEvent.Stage?

    private var settled: Bool { stage == .didDisplay || stage == .didDismiss }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(stage == nil
                      ? OpenPushStyle.hairline
                      : (settled ? OpenPushStyle.signal : OpenPushStyle.warning))
                .frame(width: 8, height: 8)
            Text(stage?.rawValue ?? "none yet")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(stage == nil ? OpenPushStyle.muted : OpenPushStyle.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(OpenPushStyle.paperRaised)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(OpenPushStyle.hairline, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inapp-last-stage")
        .accessibilityLabel(stage?.rawValue ?? "none yet")
    }
}

private struct ConsentGateNotice: View {
    @EnvironmentObject private var model: ExampleModel

    var body: some View {
        LabPanel(title: "SDK waiting", note: "host consent") {
            Label(
                "Live SDK actions are paused. Grant consent to initialize OpenPush for this process.",
                systemImage: "hand.raised"
            )
            .font(.subheadline)
            .foregroundStyle(OpenPushStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            Button("Grant consent & start SDK") { model.grantConsent() }
                .buttonStyle(PrimaryActionButtonStyle())
        }
        .accessibilityIdentifier("consent-gate-notice")
    }
}

private struct ActivityPreview: View {
    let orderNumber: String
    let stage: String
    let eta: Int
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("DELIVERY", systemImage: "shippingbox.fill")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(OpenPushStyle.signalText)
                Spacer()
                Text(running ? "LIVE" : "PREVIEW")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(running ? OpenPushStyle.signalText : OpenPushStyle.muted)
            }
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage)
                        .font(.headline)
                    Text(orderNumber.isEmpty ? "ORD-1234" : orderNumber)
                        .font(.caption.monospaced())
                        .foregroundStyle(OpenPushStyle.muted)
                }
                Spacer()
                Text("\(eta)")
                    .font(.title.bold().monospacedDigit())
                Text("min")
                    .font(.caption)
                    .foregroundStyle(OpenPushStyle.muted)
            }
        }
        .padding(16)
        .background(OpenPushStyle.paper)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OpenPushStyle.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Delivery \(orderNumber), \(stage), \(eta) minutes")
    }
}
