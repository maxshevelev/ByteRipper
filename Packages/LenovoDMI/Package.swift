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
//  A package of its own rather than part of `UEFIImage`: the tree reads the
//  store with it — in place of the three regions the Insyde flash device map
//  declares as "Unknown" — and the UEFI Structure panel decodes the store's
//  rows with it, and the format is worth testing apart from either. It
//  depends on nothing but the words it says and the codec a block opened
//  decoded goes back through, so `swift test` reads blocks built byte by byte.
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
        // The codec a block opened decoded goes back into the file through.
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
