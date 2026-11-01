import XCTest
@testable import OpenPush
@testable import OpenPushOneSignal
import OpenPushCore

/// `openLaunchURLs`: on by default, as on Android and Unity — the tap's URL opens
/// after the click listeners are told, with `launchURLOpened` saying so.
final class OpenPushLaunchURLTests: OpenPushTestCase {
    /// Everything the test observes, in the order it happened.
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []
        private var events: [OpenPush.ClickEvent] = []
        func add(_ step: String) { lock.lock(); steps.append(step); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return steps }
        func event(_ value: OpenPush.ClickEvent) { lock.lock(); events.append(value); lock.unlock() }
        func clicks() -> [OpenPush.ClickEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private let trace = Trace()

    override func setUp() {
        super.setUp()
        let trace = trace
        OpenPush.launchURLOpener = { trace.add("open \($0.absoluteString)") }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.storeToken("aabb")
    }

    private func listen() -> UUID {
        let trace = trace
        return OpenPush.Notifications.addClickListener { event in
            trace.add("listener")
            trace.event(event)
        }
    }

    private func tap(_ link: String?, messageId: String = "m-\(UUID().uuidString)",
                     actionId: String? = nil) {
        var info: [AnyHashable: Any] = ["op_message_id": messageId]
        if let link { info["deep_link"] = link }
        OpenPush.Notifications.handleClick(userInfo: info, actionId: actionId)
    }

    func testTheSettingIsOnByDefault() {
        XCTAssertTrue(OpenPush.Notifications.openLaunchURLs)
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("https://example.com/offer")

        XCTAssertEqual(trace.all(), ["listener", "open https://example.com/offer"],
                       "nothing was set, and the SDK opens the URL itself")
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, true)
    }

    func testSettingItFalseOpensNothing() {
        OpenPush.Notifications.openLaunchURLs = false
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("https://example.com/offer")
        tap("myapp://store")
        tapButton("shop")
        tap("https://example.com/held")

        XCTAssertEqual(trace.all(), ["listener", "listener", "listener", "listener"],
                       "the app routes every URL itself")
        XCTAssertEqual(trace.clicks().map(\.launchURLOpened), [false, false, false, false])
    }

