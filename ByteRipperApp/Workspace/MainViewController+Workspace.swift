import ByteRipperCore
import Cocoa
import Localization
import PartCodec
import ToolModuleKit
import UEFIImage
import Workspace

/// A pane a restore opened, and whether its document is still the one the
/// workspace was written from.
struct RestoredPane {
    let pane: PaneViewModel
    let unchanged: Bool
}

/// What restoring a tab's own panes opened, for the panels to be put back on
/// top of them.
struct TabRestore {
    var issues: [RestoreIssue] = []
    /// The panes by the slot they were written from (`TabState.panes`).
    var slots: [Int: RestoredPane] = [:]
}

/// A tab's half of the workspace (`Design/WORKSPACE_PLAN.md`): what it writes
/// down about itself, and how it puts that back into a fresh tab.
extension MainViewController {
    /// The tab as it stands: File A and File B, the active pane, the split,
    /// the bookmarks, the minimap, the Find bar and the panels. Untitled
    /// documents are written down through `keeper`, and left out without one.
    func workspaceTab(keeper: UntitledKeeper? = nil) -> TabState {
        let panes = [windowModel.pane1, windowModel.pane2].map { workspacePane(of: $0, keeper: keeper) }
        let fraction = mode == .comparison ? comparisonView.map { Double($0.currentFraction) } : nil
        var state = TabState(
            panes: panes, activePane: windowModel.activePaneIndex, dividerFraction: fraction,
            bookmarks: windowModel.bookmarkStore.bookmarks.map { BookmarkState(row: $0.row, name: $0.name) },
            surface: workspaceSurface(surface))
        state.surface.findPattern = openFindPattern.map {
            FindPatternState(text: $0.text, encoding: $0.encoding.rawValue)
        }
        (state.fragments, state.expandedFragment) = workspaceFragments(keeper: keeper)
        return state
    }

    private func workspaceSurface(_ surface: DocumentSurface) -> SurfaceState {
        let minimap = surface.minimap
        return SurfaceState(minimapVisible: minimap.isPanelVisible,
                            minimapMode: minimap.isPanelVisible ? minimap.view.renderMode.rawValue : nil,
                            tool: workspaceTool(surface.tools))
    }

    /// The open tool-module, what it has chosen, and the pane it reads.
    private func workspaceTool(_ tools: ToolController) -> ToolState? {
        guard let identifier = tools.activeIdentifier, let bound = tools.boundPane else { return nil }
        let slot: Int? = bound === windowModel.pane1 ? 0 : bound === windowModel.pane2 ? 1 : nil
        let state = (tools.session?.parkedState as? any PersistableToolSessionState)?.encoded
        return ToolState(identifier: identifier, state: state, pane: slot)
    }

    /// One pane, or nil when there is nothing in it that could be opened
    /// again. `source` overrides where its bytes are said to come from — a
    /// part's, which are decoded again from its parent.
    private func workspacePane(of pane: PaneViewModel, keeper: UntitledKeeper?,
                               source override: DocumentSource? = nil) -> PaneState? {
        guard pane.isOpen, let document = pane.document else { return nil }
        let source: DocumentSource
        if let override {
            source = override
        } else if pane.isUntitled {
            guard let stamp = keeper?.stamp(for: pane) else { return nil }
            source = .untitled(stamp)
        } else {
            source = .file(FileStamp(url: document.url)
                ?? FileStamp(path: document.url.standardizedFileURL.path, size: pane.fileSize, modified: nil))
        }
        let selection = document.selection
        return PaneState(
            document: source,
            selectionStart: selection.start, selectionEnd: selection.end,
            inputRegion: pane.inputRegion == .ascii ? .text : .hex,
            insertMode: pane.isInsertMode,
            topOffset: filePaneView(for: pane)?.firstVisibleOffset ?? 0,
            segments: pane.workspaceSegments(),
            uefiOpenRows: pane.uefiState.openUEFIRows.isEmpty
                ? nil : pane.uefiState.openUEFIRows.map(\.path).sorted { $0.lexicographicallyPrecedes($1) })
    }

