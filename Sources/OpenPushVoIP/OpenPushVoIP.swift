import Foundation
import OpenPushCore
@_spi(OpenPushVoIP) import OpenPush
#if canImport(PushKit) && os(iOS)
import PushKit
import UIKit
#endif

/// VoIP pushes for calling apps: PushKit registration, the VoIP token kept on the
/// server against this device's push subscription, and incoming VoIP pushes
/// handed to the app.
///
/// It is its own product so an app without calls never links PushKit.
///
/// ```swift
/// import OpenPushVoIP
///
/// OpenPushVoIP.start { push, completion in
///     // Report the call to CallKit before returning — every time.
///     callProvider.reportNewIncomingCall(with: UUID(), update: update(for: push)) { _ in
///         completion()
///     }
/// }
/// ```
///
/// **iOS requires every VoIP push to be reported to CallKit.** From iOS 13 an app
/// that receives a VoIP push and does not call
/// `CXProvider.reportNewIncomingCall(with:update:completion:)` before the
/// handler returns is terminated, and after repeated failures iOS stops
/// delivering VoIP pushes to it at all. Send a VoIP push only for an incoming
/// call; use a regular or background push for everything else.
public enum OpenPushVoIP {
    /// One VoIP push as it arrived.
    public struct Push: Sendable, Equatable {
        /// The OpenPush message id (`op_message_id`), when the push carries one.
        public let messageId: String?
        /// The `data` the sender passed: every top-level key that is not `aps` and
        /// not `op_`-prefixed, nesting intact.
        public let data: [String: OpenPushJSONValue]
        /// The whole payload, nesting intact.
        public let rawPayload: [String: OpenPushJSONValue]

        public init(payload: [AnyHashable: Any]) {
            let raw = OpenPushJSONValue(payload)?.objectValue ?? [:]
            rawPayload = raw
            messageId = OpenPushPayload.messageID(from: payload)
            data = raw.filter { key, _ in key != "aps" && !key.hasPrefix("op_") }
        }

        /// True when OpenPush sent it (`op_voip` is `"1"`).
        public var isOpenPush: Bool { rawPayload["op_voip"]?.stringValue == "1" }
    }

    /// Called for every incoming VoIP push, on the main queue, with the push and
    /// PushKit's completion. Report the call to CallKit, then call `completion`.
    public typealias Handler = @Sendable (_ push: Push,
                                          _ completion: @escaping @Sendable () -> Void) -> Void

    /// Registers for VoIP pushes and starts keeping the VoIP token on the server.
    ///
    /// The token is posted with this device's push subscription id once both are
    /// known, and posted again whenever either changes, so call it once at launch;
    /// it may come before or after `OpenPush.initialize`. Calling it again replaces
    /// the handler. Each incoming VoIP push is handed to `handler`.
    public static func start(handler: @escaping Handler) {
        registrar.start(handler: handler)
        registrar.pushKit.register()
    }

    /// Stops VoIP pushes: unregisters from PushKit and removes the VoIP token from
    /// the server, so no further VoIP push is sent to this device.
    public static func stop() {
        registrar.stop()
        registrar.pushKit.unregister()
    }

    /// The current PushKit VoIP token, hex-encoded, or nil before PushKit has
    /// issued one.
    public static var token: String? { registrar.currentToken }

    /// Whether `start` has been called without a later `stop`.
    public static var isStarted: Bool { registrar.isStarted }

    static let registrar = Registrar()
}

extension OpenPushVoIP {
    /// The token's life on the server, kept apart from PushKit so it can be driven
    /// directly: a token and a subscription id arrive in either order, and the pair
    /// is posted once both are known and whenever either changes.
    final class Registrar: @unchecked Sendable {
        /// The PushKit side, behind a seam: a real `PKPushRegistry` in a
        /// bundle-less test process on a Simulator destination is not something a
        /// unit test can stand behind.
        struct PushKitSeam: Sendable {
            var register: @Sendable () -> Void
            var unregister: @Sendable () -> Void

