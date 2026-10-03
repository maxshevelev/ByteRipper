// swift-tools-version: 5.9
//
//  PartCodec — what a part panel's bytes are to the bytes of the file they came
//  out of, in both directions.
//
//  A part of a file opens as a panel over it — a zone, a selection, a node of
//  an image, a compressed section, an encrypted block — and goes back into it
//  with Update in Parent (`Design/FRAGMENT_PANELS_PLAN.md`,
//  `Design/UEFI/UPDATE_IN_PARENT.md`). What the panel shows is not always the
//  source's bytes as they lie: it may be what they decompress or decrypt to.
//  Each of those is a codec, and the app opens and puts back every part the
//  same way, whoever asked for it to be opened.
//
//  A package of its own because the app opens parts of its own accord (a zone,
//  a selection) as much as on a tool-module's behalf, so it cannot live in
//  `ToolModuleKit`; and the codecs for firmware formats live beside their
//  parsers, which must not depend on the app. Pure: no AppKit, nothing but the
//  words it says.
//

import PackageDescription

let package = Package(
    name: "PartCodec",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PartCodec", targets: ["PartCodec"])
    ],
    dependencies: [
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../Localization")
    ],
    targets: [
        .target(name: "PartCodec", dependencies: [
            .product(name: "Localization", package: "Localization")
        ]),
        .testTarget(name: "PartCodecTests", dependencies: ["PartCodec"])
    ]
)
