import AppKit
import Find
import Localization

/// The navigator's Search tab (#41): one search over the C of every function
/// of the module, its occurrences listed as a tree, and a click that opens
/// the function on the occurrence.
///
/// The query controls are the app's — the same field, case rule, whole-word
/// rule and recent queries as the bar over the code; the pane searches and
/// shows.
extension CodePaneView {
    /// Gives the tab the app's query controls.
    public func setSearchQueryView(_ view: NSView) {
        searchPanel.queryView = view
    }

    /// Puts the Search tab in front of the lists, or the lists back.
    public func showSearchTab(_ shows: Bool) {
        showsSearchTab = shows
        searchPanel.isHidden = !shows
        drawListSwitch()
    }

    /// Searches every function's C for `query` and lists what it finds. The
    /// functions whose code has not been read yet are read first.
    public func searchAllFunctions(_ query: TextQuery) {
        showSearchTab(true)
        searchAllTask?.cancel()
        searchAllTask = nil
        guard !query.text.isEmpty else {
            searchedAll = nil
            searchPanel.clear()
            return
        }
        searchedAll = query
        guard hasCodeToRead else { return runSearchAll(query) }
        searchPanel.show(status: L("Reading all functions…"))
        // A read that fails leaves those functions out; the rest is searched.
        whenRead(nil, quietly: true, otherwise: { [weak self] in
            guard let self, self.searchedAll == query else { return }
            self.runSearchAll(query)
        }) { [weak self] in
            guard let self, self.searchedAll == query else { return }
            self.runSearchAll(query)
        }
    }

    private func runSearchAll(_ query: TextQuery) {
        let corpus = searchCorpus
        searchPanel.show(status: L("Searching…"))
        searchAllTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? TextCorpusSearch.search(query, in: corpus, shouldCancel: { Task.isCancelled })
            }.value
            guard let self, !Task.isCancelled, self.searchedAll == query, let result else { return }
            let items = result.groups.map {
                CodeSearchPanel.FunctionItem(index: $0.id, name: self.navigatorName(of: $0.id), hits: $0.hits)
            }
            self.searchPanel.show(items, truncated: result.isTruncated)
            self.searchAllTask = nil
            self.onSearchAllFinished?(query, !items.isEmpty)
        }
    }

    /// Opens a row of the tab: the function, on its C, and — for an
    /// occurrence — the occurrence selected, scrolled to and flashed.
    func openSearchHit(function: Int, hit: TextSearchHit?) {
        if showsDescription { showDescription(false) }
        selectFunction(at: function)
        showDecompiledC(true)
        guard let hit else { return }
        let range = NSRange(location: Int(hit.range.lowerBound) + cShift,
                            length: Int(hit.range.upperBound - hit.range.lowerBound))
        guard NSMaxRange(range) <= (cTextView.string as NSString).length else { return }
        cTextView.setSelectedRange(range)
        cTextView.scrollRangeToVisible(range)
        if cTextView.window != nil { cTextView.showFindIndicator(for: range) }
    }

    // MARK: - For tests


    /// The tab's tree: each function's name and its occurrences' lines.
    public var searchResultsForTests: [(function: String, lines: [String])] {
        searchPanel.items.map { ($0.name, $0.children.map(\.hit.lineText)) }
    }

    /// What the tab says over its tree.
    public var searchSummaryForTests: String { searchPanel.summaryLabel.stringValue }

    /// Whether a search of every function is still running.
    public var isSearchingAllForTests: Bool { searchAllTask != nil }

    /// Chooses the row at `row` of the tree, as a click would.
    public func chooseSearchRowForTests(_ row: Int) { searchPanel.choose(row: row) }
}
