import XCTest
@testable import OpenPushCore

/// The SDK key moves out of `initialize`'s argument list and into the app bundle
/// so the call can match the one a migrating host already wrote. The resolver takes a lookup closure rather
/// than a `Bundle` because `Bundle.object(forInfoDictionaryKey:)` cannot be
/// stubbed, and a resolver that can only be tested against the test bundle's own
/// Info.plist is a resolver nobody can write a negative case for.
final class OpenPushBundledKeyTests: XCTestCase {
    func testABundledKeyIsTrimmedAndReturned() {
        let found = OpenPushConfiguration.bundledSDKKey(lookup: { key in
            key == OpenPushConfiguration.sdkKeyInfoKey ? "  pk_live_abc  " : nil
        })
        XCTAssertEqual(found, "pk_live_abc")
    }

    func testAnEmptyOrWhitespaceKeyIsTreatedAsAbsent() {
        XCTAssertNil(OpenPushConfiguration.bundledSDKKey(lookup: { _ in "   " }))
        XCTAssertNil(OpenPushConfiguration.bundledSDKKey(lookup: { _ in "" }))
        XCTAssertNil(OpenPushConfiguration.bundledSDKKey(lookup: { _ in nil }))
    }

    func testANonStringPlistValueIsTreatedAsAbsentRatherThanStringified() {
        // A plist number under the key must not become the string "42": that would
        // send a syntactically valid, permanently rejected key on every request.
        XCTAssertNil(OpenPushConfiguration.bundledSDKKey(lookup: { _ in 42 }))
    }

    func testTheAppIdIsReadFromItsOwnKey() {
        let found = OpenPushConfiguration.bundledAppID(lookup: { key in
            key == OpenPushConfiguration.appIDInfoKey ? "abc-123" : nil
        })
        XCTAssertEqual(found, "abc-123")
    }
}
