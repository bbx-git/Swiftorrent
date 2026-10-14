// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Core",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "SwiftorrentCore", targets: ["SwiftorrentCore"])
    ],
    targets: [
        .target(name: "SwiftorrentCore"),
        .testTarget(name: "SwiftorrentCoreTests", dependencies: ["SwiftorrentCore"])
    ]
)
