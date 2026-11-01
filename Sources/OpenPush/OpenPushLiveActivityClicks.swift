import Foundation
import OpenPushLiveActivities

public extension OpenPush.LiveActivities {
    @discardableResult
    static func trackClickAndReturnOriginal(_ url: URL) -> URL? {
        guard url.scheme == OpenPushLiveActivityClickURL.scheme,
              url.host == OpenPushLiveActivityClickURL.host,
              url.path == OpenPushLiveActivityClickURL.clickPath,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return url }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let redirect = value("redirect").flatMap(URL.init(string:))
        guard let activityId = value("activityId"), !activityId.isEmpty else { return redirect }
        executor.append(OpenPush.LiveActivityRequest(
            kind: .click, key: UUID().uuidString, activityId: activityId,
            activityType: value("activityType") ?? "",
            notificationId: value("notificationId") ?? ""))
        return redirect
    }
}