    func testSettingItFalseOpensNothingForAHeldColdStartClick() {
        OpenPush.Notifications.openLaunchURLs = false

        tap("https://example.com/offer")
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        waitForMainQueue()
        XCTAssertEqual(trace.all(), ["listener"])
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, false)
    }

    func testWhenOnTheURLOpensAfterTheListenerIsTold() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("https://example.com/offer")

        XCTAssertEqual(trace.all(), ["listener", "open https://example.com/offer"])
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, true)
    }

    func testAHeldColdStartClickStillOpensAtOnce() {

        tap("myapp://store")
        XCTAssertEqual(trace.all(), ["open myapp://store"],
                       "the URL does not wait for a listener the app adds later")

        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }
        waitForMainQueue()
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, true)
    }

    func testAURLOfAnySchemeIsOpened() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("otherapp://somewhere")
        tap("tel:+15550100")
        tap("myapp://store")
        tap("http://example.com/plain")

        XCTAssertEqual(trace.all(), ["listener", "open otherapp://somewhere",
                                     "listener", "open tel:+15550100",
                                     "listener", "open myapp://store",
                                     "listener", "open http://example.com/plain"],
                       "no scheme filter: whatever parses is handed to the system")
        XCTAssertEqual(trace.clicks().map(\.launchURLOpened), [true, true, true, true])
    }

    func testSurroundingWhitespaceIsTrimmedBeforeOpening() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("  https://example.com/offer \n")

        XCTAssertEqual(trace.all(), ["listener", "open https://example.com/offer"])
    }

    func testAURLThatDoesNotParseOpensNothing() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("http://[::1")
        tap("   ")

        XCTAssertEqual(trace.all(), ["listener", "listener"])
        XCTAssertEqual(trace.clicks().map(\.launchURLOpened), [false, false])
    }

    // MARK: - Opting out

    func testTheInfoPlistKeyTurnsOpeningOffAtInitialize() {
        OpenPush.launchURLs.setInfoLookup {
            $0 == OpenPushConfiguration.suppressLaunchURLsInfoKey ? true : nil
        }
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        XCTAssertFalse(OpenPush.Notifications.openLaunchURLs)
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("https://example.com/offer")

        XCTAssertEqual(trace.all(), ["listener"])
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, false)
    }

    func testTheInfoPlistKeyIsReadAsABoolInAnyOfItsSpellings() {
        XCTAssertEqual(OpenPushConfiguration.suppressLaunchURLsInfoKey, "OpenPushSuppressLaunchURLs")
        let cases: [(Any?, Bool)] = [(true, true), (false, false), ("YES", true), ("NO", false),
                                     (NSNumber(value: 1), true), (nil, false)]
        for (value, suppressed) in cases {
            XCTAssertEqual(OpenPush.LaunchURLs.isTrue(value), suppressed,
                           "\(String(describing: value))")
        }
    }

    func testWithoutTheInfoPlistKeyInitializeKeepsTheAppsCodeSetting() {
        OpenPush.launchURLs.setInfoLookup { _ in nil }
        OpenPush.Notifications.openLaunchURLs = false
        OpenPush.initialize(appId: "sample", sdkKey: "sdk_public",
                            serverURL: "https://push.example",
                            transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        XCTAssertFalse(OpenPush.Notifications.openLaunchURLs)
    }

    func testAPushWithoutALaunchURLOpensNothing() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap(nil)

        XCTAssertEqual(trace.all(), ["listener"])
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, false)
    }

    func testARepeatedTapOpensNothingAgain() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("https://example.com/a", messageId: "same")
        tap("https://example.com/a", messageId: "same")

        XCTAssertEqual(trace.all(), ["listener", "open https://example.com/a"])
    }

    // MARK: - Compatibility facade

    func testTheFacadeKeepsLaunchURLsOpeningByDefault() {
        OneSignal.initialize(appId: "sample", sdkKey: "sdk_public",
                             serverURL: "https://push.example",
                             transport: { _, done in done(200, #"{"id":"sub_1"}"#) })

        XCTAssertTrue(OpenPush.Notifications.openLaunchURLs,
                      "the facade keeps the default of the SDK it replaces")
    }

    func testThePlistKeyKeepsTheFacadeFromOpeningLaunchURLs() {
        OneSignal.applyLaunchURLDefault { $0 == OneSignal.suppressLaunchURLsInfoKey ? true : nil }
        XCTAssertFalse(OpenPush.Notifications.openLaunchURLs)

        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }
        tap("https://example.com/offer")
        XCTAssertEqual(trace.all(), ["listener"])
    }

    func testWithoutThePlistKeyTheFacadeLeavesTheAppsChoiceAlone() {
        OneSignal.applyLaunchURLDefault { _ in nil }
        XCTAssertTrue(OpenPush.Notifications.openLaunchURLs, "the default stays on")

        OpenPush.Notifications.openLaunchURLs = false
        OneSignal.applyLaunchURLDefault { _ in nil }
        XCTAssertFalse(OpenPush.Notifications.openLaunchURLs,
                       "an app that turned it off before initialize keeps it off")
    }

    func testThePlistKeyIsReadAsABoolInAnyOfItsSpellings() {
        let cases: [(Any?, Bool)] = [(true, true), (false, false), ("YES", true), ("true", true),
                                     ("NO", false), (NSNumber(value: 1), true), (nil, false),
                                     ("", false)]
        for (value, suppressed) in cases {
            XCTAssertEqual(OneSignal.launchURLsSuppressed { _ in value }, suppressed,
                           "\(String(describing: value))")
        }
    }

    func testTheSettingCanStillBeChangedAfterTheFacadeInitializes() {
        OneSignal.initialize(appId: "sample", sdkKey: "sdk_public",
                             serverURL: "https://push.example",
                             transport: { _, done in done(200, #"{"id":"sub_1"}"#) })
        OpenPush.Notifications.openLaunchURLs = false
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tap("https://example.com/offer")

        XCTAssertEqual(trace.all(), ["listener"])
    }

    // MARK: - A link per action button

    private func tapButton(_ actionId: String, link: String? = "https://example.com/push") {
        var info: [AnyHashable: Any] = [
            "op_message_id": "m-\(UUID().uuidString)",
            "op_actions": [["id": "shop", "label": "Shop", "url": "https://example.com/shop"],
                           ["id": "later", "label": "Later"],
                           ["id": "elsewhere", "label": "Elsewhere", "url": "otherapp://x"]],
        ]
        if let link { info["deep_link"] = link }
        OpenPush.Notifications.handleClick(userInfo: info, actionId: actionId)
    }

    func testAButtonTapCarriesTheButtonsURLEvenWithOpeningOff() {
        OpenPush.Notifications.openLaunchURLs = false
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tapButton("shop")
        tapButton("later")
        tap("https://example.com/push")

        XCTAssertEqual(trace.clicks().map(\.actionURL),
                       [URL(string: "https://example.com/shop"), nil, nil])
        XCTAssertEqual(trace.all(), ["listener", "listener", "listener"], "nothing is opened")
    }

    func testWhenOnAButtonsURLOpensInsteadOfThePushLink() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tapButton("shop")

        XCTAssertEqual(trace.all(), ["listener", "open https://example.com/shop"])
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, true)
    }

    func testAButtonWithoutAURLOpensThePushLinkAsBefore() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tapButton("later")
        tapButton("later", link: nil)

        XCTAssertEqual(trace.all(), ["listener", "open https://example.com/push", "listener"])
        XCTAssertEqual(trace.clicks().map(\.launchURLOpened), [true, false])
    }

    func testAButtonURLOfAnySchemeIsOpenedInsteadOfThePushLink() {
        let listener = listen()
        defer { OpenPush.Notifications.removeClickListener(listener) }

        tapButton("elsewhere")

        XCTAssertEqual(trace.all(), ["listener", "open otherapp://x"])
        XCTAssertEqual(trace.clicks().first?.actionURL, URL(string: "otherapp://x"))
        XCTAssertEqual(trace.clicks().first?.launchURLOpened, true)
    }
}
