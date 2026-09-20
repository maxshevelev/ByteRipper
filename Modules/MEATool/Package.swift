// swift-tools-version: 5.9
//
//  MEATool — the "ME Analyzer" instrument panel: two tabs, Summary and Full
//  Tree, a view over `MEFirmware`'s `FirmwareAnalysis`.
//
//  The engine (`MEFirmwareAnalyzer.analyze`) returns one big typed model. The
//  shared presentation over that model — the curated Full Tree, its zones, its
//  row marks, its value text — lives in `MEPresentation`, because the UEFI
//  Structure's ME branch builds the same tree and a tool-module may not depend
//  on another. This module's pure target keeps what only the ME Analyzer shows:
//  the Summary tab's model, tested by `swift test` over in-memory
//  `FirmwareAnalysis` fixtures. The UI target lays out both tabs.
//
//  Two targets, as every tool-module has: the Summary decisions and the view
//  over them.
//

import PackageDescription

let package = Package(
    name: "MEATool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MEATool", targets: ["MEATool"]),
        .library(name: "MEAToolUI", targets: ["MEAToolUI"])
    ],
    dependencies: [
        .package(path: "../../Packages/ALSplitView"),
        .package(path: "../../Packages/ToolModuleKit"),
        .package(path: "../../Packages/AppPalette"),
        .package(path: "../../Packages/MEFirmware"),
        .package(path: "../../Packages/MEPresentation"),
        .package(path: "../../Packages/UEFIImage")
    ],
    targets: [
        .target(name: "MEATool", dependencies: [
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "MEPresentation", package: "MEPresentation"),
        ]),
        .target(name: "MEAToolUI", dependencies: [
            .product(name: "AppPalette", package: "AppPalette"),
            "MEATool",
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "MEPresentation", package: "MEPresentation"),
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage")
        ]),
        .testTarget(name: "MEAToolTests", dependencies: [
            "MEATool",
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "MEPresentation", package: "MEPresentation")
        ])
    ]
)
