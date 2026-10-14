// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Domain",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "SwiftorrentDomain", targets: ["SwiftorrentDomain"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "SwiftorrentDomain",
            dependencies: [
                .product(name: "SwiftorrentCore", package: "Core")
            ]
        ),
        .testTarget(
            name: "SwiftorrentDomainTests",
            dependencies: ["SwiftorrentDomain"]
        )
    ]
)
