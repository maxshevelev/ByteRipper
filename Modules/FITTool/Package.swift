// swift-tools-version: 5.9
//
//  FITTool — the Intel Firmware Interface Table, read and repaired.
//
//  The table is not part of the UEFI tree: it is found through a pointer at a
//  fixed physical address, its entries address memory rather than the file, and
//  what they point at is often outside any FFS file. So its structure, its
//  rules and its edits live here, in a tool-module, and what it takes from
//  `UEFIImage` is the one thing it cannot work out for itself — the mapping
//  between an address and an offset, which comes from a full parse of the image
//  (`Design/TOOL_MODULES_PLAN.md`, `Design/UEFI/FIT_TABLE_FORMAT.md`).
//
//  Two targets, as every tool-module has: the decisions, tested by `swift test`
//  over images built byte by byte, and the view over them.
//

import PackageDescription

let package = Package(
    name: "FITTool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FITTool", targets: ["FITTool"]),
        .library(name: "FITToolUI", targets: ["FITToolUI"])
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

        // How an offset or a size is written in hex: one copy for the app and
        // every tool-module, with no format string to read 32 bits of 64.
        .package(path: "../../Packages/HexText"),
        .package(path: "../../Packages/ToolModuleKit"),
        .package(path: "../../Packages/AppPalette"),
        .package(path: "../../Packages/UEFIImage"),
        .package(path: "../../Packages/UEFIContentSource"),
        .package(path: "../../Packages/FreshData"),
        // What the module answers an agent with (`FITAgentQueries`,
        // Design/AGENT_PLAN.md).
        .package(path: "../../Packages/AgentKit"),
        // The processor tables — which models stand behind a CPUID — and the
        // one repository and store they are read through, shared with the
        // app's Intel CPUID Lookup window.
        .package(path: "../../Packages/IntelCPUID")
    ],
    targets: [
        .target(name: "FITTool", dependencies: [
            .product(name: "HexText", package: "HexText"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage"),
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "IntelCPUID", package: "IntelCPUID")
        ]),
        .target(name: "FITToolUI", dependencies: [
            .product(name: "HelpUI", package: "HelpUI"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "FreshData", package: "FreshData"),
            .product(name: "AppPalette", package: "AppPalette"),
            "FITTool",
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage"),
            .product(name: "UEFIContentSource", package: "UEFIContentSource"),
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "IntelCPUID", package: "IntelCPUID")
        ]),
        .testTarget(name: "FITToolTests", dependencies: [
            "FITTool",
            .product(name: "IntelCPUID", package: "IntelCPUID")
        ])
    ]
)
