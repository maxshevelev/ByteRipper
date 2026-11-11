import AppKit
import Find

/// The code panel's side of a search (#41): where the Find bar stands, which
/// text it searches, and how a match is shown.
///
/// The bar is the app's; the search is `finder`. What is here keeps the
/// finder's content in step with the text on screen and draws what it holds:
/// every match under a grey fill — the dump's — and the reader's match
/// selected, scrolled to and flashed.
extension CodePaneView {
    /// Which text a search of the panel reads.
    public enum FindSide: Equatable {
        /// The decompiled C of the function on screen. The listing is not
        /// searched: a search with the listing on screen shows the C.
        case c
        /// The module description, while it is open.
        case description
    }

    // MARK: - The bar

    /// Puts `bar` across the top of the code area: over the code or the
    /// description, never over the navigator. A bar another view holds moves
    /// here.
    public func showFindBar(_ bar: NSView) {
        findBarSlot.bar = bar
        wireFinder()
        findTextMayHaveChanged()
    }

    /// Takes the bar away, and the search's showing with it; the code gets
    /// the height back.
    public func hideFindBar() {
        findBarSlot.bar = nil
        finder.cancel()
        finder.endHighlighting()
    }

    /// Whether the Find bar is up over this pane's code.
    public var isFindBarShown: Bool {
        guard let bar = findBarSlot.bar else { return false }
        return bar.superview === findBarSlot && !bar.isHidden
    }

    // MARK: - What is searched

    /// The side a search reads now: the description while it is open, the C
    /// otherwise.
    public var findSide: FindSide { showsDescription ? .description : .c }

    /// Readies a search: the listing gives way to the C, and the finder is
    /// given the text on screen.
    public func prepareForFind() {
        if !showsDescription, !showsDecompiledC { showDecompiledC(true) }
        findTextMayHaveChanged()
    }

    /// The text view the side is drawn in.
    func findTextView(_ side: FindSide) -> NSTextView {
        side == .c ? cTextView : descriptionView.textView
    }

    /// Where a search starts: the caret, or the edge of the selection it
    /// would otherwise find again — as in the dump.
    public func findAnchor(_ direction: SearchDirection) -> UInt64 {
        let selection = findTextView(findSide).selectedRange()
        let edge = direction == .forward ? NSMaxRange(selection) : selection.location
        return UInt64(max(0, edge))
    }

    /// The selected text of the side on screen — what ⌘E takes. Nil with
    /// nothing selected.
    public var findSelection: String? {
        let view = findTextView(findSide)
        let range = view.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (view.string as NSString).length else { return nil }
        return (view.string as NSString).substring(with: range)
    }

    /// Whether the keyboard is in the text a search reads.
    public var findTextHasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: findTextView(findSide))
    }

    /// Gives the keyboard to the text a search reads.
    public func focusFoundText() {
        window?.makeFirstResponder(findTextView(findSide))
    }

    /// The text on screen may no longer be what the finder holds — another
    /// function, the description opened or closed, the description read.
    /// The set goes, and a search the reader is running is indexed again over
    /// the new text, so its matches show there too.
    func findTextMayHaveChanged() {
        guard findBarSlot.bar != nil else { return }
        let side = findSide
        let text = findTextView(side).string
        if let searched = findSearched, searched.side == side, searched.text == text { return }
        let carried = finder.isHighlighting ? finder.matches?.query : nil
        findSearched = (side, text)
        finder.invalidate()
        finder.content = TextFindContent(text: text)
        if let carried { finder.index(carried) }
        paintFindMatches()
    }

    // MARK: - Showing

    /// Puts the reader on a match: selected, scrolled to, flashed.
    public func showFindMatch(_ range: Range<UInt64>) {
        guard let searched = findSearched else { return }
        let view = findTextView(searched.side)
        let match = NSRange(location: Int(range.lowerBound), length: Int(range.upperBound - range.lowerBound))
        guard NSMaxRange(match) <= (view.string as NSString).length else { return }
        view.setSelectedRange(match)
        view.scrollRangeToVisible(match)
        if view.window != nil { view.showFindIndicator(for: match) }
    }

    /// The finder's matches, as the text views draw them.
    var findMatchRanges: [NSRange] {
        guard let set = finder.highlightedMatches, set.isHighlightable else { return [] }
        return set.matches(intersecting: 0..<set.extent).map {
            NSRange(location: Int($0.lowerBound), length: Int($0.upperBound - $0.lowerBound))
        }
    }

    private func wireFinder() {
        guard finder.onAppearanceChanged == nil else { return }
        finder.onAppearanceChanged = { [weak self] in self?.findShowingChanged() }
        finder.onFilled = { [weak self] _ in self?.findShowingChanged() }
    }

    private func findShowingChanged() {
        paintFindMatches()
        onFindChanged?()
    }

    /// The grey of the dump's matches, behind every match of the side that
    /// was searched; none in the other.
    func paintFindMatches() {
        let ranges = findMatchRanges
        for side in [FindSide.c, .description] {
            let view = findTextView(side)
            guard let layout = view.layoutManager else { continue }
            let length = (view.string as NSString).length
            layout.removeTemporaryAttribute(.backgroundColor,
                                            forCharacterRange: NSRange(location: 0, length: length))
            guard side == findSearched?.side, findSearched?.text == view.string else { continue }
            for range in ranges where NSMaxRange(range) <= length {
                layout.addTemporaryAttribute(.backgroundColor, value: Self.findMatchFill,
                                             forCharacterRange: range)
            }
        }
    }

    /// The dump's match grey (`HexTheme.matchFill`): one colour for a found
    /// thing, whatever it was found in.
    static let findMatchFill = NSColor.unemphasizedSelectedTextBackgroundColor

    // MARK: - For tests

    /// The ranges the side's text view has under the find fill.
    func paintedFindRanges(_ side: FindSide) -> [NSRange] {
        let view = findTextView(side)
        guard let layout = view.layoutManager else { return [] }
        var found: [NSRange] = []
        var index = 0
        let length = (view.string as NSString).length
        while index < length {
            var effective = NSRange()
            let value = layout.temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                                  effectiveRange: &effective)
            if value != nil { found.append(effective) }
            index = max(NSMaxRange(effective), index + 1)
        }
        return found
    }
}

/// The place over the code area the Find bar stands in: as tall as the bar
/// while one is in it, no height otherwise. The bar is placed by frame, as
/// the surface places it, so it carries no constraints from one host to the
/// other.
final class CodeFindBarSlot: NSView {
    override var isFlipped: Bool { true }

    /// The bar, or nil. Set to a bar another view holds, it moves here; set
    /// to nil, the bar is hidden if it is still here.
    var bar: NSView? {
        didSet {
            if let oldValue, oldValue !== bar, oldValue.superview === self {
                oldValue.isHidden = true
            }
            if let bar {
                bar.translatesAutoresizingMaskIntoConstraints = true
                if bar.superview !== self { addSubview(bar) }
                bar.isHidden = false
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private var shownBar: NSView? {
        guard let bar, bar.superview === self, !bar.isHidden else { return nil }
        return bar
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: shownBar?.fittingSize.height ?? 0)
    }

    override func layout() {
        super.layout()
        shownBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }
}
