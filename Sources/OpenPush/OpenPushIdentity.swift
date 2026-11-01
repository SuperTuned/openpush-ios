import Foundation

public extension OpenPush {
    enum IdentityResult: Sendable, Equatable {
        case success
        /// The server accepted the device but stripped the identity: the install
        /// is registered and anonymous. The note explains why.
        case identityRejected(String)
        case failed(String)
    }

    /// Identify this install. If a token already exists the identity is sent
    /// immediately; otherwise it is stored and rides the next registration, so a
    /// login before the APNs token arrives is not lost.
    /// The positional compatibility form, so `login("player-9")` compiles after
    /// a migrating host replaces its old SDK's prefix with `OpenPush.`.
    static func login(_ externalId: String) {
        login(externalId: externalId)
    }

    /// Logging in again as the person already identified, with no new auth hash,
    /// sends nothing and completes `.success` — a host may call this on every
    /// launch. A rotated or still-owed hash is new proof and is always sent.
    static func login(externalId: String, authHash: String? = nil,
                      completion: (@Sendable (IdentityResult) -> Void)? = nil) {
        // The host hears the outcome on the main thread; the registration itself
        // and the identity bookkeeping in `identityResult` stay where they run.
        let completion = onMain(completion)
        guard !externalId.isEmpty else {
            let message = "login requires a non-empty external ID; use logout to detach this install"
            onLog("✗ \(message)")
            completion?(.failed(message))
            return
        }
        // One lock acquisition decides and applies: reading the identity and then
        // replacing it separately would let a concurrent login land in between.
        guard case .adopted(let switchingUsers) = state.applyLogin(externalID: externalId,
                                                                   authHash: authHash) else {
            onLog("• already logged in as \(externalId) — nothing to send")
            completion?(.success)
            return
        }
        if switchingUsers {
            onLog("• login switched users — the previous user's tags and aliases were " +
                  "cleared locally so they are not written onto \(externalId)")
        }
        guard let token = currentToken else {
            onLog("• login stored — no APNs token yet, so this identity is sent with the " +
                  "next registration")
            completion?(.success)
            return
        }
        performRegistration(token: token) { result in
            completion?(identityResult(from: result))
        }
    }

    /// Detach this install from its identified user. The next and every later
    /// registration carries an explicit empty `external_id`. An install that is
    /// not identified — never logged in, or already detached by an accepted
    /// registration — sends nothing and completes `.success`, but it still drops
    /// the tags and aliases staged onto it: a logout always leaves this install
    /// holding nobody's data.
    static func logout(completion: (@Sendable (IdentityResult) -> Void)? = nil) {
        let completion = onMain(completion)
        guard state.applyLogout() else {
            // The staged writes this just dropped must not be flushed by a window
            // that was already open for them.
            state.cancelWriteWindow()
            onLog("• logout skipped — this install is not identified, so there is " +
                  "nothing to detach; any tags and aliases staged on it were cleared")
            completion?(.success)
            return
        }
        guard let token = currentToken else {
            onLog("• logout stored — no APNs token yet, so the detach is sent with the " +
                  "next registration")
            completion?(.success)
            return
        }
        performRegistration(token: token) { result in
            completion?(identityResult(from: result))
        }
    }
}

extension OpenPush {
    static func identityResult(from result: RegistrationResult) -> IdentityResult {
        switch result {
        case .accepted(let outcome):
            guard let note = outcome.identityRejected else { return .success }
            // The device row exists, so no status code reveals this. Without a
            // loud line here a host believes its users are identified when they
            // are anonymous.
            onLog("✗ identity NOT applied — this install is still anonymous: \(note)")
            // The local identity must match: leaving it identified would have
            // `externalId` report a user the server does not know about, and would
            // re-assert the same unaccepted id on every later registration. Scoped
            // to an identified install: a rejection note on a detach or on an
            // anonymous body says nothing about an identity this install asserted,
            // and turning `.detached` into `.anonymous` would silently stop the
            // detach from being re-sent. `setIdentity` clears the owed auth hash
            // and the delivered mark with it.
            if case .identified = state.currentIdentity { state.setIdentity(.anonymous) }
            return .identityRejected(note)
        case .rejected(_, let message):
            return .failed(message)
        case .dropped(let reason):
            return .failed(reason)
        }
    }
}
