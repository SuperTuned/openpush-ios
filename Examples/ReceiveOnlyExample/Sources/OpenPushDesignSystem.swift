import SwiftUI
import UIKit
import OpenPush
import OpenPushCore

enum OpenPushStyle {
    // The dashboard's Signal green stays bright in dark appearance; the light
    // appearance uses its deeper accessible partner for controls and text.
    static let signal = Color.dynamic(light: 0x006B3D, dark: 0x00C267)
    static let signalText = Color.dynamic(light: 0x006B3D, dark: 0x65E59D)
    static let paper = Color.dynamic(light: 0xF7F5F1, dark: 0x0A0A0A)
    static let paperRaised = Color.dynamic(light: 0xFFFFFF, dark: 0x171717)
    static let ink = Color.dynamic(light: 0x0A0A0A, dark: 0xF7F5F1)
    static let muted = Color.dynamic(light: 0x686761, dark: 0xAAA8A1)
    static let hairline = Color.dynamic(light: 0xD7D4CD, dark: 0x3A3936)
    static let warning = Color.dynamic(light: 0x9A6700, dark: 0xFFD166)
}

private extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            uiColor: UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct OpenPushMark: View {
    var size: CGFloat = 46

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(OpenPushStyle.ink, lineWidth: max(2, size * 0.06))
                .padding(size * 0.12)
            Circle()
                .fill(OpenPushStyle.paper)
                .frame(width: size * 0.36, height: size * 0.36)
                .overlay {
                    Circle()
                        .fill(OpenPushStyle.signal)
                        .padding(size * 0.06)
                }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LabIntro: View {
    let summary: String
    let mode: RuntimeMode

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            OpenPushMark()
            VStack(alignment: .leading, spacing: 5) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(OpenPushStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ModeBadge(mode: mode)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lab-intro")
    }
}

struct ModeBadge: View {
    let mode: RuntimeMode

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(mode == .live ? OpenPushStyle.signal : OpenPushStyle.warning)
                .frame(width: 8, height: 8)
            Text(mode == .live ? "LIVE SDK" : "DEMO · SDK WRITES SIMULATED")
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(0.6)
        }
        .foregroundStyle(OpenPushStyle.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(OpenPushStyle.paperRaised)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(OpenPushStyle.hairline, lineWidth: 1) }
    }
}

struct MetricCell: View {
    let label: String
    let value: String
    let detail: String
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.caption2.monospaced().weight(.medium))
                .tracking(0.7)
                .foregroundStyle(OpenPushStyle.muted)
            Text(value)
                .font(.headline.monospaced().weight(.semibold))
                .foregroundStyle(accent ? OpenPushStyle.signalText : OpenPushStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(OpenPushStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .padding(16)
        .background(OpenPushStyle.paperRaised)
        .overlay { Rectangle().stroke(OpenPushStyle.hairline, lineWidth: 1) }
    }
}

struct LabPanel<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    init(title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 12)
                    if let note {
                        Text(note.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(OpenPushStyle.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    if let note {
                        Text(note.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(OpenPushStyle.muted)
                    }
                }
            }
            .padding(16)

            Rectangle()
                .fill(OpenPushStyle.hairline)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(16)
        }
        .background(OpenPushStyle.paperRaised)
        .overlay { Rectangle().stroke(OpenPushStyle.hairline, lineWidth: 1) }
    }
}

struct TelemetryRow: View {
    let label: String
    let value: String
    var valueColor: Color = OpenPushStyle.ink

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                telemetryLabel
                Spacer(minLength: 8)
                telemetryValue.multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                telemetryLabel
                telemetryValue.multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var telemetryLabel: some View {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(OpenPushStyle.muted)
    }

    private var telemetryValue: some View {
        Text(value)
            .font(.caption.monospaced())
            .foregroundStyle(valueColor)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(OpenPushStyle.hairline).frame(height: 1)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 14)
            .foregroundStyle(OpenPushStyle.paper)
            .background(OpenPushStyle.ink.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 14)
            .foregroundStyle(OpenPushStyle.ink)
            .background(configuration.isPressed ? OpenPushStyle.hairline.opacity(0.4) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(OpenPushStyle.hairline, lineWidth: 1)
            }
    }
}

struct DestructiveActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 14)
            .foregroundStyle(Color.red)
            .background(configuration.isPressed ? Color.red.opacity(0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
            }
    }
}

/// Applies an accessibility identifier only when the caller supplied one, so a
/// field without one keeps whatever identifier SwiftUI would derive instead of
/// being given an empty string.
private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

struct LabTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String
    var capitalization: TextInputAutocapitalization = .never
    /// Goes on the field itself, not on this container: an identifier set on
    /// the stack would not be the one `app.textFields[…]` asks for.
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.caption2.monospaced().weight(.medium))
                .tracking(0.6)
                .foregroundStyle(OpenPushStyle.muted)
            TextField(prompt, text: $text)
                // Only when one was given: `accessibilityIdentifier("")` would
                // hand every unnamed field the same empty identifier.
                .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(OpenPushStyle.paper)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(OpenPushStyle.hairline, lineWidth: 1)
                }
        }
    }
}

struct SettingsButton: View {
    @Environment(\.colorScheme) private var presentingColorScheme
    @EnvironmentObject private var model: ExampleModel
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Feature lab settings")
        .sheet(isPresented: $presented) {
            LabSettingsView()
                .preferredColorScheme(
                    model.appearance.colorScheme ?? presentingColorScheme
                )
        }
    }
}

struct LabSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: ExampleModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Runtime") {
                    Picker("Mode", selection: Binding(
                        get: { model.mode },
                        set: { model.setMode($0) }
                    )) {
                        ForEach(RuntimeMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !model.liveAvailable {
                        Label("Add App ID and SDK key, then relaunch to unlock Live mode.", systemImage: "key")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Appearance") {
                    Picker("Appearance", selection: Binding(
                        get: { model.appearance },
                        set: { model.setAppearance($0) }
                    )) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Configuration") {
                    LabeledContent("App ID", value: ExampleConfiguration.hasLiveCredentials
                                   ? ExampleConfiguration.appID : "Not configured")
                    LabeledContent("SDK key", value: ExampleConfiguration.hasLiveCredentials
                                   ? "Configured" : "Not configured")
                    LabeledContent("Device credential", value: model.deviceCredentialAvailable
                                   ? "Stored" : "Not stored")
                    LabeledContent("Host consent", value: model.consentStatusLabel)
                    LabeledContent("SDK startup", value: model.sdkStartupLabel)
                    LabeledContent("SDK", value: OpenPush.sdkVersion)
                }

                Section("Request identification") {
                    LabeledContent(OpenPushSDKVersion.headerField,
                                   value: OpenPushSDKVersion.headerValue)
                    LabeledContent(OpenPushSDKVersion.wrapperHeaderField,
                                   value: model.wrapperHeaderLabel)
                    Text("Every request this SDK makes—from the app and from the service extension—carries the first header. The second is present only when a wrapper SDK set OpenPush.wrapper before initialize; a host integrating OpenPush directly, as this sample does, sends none.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Feature Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
