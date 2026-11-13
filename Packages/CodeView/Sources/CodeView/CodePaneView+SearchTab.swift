import AppKit
import Find
import Localization
import ToolModuleKit

/// The navigator's Search tab (#41): one search over the C of every function
/// of the module and its description, the occurrences listed as a tree, and a
/// click that opens the function, or the description, on the occurrence.
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

    /// Searches what the tab's scope takes in — every function's C, the
    /// description — for `query` and lists what it finds. The functions whose
    /// code has not been read yet are read first.
    public func searchAllFunctions(_ query: TextQuery) {
        showSearchTab(true)
        startSearchAll(query)
    }

    /// The search itself, the tab left in front or not.
    private func startSearchAll(_ query: TextQuery) {
        searchAllTask?.cancel()
        searchAllTask = nil
        guard !query.text.isEmpty else {
            searchedAll = nil
            searchPanel.clear()
            paintFindMatches()
            return
        }
        searchedAll = query
        guard hasCodeToRead, searchPanel.scope != .description else { return runSearchAll(query) }
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
        searchedDescription = descriptionView.hasDescription ? descriptionView.textView.string : nil
        let corpus = searchCorpus
        searchPanel.show(status: L("Searching…"))
        searchAllTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? TextCorpusSearch.search(query, in: corpus, shouldCancel: { Task.isCancelled })
            }.value
            guard let self, !Task.isCancelled, self.searchedAll == query, let result else { return }
            let items = result.groups.map { group -> CodeSearchPanel.GroupItem in
                switch group.id {
                case .description:
                    return CodeSearchPanel.GroupItem(target: .description, name: self.manifest.module.name,
                                                     detail: L("Description"),
                                                     nameMark: self.searchModuleMark(), hits: group.hits)
                case .function(let index):
                    return CodeSearchPanel.GroupItem(
                        target: group.id, name: self.navigatorName(of: index),
                        mark: self.navigatorMark(of: index), hits: group.hits)
                }
            }
            self.searchPanel.show(items, truncated: result.isTruncated)
            self.paintFindMatches()
            self.searchAllTask = nil
            self.onSearchAllFinished?(query, !items.isEmpty)
        }
    }

    /// Opens a row of the tab: the function on its C, or the description,
    /// and — for an occurrence — the occurrence selected, scrolled to and
    /// flashed.
    func openSearchHit(_ target: CodeSearchPanel.Target, hit: TextSearchHit?) {
        let view: NSTextView
        var shift = 0
        switch target {
        case .description:
            showDescription(true)
            view = descriptionView.textView
        case .function(let index):
            if showsDescription { showDescription(false) }
            selectFunction(at: index)
            showDecompiledC(true)
            view = cTextView
            shift = cShift
        }
        guard let hit else { return }
        let range = NSRange(location: Int(hit.range.lowerBound) + shift,
                            length: Int(hit.range.upperBound - hit.range.lowerBound))
        guard NSMaxRange(range) <= (view.string as NSString).length else { return }
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        if view.window != nil { view.showFindIndicator(for: range) }
        showFindPlate(range, in: view)
    }

    /// The module's origin, as the navigator's head draws it before the
    /// name — the category's framed word — in the tab's size. Nil when the
    /// review has not placed the module.
    func searchModuleMark() -> NSImage? {
        ToolPanelOriginBadge.image(for: manifest.reading?.origin,
                                   pointSize: (CodePaneView.navigatorSize * 0.8).rounded())
    }

    // MARK: - Kept with the screen

    /// What the Search tab holds: the search it lists and where it looks —
    /// carried by a screen that moves to another container, and kept in the
    /// workspace. The search is run again when it is put back.
    public struct SearchTabState: Equatable, Sendable {
        public enum Scope: String, Sendable {
            case everywhere, functions, description
        }
        public var query: TextQuery?
        public var scope: Scope

        public init(query: TextQuery?, scope: Scope) {
            self.query = query
            self.scope = scope
        }
    }

    /// The Search tab as it stands; nil while the lists are in front.
    public var searchTabState: SearchTabState? {
        guard showsSearchTab else { return nil }
        let scope: SearchTabState.Scope = switch searchPanel.scope {
        case .everywhere: .everywhere
        case .functions: .functions
        case .description: .description
        }
        return SearchTabState(query: searchedAll, scope: scope)
    }

    /// Puts the Search tab back in front, with its scope, and runs its search
    /// again: the result is the module's as it is now.
    public func restoreSearchTab(_ state: SearchTabState) {
        searchPanel.scope = switch state.scope {
        case .everywhere: .everywhere
        case .functions: .functions
        case .description: .description
        }
        guard let query = state.query, !query.text.isEmpty else { return showSearchTab(true) }
        searchAllFunctions(query)
        onSearchRestored?(query)
    }

    /// The description arrived, or changed, while a search stands: it is
    /// searched again so the description's occurrences are in the result.
    func searchDescriptionAgainIfChanged(_ markdown: String?) {
        guard let query = searchedAll, searchPanel.scope != .functions else { return }
        let text = descriptionView.hasDescription ? descriptionView.textView.string : nil
        guard text != searchedDescription else { return }
        startSearchAll(query)
    }

    // MARK: - For tests


    /// The tab's tree: each group's name — a function's, or the module's for
    /// the description — and its occurrences' lines.
    public var searchResultsForTests: [(function: String, lines: [String])] {
        searchPanel.items.map { ($0.name, $0.children.map(\.hit.lineText)) }
    }

    /// What the tab says over its tree.
    public var searchSummaryForTests: String { searchPanel.summaryLabel.stringValue }

    /// Whether a search of every function is still running.
    public var isSearchingAllForTests: Bool { searchAllTask != nil }

    /// The tab's scope, as the reader would choose it.
    public func setSearchScopeForTests(everywhere: Bool, functions: Bool) {
        searchPanel.scope = everywhere ? .everywhere : functions ? .functions : .description
        searchPanel.onScopeChanged?(searchPanel.scope)
    }

    /// Chooses the row at `row` of the tree, as a click would.
    public func chooseSearchRowForTests(_ row: Int) { searchPanel.choose(row: row) }
}