    /// The panels, in the order they were opened, and the one in front.
    ///
    /// A part whose parent is still open is written as where it came from and
    /// how it was decoded, and is decoded again at restore. One with no
    /// parent, or with a parent closed since or a codec this cannot write, is
    /// written as untitled bytes — it comes back, without its way home.
    private func workspaceFragments(keeper: UntitledKeeper?) -> ([FragmentState], Int?) {
        var states: [FragmentState] = []
        var indexOf: [ObjectIdentifier: Int] = [:]
        var expanded: Int?
        for id in fragments.dock.panels {
            guard let pane = fragments.pane(id), let surface = fragments.surface(id) else { continue }
            var parent: FragmentState.Parent?
            var codec: String?
            var layout: String?
            var range: Range<UInt64> = 0..<0
            if let origin = pane.origin, origin.state != .parentClosed, let from = origin.parent,
               let codecState = PartCodecState(origin.codec) {
                if from === windowModel.pane1 {
                    parent = .pane(0)
                } else if from === windowModel.pane2 {
                    parent = .pane(1)
                } else if let index = indexOf[ObjectIdentifier(from)] {
                    parent = .fragment(index)
                }
                if parent != nil {
                    codec = PartCodecState.text(codecState)
                    layout = PartCodecState.text(origin.layout)
                    range = origin.sourceRange
                }
            }
            let source: DocumentSource? = parent == nil ? nil : .part(size: pane.fileSize)
            guard let paneState = workspacePane(of: pane, keeper: keeper, source: source) else { continue }
            if fragments.expanded == id { expanded = states.count }
            indexOf[ObjectIdentifier(pane)] = states.count
            states.append(FragmentState(
                parent: parent, sourceStart: range.lowerBound, sourceEnd: range.upperBound,
                name: pane.status.fileName, layout: layout, codec: codec,
                pane: paneState, surface: workspaceSurface(surface)))
        }
        return (states, expanded)
    }

    // MARK: - Restoring

    /// Opens what `tab` had open and puts every pane back where it was.
    /// Returns what could not be brought back as it was. Asks nothing: a file
    /// that is gone is reported, not alerted about, and nothing is added to
    /// Open Recent — the files were opened by the person, last session.
    ///
    /// The panels come back after, in `restoreWorkspaceFragments`: a part may
    /// have to be decompressed again, which is not done on the main actor.
    func restoreWorkspaceTab(_ tab: TabState, keeper: UntitledKeeper? = nil) -> TabRestore {
        var result = TabRestore()
        var opened: [(slot: Int, pane: PaneViewModel, state: PaneState, unchanged: Bool)] = []
        for (slot, saved) in tab.panes.prefix(2).enumerated() {
            guard let state = saved else { continue }
            // A pane alone is File A, whichever slot it was written from.
            let pane = opened.isEmpty ? windowModel.pane1 : windowModel.pane2
            guard let unchanged = open(state.document, in: pane, keeper: keeper, issues: &result.issues)
            else { continue }
            opened.append((slot, pane, state, unchanged))
            result.slots[slot] = RestoredPane(pane: pane, unchanged: unchanged)
        }
        guard !opened.isEmpty else { return result }

        // Before the panes are built, so they draw the marks from the start:
        // a seeded store reports nothing (`BookmarkStore.seed`).
        let largest = opened.map(\.pane.fileSize).max()
        windowModel.bookmarkStore.seed(tab.bookmarks.restorable(withinLargest: largest).map {
            Bookmark(row: BookmarkStore.row(containing: $0.row), name: $0.name)
        })

        let savedCount = tab.panes.prefix(2).compactMap { $0 }.count
        let active = savedCount == opened.count ? min(tab.activePane, opened.count - 1) : 0
        windowModel.setActivePane(active)
        refreshToolPanelHeader()
        refreshMode()

        for entry in opened {
            apply(entry.state, to: entry.pane, unchanged: entry.unchanged)
        }
        apply(tab.surface, to: surface)
        if let fraction = tab.dividerFraction, mode == .comparison {
            comparisonView?.setFraction(CGFloat(fraction))
        }
        // The rows on screen are a matter of layout, so the tab lays out
        // first: a scroll into a view with no height lands nowhere.
        view.layoutSubtreeIfNeeded()
        for entry in opened {
            scroll(entry.pane, to: entry.state, unchanged: entry.unchanged)
        }
        if let tool = tab.surface.tool {
            // The tool binds to the active pane as it starts; the one it read
            // is made active for that moment.
            let slot = tool.pane.flatMap { result.slots[$0] } ?? result.slots.values.first
            if let target = slot {
                let index = target.pane === windowModel.pane2 ? 1 : 0
                windowModel.setActivePane(index)
                restoreTool(tool, on: surface.tools, pane: target)
                windowModel.setActivePane(active)
            }
        }
        if mode == .comparison { activatePane(at: active) }
        if let find = tab.surface.findPattern {
            reopenFindBar(text: find.text, encoding: SearchEncoding(rawValue: find.encoding) ?? .hex)
        }
        return result
    }

