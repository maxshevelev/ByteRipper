// swift-tools-version: 5.9
//
//  ZoneSketch — a tool-module for marking zones by hand.
//
//  The first one, and deliberately the simplest thing that uses the whole seam:
//  it publishes zones, navigates to them, writes through a transaction and
//  exports bytes, so the panel, the outlines in the dump, the undo step and the
//  file panels can all be tried on a real dump before a parser exists to
//  produce any of it (Design/TOOL_MODULES_PLAN.md).
//
//  Two targets, as every tool-module has: the decisions, which are tested by
//  `swift test`, and the view over them.
//

import PackageDescription

let package = Package(
    name: "ZoneSketch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ZoneSketch", targets: ["ZoneSketch"]),
        .library(name: "ZoneSketchUI", targets: ["ZoneSketchUI"])
    ],
    dependencies: [
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../../Packages/Localization"),
        // The help book: a tool-module names the page its panel header's `?`
        // opens (`ToolModule.helpTopic`), and the firmware panels key a row's
        // term to a glossary entry. The pure half only — the `?` itself and
        // the popover are drawn by the app and by `ToolModuleKit`.
        .package(path: "../../Packages/HelpBook"),
        // The `?` button, the per-term popover and `ControlHelp` — the one way
        // a control says what it does.
        .package(path: "../../Packages/HelpUI"),

        .package(path: "../../Packages/ToolModuleKit")
    ],
    targets: [
        .target(name: "ZoneSketch", dependencies: [
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ]),
        .target(name: "ZoneSketchUI", dependencies: [
            .product(name: "HelpUI", package: "HelpUI"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "HelpBook", package: "HelpBook"),
            "ZoneSketch",
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ]),
        .testTarget(name: "ZoneSketchTests", dependencies: ["ZoneSketch"])
    ]
)
