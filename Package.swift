// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Swiftorrent",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Swiftorrent", targets: ["SwiftorrentApp"]),
        .executable(name: "swiftorrent-bench", targets: ["SwiftorrentBench"]),
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
                "SwiftorrentFeatures",
                "SwiftorrentDomain"
            ],
            path: "App/Sources/SwiftorrentApp"
        ),
        .executableTarget(
            name: "SwiftorrentBench",
            dependencies: ["SwiftorrentCore"],
            path: "Tools/SwiftorrentBench"
        ),
        .testTarget(
            name: "SwiftorrentCoreTests",
            dependencies: ["SwiftorrentCore"],
            path: "Packages/SwiftorrentCore/Tests/SwiftorrentCoreTests"
        ),
        .testTarget(
            name: "SwiftorrentDomainTests",
            dependencies: ["SwiftorrentDomain"],
            path: "Packages/SwiftorrentDomain/Tests/SwiftorrentDomainTests"
        )
    ]
)
