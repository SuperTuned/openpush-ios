import Foundation
import UserNotifications
import OpenPushCore

public extension OpenPush {
    /// A snapshot of this install's push subscription. `id` is the row the server
    /// returned from the last accepted registration, so it is `nil` until one
    /// succeeds.
    struct PushSubscriptionState: Sendable, Equatable {
        public let id: String?
        public let token: String?
        public let optedIn: Bool
        /// This install's current `notification_types` value. It is always
        /// populated, while remaining optional for source compatibility.
        public let status: Int?

        public init(id: String?, token: String?, optedIn: Bool, status: Int? = nil) {
            self.id = id
            self.token = token
            self.optedIn = optedIn
            self.status = status
        }
    }
}

public extension OpenPush {
    /// One JSON value from a notification payload, nesting intact.
    typealias JSONValue = OpenPushJSONValue

    /// A notification as it arrived, parsed into named fields. Note that inside
    /// any `extension OpenPush` the bare name `Notification` now means this type
    /// rather than Foundation's — spell that one `Foundation.Notification`.
    typealias Notification = OpenPushNotification

    /// A notification the user opened. `notification` is the whole payload with
    /// its nesting intact; `payload` is the old string-coerced top level.
    struct ClickEvent: Sendable {
        public let messageId: String?
        public let notification: OpenPush.Notification
        public let actionId: String?
        /// The tapped button's own link (its `url` in the composer), when the tap
        /// was on an action button that has one. nil for the default open, and for
        /// a button without a link.
        public let actionURL: URL?
        /// True when the SDK opened a URL for this tap itself, because
        /// `OpenPush.Notifications.openLaunchURLs` is on. The open happens right
        /// after the click listeners are told, so a listener that routes the URL
        /// itself should skip it when this is true. Always false with the setting
        /// off (it is on by default).
        public let launchURLOpened: Bool
        private let stringPayload: [String: String]

        /// The top level of the APNs `userInfo`, coerced to strings.
        @available(*, deprecated, message: "Use notification.additionalData or notification.rawPayload")
        public var payload: [String: String] { stringPayload }

        init(messageId: String?, payload: [String: String], actionId: String?,
             notification: OpenPush.Notification, launchURLOpened: Bool = false) {
            self.messageId = messageId
            self.stringPayload = payload
            self.actionId = actionId
            self.notification = notification
            self.launchURLOpened = launchURLOpened
            self.actionURL = actionId.flatMap { id in
                notification.actions.first { $0.id == id }?.url
            }
        }
    }

    /// A notification that arrived while the app was in the foreground. Listeners
    /// run synchronously inside `processForeground`, which is why this is a class:
    /// `preventDefault` has to be visible to the caller by the time it returns.
    final class ForegroundEvent: @unchecked Sendable {
        public let messageId: String?
        public let notification: OpenPush.Notification
        private let stringPayload: [String: String]
        private let lock = NSLock()
        private var prevented = false
        private var displayRequested = false
        /// Whether the asynchronous path's completion handler has already run.
        /// Exactly one of `display()` and the timeout may run it.
        private var settled = false
        private var deferredCompletion:
            (@Sendable (UNNotificationPresentationOptions) -> Void)?
        private var deferredPresentation: UNNotificationPresentationOptions = []
        private var deferredTimeout: OpenPush.ScheduledWork?

        /// The top level of the APNs `userInfo`, coerced to strings.
        @available(*, deprecated, message: "Use notification.additionalData or notification.rawPayload")
        public var payload: [String: String] { stringPayload }

        init(messageId: String?, payload: [String: String],
             notification: OpenPush.Notification) {
            self.messageId = messageId
            self.stringPayload = payload
            self.notification = notification
        }

        /// Suppress the system presentation for this notification. The host then
        /// owns whatever in-app presentation it shows instead.
        public func preventDefault() { lock.withLock { prevented = true } }

        /// Change your mind: present the notification after all, having called
        /// `preventDefault()`. Use it when the in-app surface you meant to show
        /// instead could not be shown, so the notification is not simply lost.
        ///
        /// Only the asynchronous
        /// `OpenPush.Notifications.processForeground(_:completion:)` can honor
        /// this. The synchronous `processForeground(_:)` has already returned its
        /// answer to iOS by the time a listener could call `display()`, so there
        /// it does nothing. It also does nothing without a preceding
        /// `preventDefault()`, after the deferral window has expired, or on a
        /// second call: the delegate's completion handler runs exactly once.
        public func display() {
            let resume: (@Sendable (UNNotificationPresentationOptions) -> Void,
                         UNNotificationPresentationOptions)? = lock.withLock {
                guard prevented, !displayRequested, !settled else { return nil }
                displayRequested = true
                guard let completion = deferredCompletion else { return nil }
                settled = true
                deferredCompletion = nil
                deferredTimeout?.cancel()
                deferredTimeout = nil
                return (completion, deferredPresentation)
            }
            // Never under the lock: this is iOS's completion handler by way of the
            // host's delegate, and what it does next is not ours to reason about.
            guard let resume else { return }
            resume.0(resume.1)
        }

        var isPrevented: Bool { lock.withLock { prevented } }

        /// Hand the asynchronous path's completion handler to the event, to be
        /// run when `display()` is called or the deferral times out. Returns
        /// `true` when the answer is now held and the caller should arm that
        /// timeout, `false` when a listener already called `display()` — in which
        /// case the completion handler has been run here.
        func holdDecision(
            presenting presentation: UNNotificationPresentationOptions,
            completion: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
        ) -> Bool {
            let alreadyRequested: Bool = lock.withLock {
                if displayRequested {
                    settled = true
                    return true
                }
                deferredCompletion = completion
                deferredPresentation = presentation
                return false
            }
            guard !alreadyRequested else {
                completion(presentation)
                return false
            }
            return true
        }

        /// Keep the timeout handle so `display()` can cancel it. A `display()`
        /// that landed while the timer was being scheduled leaves nothing to
        /// cancel, so the handle is retired here instead.
        func holdTimeout(_ work: OpenPush.ScheduledWork) {
            let stale: Bool = lock.withLock {
                guard !settled else { return true }
                deferredTimeout = work
                return false
            }
            if stale { work.cancel() }
        }

        /// The host never called `display()`: honor the `preventDefault()`.
        /// Returns whether this call is the one that answered, so the caller can
        /// report the expiry without reporting it against a `display()` that won
        /// the race between the timer firing and this check.
        @discardableResult
        func deferredDecisionTimedOut() -> Bool {
            let completion: (@Sendable (UNNotificationPresentationOptions) -> Void)? =
                lock.withLock {
                    guard !settled, let pending = deferredCompletion else { return nil }
                    settled = true
                    deferredCompletion = nil
                    deferredTimeout = nil
                    return pending
                }
            guard let completion else { return false }
            completion([])
            return true
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
