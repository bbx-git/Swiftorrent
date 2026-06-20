// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Swiftorrent",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Swiftorrent", targets: ["SwiftorrentApp"]),
        .library(name: "SwiftorrentCore", targets: ["SwiftorrentCore"]),
        .library(name: "SwiftorrentDomain", targets: ["SwiftorrentDomain"]),
        .library(name: "SwiftorrentFeatures", targets: ["SwiftorrentFeatures"])
    ],
    targets: [
        .target(
            name: "SwiftorrentCore",
            path: "Packages/SwiftorrentCore/Sources/SwiftorrentCore"
        ),
        .target(
            name: "SwiftorrentDomain",
            dependencies: ["SwiftorrentCore"],
            path: "Packages/SwiftorrentDomain/Sources/SwiftorrentDomain"
        ),
        .target(
            name: "SwiftorrentFeatures",
            dependencies: ["SwiftorrentCore", "SwiftorrentDomain"],
            path: "Packages/SwiftorrentFeatures/Sources/SwiftorrentFeatures"
        ),
        .executableTarget(
            name: "SwiftorrentApp",
            dependencies: [
                "SwiftorrentFeatures"
            ],
            path: "App/Sources/SwiftorrentApp"
        ),
        .testTarget(
            name: "SwiftorrentCoreTests",
            dependencies: ["SwiftorrentCore"],
            path: "Packages/SwiftorrentCore/Tests/SwiftorrentCoreTests"
        )
    ]
)
