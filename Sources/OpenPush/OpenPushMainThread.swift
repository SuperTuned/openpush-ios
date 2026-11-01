import Foundation

extension OpenPush {
    /// The one road every public host callback takes: observers, listeners,
    /// completions and the registration hooks all reach the host here.
    ///
    /// Always posted to the main queue, even from the main thread. A callback
    /// never runs inside the call that caused it — an observer cannot fire in
    /// the middle of `optOut()` — and because the main queue is serial, the
    /// callbacks keep the order they were posted in.
    ///
    /// Only the hop to the host moves here. Whatever the SDK does before the
    /// callback (network, storage, registration bookkeeping) stays on the
    /// thread it already ran on, and nothing ever waits on the main queue.
    ///
    /// Two deliberate exceptions do not come through here: the notification
    /// click listeners and the foreground will-present listeners. Both run
    /// inline on the thread that called `processClick` / `processForeground`,
    /// which is the `UNUserNotificationCenterDelegate` thread — main in
    /// practice. The synchronous foreground form has to return the
    /// presentation options, so it cannot hop.
    static func deliverOnMain(_ body: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    /// A host completion that delivers through `deliverOnMain` when called.
    /// `nil` stays `nil`, so an optional completion keeps its meaning.
    static func onMain<Value: Sendable>(
        _ completion: (@Sendable (Value) -> Void)?
    ) -> (@Sendable (Value) -> Void)? {
        guard let completion else { return nil }
        return { value in deliverOnMain { completion(value) } }
    }

    /// The same, for a completion that carries nothing.
    static func onMain(_ completion: (@Sendable () -> Void)?) -> (@Sendable () -> Void)? {
        guard let completion else { return nil }
        return { deliverOnMain(completion) }
    }

    static func fireRegistered() {
        let hook = state.registeredHook
        deliverOnMain { hook() }
    }

    static func fireRegistrationFailed(_ message: String) {
        let hook = state.registrationFailedHook
        deliverOnMain { hook(message) }
    }

    /// The two callbacks that stay on the delegate's thread are expected on
    /// main. Debug builds say so loudly; release builds compile this out.
    static func assertOnDelegateThread(_ entry: StaticString) {
        assert(Thread.isMainThread,
               "OpenPush: \(entry) runs host listeners inline — call it from your " +
               "UNUserNotificationCenterDelegate method on the main thread")
    }
}
