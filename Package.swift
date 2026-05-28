// swift-tools-version: 5.9
//
// VoxrtSilero — Silero v5 voice-activity detection running on the
// VoxRT custom inference runtime (https://voxrt.com).
//
// This file is generated per-release from the VoxRT monorepo. Do not
// edit by hand — changes here are clobbered on the next cut.

import PackageDescription

let package = Package(
    name: "VoxrtSilero",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "VoxrtSilero",
            targets: ["VoxrtSilero"]
        ),
    ],
    targets: [
        .target(
            name: "VoxrtSilero",
            dependencies: ["VoxrtSileroNative"],
            path: "Sources/VoxrtSilero"
        ),
        .binaryTarget(
            name: "VoxrtSileroNative",
            url: "https://github.com/VoxRT/voxrt-silero-ios/releases/download/v0.1.3/VoxrtSileroNative.xcframework.zip",
            checksum: "6020da631677e155dbe9ca94714df353225eed005959f629b292f0c922fba1a0"
        ),
    ]
)
