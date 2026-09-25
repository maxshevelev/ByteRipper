import Foundation

/// A page of the help book, named once and referred to by that name everywhere
/// — a menu item, a `?` button beside a form, a link inside another page.
///
/// A string wrapped in a type rather than a bare `String`, because the two
/// kinds of identifier in this package are easy to mistake for one another and
/// the compiler is the cheapest place to catch it. The raw value is also the
/// file name the page is loaded from (`Topics/<raw>.md`), so a page and its id
/// cannot drift apart.
public struct HelpTopicID: RawRepresentable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A word the panels show and nobody outside a firmware bench has met: `$FPT`,
/// ARB SVN, a VSS store. One entry per term, keyed by a stable id so a row in a
/// panel can point at it without repeating the text.
public struct HelpTermID: RawRepresentable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a link in the help text goes. There are two destinations and no third:
/// another page, or a term's entry in the glossary.
public enum HelpLink: Hashable, Sendable {
    case topic(HelpTopicID)
    case term(HelpTermID)
}

// MARK: - The pages

/// Every page the book holds. Listed here rather than discovered from the
/// resource directory so that a page a `?` button points at is a compile-time
/// name, and a translation that is missing a file is a test failure rather than
/// an empty window.
extension HelpTopicID {
    // Getting started
    public static let overview = HelpTopicID("overview")
    public static let firstComparison = HelpTopicID("first-comparison")
    public static let openingFiles = HelpTopicID("opening-files")
    public static let largeFiles = HelpTopicID("large-files")

    // Reading a dump
    public static let hexView = HelpTopicID("hex-view")
    public static let colors = HelpTopicID("colors")
    public static let navigation = HelpTopicID("navigation")
    public static let minimap = HelpTopicID("minimap")
    public static let search = HelpTopicID("search")
    public static let bookmarks = HelpTopicID("bookmarks")
    public static let segments = HelpTopicID("segments")
    public static let fragments = HelpTopicID("fragments")

    // Changing a dump
    public static let editing = HelpTopicID("editing")
    public static let saving = HelpTopicID("saving")
    public static let joinDuplicate = HelpTopicID("join-duplicate")
    public static let benchSafety = HelpTopicID("bench-safety")

    // The firmware panels
    public static let toolsOverview = HelpTopicID("tools-overview")
    public static let toolUEFI = HelpTopicID("tool-uefi")
    public static let toolME = HelpTopicID("tool-me")
    public static let toolFIT = HelpTopicID("tool-fit")
    public static let toolZones = HelpTopicID("tool-zones")
    public static let databases = HelpTopicID("databases")
    public static let provenance = HelpTopicID("provenance")

    // On the bench
    public static let recipeDonor = HelpTopicID("recipe-donor")
    public static let recipeBoardData = HelpTopicID("recipe-board-data")
    public static let recipeMECheck = HelpTopicID("recipe-me-check")
    public static let recipeMicrocode = HelpTopicID("recipe-microcode")
    public static let recipeChecksums = HelpTopicID("recipe-checksums")

    // Settings
    public static let settings = HelpTopicID("settings")
}
