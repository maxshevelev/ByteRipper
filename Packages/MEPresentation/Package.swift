// swift-tools-version: 5.9
//
//  MEPresentation — how a `FirmwareAnalysis` is shown.
//
//  `MEFirmware` is the engine: it turns the bytes of an ME region into one
//  typed `FirmwareAnalysis`. This package is the presentation over that model —
//  the hand-named tree a panel lays out (and the byte ranges its rows reveal),
//  the row marks a node wears, the value text the rows carry, and the name
//  lookups (MFS / EFS files, config-record paths) that label them.
//
//  It is a package of its own, not a target inside `MEATool`, because two
//  tool-modules build it: the ME Analyzer panel and the UEFI Structure's ME
//  branch — and a tool-module may not depend on another. The ME Analyzer's
//  Summary-tab model stays in `MEATool`; only what both panels present moves
//  here.
//
import PackageDescription

let package = Package(
    name: "MEPresentation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MEPresentation", targets: ["MEPresentation"])
    ],
    dependencies: [
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../Localization"),
        .package(path: "../MEFirmware"),
        .package(path: "../ToolModuleKit"),
        // The glossary a row points at. A `HelpTermID` on the node rather than
        // a lookup by title in the panel: the tree is hand-named here, so this
        // is the one place that knows what a row *is*, and a title is a label
        // that may be translated while an id is not.
        .package(path: "../HelpBook")
    ],
    targets: [
        .target(name: "MEPresentation", dependencies: [
            .product(name: "Localization", package: "Localization"),
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "HelpBook", package: "HelpBook")
        ]),
        .testTarget(name: "MEPresentationTests", dependencies: [
            "MEPresentation",
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ])
    ]
)
