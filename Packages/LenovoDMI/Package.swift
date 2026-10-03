// swift-tools-version: 5.9
//
//  LenovoDMI — the store Lenovo's InsydeH2O firmware keeps a machine's identity
//  in: the `LDBG` change log and the two `LENV` blocks after it.
//
//  The format was reverse-engineered from `LenovoVariableDxe` by
//  LenovoDMIDecryptor (github.com/Shmurkio/LenovoDMIDecryptor, MIT, read at
//  6dc9bdf, 2026-04-05), and checked here against real dumps; where the two
//  disagree, the dumps win and the comment says so.
//
//  A shared package rather than the pure half of the tool-module: the UEFI
//  Structure tool shows the same three regions — the Insyde flash device map
//  declares them, as "Unknown" — and naming them there must not mean one
//  tool-module depending on another. It depends on nothing but the words it
//  says, so `swift test` reads blocks built byte by byte.
//

import PackageDescription

let package = Package(
    name: "LenovoDMI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LenovoDMI", targets: ["LenovoDMI"])
    ],
    dependencies: [
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../Localization"),
        // The codec a block opened decrypted goes back into the file through.
        .package(path: "../PartCodec")
    ],
    targets: [
        .target(name: "LenovoDMI", dependencies: [
            .product(name: "Localization", package: "Localization"),
            .product(name: "PartCodec", package: "PartCodec")
        ]),
        .testTarget(name: "LenovoDMITests", dependencies: [
            "LenovoDMI",
            .product(name: "PartCodec", package: "PartCodec")
        ])
    ]
)
