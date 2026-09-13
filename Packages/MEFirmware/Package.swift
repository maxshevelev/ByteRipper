// swift-tools-version: 5.9
//
//  MEFirmware — Intel ME / CSME / TXE / SPS / GSC firmware analysis.
//
//  A shared package, not a tool-module: the structure browser and any editor
//  both want the same parse tree, and parsing the same region twice in two
//  packages is how they would drift apart. It is a Swift port of the parsing
//  that upstream platomav/MEAnalyzer does in a single ~14k-line `MEA.py`, kept
//  in step with that repo by the `sync-mea-engine` skill
//  (`Skills/sync-mea-engine/SKILL.md`). Its symbol-to-Swift ledger is
//  `Skills/sync-mea-engine/reference/upstream-map.md`.
//
//  It depends on no part of the app — not on `ToolModuleKit`, not on the app
//  itself — because a parser that can be run by `swift test` over a hand-built
//  region is a parser whose diagnostics can be pinned down without a window.
//  The packages it links are data and decoders: `FreshData` for the databases,
//  `FirmwareCompression` for the LZMA-compressed CSME modules.
//
//  The module fronting this package exposes an async API to the UI and fetches
//  its firmware databases (MEA.dat / Huffman.dat / FileTable.dat) live from the
//  MEAnalyzer repo on first use, holding them in memory for the life of the
//  process and re-checking them once a day — never storing them on disk. That
//  contract is pinned in `Skills/sync-mea-engine/reference/async-api.md`, and
//  the UI-facing result model in `Skills/sync-mea-engine/reference/result-model.md`.
//

import PackageDescription

let package = Package(
    name: "MEFirmware",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MEFirmware", targets: ["MEFirmware"]),
        // Developer harness, not part of the library: analyse a file from the
        // command line and dump the result model as JSON.
        .executable(name: "MEFirmwareCLI", targets: ["MEFirmwareCLI"])
    ],
    dependencies: [
        // Holding MEA.dat for the life of the process, and checking it once a
        // day — see FreshData's own manifest for why that is a package.
        .package(path: "../FreshData"),
        // The LZMA decoder a CSME module is stored with (`mod_comp == 2`).
        .package(path: "../FirmwareCompression")
    ],
    targets: [
        .target(name: "MEFirmware", dependencies: [
            "FreshData",
            .product(name: "FirmwareCompression", package: "FirmwareCompression")
        ]),
        .testTarget(
            name: "MEFirmwareTests",
            dependencies: [
                "MEFirmware",
                // The encoder, to build an LZMA module byte by byte.
                .product(name: "FirmwareCompressionTestSupport", package: "FirmwareCompression")
            ]
        ),
        .executableTarget(
            name: "MEFirmwareCLI",
            dependencies: ["MEFirmware"]
        )
    ]
)
