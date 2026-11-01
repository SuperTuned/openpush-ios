// The compatibility spelling of the Live Activity attributes, kept so a widget
// written against another push SDK compiles unchanged. Every type here is the
// migrating host's spelling of the `OpenPush…` type beside it in
// `OpenPushLiveActivityAttributes.swift`; the field name is part of the wire
// contract the server already sends, so it is not renamed. New code uses the
// `OpenPush…` spelling.

import Foundation

public struct OneSignalLiveActivityAttributeData: Codable, Hashable, Sendable {
    public var activityId: String
    enum CodingKeys: String, CodingKey { case activityId = "activity_id" }
    public init(activityId: String) { self.activityId = activityId }
    public static func create(activityId: String) -> Self { Self(activityId: activityId) }
}

public struct OneSignalLiveActivityContentStateData: Codable, Hashable, Sendable {
    public var notificationId: String
    enum CodingKeys: String, CodingKey { case notificationId = "notification_id" }
    public init(notificationId: String) { self.notificationId = notificationId }
}

public protocol OneSignalLiveActivityContentState: Codable, Hashable {
    var onesignal: OneSignalLiveActivityContentStateData? { get set }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
public protocol OneSignalLiveActivityAttributes: ActivityAttributes
where ContentState: OneSignalLiveActivityContentState {
    var onesignal: OneSignalLiveActivityAttributeData { get set }
}

@available(iOS 16.1, *)
public extension View {
    @MainActor
    func onesignalWidgetURL<T: OneSignalLiveActivityAttributes>(
        _ url: URL?, context: ActivityViewContext<T>
    ) -> some View {
        widgetURL(OpenPushLiveActivityClickURL.build(
            originalURL: url, activityId: context.attributes.onesignal.activityId,
            activityType: OpenPushLiveActivityTypeName.derived(T.self),
            notificationId: context.state.onesignal?.notificationId))
    }
}

@available(iOS 16.1, *)
public extension DynamicIsland {
    func onesignalWidgetURL<T: OneSignalLiveActivityAttributes>(
        _ url: URL?, context: ActivityViewContext<T>
    ) -> DynamicIsland {
        widgetURL(OpenPushLiveActivityClickURL.build(
            originalURL: url, activityId: context.attributes.onesignal.activityId,
            activityType: OpenPushLiveActivityTypeName.derived(T.self),
            notificationId: context.state.onesignal?.notificationId))
    }
}
#endif
