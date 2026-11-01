import AppKit
import CodeAnalysis
import Localization
import ToolModuleKit

/// One line of the diff as the pane hands it over: the row, the tokens of the
/// line's code in its function's C, where that line starts in the same text,
/// and which revision's code it is — the one on screen or the one compared
/// with.
struct CodeDiffLine {
    let row: LineDiff.Row
    let tokens: [CodeToken]
    let lineStart: Int
    let currentSide: Bool
}

/// A token of the diff as drawn: where it is in the view's text, the token in
/// its function's C, whose revision it came from, and the link it carries in
/// the view's link table.
struct CodeDiffToken {
    let range: NSRange
    let token: CodeToken
    let currentSide: Bool
    let linkIndex: Int?
}

/// The C of a function against the same function in an earlier revision, as
/// GitHub shows a file's diff: the old line number, the new one, a mark and
/// the line — what only the old review had on red, what only this one has on
/// green, the lines both share as they are. The code is drawn with the
/// artifact's tokens, in the panel's colours, and answers a click as the C
/// does: a name highlights its occurrences, ⌘-click follows a call, a click on
/// a name that explains itself opens its popover.
@MainActor final class CodeDiffView: NSView {
    private let scroll = NSScrollView()
    private let text = CodeTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    /// What the view shows now, for a test; nil while it shows a message.
    private(set) var shownDiff: LineDiff?
    private(set) var shownTokens: [CodeDiffToken] = []
    private(set) var shownLinks: [CodeLink] = []
    /// How many lines the new text adds and the old one loses, for a test.
    var counts: (added: Int, removed: Int)? {
        shownDiff.map { ($0.added, $0.removed) }
    }

    /// A click in the diff, as in the C: the character under it, and the
    /// event for its modifiers and its click count.
    var onClick: ((Int?, NSEvent) -> Bool)? {
        didSet { text.onClick = onClick }
    }
    var onEscape: (() -> Void)? {
        didSet { text.onEscape = onEscape }
    }
    /// The names the question-mark pointer marks.
    var explainable: [NSRange] {
        get { text.explainable }
        set { text.explainable = newValue }
    }

    init() {
        super.init(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 8, height: 12)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = ToolPanelFont.body()
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The diff to show: its rows, and each line's tokens and place in the C
    /// it came from.
    func show(_ diff: LineDiff, lines: [CodeDiffLine], font: NSFont,
              lineHeight: CGFloat, padding: CGFloat) {
        shownDiff = diff
        placeholder.isHidden = true
        scroll.isHidden = false
        let origin = scroll.contentView.bounds.origin
        let shown = NSMutableAttributedString()
        shownTokens = []
        shownLinks = []
        let oldWidth = max(1, String(diff.rows.reduce(0) { max($0, oldNumber($1) ?? 0) }).count)
        let newWidth = max(1, String(diff.rows.reduce(0) { max($0, newNumber($1) ?? 0) }).count)
        let blankOld = String(repeating: " ", count: oldWidth)
        let blankNew = String(repeating: " ", count: newWidth)
        func number(_ value: Int?, width: Int) -> String {
            let shown = value.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, width - shown.count)) + shown
        }
        for line in lines {
            let start = shown.length
            let lineText = text(of: line.row)
            // The gutter and the mark first, in the panel's grey; the code
            // follows with its tokens coloured, as in the C.
            let prefix: String
            var mark: String?
            switch line.row {
            case let .same(old, new, _):
                prefix = " \(number(old, width: oldWidth))  \(number(new, width: newWidth))   "
            case let .removed(old, _):
                prefix = " \(number(old, width: oldWidth))  \(blankNew) - "
                mark = "-"
            case let .added(new, _):
                prefix = " \(blankOld)  \(number(new, width: newWidth)) + "
                mark = "+"
            }
            shown.append(NSAttributedString(string: prefix, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor
            ]))
            if let mark {
                shown.addAttribute(.foregroundColor,
                                   value: mark == "-" ? CodeColors.diffRemovedMark : CodeColors.diffAddedMark,
                                   range: NSRange(location: start + prefix.utf16.count - 2, length: 1))
            }
            let codeStart = shown.length
            let shifted = line.tokens.map {
                CodeToken(start: $0.start - line.lineStart, length: $0.length, kind: $0.kind, link: $0.link)
            }
            var linkCursor = shownLinks.count
            var linkIndices: [Int?] = []
            for token in line.tokens {
                if token.link != nil {
                    linkIndices.append(linkCursor)
                    linkCursor += 1
                } else {
                    linkIndices.append(nil)
                }
            }
            shown.append(CodeColors.attributed(lineText, tokens: shifted, font: font,
                                               links: &shownLinks, asTextLinks: true))
            for (index, token) in line.tokens.enumerated() {
                let range = NSRange(location: codeStart + token.start - line.lineStart, length: token.length)
                guard range.location >= codeStart, range.location + range.length <= shown.length else { continue }
                shownTokens.append(CodeDiffToken(range: range, token: token,
                                                 currentSide: line.currentSide,
                                                 linkIndex: linkIndices[index]))
            }
            shown.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            let rowRange = NSRange(location: start, length: shown.length - start)
            switch line.row {
            case .same: break
            case .removed:
                shown.addAttribute(.backgroundColor, value: CodeColors.diffRemoved, range: rowRange)
            case .added:
                shown.addAttribute(.backgroundColor, value: CodeColors.diffAdded, range: rowRange)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let whole = NSRange(location: 0, length: shown.length)
        shown.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        shown.addAttribute(.baselineOffset, value: padding, range: whole)
        text.highlightInset = padding
        text.textStorage?.setAttributedString(shown)
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            text.sizeToFit()
        }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func text(of row: LineDiff.Row) -> String {
        switch row {
        case let .same(_, _, text), let .removed(_, text), let .added(_, text): text
        }
    }

