import ActivityKit
import Foundation
import OpenPushLiveActivities

struct ExampleDeliveryAttributes: OpenPushLiveActivityAttributes, Sendable {
    struct ContentState: OpenPushLiveActivityContentState, Sendable {
        var stage: String
        var etaMinutes: Int
        var openpush: OpenPushLiveActivityContentStateData?

        init(stage: String, etaMinutes: Int,
             openpush: OpenPushLiveActivityContentStateData? = nil) {
            self.stage = stage
            self.etaMinutes = etaMinutes
            self.openpush = openpush
        }
    }

    var orderNumber: String
    var openpush: OpenPushLiveActivityAttributeData

    init(orderNumber: String, activityId: String? = nil) {
        self.orderNumber = orderNumber
        self.openpush = .create(activityId: activityId ?? orderNumber)
    }
}