    /// Puts the panels back over the panes `restored` opened, parents first,
    /// decoding each part from its parent as it is now. A part whose parent
    /// did not come back, or changed on disk, stays closed: its stretch of
    /// the parent may hold something else.
    func restoreWorkspaceFragments(_ tab: TabState, over restored: TabRestore,
                                   keeper: UntitledKeeper? = nil) async -> [RestoreIssue] {
        var issues: [RestoreIssue] = []
        var panels: [RestoredPane?] = []
        for state in tab.fragments {
            let opened = await restoreFragment(state, over: restored, panels: panels,
                                               keeper: keeper, issues: &issues)
            panels.append(opened)
        }
        if let index = tab.expandedFragment, panels.indices.contains(index),
           let pane = panels[index]?.pane, let id = fragments.panel(holding: pane) {
            fragments.expand(id, animated: false)
        } else if fragments.expanded != nil {
            fragments.collapse(animated: false)
        }
        return issues
    }

    private func restoreFragment(_ state: FragmentState, over restored: TabRestore,
                                 panels: [RestoredPane?], keeper: UntitledKeeper?,
                                 issues: inout [RestoreIssue]) async -> RestoredPane? {
        let id: FragmentDock.PanelID?
        let unchanged: Bool
        if let parentRef = state.parent {
            let parent: RestoredPane?
            switch parentRef {
            case let .pane(slot): parent = restored.slots[slot]
            case let .fragment(index): parent = panels.indices.contains(index) ? panels[index] : nil
            }
            guard let parent, parent.unchanged,
                  let codec = PartCodecState.value(PartCodecState.self, from: state.codec)?.codec,
                  let layout = PartCodecState.value(UEFIRootLayout.self, from: state.layout),
                  state.sourceStart <= state.sourceEnd else { return nil }
            let source = state.sourceStart..<state.sourceEnd
            guard let bytes = await decode(codec, from: parent.pane, source: source, name: state.name),
                  let origin = DocumentOrigin(parent: parent.pane, source: source, partName: state.name,
                                              layout: layout, codec: codec, content: bytes)
            else {
                issues.append(.missing(path: state.name))
                return nil
            }
            id = openFragment(bytes, named: state.name, origin: origin, animated: false)
            if case let .part(size) = state.pane.document {
                unchanged = UInt64(bytes.count) == size
            } else {
                unchanged = false
            }
        } else {
            guard case let .untitled(stamp) = state.pane.document,
                  let bytes = keeper?.bytes(for: stamp) else {
                issues.append(.missing(path: state.name))
                return nil
            }
            id = openFragment([UInt8](bytes), named: stamp.name ?? state.name, animated: false)
            if let id, let pane = fragments.pane(id) {
                if stamp.dirty { pane.document?.undoHistory.clearKeepingDirty() }
                keeper?.adopt(pane, as: stamp)
            }
            unchanged = UInt64(bytes.count) == stamp.size
        }
        guard let id, let pane = fragments.pane(id) else { return nil }
        apply(state.pane, to: pane, unchanged: unchanged)
        if let surface = fragments.surface(id) {
            apply(state.surface, to: surface)
            if let tool = state.surface.tool {
                restoreTool(tool, on: surface.tools, pane: RestoredPane(pane: pane, unchanged: unchanged))
            }
        }
        view.layoutSubtreeIfNeeded()
        scroll(pane, to: state.pane, unchanged: unchanged)
        return RestoredPane(pane: pane, unchanged: unchanged)
    }

