import AppKit
import AppPalette
import HelpBook
import Localization

/// Turns the book's blocks into the attributed text a view draws.
///
/// One renderer for all three places help is shown — the window's body, a
/// term's popover, a `?`'s tooltip — so a page reads the same wherever it is
/// opened. It draws nothing itself: it hands back strings, which is what makes
/// it testable without a window.
public enum HelpText {
    /// Where a link went, when the reader clicked one. Attributed-string links
    /// carry a URL, so the book's two destinations are spelled as one:
    /// `byteripper-help://topic/hex-view`.
    public static let scheme = "byteripper-help"

    public static func url(for link: HelpLink) -> URL {
        switch link {
        case .topic(let id): return URL(string: "\(scheme)://topic/\(id.rawValue)")!
        case .term(let id): return URL(string: "\(scheme)://term/\(id.rawValue)")!
        }
    }

    /// The link a URL stands for, or nil for a URL that is not one of ours —
    /// which is how an ordinary web link in the text would be left to the
    /// system.
    public static func link(from url: URL) -> HelpLink? {
        guard url.scheme == scheme else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { return nil }
        switch url.host {
        case "topic": return .topic(HelpTopicID(id))
        case "term": return .term(HelpTermID(id))
        default: return nil
        }
    }

    // MARK: - Fonts

    /// The text sizes the help is drawn at. Not the dump's font and not the
    /// panel's: help is prose, and prose is read at the system's reading size.
    public enum Size {
        public static let title: CGFloat = 20
        public static let heading: CGFloat = 14
        public static let body: CGFloat = 13
        public static let caption: CGFloat = 11
    }

    // MARK: - Rendering

    /// A page, whole: its title, its summary, and its blocks.
    public static func render(_ topic: HelpTopic) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(title(topic.title))
        if !topic.summary.isEmpty {
            text.append(summary(topic.summary))
        }
        text.append(render(topic.blocks))
        return text
    }

    /// A term, whole: its name, its one sentence, its body, and where else to
    /// look.
    public static func render(_ term: HelpTerm) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(title(term.name))
        text.append(summary(term.summary))
        text.append(render(term.blocks))
        if !term.seeAlso.isEmpty {
            text.append(heading("See also"))
            text.append(render([.bullets(term.seeAlso.map { [linkSpan(for: $0)] })]))
        }
        return text
    }

    /// What a popover shows: the one sentence, and the body under it. Without
    /// the name, which the popover draws as its own header, and without the
    /// see-also list, which belongs to the window.
    public static func renderBrief(_ term: HelpTerm) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(summary(term.summary))
        text.append(render(term.blocks))
        return text
    }

    public static func render(_ blocks: [HelpBlock]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for block in blocks {
            switch block {
            case .heading(let words):
                text.append(heading(words))
            case .paragraph(let spans):
                text.append(paragraph(spans))
            case .bullets(let items):
                for item in items { text.append(listItem(item, marker: "•")) }
            case .steps(let items):
                for (index, item) in items.enumerated() {
                    text.append(listItem(item, marker: "\(index + 1)."))
                }
            case .caution(let spans):
                text.append(caution(spans))
            }
        }
        return text
    }

    // MARK: - The pieces

    private static func title(_ words: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        return NSAttributedString(string: words + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: Size.title, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ])
    }

    /// The lead sentence, set apart from the body: a shade quieter and a size
    /// larger, which is how a reader can take the whole answer from the first
    /// line when that is all they needed.
    private static func summary(_ words: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 12
        style.lineSpacing = 2
        return NSAttributedString(string: words + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: Size.heading),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ])
    }

    private static func heading(_ words: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 12
        style.paragraphSpacing = 4
        return NSAttributedString(string: words + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: Size.heading, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ])
    }

    private static func paragraph(_ spans: [HelpSpan]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        style.lineSpacing = 2
        return line(spans, style: style)
    }

    /// A list item: the marker in the margin and the text hanging off it, so a
    /// wrapped second line starts under the first rather than under the bullet.
    private static func listItem(_ spans: [HelpSpan], marker: String) -> NSAttributedString {
        let indent: CGFloat = 20
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.lineSpacing = 2
        style.headIndent = indent
        style.firstLineHeadIndent = 6
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        let text = NSMutableAttributedString(string: marker + "\t", attributes: [
            .font: NSFont.systemFont(ofSize: Size.body),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ])
        text.append(line(spans, style: style))
        return text
    }

    /// A caution, indented behind a bar's width and drawn in the palette's
    /// caution colour — the same meaning the panels give that colour.
    private static func caution(_ spans: [HelpSpan]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 10
        style.lineSpacing = 2
        style.headIndent = 18
        style.firstLineHeadIndent = 0
        style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
        let text = NSMutableAttributedString(string: "⚠\t", attributes: [
            .font: NSFont.systemFont(ofSize: Size.body),
            .foregroundColor: SemanticColors.caution,
            .paragraphStyle: style
        ])
        text.append(line(spans, style: style, color: SemanticColors.caution))
        return text
    }

    /// One run of spans, ended with a newline so the paragraph style applies to
    /// the whole of it.
    private static func line(_ spans: [HelpSpan],
                             style: NSParagraphStyle,
                             color: NSColor = .labelColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: Size.body)
        for span in spans {
            switch span {
            case .text(let words):
                text.append(NSAttributedString(string: words, attributes: [
                    .font: body, .foregroundColor: color
                ]))
            case .strong(let words):
                text.append(NSAttributedString(string: words, attributes: [
                    .font: NSFont.systemFont(ofSize: Size.body, weight: .semibold),
                    .foregroundColor: color
                ]))
            case .code(let words):
                // The dump's own kind of type for a value the reader will go
                // and look for in the dump.
                text.append(NSAttributedString(string: words, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: Size.body - 1, weight: .regular),
                    .foregroundColor: color
                ]))
            case .link(let words, let link):
                text.append(NSAttributedString(string: words, attributes: [
                    .font: body,
                    .link: url(for: link),
                    .foregroundColor: NSColor.linkColor,
                    .cursor: NSCursor.pointingHand
                ]))
            case .web(let words, let destination):
                // The URL as written, in no scheme of ours, so the text view
                // hands the click to the system and the browser opens it.
                text.append(NSAttributedString(string: words, attributes: [
                    .font: body,
                    .link: destination,
                    .foregroundColor: NSColor.linkColor,
                    .cursor: NSCursor.pointingHand
                ]))
            }
        }
        text.append(NSAttributedString(string: "\n"))
        text.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: text.length))
        return text
    }

    /// The see-also list's rows: a link with nothing but the destination's own
    /// id to show, which the window replaces with its title when it renders.
    private static func linkSpan(for link: HelpLink) -> HelpSpan {
        let book = Help.shared
        switch link {
        case .topic(let id):
            return .link(text: book.topic(id)?.title ?? id.rawValue, link: link)
        case .term(let id):
            return .link(text: book.term(id)?.name ?? id.rawValue, link: link)
        }
    }
}
