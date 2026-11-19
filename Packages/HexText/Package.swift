// swift-tools-version: 5.9
//
//  HexText — how a number is written in hex for a person to read: `0x1FE028`.
//
//  A package of its own because the app and every tool-module quote offsets
//  and sizes, and a tool-module may not see the app (CLAUDE.md, "Packages").
//  Left to each, the same line was written eight times over as
//  `String(format: "0x%llX", value)` — and the one copy written `%X` instead
//  read 32 bits of a 64-bit offset and printed `0x123456780` as `0x23456780`.
//  Here the digits come from the integer itself, with no format string to get
//  wrong. It links nothing.
//

import PackageDescription

let package = Package(
    name: "HexText",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HexText", targets: ["HexText"])
    ],
    targets: [
        .target(name: "HexText"),
        .testTarget(name: "HexTextTests", dependencies: ["HexText"])
    ]
)
