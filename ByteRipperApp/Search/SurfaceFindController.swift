import AppKit
import ByteRipperCore
import Localization

/// The search status bar operation is what a `FindIndexer` shows while it
/// scans: its progress, and its (×).
extension BackgroundOperation: FindActivity {}

/// One surface's Find bar and what its searches do on screen (§11).
///
/// Every surface has one — the tab's, over its panes, and each fragment panel's,
/// over its dump — and each searches only its own panes: the tab's active pane,
/// or the panel's part. The search itself — the pass, the index, the steps — is
/// the searched pane's `FindIndexer`; what is here is the bar, and what an
/// answer does on screen: the selection, the reveal, the plate, the results
/// panel, where the keyboard goes.
///
/// `MainViewController` only delivers the commands — ⌘F, ⌘G, ⌘E, Esc, the
/// toolbar's Find — to the surface in front.
@MainActor final class SurfaceFindController {
    /// The bar, across the top of the surface's content when shown.
    let bar = FindBarView()

    private weak var surface: DocumentSurface?
    private weak var host: MainViewController?

    /// The pane a search goes to: the tab's active pane, or the panel's part.
    var searchedPane: () -> PaneViewModel? = { nil }

    init(surface: DocumentSurface, host: MainViewController?) {
        self.surface = surface
        self.host = host
        bar.isHidden = true
        wireBar()
    }

    private func wireBar() {
        bar.onSearch = { [weak self] request, direction in
            self?.returnsFocusTo = nil
            self?.runSearch(request, direction: direction)
        }
        bar.onSearchAll = { [weak self] request in self?.toggleSearchResults(request) }
        bar.onError = { [weak self] message in self?.showFindMessage(message) }
        bar.onClose = { [weak self] in self?.hide() }
        // A pattern being typed describes no search yet, so the one that was
        // running stops being shown — count and greys together (§11). Its set
        // stays: the file has not moved under it, so a results panel listing it
        // is still telling the truth, until the next search replaces it.
        bar.onPatternEdited = { [weak self] in self?.searchedPane()?.endMatchHighlighting() }
        // Keeping a pattern needs the one thing the bar has not got — a name —
        // so the bar hands over what the field describes and a sheet asks for
        // the rest (§11).
        bar.onAddToFavorites = { [weak self] entry in self?.host?.askToKeepPattern(entry) }
        bar.onManageFavorites = {
            (NSApp.delegate as? AppDelegate)?.showFavoritePatternSettings()
        }
    }

    // MARK: - The bar

    var isShown: Bool { !bar.isHidden && bar.superview != nil }

    /// ⌘F (§11). On a bar that is already open it focuses the field and
    /// selects what is in it — it does **not** prefill.
    ///
    /// Prefilling from the history belongs to *opening* the bar. Doing it on
    /// every ⌘F threw away the pattern the user had come back to fix: a search
    /// that found nothing records nothing, so "the last search" was an older,
    /// successful one, and it replaced what was in the field.
    func show() {
        guard let surface else { return }
        let wasShown = isShown
        surface.showFindBar(bar)
        // The bar lives in the hierarchy between shows, hidden. A layer colour
        // is resolved when it is assigned, and what reaches a view that nobody
        // is drawing is not something to rely on — so the bar re-resolves its
        // own as it appears.
        bar.refreshThemeColors()
        sync()
        surface.view.layoutSubtreeIfNeeded()
        if wasShown {
            bar.focusForEditing()
        } else {
            bar.prepareForShow()
        }
    }

    /// Done, Esc: the bar goes, and so does every search's showing on this
    /// surface. The sets survive, so an open results panel goes on listing the
    /// search that was actually run (§11).
    func hide() {
        host?.notices.dismiss()
        surface?.hideFindBar()
        bar.isHidden = true
        for pane in surface?.panesInMapOrder() ?? [] {
            pane.finder.cancel()
            pane.endMatchHighlighting()
        }
        if let pane = searchedPane() { host?.filePaneView(for: pane)?.focusHexView() }
    }

    /// The toolbar's Find button: a switch, so pressing it again is Done.
    func toggle() {
        if isShown { hide() } else { show() }
    }

    /// Puts the bar in the hierarchy, hidden: it lives there between shows.
    func park() {
        surface?.showFindBar(bar)
        surface?.hideFindBar()
    }

    /// ⌘E: the selection becomes the pattern.
    func stage(_ pattern: SelectionFindPattern) {
        bar.stage(pattern)
    }

