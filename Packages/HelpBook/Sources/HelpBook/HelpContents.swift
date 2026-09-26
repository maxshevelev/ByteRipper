import Foundation

/// A group of pages in the contents list.
public struct HelpSection: Equatable, Sendable, Identifiable {
    public var id: String
    /// The row the reader sees. Comes from `Sections.md`, so it translates.
    public var name: String
    public var topics: [HelpTopicID]

    public init(id: String, name: String, topics: [HelpTopicID]) {
        self.id = id
        self.name = name
        self.topics = topics
    }
}

/// The shape of the book: which pages there are and in what order.
///
/// In code, not in a content file, and that is the whole division this package
/// rests on — **structure is code, words are resources**. A translator who
/// reorders a list cannot drop a page the app links to, and a page added here
/// is a page every language is then measured against: the tests fail until the
/// file exists in each.
public enum HelpContents {
    /// The sections, in the order the contents list shows them. The ids are the
    /// keys `Sections.md` gives names to.
    public static let sections: [(id: String, topics: [HelpTopicID])] = [
        ("getting-started", [
            .overview,
            .firstComparison,
            .openingFiles,
            .largeFiles
        ]),
        ("reading", [
            .hexView,
            .colors,
            .navigation,
            .search,
            .minimap,
            .bookmarks,
            .segments,
            .fragments
        ]),
        ("changing", [
            .editing,
            .saving,
            .joinDuplicate,
            .benchSafety,
            .flashWrites
        ]),
        ("firmware", [
            .toolsOverview,
            .toolUEFI,
            .toolME,
            .toolFIT,
            .databases,
            .provenance
        ]),
        ("bench", [
            .recipeDonor,
            .recipeBoardData,
            .recipeMECheck,
            .recipeMicrocode,
            .recipeChecksums
        ]),
        ("settings", [
            .settings
        ])
    ]

    /// Every page the book holds, in contents order — what the loader reads and
    /// what the tests count.
    public static var allTopics: [HelpTopicID] { sections.flatMap(\.topics) }
}
