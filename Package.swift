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
            url: "https://github.com/VoxRT/voxrt-silero-ios/releases/download/v0.1.1/VoxrtSileroNative.xcframework.zip",
            checksum: "f3906300cbda993ff12c9fe5078e93e833b95fb8349d0ee743983fcf93ad8ad2"
        ),
    ]
)
