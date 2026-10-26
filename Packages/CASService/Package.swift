// swift-tools-version: 5.9
//
//  CASService — the code-analysis store served over HTTP (`/cas/v1`): the
//  store's operations as routes over `ContentStore`, and the change feed a
//  mirror follows (`Design/SERVER_PLAN.md` §4). A package of its own because
//  it is one role of `byteripper-server` beside the Ghidra host, and the app,
//  which is only ever a client (`RemoteStore`, in CodeAnalysis), never links
//  it.
//
import PackageDescription

let package = Package(
    name: "CASService",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CASService", targets: ["CASService"])
    ],
    dependencies: [
        .package(path: "../CodeAnalysis"),
        .package(path: "../HTTPService")
    ],
    targets: [
        .target(name: "CASService", dependencies: [
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "HTTPService", package: "HTTPService")
        ]),
        .testTarget(name: "CASServiceTests", dependencies: [
            "CASService",
            .product(name: "CodeAnalysis", package: "CodeAnalysis"),
            .product(name: "HTTPService", package: "HTTPService")
        ])
    ]
)
