import XCTest
@testable import OpenPush

final class OpenPushInAppMessageTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func first(pathSuffix: String) -> URLRequest? {
            lock.withLock { requests.first { $0.url?.path.hasSuffix(pathSuffix) == true } }
        }
    }

    func testFetchUsesBoundDeviceScopeAndPostsAnImpressionEnvelope() throws {
        let capture = Capture()
        let padding = String(repeating: "x", count: 6_000)
        // The impression now waits for the document to render, so the test
        // stands in for a WebView that loaded on the first try.
        OpenPush.IamEngine.shared.setPresenter { _, emit in emit(.rendered(height: nil)) }
        OpenPush.initialize(
            appId: "openpush-sample", sdkKey: "sdk-public",
            serverURL: "https://push.example", credential: { "opdev_owner" },
            transport: { request, done in
                capture.add(request)
                switch request.url?.path {
                case "/v1/apps/openpush-sample/subscriptions":
                    done(200, #"{"id":"sub_owner"}"#)
                case "/v1/apps/openpush-sample/subscriptions/sub_owner/iams":
                    done(200, #"{"in_app_messages":[{"id":"iam_1","html_path":"/v1/apps/openpush-sample/iams/iam_1/html","layout":"center","triggers":[],"padding":"\#(padding)"}]}"#)
                case "/v1/ingest":
                    done(200, #"{"accepted":1,"dropped":0}"#)
                default:
                    done(404, "")
                }
            })
        OpenPush.register(token: "aabbcc")
        // The registration above is not what this test is about; the fetch it
        // arms is, so the automatic path is armed only now.
        OpenPush.IamEngine.shared.setAutomaticFetchForTests(true)
        OpenPush.InAppMessages.onSubscriptionReady()

        let fetch = try XCTUnwrap(capture.first(
            pathSuffix: "/subscriptions/sub_owner/iams"))
        XCTAssertEqual(fetch.value(forHTTPHeaderField: "X-OP-SDK-Key"), "sdk-public")
        XCTAssertEqual(fetch.value(forHTTPHeaderField: "X-OP-Device-Key"), "opdev_owner")

        let ingest = try XCTUnwrap(capture.first(pathSuffix: "/v1/ingest"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(ingest.httpBody)) as? [String: Any])
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "iam_impression")
        XCTAssertEqual(events[0]["app"] as? String, "openpush-sample")
        XCTAssertEqual(events[0]["message_id"] as? String, "iam_1")
        XCTAssertEqual(events[0]["token"] as? String, "aabbcc")
    }

    func testTransportBodyDoesNotTruncateLargeInAppDefinitions() {
        let document = String(repeating: "message-content-", count: 500)
        let data = Data(document.utf8)
        XCTAssertGreaterThan(data.count, 4_096)
        XCTAssertEqual(OpenPush.transportBody(data), document)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
