import ALSplitView
import AnalysisProfiles
import AppKit
import AppPalette
import CodeAnalysis
import Find
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

// A name in the code: its occurrences highlighted and stepped through, and what it stands for.
extension CodePaneView {
    // MARK: - Highlighting a symbol

    /// The symbol a token is an occurrence of, or nil for one that is not a
    /// name: a keyword, a type, a constant, an address.
    func symbol(of token: CodeToken, in text: String) -> CodeSymbol? {
        symbol(of: token, in: Array(text.utf16))
    }

    /// The same over the text's UTF-16 units, made once by a caller that
    /// asks for many tokens: a copy of the whole text per token made a click
    /// in a long function's C cost seconds.
    private func symbol(of token: CodeToken, in units: [UTF16.CodeUnit]) -> CodeSymbol? {
        CodeSymbolMatch.symbol(of: token, in: units)
    }

    func highlightedRanges(in tokens: [CodeToken], of text: String) -> [NSRange] {
        guard let highlightedSymbol else { return [] }
        return CodeSymbolMatch.ranges(of: highlightedSymbol, in: tokens, of: text)
    }

    /// The occurrences of the highlighted symbol in the C on screen. What
    /// each token names is worked out once per text shown, so a click costs
    /// a pass over the names, not a reading of the text.
    func highlightedRangesInC() -> [NSRange] {
        guard let highlightedSymbol else { return [] }
        if shownCSymbols == nil {
            let units = Array(cTextView.string.utf16)
            shownCSymbols = shownCTokens.map { symbol(of: $0, in: units) }
        }
        return zip(shownCTokens, shownCSymbols ?? []).compactMap { token, symbol in
            symbol == highlightedSymbol ? NSRange(location: token.start, length: token.length) : nil
        }
    }

