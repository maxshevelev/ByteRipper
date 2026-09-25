// swift-tools-version: 5.9
//
//  HelpBook — what the app has to say about itself, and the words it shows.
//
//  A package of its own, and a pure one: the help is *content* — a page per
//  subject and a paragraph per acronym — and content that lives in Swift string
//  literals is content nobody can translate. Everything a reader sees is a
//  Markdown-ish file under `Resources/Help/<language>/`, parsed here into
//  values a view lays out; adding a language is adding a directory beside `en`,
//  with no code to touch.
//
//  It knows nothing about AppKit on purpose. The book is read by the app, by
//  every tool-module's panel and by the tests, and a package that draws would
//  make the tests need a window to check that a term the ME panel links to
//  actually exists.
//
import PackageDescription

let package = Package(
    name: "HelpBook",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HelpBook", targets: ["HelpBook"])
    ],
    // Which language to read the book in is not the book's own decision: it
    // is the app's one language setting, which a user can override in
    // Settings. The pure half of that lives here.
    dependencies: [
        .package(path: "../Localization")
    ],
    targets: [
        // `.copy` rather than `.process`: the directory tree *is* the format —
        // `Help/<language>/Topics/<id>.md` — and processing is free to flatten
        // it, which would put two languages' `overview.md` in one place.
        .target(name: "HelpBook",
                dependencies: [.product(name: "Localization", package: "Localization")],
                resources: [.copy("Resources/Help")]),
        .testTarget(name: "HelpBookTests", dependencies: [
            "HelpBook",
            .product(name: "Localization", package: "Localization")
        ])
    ]
)
