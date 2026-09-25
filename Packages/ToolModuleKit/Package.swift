// swift-tools-version: 5.9
//
//  ToolModuleKit — the whole of what a tool-module and the app agree on.
//
//  Both sides import this and nothing else of each other's: a tool-module never
//  sees `ByteRipperApp` or `ByteRipperCore`, and the app never sees a
//  tool-module's tree, its parse or its diagnostics. `Design/TOOL_MODULES_PLAN.md`
//  says why — making the app's core a public API is a price with no return.
//

import PackageDescription

let package = Package(
    name: "ToolModuleKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ToolModuleKit", targets: ["ToolModuleKit"])
    ],
    // The app's colours. This draws — the tables here put a marker beside a
    // value — and a marker's colour is a meaning, so it comes from the palette
    // rather than from a system colour picked by hand.
    //
    // The help book, for the one thing the seam carries about it: which page a
    // tool-module's panel header offers. A `HelpTopicID` rather than a bare
    // string, so a panel pointing at a page that does not exist is a
    // compile-time name and a test failure in the book rather than an empty
    // window on a bench. The pure half only — nothing here draws the help.
    dependencies: [
        // Every word this shows the user comes from the one catalogue the
        // whole app is translated in.
        .package(path: "../Localization"),
        .package(path: "../AppPalette"),
        .package(path: "../HelpBook"),
        // The `?` the shared detail list carries for the row in focus, and the
        // popover it opens. Here rather than in each panel so that "what is
        // this row" is the same button in the same corner in both of them —
        // the argument that put the row-marks legend here too.
        .package(path: "../HelpUI")
    ],
    targets: [
        .target(name: "ToolModuleKit",
                dependencies: [
                    .product(name: "Localization", package: "Localization"),
                    .product(name: "AppPalette", package: "AppPalette"),
                    .product(name: "HelpBook", package: "HelpBook"),
                    .product(name: "HelpUI", package: "HelpUI")
                ]),
        .testTarget(
            name: "ToolModuleKitTests",
            // Everything the target under test links, declared again: a
            // `@testable` import re-typechecks the module's interface, and a
            // product it can see but this cannot is an error only `swift test`
            // reports (measured — `swift build` was green).
            dependencies: [
                "ToolModuleKit",
                .product(name: "HelpBook", package: "HelpBook"),
                .product(name: "HelpUI", package: "HelpUI"),
                .product(name: "Localization", package: "Localization")
            ]
        )
    ]
)
