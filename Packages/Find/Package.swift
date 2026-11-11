// swift-tools-version: 5.9
//
//  Find — the logic of a search: what is searched for, the index of every
//  occurrence, and the reader's way through it.
//
//  A package of its own because the same search runs over different content:
//  the bytes of a dump, in `ByteRipperCore`, and text (`TextFindContent`) —
//  the code panel's C and its module description. Each
//  panel that searches holds its own `FindIndexer`; the content says how to
//  scan, and everything else — the pass, the index as it fills, the steps and
//  the wrap — is written once, here. Pure Swift: views only show what it holds.
//

import PackageDescription

let package = Package(
    name: "Find",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Find", targets: ["Find"])
    ],
    targets: [
        .target(name: "Find"),
        .testTarget(name: "FindTests", dependencies: ["Find"])
    ]
)
