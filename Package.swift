// swift-tools-version: 6.0

import PackageDescription

// PsySync: engine contracts, LiveSyncEngine (REST/events), policy, Files
// projection. Consumed by the App and File Provider targets of
// Psynguechthyngue.xcodeproj (Scripts/generate-xcodeproj.rb). The Go bridge
// (GoBridge/, PsyBridge.xcframework) is linked only by the Xcode targets.
let package = Package(
    name: "Psynguechthyngue",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PsySync", targets: ["PsySync"]),
    ],
    targets: [
        .target(
            name: "PsySync",
            path: "Sources/PsySync"
        ),
        .testTarget(
            name: "PsySyncTests",
            dependencies: ["PsySync"],
            path: "Tests/PsySyncTests"
        ),
    ]
)
