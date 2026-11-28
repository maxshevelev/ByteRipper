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

// Following links in the C and the listing, the way back, and showing where the reader arrived.
extension CodePaneView {
    // MARK: - Following links, and the way back

    /// A click on a call, a jump's label or a global — in the C or the
    /// listing — goes where it names, as in an IDE: a function opens with its
    /// range as the dump's main zone, an instruction is selected with its
    /// bytes, data selects its bytes in the hex view. The first two are
    /// places Back returns from.
    /// `even`: a move Back returns from even when the function and the
    /// instruction stay what they were.
    func follow(_ link: CodeLink, even: Bool = false) {
        // The code the reader just moved in has the keyboard: ⌘[ goes back
        // here, and the arrows move in the listing.
        takeKeyboard()
        switch link {
        case .function(let index):
            jump { selectFunction(at: index) }
            flashArrival()
        case .line(let line):
            jump(even: even) {
                select(line: line)
                notifyInstruction()
            }
            flashArrival()
        case .bytes(let address):
            // An address inside a function not read yet is an instruction, not data.
            if let pending = model.pendingFunction(holding: address) {
                whenRead([pending]) { [weak self] in
                    guard let self, let link = self.model.link(to: address) else { return }
                    self.follow(link, even: even)
                }
                return
            }
            if let range = dataRange(at: address) {
                selectingBytes = true
                if let onPointBytes { onPointBytes(range) } else { onSelectRange?(range) }
                selectingBytes = false
            }
        case .label(let name):
            // In the same function's C: to the line that defines the label,
            // and to its instruction when the name still spells its address.
            guard let range = labelDefinition(named: name) else { NSSound.beep(); return }
            jump(even: true) {
                if let address = Self.labelAddress(name), let line = model.line(at: address) {
                    select(line: line)
                    notifyInstruction()
                }
                cTextView.setSelectedRange(range)
            }
            flashArrival(cMark: range)
        }
    }

    /// Where `NAME:` stands in the C on screen.
    private func labelDefinition(named name: String) -> NSRange? {
        let text = cTextView.string as NSString
        return shownCTokens.first { token in
            token.kind == .label && token.link == nil && token.start + token.length <= text.length
                && text.substring(with: NSRange(location: token.start, length: token.length)) == name
        }.map { NSRange(location: $0.start, length: $0.length) }
    }

    /// The address a label of Ghidra's own spelling names, `LAB_09dff047`.
    static func labelAddress(_ name: String) -> CodeAddress? {
        guard name.hasPrefix("LAB_") else { return nil }
        return CodeAddress(hex: String(name.dropFirst(4).prefix { $0.isHexDigit }))
    }

    /// The bytes a click on a global selects: a GUID's 16, an integer's or a
    /// pointer's width, or the one byte at the address when the type does
    /// not say.
    private func dataRange(at address: CodeAddress) -> Range<UInt64>? {
        // As wide as its type: a UINT64 is eight bytes, not its first.
        let symbol = artifact.symbols.first { $0.address == address }
        let count = symbol?.type.flatMap(model.width(ofType:)) ?? 1
        return model.moduleRange(of: address, count: count) ?? model.moduleRange(of: address, count: 1)
    }

    private var currentPlace: Place? {
        state.function.map { Place(function: $0, line: state.line) }
    }


    /// How the reader has the code on screen now: both scroll positions, and
    /// in the C the call they followed or the name they asked about. What
    /// they selected by hand is not kept: a function arrived at — Back and
    /// Forward too — starts with no text selected.
    private var currentView: CodeViewPosition {
        CodeViewPosition(listing: tableScroll.contentView.bounds.origin,
                         c: cScroll.contentView.bounds.origin,
                         cMark: leavingCMark,
                         cText: state.function.flatMap { model.functions[$0].c },
                         description: showsDescription ? descriptionView.scrollOrigin : nil,
                         descriptionMark: showsDescription ? leavingDescriptionMark : nil)
    }

    /// Keeps the current place as the reader has it now, before they leave it.
    private func recordCurrentPlace() {
        guard var place = currentPlace else { return }
        place.view = currentView
        navigation.update(place)
    }

