// swift-tools-version: 5.9
//
//  AgentKit — what the app says to an agent, and how: JSON, the line framing,
//  the Model Context Protocol's requests and answers, and the shape of a tool.
//
//  A package of its own because the parties that need it may not depend on one
//  another (`Design/AGENT_PLAN.md`): the app, which runs the service; the
//  relay a client launches, which shares the socket code and the socket's
//  path; `ToolModuleKit`, through which a tool-module declares the tools it
//  answers; and each tool-module's pure target, where those answers are
//  computed. It knows nothing about dumps, panes or AppKit, so the protocol
//  can be driven line by line by `swift test` without a window or a client,
//  and the socket with nothing but a temporary folder.
//
//  Written here rather than taken from an SDK: over a byte stream MCP is
//  newline-delimited JSON-RPC 2.0 and a handful of methods, and `CLAUDE.md`
//  admits third-party code only for decoders of published formats.
//

import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"])
    ],
    targets: [
        .target(name: "AgentKit"),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"]
        )
    ]
)
