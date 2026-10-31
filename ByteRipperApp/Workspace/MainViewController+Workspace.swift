import ByteRipperCore
import Cocoa
import CodeAnalysis
import Localization
import PartCodec
import ToolModuleKit
import UEFIImage
import UEFIToolUI
import Workspace

/// A pane a restore opened, and whether its document is still the one the
/// workspace was written from.
struct RestoredPane {
    let pane: PaneViewModel
    var unchanged: Bool
    /// The part had changes kept that could not be read: it opened as its
    /// parent holds it.
    var keptChangesLost = false
}

/// A file opened in a restore's first pass with content kept to lay over it:
/// whether it is still the file the content was made on is settled in the
/// second (`WorkspaceRestorer.settleKeptFiles`).
struct KeptFileCheck {
    let pane: PaneViewModel
    let kept: KeptContent
    let stamp: FileStamp
    let url: URL
    let current: FileStamp
    let id: String?

    /// The file is the one written down: by its SHA-256 when the workspace has
    /// it — a moved date alone does not make another file — by its size and
    /// date when it has not. Read off the main thread.
    func isTheSameFile(progress: (@Sendable (Int) -> Void)? = nil) async -> Bool {
        guard let expected = stamp.sha256 else { return stamp.isUnchanged(comparedWith: current) }
        guard current.size == stamp.size else { return false }
        let url = url
        return await Task.detached(priority: .userInitiated) {
            (try? FileDigest.sha256(of: url, progress: progress))?.hex == expected
        }.value
    }

    /// Whether finding out reads the whole file.
    var readsTheFile: Bool { stamp.sha256 != nil && current.size == stamp.size }
}

/// Names the panes of one snapshot, so a part can name its parent wherever in
/// the workspace that is (`PartOrigin.parent`). One per snapshot: the names
/// mean nothing outside it.
final class WorkspacePaneIDs {
    private var ids: [ObjectIdentifier: String] = [:]

    func id(for pane: PaneViewModel) -> String {
        if let id = ids[ObjectIdentifier(pane)] { return id }
        let id = "p\(ids.count + 1)"
        ids[ObjectIdentifier(pane)] = id
        return id
    }
}

/// A tab's half of the workspace (`Design/WORKSPACE_PLAN.md`): what it writes
/// down about itself, and the steps `WorkspaceRestorer` puts it back with.
extension MainViewController {
    // MARK: - Writing down

    /// The tab as it stands: File A and File B, the active pane, the split,
    /// the bookmarks, the minimap, the Find bar and the panels. Untitled
    /// documents are written down through `keeper`, and left out without one.
    func workspaceTab(keeper: ContentKeeper? = nil, ids: WorkspacePaneIDs = WorkspacePaneIDs()) -> TabState {
        let panes = [windowModel.pane1, windowModel.pane2].map { workspacePane(of: $0, keeper: keeper, ids: ids) }
        let fraction = mode == .comparison ? comparisonView.map { Double($0.currentFraction) } : nil
        var state = TabState(
            panes: panes, activePane: windowModel.activePaneIndex, dividerFraction: fraction,
            bookmarks: windowModel.bookmarkStore.bookmarks.map { BookmarkState(row: $0.row, name: $0.name) },
            surface: workspaceSurface(surface))
        state.surface.findPattern = openFindPattern.map {
            FindPatternState(text: $0.text, encoding: $0.encoding.rawValue)
        }
        state.code = currentCodeScreen().flatMap(workspaceCodeScreen)
        var expanded: Int?
        for id in fragments.dock.panels {
            guard let pane = fragments.pane(id), let surface = fragments.surface(id),
                  let paneState = workspacePane(of: pane, keeper: keeper, ids: ids) else { continue }
            if fragments.expanded == id { expanded = state.fragments.count }
            let code = fragments.content(id)?.code.flatMap(workspaceCodeScreen)
            state.fragments.append(FragmentState(pane: paneState,
                                                 surface: workspaceSurface(surface),
                                                 code: code))
        }
        state.expandedFragment = expanded
        return state
    }

    private func workspaceSurface(_ surface: DocumentSurface) -> SurfaceState {
        let minimap = surface.minimap
        return SurfaceState(minimapVisible: minimap.isPanelVisible,
                            minimapMode: minimap.isPanelVisible ? minimap.view.renderMode.rawValue : nil,
                            tool: workspaceTool(surface.tools))
    }

