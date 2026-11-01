// swift-tools-version: 6.0
import PackageDescription

// The setup tool is its own package so an app that depends on the SDK never
// resolves XcodeProj or ArgumentParser: they are build-time tools for the
// developer's Mac, not part of what ships in an app.
let package = Package(
    name: "OpenPushSetup",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openpush-ios-setup", targets: ["openpush-ios-setup"]),
        .library(name: "OpenPushSetupKit", targets: ["OpenPushSetupKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tuist/XcodeProj.git", exact: "9.17.6"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "OpenPushSetupKit",
                dependencies: [.product(name: "XcodeProj", package: "XcodeProj")]),
        .executableTarget(name: "openpush-ios-setup",
                          dependencies: ["OpenPushSetupKit",
                                         .product(name: "ArgumentParser",
                                                  package: "swift-argument-parser")]),
        .testTarget(name: "OpenPushSetupKitTests",
                    dependencies: ["OpenPushSetupKit"]),
    ]
)
