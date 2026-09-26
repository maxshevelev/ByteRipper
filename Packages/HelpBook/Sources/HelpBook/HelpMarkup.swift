import Foundation

/// A run of text inside one block: plain words, something emphasised, a value
/// to be shown in the dump's own typeface, or a link to somewhere else in the
/// book.
///
/// Deliberately small. The help is prose for a bench, not a document format:
/// what it needs is a way to stress a word, to quote `0xFF` without it reading
/// as prose, and to point at the page that explains the word it just used.
public enum HelpSpan: Equatable, Sendable {
    case text(String)
    case strong(String)
    /// Shown monospaced: an offset, a signature, a menu path typed as it is.
    case code(String)
    /// `text` is what the reader sees; `link` is where it goes.
    case link(text: String, link: HelpLink)
    /// A link out of the book, to a page on the web. Separate from `link`
    /// because the book's own destinations are pages a `?` button or the
    /// contents list can also point at, and neither can point at the web.
    ///
    /// It exists for one job: a page that states something a datasheet does not
    /// document has to say where the claim comes from, and a reader who wants
    /// to check has to be able to get there.
    case web(text: String, url: URL)
}

/// One block of a page. A page is a list of these, in the order they were
/// written.
public enum HelpBlock: Equatable, Sendable {
    /// A sub-heading inside the page. The page's own title is not a block.
    case heading(String)
    case paragraph([HelpSpan])
    /// An unordered list. Each item is its own run of spans.
    case bullets([[HelpSpan]])
    /// A numbered list — a procedure, which is most of what the bench pages
    /// are. Numbered by the view, so a step inserted in the middle renumbers
    /// itself.
    case steps([[HelpSpan]])
    /// Something to be careful about, drawn apart from the prose around it.
    case caution([HelpSpan])
}

