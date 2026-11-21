// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Psynguechthyngue",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PsyCore", targets: ["PsyCore"]),
    ],
    targets: [
        .target(
            name: "PsyCore",
            path: "Sources/PsyCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "PsyCoreTests",
            dependencies: ["PsyCore"],
            path: "Tests/PsyCoreTests",
            exclude: ["PhysicalFileProviderE2ETests.swift"]
        ),
    ]
)