    /// A code screen as the workspace writes it down: the manifest as text
    /// (the Workspace package does not read the analysis model), and the place
    /// the reader left in it. Its bytes come back with the panel's own pane.
    private func workspaceCodeScreen(_ code: CodeScreen) -> CodeScreenState? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(code.manifest),
              let manifest = String(data: data, encoding: .utf8)
        else { return nil }
        let place = code.place.map {
            CodeScreenState.Place(function: $0.function?.description,
                                  instruction: $0.address?.description)
        }
        return CodeScreenState(manifest: manifest,
                               selectedFunction: code.selectedFunction,
                               selectedInstruction: code.selectedInstruction,
                               place: place,
                               showsC: code.showsC)
    }

    /// The analysis a code screen was drawn from, read back from the store
    /// its manifest names. Nil when the manifest or the artifact is gone: the
    /// panel comes back as the part it holds rather than not at all.
    @MainActor
    func restoredCodeScreen(_ state: CodeScreenState,
                            pane: PaneViewModel) async -> CodeScreen? {
        guard let document = pane.document,
              let bytes = try? document.read(at: 0, length: Int(document.size))
        else { return nil }
        return await restoredCodeScreen(state, bytes: bytes)
    }

    /// The same screen for bytes that are not in a pane yet — a part being
    /// opened for the first time by a restore.
    @MainActor
    func restoredCodeScreen(_ state: CodeScreenState, bytes: [UInt8]) async -> CodeScreen? {
        guard let text = state.manifest.data(using: .utf8),
              let saved = try? JSONDecoder().decode(AnalysisManifest.self, from: text)
        else { return nil }
        let root = CodeAnalysisStore.root
        let loaded = await Task.detached(priority: .userInitiated)
        { () -> (manifest: AnalysisManifest, artifact: CodeArtifact, recipes: [AnalysisManifest])? in
            guard let store = try? ContentStore(root: root, create: false) else { return nil }
            // The analysis as the store holds it now: a review published
            // again while the session was closed is what the screen shows,
            // not the revision the session saw last.
            let current = saved.key.flatMap { try? store.analysis(module: $0.module, recipe: $0.recipe) }
            var found: (AnalysisManifest, CodeArtifact)?
            for manifest in [current, saved].compactMap({ $0 }) {
                if let artifact = try? store.artifact(for: manifest) {
                    found = (manifest, artifact)
                    break
                }
            }
            guard var (manifest, artifact) = found else { return nil }
            let index = CodeAnalysisIndex(manifests: store.usableAnalyses())
            // A later revision published through a newer exporter sits under
            // another recipe; the screen follows its reading there.
            let latest = index.latestReading(of: manifest)
            if latest != manifest, let later = try? store.artifact(for: latest) {
                (manifest, artifact) = (latest, later)
            }
            return (manifest, artifact, index.manifests(for: manifest.module.sha256))
        }.value
        guard let loaded else { return nil }
        return CodeScreen(manifest: loaded.manifest, artifact: loaded.artifact, bytes: Data(bytes),
                          selectedFunction: state.selectedFunction,
                          selectedInstruction: state.selectedInstruction,
                          place: state.place.map {
                              CodeLocation(function: $0.function.flatMap(CodeAddress.init(hex:)),
                                           address: $0.instruction.flatMap(CodeAddress.init(hex:)))
                          },
                          showsC: state.showsC,
                          recipes: loaded.recipes)
    }

    /// The open tool-module, what it has chosen, and the pane it reads.
    private func workspaceTool(_ tools: ToolController) -> ToolState? {
        guard let identifier = tools.activeIdentifier, let bound = tools.boundPane else { return nil }
        let slot: Int? = bound === windowModel.pane1 ? 0 : bound === windowModel.pane2 ? 1 : nil
        let state = (tools.session?.parkedState as? any PersistableToolSessionState)?.encoded
        return ToolState(identifier: identifier, state: state, pane: slot)
    }

    /// One pane, or nil when there is nothing in it that could be opened
    /// again.
    ///
    /// A part — in a panel, or torn off into a tab — whose parent is still
    /// open is written as where it came from, and taken out again at restore.
    /// One with no parent, or with a parent closed since or a codec this
    /// cannot write, is written as untitled bytes: it comes back without its
    /// way home.
    private func workspacePane(of pane: PaneViewModel, keeper: ContentKeeper?,
                               ids: WorkspacePaneIDs) -> PaneState? {
        guard pane.isOpen, let document = pane.document else { return nil }
        let source: DocumentSource
        var kept: KeptContent?
        if !pane.isUntitled {
            var stamp = FileStamp(url: document.url)
                ?? FileStamp(path: document.url.standardizedFileURL.path, size: pane.fileSize, modified: nil)
            stamp.relativePath = keeper?.relativeBase.flatMap { FileStamp.relativePath(of: stamp.path, to: $0) }
            kept = keeper?.keep(pane, presenter: self)
            // What the kept content is laid over is checked by its bytes at
            // restore, not only by its size and date.
            if kept != nil { stamp.sha256 = keeper?.fileHash(for: stamp, savedDigest: document.savedDigest) }
            source = .file(stamp)
        } else if let origin = partOrigin(of: pane, keeper: keeper, ids: ids) {
            source = .part(origin)
        } else {
            guard let stamp = keeper?.stamp(for: pane, presenter: self) else { return nil }
            source = .untitled(stamp)
        }
        let selection = document.selection
        return PaneState(
            id: ids.id(for: pane),
            document: source,
            selectionStart: selection.start, selectionEnd: selection.end,
            inputRegion: pane.inputRegion == .ascii ? .text : .hex,
            insertMode: pane.isInsertMode,
            topOffset: filePaneView(for: pane)?.firstVisibleOffset ?? 0,
            segments: pane.workspaceSegments(),
            uefiOpenRows: pane.uefiState.openUEFIRows.isEmpty
                ? nil : pane.uefiState.openUEFIRows.map(\.path).sorted { $0.lexicographicallyPrecedes($1) },
            kept: kept)
    }

    /// A part whose parent is still open. Changes its parent has not got are
    /// kept as bytes beside it; without a keeper to keep them the part is
    /// still written, and comes back as its parent holds it.
    private func partOrigin(of pane: PaneViewModel, keeper: ContentKeeper?,
                            ids: WorkspacePaneIDs) -> PartOrigin? {
        guard let origin = pane.origin, origin.state != .parentClosed, let parent = origin.parent,
              let codec = PartCodecState(origin.codec).flatMap(PartCodecState.text) else { return nil }
        let range = origin.sourceRange
        let edits = origin.hasChanges(in: pane) ? keeper?.stamp(for: pane, presenter: self) : nil
        return PartOrigin(parent: ids.id(for: parent), sourceStart: range.lowerBound,
                          sourceEnd: range.upperBound, name: origin.partName,
                          layout: PartCodecState.text(origin.layout), codec: codec, size: pane.fileSize,
                          edits: edits)
    }

    // MARK: - Putting back

    /// The pane at `slot` of the tab's own two.
    func workspaceSlot(_ slot: Int) -> PaneViewModel {
        slot == 0 ? windowModel.pane1 : windowModel.pane2
    }

    /// Opens a file or an untitled document into `pane`. Returns whether it is
    /// unchanged since the workspace was written, or nil when it could not be
    /// opened. A part is not opened here: it waits for its parent
    /// (`openWorkspacePart`).
    ///
    /// A file is looked for at its path, then — inside a project — at its
    /// path relative to the project; its kept changes are laid over it again
    /// when it is the file they were made on.
    func openWorkspaceDocument(_ state: PaneState, in pane: PaneViewModel, keeper: ContentKeeper?,
                               issues: inout [RestoreIssue], keptFiles: inout [KeptFileCheck]) -> Bool? {
        switch state.document {
        case let .file(stamp):
            guard let url = stamp.locate(relativeTo: keeper?.relativeBase),
                  let current = FileStamp(url: url) else {
                issues.append(.missing(path: stamp.path))
                return nil
            }
            do {
                try pane.open(url: url)
            } catch {
                issues.append(.missing(path: stamp.path))
                return nil
            }
            let unchanged = stamp.isUnchanged(comparedWith: current)
            if let kept = state.kept, keeper != nil {
                // Settled in the second pass, before any part is taken out of
                // it: the file is checked by its bytes there, off the main thread.
                keptFiles.append(KeptFileCheck(pane: pane, kept: kept, stamp: stamp, url: url,
                                               current: current, id: state.id))
                return unchanged
            }
            if !unchanged { issues.append(.changed(path: url.path)) }
            return unchanged
        case let .untitled(stamp):
            guard let bytes = try? keeper?.bytes(of: stamp.content) else {
                issues.append(.unreadable(name: stamp.name ?? L("Untitled")))
                return nil
            }
            pane.openBytes(bytes, named: stamp.name)
            // Work nobody saved is still work nobody saved: closing it asks,
            // as it would have before the app went down.
            keeper?.adopt(pane, content: stamp.content, name: stamp.name ?? L("Untitled"), dirty: stamp.dirty)
            return UInt64(bytes.count) == stamp.size
        case .part:
            return nil
        }
    }

    /// Takes a part out of `parent` again and opens it — into `pane`, a slot
    /// of the tab, or as a panel when `pane` is nil — with the changes it held
    /// laid over it. Nil when it could not be taken out: the parent changed on
    /// disk, no longer has room for it, or the codec refused.
    func openWorkspacePart(_ origin: PartOrigin, from parent: RestoredPane, into pane: PaneViewModel?,
                           keeper: ContentKeeper?,
                           code: CodeScreenState? = nil) async -> RestoredPane? {
        guard parent.unchanged,
              let codec = PartCodecState.value(PartCodecState.self, from: origin.codec)?.codec,
              let layout = PartCodecState.value(UEFIRootLayout.self, from: origin.layout),
              origin.sourceStart <= origin.sourceEnd else { return nil }
        let source = origin.sourceStart..<origin.sourceEnd
        guard let bytes = await decode(codec, from: parent.pane, source: source, name: origin.name),
              let link = DocumentOrigin(parent: parent.pane, source: source, partName: origin.name,
                                        layout: layout, codec: codec, content: bytes)
        else { return nil }
        // What the parent gives is the part's baseline — what it is measured
        // against, and what Update in Parent compares with; the bytes shown
        // are the part's own, changes included.
        let edited = origin.edits.flatMap { try? keeper?.bytes(of: $0.content) }
        let shown = edited ?? bytes
        let opened: PaneViewModel
        if let pane {
            pane.openBytes(shown, named: origin.name, origin: link)
            opened = pane
        } else {
            // A panel opens as the screen it was, not as a part converted
            // afterwards: one route through the dock for every panel, and the
            // stage measures it the way it measures any other.
            let restored: CodeScreen?
            if let saved = code {
                restored = await restoredCodeScreen(saved, bytes: shown)
            } else {
                restored = nil
            }
            guard let id = openFragment(shown, named: origin.name, origin: link,
                                        code: restored, animated: false),
                  let panel = fragments.pane(id) else { return nil }
            opened = panel
        }
        if let stamp = origin.edits, edited != nil {
            keeper?.adopt(opened, content: stamp.content, name: origin.name, dirty: stamp.dirty)
        }
        return RestoredPane(pane: opened, unchanged: UInt64(shown.count) == origin.size,
                            keptChangesLost: origin.edits != nil && edited == nil)
    }

    /// A part's own bytes when its parent did not come back: kept work is not
    /// thrown away for want of a way home, so it opens as untitled bytes —
    /// into `pane`, or as a panel when `pane` is nil.
    func openWorkspaceOrphan(_ origin: PartOrigin, into pane: PaneViewModel?,
                             keeper: ContentKeeper?) -> RestoredPane? {
        guard var stamp = origin.edits else { return nil }
        if stamp.name == nil { stamp.name = origin.name }
        if let pane {
            guard let bytes = try? keeper?.bytes(of: stamp.content) else { return nil }
            pane.openBytes(bytes, named: stamp.name)
            keeper?.adopt(pane, content: stamp.content, name: stamp.name ?? origin.name, dirty: stamp.dirty)
            return RestoredPane(pane: pane, unchanged: UInt64(bytes.count) == stamp.size)
        }
        return openWorkspaceLooseFragment(stamp, keeper: keeper)
    }

    /// Opens a panel of untitled bytes — one with no parent.
    func openWorkspaceLooseFragment(_ stamp: UntitledStamp, keeper: ContentKeeper?) -> RestoredPane? {
        guard let bytes = try? keeper?.bytes(of: stamp.content),
              let id = openFragment(bytes, named: stamp.name ?? L("Untitled"), animated: false),
              let pane = fragments.pane(id) else { return nil }
        keeper?.adopt(pane, content: stamp.content, name: stamp.name ?? L("Untitled"), dirty: stamp.dirty)
        return RestoredPane(pane: pane, unchanged: UInt64(bytes.count) == stamp.size)
    }

    /// Lays the tab out around the panes `opened` holds, by the slot each was
    /// written from: the bookmarks, the mode, each pane's place in its file,
    /// the split, the minimap, the tool panel and the Find bar.
    func finishWorkspaceTab(_ tab: TabState, opened: [Int: RestoredPane]) async {
        guard !opened.isEmpty else { return }
        // Before the panes are built, so they draw the marks from the start:
        // a seeded store reports nothing (`BookmarkStore.seed`).
        let largest = opened.values.map(\.pane.fileSize).max()
        windowModel.bookmarkStore.seed(tab.bookmarks.restorable(withinLargest: largest).map {
            Bookmark(row: BookmarkStore.row(containing: $0.row), name: $0.name)
        })

        let savedCount = tab.panes.prefix(2).compactMap { $0 }.count
        let active = savedCount == opened.count ? min(tab.activePane, opened.count - 1) : 0
        windowModel.setActivePane(active)
        refreshToolPanelHeader()
        refreshMode()

        for (slot, entry) in opened {
            guard let state = tab.panes[slot] else { continue }
            apply(state, to: entry.pane, unchanged: entry.unchanged)
        }
        apply(tab.surface, to: surface)
        if let fraction = tab.dividerFraction, mode == .comparison {
            comparisonView?.setFraction(CGFloat(fraction))
        }
        // The rows on screen are a matter of layout, so the tab lays out
        // first: a scroll into a view with no height lands nowhere.
        view.layoutSubtreeIfNeeded()
        for (slot, entry) in opened {
            guard let state = tab.panes[slot] else { continue }
            scroll(entry.pane, to: state, unchanged: entry.unchanged)
        }
        // A tab that was a code screen comes back as one, after its pane is
        // placed: the screen's own function and instruction then win.
        if let saved = tab.code, windowModel.pane1.isOpen,
           let screen = await restoredCodeScreen(saved, pane: windowModel.pane1) {
            installCodeScreen(screen, on: windowModel.pane1)
            apply(mode: .singleFile)
            view.layoutSubtreeIfNeeded()
        }
        if let tool = tab.surface.tool {
            // The tool binds to the active pane as it starts; the one it read
            // is made active for that moment.
            if let target = tool.pane.flatMap({ opened[$0] }) ?? opened.values.first {
                windowModel.setActivePane(target.pane === windowModel.pane2 ? 1 : 0)
                restoreTool(tool, on: surface.tools, pane: target)
                windowModel.setActivePane(active)
            }
        }
        if mode == .comparison { activatePane(at: active) }
        if let find = tab.surface.findPattern {
            reopenFindBar(text: find.text, encoding: SearchEncoding(rawValue: find.encoding) ?? .hex)
        }
    }

    /// Puts a panel's place, minimap and tool back once it is open, and makes
    /// it the code screen again when the workspace says it was one.
    func finishWorkspaceFragment(_ state: FragmentState, opened: RestoredPane) async {
        apply(state.pane, to: opened.pane, unchanged: opened.unchanged)
        // A part with a parent opens as the code screen in `openWorkspacePart`;
        // one that had to come back as loose bytes is still a plain panel here
        // and is made Code once its place is laid down.
        let panelID = fragments.panel(holding: opened.pane)
        let needsCode = state.code != nil
            && (panelID == nil || fragments.codePane(panelID!) == nil)
        if !needsCode, let surface = fragments.surface(holding: opened.pane) {
            apply(state.surface, to: surface)
            if let tool = state.surface.tool {
                restoreTool(tool, on: surface.tools, pane: opened)
            }
        }
        view.layoutSubtreeIfNeeded()
        scroll(opened.pane, to: state.pane, unchanged: opened.unchanged)
        if needsCode, let saved = state.code, let id = panelID,
           let screen = await restoredCodeScreen(saved, pane: opened.pane) {
            fragments.reopenAsCode(id, screen: screen, animated: false)
            if let surface = fragments.surface(holding: opened.pane) {
                apply(state.surface, to: surface)
            }
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Brings the panel that was in front to the front again, or none.
    func settleWorkspaceFragments(expanded pane: PaneViewModel?) {
        if let pane, let id = fragments.panel(holding: pane) {
            fragments.expand(id, animated: false)
        } else if fragments.expanded != nil {
            fragments.collapse(animated: false)
        }
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

    /// The caret, the selection, the typing mode, the cuts and the open rows.
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
