// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Features",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "SwiftorrentFeatures", targets: ["SwiftorrentFeatures"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Domain")
    ],
    targets: [
        .target(
            name: "SwiftorrentFeatures",
            dependencies: [
                .product(name: "SwiftorrentCore", package: "Core"),
                .product(name: "SwiftorrentDomain", package: "Domain")
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
