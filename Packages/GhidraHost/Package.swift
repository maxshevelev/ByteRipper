// swift-tools-version: 5.9
//
//  GhidraHost — the Ghidra owners of `Design/GHIDRA_SHARED_PLAN.md`, hosted
//  from Swift (`Design/SERVER_PLAN.md` §6): the Ghidra and JDK install, the
//  owner built for it, each module's kept project, the owner processes, the
//  write lease and the publish into a store. A package of its own because two
//  hosts run it — `byteripper-server` and, for a desktop, the app — and
//  neither may be the other's dependency. It speaks to an owner over loopback
//  HTTP and never links Ghidra; the owner itself is Java, inside Ghidra's JVM.
//
import PackageDescription

let package = Package(
    name: "GhidraHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhidraHost", targets: ["GhidraHost"])
    ],
    dependencies: [
        .package(path: "../CodeAnalysis")
    ],
    targets: [
        .target(name: "GhidraHost", dependencies: [
            .product(name: "CodeAnalysis", package: "CodeAnalysis")
        ]),
        .testTarget(name: "GhidraHostTests", dependencies: [
            "GhidraHost",
            .product(name: "CodeAnalysis", package: "CodeAnalysis")
        ])
    ]
)
