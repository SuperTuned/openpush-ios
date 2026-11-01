import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushSessionPersistenceTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    /// One boolean an off-main read can put its answer into.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool? { lock.withLock { value } }
    }

    private let clock = ManualClock()

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scratchKeys() -> (tokenKey: String, sessionKey: String) {
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        return (tokenKey, OpenPush.State.sessionKey(forTokenKey: tokenKey))
    }

    private func coldStart(tokenKey: String, appID: String = "sample",
                           _ transport: @escaping OpenPush.Transport) {
        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: appID,
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: transport)
    }

    func testTheWholeNonSecretSessionRidesTheFirstRegistrationAfterAColdStart() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }

        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_1"}"#) }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.User.addTags(["plan": "pro"])
        OpenPush.User.addAliases(["player_id": "p-1"])
        OpenPush.login(externalId: "person-7", authHash: "hash-7")
        OpenPush.PushSubscription.optOut()

        let capture = Capture()
        coldStart(tokenKey: keys.tokenKey) { request, done in
            capture.set(request)
            done(200, #"{"id":"sub_1"}"#)
        }
        OpenPush.register(token: "aabb")

        let json = try body(of: capture.get())
        XCTAssertEqual(json["tags"] as? [String: String], ["plan": "pro"])
        XCTAssertEqual(json["aliases"] as? [String: String], ["player_id": "p-1"])
        // D5: a verified identity restored without its hash is not asserted at all.
        XCTAssertFalse(json.keys.contains("external_id"))
        XCTAssertFalse(json.keys.contains("external_id_auth_hash"),
                       "an identity proof is a bearer credential and must stay memory-only")
        XCTAssertEqual(json["status"] as? Int, -2)

        let stored = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: keys.sessionKey))
        XCTAssertFalse(stored.keys.contains("authHash"))
        XCTAssertFalse(stored.keys.contains("external_id_auth_hash"))
    }

    func testALegacyOptOutMigratesWithoutResubscribingTheDevice() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        UserDefaults.standard.set(["status": -2], forKey: keys.sessionKey)
        let capture = Capture()

        coldStart(tokenKey: keys.tokenKey) { request, done in
            capture.set(request)
            done(200, #"{"id":"sub_1"}"#)
        }
        OpenPush.register(token: "aabb")

        XCTAssertEqual(try body(of: capture.get())["status"] as? Int, -2)
        let migrated = try XCTUnwrap(
            UserDefaults.standard.dictionary(forKey: keys.sessionKey))
        XCTAssertEqual(migrated["optedOut"] as? Bool, true)
        XCTAssertNil(migrated["status"])
    }

    func testWhatTheHostStagedBeforeInitializeBeatsWhatTheLastProcessStored() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, "{}") }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.User.addTags(["plan": "trial", "seats": "1"])

        OpenPush.state.resetAsIfTheProcessJustStarted()
        OpenPush.User.addTag(key: "plan", value: "pro")
        let capture = Capture()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: keys.tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        OpenPush.register(token: "aabb")

        XCTAssertEqual(try body(of: capture.get())["tags"] as? [String: String],
                       ["plan": "pro", "seats": "1"])
    }

    func testAWorkspaceSwitchClearsOldWorkspaceStateOnDiskAndInMemory() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, "{}") }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.User.addTag(key: "plan", value: "trial")
        OpenPush.login(externalId: "person-9")
        XCTAssertNotNil(UserDefaults.standard.dictionary(forKey: keys.sessionKey))

        let capture = Capture()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "other",
                                                             sdkKey: "sdk_other",
                                                             serverURL: "https://push.example",
                                                             tokenKey: keys.tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        OpenPush.register(token: "aabb")

        let json = try body(of: capture.get())
        XCTAssertFalse(json.keys.contains("tags"))
        XCTAssertFalse(json.keys.contains("external_id"))
        let persisted = UserDefaults.standard.dictionary(forKey: keys.sessionKey)
        XCTAssertNil(persisted?["tags"])
        XCTAssertNil(persisted?["identity"])
        XCTAssertEqual(persisted?["notificationTypes"] as? Int, -18)
    }

    /// A workspace switch is a switch *away* from one workspace, not a wipe of
    /// the one being entered. Hosts that give each workspace a token key of its
    /// own had every store of the incoming workspace erased on the way in: the
    /// receipts it still owed the server, the Custom Events it had queued, its
    /// session and its in-app display history all went with the workspace being
    /// left. Only the leaving workspace's keys may be removed — which is still
    /// the same blob for the hosts that keep one token key for both.
    func testAWorkspaceSwitchKeepsTheIncomingWorkspacesOwnStorage() throws {
        let leaving = scratchKeys()
        let entering = scratchKeys()
        let receiptsKey = OpenPush.ReceiptQueue.storageKey(forTokenKey: entering.tokenKey)
        let eventsKey = entering.tokenKey + ".customEvents"
        let iamKey = entering.tokenKey + ".iamState"
        defer {
            for key in [leaving.tokenKey, leaving.sessionKey, entering.tokenKey,
                        entering.sessionKey, receiptsKey, eventsKey, iamKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // What the workspace being entered left behind the last time it ran.
        UserDefaults.standard.set(["tags": ["plan": "pro"], "externalId": "person-b"],
                                  forKey: entering.sessionKey)
        UserDefaults.standard.set(#"[{"type":"iam_impression","message_id":"iam_b"}]"#,
                                  forKey: receiptsKey)
        UserDefaults.standard.set(#"[{"name":"checkout_started"}]"#, forKey: eventsKey)
        var stored = OpenPush.IamPersistedState()
        stored.dismissed = ["iam_b"]
        UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: iamKey)

        coldStart(tokenKey: leaving.tokenKey, appID: "workspace-a") { _, done in
            done(200, #"{"id":"sub_a"}"#)
        }
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "workspace-b",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: entering.tokenKey),
                        credential: { nil },
                        transport: { _, done in done(200, #"{"id":"sub_b"}"#) })

        XCTAssertEqual(UserDefaults.standard
                        .dictionary(forKey: entering.sessionKey)?["tags"] as? [String: String],
                       ["plan": "pro"],
                       "the incoming workspace's session is not the leaving one's to delete")
        XCTAssertEqual(OpenPush.ReceiptQueue.shared.pendingCount, 1,
                       "delivery evidence this workspace still owes its own server")
        XCTAssertNotNil(UserDefaults.standard.string(forKey: eventsKey),
                        "and the events it had queued are still its to send")
        let iam = try JSONDecoder().decode(
            OpenPush.IamPersistedState.self,
            from: try XCTUnwrap(UserDefaults.standard.data(forKey: iamKey)))
        XCTAssertEqual(iam.dismissed, ["iam_b"],
                       "a message this workspace's user already dismissed stays dismissed")

        // Intact on disk is only half the claim: the next launch under this
        // workspace has to read it back.
        coldStart(tokenKey: entering.tokenKey, appID: "workspace-b") { _, done in
            done(200, #"{"id":"sub_b"}"#)
        }
        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro"])
    }

    /// A background launch before the device's first unlock cannot read
    /// `UserDefaults`, so the session looks empty. Writing that back is how
    /// every tag, alias and identity on the device disappears at once.
    func testAttachBeforeFirstUnlockNeverOverwritesThePersistedSession() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, "{}") }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.User.addTags(["plan": "pro"])
        OpenPush.login(externalId: "person-7")
        let before = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: keys.sessionKey))
        XCTAssertEqual(before["tags"] as? [String: String], ["plan": "pro"])

        OpenPush.protectedDataAvailableSeam = { false }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, "{}") }

        XCTAssertTrue(OpenPush.User.getTags().isEmpty,
                      "nothing was readable, so nothing may be reported as read")
        let after = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: keys.sessionKey))
        XCTAssertEqual(after["tags"] as? [String: String], ["plan": "pro"])
        XCTAssertEqual(after["externalId"] as? String, "person-7")
        XCTAssertEqual(after["notificationTypes"] as? Int,
                       before["notificationTypes"] as? Int)

        // Still locked: a foreground or a second attach may call in at any time
        // and must not restore from a store it still cannot read.
        OpenPush.state.restorePendingSession()
        XCTAssertTrue(OpenPush.User.getTags().isEmpty)

        OpenPush.protectedDataAvailableSeam = { true }
        OpenPush.state.restorePendingSession()

        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro"])
        XCTAssertEqual(OpenPush.User.externalId, "person-7")
        // A second notification must not undo the first one's work.
        OpenPush.state.restorePendingSession()
        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro"])
    }

    /// The deferred restore runs long after the host has moved on. If it merges
    /// the blob it was holding, the person who logged in during the window
    /// inherits the previous user's tags, aliases and even their external ID.
    func testALoginInsideTheRestoreWindowIsNotGivenTheStoredUsersData() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        OpenPush.scheduler = clock.seam
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_5"}"#) }
        OpenPush.register(token: "aabb")
        OpenPush.PushSubscription.optOut()
        // No token in the store, so the login in the window defers instead of
        // registering and the assertions are about the restore alone.
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.User.addTags(["plan": "pro"])
        OpenPush.User.addAliases(["crm_id": "c-a"])
        OpenPush.login(externalId: "person-a")

        // A relaunch before the device's first unlock: the blob cannot be read.
        OpenPush.protectedDataAvailableSeam = { false }
        let capture = Capture()
        coldStart(tokenKey: keys.tokenKey) { request, done in
            capture.set(request)
            done(200, #"{"id":"sub_5"}"#)
        }
        OpenPush.login(externalId: "person-b")

        OpenPush.protectedDataAvailableSeam = { true }
        OpenPush.state.restorePendingSession()

        XCTAssertEqual(OpenPush.User.getTags(), [:],
                       "user A's tags must not be handed to user B at the unlock")
        XCTAssertEqual(OpenPush.state.aliasMap, [:])
        XCTAssertEqual(OpenPush.User.externalId, "person-b")
        // The device's own axes are not the user's and still come back.
        XCTAssertEqual(OpenPush.User.pushSubscription.id, "sub_5")
        XCTAssertFalse(OpenPush.User.pushSubscription.optedIn)

        OpenPush.register(token: "aabb")
        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "person-b")
        XCTAssertNil(json["tags"], "the next body must not write A's tags onto B")
        XCTAssertNil(json["aliases"])
        let stored = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: keys.sessionKey))
        XCTAssertNil(stored["tags"])
        XCTAssertEqual(stored["externalId"] as? String, "person-b")
    }

    func testALogoutInsideTheRestoreWindowIsNotUndoneByTheDeferredRestore() throws {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        OpenPush.scheduler = clock.seam
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_6"}"#) }
        OpenPush.state.setToken(nil, persist: true)
        OpenPush.User.addTags(["plan": "pro"])
        OpenPush.login(externalId: "person-a")

        OpenPush.protectedDataAvailableSeam = { false }
        let capture = Capture()
        coldStart(tokenKey: keys.tokenKey) { request, done in
            capture.set(request)
            done(200, #"{"id":"sub_6"}"#)
        }
        OpenPush.login(externalId: "person-b")
        OpenPush.logout()

        OpenPush.protectedDataAvailableSeam = { true }
        OpenPush.state.restorePendingSession()

        XCTAssertEqual(OpenPush.User.getTags(), [:],
                       "the detached install must not be given the stored user's tags")
        XCTAssertNil(OpenPush.User.externalId)
        XCTAssertEqual(OpenPush.state.currentIdentity, .detached,
                       "the restore may not resurrect the identity the logout detached")

        OpenPush.register(token: "aabb")
        let json = try body(of: capture.get())
        XCTAssertEqual(json["external_id"] as? String, "")
        XCTAssertNil(json["tags"])
    }

    func testTheSubscriptionIdIsKnownAtColdStartBeforeAnyRegistration() {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_77"}"#) }
        OpenPush.register(token: "aabb")

        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_77"}"#) }

        XCTAssertEqual(OpenPush.User.pushSubscription.id, "sub_77",
                       "a host reading the id at launch to hand to its backend gets it")
    }

    /// The relaunch above re-registers off the restored token, so only a
    /// response WITHOUT an id proves the value came back from storage.
    func testTheStoredSubscriptionIdIsRestoredWhenTheResponseOmitsIt() {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_77"}"#) }
        OpenPush.register(token: "aabb")

        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, "{}") }

        XCTAssertEqual(OpenPush.User.pushSubscription.id, "sub_77")
    }

    /// Reads `State.protectedDataReadable()` from a background queue and hands
    /// back what it said.
    private func readOffTheMainThread() -> Bool? {
        let answer = Answer()
        let done = expectation(description: "the reading came back from a background queue")
        DispatchQueue.global().async {
            answer.set(OpenPush.state.protectedDataReadable())
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return answer.get()
    }

    /// `UIApplication.isProtectedDataAvailable` is main-thread state, and
    /// `attach` may be called from anywhere. The property is read where that is
    /// allowed — on the main thread, and by UIKit's own protected-data
    /// notifications, which arrive there — and the answer is kept for the reads
    /// that cannot take it themselves.
    func testTheProtectedDataReadingIsTakenAndKeptOnTheMainThread() {
        OpenPush.protectedDataAvailableSeam = { false }
        XCTAssertFalse(OpenPush.state.protectedDataReadable(),
                       "on the main thread the property itself is what answers")

        // What the did-become-available notification records when it fires.
        OpenPush.state.cacheProtectedData(true)
        XCTAssertEqual(readOffTheMainThread(), true,
                       "off the main thread the notification's answer is used")

        // And the will-become-unavailable half, so the cache is a reading and
        // not a latch stuck at true for the life of the process.
        OpenPush.state.cacheProtectedData(false)
        XCTAssertEqual(readOffTheMainThread(), false)

        // A main-thread pass refreshes it again, so the cache is never staler
        // than the last read that was allowed to take one.
        OpenPush.state.cacheProtectedData(true)
        OpenPush.protectedDataAvailableSeam = { false }
        XCTAssertFalse(OpenPush.state.protectedDataReadable())
        XCTAssertEqual(readOffTheMainThread(), false,
                       "the refreshed answer is what later background reads see")
    }

    /// A new seam is a new source of truth, and the answer the previous one gave
    /// has to go with it — otherwise a test that installs one is told what the
    /// last one said.
    func testInstallingAProtectedDataSeamForgetsTheCachedReading() {
        OpenPush.state.cacheProtectedData(true)
        OpenPush.protectedDataAvailableSeam = { false }

        XCTAssertEqual(readOffTheMainThread(), false)
    }

    func testAnUncachedBackgroundReadDefersUntilTheMainThreadCanReadUIKit() {
        OpenPush.protectedDataAvailableSeam = { true }

        XCTAssertEqual(readOffTheMainThread(), false,
                       "an uncached background attach must defer instead of touching UIKit")
        XCTAssertTrue(OpenPush.state.protectedDataReadable(),
                      "the main thread can take and cache the real reading")
        XCTAssertEqual(readOffTheMainThread(), true,
                       "later background reads use the main-thread cache")
    }

    func testAWorkspaceSwitchForgetsThePersistedSubscriptionId() {
        let keys = scratchKeys()
        defer {
            UserDefaults.standard.removeObject(forKey: keys.tokenKey)
            UserDefaults.standard.removeObject(forKey: keys.sessionKey)
        }
        coldStart(tokenKey: keys.tokenKey) { _, done in done(200, #"{"id":"sub_77"}"#) }
        OpenPush.register(token: "aabb")
        XCTAssertEqual(OpenPush.User.pushSubscription.id, "sub_77")

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "other",
                                                             sdkKey: "sdk_other",
                                                             serverURL: "https://push.example",
                                                             tokenKey: keys.tokenKey),
                        credential: { nil },
                        transport: { _, done in done(200, "{}") })

        XCTAssertNil(OpenPush.User.pushSubscription.id,
                     "one workspace's subscription row must never be read as another's")
    }

    /// A workspace switch before the device's first unlock reads the same
    /// unreadable store a launch does. If the restore is not armed there, the
    /// attach goes on to sync notification types and that first write replaces
    /// the incoming workspace's session with an empty one.
    func testAWorkspaceSwitchBeforeFirstUnlockDefersTheIncomingRestore() throws {
        let leaving = scratchKeys()
        let entering = scratchKeys()
        defer {
            for key in [leaving.tokenKey, leaving.sessionKey,
                        entering.tokenKey, entering.sessionKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // What the workspace being entered stored the last time it ran.
        UserDefaults.standard.set(["tags": ["plan": "pro"], "externalId": "person-b",
                                   "identity": "identified"],
                                  forKey: entering.sessionKey)
        let before = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: entering.sessionKey))

        OpenPush.protectedDataAvailableSeam = { false }
        coldStart(tokenKey: leaving.tokenKey, appID: "workspace-a") { _, done in
            done(200, "{}")
        }
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "workspace-b",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: entering.tokenKey),
                        credential: { nil },
                        transport: { _, done in done(200, "{}") })

        XCTAssertTrue(OpenPush.User.getTags().isEmpty,
                      "nothing was readable, so nothing may be reported as read")
        let after = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: entering.sessionKey))
        XCTAssertEqual(after["tags"] as? [String: String],
                       before["tags"] as? [String: String],
                       "the incoming workspace's session survives an attach that could not read it")
        XCTAssertEqual(after["externalId"] as? String, before["externalId"] as? String)
        XCTAssertNil(after["notificationTypes"],
                     "and no empty session was written over it")

        OpenPush.protectedDataAvailableSeam = { true }
        OpenPush.state.restorePendingSession()

        XCTAssertEqual(OpenPush.User.getTags(), ["plan": "pro"],
                       "the deferred restore reads the workspace the host is in now")
        XCTAssertEqual(OpenPush.User.externalId, "person-b")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
