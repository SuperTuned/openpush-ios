import Foundation

public extension OpenPush {
    enum LiveActivityState: Sendable, Equatable {
        case active
        case ended
        case dismissed
        case stale
    }
}

public protocol OpenPushLiveActivityHandle: Sendable {
    var appleId: String { get }
    var topicKey: String { get }
    var currentPushToken: Data? { get }
    func pushTokens() -> AsyncStream<Data>
    func states() -> AsyncStream<OpenPush.LiveActivityState>
    func notificationIds() -> AsyncStream<String>
    func endImmediately() async
}

public protocol OpenPushLiveActivitySource: Sendable {
    associatedtype Handle: OpenPushLiveActivityHandle
    func existingActivities() -> [Handle]
    func activityUpdates() -> AsyncStream<Handle>
    func pushToStartTokens() -> AsyncStream<Data>
}

protocol OpenPushLiveActivityAuthorizationSource: Sendable {
    var activitiesEnabled: Bool { get }
    var frequentPushesEnabled: Bool { get }
    func activityEnablementUpdates() -> AsyncStream<Bool>
    func frequentPushEnablementUpdates() -> AsyncStream<Bool>
}

final class OpenPushLiveActivityAuthorizationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func start(_ operation: @escaping @Sendable () -> Void) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        if shouldStart { operation() }
    }

    func resetForTests() {
        lock.withLock { started = false }
    }
}

extension OpenPush.LiveActivities {
    static let authorizationMonitor = OpenPushLiveActivityAuthorizationMonitor()

    static func observeAuthorizationUpdates<
        S: OpenPushLiveActivityAuthorizationSource
    >(_ source: S) {
        Task.detached {
            await observeAuthorizationUpdatesAndWaitForTests(source)
        }
    }

    static func observeAuthorizationAndWaitForTests<
        S: OpenPushLiveActivityAuthorizationSource
    >(_ source: S) async {
        recordAuthorization(
            activitiesEnabled: source.activitiesEnabled,
            frequentPushesEnabled: source.frequentPushesEnabled
        )
        await observeAuthorizationUpdatesAndWaitForTests(source)
    }

    static func observeAuthorizationUpdatesAndWaitForTests<
        S: OpenPushLiveActivityAuthorizationSource
    >(_ source: S) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await enabled in source.activityEnablementUpdates() {
                    recordActivitiesEnabled(enabled)
                }
            }
            group.addTask {
                for await enabled in source.frequentPushEnablementUpdates() {
                    recordFrequentPushes(enabled)
                }
            }
            await group.waitForAll()
        }
    }
}

extension OpenPush.LiveActivities {
    static func observe<S: OpenPushLiveActivitySource>(
        _ source: S, activityType: String,
        enablePushToStart: Bool, enablePushToUpdate: Bool
    ) {
        Task.detached {
            await observeAndWaitForTests(source, activityType: activityType,
                                         enablePushToStart: enablePushToStart,
                                         enablePushToUpdate: enablePushToUpdate)
        }
    }

    static func observeAndWaitForTests<S: OpenPushLiveActivitySource>(
        _ source: S, activityType: String,
        enablePushToStart: Bool, enablePushToUpdate: Bool
    ) async {
        // Subscribe before taking the snapshot. An activity created between
        // those two operations is buffered by AsyncStream and cannot fall into
        // the old snapshot-before-subscription gap.
        let updates = source.activityUpdates()
        let existing = source.existingActivities()
        let seededAppleIds = Set(existing.map(\.appleId))
        await withTaskGroup(of: Void.self) { group in
            if enablePushToStart {
                group.addTask {
                    for await token in source.pushToStartTokens() {
                        recordPushToStart(activityType: activityType, tokenData: token)
                    }
                }
            }

            // Push-to-start may launch the app after ActivityKit has already
            // inserted the activity into this set, so seed every survivor.
            for handle in existing {
                group.addTask {
                    await attach(handle, activityType: activityType,
                                 enablePushToUpdate: enablePushToUpdate)
                }
            }

            group.addTask {
                await withTaskGroup(of: Void.self) { attachments in
                    var observedAppleIds = seededAppleIds
                    for await handle in updates {
                        // The pre-snapshot subscription may report an activity
                        // that the snapshot also contained. Attach it once.
                        guard observedAppleIds.insert(handle.appleId).inserted else { continue }

                        // One topic key represents one logical Live Activity. End an
                        // older per-device duplicate before attaching the new one.
                        for other in source.existingActivities()
                        where other.appleId != handle.appleId
                                && other.topicKey == handle.topicKey {
                            OpenPush.onLog("• live activity \(activityType): ending duplicate " +
                                           "\(other.appleId) for topic \(other.topicKey)")
                            await other.endImmediately()
                        }

                        // ActivityKit's state/content/token streams can remain
                        // open for the lifetime of an activity. Never await one
                        // inline or it blocks every later activity registration.
                        attachments.addTask {
                            await attach(handle, activityType: activityType,
                                         enablePushToUpdate: enablePushToUpdate)
                        }
                    }
                    await attachments.waitForAll()
                }
            }
            await group.waitForAll()
        }
    }

