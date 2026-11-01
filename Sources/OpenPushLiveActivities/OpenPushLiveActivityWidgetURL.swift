import Foundation

public enum OpenPushLiveActivityClickURL {
    public static let scheme = "openpush-liveactivity"
    public static let host = "track"
    public static let clickPath = "/click"

    public static func build(originalURL: URL?, activityId: String,
                             activityType: String, notificationId: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = clickPath
        var items = [URLQueryItem(name: "activityId", value: activityId),
                     URLQueryItem(name: "activityType", value: activityType)]
        if let notificationId { items.append(.init(name: "notificationId", value: notificationId)) }
        if let originalURL { items.append(.init(name: "redirect", value: originalURL.absoluteString)) }
        components.queryItems = items
        return components.url
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
public extension View {
    @MainActor
    func openpushWidgetURL<T: OpenPushLiveActivityAttributes>(
        _ url: URL?, context: ActivityViewContext<T>
    ) -> some View {
        widgetURL(OpenPushLiveActivityClickURL.build(
            originalURL: url, activityId: context.attributes.openpush.activityId,
            activityType: OpenPushLiveActivityTypeName.derived(T.self),
            notificationId: context.state.openpush?.notificationId))
    }
}

@available(iOS 16.1, *)
public extension DynamicIsland {
    func openpushWidgetURL<T: OpenPushLiveActivityAttributes>(
        _ url: URL?, context: ActivityViewContext<T>
    ) -> DynamicIsland {
        widgetURL(OpenPushLiveActivityClickURL.build(
            originalURL: url, activityId: context.attributes.openpush.activityId,
            activityType: OpenPushLiveActivityTypeName.derived(T.self),
            notificationId: context.state.openpush?.notificationId))
    }
}
#endif
