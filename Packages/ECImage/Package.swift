// swift-tools-version: 5.9
//
//  ECImage — an embedded controller's firmware image, as bytes.
//
//  A shared package of its own: the analysis server opens an EC image as a
//  module for review in Ghidra, and the app is to show the same module, with
//  the same identity, later. Recognising the image, finding where the linked
//  image ends, the identity hash with the bytes the EC rewrites itself
//  normalised, and the layout of its vectors and interrupt dispatch are
//  decided here once, so the two cannot drift apart. Pure Swift with no
//  dependency: every rule is pinned down by `swift test` over a real image.
//

import PackageDescription

let package = Package(
    name: "ECImage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ECImage", targets: ["ECImage"])
    ],
    targets: [
        .target(name: "ECImage"),
        .testTarget(name: "ECImageTests", dependencies: ["ECImage"])
    ]
)