    /// Whether the bar matches case — open or closed, the surface's own rule,
    /// kept in the workspace and inherited by a panel taken out of it.
    var caseSensitive: Bool {
        get { bar.query.caseRule }
        set { bar.query.caseRule = newValue }
    }

    /// The pattern of an open bar, for the workspace.
    var openPattern: (text: String, encoding: SearchEncoding)? {
        isShown ? (bar.query.text, bar.query.currentEncoding()) : nil
    }

    /// Opens the bar on `text`, read as `encoding` — a restored workspace's
    /// bar. Runs no search: the highlights come back when the person searches
    /// again.
    func reopen(text: String, encoding: SearchEncoding) {
        show()
        bar.query.select(encoding)
        bar.query.text = text
    }

    /// Hands the bar the searched pane's session: "3 of 128", "Not found", or
    /// nothing at all, and whether its results panel is up (§11). Every
    /// reading is derived on the spot rather than remembered.
    func sync() {
        guard let pane = searchedPane() else { return }
        bar.apply(FindBarView.PaneContext(
            count: FindCount.reading(of: pane.highlightedMatchSet, current: pane.currentMatchIndex),
            resultsShown: host?.filePaneView(for: pane)?.searchResultsPanelVisible == true))
    }

    /// Something about how a search on this surface *looks* changed: the
    /// count is re-read and the surface's map re-marked. Skipped for the map
    /// while its panel is closed: it paints nothing.
    func appearanceChanged() {
        sync()
        guard let surface, surface.minimapPanelVisible else { return }
        surface.minimapView.invalidateCells()
        surface.minimap.scheduleMatchSync()
    }

    /// Stops every search on this surface: its panes are being rebuilt.
    func cancelAll() {
        for pane in surface?.panesInMapOrder() ?? [] { pane.finder.cancel() }
    }

    // MARK: - Find Next and Find Previous

    /// ⌘G / ⇧⌘G: the next match of what the bar holds — or of the find
    /// pasteboard's string, when another search put a new one there. A closed
    /// bar opens, so what is being looked for is on screen, and the keyboard
    /// stays where it was.
    func findAgain(_ direction: SearchDirection, window: NSWindow?) {
        // A reader who pressed ⌘G in the dump goes on reading the dump: the
        // search hands the keyboard back there, not to the field that opening
        // the bar focused. Pressed in the field, it stays in the field.
        let responder = window?.firstResponder
        let inBar = (responder as? NSView)?.isDescendant(of: bar) ?? false
        if !isShown { show() }
        guard let request = bar.requestForFindAgain() else { return }
        returnsFocusTo = inBar ? nil : responder
        runSearch(request, direction: direction)
        if let responder = returnsFocusTo { window?.makeFirstResponder(responder) }
    }

    /// Where the keyboard goes once a ⌘G's search has landed: where it was when
    /// the key was pressed. Nil for a search from the bar, which leaves it in
    /// the field.
    private var returnsFocusTo: NSResponder?

    // MARK: - Searching

    /// A press of Return or ‹ › (§11): a step through the search already in
    /// hand, or a new search.
    private func runSearch(_ request: FindBarView.Request, direction: SearchDirection) {
        guard let pane = searchedPane(), pane.isOpen, let attempts = attempts(for: request) else { return }
        // A search already running here is stepped rather than started again —
        // including the one a Smart Search settled on, whose attempt is
        // usually not the first (the popup names it).
        if steppable(attempts, of: request)
            .contains(where: { pane.hasMatches(for: $0.pattern, folding: $0.folding) }),
           pane.finder.passInFlight == nil {
            step(direction, in: pane)
            return
        }
        pass(attempts, direction: direction, goal: .showTheMatch, in: pane)
    }

    /// Which of the attempts a press may *step* through rather than scan for:
    /// all of them, or — where the user has named an encoding — only that one.
    ///
    /// Switching the popup to UTF-16 while standing on an ASCII match means
    /// "find this as UTF-16", not "the next ASCII one" (§11).
    private func steppable(_ attempts: [SmartSearch.Attempt],
                           of request: FindBarView.Request) -> [SmartSearch.Attempt] {
        guard case .smart(_, _, let preferred) = request, let preferred,
              let first = attempts.first, first.encoding == preferred else {
            return attempts
        }
        return [first]
    }

    /// What the field is asking for, as things to look for: one attempt for a
    /// chosen encoding, Smart Search's list otherwise (§11). Nil when there is
    /// nothing to look for at all, which the bar reports where the count goes.
    private func attempts(for request: FindBarView.Request) -> [SmartSearch.Attempt]? {
        switch request {
        case .pattern(let pattern, let folding):
            return [SmartSearch.Attempt(pattern: pattern, folding: folding,
                                        encodings: [pattern.encoding])]
        case .smart(let text, let caseSensitive, let preferred):
            let attempts = SmartSearch.attempts(for: text, caseSensitive: caseSensitive,
                                                preferring: preferred)
            guard !attempts.isEmpty else {
                bar.reportNoUsablePattern()
                return nil
            }
            return attempts
        }
    }

