// swift-tools-version: 5.9
//
//  ByteRipperServer — `byteripper-server`, one process for a personal network:
//  the code-analysis store every Mac's app mirrors and, later, the Ghidra host
//  (`Design/SERVER_PLAN.md`). The library holds the configuration, the token
//  and the composition of the roles, so they are tested without a process; the
//  executable only calls it. A package of its own because it is the one place
//  that links every role, and the app links none of it.
//
import PackageDescription

let package = Package(
    name: "ByteRipperServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ByteRipperServer", targets: ["ByteRipperServer"]),
        .executable(name: "byteripper-server", targets: ["byteripper-server"])
    ],
    dependencies: [
        .package(path: "../CodeAnalysis"),
        .package(path: "../HTTPService"),
        .package(path: "../CASService"),
        .package(path: "../GhidraHost"),
        .package(path: "../AgentKit")
    ],
    targets: [
        .target(name: "ByteRipperServer", dependencies: [
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "HTTPService", package: "HTTPService"),
            .product(name: "CASService", package: "CASService"),
            .product(name: "GhidraHost", package: "GhidraHost"),
            .product(name: "AgentKit", package: "AgentKit")
        ]),
        .executableTarget(name: "byteripper-server", dependencies: ["ByteRipperServer"]),
        .testTarget(name: "ByteRipperServerTests", dependencies: [
            "ByteRipperServer",
            .product(name: "CodeAnalysis", package: "CodeAnalysis")
        ])
    ]
)
