// swift-tools-version: 5.9
//
//  MapData — the envelope of ByteRipper's compiled map resources.
//
//  The strap tables (`UEFIImage`) and the ME configuration maps
//  (`MEFirmware`) are descriptions, generated from the tools' own layouts as
//  JSON and compiled into one binary (`Design/MAP_DATA.md`). The two readers
//  share everything about that binary except what a record means: the magic,
//  the format and data versions, the section table, the string pool, the
//  bounds checks and the checksum. That envelope lives here, so a change to
//  it is one change and both maps cannot drift apart.
//
//  The package knows nothing about straps or ME settings, and depends on
//  nothing but Foundation.
//

import PackageDescription

let package = Package(
    name: "MapData",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MapData", targets: ["MapData"])
    ],
    targets: [
        .target(name: "MapData"),
        .testTarget(name: "MapDataTests", dependencies: ["MapData"])
    ]
)