    /// Moves somewhere new: the place left is kept, what was ahead of it is
    /// dropped, and the new place becomes the current one.
    /// `even`: a new place even when the function and the instruction stay —
    /// a jump to a label in the same function, whose instruction may be
    /// unknown, is still a move Back returns from.
    func jump(even: Bool = false, _ move: () -> Void) {
        recordCurrentPlace()
        leavingCMark = nil
        leavingDescriptionMark = nil
        move()
        guard let place = currentPlace else { return }
        // Leaving the description for the function on screen is still a
        // move: Back returns to the description.
        let moved = navigation.move(to: place) { here, there in
            !even && here.function == there.function && here.line == there.line && here.view.description == nil
        }
        if moved { historyChanged() }
    }

    func resetHistory() {
        navigation = CodeNavigationHistory(places: currentPlace.map { [$0] } ?? [])
        historyChanged()
    }

    /// Back and forward by address, where in it the reader is, and how each
    /// place was on screen: what a pane drawing another artifact of the same
    /// module — a republished review, another recipe — takes over with
    /// `adoptHistory`.
    public var carriedHistory: CodeHistory {
        recordCurrentPlace()
        let places = navigation.places.map { place in
            CodeLocation(function: artifact.functions.indices.contains(place.function)
                            ? artifact.functions[place.function].entry : nil,
                         address: place.line.flatMap { model.lines.indices.contains($0)
                            ? model.lines[$0].instruction.address : nil })
        }
        return CodeHistory(places: places, index: navigation.index, views: navigation.places.map(\.view))
    }

    /// Takes over another pane's history, place by place, through this
    /// artifact's own numbering; a place this artifact no longer has drops
    /// out. The current place stays where `restore` put it. A place keeps its
    /// scroll positions; its mark in the C only while the function's C is the
    /// same text, since a renamed local moves every offset after it.
    public func adoptHistory(_ carried: CodeHistory) {
        var adopted: [Place] = []
        var current = -1
        for (position, location) in carried.places.enumerated() {
            let found = model.indices(of: location)
            guard let function = found.function else { continue }
            if position == carried.index { current = adopted.count }
            var view = carried.views.indices.contains(position) ? carried.views[position] : CodeViewPosition()
            let c = model.functions[function].c
            if view.cText != c {
                view.cMark = nil
                view.cText = c
            }
            adopted.append(Place(function: function, line: found.line, view: view))
        }
        guard current >= 0, var here = currentPlace else { return }
        // The place on screen stays scrolled as it was in the other pane.
        if here.function == adopted[current].function {
            here.view = adopted[current].view
            show(here.view)
            if let origin = here.view.description {
                showDescription(true)
                if descriptionView.hasDescription {
                    descriptionView.scroll(to: origin)
                } else {
                    pendingDescriptionScroll = origin
                }
            }
        }
        adopted[current] = here
        navigation = CodeNavigationHistory(places: adopted, index: current)
        historyChanged()
    }

    /// Shows the annotations on this module's code: a mark beside each
    /// annotated function in the list, the title at the end of an annotated
    /// instruction's row, and a comment over the function's C.
    public func setNotes(_ notes: [CodeNote]) {
        guard notes != self.notes else { return }
        self.notes = notes
        indexNotes()
        drawNavigator()
        let selected = table.selectedRow
        syncingSelection = true
        table.reloadData()
        if selected >= 0, selected < table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        syncingSelection = false
        drawnC = nil
        updateC()
    }

    /// Places the notes in the functions and the lines read so far.
    func indexNotes() {
        notesByFunction = [:]
        notesByLine = [:]
        for note in notes {
            let place = model.indices(of: note.location)
            if let function = place.function { notesByFunction[function, default: []].append(note) }
            if let line = place.line { notesByLine[line, default: []].append(note) }
        }
    }

    /// Goes to a function, or to an instruction and the function holding it,
    /// as a click on a link would: a place Back returns from. What an
    /// annotation on code and an agent's `open_code` open at.
    public func go(to location: CodeLocation) {
        opensOnDescription = false
        let place = model.indices(of: location)
        if let line = place.line {
            follow(.line(line))
        } else if let function = place.function {
            if location.address != nil, model.isPending(function) {
                whenRead([function]) { [weak self] in self?.go(to: location) }
                return
            }
            follow(.function(function))
        }
    }

