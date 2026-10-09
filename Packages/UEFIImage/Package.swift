// swift-tools-version: 5.9
//
//  UEFIImage — the domain model of a UEFI firmware image.
//
//  A shared package, not a tool-module: the structure browser and the FIT
//  editor both need the same tree, and parsing an image twice in two packages
//  is how the two would drift apart. It depends on no part of the app — not on
//  `ToolModuleKit`, not on the app itself — because a parser that can be run by
//  `swift test` over a hand-built image is a parser whose diagnostics can be
//  pinned down without a window. The packages it links are
//  `FirmwareCompression`, for the compressed sections most of an image's DXE
//  volume sits inside (`Design/UEFI/COMPRESSED_SECTIONS.md`), and `LenovoDMI`,
//  for the store Lenovo keeps a machine's identity in.
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
        .package(path: "../FirmwareCompression"),
        // The parser names the gaps it finds — "Free space", "Padding" — and
        // those names are what the tree's Name column shows a reader.
        .package(path: "../Localization"),
        // Lenovo's DMI store is read into the tree in the format's own terms,
        // so the tree and whatever else reads the store cannot drift apart.
        .package(path: "../LenovoDMI")
    ],
    targets: [
        .target(name: "UEFIImage", dependencies: [
            .product(name: "FirmwareCompression", package: "FirmwareCompression"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "LenovoDMI", package: "LenovoDMI")
        ]),
        .testTarget(
            name: "UEFIImageTests",
            dependencies: [
                "UEFIImage",
                .product(name: "FirmwareCompression", package: "FirmwareCompression"),
                .product(name: "Localization", package: "Localization"),
                // The encoders, to build a compressed section byte by byte.
                .product(name: "FirmwareCompressionTestSupport", package: "FirmwareCompression")
            ]
        )
    ]
)
