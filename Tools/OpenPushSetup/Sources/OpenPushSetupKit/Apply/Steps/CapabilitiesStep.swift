import Foundation

/// Push Notifications (`aps-environment`), the `remote-notification`
/// background mode, and Live Activity support when a widget is in use.
struct CapabilitiesStep: ApplyStep {
    func apply(_ context: ApplyContext) throws {
        let app = context.plan.appTarget
        for path in context.entitlementsFiles(of: app) {
            if try context.plist(path).setIfMissing("aps-environment", "development") {
                context.report.changed("\(path): aps-environment = development (Push Notifications)")
            }
        }
        for path in context.infoPlistFiles(of: app) {
            if try context.plist(path).addToArray("UIBackgroundModes", BackgroundModesDetector.remoteNotification) {
                context.report.changed("\(path): UIBackgroundModes += remote-notification")
            }
            if let widget = context.choices.widgetExtension, widget.mode != .off,
               try context.plist(path).setIfMissing("NSSupportsLiveActivities", true) {
                context.report.changed("\(path): NSSupportsLiveActivities = YES")
            }
        }
    }
}
