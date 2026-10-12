// swift-tools-version: 5.9
//
//  BytePattern — a byte pattern with holes and the scan that finds it.
//
//  A package of its own because two sides that may not see each other both
//  search bytes for it: the app's find bar and agent tools, in
//  `ByteRipperCore`, and the UEFI Structure's search through a firmware's
//  volumes and what its compressed sections decompress to, in a tool-module —
//  which never links `ByteRipperCore`. One scan, so a pattern is found in the
//  tree exactly where the find bar finds it in the dump.
//
//  It knows nothing about where the bytes are kept: the caller hands it a
//  read. So it links nothing.
//

import PackageDescription

let package = Package(
    name: "BytePattern",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BytePattern", targets: ["BytePattern"])
    ],
    targets: [
        .target(name: "BytePattern"),
        .testTarget(name: "BytePatternTests", dependencies: ["BytePattern"])
    ]
)
