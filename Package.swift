// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Swiftorrent",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Swiftorrent", targets: ["Swiftorrent"]),
        .executable(name: "swiftorrent-bench", targets: ["SwiftorrentBench"])
    ],
    dependencies: [
        .package(path: "Packages/Core"),
        .package(path: "Packages/Domain"),
        .package(path: "Packages/Features")
    ],
    targets: [
        .executableTarget(
            name: "Swiftorrent",
            dependencies: [
                .product(name: "SwiftorrentFeatures", package: "Features"),
                .product(name: "SwiftorrentDomain", package: "Domain")
            ],
            path: "App/Swiftorrent"
        ),
        .executableTarget(
            name: "SwiftorrentBench",
            dependencies: [
                .product(name: "SwiftorrentCore", package: "Core")
            ],
            path: "Tools/SwiftorrentBench"
        )
    ]
)