    /// A part's bytes, decoded from `parent` as it is now — off the main
    /// actor when the codec says decoding is slow, as `openPart` does.
    private func decode(_ codec: any PartCodec, from parent: PaneViewModel,
                        source: Range<UInt64>, name: String) async -> [UInt8]? {
        guard let document = parent.document, source.upperBound <= document.size,
              let content = try? DocumentPartReader(document: document) else { return nil }
        let partParent = PartParent(content: content, source: source, name: parent.status.fileName,
                                    partName: name)
        if codec.decodesImmediately { return try? codec.decode(partParent) }
        return await Task.detached(priority: .userInitiated) { try? codec.decode(partParent) }.value
    }

    /// Opens a tab pane's document. Returns whether it is unchanged since the
    /// workspace was written, or nil when it could not be opened.
    private func open(_ document: DocumentSource, in pane: PaneViewModel, keeper: UntitledKeeper?,
                      issues: inout [RestoreIssue]) -> Bool? {
        switch document {
        case let .file(stamp):
            guard let current = FileStamp(url: stamp.url) else {
                issues.append(.missing(path: stamp.path))
                return nil
            }
            do {
                try pane.open(url: stamp.url)
            } catch {
                issues.append(.missing(path: stamp.path))
                return nil
            }
            let unchanged = stamp.isUnchanged(comparedWith: current)
            if !unchanged { issues.append(.changed(path: stamp.path)) }
            return unchanged
        case let .untitled(stamp):
            guard let bytes = keeper?.bytes(for: stamp) else {
                issues.append(.missing(path: stamp.name ?? L("Untitled")))
                return nil
            }
            pane.openBytes([UInt8](bytes), named: stamp.name)
            // Work nobody saved is still work nobody saved: closing it asks,
            // as it would have before the app went down.
            if stamp.dirty { pane.document?.undoHistory.clearKeepingDirty() }
            keeper?.adopt(pane, as: stamp)
            return UInt64(bytes.count) == stamp.size
        case .part:
            // A tab's own pane is never a part: parts are panels.
            return nil
        }
    }

    /// The caret, the selection, the typing mode and the cuts.
    private func apply(_ state: PaneState, to pane: PaneViewModel, unchanged: Bool) {
        let restore = PaneRestore(state, size: pane.fileSize, unchanged: unchanged)
        pane.select(range: restore.selection)
        pane.setInputRegion(restore.inputRegion == .text ? .ascii : .hex)
        if restore.insertMode != pane.isInsertMode { flipInsertMode(of: pane) }
        if let segments = state.segments, segments.applies(toSize: pane.fileSize, unchanged: unchanged) {
            pane.restoreSegments(segments)
        }
        if unchanged, let rows = state.uefiOpenRows {
            pane.uefiState.openUEFIRows = Set(rows.map(NodeID.init))
        }
    }

    /// Opens the tool panel on `pane` as it was. What the tool had chosen is
    /// handed back only for a document that is the one it was chosen in.
    private func restoreTool(_ tool: ToolState, on tools: ToolController, pane: RestoredPane) {
        guard let module = ToolRegistry.module(identified: tool.identifier) else { return }
        if pane.unchanged, let data = tool.state, let state = module.restoredState(from: data) {
            tools.park(state, for: tool.identifier, on: pane.pane)
        }
        tools.activate(tool.identifier, animated: false, movesWindow: false)
    }

    private func scroll(_ pane: PaneViewModel, to state: PaneState, unchanged: Bool) {
        let restore = PaneRestore(state, size: pane.fileSize, unchanged: unchanged)
        filePaneView(for: pane)?.scrollRowToTop(containing: restore.topOffset)
    }

    private func apply(_ state: SurfaceState, to surface: DocumentSurface) {
        guard state.minimapVisible else { return }
        surface.minimap.setPanelVisible(true, animated: false)
        if let mode = state.minimapMode.flatMap(MinimapView.RenderMode.init(rawValue:)) {
            surface.minimap.setRenderMode(mode)
        }
    }
}
