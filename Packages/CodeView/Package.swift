// swift-tools-version: 5.9
// CodeView: the code pane a module's stored analysis is read in. AppKit, beside
// the module bytes in a fragment panel; the model and the store are in
// CodeAnalysis. A package of its own because the pane is not a tool-module's
// left strip: it takes the content width, and a later reader can use it without
// the UEFI tree.
import PackageDescription

let package = Package(
    name: "CodeView",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodeView", targets: ["CodeView"])
    ],
    dependencies: [
        .package(path: "../ALSplitView"),
        .package(path: "../AppPalette"),
        .package(path: "../CodeAnalysis"),
        .package(path: "../HelpBook"),
        .package(path: "../HelpUI"),
        .package(path: "../Localization"),
        .package(path: "../ToolModuleKit")
    ],
    targets: [
        .target(name: "CodeView", dependencies: [
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "AppPalette", package: "AppPalette"),
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "HelpUI", package: "HelpUI"),
            .product(name: "Localization", package: "Localization"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit")
        ]),
        .testTarget(name: "CodeViewTests", dependencies: [
            "CodeView",
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "HelpUI", package: "HelpUI")
        ])
    ]
)
