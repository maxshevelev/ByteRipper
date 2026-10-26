// swift-tools-version: 5.9
// CodeAnalysis: the code artifacts a disassembler produces, and the local
// content-addressed store that keeps them. It links nothing but the system:
// CryptoKit for hashes, Foundation for files and JSON, CoreServices for the
// FSEvents stream that says when another process wrote the store. A reader — the Code
// panel or an agent — never needs a disassembler to read what it holds.
//
// Beside the library, one executable: `byteripper-cas`, the store as a command
// line. The skill's Python writes and reads the store through it, so the
// store's rules exist once, in Swift, and not again in Python.
import PackageDescription

let package = Package(
    name: "CodeAnalysis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodeAnalysis", targets: ["CodeAnalysis"]),
        .executable(name: "byteripper-cas", targets: ["byteripper-cas"])
    ],
    targets: [
        .target(name: "CodeAnalysis"),
        .executableTarget(name: "byteripper-cas", dependencies: ["CodeAnalysis"]),
        .testTarget(
            name: "CodeAnalysisTests",
            dependencies: ["CodeAnalysis"],
            resources: [.copy("Fixtures")]
        )
    ]
)
