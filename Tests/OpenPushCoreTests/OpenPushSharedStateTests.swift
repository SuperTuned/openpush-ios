import XCTest
@testable import OpenPushCore

final class OpenPushSharedStateTests: XCTestCase {
    private func makeSuiteName() -> String {
        "openpush.tests.\(UUID().uuidString)"
    }

    private func removeSuite(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    func testSaveThenLoadRoundTripsThroughTheSuite() throws {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        let value = OpenPushSharedState(appID: "sample",
                                        serverURL: "https://push.example",
                                        sdkKey: "sdk_public",
                                        token: "aabb",
                                        subscriptionID: "sub_1",
                                        appGroup: suite)
        OpenPushSharedState.save(value, appGroup: suite)

        XCTAssertEqual(OpenPushSharedState.load(appGroup: suite), value)

        // The extension rebuilds a configuration it can send receipts with, and it
        // stays pointed at the same group.
        let configuration = try XCTUnwrap(OpenPushSharedState.load(appGroup: suite)).configuration
        XCTAssertEqual(configuration.appID, "sample")
        XCTAssertEqual(configuration.serverURL, "https://push.example")
        XCTAssertEqual(configuration.sdkKey, "sdk_public")
        XCTAssertEqual(configuration.appGroup, suite)

        OpenPushSharedState.clear(appGroup: suite)
        XCTAssertNil(OpenPushSharedState.load(appGroup: suite))
    }

    func testLoadReturnsNilWhenNothingWasSaved() {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        XCTAssertNil(OpenPushSharedState.load(appGroup: suite))
    }

    /// The wrapper is additive: a mirror written by an older build has no such key
    /// and must still load, with the wrapper simply absent.
    func testTheWrapperRoundTripsAndIsAbsentFromAnOlderMirror() throws {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        let wrapped = OpenPushSharedState(appID: "sample", serverURL: "https://push.example",
                                          sdkKey: "sdk_public", token: "aabb",
                                          subscriptionID: "sub_1",
                                          sdkWrapper: "unity/1.1.4", appGroup: suite)
        OpenPushSharedState.save(wrapped, appGroup: suite)
        XCTAssertEqual(OpenPushSharedState.load(appGroup: suite)?.sdkWrapper, "unity/1.1.4")

        // A native install overwrites the same group: the wrapper must not linger.
        let native = OpenPushSharedState(appID: "sample", serverURL: "https://push.example",
                                         sdkKey: "sdk_public", token: "aabb",
                                         subscriptionID: "sub_1", appGroup: suite)
        OpenPushSharedState.save(native, appGroup: suite)
        XCTAssertEqual(OpenPushSharedState.load(appGroup: suite), native)
        XCTAssertNil(OpenPushSharedState.load(appGroup: suite)?.sdkWrapper)
    }

    /// Every key the SDK writes into the host's own group is namespaced, so an
    /// App Group shared with the rest of the app cannot be trampled.
    func testEveryWrittenKeyIsNamespaced() {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        let defaults = UserDefaults(suiteName: suite)
        defaults?.set("host value", forKey: "hostKey")
        OpenPushSharedState.save(OpenPushSharedState(appID: "sample",
                                                     serverURL: "https://push.example",
                                                     sdkKey: "sdk_public",
                                                     appGroup: suite),
                                 appGroup: suite)

        let written = (defaults?.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("openpush.") || $0 == "hostKey"
        }) ?? []
        XCTAssertTrue(written.allSatisfy {
            $0 == "hostKey" || $0.hasPrefix(OpenPushSharedState.keyPrefix)
        }, "unexpected keys: \(written)")

        OpenPushSharedState.clear(appGroup: suite)
        XCTAssertEqual(defaults?.string(forKey: "hostKey"), "host value",
                       "clear must not empty the host's own group")
    }

    // MARK: - Stored badge count

    func testTheBadgeCountStartsAtZeroAndIncrementsFromTheStoredValue() throws {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 0)
        XCTAssertEqual(OpenPushSharedState.incrementBadgeCount(by: 2, appGroup: suite), 2)
        XCTAssertEqual(OpenPushSharedState.incrementBadgeCount(by: 3, appGroup: suite), 5)
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 5)

        XCTAssertTrue(OpenPushSharedState.setBadgeCount(0, appGroup: suite))
        XCTAssertEqual(OpenPushSharedState.incrementBadgeCount(by: 1, appGroup: suite), 1,
                       "a reset is where the next increment counts from")
    }

    func testTheBadgeCountNeverGoesNegative() {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        OpenPushSharedState.setBadgeCount(-4, appGroup: suite)
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 0)
        XCTAssertEqual(OpenPushSharedState.incrementBadgeCount(by: -3, appGroup: suite), 0)
    }

    /// The mirror is rewritten on every token or subscription change and cleared
    /// on a workspace switch; neither may touch a count the extension raised.
    func testTheBadgeCountSurvivesMirrorWritesAndClears() {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }

        _ = OpenPushSharedState.incrementBadgeCount(by: 4, appGroup: suite)
        OpenPushSharedState.save(OpenPushSharedState(appID: "sample",
                                                     serverURL: "https://push.example",
                                                     sdkKey: "sdk_public", token: "aabb",
                                                     appGroup: suite),
                                 appGroup: suite)
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 4)
        OpenPushSharedState.clear(appGroup: suite)
        XCTAssertEqual(OpenPushSharedState.badgeCount(appGroup: suite), 4)
        XCTAssertTrue(OpenPushSharedState.badgeCountKey.hasPrefix(OpenPushSharedState.keyPrefix))
    }
}
