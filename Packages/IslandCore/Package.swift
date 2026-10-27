// swift-tools-version: 5.10
//
// IslandCore — platform-independent logic of the island: activity queue,
// interaction state machine, event routing, layout math, settings, timers
// and parsers. It depends only on Foundation, so it builds and tests on
// macOS (Xcode / SwiftPM) and on Linux (used by CI and by Docker).

import PackageDescription

let package = Package(
    name: "IslandCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IslandCore", targets: ["IslandCore"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
