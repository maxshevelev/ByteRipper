// swift-tools-version: 5.9
//
//  FirmwareCompression — the decoders for the compressed data a firmware image
//  holds (`Design/UEFI/COMPRESSED_SECTIONS.md`).
//
//  A shared package because two parsers need the same decoders: `UEFIImage`,
//  for the compressed sections that hold most of a UEFI image's DXE volume, and
//  `MEFirmware`, for the LZMA-compressed modules of a CSME region. A decoder
//  living in one of them is a decoder the other copies.
//
//  It is also the one place third-party code enters the project. Each format
//  here is published, with a reference decoder, and a rewrite is where the risk
//  would be — so the reference is vendored unmodified, as a C target of its own,
//  and the Swift target in front of it is the only thing anyone imports:
//
//  - `CLZMA` — the LZMA SDK's decoder and x86 branch filter (public domain),
//    behind a two-function header. See `Sources/CLZMA/SDK/README.md`.
//  - `CTiano` — EDK2's Tiano / EFI 1.1 decompressor as UEFITool carries it
//    (BSD), behind a two-function header. See `Sources/CTiano/README.md`.
//  - `FirmwareCompression` — the API: whole buffers in, whole buffers or a
//    reason out, under a size limit the caller sets.
//  - `CLZMAEncoder`, `CTianoEncoder` — the matching encoders, for building test
//    fixtures.
//  - `FirmwareCompressionTestSupport` — those encoders behind a Swift API, a
//    product only so that the parsers' own tests can build a compressed section
//    byte by byte. Nothing but a test target may link it: the app decodes and
//    never encodes.
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
        .target(name: "CLZMA", exclude: ["SDK/README.md"]),
        .target(name: "CTiano", exclude: ["README.md"]),
        .target(name: "FirmwareCompression", dependencies: ["CLZMA", "CTiano"]),
        .target(name: "CLZMAEncoder", path: "Tests/CLZMAEncoder"),
        .target(name: "CTianoEncoder", path: "Tests/CTianoEncoder"),
        .target(
            name: "FirmwareCompressionTestSupport",
            dependencies: ["CLZMA", "CLZMAEncoder", "CTianoEncoder"],
            path: "Tests/FirmwareCompressionTestSupport"
        ),
        .testTarget(
            name: "FirmwareCompressionTests",
            dependencies: ["FirmwareCompression", "FirmwareCompressionTestSupport"]
        )
    ]
)
