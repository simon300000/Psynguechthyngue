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
        // Rewrite (Docs/REWRITE/DESIGN.md): new contracts; PsyCore is removed by WP-E.
        .library(name: "PsySync", targets: ["PsySync"]),
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
        .target(
            name: "PsySync",
            path: "Sources/PsySync"
        ),
        .testTarget(
            name: "PsySyncTests",
            dependencies: ["PsySync"],
            path: "Tests/PsySyncTests"
        ),
        .testTarget(
            name: "PsyCoreTests",
            dependencies: ["PsyCore"],
            path: "Tests/PsyCoreTests",
            exclude: ["PhysicalFileProviderE2ETests.swift"]
        ),
    ]
)
