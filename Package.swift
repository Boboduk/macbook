// swift-tools-version: 6.0
//
// Alternative build of the app with SwiftPM, for machines with only the
// Command Line Tools (no Xcode). Scripts/build-app.sh --spm wraps the
// executable into AlcoveInspired.app with Info.plist, icon and signature.
// The primary build is AlcoveInspired.xcodeproj.

import PackageDescription

let package = Package(
    name: "AlcoveInspired",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AlcoveInspired", targets: ["AlcoveInspired"]),
    ],
    dependencies: [
        .package(path: "Packages/IslandCore"),
    ],
    targets: [
        .executableTarget(
            name: "AlcoveInspired",
            dependencies: [.product(name: "IslandCore", package: "IslandCore")],
            path: "AlcoveInspired",
            exclude: ["Resources"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
