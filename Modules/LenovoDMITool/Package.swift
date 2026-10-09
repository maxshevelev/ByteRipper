// swift-tools-version: 5.9
//
//  LenovoDMITool — the identity store of Lenovo's InsydeH2O firmware, read: the
//  change log and the two `LENV` blocks, their entries decoded, and which
//  block the firmware uses.
//
//  The format and the parse are `LenovoDMI`'s; this is what the panel makes of
//  them — the tree, the detail of the row in focus, and the zones the dump
//  draws — and the view over that.
//
//  Two targets, as every tool-module has: the decisions, tested by `swift test`
//  over stores built byte by byte, and the view over them.
//

import PackageDescription

let package = Package(
    name: "LenovoDMITool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LenovoDMITool", targets: ["LenovoDMITool"]),
        .library(name: "LenovoDMIToolUI", targets: ["LenovoDMIToolUI"])
    ],
    dependencies: [
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../../Packages/Localization"),
        .package(path: "../../Packages/ALSplitView"),
        // The help book: the page the panel header's `?` opens, and the
        // glossary entry the detail's `?` opens for the row in focus.
        .package(path: "../../Packages/HelpBook"),
        // The `?` button and `ControlHelp` — the one way a control says what
        // it does.
        .package(path: "../../Packages/HelpUI"),

        .package(path: "../../Packages/ToolModuleKit"),
        .package(path: "../../Packages/AppPalette"),
        .package(path: "../../Packages/LenovoDMI"),
        // The image's drivers, searched for the entries they ask for.
        .package(path: "../../Packages/UEFIImage"),
        .package(path: "../../Packages/PartCodec")
    ],
    targets: [
        .target(name: "LenovoDMITool", dependencies: [
            .product(name: "Localization", package: "Localization"),
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "LenovoDMI", package: "LenovoDMI"),
            .product(name: "UEFIImage", package: "UEFIImage")
        ]),
        .target(name: "LenovoDMIToolUI", dependencies: [
            .product(name: "HelpUI", package: "HelpUI"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "AppPalette", package: "AppPalette"),
            "LenovoDMITool",
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "LenovoDMI", package: "LenovoDMI"),
            .product(name: "PartCodec", package: "PartCodec")
        ]),
        .testTarget(name: "LenovoDMIToolTests", dependencies: [
            "LenovoDMITool",
            .product(name: "LenovoDMI", package: "LenovoDMI"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ])
    ]
)
