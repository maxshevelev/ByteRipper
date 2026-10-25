// swift-tools-version: 5.9
// CodeAnalysis: the code artifacts a disassembler produces, and the local
// content-addressed store that keeps them. It links nothing but the system:
// CryptoKit for hashes, Foundation for files and JSON. A reader — the Code
// panel or an agent — never needs a disassembler to read what it holds.
import PackageDescription

let package = Package(
    name: "CodeAnalysis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodeAnalysis", targets: ["CodeAnalysis"])
    ],
    targets: [
        .target(name: "CodeAnalysis"),
        .testTarget(
            name: "CodeAnalysisTests",
            dependencies: ["CodeAnalysis"],
            resources: [.copy("Fixtures")]
        )
    ]
)
