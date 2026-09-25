import Foundation

/// One page of the book, as it was written and as a view lays it out.
public struct HelpTopic: Equatable, Sendable, Identifiable {
    public var id: HelpTopicID
    /// The heading of the page, and the row in the contents list.
    public var title: String
    /// The one line a list shows under the title, and the sentence the page
    /// opens with. Written as the `> ` line at the top of the file; empty when
    /// the page did not bother.
    public var summary: String
    public var blocks: [HelpBlock]
    /// The pieces of functionality this page explains, by the anchor the code
    /// declares them under (`Skills/help-coverage`). Metadata, never shown —
    /// what it is for is the check that new functionality did not ship without
    /// a page.
    public var covers: [String]

    public init(id: HelpTopicID, title: String, summary: String,
                blocks: [HelpBlock], covers: [String] = []) {
        self.id = id
        self.title = title
        self.summary = summary
        self.blocks = blocks
        self.covers = covers
    }

    /// Title, summary and body as one string — what a search over the book
    /// matches against.
    public var searchText: String {
        ([title, summary] + [HelpMarkup.plainText(blocks)]).joined(separator: "\n")
    }
}

/// One word the panels show, explained.
///
/// A term is not a small page: it has a *name* (what the panel writes on the
/// row) and a *short* (one sentence, which is all a popover beside that row
/// has room for), and only then a body. That shape is what lets the same entry
/// serve a tooltip, a popover and a page of the glossary without being written
/// three times.
public struct HelpTerm: Equatable, Sendable, Identifiable {
    public var id: HelpTermID
    /// What the term is called, spelled out: "Flash Partition Table (`$FPT`)".
    public var name: String
    /// One sentence. The whole of what a popover shows above the fold.
    public var summary: String
    public var blocks: [HelpBlock]
    /// Where else to look, in the order the author put them.
    public var seeAlso: [HelpLink]
    /// The glossary this term is listed under.
    public var group: HelpTermGroup

    public init(id: HelpTermID, name: String, summary: String,
                blocks: [HelpBlock], seeAlso: [HelpLink], group: HelpTermGroup) {
        self.id = id
        self.name = name
        self.summary = summary
        self.blocks = blocks
        self.seeAlso = seeAlso
        self.group = group
    }

    public var searchText: String {
        ([id.rawValue, name, summary] + [HelpMarkup.plainText(blocks)]).joined(separator: "\n")
    }
}

/// Which glossary a term belongs to — which is also which file it was written
/// in (`Terms/<raw>.md`). Three, because a reader arrives with one of three
/// questions: what does this app mean by that, what does the UEFI panel mean by
/// that, what does the ME panel mean by that.
public enum HelpTermGroup: String, CaseIterable, Sendable {
    case general
    case uefi
    case me
}