    private static func attach<H: OpenPushLiveActivityHandle>(
        _ handle: H, activityType: String, enablePushToUpdate: Bool
    ) async {
        OpenPush.state.setLiveActivityType(activityType, for: handle.topicKey)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in handle.states() where state == .dismissed {
                    exit(handle.topicKey)
                }
            }
            group.addTask {
                for await notificationId in handle.notificationIds() {
                    reportReceipt(notificationId: notificationId,
                                  activityId: handle.topicKey,
                                  activityType: activityType)
                }
            }
            if enablePushToUpdate {
                group.addTask {
                    if let token = handle.currentPushToken {
                        record(activityId: handle.topicKey, activityType: activityType,
                               tokenData: token)
                    }
                    for await token in handle.pushTokens() {
                        record(activityId: handle.topicKey, activityType: activityType,
                               tokenData: token)
                    }
                }
            }
            await group.waitForAll()
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.2, *)
struct ActivityKitAuthorizationSource: OpenPushLiveActivityAuthorizationSource {
    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var frequentPushesEnabled: Bool { ActivityAuthorizationInfo().frequentPushesEnabled }

    func activityEnablementUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let updates = ActivityAuthorizationInfo().activityEnablementUpdates
            let task = Task.detached {
                for await enabled in updates { continuation.yield(enabled) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func frequentPushEnablementUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let updates = ActivityAuthorizationInfo().frequentPushEnablementUpdates
            let task = Task.detached {
                for await enabled in updates { continuation.yield(enabled) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@available(iOS 16.1, *)
private final class OpenPushObservedActivityBox<Attributes: ActivityAttributes>: @unchecked Sendable {
    let value: Activity<Attributes>
    init(_ value: Activity<Attributes>) { self.value = value }
}

@available(iOS 16.1, *)
struct ActivityKitHandle<Attributes: ActivityAttributes & Sendable>:
    OpenPushLiveActivityHandle {
    let appleId: String
    let topicKey: String
    let notificationId: (@Sendable (Attributes.ContentState) -> String?)?
    private let observedActivity: OpenPushObservedActivityBox<Attributes>

    init(activity: Activity<Attributes>, topicKey: String,
         notificationId: (@Sendable (Attributes.ContentState) -> String?)?) {
        appleId = activity.id
        self.topicKey = topicKey
        self.notificationId = notificationId
        observedActivity = OpenPushObservedActivityBox(activity)
    }

    var currentPushToken: Data? { observedActivity.value.pushToken }

    func pushTokens() -> AsyncStream<Data> {
        let activity = observedActivity
        return AsyncStream<Data> { continuation in
            Task.detached {
                for await token in activity.value.pushTokenUpdates { continuation.yield(token) }
                continuation.finish()
            }
        }
    }

    func states() -> AsyncStream<OpenPush.LiveActivityState> {
        let activity = observedActivity
        return AsyncStream<OpenPush.LiveActivityState>(bufferingPolicy: .unbounded) {
            (continuation: AsyncStream<OpenPush.LiveActivityState>.Continuation) in
            Task.detached {
                for await state in activity.value.activityStateUpdates {
                    switch state {
                    case .active: continuation.yield(OpenPush.LiveActivityState.active)
                    case .ended: continuation.yield(OpenPush.LiveActivityState.ended)
                    case .dismissed: continuation.yield(OpenPush.LiveActivityState.dismissed)
                    case .stale: continuation.yield(OpenPush.LiveActivityState.stale)
                    default: break
                    }
                }
                continuation.finish()
            }
        }
    }

    func notificationIds() -> AsyncStream<String> {
        let activity = observedActivity
        let extract = notificationId
        return AsyncStream<String> { continuation in
            guard #available(iOS 16.2, *), extract != nil else {
                continuation.finish(); return
            }
            Task.detached {
                guard let extract else { continuation.finish(); return }
                for await content in activity.value.contentUpdates {
                    if let notificationId = extract(content.state) {
                        continuation.yield(notificationId)
                    }
                }
                continuation.finish()
            }
        }
    }

    func endImmediately() async {
        guard #available(iOS 16.2, *) else { return }
        await observedActivity.value.end(nil, dismissalPolicy: .immediate)
    }
}

@available(iOS 16.1, *)
struct ActivityKitSource<Attributes: ActivityAttributes & Sendable>:
    OpenPushLiveActivitySource {
    let topicKey: (@Sendable (Attributes) -> String)?
    let notificationId: (@Sendable (Attributes.ContentState) -> String?)?

    private func handle(_ activity: Activity<Attributes>) -> ActivityKitHandle<Attributes> {
        ActivityKitHandle(activity: activity,
                          topicKey: topicKey?(activity.attributes) ?? activity.id,
                          notificationId: notificationId)
    }

    func existingActivities() -> [ActivityKitHandle<Attributes>] {
        Activity<Attributes>.activities.map(handle)
    }

    func activityUpdates() -> AsyncStream<ActivityKitHandle<Attributes>> {
        let topic = topicKey
        let notification = notificationId
        return AsyncStream { continuation in
            let updates = Activity<Attributes>.activityUpdates
            Task.detached {
                for await activity in updates {
                    continuation.yield(ActivityKitHandle(
                        activity: activity,
                        topicKey: topic?(activity.attributes) ?? activity.id,
                        notificationId: notification))
                }
                continuation.finish()
            }
        }
    }

    func pushToStartTokens() -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard #available(iOS 17.2, *) else { continuation.finish(); return }
            let updates = Activity<Attributes>.pushToStartTokenUpdates
            Task.detached {
                // The observer can attach after ActivityKit minted the current
                // token (notably after a simulator reinstall or cold launch).
                // The updates sequence is for rotations and is not guaranteed
                // to replay that already-current value, so seed it explicitly.
                // LiveActivityExecutor deduplicates the same token if the
                // sequence immediately yields it as well.
                if let current = Activity<Attributes>.pushToStartToken {
                    continuation.yield(current)
                }
                for await token in updates { continuation.yield(token) }
                continuation.finish()
            }
        }
    }
}
#endif

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
