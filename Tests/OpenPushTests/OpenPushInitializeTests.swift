import XCTest
@testable import OpenPush
import OpenPushCore

final class OpenPushInitializeTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A host may tag, alias, or identify before `initialize` — the SDK answers each
    /// with "stored — … sent with the next registration". `attach` reset those maps,
    /// so on the very first attach that promise was a lie.
    func testStateStoredBeforeTheFirstAttachRidesTheFirstRegistration() throws {
        let capture = Capture()
        OpenPush.state.resetAsIfTheProcessJustStarted()

        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        OpenPush.User.addTag(key: "plan", value: "trial")
        OpenPush.User.addAlias(label: "player_id", id: "p-1042")
        OpenPush.login(externalId: "player-9")
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        OpenPush.register(token: "aabb")

        let json = try body(of: capture.get())
        XCTAssertEqual(json["tags"] as? [String: String], ["plan": "trial"])
        XCTAssertEqual(json["aliases"] as? [String: String], ["player_id": "p-1042"])
        XCTAssertEqual(json["external_id"] as? String, "player-9")
    }

    func testAnOptOutBeforeTheFirstAttachRidesTheFirstRegistration() throws {
        let capture = Capture()
        OpenPush.state.resetAsIfTheProcessJustStarted()

        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        OpenPush.PushSubscription.optOut()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        OpenPush.register(token: "aabb")

        // optOut() answers "stored" and now survives a relaunch as well as riding
        // the next registration. Losing it would resume pushes for someone who
        // asked us to stop.
        XCTAssertEqual(try body(of: capture.get())["status"] as? Int, -2)
    }

    func testASecondAttachClearsSessionStateBecauseItIsAWorkspaceSwitch() throws {
        let capture = Capture()
        OpenPush.state.resetAsIfTheProcessJustStarted()
        let tokenKey = "openpush.test.\(UUID().uuidString)"
        let sessionKey = OpenPush.State.sessionKey(forTokenKey: tokenKey)
        defer {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        OpenPush.User.addTag(key: "plan", value: "trial")
        OpenPush.User.addAlias(label: "player_id", id: "p-1042")
        OpenPush.login(externalId: "player-9")
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "sample",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        OpenPush.register(token: "aabb")
        XCTAssertEqual(try body(of: capture.get())["tags"] as? [String: String],
                       ["plan": "trial"])

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "other",
                                                             sdkKey: "sdk_other",
                                                             serverURL: "https://push.example",
                                                             tokenKey: tokenKey),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        OpenPush.register(token: "aabb")

        let json = try body(of: capture.get())
        XCTAssertFalse(json.keys.contains("tags"),
                       "a later attach is a workspace switch; tags must not cross into it")
        XCTAssertFalse(json.keys.contains("aliases"))
        XCTAssertFalse(json.keys.contains("external_id"),
                       "carrying an identity into another workspace would be a data leak")
        let persisted = UserDefaults.standard.dictionary(forKey: sessionKey)
        XCTAssertNil(persisted?["tags"])
        XCTAssertNil(persisted?["aliases"])
        XCTAssertNil(persisted?["identity"])
        XCTAssertEqual(persisted?["notificationTypes"] as? Int, -18,
                       "the new workspace immediately persists its own device state")
    }

    func testInitializeDefaultsToTheOpenPushServerAndRegistersThroughIt() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            transport: { request, done in capture.set(request); done(201, "{}") })

        OpenPush.register(token: "aabb")

        XCTAssertEqual(OpenPush.defaultServerURL, "https://app.openpush.ai")
        XCTAssertEqual(OpenPush.defaultServerURL, OpenPushConfiguration.defaultServerURL)
        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.absoluteString,
                       "https://app.openpush.ai/v1/apps/sample/subscriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-OP-Device-Key"),
                     "initialize defaults to no device credential")
    }

    func testInitializeAcceptsAnExplicitServerAndCredential() throws {
        let capture = Capture()
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            credential: { "opdev_secret" },
                            transport: { request, done in capture.set(request); done(201, "{}") })

        OpenPush.register(token: "aabb")

        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/subscriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-Device-Key"), "opdev_secret")
    }

    func testInitializeAttachesAndRegistersThroughTheFlatArgumentList() throws {
        let capture = Capture()

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                             transport: { request, done in
                                 capture.set(request)
                                 done(201, "{}")
                             })
        OpenPush.register(token: "aabb")

        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.absoluteString,
                       "https://push.example/v1/apps/sample/subscriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk_public")
    }

    func testRegistrationResponseYieldsTheSubscriptionIdentifier() {
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in
                                done(201, #"{"id":"sub_123","external_id":null}"#)
                            })

        OpenPush.register(token: "aabb")

        XCTAssertEqual(OpenPush.state.currentSubscriptionID, "sub_123")
    }

    func testNumericSubscriptionIdentifierIsAccepted() {
        XCTAssertEqual(OpenPush.parseRegistration(#"{"id":4210}"#).subscriptionID, "4210")
    }

    func testIdentityRejectionNoteIsParsedFromTheResponse() {
        XCTAssertEqual(
            OpenPush.parseRegistration(
                #"{"id":"sub_1","identity_rejected":"external_id_auth_hash did not verify"}"#
            ).identityRejected,
            "external_id_auth_hash did not verify")
        XCTAssertEqual(
            OpenPush.parseRegistration(#"{"id":"sub_1","identity_rejected":true}"#).identityRejected,
            "the server did not apply this external ID")
        XCTAssertEqual(
            OpenPush.parseRegistration(
                #"{"identity_rejected":{"reason":"identity verification is required"}}"#
            ).identityRejected,
            "identity verification is required")
        XCTAssertNil(OpenPush.parseRegistration(#"{"id":"sub_1"}"#).identityRejected)
        XCTAssertNil(OpenPush.parseRegistration("not json at all").subscriptionID)
    }

    /// D9: a Notification Service Extension cannot read the app's UserDefaults or
    /// its Info.plist. With an App Group configured, the non-secret configuration,
    /// the APNs token and the subscription id are mirrored where the extension can
    /// read them. The device credential is never among them.
    func testAnAppGroupMirrorsTheNonSecretConfigurationAndToken() {
        let group = "openpush.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: group)?.removePersistentDomain(forName: group) }

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            appGroup: group,
                            credential: { "opdev_secret" },
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.register(token: "aabb")

        XCTAssertEqual(OpenPushSharedState.load(appGroup: group),
                       OpenPushSharedState(appID: "sample",
                                           serverURL: "https://push.example",
                                           sdkKey: "sdk_public",
                                           token: "aabb",
                                           subscriptionID: "sub_1",
                                           appGroup: group))
        let mirrored = UserDefaults(suiteName: group)?.dictionaryRepresentation() ?? [:]
        XCTAssertFalse(mirrored.values.contains { ($0 as? String) == "opdev_secret" },
                       "the device credential is never mirrored")
    }

    /// A wrapper install's extension has to identify itself too, and the App Group
    /// is the only channel between the two processes.
    func testTheAppGroupMirrorCarriesTheWrapper() {
        let group = "openpush.tests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: group)?.removePersistentDomain(forName: group)
            OpenPush.wrapper = nil
        }
        OpenPush.wrapper = OpenPush.SDKWrapper(name: "unity", version: "1.1.4")

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            appGroup: group,
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.register(token: "aabb")

        XCTAssertEqual(OpenPushSharedState.load(appGroup: group)?.sdkWrapper, "unity/1.1.4")
    }

    /// A workspace switch must not leave the previous workspace's app id, SDK key,
    /// token and subscription id readable by every extension that still has the old
    /// group in its entitlements.
    func testAWorkspaceSwitchClearsThePreviousAppGroupMirror() {
        let groupA = "openpush.tests.a.\(UUID().uuidString)"
        let groupB = "openpush.tests.b.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: groupA)?.removePersistentDomain(forName: groupA)
            UserDefaults(suiteName: groupB)?.removePersistentDomain(forName: groupB)
        }

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            appGroup: groupA,
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.register(token: "aabb")
        XCTAssertNotNil(OpenPushSharedState.load(appGroup: groupA))

        OpenPush.initialize(appId: "other", sdkKey: "sdk_other",
                            serverURL: "https://push.example",
                            appGroup: groupB,
                            transport: { _, done in done(200, #"{"id":"sub_2"}"#) })
        OpenPush.register(token: "ccdd")

        XCTAssertNil(OpenPushSharedState.load(appGroup: groupA),
                     "the previous workspace's mirror is gone")
        let leftBehind = (UserDefaults(suiteName: groupA)?.dictionaryRepresentation() ?? [:])
            .keys.filter { $0.hasPrefix(OpenPushSharedState.keyPrefix) }
        XCTAssertEqual(leftBehind, [], "no openpush.shared.* key survives the switch")
        XCTAssertEqual(OpenPushSharedState.load(appGroup: groupB),
                       OpenPushSharedState(appID: "other",
                                           serverURL: "https://push.example",
                                           sdkKey: "sdk_other",
                                           token: "ccdd",
                                           subscriptionID: "sub_2",
                                           appGroup: groupB))
    }

    func testNoAppGroupMeansNothingIsMirrored() {
        let group = "openpush.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: group)?.removePersistentDomain(forName: group) }

        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.register(token: "aabb")

        XCTAssertNil(OpenPushSharedState.load(appGroup: group))
    }

    func testResponseLoggingStaysBoundedWhileParsingSeesTheWholeBody() {
        let padding = String(repeating: "x", count: 400)
        let response = #"{"note":"\#(padding)","id":"sub_77"}"#

        XCTAssertLessThanOrEqual(OpenPush.boundedLog(response).count, 161,
                                 "diagnostic logs stay bounded")
        XCTAssertEqual(OpenPush.parseRegistration(response).subscriptionID, "sub_77",
                       "parsing must not be limited by the log budget")
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private final class StringCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String) { lock.withLock { value = newValue } }
        func get() -> String? { lock.withLock { value } }
    }

    /// D12. An app id with a space in it builds a URL the server can only reject,
    /// and the SDK would spend the whole session retrying it. A copy-pasted
    /// placeholder is legal but almost certainly wrong, so it is said out loud
    /// once rather than refused.
    func testAnAppIdWithWhitespaceIsRefused() {
        OpenPush.state.resetAsIfTheProcessJustStarted()
        let log = LogCapture()
        let failure = StringCapture()
        OpenPush.onLog = { log.add($0) }
        OpenPush.onRegistrationFailed = { failure.set($0) }

        let capture = Capture()
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "my app",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example"),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })

        XCTAssertFalse(OpenPush.isInitialized,
                       "a refused app id must leave the SDK unconfigured, not half-set-up")
        XCTAssertNil(capture.get(), "nothing reaches the network on a refused app id")
        waitForMainQueue()
        XCTAssertNotNil(failure.get(),
                        "the host learns from onRegistrationFailed, not from the console")
        XCTAssertTrue(log.joined().contains("app id"), log.joined())

        OpenPush.attach(configuration: OpenPushConfiguration(appID: "   ",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example"),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        XCTAssertFalse(OpenPush.isInitialized, "an empty app id is refused too")

        // A placeholder is a warning, not a refusal: a self-hosted install may
        // legitimately name an app anything at all.
        let placeholder = LogCapture()
        OpenPush.onLog = { placeholder.add($0) }
        OpenPush.attach(configuration: OpenPushConfiguration(appID: "replace-with-your-app-id",
                                                             sdkKey: "sdk_public",
                                                             serverURL: "https://push.example"),
                        credential: { nil },
                        transport: { request, done in capture.set(request); done(200, "{}") })
        XCTAssertTrue(OpenPush.isInitialized, "a placeholder app id still attaches")
        XCTAssertTrue(placeholder.joined().contains("placeholder"), placeholder.joined())
    }

    /// An app id is spliced straight into every path, so a `/` or a `?` does not
    /// fail — it retargets, addressing another route or adding a query of its own.
    func testAnAppIdWithPathCharactersIsRefused() {
        for appID in ["my/app", "app?debug=1"] {
            OpenPush.state.resetAsIfTheProcessJustStarted()
            let log = LogCapture()
            let failure = StringCapture()
            OpenPush.onLog = { log.add($0) }
            OpenPush.onRegistrationFailed = { failure.set($0) }

            let capture = Capture()
            OpenPush.attach(configuration: OpenPushConfiguration(appID: appID,
                                                                 sdkKey: "sdk_public",
                                                                 serverURL: "https://push.example"),
                            credential: { nil },
                            transport: { request, done in capture.set(request); done(200, "{}") })

            XCTAssertFalse(OpenPush.isInitialized,
                           "\(appID) must leave the SDK unconfigured")
            XCTAssertNil(capture.get(), "nothing reaches the network on a refused app id")
            waitForMainQueue()
            XCTAssertNotNil(failure.get(),
                            "the host learns from onRegistrationFailed, not from the console")
            XCTAssertTrue(log.joined().contains("app id"), log.joined())
            XCTAssertTrue(log.joined().contains("path character"), log.joined())
        }
    }

    /// `initialize` is `attach` plus a permission step. A refusal that only stops
    /// the attach would still prompt for notifications on behalf of a
    /// configuration the SDK just threw away.
    func testARefusedAppIdNeverReachesTheNotificationPrompt() {
        OpenPush.state.resetAsIfTheProcessJustStarted()
        let asked = StringCapture()
        OpenPush.permissionSeam = OpenPush.PermissionSeam(
            status: { done in done(.notDetermined) },
            request: { _, done in asked.set("asked"); done(false) },
            openSettings: {},
            registerForRemoteNotifications: { asked.set("registered") })
        OpenPush.onLog = { _ in }

        OpenPush.initialize(appId: " ", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            provisional: true,
                            transport: { _, done in done(200, "{}") })

        XCTAssertFalse(OpenPush.isInitialized)
        XCTAssertNil(asked.get(),
                     "a refused app id must not ask iOS for anything")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
