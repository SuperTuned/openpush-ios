import ActivityKit
import OpenPushLiveActivities
import SwiftUI
import WidgetKit

@main
struct OpenPushExampleWidgets: WidgetBundle {
    var body: some Widget {
        ExampleDeliveryWidget()
    }
}

struct ExampleDeliveryWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExampleDeliveryAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Color(red: 4 / 255, green: 122 / 255, blue: 69 / 255))
                    .frame(width: 36, height: 36)
                    .background(Color(red: 0, green: 194 / 255, blue: 103 / 255).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.stage)
                        .font(.headline)
                    Text(context.attributes.orderNumber)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(context.state.etaMinutes)")
                        .font(.title2.bold().monospacedDigit())
                    Text("MIN")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(Color(uiColor: .systemBackground))
            .activitySystemActionForegroundColor(Color.primary)
            // Not `widgetURL`: the OpenPush wrapper folds the activity id, the
            // activity type, and the update's notification id into a tracking
            // URL, and the app hands that back to the SDK in `onOpenURL`. The
            // app's own destination travels inside it and comes back out there.
            .openpushWidgetURL(deepLink(for: context), context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Delivery", systemImage: "shippingbox.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0, green: 194 / 255, blue: 103 / 255))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.etaMinutes) min")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.stage)
                        Spacer()
                        Text(context.attributes.orderNumber)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Color(red: 0, green: 194 / 255, blue: 103 / 255))
            } compactTrailing: {
                Text("\(context.state.etaMinutes)m")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Color(red: 0, green: 194 / 255, blue: 103 / 255))
            }
            .keylineTint(Color(red: 0, green: 194 / 255, blue: 103 / 255))
            // ActivityKit accepts a URL only on the compact and minimal
            // presentations, so this one modifier covers the whole Dynamic
            // Island. The expanded regions carry no tap target of their own.
            .openpushWidgetURL(deepLink(for: context), context: context)
        }
    }

    /// Where the app should go once the tap has been recorded. The SDK returns
    /// exactly this URL from `trackClickAndReturnOriginal(_:)`.
    private func deepLink(for context: ActivityViewContext<ExampleDeliveryAttributes>) -> URL? {
        URL(string: "openpush-example://activity/\(context.attributes.openpush.activityId)")
    }
}
