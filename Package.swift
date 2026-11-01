// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "openpush-ios",
    // iOS is the shipped platform. The macOS entry exists only so `swift test`
    // on the host can compile UserNotifications; it is deliberately below
    // macOS 13, where Foundation's own NSLock.withLock would overload against
    // this package's file-private helper.
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [
        .library(name: "OpenPush", targets: ["OpenPush"]),
        .library(name: "OpenPushCore", targets: ["OpenPushCore"]),
        .library(name: "OpenPushLiveActivities", targets: ["OpenPushLiveActivities"]),
        .library(name: "OpenPushNSE", targets: ["OpenPushNSE"]),
        .library(name: "OpenPushOneSignal", targets: ["OpenPushOneSignal"]),
        // Separate so an app without calls never links PushKit.
        .library(name: "OpenPushVoIP", targets: ["OpenPushVoIP"]),
    ],
    targets: [
        .target(name: "OpenPushCore",
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "OpenPushLiveActivities",
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "OpenPush", dependencies: ["OpenPushCore", "OpenPushLiveActivities"],
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "OpenPushNSE", dependencies: ["OpenPushCore"],
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "OpenPushOneSignal", dependencies: ["OpenPush", "OpenPushLiveActivities"],
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "OpenPushVoIP", dependencies: ["OpenPush", "OpenPushCore"],
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .testTarget(name: "OpenPushCoreTests", dependencies: ["OpenPushCore"]),
        .testTarget(name: "OpenPushTests",
                    dependencies: ["OpenPush", "OpenPushCore", "OpenPushLiveActivities",
                                   "OpenPushOneSignal", "OpenPushNSE", "OpenPushVoIP"]),
    ]
)
