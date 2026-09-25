import AppKit
import HelpBook

/// A row of the help window's contents list: a section, a page, a glossary or
/// one term.
///
/// A class rather than a value because `NSOutlineView` identifies its items by
/// object identity — the same row must be the same object every time it is
/// asked for — and building the whole list once at load is what guarantees that.
final class HelpOutlineRow: NSObject {
    enum Kind {
        /// A section of the contents, or a glossary.
        case group(String)
        case topic(HelpTopic)
        case term(HelpTerm)
    }

    let kind: Kind
    let children: [HelpOutlineRow]

    init(kind: Kind, children: [HelpOutlineRow] = []) {
        self.kind = kind
        self.children = children
        super.init()
    }

    var title: String {
        switch kind {
        case .group(let name): return name
        case .topic(let topic): return topic.title
        case .term(let term): return term.name
        }
    }

    /// Where selecting this row goes. Nil for a group, which is a heading
    /// rather than a destination.
    var link: HelpLink? {
        switch kind {
        case .group: return nil
        case .topic(let topic): return .topic(topic.id)
        case .term(let term): return .term(term.id)
        }
    }

    var isGroup: Bool { if case .group = kind { return true } else { return false } }
}

/// The whole contents list, built once from a book.
///
/// The pages first, in the order `HelpContents` puts them, then one group per
/// glossary. A glossary is part of the contents rather than a separate window
/// because a reader arriving with "what is `$FPT`" and a reader arriving with
/// "how do I compare two dumps" are the same reader ten minutes apart.
enum HelpOutlineModel {
    static func build(from book: HelpBook, glossaryNames: [HelpTermGroup: String]) -> [HelpOutlineRow] {
        var rows = book.sections.map { section in
            HelpOutlineRow(kind: .group(section.name),
                           children: section.topics.compactMap(book.topic).map {
                               HelpOutlineRow(kind: .topic($0))
                           })
        }
        for group in HelpTermGroup.allCases {
            let terms = book.terms(in: group)
            guard !terms.isEmpty else { continue }
            rows.append(HelpOutlineRow(kind: .group(glossaryNames[group] ?? group.rawValue),
                                       children: terms.map { HelpOutlineRow(kind: .term($0)) }))
        }
        return rows
    }

    /// The row a link points at, anywhere in the list — what a `?` button's
    /// jump selects in the sidebar.
    static func row(for link: HelpLink, in rows: [HelpOutlineRow]) -> HelpOutlineRow? {
        for candidate in rows {
            if candidate.link == link { return candidate }
            if let found = row(for: link, in: candidate.children) { return found }
        }
        return nil
    }
}