    /// Makes the listing — or the C, when that is showing — the first
    /// responder, unless something in this pane already is.
    private func takeKeyboard() {
        guard let window else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) { return }
        if showsRevisionDiff {
            diffView.focus()
            return
        }
        window.makeFirstResponder(showsDecompiledC ? cTextView : table)
    }

    /// Back: the place before the last jump. View ▸ Back (⌘[) calls this
    /// while the code pane has the keyboard.
    public func goBack() {
        guard canGoBack else { return }
        recordCurrentPlace()
        leavingCMark = nil
        leavingDescriptionMark = nil
        if let place = navigation.back() { go(to: place) }
    }

    public func goForward() {
        guard canGoForward else { return }
        recordCurrentPlace()
        leavingCMark = nil
        leavingDescriptionMark = nil
        if let place = navigation.forward() { go(to: place) }
    }

    /// Returns to a place as the reader left it: the same function and
    /// instruction, both scrolled where they were, and the place itself — the
    /// call followed in the C, the instruction in the listing — flashed.
    private func go(to place: Place) {
        selectFunction(at: place.function)
        if let line = place.line, model.lines.indices.contains(line) {
            select(line: line)
            notifyInstruction()
        }
        if let origin = place.view.description {
            showDescription(true)
            descriptionView.scroll(to: origin)
            historyChanged()
            if let mark = place.view.descriptionMark { descriptionView.flash(mark) }
            return
        }
        leaveDescription()
        show(place.view)
        historyChanged()
        flashArrival(cMark: cMarkHere(place.view))
    }

    /// A place's mark, if it is a place in the C on screen: a mark is a range
    /// of the C it was taken from, and in any other text — the function's
    /// code read since, or changed — it would select whatever came to stand
    /// there.
    private func cMarkHere(_ view: CodeViewPosition) -> NSRange? {
        guard let mark = view.cMark, let index = state.function, model.functions.indices.contains(index),
              let c = model.functions[index].c, view.cText == c,
              NSMaxRange(mark) <= (cTextView.string as NSString).length else { return nil }
        return mark
    }

    /// A link in the description: the function it names opens in the code,
    /// or the instruction with its function, as a click on a call would. The
    /// description is the place Back returns to.
    func followFromDescription(_ address: CodeAddress, link: NSRange) {
        let function = model.function(at: address)
        let line = function == nil ? model.line(at: address) : nil
        if function == nil, line == nil, let pending = model.pendingFunction(holding: address) {
            whenRead([pending]) { [weak self] in self?.followFromDescription(address, link: link) }
            return
        }
        guard function != nil || line != nil else {
            NSSound.beep()
            return
        }
        // The jump keeps it with the place it leaves.
        leavingDescriptionMark = link
        jump {
            leaveDescription()
            if let function {
                selectFunction(at: function)
            } else if let line {
                select(line: line)
                notifyInstruction()
            }
        }
        takeKeyboard()
        flashArrival()
    }

    /// Scrolls the listing and the C as a place had them, and selects its
    /// mark in the C.
    private func show(_ view: CodeViewPosition) {
        if let origin = view.listing {
            table.layoutSubtreeIfNeeded()
            scroll(tableScroll, to: origin)
        }
        if let mark = cMarkHere(view) {
            cTextView.setSelectedRange(mark)
        }
        if let origin = view.c {
            if let layout = cTextView.layoutManager, let container = cTextView.textContainer {
                layout.ensureLayout(for: container)
            }
            scroll(cScroll, to: origin)
        }
    }

    /// The row at the top of `table`'s view, and how far into it the view
    /// starts, as a fraction of the row. Read off the clip view, which a
    /// table hidden behind the C still has: its own visible rect is then
    /// empty. A header over the rows insets the clip view by its height
    /// (measured: the origin is at −28 with the first row whole).
    func topRow(of table: NSTableView) -> (row: Int, into: CGFloat)? {
        guard let clip = table.enclosingScrollView?.contentView else { return nil }
        let top = clip.bounds.minY + clip.contentInsets.top
        let row = table.row(at: NSPoint(x: 0, y: max(0, top)))
        guard row >= 0 else { return nil }
        let rect = table.rect(ofRow: row)
        return (row, rect.height > 0 ? max(0, top - rect.minY) / rect.height : 0)
    }

    func scroll(_ table: NSTableView, toTop top: (row: Int, into: CGFloat)) {
        guard let scrollView = table.enclosingScrollView, top.row < table.numberOfRows else { return }
        let rect = table.rect(ofRow: top.row)
        let clip = scrollView.contentView
        let inset = clip.contentInsets.top
        // From the origin that shows the first row whole to the one that shows
        // the last row at the bottom.
        let highest = -inset
        let lowest = max(highest, table.frame.height - clip.bounds.height)
        let y = min(max(highest, rect.minY + top.into * rect.height - inset), lowest)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The character at the top of the C's view, and how far into its line
    /// the view starts, as a fraction of the line.
    func topOfC() -> (character: Int, into: CGFloat)? {
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer,
              let storage = cTextView.textStorage, storage.length > 0 else { return nil }
        let origin = cTextView.textContainerOrigin
        let top = cScroll.contentView.bounds.minY - origin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, top)), in: container)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (layout.characterIndexForGlyph(at: glyph),
                line.height > 0 ? (top - line.minY) / line.height : 0)
    }

    func scrollC(toTop place: (character: Int, into: CGFloat)) {
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer,
              let storage = cTextView.textStorage, place.character < storage.length else { return }
        layout.ensureLayout(for: container)
        cTextView.sizeToFit()
        let glyph = layout.glyphIndexForCharacter(at: place.character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll(cScroll, to: NSPoint(x: cScroll.contentView.bounds.minX,
                                    y: cTextView.textContainerOrigin.y + line.minY + place.into * line.height))
    }

    /// Puts `line` of the function's own C at the top — the notes header
    /// above it is not one of its lines. A line the function no longer has,
    /// because it came back shorter, shows its last part rather than an empty
    /// view below the text.
    func scrollC(toLine line: Int) {
        // The first line's top is the view's own top: the text's inset is not
        // a place to scroll past.
        guard line > 0 else { scroll(cScroll, to: .zero); return }
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer else { return }
        layout.ensureLayout(for: container)
        cTextView.sizeToFit()
        let text = cTextView.string as NSString
        guard let character = cLineStart(line, in: text) else {
            scroll(cScroll, to: NSPoint(x: cScroll.contentView.bounds.minX,
                                        y: CGFloat.greatestFiniteMagnitude))
            return
        }
        let glyph = layout.glyphIndexForCharacter(at: character)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll(cScroll, to: NSPoint(x: cScroll.contentView.bounds.minX,
                                    y: cTextView.textContainerOrigin.y + fragment.minY))
    }

    /// Where `line` of the C begins in the drawn text, the header excluded;
    /// nil for a line past the text's end.
    private func cLineStart(_ line: Int, in text: NSString) -> Int? {
        guard line >= 0 else { return nil }
        var index = min(max(cShift, 0), text.length)
        guard index < text.length else { return nil }
        var at = 0
        while at < line {
            let next = text.range(of: "\n", options: [],
                                  range: NSRange(location: index, length: text.length - index))
            guard next.location != NSNotFound else { return nil }
            index = NSMaxRange(next)
            guard index < text.length else { return nil }
            at += 1
        }
        return index
    }

    /// The line at the top of the code area as it stands, in the space the
    /// screen keeps: the C's own lines, or the new revision's line at the top
    /// of a comparison. Nil while neither is on screen — the listing or the
    /// description is — so a position read there does not overwrite the one
    /// the code had.
    func currentTopLine() -> Int? {
        guard mode == 1 else { return nil }
        if showsRevisionDiff { return diffView.topNewLine }
        guard let place = topOfC() else { return nil }
        let text = cTextView.string as NSString
        let start = min(max(cShift, 0), text.length)
        let end = min(max(place.character, start), text.length)
        return text.substring(with: NSRange(location: start, length: end - start))
            .reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        guard let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds.size
        let y = max(0, min(origin.y, document.frame.height - visible.height))
        let x = max(0, min(origin.x, document.frame.width - visible.width))
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Showing where the reader arrived

    /// What the last arrival flashed, for tests: a row of the listing, or a
    /// range of the C.
    enum Flash: Equatable {
        case row(Int)
        case c(NSRange)
    }

    /// Flashes the place the reader just arrived at, in whichever of the
    /// listing and the C is showing: in the C `cMark` when there is one, else
    /// the call made at the selected instruction, else — a function arrived at
    /// from its start — its name in the signature; in the listing the
    /// selected instruction's row.
    func flashArrival(cMark: NSRange? = nil) {
        lastFlash = nil
        if showsDecompiledC {
            let length = (cTextView.string as NSString).length
            var range = cMark
            if range == nil, let line = state.line, let function = state.selectedFunction,
               let site = function.cSites.first(where: { $0.address == model.lines[line].instruction.address }) {
                range = NSRange(location: site.start + cShift, length: site.length)
            }
            if range == nil, let index = state.function,
               let own = shownCTokens.first(where: { $0.link == .function(index) }) {
                range = NSRange(location: own.start, length: own.length)
            }
            guard let range, range.length > 0, NSMaxRange(range) <= length else { return }
            lastFlash = .c(range)
            cTextView.scrollRangeToVisible(range)
            if cTextView.window != nil { cTextView.showFindIndicator(for: range) }
        } else {
            guard let row = state.selectedRow, row < table.numberOfRows else { return }
            lastFlash = .row(row)
            flashRow(row)
        }
    }

    /// A box over one row of the listing that fades out, as the find
    /// indicator does in the C.
    func flashRow(_ row: Int) {
        flashView?.removeFromSuperview()
        let rect = table.rect(ofRow: row)
        guard !rect.isEmpty else { return }
        let box = NSView(frame: rect.insetBy(dx: 2, dy: 0))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(0.55).cgColor
        box.layer?.cornerRadius = CodeColors.symbolHighlightRadius
        table.addSubview(box)
        flashView = box
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.9
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            box.animator().alphaValue = 0
        } completionHandler: { [weak self, weak box] in
            MainActor.assumeIsolated {
                box?.removeFromSuperview()
                if self?.flashView === box { self?.flashView = nil }
            }
        }
    }

    /// The window's Back and Forward answer `canGoBack` and `canGoForward`
    /// when they are validated, and a jump an agent makes comes with no event
    /// that would validate them.
    private func historyChanged() {
        window?.toolbar?.validateVisibleItems()
    }


    override public func layout() {
        super.layout()
        let width = functionTable.bounds.width
        guard width > 0, abs(width - fittedNavigatorWidth) > 0.5 else { return }
        fittedNavigatorWidth = width
        layOutNavigatorColumns()
    }

    /// What a navigator row means in the list that is showing. The table has
    /// selected the row already; this puts its bytes or its function on screen.
    func selectNavigatorRow(_ row: Int) {
        guard row >= 0, row < state.rowCount else { return }
        syncingSelection = true
        functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        functionTable.scrollRowToVisible(row)
        syncingSelection = false
        let range: Range<UInt64>?
        switch state.list {
        case .functions:
            guard let index = state.function(atRow: row) else { return }
            // Another place of the function in front: nothing to read anew and
            // nowhere to go back from. Its calls move there, and that is all.
            if state.function == index, state.functionOrder == .calls, state.searchText.isEmpty {
                let wayBefore = (0..<state.rowCount).filter { state.isOnChosenWay(atRow: $0) }
                    .compactMap { state.callPath(atRow: $0) }
                keepingChosenRow { foldRows { $0.chooseCallPlace(atRow: row) } }
                // A row kept its cell, and the bold has moved with the way.
                var changed = IndexSet(wayBefore.compactMap { state.row(ofCallPath: $0) })
                changed.formUnion(IndexSet((0..<state.rowCount).filter { state.isOnChosenWay(atRow: $0) }))
                functionTable.reloadData(forRowIndexes: changed,
                                         columnIndexes: IndexSet(functionTable.tableColumns.indices))
                return
            }
            state.chooseCallPlace(atRow: row)
            jump { selectFunction(at: index) }
            return
        case .strings:
            range = model.moduleRange(of: artifact.strings[state.listedStrings[row]])
        case .postCodes:
            showSite(artifact.postCodes[state.listedPostCodes[row]].address)
            return
        case .statusCodes:
            showSite(artifact.statusCodeCalls[state.listedStatusCodes[row]].address)
            return
        }
        if let range { onSelectRange?(range) }
    }

}
