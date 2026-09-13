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
        .target(name: "CLZMA", exclude: ["SDK/README.md"]),
        .target(name: "CLZMAEncoder", exclude: ["SDK/README.md"]),
        .target(name: "CTiano", exclude: ["README.md"]),
        .target(name: "CTianoEncoder", exclude: ["README.md"]),
        .target(
            name: "FirmwareCompression",
            dependencies: ["CLZMA", "CLZMAEncoder", "CTiano", "CTianoEncoder"]
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
