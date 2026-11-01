import Foundation

/// The Live Activity widget: reuse an existing widget extension, or create
/// `LiveActivityWidget` with a widget for OpenPush's default attributes.
struct WidgetStep: ApplyStep {
    func apply(_ context: ApplyContext) throws {
        guard let choice = context.choices.widgetExtension, choice.mode == .new, let name = choice.target else { return }
        try ExtensionTargetFactory().create(.init(
            name: name,
            bundleID: choice.bundleID ?? name,
            extensionPoint: "com.apple.widgetkit-extension",
            principalClass: nil,
            deploymentTarget: "16.1",
            sources: ["\(name).swift": ExtensionTemplates.liveActivityWidget],
            entitlements: false,
            profiles: choice.profile,
            profileFlag: "--widget-profile"), in: context)
    }
}
