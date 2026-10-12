// swift-tools-version: 5.9
//
//  ByteRipperCore — pure Swift storage + model layers.
//  Must never import AppKit. UI lives in the app target.
//

import PackageDescription

let package = Package(
    name: "ByteRipperCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ByteRipperCore", targets: ["ByteRipperCore"])
    ],
    dependencies: [
        .package(path: "../Localization"),
        // The masked pattern and its scan, shared with the UEFI Structure's
        // search, which may not link this package. Re-exported: to everyone
        // here it is the search engine's own.
        .package(path: "../BytePattern")
    ],
    targets: [
        .target(
            name: "ByteRipperCore",
            dependencies: [
                .product(name: "Localization", package: "Localization"),
                .product(name: "BytePattern", package: "BytePattern")
            ]
        ),
        .testTarget(
            name: "ByteRipperCoreTests",
            dependencies: [
                "ByteRipperCore",
                .product(name: "Localization", package: "Localization"),
            ]
        )
    ]
)
