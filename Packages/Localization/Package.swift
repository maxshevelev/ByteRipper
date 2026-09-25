// swift-tools-version: 5.9
//
//  Localization — the language the app speaks, and every word it says.
//
//  One catalogue for the whole app rather than a table per package: a
//  translator opens three files, not fifteen, and a term translated once is
//  translated everywhere. Everything that shows a word links this; it links
//  nothing, the way `AppPalette` does and for the same reason — what a word
//  *is* is the whole app's business.
//
//  The key is the English text. That is deliberate: a site is localized by
//  wrapping the literal it already had, there is no key to invent and none to
//  get wrong, and a translation nobody has written yet falls back to correct
//  English instead of to `settings.editing.warn.caption`.
//
import PackageDescription

let package = Package(
    name: "Localization",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Localization", targets: ["Localization"])
    ],
    targets: [
        // `.copy`, not `.process`: the `.lproj` directories are read by name
        // here rather than through `Bundle`'s own localization lookup, because
        // the language is the user's choice and not only the system's.
        .target(name: "Localization", resources: [.copy("Resources")]),
        .testTarget(name: "LocalizationTests", dependencies: ["Localization"])
    ]
)
