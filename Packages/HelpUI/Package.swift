// swift-tools-version: 5.9
//
//  HelpUI — the help, on screen: the window, the `?` button and the popover a
//  panel shows for one term.
//
//  Apart from `HelpBook` because that one is pure and this one draws, and the
//  split is what lets the book's own tests prove that every link in the content
//  resolves without a window server. A package of its own rather than a folder
//  in the app, because the `?` beside a firmware panel's detail list is drawn
//  by a tool-module — and a tool-module may not import the app.
//
import PackageDescription

let package = Package(
    name: "HelpUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HelpUI", targets: ["HelpUI"])
    ],
    dependencies: [
        .package(path: "../HelpBook"),
        .package(path: "../AppPalette"),
        .package(path: "../ALSplitView")
    ],
    targets: [
        .target(name: "HelpUI", dependencies: [
            .product(name: "HelpBook", package: "HelpBook"),
            .product(name: "AppPalette", package: "AppPalette"),
            .product(name: "ALSplitView", package: "ALSplitView")
        ]),
        .testTarget(name: "HelpUITests", dependencies: [
            "HelpUI",
            .product(name: "HelpBook", package: "HelpBook")
        ])
    ]
)
