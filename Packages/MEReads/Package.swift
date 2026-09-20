// swift-tools-version: 5.9
//
//  MEReads — the ME region's bytes, and the reads both tool-modules make over
//  them.
//
//  Two panels read the same region the same way: they materialise it off the
//  pane's own reader, hand it to `MEFirmwareAnalyzer` at the region's base
//  offset, digest the same buffer for the Checksums group, and fetch the
//  file-name table that labels their rows. That is neither the engine
//  (`MEFirmware`) nor how a result is shown (`MEPresentation`) — it is the
//  seam between them, and it is a package of its own because both the UEFI
//  Structure and the ME Analyzer need it and a tool-module may not depend on
//  another.
//
//  It leans on `MEPresentation` for the name lookups the table turns into
//  (`MFSFileNames`, `EFSFileNames`, `ConfigRecordPaths`) — those are the types
//  that label a row, and that is where they live.
//
import PackageDescription

let package = Package(
    name: "MEReads",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MEReads", targets: ["MEReads"])
    ],
    dependencies: [
        .package(path: "../MEFirmware"),
        .package(path: "../MEPresentation"),
        .package(path: "../ToolModuleKit")
    ],
    targets: [
        .target(name: "MEReads", dependencies: [
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "MEPresentation", package: "MEPresentation"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ]),
        .testTarget(name: "MEReadsTests", dependencies: [
            "MEReads",
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ])
    ]
)
