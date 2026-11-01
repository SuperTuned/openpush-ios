import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension OpenPush {
    /// Fixed window measured from the first unflushed tag or alias write.
    static let writeCoalescingWindow = 0.3

    /// Keeps the process alive across one request that was started as the app was
    /// being backgrounded. Without it iOS may suspend the process mid-flight and
    /// the pending tag and alias writes are lost until the next launch.
    ///
    /// A struct of two closures rather than a direct UIKit call so the macOS test
    /// host compiles and so tests can watch begin/end pairing.
    struct BackgroundAssertion: Sendable {
        /// Opaque, so callers cannot invent one or arithmetic their way onto
        /// someone else's task.
        struct Handle: Sendable, Hashable {
            let raw: Int
        }

        var begin: @Sendable (_ name: String) -> Handle
        var end: @Sendable (_ handle: Handle) -> Void

        #if canImport(UIKit)
        static let system = BackgroundAssertion(
            begin: { UIKitBackgroundAssertions.shared.begin(name: $0) },
            end: { UIKitBackgroundAssertions.shared.end($0) })
        #else
        static let system = BackgroundAssertion(
            begin: { _ in NoopBackgroundAssertions.shared.next() },
            end: { _ in })
        #endif
    }

    #if !canImport(UIKit)
    /// Handles still have to be unique on a platform with no background tasks,
    /// so a test that pairs them is testing the same thing everywhere.
    final class NoopBackgroundAssertions: @unchecked Sendable {
        static let shared = NoopBackgroundAssertions()
        private let lock = NSLock()
        private var counter = 0

        func next() -> BackgroundAssertion.Handle {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            return BackgroundAssertion.Handle(raw: counter)
        }
    }
    #endif

    #if canImport(UIKit)
    /// Owns the mapping from our handles to UIKit's identifiers, and guarantees
    /// each identifier is ended exactly once — whether the work finished or the
    /// expiration handler fired first. Ending twice, or never, both crash the app
    /// under the watchdog.
    final class UIKitBackgroundAssertions: @unchecked Sendable {
        static let shared = UIKitBackgroundAssertions()
        private let lock = NSLock()
        /// A handle mapped to `.invalid` is one whose `beginBackgroundTask` call
        /// has not returned yet. It reserves the slot so an expiration that fires
        /// during the call still claims the handle.
        private var live: [BackgroundAssertion.Handle: UIBackgroundTaskIdentifier] = [:]
        private var counter = 0

        func begin(name: String) -> BackgroundAssertion.Handle {
            let handle: BackgroundAssertion.Handle = withLock {
                counter += 1
                let handle = BackgroundAssertion.Handle(raw: counter)
                live[handle] = .invalid
                return handle
            }
            onMain { [weak self] in
                self?.beginUIKitTask(name: name, handle: handle)
            }
            return handle
        }

        @MainActor
        private func beginUIKitTask(name: String, handle: BackgroundAssertion.Handle) {
            let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                [weak self] in self?.end(handle)
            }
            let strayIdentifier: UIBackgroundTaskIdentifier? = withLock {
                guard live[handle] != nil else {
                    // The expiration handler already claimed the handle while the
                    // call was in flight; this identifier is ours to end.
                    return identifier == .invalid ? nil : identifier
                }
                if identifier == .invalid {
                    // The system refused the assertion. Nothing to end later.
                    live.removeValue(forKey: handle)
                    return nil
                }
                live[handle] = identifier
                return nil
            }
            if let strayIdentifier {
                UIApplication.shared.endBackgroundTask(strayIdentifier)
            }
        }

        func end(_ handle: BackgroundAssertion.Handle) {
            let identifier: UIBackgroundTaskIdentifier? = withLock {
                guard let identifier = live.removeValue(forKey: handle) else { return nil }
                return identifier == .invalid ? nil : identifier
            }
            guard let identifier else { return }
            onMain {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }

        private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(body)
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated(body)
                }
            }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }
    }
    #endif

    static func coalesceWrite(heldNote: String) {
        guard currentToken != nil else {
            onLog("• \(heldNote) stored — no APNs token yet, so they are sent with the " +
                  "next registration")
            return
        }
        let opened = state.scheduleWriteFlush(after: writeCoalescingWindow) {
            guard let token = currentToken else { return }
            performRegistration(token: token) {
                _ = identityResult(from: $0)
            }
        }
        if !opened {
            onLog("• \(heldNote) joined the open write window — one registration carries " +
                  "them all")
        }
    }

    static func flushPendingWritesOnBackground() {
        // Claimed before the check: by the time this runs the app is already on its
        // way out, and the window read plus the request have to sit inside one
        // assertion or the suspension can land between them.
        let assertion = backgroundAssertion
        let handle = assertion.begin("openpush.flush")
        guard state.hasOpenWriteWindow, let token = currentToken else {
            assertion.end(handle)
            return
        }
        onLog("• app backgrounded — sending the pending tag and alias writes now")
        performRegistration(token: token) { result in
            _ = identityResult(from: result)
            assertion.end(handle)
        }
    }

    #if canImport(UIKit)
    /// NotificationCenter's opaque observer token is immutable after registration,
    /// but Objective-C does not declare it Sendable. Keep it inside a lifetime-only
    /// box so Swift 6 can safely share the one process-wide observer.
    private final class BackgroundObserver: @unchecked Sendable {
        let token: NSObjectProtocol

        init() {
            token = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil) { _ in
                    flushPendingWritesOnBackground()
                    recordSessionDurationOnBackground()
                    InAppMessages.onAppBackgrounded()
                }
        }

        deinit { NotificationCenter.default.removeObserver(token) }
    }

    private static let backgroundObserver = BackgroundObserver()

    static func observeBackgrounding() { _ = backgroundObserver }
    #else
    static func observeBackgrounding() {}
    #endif
}
