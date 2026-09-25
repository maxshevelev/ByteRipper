// swift-tools-version: 5.9
//
//  MEATool — the "ME Analyzer" instrument panel: two tabs, Summary and Full
//  Tree, a view over `MEFirmware`'s `FirmwareAnalysis`.
//
//  The engine (`MEFirmwareAnalyzer.analyze`) returns one big typed model. The
//  shared presentation over that model — the curated Full Info tree, its zones, its
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
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../../Packages/Localization"),
        .package(path: "../../Packages/ALSplitView"),
        // The help book: a tool-module names the page its panel header's `?`
        // opens (`ToolModule.helpTopic`), and the firmware panels key a row's
        // term to a glossary entry. The pure half only — the `?` itself and
        // the popover are drawn by the app and by `ToolModuleKit`.
        .package(path: "../../Packages/HelpBook"),
        // The `?` button, the per-term popover and `ControlHelp` — the one way
        // a control says what it does.
        .package(path: "../../Packages/HelpUI"),

        .package(path: "../../Packages/ToolModuleKit"),
        .package(path: "../../Packages/AppPalette"),
        .package(path: "../../Packages/MEFirmware"),
        .package(path: "../../Packages/MEPresentation"),
        .package(path: "../../Packages/MEReads"),
        .package(path: "../../Packages/UEFIImage")
    ],
    targets: [
        .target(name: "MEATool", dependencies: [
            .product(name: "Localization", package: "Localization"),
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "MEPresentation", package: "MEPresentation"),
            // The tone a value is drawn by — the shared vocabulary in
            // `ToolValueTone`, which the UEFI Structure's pure target links for
            // the same reason.
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ]),
        .target(name: "MEAToolUI", dependencies: [
            .product(name: "HelpUI", package: "HelpUI"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "AppPalette", package: "AppPalette"),
            "MEATool",
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "MEPresentation", package: "MEPresentation"),
            .product(name: "MEReads", package: "MEReads"),
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
