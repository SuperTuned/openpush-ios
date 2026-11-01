import Foundation

/// The source files setup writes for targets it creates or takes over.
enum ExtensionTemplates {
    /// A whole notification service extension on OpenPush's handler. `@objc`
    /// keeps a principal class the Info.plist names without a module prefix.
    static func serviceExtension(className: String, appGroup: String, objcName: Bool) -> String {
        """
        import OpenPushNSE
        import UserNotifications

        /// OpenPush's notification service extension: action buttons, the
        /// notification image and the delivery receipt, in one handler.
        \(objcName ? "@objc(\(className))\n" : "")final class \(className): UNNotificationServiceExtension {
            private let openPush = OpenPushNotificationServiceHandler(options: {
                var options = OpenPushNotificationServiceHandler.Options()
                options.appGroup = \(SwiftLiteral.string(appGroup))
                return options
            }())

            override func didReceive(
                _ request: UNNotificationRequest,
                withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
            ) {
                openPush.didReceive(request, withContentHandler: contentHandler)
            }

            override func serviceExtensionTimeWillExpire() {
                openPush.serviceExtensionTimeWillExpire()
            }
        }

        """
    }

    /// A Live Activity widget for activities started with OpenPush's default
    /// attributes. It shows the `title` and `body` of the activity's data.
    static let liveActivityWidget = """
        import ActivityKit
        import OpenPushLiveActivities
        import SwiftUI
        import WidgetKit

        @main
        struct OpenPushLiveActivityWidgets: WidgetBundle {
            var body: some Widget {
                OpenPushLiveActivityWidget()
            }
        }

        /// Shows a Live Activity started from the OpenPush console with the default
        /// attributes. Replace the views with your own design.
        struct OpenPushLiveActivityWidget: Widget {
            var body: some WidgetConfiguration {
                ActivityConfiguration(for: DefaultLiveActivityAttributes.self) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text(context.state.data["title"] ?? context.attributes.data["title"]))
                            .font(.headline)
                        Text(text(context.state.data["body"] ?? context.attributes.data["body"]))
                            .font(.subheadline)
                    }
                    .padding()
                } dynamicIsland: { context in
                    DynamicIsland {
                        DynamicIslandExpandedRegion(.bottom) {
                            Text(text(context.state.data["body"] ?? context.attributes.data["body"]))
                        }
                    } compactLeading: {
                        Text(text(context.state.data["title"] ?? context.attributes.data["title"]))
                    } compactTrailing: {
                        EmptyView()
                    } minimal: {
                        EmptyView()
                    }
                }
            }

            private func text(_ value: OpenPushAnyCodable?) -> String { value?.asString() ?? "" }
        }

        """

    /// The Info.plist of a created extension: only the extension point and the
    /// principal class. The rest is generated from build settings.
    static func extensionInfoPlist(point: String, principalClass: String?) -> [String: Any] {
        var attributes: [String: Any] = ["NSExtensionPointIdentifier": point]
        if let principalClass { attributes["NSExtensionPrincipalClass"] = principalClass }
        return ["NSExtension": attributes]
    }
}