/// The markup the content files are written in, parsed into blocks.
///
/// It is a deliberate handful of Markdown: headings, paragraphs, two kinds of
/// list, a caution line, and four inline forms. Not a Markdown library and not
/// `AttributedString(markdown:)` — the book needs `[[term:fpt]]` to come out as
/// a link a panel can act on, and it needs the result to be a value the pure
/// tests can read, which an attributed string in an AppKit view is not.
///
/// Every rule here is one a translator has to keep, so there are as few as
/// there can be:
///
/// - `## text` — a sub-heading.
/// - `- text` — a bullet; `1. text` (any number) — a step.
/// - `! text` — a caution.
/// - a blank line ends a block; consecutive lines of prose are one paragraph.
/// - `**bold**`, `` `code` ``, `[[topic:id]]`, `[[term:id]]`, and either link
///   form with `|` and the words to show: `[[term:fpt|the partition table]]`.
/// - `[[web:https://…|the words to show]]` — a link out to a source. https
///   only: a page of ours will not send a reader over plain http.
public enum HelpMarkup {
    public static func parse(_ source: String) -> [HelpBlock] {
        var blocks: [HelpBlock] = []
        // The paragraph being gathered: prose lines join up until a blank line
        // or a line that starts a block of another kind.
        var paragraph: [String] = []
        var bullets: [[HelpSpan]] = []
        var steps: [[HelpSpan]] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(spans(paragraph.joined(separator: " "))))
            paragraph = []
        }
        func flushLists() {
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets = []
            }
            if !steps.isEmpty {
                blocks.append(.steps(steps))
                steps = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushLists()
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushAll()
                continue
            }
            if line.hasPrefix("##") {
                flushAll()
                blocks.append(.heading(
                    line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                ))
                continue
            }
            if line.hasPrefix("! ") {
                flushAll()
                blocks.append(.caution(spans(String(line.dropFirst(2)))))
                continue
            }
            if line.hasPrefix("- ") {
                flushParagraph()
                if !steps.isEmpty { flushLists() }
                bullets.append(spans(String(line.dropFirst(2))))
                continue
            }
            if let step = stepBody(of: line) {
                flushParagraph()
                if !bullets.isEmpty { flushLists() }
                steps.append(spans(step))
                continue
            }
            // Prose. A list item's continuation line would land here, so a list
            // in progress ends first — items are one line each, which is a rule
            // worth keeping because it is the one that makes translating a list
            // a line-for-line job.
            flushLists()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    /// The text after the number of a step line (`1. Open the dump.`), or nil
    /// when the line is not one. The number itself is thrown away: the view
    /// numbers the steps, so a step added in the middle of a translated page
    /// cannot be given the wrong number.
    private static func stepBody(of line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return String(rest.dropFirst(2))
    }

    /// One line of text, cut into its runs.
    ///
    /// Scanned once, left to right, rather than run through a chain of regular
    /// expressions: the four forms cannot nest — a link's text is words, an
    /// emphasis holds no code — so a single pass is both the simplest reading
    /// and the one with no order-of-application surprises.
    public static func spans(_ line: String) -> [HelpSpan] {
        var result: [HelpSpan] = []
        var plain = ""
        var rest = Substring(line)

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(.text(plain))
            plain = ""
        }

        while let next = rest.first {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                flushPlain()
                result.append(.strong(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])))
                rest = rest[end.upperBound...]
                continue
            }
            if next == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                flushPlain()
                result.append(.code(String(rest[rest.index(after: rest.startIndex)..<end])))
                rest = rest[rest.index(after: end)...]
                continue
            }
            if rest.hasPrefix("[["), let end = rest.range(of: "]]") {
                let body = rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]
                if let span = linkSpan(String(body)) {
                    flushPlain()
                    result.append(span)
                    rest = rest[end.upperBound...]
                    continue
                }
            }
            plain.append(next)
            rest = rest.dropFirst()
        }
        flushPlain()
        return result
    }

    /// `topic:opening-files`, `term:fpt`, `web:https://…`, or any of them with
    /// `|the words to show`. Nil for anything else, which leaves the brackets
    /// in the text as written — a page that says `[[` and means it reads as it
    /// was typed rather than losing the line.
    private static func linkSpan(_ body: String) -> HelpSpan? {
        let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        let shown = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        guard let colon = target.firstIndex(of: ":") else { return nil }
        let kind = String(target[target.startIndex..<colon])
        let id = String(target[target.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        switch kind {
        case "topic":
            return .link(text: shown.isEmpty ? id : shown, link: .topic(HelpTopicID(id)))
        case "term":
            return .link(text: shown.isEmpty ? id : shown, link: .term(HelpTermID(id)))
        case "web":
            // https only, and a URL the system can actually open. A source
            // link that silently renders as prose is better than one that
            // renders as a link and goes nowhere.
            guard id.hasPrefix("https://"), let url = URL(string: id) else { return nil }
            return .web(text: shown.isEmpty ? id : shown, url: url)
        default:
            return nil
        }
    }

    /// The blocks as running text, for searching and for a one-line preview.
    /// Links read as the words they show — what the reader sees is what a
    /// search over the book matches.
    public static func plainText(_ blocks: [HelpBlock]) -> String {
        blocks.map(plainText).joined(separator: "\n")
    }

    public static func plainText(_ block: HelpBlock) -> String {
        switch block {
        case .heading(let text): return text
        case .paragraph(let spans), .caution(let spans): return plainText(spans)
        case .bullets(let items), .steps(let items):
            return items.map(plainText).joined(separator: "\n")
        }
    }

    public static func plainText(_ spans: [HelpSpan]) -> String {
        spans.map { span in
            switch span {
            case .text(let t), .strong(let t), .code(let t): return t
            case .link(let text, _), .web(let text, _): return text
            }
        }.joined()
    }

    /// Everywhere the blocks point. What the tests walk to prove the book has
    /// no link into nothing.
    public static func links(in blocks: [HelpBlock]) -> [HelpLink] {
        blocks.flatMap { block -> [HelpLink] in
            switch block {
            case .heading: return []
            case .paragraph(let spans), .caution(let spans): return links(in: spans)
            case .bullets(let items), .steps(let items): return items.flatMap(links(in:))
            }
        }
    }

    private static func links(in spans: [HelpSpan]) -> [HelpLink] {
        spans.compactMap { if case .link(_, let link) = $0 { return link } else { return nil } }
    }

    /// Every link out of the book a page carries — what the tests check for
    /// reachability rather than for a destination inside the book.
    public static func webLinks(in blocks: [HelpBlock]) -> [URL] {
        blocks.flatMap { block -> [URL] in
            switch block {
            case .heading: return []
            case .paragraph(let spans), .caution(let spans): return webLinks(in: spans)
            case .bullets(let items), .steps(let items): return items.flatMap(webLinks(in:))
            }
        }
    }

    private static func webLinks(in spans: [HelpSpan]) -> [URL] {
        spans.compactMap { if case .web(_, let url) = $0 { return url } else { return nil } }
    }
}