    /// Says why there is nothing to compare, in the panel's grey.
    func showMessage(_ message: String) {
        shownDiff = nil
        shownTokens = []
        shownLinks = []
        text.textStorage?.setAttributedString(NSAttributedString(string: ""))
        placeholder.stringValue = message
        placeholder.isHidden = false
        scroll.isHidden = true
    }

    private func oldNumber(_ row: LineDiff.Row) -> Int? {
        switch row {
        case let .same(old, _, _), let .removed(old, _): old
        case .added: nil
        }
    }

    private func newNumber(_ row: LineDiff.Row) -> Int? {
        switch row {
        case let .same(_, new, _), let .added(new, _): new
        case .removed: nil
        }
    }

    /// The token whose glyphs are under `character`, if one is.
    func token(at character: Int) -> CodeDiffToken? {
        shownTokens.first { NSLocationInRange(character, $0.range) }
    }

    /// The tokens of the diff that read like `token`: the same word of the
    /// same kind, from either side.
    func occurrences(of token: CodeDiffToken) -> [NSRange] {
        let string = text.string as NSString
        guard token.range.location + token.range.length <= string.length else { return [] }
        let word = string.substring(with: token.range)
        return shownTokens.filter { candidate in
            guard candidate.token.kind == token.token.kind,
                  candidate.range.location + candidate.range.length <= string.length else { return false }
            return string.substring(with: candidate.range) == word
        }.map(\.range)
    }

    /// The rect a range of the diff occupies, for a popover.
    func rect(of range: NSRange) -> NSRect? {
        guard let layout = text.layoutManager, let container = text.textContainer,
              range.location + range.length <= (text.string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
        box.origin.x += text.textContainerOrigin.x
        box.origin.y += text.textContainerOrigin.y
        return box
    }

    func highlight(_ ranges: [NSRange]) { text.highlight(ranges) }
    /// What the diff has highlighted, for a test.
    var highlightedRanges: [NSRange] { text.highlightedRanges }

    /// Gives the diff the keyboard, as a click in it would.
    func focus() { window?.makeFirstResponder(text) }

    /// The diff's text as drawn, for a test.
    var shownText: String { text.string }
    var shownAttributedText: NSAttributedString {
        text.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString()
    }
    /// The background a row is drawn on, for a test: the colour of the first
    /// character of the row holding `line`.
    func background(ofLineContaining line: String) -> NSColor? {
        guard let storage = text.textStorage else { return nil }
        let range = (storage.string as NSString).range(of: line)
        guard range.location != NSNotFound, range.location < storage.length else { return nil }
        return storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
    /// The colour a token reads in, for a test.
    func ink(of range: NSRange) -> NSColor? {
        text.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
    var placeholderText: String? { placeholder.isHidden ? nil : placeholder.stringValue }
    var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }
    func scroll(to origin: NSPoint) {
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
