// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftorrentDomain",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SwiftorrentDomain", targets: ["SwiftorrentDomain"])
    ],
    dependencies: [
        .package(path: "../SwiftorrentCore")
    ],
    targets: [
        .target(
            name: "SwiftorrentDomain",
            dependencies: [
                .product(name: "SwiftorrentCore", package: "SwiftorrentCore")
            ]
        )
    ]
)
