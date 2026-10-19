// swift-tools-version: 5.9
//
//  Workspace — the session the app writes down and brings back at launch
//  (`Design/WORKSPACE_PLAN.md`).
//
//  A package of its own because it is the one part of workspace restore that
//  can be pure: the value that is written (`Workspace`), the rule for what of
//  it still applies once a file has changed on disk (`PaneRestore`), and the
//  folder it lives in (`WorkspaceFolder`). The app gathers the value from live
//  windows and applies it back; everything a test can check without a window
//  is here.
//

import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Workspace", targets: ["Workspace"])
    ],
    targets: [
        .target(name: "Workspace"),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace"])
    ]
)
