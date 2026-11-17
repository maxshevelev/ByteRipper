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
        .package(path: "../BytePattern"),
        // The logic of a search — the index, the pass, the steps — shared
        // with the code panel's search, which may not link this package.
        // Re-exported for the same reason as BytePattern: to everyone here
        // the index and the direction are the search engine's own.
        .package(path: "../Find"),
        // How a number is written in hex: the sum's terms and its result in
        // an address field, in the one form the whole app writes.
        .package(path: "../HexText")
    ],
    targets: [
        .target(
            name: "ByteRipperCore",
            dependencies: [
                .product(name: "Localization", package: "Localization"),
                .product(name: "BytePattern", package: "BytePattern"),
                .product(name: "Find", package: "Find"),
                .product(name: "HexText", package: "HexText")
            ]
        ),
        .testTarget(
            name: "ByteRipperCoreTests",
            dependencies: [
                "ByteRipperCore",
                .product(name: "Localization", package: "Localization"),
                .product(name: "Find", package: "Find"),
                .product(name: "HexText", package: "HexText")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
