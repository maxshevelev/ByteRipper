// swift-tools-version: 5.9
//
//  IntelCPUID — which Intel processors stand behind a CPUID, read from
//  `github.com/maxshevelev/IntelCPUID` at run time.
//
//  A package of its own because the tables have more than one reader and must
//  be one copy: the FIT panel names the processors of a microcode by them, and
//  the Intel CPUID Lookup window searches them by CPUID, model and S-SPEC. Both
//  read the one store here, which the one repository here fills — from the
//  network, or from the copy of the last good read it keeps — so a correction
//  pushed to the repository shows in both at once, and neither can hold a
//  table the other does not.
//
//  Foundation only: the model, the download and its cache, and the search the
//  window runs, all tested without AppKit.
//

import PackageDescription

let package = Package(
    name: "IntelCPUID",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "IntelCPUID", targets: ["IntelCPUID"])
    ],
    targets: [
        .target(name: "IntelCPUID"),
        .testTarget(name: "IntelCPUIDTests", dependencies: ["IntelCPUID"])
    ]
)
