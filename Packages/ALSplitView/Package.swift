// swift-tools-version: 5.9
//
//  ALSplitView — a small Auto Layout split view for macOS.
//  Two (or more) panes separated by draggable dividers, laid out by
//  explicit frame math instead of NSSplitView's content-based distribution.
//

import PackageDescription

let package = Package(
    name: "ALSplitView",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ALSplitView", targets: ["ALSplitView"])
    ],
    // Only the tests below: they put windows on the screen, and this makes
    // them invisible while keeping them windows.
    dependencies: [
        .package(path: "../TestWindowHiding")
    ],
    targets: [
        .target(name: "ALSplitView"),
        .testTarget(
            name: "ALSplitViewTests",
            dependencies: [
                "ALSplitView",
                .product(name: "TestWindowHiding", package: "TestWindowHiding")
            ]
        )
    ]
)
