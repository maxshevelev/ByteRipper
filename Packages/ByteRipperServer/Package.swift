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
        .package(path: "../AgentKit"),
        .package(path: "../AgentDocuments"),
        .package(path: "../ToolModuleKit"),
        .package(path: "../UEFIImage"),
        .package(path: "../UEFIContentSource"),
        .package(path: "../../Modules/UEFITool")
    ],
    targets: [
        // Tokens: the file, the authorizer the listener runs on, and the
        // console's cookies. A target of its own so what decides who a request
        // is can be tested without a listener or a store.
        .target(name: "ServerAuth", dependencies: [
            .product(name: "HTTPService", package: "HTTPService")
        ]),
        // The documents the server holds: snapshots read whole at open, the
        // tree read from each, the ids that survive a restart, the roots and
        // the limits (`Design/SERVER_HEADLESS_PLAN.md` §6).
        .target(name: "DumpHost", dependencies: [
            .product(name: "AgentDocuments", package: "AgentDocuments"),
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage"),
            .product(name: "UEFIContentSource", package: "UEFIContentSource")
        ]),
        // The local MCP: the tools over the documents, the socket they are
        // served on, and the activity the console shows
        // (`Design/SERVER_HEADLESS_PLAN.md` §7).
        .target(name: "ServerMCP", dependencies: [
            "DumpHost",
            .product(name: "AgentDocuments", package: "AgentDocuments"),
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "GhidraHost", package: "GhidraHost"),
            .product(name: "UEFITool", package: "UEFITool")
        ]),
        // The stdio↔socket bridge, and nothing else: a target whose only
        // import is AgentKit cannot start a role.
        .target(name: "ServerRelay", dependencies: [
            .product(name: "AgentKit", package: "AgentKit")
        ]),
        .target(name: "ByteRipperServer", dependencies: [
            "ServerAuth",
            "ServerMCP",
            "ServerRelay",
            "DumpHost",
            .product(name: "AgentDocuments", package: "AgentDocuments"),
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "HTTPService", package: "HTTPService"),
            .product(name: "CASService", package: "CASService"),
            .product(name: "GhidraHost", package: "GhidraHost"),
            .product(name: "AgentKit", package: "AgentKit")
        ]),
        .executableTarget(name: "byteripper-server", dependencies: ["ByteRipperServer", "ServerRelay"]),
        .testTarget(name: "ServerAuthTests", dependencies: [
            "ServerAuth",
            .product(name: "HTTPService", package: "HTTPService")
        ]),
        .testTarget(name: "ByteRipperServerTests", dependencies: [
            "ByteRipperServer",
            "DumpHost",
            "ServerMCP",
            "ServerRelay",
            .product(name: "AgentDocuments", package: "AgentDocuments"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage"),
            "ServerAuth",
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "GhidraHost", package: "GhidraHost"),
            .product(name: "HTTPService", package: "HTTPService"),
            .product(name: "AgentKit", package: "AgentKit")
        ])
    ]
)
