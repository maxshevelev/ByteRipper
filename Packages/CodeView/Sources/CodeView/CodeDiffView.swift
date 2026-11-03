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
    /// On a line only the current revision has: the earlier revision never
    /// read it, whatever `currentSide` says of the lines the two share.
    let added: Bool
    let linkIndex: Int?
}

/// Where a line's code sits in the view's text, and where that line starts in
/// its function's C: what a place in one is turned into a place in the other by.
struct CodeDiffCode {
    let range: NSRange
    let lineStart: Int
    let currentSide: Bool
}

/// The C of a function against the same function in an earlier revision, as
/// GitHub shows a file's diff: the old line number, the new one, a mark and
/// the line — what only the old review had on red, what only this one has on
/// green, the lines both share as they are. The code is drawn with the
/// artifact's tokens, in the panel's colours, and answers a click as the C
/// does: a name highlights its occurrences, ⌘-click follows a call or selects
/// a variable's definition, a click on a name or a field that explains itself
/// opens its popover.
@MainActor final class CodeDiffView: NSView {
    private let scroll = NSScrollView()
    private let text = CodeTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    /// What the view shows now, for a test; nil while it shows a message.
    private(set) var shownDiff: LineDiff?
    /// Where each row of the shown text begins, as a UTF-16 offset: what a
    /// line saved for the function is found by.
    private var rowStarts: [Int] = []
    private(set) var shownTokens: [CodeDiffToken] = []
    private(set) var shownLinks: [CodeLink] = []
    private var shownCode: [CodeDiffCode] = []
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
        // The placeholder's margins yield in a pane laid out at no width.
        let insetLeading = placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                              constant: 20)
        let insetTrailing = placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                                 constant: -20)
        insetLeading.priority = NSLayoutConstraint.Priority(999)
        insetTrailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            insetLeading,
            insetTrailing
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
        rowStarts = []
        let origin = scroll.contentView.bounds.origin
        let shown = NSMutableAttributedString()
        var tints: [(range: NSRange, color: NSColor)] = []
        shownTokens = []
        shownLinks = []
        shownCode = []
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
            rowStarts.append(start)
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
                                               links: &shownLinks, asTextLinks: true, spacedCommas: true))
            shownCode.append(CodeDiffCode(range: NSRange(location: codeStart, length: shown.length - codeStart),
                                          lineStart: line.lineStart, currentSide: line.currentSide))
            let added = if case .added = line.row { true } else { false }
            for (index, token) in line.tokens.enumerated() {
                let range = NSRange(location: codeStart + token.start - line.lineStart, length: token.length)
                guard range.location >= codeStart, range.location + range.length <= shown.length else { continue }
                shownTokens.append(CodeDiffToken(range: range, token: token,
                                                 currentSide: line.currentSide, added: added,
                                                 linkIndex: linkIndices[index]))
            }
            shown.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            let rowRange = NSRange(location: start, length: shown.length - start)
            // The row's tint is drawn behind the text with the highlight, not
            // set as a background attribute: an attribute is drawn over the
            // highlight, and a click's box on a changed line would vanish.
            switch line.row {
            case .same: break
            case .removed: tints.append((rowRange, CodeColors.diffRemoved))
            case .added: tints.append((rowRange, CodeColors.diffAdded))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let whole = NSRange(location: 0, length: shown.length)
        shown.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        shown.addAttribute(.baselineOffset, value: padding, range: whole)
        text.highlightInset = padding
        // A selection and a highlight are places in the text: in another text
        // they would mark whatever came to stand there. The same text, drawn
        // again at a new size, keeps them.
        let sameText = text.string == shown.string
        text.textStorage?.setAttributedString(shown)
        if !sameText {
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.highlight([])
        }
        text.rowTints = tints
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            text.sizeToFit()
        }
        // A diff shorter than the one before must not be left scrolled past
        // its end: the clip view keeps an origin it was given, and a short
        // function would read as an empty pane until the reader scrolls.
        let visible = scroll.contentView.bounds.size
        scroll.contentView.scroll(to: NSPoint(x: min(origin.x, max(0, text.frame.width - visible.width)),
                                              y: min(origin.y, max(0, text.frame.height - visible.height))))
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
        rowStarts = []
        text.rowTints = []
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

    /// The place in its function's C of the character `character` is on, and
    /// which revision's C that is.
    func placeInC(at character: Int) -> (offset: Int, currentSide: Bool)? {
        guard let code = shownCode.first(where: { NSLocationInRange(character, $0.range) }) else { return nil }
        return (code.lineStart + character - code.range.location, code.currentSide)
    }

    /// Where the diff shows a span of a revision's C, if a row of it does.
    func range(ofC start: Int, length: Int, currentSide: Bool) -> NSRange? {
        for code in shownCode where code.currentSide == currentSide {
            let offset = start - code.lineStart
            if offset >= 0, offset + length <= code.range.length {
                return NSRange(location: code.range.location + offset, length: length)
            }
        }
        return nil
    }

    /// Where the variable `token` names is defined, as its revision reads it:
    /// its first occurrence there, since Ghidra writes the parameters in the
    /// signature and declares every local at the top of the body. A line only
    /// the other revision has is not looked at.
    func definition(of token: CodeDiffToken) -> NSRange? {
        let variables: Set<CodeToken.Kind> = [.parameter, .local]
        let string = text.string as NSString
        guard variables.contains(token.token.kind),
              token.range.location + token.range.length <= string.length else { return nil }
        let word = string.substring(with: token.range)
        return shownTokens.first { candidate in
            guard variables.contains(candidate.token.kind),
                  token.currentSide ? candidate.currentSide : !candidate.added,
                  candidate.range.location + candidate.range.length <= string.length else { return false }
            return string.substring(with: candidate.range) == word
        }?.range
    }

    /// Selects `range` and brings it into view.
    func select(_ range: NSRange) {
        focus()
        text.setSelectedRange(range)
        text.scrollRangeToVisible(range)
    }
    /// What the diff has selected, for a test.
    var selectedRange: NSRange { text.selectedRange() }

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

    /// The rect a range of the diff occupies, for a popover — in this view's
    /// coordinates, not the text's: the text is the scroll view's document, and
    /// a rect in those coordinates puts the popover at the document's top, not
    /// beside the word clicked.
    func rect(of range: NSRange) -> NSRect? {
        guard let layout = text.layoutManager, let container = text.textContainer,
              range.location + range.length <= (text.string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
        box.origin.x += text.textContainerOrigin.x
        box.origin.y += text.textContainerOrigin.y
        return convert(box, from: text)
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
        return text.rowTints.first { NSLocationInRange(range.location, $0.range) }?.color
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

    // MARK: - Lines

    /// The new revision's line at the top of the view, counted from zero —
    /// the line the C would call its own, so a place kept in the code is the
    /// same place in the comparison. Nil while the view shows no diff, and
    /// while the rows there belong to the old side alone: there is no line of
    /// the function under them.
    var topNewLine: Int? {
        guard let diff = shownDiff, let character = topCharacter() else { return nil }
        let row = rowStarts.lastIndex { $0 <= character } ?? 0
        for row in row..<diff.rows.count {
            if let line = newNumber(diff.rows[row]) { return line - 1 }
        }
        return nil
    }

    /// Reads the diff from the row that shows `line` of the new revision. A
    /// line the diff no longer has — a function that came back shorter —
    /// shows its last part instead of an empty view below the text.
    func scroll(toNewLine line: Int) {
        guard let diff = shownDiff else { return }
        guard line > 0 else { scroll(to: .zero); return }
        if let row = diff.rows.firstIndex(where: { newNumber($0).map { $0 >= line + 1 } ?? false }) {
            scroll(toRow: row)
        } else {
            scrollToBottom()
        }
    }

    /// The character at the top of the visible text.
    private func topCharacter() -> Int? {
        guard let layout = text.layoutManager, let container = text.textContainer else { return nil }
        let top = scroll.contentView.bounds.minY - text.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, top)), in: container)
        return layout.characterIndexForGlyph(at: glyph)
    }

    private func scroll(toRow row: Int) {
        guard rowStarts.indices.contains(row),
              let layout = text.layoutManager, let container = text.textContainer else {
            scrollToBottom()
            return
        }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: rowStarts[row])
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll(insideTheTextTo: NSPoint(x: 0, y: text.textContainerOrigin.y + line.minY))
    }

    private func scrollToBottom() {
        scroll(insideTheTextTo: NSPoint(x: 0, y: CGFloat.greatestFiniteMagnitude))
    }

    /// Moves the clip view, kept inside the text it has: a clip view holds
    /// whatever origin it is given, even one past its document, and a short
    /// diff would then read as an empty view.
    private func scroll(insideTheTextTo origin: NSPoint) {
        let visible = scroll.contentView.bounds.size
        scroll.contentView.scroll(to: NSPoint(
            x: max(0, min(origin.x, max(0, text.frame.width - visible.width))),
            y: max(0, min(origin.y, max(0, text.frame.height - visible.height)))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
