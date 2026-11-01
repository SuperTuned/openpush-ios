import XCTest
@testable import OpenPush
import OpenPushCore

/// `initialize(appId:)` resolves the SDK key from the app bundle so the call can
/// match the one a migrating host already wrote. These tests assert on the wire rather than on stored state:
/// the configuration is private, and what actually matters is which key reaches
/// the server.
final class OpenPushInitializeFromBundleTests: OpenPushTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.withLock { value = request } }
        func get() -> URLRequest? { lock.withLock { value } }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
    }

    private func transport(_ capture: Capture) -> OpenPush.Transport {
        { request, done in
            capture.set(request)
            done(200, #"{"id":"sub_1"}"#)
        }
    }

    override func tearDown() {
        OpenPush.bundledSDKKeySeam = { OpenPushConfiguration.bundledSDKKey() }
        super.tearDown()
    }

    func testAnExplicitKeyBeatsTheBundledOne() throws {
        let capture = Capture()
        OpenPush.bundledSDKKeySeam = { "pk_from_plist" }
        OpenPush.initialize(appId: "sample", sdkKey: "explicit_key",
                            serverURL: "https://push.example",
                            transport: transport(capture))
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "explicit_key")
    }

    func testABundledKeyConfiguresTheSDKAndRidesTheWire() throws {
        let capture = Capture()
        OpenPush.bundledSDKKeySeam = { "pk_from_plist" }
        OpenPush.initialize(appId: "sample", serverURL: "https://push.example",
                            transport: transport(capture))
        XCTAssertTrue(OpenPush.isInitialized)
        OpenPush.didRegisterForRemoteNotifications(deviceToken: Data([0xab]))
        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OP-SDK-Key"), "pk_from_plist")
    }

    func testWithoutAKeyAnywhereInitializeRefusesLoudlyAndStaysUnconfigured() {
        let logs = LogCapture()
        let failures = LogCapture()
        OpenPush.onLog = { logs.add($0) }
        OpenPush.onRegistrationFailed = { failures.add($0) }
        OpenPush.bundledSDKKeySeam = { nil }

        OpenPush.initialize(appId: "sample", serverURL: "https://push.example")

        XCTAssertFalse(OpenPush.isInitialized,
                       "a half-configured SDK that never registers and never says why is the "
                       + "worst outcome available here")
        XCTAssertTrue(logs.joined().contains(OpenPushConfiguration.sdkKeyInfoKey),
                      "the refusal must name the Info.plist key to add")
        waitForMainQueue()
        XCTAssertFalse(failures.joined().isEmpty,
                       "a host watching onRegistrationFailed must hear about it too")
    }
}
