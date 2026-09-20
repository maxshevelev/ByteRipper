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
        .package(path: "../MEFirmware"),
        .package(path: "../ToolModuleKit")
    ],
    targets: [
        .target(name: "MEPresentation", dependencies: [
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ]),
        .testTarget(name: "MEPresentationTests", dependencies: [
            "MEPresentation",
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ])
    ]
)
