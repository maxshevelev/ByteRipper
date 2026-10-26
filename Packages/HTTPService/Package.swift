// swift-tools-version: 5.9
//
//  HTTPService — the small HTTP/1.1 server `byteripper-server` listens with:
//  a listener, requests read by length, routes by method and path, a bearer
//  token, and a long poll. A package of its own because the server's roles
//  (`CASService`, the Ghidra host) each register routes on it and must not
//  depend on one another, and because the app never links it.
//
//  Written here rather than taken from SwiftNIO: on macOS Network.framework
//  gives the sockets, and what the server needs above them is a few hundred
//  lines. On Linux and Windows SwiftNIO goes behind the same interface
//  (`Design/SERVER_PLAN.md` §9).
//
import PackageDescription

let package = Package(
    name: "HTTPService",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HTTPService", targets: ["HTTPService"])
    ],
    targets: [
        .target(name: "HTTPService"),
        .testTarget(name: "HTTPServiceTests", dependencies: ["HTTPService"])
    ]
)