    /// What a pass does once it knows which encoding to use.
    private enum Goal {
        /// A press of Enter or ‹ ›: put the user on the match.
        case showTheMatch
        /// A press of the results button: list them, and leave the caret alone.
        case listTheMatches
    }

    /// Readies `pane`'s search: its bytes, and the status bar its scans show in.
    private func prepare(_ pane: PaneViewModel) {
        pane.prepareFinder(chunkSize: MainViewController.searchChunkSize)
        pane.finder.beginActivity = { [weak self, weak pane] cancel in
            let operation = BackgroundOperation(name: L("Searching…")) { cancel() }
            if let pane { self?.host?.filePaneView(for: pane)?.beginOperation(operation) }
            return operation
        }
        pane.finder.onFoundSomething = { [weak self] query in
            // An index that turned up matches is a search that found something,
            // so it is remembered — the results button's own case, where no
            // pass ran to say so (§11).
            self?.bar.recordFoundSearch(encoding: query.pattern.encoding)
        }
    }

    /// The candidates in turn until one finds something; then the search is
    /// that one's (§11).
    private func pass(_ attempts: [SmartSearch.Attempt], direction: SearchDirection,
                      goal: Goal, in pane: PaneViewModel) {
        // Whatever a plate is saying is about the search before this one.
        host?.notices.dismiss()
        prepare(pane)
        let anchor = searchAnchor(in: pane, direction: direction)
        // Started here, not inside the task: the search in hand is this one
        // from the press on, so a second press finds it under way.
        let search = pane.finder.start(attempts.map(\.query), from: anchor,
                                       direction: direction, landing: goal == .showTheMatch)
        Task { [weak self] in
            let outcome = await search.value
            guard let self, pane.isOpen else { return }
            switch outcome {
            case .found(let index, _, let range, let wrapped):
                self.adopt(attempts[index], foundAt: range, wrapped: wrapped,
                           direction: direction, goal: goal, in: pane)
            case .nothing:
                self.reportNothingFound(attempts, goal: goal, in: pane)
            case .cancelled, .alreadyRunning:
                break
            }
        }
    }

    /// Where a search starts from: the caret, or the edge of the selection it
    /// would otherwise find again (§11).
    private func searchAnchor(in pane: PaneViewModel, direction: SearchDirection) -> UInt64 {
        let selection = pane.hexSelection()
        return selection.isEmpty ? pane.caretOffset
            : direction == .forward ? selection.end : selection.start
    }

    /// The attempt that found something is *the* search: the bar's popup says
    /// which encoding it was, and the search goes into the history (§11).
    private func adopt(_ attempt: SmartSearch.Attempt, foundAt range: Range<UInt64>,
                       wrapped: Bool, direction: SearchDirection, goal: Goal,
                       in pane: PaneViewModel) {
        bar.adopt(encoding: attempt.encoding)
        bar.recordFoundSearch(encoding: attempt.encoding)
        switch goal {
        case .showTheMatch:
            show(match: range, in: pane)
            if wrapped { host?.showWrapNotice(direction: direction) }
        case .listTheMatches:
            // The results button is not a Find Next: the caret stays where it
            // is, and the panel opens on the index as it fills (§11).
            presentSearchResults(for: pane)
        }
        handOffFocus(from: pane)
    }

    /// A pass where every attempt came back empty (§11). Where there was a
    /// choice of encodings, a plate says which ones were tried.
    private func reportNothingFound(_ attempts: [SmartSearch.Attempt], goal: Goal,
                                    in pane: PaneViewModel) {
        // The button opens the panel whatever the search has to say — here,
        // that nothing came back.
        if goal == .listTheMatches { presentSearchResults(for: pane) }
        if attempts.count > 1 {
            host?.showNotice(symbol: "wand.and.sparkles",
                             lines: [L("Smart search.")]
                                 + attempts.map { L("%1$@ — no results.", $0.label) })
        }
        handOffFocus(from: pane)
    }

