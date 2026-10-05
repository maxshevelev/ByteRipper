// swift-tools-version: 5.9
//
//  FirmwareCompression — the decoders and encoders for the compressed data a
//  firmware image holds (`Design/UEFI/COMPRESSED_SECTIONS.md`,
//  `Design/UEFI/UPDATE_IN_PARENT.md` §5).
//
//  A shared package because two parsers need the same decoders: `UEFIImage`,
//  for the compressed sections that hold most of a UEFI image's DXE volume, and
//  `MEFirmware`, for the LZMA-compressed modules of a CSME region. A decoder
//  living in one of them is a decoder the other copies. The encoders are here
//  for putting an edited buffer back into its section.
//
//  It is also the one place third-party code enters the project. Each format
//  here is published, with a reference implementation, and a rewrite is where
//  the risk would be — so the reference is vendored unmodified, as a C target of
//  its own, and the Swift target in front of it is the only thing anyone
//  imports:
//
//  - `CLZMA` — the LZMA SDK's decoder and x86 branch filter (public domain),
//    behind a two-function header. See `Sources/CLZMA/SDK/README.md`.
//  - `CLZMAEncoder` — the same SDK's encoder, behind a one-function header. See
//    `Sources/CLZMAEncoder/SDK/README.md`.
//  - `CTiano` — EDK2's Tiano / EFI 1.1 decompressor as UEFITool carries it
//    (BSD), behind a two-function header. See `Sources/CTiano/README.md`.
//  - `CTianoEncoder` — the matching compressor, from the same place. See
//    `Sources/CTianoEncoder/README.md`.
//  - `CBZip2` — not vendored: the `libbz2` macOS itself ships, for the one
//    bzip2 stream a Mac's firmware keeps (Apple's `overrides`). A system
//    library target, so there is no source here and nothing to keep in step.
//  - `zlib` — not a target at all: the SDK already declares the module for
//    the `libz` macOS ships, so `FirmwareCompression` imports it as it is,
//    for AMD's Zlib sections.
//  - `FirmwareCompression` — the API: `FirmwareDecompression`, whole buffers in
//    and whole buffers or a reason out under a size limit the caller sets, and
//    `FirmwareCompression`, which decodes every stream it writes back before
//    handing it over.
//  - `FirmwareCompressionTestSupport` — the encoders with test defaults and no
//    errors to handle, a product so that the parsers' own tests can build a
//    compressed section byte by byte. Test targets only.
//

import PackageDescription

let package = Package(
    name: "FirmwareCompression",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FirmwareCompression", targets: ["FirmwareCompression"]),
        .library(name: "FirmwareCompressionTestSupport", targets: ["FirmwareCompressionTestSupport"])
    ],
    targets: [
        .systemLibrary(name: "CBZip2", path: "Sources/CBZip2"),
        .target(name: "CLZMA", exclude: ["SDK/README.md"]),
        .target(name: "CLZMAEncoder", exclude: ["SDK/README.md"]),
        .target(name: "CTiano", exclude: ["README.md"]),
        .target(name: "CTianoEncoder", exclude: ["README.md"]),
        .target(
            name: "FirmwareCompression",
            dependencies: ["CBZip2", "CLZMA", "CLZMAEncoder", "CTiano", "CTianoEncoder"]
        ),
        .target(
            name: "FirmwareCompressionTestSupport",
            dependencies: ["FirmwareCompression"],
            path: "Tests/FirmwareCompressionTestSupport"
        ),
        .testTarget(
            name: "FirmwareCompressionTests",
            dependencies: ["FirmwareCompression", "FirmwareCompressionTestSupport"]
        )
    ]
)
