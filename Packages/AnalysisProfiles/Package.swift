// swift-tools-version: 5.9
// AnalysisProfiles: how modules of one kind are reviewed — the catalogue of
// analysis profiles (UEFI, ITE EC on NDS32), the records and gates each
// declares, and how the Code panel lays out its sections for each. Pure data
// and pure functions, with no dependencies.
//
// A package of its own because three readers share one declaration: the
// server's `ghidra_profile` (through GhidraHost), the store's revisions
// (CodeAnalysis stamps a revision with a profile) and the app's Code panel
// (CodeView builds its sections per profile). The panel must not have to link
// the store to learn which sections to show, and the declaration must not
// depend on the store's types: a library kind is its raw string here.
import PackageDescription

let package = Package(
    name: "AnalysisProfiles",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnalysisProfiles", targets: ["AnalysisProfiles"])
    ],
    targets: [
        .target(name: "AnalysisProfiles"),
        .testTarget(name: "AnalysisProfilesTests", dependencies: ["AnalysisProfiles"],
                    resources: [.copy("Golden")])
    ]
)
