// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftorrentCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SwiftorrentCore", targets: ["SwiftorrentCore"])
    ],
    targets: [
        .target(name: "SwiftorrentCore"),
        .testTarget(name: "SwiftorrentCoreTests", dependencies: ["SwiftorrentCore"])
    ]
)
