// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftorrentFeatures",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SwiftorrentFeatures", targets: ["SwiftorrentFeatures"])
    ],
    dependencies: [
        .package(path: "../SwiftorrentCore"),
        .package(path: "../SwiftorrentDomain")
    ],
    targets: [
        .target(
            name: "SwiftorrentFeatures",
            dependencies: [
                .product(name: "SwiftorrentCore", package: "SwiftorrentCore"),
                .product(name: "SwiftorrentDomain", package: "SwiftorrentDomain")
            ]
        )
    ]
)
