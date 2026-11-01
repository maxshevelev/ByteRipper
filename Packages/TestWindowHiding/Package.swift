// swift-tools-version: 5.9
// TestWindowHiding: the windows a test process creates are made invisible —
// `NSWindow`'s designated initializer is swizzled by a constructor, so the
// swizzle is in place before the first test runs. A package of its own because
// a package's test target is the only thing that links it: three packages'
// tests put windows on the screen of whoever runs the suite, and SwiftPM
// gives a test bundle no Info.plist to name a principal class in, which is
// how the app's own suite does it.
import PackageDescription

let package = Package(
    name: "TestWindowHiding",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TestWindowHiding", targets: ["TestWindowHiding"])
    ],
    targets: [
        .target(name: "TestWindowHiding",
                linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "TestWindowHidingTests", dependencies: ["TestWindowHiding"])
    ]
)
