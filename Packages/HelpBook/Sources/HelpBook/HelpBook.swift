import Foundation

/// The help, loaded: every page, every term, and the contents that order them.
///
/// Built once and held — the whole book is a few dozen small files, and the
/// parse of all of them is well under the time it takes the window to open, so
/// there is no lazier arrangement worth its complexity.
public struct HelpBook: Sendable {
    /// The language the pages were loaded from — `en`, or whichever directory
    /// under `Help/` matched what the user reads.
    public let language: String
    public let sections: [HelpSection]
    /// What each glossary is called in the contents list. From `Sections.md`
    /// under `glossary-<group>`, so it translates with the rest of the words.
    public let glossaryNames: [HelpTermGroup: String]
    private let topicsByID: [HelpTopicID: HelpTopic]
    private let termsByID: [HelpTermID: HelpTerm]
    /// The terms of each glossary, in the order their file listed them.
    private let termsByGroup: [HelpTermGroup: [HelpTermID]]

    public init(language: String,
                sections: [HelpSection],
                topics: [HelpTopic],
                terms: [HelpTerm],
                glossaryNames: [HelpTermGroup: String] = [:]) {
        self.language = language
        self.sections = sections
        self.glossaryNames = glossaryNames
        topicsByID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        termsByID = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        termsByGroup = Dictionary(grouping: terms, by: \.group).mapValues { $0.map(\.id) }
    }

    public func topic(_ id: HelpTopicID) -> HelpTopic? { topicsByID[id] }
    public func term(_ id: HelpTermID) -> HelpTerm? { termsByID[id] }

    /// Every page, in contents order.
    public var topics: [HelpTopic] {
        sections.flatMap { $0.topics.compactMap(topic) }
    }

    /// Every term, in glossary order.
    public var terms: [HelpTerm] {
        HelpTermGroup.allCases.flatMap { self.terms(in: $0) }
    }

    /// What a glossary is called, falling back to its key so a name nobody
    /// wrote is visibly missing rather than blank.
    public func glossaryName(_ group: HelpTermGroup) -> String {
        glossaryNames[group] ?? group.rawValue
    }

    public func terms(in group: HelpTermGroup) -> [HelpTerm] {
        (termsByGroup[group] ?? []).compactMap(term)
    }

    /// What a link points at, as something to show. Nil when the book has
    /// nothing under that id — which the tests make sure never happens for a
    /// link the book itself wrote, but can happen for one a panel names.
    public func destinationExists(_ link: HelpLink) -> Bool {
        switch link {
        case .topic(let id): return topicsByID[id] != nil
        case .term(let id): return termsByID[id] != nil
        }
    }

    // MARK: - Searching

    /// Pages and terms whose text holds `query`, pages first, each in the order
    /// the book lists it.
    ///
    /// A plain case-insensitive, diacritic-insensitive substring match over the
    /// whole of an entry — title, summary and body. Ranking a bench tool's help
    /// would be inventing a problem: the book is forty pages, and what the
    /// reader typed is nearly always a term that appears in two of them.
    public func search(_ query: String) -> [HelpSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return topics.filter { $0.searchText.range(of: needle, options: options) != nil }
            .map(HelpSearchResult.topic)
            + terms.filter { $0.searchText.range(of: needle, options: options) != nil }
            .map(HelpSearchResult.term)
    }
}

/// A hit: the page or the term itself, so the list can show its own title and
/// summary without looking anything up again.
public enum HelpSearchResult: Equatable, Sendable, Identifiable {
    case topic(HelpTopic)
    case term(HelpTerm)

    public var id: String {
        switch self {
        case .topic(let topic): return "topic:" + topic.id.rawValue
        case .term(let term): return "term:" + term.id.rawValue
        }
    }

    public var title: String {
        switch self {
        case .topic(let topic): return topic.title
        case .term(let term): return term.name
        }
    }

    public var summary: String {
        switch self {
        case .topic(let topic): return topic.summary
        case .term(let term): return term.summary
        }
    }

    public var link: HelpLink {
        switch self {
        case .topic(let topic): return .topic(topic.id)
        case .term(let term): return .term(term.id)
        }
    }
}