    /// The next or previous match of the search in hand (§11): from the index
    /// where it can answer, by one scan where it cannot.
    private func step(_ direction: SearchDirection, in pane: PaneViewModel) {
        prepare(pane)
        let anchor = searchAnchor(in: pane, direction: direction)
        // The index answers at once wherever it can: the press lands before it
        // returns, and a run of ⌘G never queues behind itself.
        if let step = pane.finder.indexedStep(direction, from: anchor) {
            land(on: step.range, wrapped: step.wrapped, direction: direction, in: pane)
            return
        }
        Task { [weak self] in
            let outcome = await pane.finder.step(direction, from: anchor)
            guard let self, pane.isOpen else { return }
            switch outcome {
            case .indexed(let step):
                self.land(on: step.range, wrapped: step.wrapped, direction: direction, in: pane)
            case .scanned(let range, let wrapped):
                self.land(on: range, wrapped: wrapped, direction: direction, in: pane)
            case .notFound:
                self.showFindMessage(L("Not found."))
            case .nothing, .cancelled:
                break
            }
        }
    }

    /// Puts the user on a match a step found, and says so when it wrapped.
    private func land(on range: Range<UInt64>, wrapped: Bool, direction: SearchDirection,
                      in pane: PaneViewModel) {
        show(match: range, in: pane)
        // Said after the move, not instead of it: the plate is the answer and
        // this is the footnote (§11).
        if wrapped { host?.showWrapNotice(direction: direction) }
        handOffFocus(from: pane)
    }

    /// Puts the user on a match: selected, revealed, and under the plate — the
    /// answer looks the same whether or not the index behind it exists yet
    /// (§11).
    private func show(match range: Range<UInt64>, in pane: PaneViewModel) {
        host?.recordJump(in: pane)
        pane.select(range: range)
        // The search keeps its match: selecting it is the reader arriving
        // there, not leaving it.
        pane.highlightMatches(onMatch: range)
        let view = host?.filePaneView(for: pane)
        // A match already on screen moves the highlight, not the page; one off
        // screen is centred (§10.4).
        view?.revealSelectionCenteredIfNeeded()
        // The pop answers the key press — including when a lone match wraps
        // onto itself. Started *after* the reveal, so its first frame is never
        // drawn into a pass a scroll is still rearranging.
        view?.bounceFindIndicator()
    }

    /// A search launched from the bar leaves focus in the pattern field so a
    /// subsequent Enter re-searches; a ⌘G hands it back to where it was; with
    /// the bar hidden it goes to the dump.
    private func handOffFocus(from pane: PaneViewModel) {
        if let responder = returnsFocusTo {
            returnsFocusTo = nil
            bar.window?.makeFirstResponder(responder)
        } else if !isShown {
            host?.filePaneView(for: pane)?.focusHexView()
        } else {
            bar.focusPatternField()
        }
    }

    private func showFindMessage(_ message: String) {
        NSSound.beep()
        if let pane = searchedPane() { host?.filePaneView(for: pane)?.showTransientMessage(message) }
    }

    // MARK: - The results panel

    /// The bar's results button (§11): shows or hides the searched pane's
    /// results panel. When the field holds a pattern nothing has looked for
    /// yet, the search starts here and the panel opens on it.
    private func toggleSearchResults(_ request: FindBarView.Request) {
        guard let pane = searchedPane(), pane.isOpen,
              let paneView = host?.filePaneView(for: pane) else { return }
        if paneView.searchResultsPanelVisible {
            paneView.hideSearchResults()
            sync()
            return
        }
        guard let attempts = attempts(for: request) else { return }
        // The same rule as a press of ‹ ›: a named encoding is what to list,
        // even where another one's index is the one already in hand (§11).
        if steppable(attempts, of: request)
            .contains(where: { pane.hasMatches(for: $0.pattern, folding: $0.folding) }) {
            presentSearchResults(for: pane)
            return
        }
        guard attempts.count > 1 else {
            // One thing to look for needs no scan to pick it: the index itself
            // finds every occurrence, and the panel fills as it does.
            host?.notices.dismiss()
            prepare(pane)
            pane.finder.index(attempts[0].query)
            bar.adopt(encoding: attempts[0].encoding)
            presentSearchResults(for: pane)
            return
        }
        // Which encoding to list is the same question Smart Search answers for
        // a jump, so it is answered the same way (§11).
        pass(attempts, direction: .forward, goal: .listTheMatches, in: pane)
    }

    /// Opens the pane's results panel on its current set (§11). It opens
    /// whatever the search has to say: one still running fills as the index
    /// does, and one that found nothing says so where the rows would be.
    private func presentSearchResults(for pane: PaneViewModel) {
        guard let paneView = host?.filePaneView(for: pane), pane.matchSet != nil else { return }
        paneView.showSearchResults()
        sync()
    }
}