    /// Highlights every occurrence of `symbol` — in the C on screen and in the
    /// listing's rows — or clears the highlight.
    public func highlight(_ symbol: CodeSymbol?) {
        guard symbol != highlightedSymbol else { return }
        highlightedSymbol = symbol
        highlightedIn = state.function
        currentOccurrence = nil
        cTextView.highlight(highlightedRangesInC())
        drawOccurrenceBar()
        // Every row, not only the visible ones: the listing may be behind the
        // C, and a row with no view yet costs nothing to reload.
        guard table.numberOfRows > 0 else { return }
        syncingSelection = true
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                         columnIndexes: IndexSet(integer: 0))
        syncingSelection = false
    }

    // MARK: - Stepping through a name's occurrences

    /// One place the highlighted name is at: a range of the C, or a row of
    /// the listing and the range in it.
    struct Occurrence: Equatable {
        var row: Int?
        var range: NSRange
    }

    /// The highlighted name's occurrences in the side on screen, in reading
    /// order. None while the description shows: it is not code.
    func occurrences() -> [Occurrence] {
        guard highlightedSymbol != nil, !showsDescription else { return [] }
        if showsDecompiledC { return highlightedRangesInC().map { Occurrence(row: nil, range: $0) } }
        return listingOccurrences().map { Occurrence(row: $0.row, range: $0.range) }
    }

    /// The listing's rows that name the highlighted symbol, row by row. Read
    /// when asked — a step or the counter — not while the rows are drawn.
    private func listingOccurrences() -> [(row: Int, range: NSRange)] {
        guard highlightedSymbol != nil else { return [] }
        let lines = state.lines
        var found: [(row: Int, range: NSRange)] = []
        for row in 0..<lines.count {
            let shown = model.listingRow(ofLine: lines[lines.startIndex + row].global)
            for range in highlightedRanges(in: shown.tokens, of: shown.text) { found.append((row, range)) }
        }
        return found
    }

    /// Which occurrence the reader is at, counted from 0, and how many there
    /// are — what the counter in the header says.
    var occurrencePosition: (current: Int?, count: Int) {
        (currentOccurrence, occurrences().count)
    }

    // help: panel.code.occurrences
    /// Goes to the next (or the previous) occurrence of the highlighted name
    /// in the C or the listing on screen: selects it, scrolls to it and
    /// flashes it. From the last it goes round to the first, and the app
    /// shows the plate a wrapped search shows. With none current yet, the
    /// step starts from the caret in the C, or the selected row.
    public func goToOccurrence(forward: Bool) {
        let all = occurrences()
        guard !all.isEmpty else { NSSound.beep(); return }
        // Where the reader is when no occurrence is current: the caret in
        // the C, or the selected row.
        let positions = showsDecompiledC ? all.map(\.range.location) : all.map { $0.row ?? 0 }
        let anchor = showsDecompiledC ? cTextView.selectedRange().location : (state.selectedRow ?? -1)
        guard let (target, wrapped) = CodeSymbolMatch.step(forward: forward, current: currentOccurrence,
                                                           positions: positions, anchor: anchor) else { return }
        currentOccurrence = target
        show(all[target])
        drawOccurrenceBar()
        if wrapped, all.count > 1 { onWrapOccurrences?(forward) }
    }

    private func show(_ occurrence: Occurrence) {
        if let row = occurrence.row {
            let lines = state.lines
            guard row < lines.count else { return }
            select(line: lines[lines.startIndex + row].global)
            notifyInstruction()
            lastFlash = .row(row)
            flashRow(row)
        } else {
            cTextView.setSelectedRange(occurrence.range)
            cTextView.scrollRangeToVisible(occurrence.range)
            lastFlash = .c(occurrence.range)
            if cTextView.window != nil { cTextView.showFindIndicator(for: occurrence.range) }
        }
    }

    /// Edit ▸ Find Next (⌘G) and Find Previous (⇧⌘G) in the code panel while
    /// a name is highlighted: they step through its occurrences. With nothing
    /// highlighted the pane does not answer them, and they go on to the
    /// window's find in the dump.
    @objc func findNextMatch() { goToOccurrence(forward: true) }
    @objc func findPreviousMatch() { goToOccurrence(forward: false) }

    override public func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(findNextMatch) || aSelector == #selector(findPreviousMatch) {
            // While the Find bar is open here, ⌘G is the bar's (#41).
            return highlightedSymbol != nil && !showsDescription && !isFindBarShown
                && super.responds(to: aSelector)
        }
        return super.responds(to: aSelector)
    }

    func makeOccurrenceBar() -> NSStackView {
        occurrenceLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        occurrenceLabel.textColor = .secondaryLabelColor
        for (button, symbol, action) in [
            (previousOccurrenceButton, "chevron.up", #selector(previousOccurrenceClicked)),
            (nextOccurrenceButton, "chevron.down", #selector(nextOccurrenceClicked))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .inline
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        ControlHelp.describe(previousOccurrenceButton, name: L("Previous Use"),
                             tooltip: L("Go to the previous use of the highlighted name (⇧⌘G)"))
        ControlHelp.describe(nextOccurrenceButton, name: L("Next Use"),
                             tooltip: L("Go to the next use of the highlighted name (⌘G)"))
        let bar = NSStackView(views: [occurrenceLabel, previousOccurrenceButton, nextOccurrenceButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 2
        bar.setCustomSpacing(6, after: occurrenceLabel)
        bar.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.isHidden = true
        return bar
    }

    @objc private func previousOccurrenceClicked() { goToOccurrence(forward: false) }
    @objc private func nextOccurrenceClicked() { goToOccurrence(forward: true) }

    /// The counter beside the ASM/C switch: "3 of 12" and the two arrows,
    /// while a name is highlighted in the side on screen; "12" until the
    /// reader is at one of them.
    func drawOccurrenceBar() {
        guard let occurrenceBar else { return }
        let count = highlightedSymbol == nil || showsDescription || showsRevisionDiff ? 0 : occurrences().count
        occurrenceBar.isHidden = count == 0
        guard count > 0 else { return }
        if let current = currentOccurrence, current < count {
            occurrenceLabel.stringValue = String(format: L("%1$@ of %2$@"), "\(current + 1)", "\(count)")
        } else {
            occurrenceLabel.stringValue = "\(count)"
        }
    }

    /// What the counter says, for tests; nil while it is hidden.
    var occurrenceCounterText: String? {
        occurrenceBar?.isHidden == false ? occurrenceLabel.stringValue : nil
    }

    /// Whether a click jumps to what it is on: ⌘-click, or a double click.
    /// A plain click highlights, as in Xcode.
    static func isJump(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) || event.clickCount >= 2
    }

    // help: panel.code.highlight
    /// A click in the C: on a name, it highlights the name's every
    /// occurrence; ⌘-click or a double click on a call goes there, and on the
    /// function's own name in its signature shows its callers. A name the
    /// question-mark pointer marks explains itself: a double click asks it,
    /// where ⌘-click still goes to its bytes.
    func clickC(at character: Int?, event: NSEvent) -> Bool {
        pendingFunctionPopover?.cancel()
        clicksInCode += 1
        let token = character.flatMap { index in
            shownCTokens.filter { $0.start <= index && index < $0.start + $0.length }
                .min { $0.length < $1.length }
        }
        // A name the pointer marks with a question mark explains itself on any
        // plain click, a double click included: that is the mark's promise, and
        // a double click that went to the name's bytes instead left the reader
        // somewhere they never asked to be. ⌘ is how those bytes are reached.
        let explained = token.map { token in
            cTextView.explainable.contains(NSRange(location: token.start, length: token.length))
        } ?? false
        let question = explained && event.clickCount >= 2 && !event.modifierFlags.contains(.command)
        if let token, let link = token.link, Self.isJump(event), !question {
            let range = NSRange(location: token.start, length: token.length)
            if case .function(let index) = link {
                // ⌘-click on the function's own name in its signature asks
                // who calls it; on a call it goes to the function.
                if range == signatureName()?.range {
                    highlight(.target(link))
                    if callers(of: index).isEmpty { NSSound.beep() } else { showCallers(of: index, at: range) }
                } else {
                    jumpToDefinition(of: index, from: range)
                }
                return true
            }
            // A link to data selects its bytes in the hex view and moves the
            // code nowhere: no place is recorded and no mark is left on the
            // place the reader stays on, so Back and Forward walk the code
            // alone. The mark belongs to a move the code made.
            if case .bytes = link {
                follow(link)
                return true
            }
            leavingCMark = range
            follow(link)
            return true
        }
        let clicked = token.flatMap { symbol(of: $0, in: cTextView.string) }
        highlight(clicked)
        if let token, clicked != nil {
            currentOccurrence = highlightedRangesInC().firstIndex { $0.location == token.start }
            drawOccurrenceBar()
        }
        if let clicked, case .variable = clicked, Self.isJump(event) {
            selectDefinition(of: clicked)
            return true
        }
        // A plain click on the function's own name in its signature asks
        // who calls it, as a click on an explained name asks what it is.
        if !Self.isJump(event), let token, case .function(let index)? = token.link,
           let own = signatureName(), own.function == index,
           own.range == NSRange(location: token.start, length: token.length), !callers(of: index).isEmpty {
            afterClick(inC: true) { [weak self] in
                self?.showCallers(of: index, at: own.range)
            }
            return false
        }
        if !Self.isJump(event), let token, case .function(let index)? = token.link {
            let range = NSRange(location: token.start, length: token.length)
            let thisClick = clicksInCode
            afterClick(inC: true) { [weak self] in
                // A later click has already said what this one was half of.
                guard self?.clicksInCode == thisClick else { return }
                self?.offerFunctionPopover(index) { [weak self] in
                    guard let self, let rect = self.cRect(range) else { return nil }
                    return (rect, self.cTextView)
                } go: { [weak self] in
                    self?.jumpToDefinition(of: index, from: range)
                }
            }
            return false
        }
        if let character, question || !Self.isJump(event) { explainC(at: character, token: token) }
        return false
    }

    // help: panel.code.function-popover
    /// Opens what a called function is, once the time for a second click has
    /// passed. The place is asked for then: the code may have moved.
    func offerFunctionPopover(_ index: Int, at place: @escaping () -> (NSRect, NSView)?,
                                      go: @escaping () -> Void) {
        guard model.functions.indices.contains(index) else { return }
        pendingFunctionPopover?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The popover quotes the plate, which lies in the function's code.
            self.whenRead([index]) { [weak self] in
                guard let self, let (rect, view) = place(), view.window != nil else { return }
                self.explanationPopover?.close()
                self.callersPopover?.close()
                self.functionPopover?.close()
                let popover = CodeFunctionPopover(function: self.artifact.functions[index],
                                                  mark: self.reviewMark(of: index),
                                                  signatureTokens: self.model.signatureTokens(ofFunction: index),
                                                  onGo: go)
                popover.show(relativeTo: rect, of: view)
                self.functionPopover = popover
            }
        }
        pendingFunctionPopover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.functionPopoverDelay, execute: work)
    }

    /// A function's mark as the list draws it.
    func reviewMark(of index: Int) -> (glyph: CodeNavigatorIcon.Glyph, color: NSColor) {
        let function = artifact.functions[index]
        switch function.reviewLevel {
        case .partial: return CodeNavigatorIcon.partialFunction
        case .decompiled: return CodeNavigatorIcon.decompiledFunction
        case .noBody, .stub: return CodeNavigatorIcon.bodylessFunction
        case .library:
            let section: LibrarySection = switch function.libraryKind {
            case .edk2: .edk2
            case .amd: .amd
            case .intel: .intel
            case .ite: .ite
            case .toolchain: .toolchain
            case nil: .unrecorded
            }
            return CodeNavigatorIcon.library(Self.badge(of: section))
        default: return CodeNavigatorIcon.function
        }
    }

    /// How long a click waits to be sure it is not half of a double click.
    static var functionPopoverDelay: TimeInterval { NSEvent.doubleClickInterval }

    // MARK: - What a name stands for

    // help: panel.code.explain
    /// A click on a name the review explained — a constant's name, a type, a
    /// field, the line for the blocks the decompiler removed — opens what it stands for beside it. After the click is done:
    /// the text view's own tracking of it would otherwise close the popover.
    private func explainC(at character: Int, token: CodeToken?) {
        guard let index = state.function else { return }
        let local = character - cShift
        var found: (CodeExplanation, NSRange)?
        if let token, Self.explainedInC.contains(token.kind),
           let explained = model.explanation(ofC: CodeToken(start: token.start - cShift, length: token.length,
                                                            kind: token.kind, link: token.link), inFunction: index) {
            found = (explained, NSRange(location: token.start, length: token.length))
        } else if let field = model.field(atC: local, inFunction: index),
                  let explained = model.explanation(ofField: field, inFunction: index) {
            found = (explained, NSRange(location: field.start + cShift, length: field.length))
        }
        guard let (explained, range) = found, let rect = cRect(range) else { return }
        afterClick(inC: true) { [weak self] in
            guard let self else { return }
            self.showExplanation(explained, relativeTo: rect, of: self.cTextView)
            self.explainedInC = range
        }
    }

    /// Runs `show` once the press ends — after the text view's or the table's
    /// own tracking of it — and only if it was a click. A press that became a
    /// drag to select text is not a question about the name it started on:
    /// the popover then stays shut (it opened at the end of every selection
    /// that started on an explained name). A drag is the pointer let go more
    /// than a few points from where it went down, or, in the C, a selection
    /// this press made — a selection the reader left there before it is not a
    /// reason to swallow the click.
    func afterClick(inC: Bool, _ show: @escaping () -> Void) {
        let down = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? $0.locationInWindow : nil }
        let selectedBefore = inC ? cTextView.selectedRange() : NSRange()
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self else { return }
            let selected = self.cTextView.selectedRange()
            if inC, selected.length > 0, selected != selectedBefore { return }
            if let down, let up = NSApp.currentEvent, up.type == .leftMouseUp,
               hypot(up.locationInWindow.x - down.x, up.locationInWindow.y - down.y) > Self.clickSlop {
                return
            }
            show()
        }
    }

    /// How far the pointer may move between press and release for the two to
    /// still be a click.
    nonisolated static let clickSlop: CGFloat = 3

    /// A click on a number of the listing that the review named: the same
    /// explanation as the name in the C.
    func explainListing(line: Int, token: CodeToken, text: String, rect: NSRect, in view: NSView) {
        guard token.kind == .constant, let value = Self.listingNumber(text),
              let explained = model.explanation(ofConstant: value, onLine: line) else { return }
        let inTable = table.convert(rect, from: view)
        afterClick(inC: false) { [weak self] in
            guard let self else { return }
            self.showExplanation(explained, relativeTo: inTable, of: self.table)
        }
    }

    /// The kinds of C token a click explains: the names the artifact holds
    /// something about — a constant's name, a type, the removed blocks' line,
    /// a named global, and a p-code operation the processor model named for an
    /// instruction (SIDT written as `InterruptDescriptorTableRegister`).
    /// A field of a structure is found by its place in the C, not by its kind.
    static let explainedInC: Set<CodeToken.Kind> = [.constant, .type, .comment, .global, .pcode]

    /// The names in the C on screen that a click explains: the named
    /// constants and the types the artifact holds, and the fields of those.
    func explainableInC() -> [NSRange] {
        guard let index = state.function else { return [] }
        var ranges = shownCTokens.compactMap { token -> NSRange? in
            guard Self.explainedInC.contains(token.kind),
                  model.explanation(ofC: CodeToken(start: token.start - cShift, length: token.length,
                                                   kind: token.kind, link: token.link), inFunction: index) != nil
            else { return nil }
            return NSRange(location: token.start, length: token.length)
        }
        for field in model.functions[index].cFields
        where model.explanation(ofField: field, inFunction: index) != nil {
            ranges.append(NSRange(location: field.start + cShift, length: field.length))
        }
        return ranges
    }

    /// The numbers of a listing row that the review named.
    func explainableInListing(_ row: (text: String, tokens: [CodeToken]), line: Int) -> [NSRange] {
        let units = Array(row.text.utf16)
        return row.tokens.compactMap { token in
            guard token.kind == .constant, token.start + token.length <= units.count,
                  let value = Self.listingNumber(String(decoding: units[token.start..<token.start + token.length],
                                                        as: UTF16.self)),
                  model.explanation(ofConstant: value, onLine: line) != nil else { return nil }
            return NSRange(location: token.start, length: token.length)
        }
    }

    /// A number as the listing writes it: `0xcf8`, `-0x1`, `12`.
    static func listingNumber(_ text: String) -> UInt64? {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        let negative = digits.hasPrefix("-")
        if negative { digits = digits.dropFirst() }
        let value: UInt64?
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            value = UInt64(digits.dropFirst(2), radix: 16)
        } else {
            value = UInt64(digits)
        }
        guard let value else { return nil }
        return negative ? UInt64(bitPattern: -Int64(bitPattern: value)) : value
    }

    /// `in` is the model the explanation was read from — the earlier
    /// revision's for a line of the diff that revision holds — and `onUse`
    /// where a use it names is followed there.
    func showExplanation(_ explained: CodeExplanation, relativeTo rect: NSRect, of view: NSView,
                                 in read: CodeModel? = nil, onUse: ((Int) -> Void)? = nil) {
        guard view.window != nil else { return }
        // Its list of uses covers the whole module, so it waits for all the code.
        if read == nil, explained.listsUsesAcrossModule, !model.pendingFunctions.isEmpty, onLoadFunctions != nil {
            whenRead(nil) { [weak self] in
                guard let self else { return }
                let clicked = self.explainedInC
                self.showExplanation(self.model.explanationAgain(explained) ?? explained,
                                     relativeTo: rect, of: view, onUse: onUse)
                self.explainedInC = clicked
            }
            return
        }
        explanationPopover?.close()
        explainedInC = nil
        let popover = CodeExplanationPopover(explanation: explained, model: read ?? model)
        popover.onUse = onUse ?? { [weak self] line in self?.goToUse(line) }
        popover.show(relativeTo: rect, of: view)
        explanationPopover = popover
    }

    /// A place under the popover's "Used at": a move Back returns from, even
    /// to the instruction already selected — a click in the C selects the
    /// instruction under it, and the use is often that one.
    public func goToUse(_ line: Int) {
        // The name the popover was opened on is the place left: Back selects
        // and flashes it, as it does the call a jump was made from — without
        // it, Back flashed the function's name and scrolled up to it.
        leavingCMark = explainedInC
        follow(.line(line), even: true)
    }


    /// What the popover open over the code explains, if one is open.
    var shownExplanation: CodeExplanation? {
        guard let explanationPopover, explanationPopover.isShown else { return nil }
        return explanationPopover.explanationShown
    }

    /// Where the popover was put, in the coordinates of the view it was
    /// shown against — for a test.
    var shownExplanationRect: NSRect? { explanationPopover?.shownRect }

    /// The diff's visible area, for a test of where a popover is put.
    var diffBounds: NSRect { diffView.bounds }

    /// The popover's rect in the diff's coordinates, and whether it is
    /// anchored to the diff's scrolling text — for a test.
    var shownExplanationInDiff: (rect: NSRect, followsText: Bool)? {
        guard let popover = explanationPopover, let rect = popover.shownRect, let shown = popover.shownView
        else { return nil }
        return (diffView.convert(rect, from: shown), shown.enclosingScrollView?.documentView === shown)
    }


    /// Where a range of the diff is drawn, in this pane's coordinates — for a
    /// test of what is painted there.
    func diffRectInPane(of range: NSRange) -> NSRect? {
        guard let box = diffView.rect(of: range) else { return nil }
        return convert(box, from: diffView)
    }

    /// The model the open popover reads, and the two the diff holds — for a
    /// test of which revision's model a line was explained from.
    var shownExplanationModel: CodeModel? { explanationPopover?.modelShown }
    var diffBaselineModelForTest: CodeModel? { diffBaselineModel }
    var currentModelForTest: CodeModel { model }

    func shownExplanationClose() {
        explanationPopover?.close()
        explanationPopover = nil
    }

    /// Where characters of the C are drawn, in the text view's coordinates.
    func cRect(_ range: NSRange) -> NSRect? {
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer,
              range.location + range.length <= (cTextView.string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += cTextView.textContainerOrigin.x
        rect.origin.y += cTextView.textContainerOrigin.y
        return rect
    }

    /// The function on screen's own name in its signature: the first token
    /// that names it.
    func signatureName() -> (function: Int, range: NSRange)? {
        guard let index = state.function,
              let own = shownCTokens.first(where: { $0.link == .function(index) }) else { return nil }
        return (index, NSRange(location: own.start, length: own.length))
    }

    /// Jump to Definition on a call in the C at `call`: opens the function
    /// called, a place Back returns from. A recursive call's definition is
    /// the signature above it, selected and flashed without a jump.
    func jumpToDefinition(of index: Int, from call: NSRange) {
        guard index != state.function else {
            guard let own = signatureName()?.range else { return }
            cTextView.setSelectedRange(own)
            flashArrival(cMark: own)
            return
        }
        leavingCMark = call
        follow(.function(index))
    }

    /// ⌘-click or a double click on a parameter or a local selects where it
    /// is defined: its first occurrence, since Ghidra writes the parameters in
    /// the signature and declares every local at the top of the body.
    private func selectDefinition(of symbol: CodeSymbol) {
        let text = cTextView.string
        let first: CodeToken? = shownCTokens.first { token in self.symbol(of: token, in: text) == symbol }
        guard let definition = first else { return }
        let range = NSRange(location: definition.start, length: definition.length)
        cTextView.window?.makeFirstResponder(cTextView)
        cTextView.setSelectedRange(range)
        cTextView.scrollRangeToVisible(range)
    }

    /// A click in the listing: on a reference, it highlights the instructions
    /// that refer to the same place; ⌘-click or a double click goes there.
    /// Anywhere else it clears the highlight. The row is selected either way.
    func clickListing(on link: CodeLink?, event: NSEvent, line: Int? = nil) -> Bool {
        if let link, Self.isJump(event) {
            // The row clicked is the place Back returns to, though the jump
            // leaves before the table selects it.
            if let line, model.lines.indices.contains(line), line != state.line { select(line: line) }
            follow(link)
            return true
        }
        highlight(link.map(CodeSymbol.target))
        if link != nil, let line, let row = state.lines.firstIndex(where: { $0.global == line }) {
            currentOccurrence = listingOccurrences().firstIndex { $0.row == row - state.lines.startIndex }
            drawOccurrenceBar()
        }
        return false
    }

    /// Escape clears the highlight.
    public override func cancelOperation(_ sender: Any?) {
        highlight(nil)
    }
}
