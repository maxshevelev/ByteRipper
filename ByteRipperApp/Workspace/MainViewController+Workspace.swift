import ByteRipperCore
import Cocoa
import Workspace

/// A tab's half of the workspace (`Design/WORKSPACE_PLAN.md`): what it writes
/// down about itself, and how it puts that back into a fresh tab.
extension MainViewController {
    /// The tab as it stands: File A and File B, the active pane, the split,
    /// the bookmarks, the minimap and the Find bar.
    func workspaceTab() -> TabState {
        let panes = [windowModel.pane1, windowModel.pane2].map(workspacePane(of:))
        let fraction = mode == .comparison ? comparisonView.map { Double($0.currentFraction) } : nil
        let minimap = surface.minimap
        return TabState(
            panes: panes, activePane: windowModel.activePaneIndex, dividerFraction: fraction,
            bookmarks: windowModel.bookmarkStore.bookmarks.map { BookmarkState(row: $0.row, name: $0.name) },
            surface: SurfaceState(
                minimapVisible: minimap.isPanelVisible,
                minimapMode: minimap.isPanelVisible ? minimap.view.renderMode.rawValue : nil,
                findPattern: openFindPattern.map { FindPatternState(text: $0.text, encoding: $0.encoding.rawValue) }))
    }

    /// One pane, or nil when there is nothing in it that could be opened
    /// again.
    private func workspacePane(of pane: PaneViewModel) -> PaneState? {
        guard pane.isOpen, !pane.isUntitled, let document = pane.document else { return nil }
        let stamp = FileStamp(url: document.url)
            ?? FileStamp(path: document.url.standardizedFileURL.path, size: pane.fileSize, modified: nil)
        let selection = document.selection
        return PaneState(
            document: .file(stamp),
            selectionStart: selection.start, selectionEnd: selection.end,
            inputRegion: pane.inputRegion == .ascii ? .text : .hex,
            insertMode: pane.isInsertMode,
            topOffset: filePaneView(for: pane)?.firstVisibleOffset ?? 0,
            segments: pane.workspaceSegments())
    }

    /// Opens what `tab` had open and puts every pane back where it was.
    /// Returns what could not be brought back as it was. Asks nothing: a file
    /// that is gone is reported, not alerted about, and nothing is added to
    /// Open Recent — the files were opened by the person, last session.
    func restoreWorkspaceTab(_ tab: TabState) -> [RestoreIssue] {
        var issues: [RestoreIssue] = []
        // A pane alone is File A, whichever slot it was written from.
        let saved = tab.panes.compactMap { $0 }
        var opened: [(pane: PaneViewModel, state: PaneState, unchanged: Bool)] = []
        for state in saved.prefix(2) {
            guard case let .file(stamp) = state.document else { continue }
            guard let current = FileStamp(url: stamp.url) else {
                issues.append(.missing(path: stamp.path))
                continue
            }
            let pane = opened.isEmpty ? windowModel.pane1 : windowModel.pane2
            do {
                try pane.open(url: stamp.url)
            } catch {
                issues.append(.missing(path: stamp.path))
                continue
            }
            let unchanged = stamp.isUnchanged(comparedWith: current)
            if !unchanged { issues.append(.changed(path: stamp.path)) }
            opened.append((pane, state, unchanged))
        }
        guard !opened.isEmpty else { return issues }

        // Before the panes are built, so they draw the marks from the start:
        // a seeded store reports nothing (`BookmarkStore.seed`).
        let largest = opened.map(\.pane.fileSize).max()
        windowModel.bookmarkStore.seed(tab.bookmarks.restorable(withinLargest: largest).map {
            Bookmark(row: BookmarkStore.row(containing: $0.row), name: $0.name)
        })

        let active = saved.count == opened.count ? min(tab.activePane, opened.count - 1) : 0
        windowModel.setActivePane(active)
        refreshToolPanelHeader()
        refreshMode()

        for entry in opened {
            let restore = PaneRestore(entry.state, size: entry.pane.fileSize, unchanged: entry.unchanged)
            entry.pane.select(range: restore.selection)
            entry.pane.setInputRegion(restore.inputRegion == .text ? .ascii : .hex)
            if restore.insertMode != entry.pane.isInsertMode { flipInsertMode(of: entry.pane) }
            if let segments = entry.state.segments,
               segments.applies(toSize: entry.pane.fileSize, unchanged: entry.unchanged) {
                entry.pane.restoreSegments(segments)
            }
        }
        if tab.surface.minimapVisible {
            surface.minimap.setPanelVisible(true, animated: false)
            if let mode = tab.surface.minimapMode.flatMap(MinimapView.RenderMode.init(rawValue:)) {
                surface.minimap.setRenderMode(mode)
            }
        }
        if let fraction = tab.dividerFraction, mode == .comparison {
            comparisonView?.setFraction(CGFloat(fraction))
        }
        // The rows on screen are a matter of layout, so the tab lays out
        // first: a scroll into a view with no height lands nowhere.
        view.layoutSubtreeIfNeeded()
        for entry in opened {
            let restore = PaneRestore(entry.state, size: entry.pane.fileSize, unchanged: entry.unchanged)
            filePaneView(for: entry.pane)?.scrollRowToTop(containing: restore.topOffset)
        }
        if mode == .comparison { activatePane(at: active) }
        if let find = tab.surface.findPattern {
            reopenFindBar(text: find.text, encoding: SearchEncoding(rawValue: find.encoding) ?? .hex)
        }
        return issues
    }
}