            static let system = PushKitSeam(
                register: {
                    #if canImport(PushKit) && os(iOS)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { PushKitBridge.shared.register() }
                    }
                    #endif
                },
                unregister: {
                    #if canImport(PushKit) && os(iOS)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { PushKitBridge.shared.unregister() }
                    }
                    #endif
                })
        }

        private var pushKitSeam = PushKitSeam.system
        var pushKit: PushKitSeam {
            get { lock.lock(); defer { lock.unlock() }; return pushKitSeam }
            set { lock.lock(); pushKitSeam = newValue; lock.unlock() }
        }

        /// What the server last accepted, so an unchanged pair is not re-posted.
        struct Registration: Equatable {
            let appID: String
            let subscriptionID: String
            let token: String
        }

        private let lock = NSLock()
        private var handler: Handler?
        private var token: String?
        private var observer: UUID?
        private var registered: Registration?
        private var inFlight: Registration?

        var currentToken: String? { lock.lock(); defer { lock.unlock() }; return token }
        var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }
        var lastRegistration: Registration? {
            lock.lock(); defer { lock.unlock() }; return registered
        }

        func start(handler: @escaping Handler) {
            lock.lock()
            self.handler = handler
            let needsObserver = observer == nil
            lock.unlock()
            if needsObserver {
                // A new subscription id — a first registration, a workspace switch —
                // means the server has no VoIP token for this device yet.
                let id = OpenPush.PushSubscription.addObserver { [weak self] _ in self?.sync() }
                lock.lock(); observer = id; lock.unlock()
            }
            sync()
        }

        func stop() {
            let appID = OpenPush.voipAppID
            let subscriptionID = OpenPush.User.pushSubscription.id
            lock.lock()
            let id = observer
            // What the server holds: what it accepted, what it is being sent, or —
            // when a failed post left neither — the pair this launch would post,
            // since an earlier launch may have registered it.
            var posted = registered ?? inFlight
            if posted == nil, let appID, let subscriptionID, let token {
                posted = Registration(appID: appID, subscriptionID: subscriptionID, token: token)
            }
            observer = nil
            handler = nil
            registered = nil
            inFlight = nil
            lock.unlock()
            if let id { OpenPush.PushSubscription.removeObserver(id) }
            if let posted { remove(posted) }
        }

        /// PushKit issued or rotated the token.
        func didUpdate(token data: Data) {
            let hex = OpenPush.hexToken(data)
            lock.lock(); token = hex; lock.unlock()
            sync()
        }

        /// PushKit withdrew the token: it no longer reaches this device.
        func didInvalidateToken() {
            lock.lock()
            let posted = registered
            token = nil
            registered = nil
            lock.unlock()
            if let posted { remove(posted) }
        }

        /// Hands an incoming push to the app's handler. With no handler — `stop`
        /// raced the push — there is nobody to report the call, so the completion
        /// is called at once and the miss is logged.
        func didReceive(payload: [AnyHashable: Any], completion: @escaping @Sendable () -> Void) {
            lock.lock(); let handler = handler; lock.unlock()
            let push = Push(payload: payload)
            guard let handler else {
                OpenPush.onLog("✗ VoIP push \(push.messageId ?? "without a message id") arrived " +
                               "with no handler — OpenPushVoIP.start was not called or was " +
                               "stopped; iOS requires every VoIP push to be reported to CallKit")
                completion()
                return
            }
            handler(push, completion)
        }

        /// Posts the token when a token, a subscription id and a configuration are
        /// all known and that pair is not what the server already holds.
        func sync() {
            guard let appID = OpenPush.voipAppID,
                  let subscriptionID = OpenPush.User.pushSubscription.id else { return }
            let next: Registration? = {
                lock.lock(); defer { lock.unlock() }
                guard handler != nil, let token else { return nil }
                let candidate = Registration(appID: appID, subscriptionID: subscriptionID,
                                             token: token)
                guard candidate != registered, candidate != inFlight else { return nil }
                inFlight = candidate
                return candidate
            }()
            guard let next else { return }
            let body: [String: Any] = ["subscription_id": next.subscriptionID,
                                       "token": next.token,
                                       "sandbox": OpenPush.voipSandbox]
            OpenPush.voipPost("/v1/apps/\(next.appID)/voip-tokens", body: body) { [weak self] code, response in
                self?.settle(next, accepted: (200...299).contains(code))
                if (200...299).contains(code) {
                    OpenPush.onLog("✓ VoIP token registered for subscription \(next.subscriptionID)")
                } else {
                    OpenPush.onLog("✗ VoIP token not registered (\(code)): \(response.prefix(160)) " +
                                   "— retried when the app next comes forward or the subscription changes")
                }
            }
        }

        private func settle(_ registration: Registration, accepted: Bool) {
            lock.lock()
            if inFlight == registration { inFlight = nil }
            // A stop or a newer token while the request was out wins over it.
            if accepted, handler != nil, token == registration.token { registered = registration }
            lock.unlock()
        }

        private func remove(_ registration: Registration) {
            let body: [String: Any] = ["subscription_id": registration.subscriptionID,
                                       "token": registration.token]
            OpenPush.voipPost("/v1/apps/\(registration.appID)/voip-tokens/remove",
                              body: body) { code, response in
                if (200...299).contains(code) {
                    OpenPush.onLog("✓ VoIP token removed for subscription \(registration.subscriptionID)")
                } else {
                    OpenPush.onLog("✗ VoIP token not removed (\(code)): \(response.prefix(160))")
                }
            }
        }

        func resetForTests() {
            lock.lock()
            let id = observer
            handler = nil
            token = nil
            observer = nil
            registered = nil
            inFlight = nil
            lock.unlock()
            if let id { OpenPush.PushSubscription.removeObserver(id) }
        }
    }
}

#if canImport(PushKit) && os(iOS)
/// PushKit's delegate. The registry is created on the main queue and delivers
/// there, which is where the handler runs.
@MainActor
final class PushKitBridge: NSObject, PKPushRegistryDelegate {
    static let shared = PushKitBridge()
    private var registry: PKPushRegistry?

    private var foregroundObserver: NSObjectProtocol?

    func register() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        // A post that failed is tried again each time the app comes forward.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in OpenPushVoIP.registrar.sync() }
    }

    func unregister() {
        registry?.desiredPushTypes = []
        registry?.delegate = nil
        registry = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didUpdate pushCredentials: PKPushCredentials,
                                  for type: PKPushType) {
        guard type == .voIP else { return }
        OpenPushVoIP.registrar.didUpdate(token: pushCredentials.token)
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        OpenPushVoIP.registrar.didInvalidateToken()
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType,
                                  completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let box = CompletionBox(completion)
        OpenPushVoIP.registrar.didReceive(payload: payload.dictionaryPayload) { box.call() }
    }
}

/// PushKit's completion is not `Sendable`; it is called once, from whichever
/// thread the app's handler finishes on, which PushKit allows.
private final class CompletionBox: @unchecked Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() { completion() }
}
#endif
