// swift-tools-version: 5.9
//
//  UEFIImage — the domain model of a UEFI firmware image.
//
//  A shared package, not a tool-module: the structure browser and the FIT
//  editor both need the same tree, and parsing an image twice in two packages
//  is how the two would drift apart. It depends on no part of the app — not on
//  `ToolModuleKit`, not on the app itself — because a parser that can be run by
//  `swift test` over a hand-built image is a parser whose diagnostics can be
//  pinned down without a window. The one package it links is
//  `FirmwareCompression`, for the compressed sections most of an image's DXE
//  volume sits inside (`Design/UEFI/COMPRESSED_SECTIONS.md`).
//
//  `Design/UEFI/UEFI_IMAGE_FORMAT.md` is the specification this follows, and
//  its section numbers are quoted throughout.
//
//  The module is named after the struct it exports, which is what the parse
//  produces. That costs one thing, measured: a type shadows a module of the
//  same name, so `UEFIImage.UEFINode` does not resolve — module-qualified
//  names into this module are not available. Nothing used them.
//

import PackageDescription

let package = Package(
    name: "UEFIImage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UEFIImage", targets: ["UEFIImage"])
    ],
    dependencies: [
        .package(path: "../FirmwareCompression")
    ],
    targets: [
        .target(name: "UEFIImage", dependencies: [
            .product(name: "FirmwareCompression", package: "FirmwareCompression")
        ]),
        .testTarget(
            name: "UEFIImageTests",
            dependencies: [
                "UEFIImage",
                .product(name: "FirmwareCompression", package: "FirmwareCompression"),
                // The encoders, to build a compressed section byte by byte.
                .product(name: "FirmwareCompressionTestSupport", package: "FirmwareCompression")
            ]
        )
    ]
)
