// swift-tools-version: 5.9
//
//  AgentDocuments — the agent's tools that two hosts serve over their own
//  documents (`Design/SERVER_HEADLESS_PLAN.md` §4.1): the rule that says
//  which document a call means, a tool-module's query run on the document it
//  names, a module's stored code analysis read by its node, and
//  `ghidra_open` by a node.
//
//  A package of its own because the app and `byteripper-server` both serve
//  these, over panes in one and over snapshots in the other, and neither may
//  be the other's dependency. It depends on the UEFI Structure's pure target;
//  the rule it must not break is the other way round — no tool-module
//  depends on this.
//
import PackageDescription

let package = Package(
    name: "AgentDocuments",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDocuments", targets: ["AgentDocuments"])
    ],
    dependencies: [
        .package(path: "../AgentKit"),
        .package(path: "../ToolModuleKit"),
        .package(path: "../UEFIImage"),
        .package(path: "../CodeAnalysis"),
        .package(path: "../GhidraHost"),
        .package(path: "../../Modules/UEFITool")
    ],
    targets: [
        .target(name: "AgentDocuments", dependencies: [
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage"),
            .product(name: "UEFITool", package: "UEFITool"),
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "GhidraHost", package: "GhidraHost")
        ]),
        .testTarget(name: "AgentDocumentsTests", dependencies: [
            "AgentDocuments",
            .product(name: "AgentKit", package: "AgentKit"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "GhidraHost", package: "GhidraHost")
        ])
    ]
)
