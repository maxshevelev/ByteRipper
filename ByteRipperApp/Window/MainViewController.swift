import Cocoa
import UniformTypeIdentifiers
import ByteRipperCore
import ToolModuleKit
import UEFIImage
import ALSplitView

/// Whether each diff-navigation action currently has a block to go to (§10.3).
/// A false value means the command is disabled — wrong mode, index still
/// building, or the block doesn't exist in that direction from the caret.
struct DiffNavigationState: Equatable {
    var previousDifference = false
    var nextDifference = false
    var previousSameBlock = false
    var nextSameBlock = false
}

final class MainViewController: NSViewController {
    private(set) var mode: WindowMode = .empty
    /// Whether a toolbar sync is already queued for the next run-loop turn.
    private var diffToolbarSyncScheduled = false

    /// Current diff-navigation availability. Recomputed on every mode, index,
    /// and caret change; the menu items read it via `validateMenuItem` (§10.3).
    private(set) var diffNavigationState = DiffNavigationState()
    let windowModel = WindowViewModel()

    /// Every window's controller, so "is this file already open?" can be asked
    /// of the whole application rather than of this window's two panes (§4.1
    /// rule 6).
    ///
    /// Nil in a controller built on its own — which every test does — and the
    /// rule then falls back to this window's own panes, exactly as it has always
    /// worked. Weak: the registry outlives no window, and this is a back
    /// reference to something the app owns.
    weak var openDocuments: OpenDocumentRegistry?

    /// What to do about a file that is already open in another window or tab.
    private enum AlreadyOpenChoice {
        /// Bring that window forward with the file's pane active.
        case show
        /// Move that pane into this window, where the user asked for it.
        case move
        case cancel
    }

    private func askAboutFileOpenElsewhere(named name: String) -> AlreadyOpenChoice {
        let alert = NSAlert()
        alert.messageText = "“\(name)” is already open"
        alert.informativeText = "A file is open in one place at a time, so it cannot be opened "
            + "here as well. Show it where it is, or move that pane into this tab."
        alert.addButton(withTitle: "Show in Its Tab")
        alert.addButton(withTitle: "Move to This Tab")
        // AppKit gives a button titled "Cancel" the Escape key.
        alert.addButton(withTitle: "Cancel")
        switch Self.presentModal(alert, defaultInTest: .alertFirstButtonReturn) {
        case .alertFirstButtonReturn: return .show
        case .alertSecondButtonReturn: return .move
        default: return .cancel
        }
    }

    /// Moves the pane holding a file out of `holder` and into this window's pane
    /// `index` — the answer to "open it here" that actually opens it here.
    ///
    /// The document is moved rather than re-opened, for the same reason the
    /// tear-off moves it: the file stays open exactly once, and the unsaved
    /// edits, undo history and segments travel with it.
    ///
    /// The marks do not. Bookmarks belong to a window (§20), and this window has
    /// its own list already — merging two would be merging two windows' notes on
    /// one row. A pane joins the list of the window it lands in. (The tear-off
    /// copies its list instead, because the tab it makes starts with none.)
    @discardableResult
    private func movePaneHere(from holder: MainViewController, at holdingPane: Int,
                              into index: Int,
                              onSaved: @escaping () -> Void) -> Bool {
        let target = index == 0 ? windowModel.pane1 : windowModel.pane2
        // The pane being displaced gets the ordinary prompt; a dirty untitled one
        // saves first and whatever asked for the move runs again from the top.
        guard confirmReplaceDirtyPane(target, onSaved: onSaved) else { return false }
        let moved = holder.releasePane(at: holdingPane)
        if target !== moved {
            paneViews.removeValue(forKey: ObjectIdentifier(target))?
                .searchResults.removeFromParent()
            target.close()
        }
        windowModel.adopt(moved, at: index)
        // Applied rather than refreshed: replacing one pane with another leaves
        // the open-pane count alone, and `refreshMode` skips a mode that has not
        // changed — which would leave the old pane's view on screen.
        apply(mode: windowModel.openPaneCount >= 2 ? .comparison : .singleFile)
        return true
    }

    /// Takes the pane at `index` out of this window and hands it over, leaving
    /// the window to re-render with one pane fewer. The shared half of both
    /// moves: tearing a pane off into a new tab, and giving it up to a window
    /// that asked to open its file.
    func releasePane(at index: Int) -> PaneViewModel {
        // The comparison ends here, so the two panes must stop holding each
        // other as companions before one of them leaves.
        if mode == .comparison { unwireComparison() }
        let pane = windowModel.detachPane(index)
        // The tool panel belongs to this window, the way its bookmarks do
        // (§20), so a pane that leaves does not take it along: the session ends
        // here (Design/TOOL_MODULES_PLAN.md).
        tools.paneLeft(pane)
        // The view bound to it belongs to this window; wherever it lands builds
        // its own from the model.
        paneViews.removeValue(forKey: ObjectIdentifier(pane))?
            .searchResults.removeFromParent()
        refreshMode()
        return pane
    }

    /// Makes a tab beside this window and hands back the controller that runs
    /// it. Set by the app delegate, which owns the windows; nil in a controller
    /// built on its own, where there is no window to put a tab beside and the
    /// command that needs one is disabled.
    var makeSiblingTab: (() -> MainViewController?)?

    /// File ▸ New Tab (⌘T): an empty tab beside this window.
    ///
    /// It lands on the key window's controller, which is the window the tab
    /// should join — the reason this is a controller command rather than the app
    /// delegate's, which has no window in mind.
    @objc func newTab(_ sender: Any?) {
        _ = makeSiblingTab?()
    }

    /// Pane menu ▸ Open in New Tab: this pane's document leaves for a tab of its
    /// own, and the window it left keeps the other file on its own.
    ///
    /// The document is **moved**, not opened again: re-opening the URL would put
    /// two live documents over one file, which is exactly what §4.1 rule 6
    /// exists to prevent, and the unsaved edits, the undo history, the segments
    /// and the change watcher would all be left behind. Moving the pane object
    /// takes every one of them along by construction.
    @objc func openPaneInNewTab(_ sender: Any?) {
        guard let pane = (sender as? NSMenuItem)?.representedObject as? PaneViewModel else { return }
        // A fragment panel's own header offers the same item, and means the
        // same thing by it — but the panel is not one of the window's two
        // panes, so asking which index it is would name the wrong one
        // (`Design/FRAGMENT_PANELS_PLAN.md`).
        if let panel = fragments.panel(withDragID: pane.dragID) {
            tearOffFragment(panel)
            return
        }
        movePaneToNewTab(at: paneIndex(pane))
    }

    /// Gives a fragment panel's pane view the wiring `apply(mode:)` gives the
    /// tab's own panes: the header's ✕ and its link to the parent, the two
    /// context menus, the status bar, and what a tool-module and the search
    /// have to hear about an edit.
    ///
    /// Written out here rather than shared with `apply(mode:)` because every
    /// target differs: the ✕ closes a panel rather than a pane, the tool that
    /// hears about an edit is the panel's own, and the pill in the dock has to
    /// be re-read for the dot that says the parent has not got these bytes.
    ///
    /// What is deliberately **not** here is the minimap's: its feed is still
    /// the tab's one map pair, so a minimap opened on a panel would draw
    /// nothing. That is the next piece of work, not an omission.
    func wireFragmentPaneView(_ view: FilePaneView, for pane: PaneViewModel,
                              panel: FragmentDock.PanelID, surface: DocumentSurface) {
        view.paneMenu = makePaneMenu(for: pane)
        view.offsetMenuProvider = { [weak self] offset in
            self?.makeOffsetMenu(for: pane, offset: offset) ?? NSMenu()
        }
        wireBookmarkDoubleClick(view, for: pane)
        wireStatusBar(view, for: pane)
        view.onClose = { [weak self] in self?.closeFragment(panel) }
        // What the pull-down gesture does, as a button. The gesture is better
        // and stays; a button beside the ✕ is what says the panel can be put
        // away at all — and the web edition has no gesture to offer.
        view.onCollapse = { [weak self] in self?.fragments.collapse() }
        // The header is also the panel's handle: pulled down it moves the panel
        // rather than carrying the pane off to a tab.
        view.onHeaderPulledDown = { [weak self] event in
            self?.fragments.beginPullDown(panel, from: event)
        }
        view.onRevealOrigin = { [weak self] in self?.revealOrigin(of: pane) }
        view.onSearchResultsClose = { [weak self] _ in self?.syncFindBarToActivePane() }
        view.onMatchesChanged = { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.searchAppearanceChanged(on: surface)
        }
        // The pane is captured weakly by the closures it holds itself: a
        // strong one is a ring the pane can never get out of, and a panel
        // closed but never freed goes on being somebody's parent.
        pane.onEdit = { [weak self, weak surface, weak pane] edit in
            guard let surface, let pane else { return }
            self?.invalidateMatches(in: pane)
            surface.tools.paneEdited(pane, edit)
            surface.minimap.repaint(after: edit, mapIndex: 0)
            // The pill's dot is "the parent has not got this", which an edit is
            // exactly what changes.
            self?.fragments.refreshDock()
        }
        pane.onFullInvalidation = { [weak self, weak surface, weak pane] in
            guard let surface, let pane else { return }
            surface.tools.paneReloaded(pane)
            self?.invalidateMatches(in: pane)
            surface.minimapView.invalidateCells()
            surface.minimap.refreshMaps()
            self?.fragments.refreshDock()
        }
        pane.onSavedStateChanged = { [weak self, weak surface] in
            if let surface {
                surface.minimapView.invalidateCells()
                surface.minimap.refreshMaps()
            }
            self?.fragments.refreshDock()
        }
        pane.onCaretChanged = { [weak surface] in
            guard let surface else { return }
            surface.minimap.updateSelections()
        }
        pane.onSegmentsChanged = { [weak surface] in
            surface?.minimap.syncSegments()
        }
    }

    /// Gives a fragment panel's surface a map of its own: what it maps, what it
    /// scrolls, and the state it opens in (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// The panel opens with the map the tab has. Someone who works with the
    /// minimap on wants it on the part too, and a part — a volume, a body, a
    /// region — is exactly where a map earns its place.
    func prepareFragmentMinimap(of surface: DocumentSurface, pane: PaneViewModel,
                                paneView: FilePaneView) {
        surface.panesInMapOrder = { [pane] }
        surface.paneViewsInMapOrder = { [paneView] }
        surface.minimap.wire(menus: false)
        surface.minimap.track(paneView)
        surface.minimap.setPanelVisible(minimapPanelVisible, animated: false)
        surface.minimap.refreshMaps()
        surface.minimap.updateLayout()
        surface.minimap.updateViewports()
        surface.minimap.syncBookmarks()
        surface.minimap.syncSegments()
        surface.minimap.syncZones()
    }

    /// A mark added or removed in a panel: its map's margin follows.
    func syncFragmentMinimapBookmarks(of surface: DocumentSurface) {
        surface.minimap.syncBookmarks()
    }

    /// The fragment panel `pane` belongs to, for the commands that mean one
    /// thing in a panel and another — or nothing — among the tab's panes.
    ///
    /// The trouble they share is `paneIndex(_:)`: it answers 0 or 1 for a pane
    /// that is neither, so a command addressed to a panel's pane quietly lands
    /// on one of the tab's.
    func fragmentPanel(of pane: PaneViewModel) -> FragmentDock.PanelID? {
        fragments.panel(holding: pane)
    }

    /// After the bytes have gone back: the panel they came from folds, and what
    /// they went into comes to the front — the tab's dump, or the panel that is
    /// the parent — with the bytes that just landed selected there.
    ///
    /// Watching the change arrive is the reason a part opens over its parent
    /// rather than in a tab of its own, and the moment it is worth watching is
    /// this one. A parent in another tab is not raised here: the panel folds
    /// all the same, and `revealOrigin` brings that window forward.
    func revealUpdateDestination(from pane: PaneViewModel, to parent: PaneViewModel) {
        guard let panel = fragmentPanel(of: pane) else { return }
        if let parentPanel = fragmentPanel(of: parent) {
            // Raising one folds the other: there is only ever one up.
            fragments.expand(parentPanel)
        } else if fragments.expanded == panel {
            fragments.collapse()
        }
        revealOrigin(of: pane)
    }

    /// Whether a fragment panel has a window to be put in a tab beside.
    var canTearOffFragment: Bool { makeSiblingTab != nil }

    /// Moves a fragment panel out into a tab beside this window: the menu's
    /// form of dragging it onto the New Tab strip, and the only form a folded
    /// panel has, since a pill has no header to drag.
    func tearOffFragment(_ panel: FragmentDock.PanelID) {
        guard let tab = makeSiblingTab?(),
              let released = fragments.release(panel) else { return }
        tab.adoptPane(released.pane, bookmarks: released.bookmarks)
    }

    private func movePaneToNewTab(at index: Int) {
        guard mode == .comparison else { return }
        tearOff(paneAt: index, into: self)
    }

    /// Moves `index`'s pane out of this window and into a tab `host` makes
    /// beside itself.
    ///
    /// `host` is the window the gesture was aimed at, which is not always this
    /// one: a pane dragged onto another window's New Tab strip belongs in a tab
    /// beside *that* window. The marks are this window's, because they are the
    /// ones the pane was read under.
    private func tearOff(paneAt index: Int, into host: MainViewController) {
        guard let tab = host.makeSiblingTab?() else { return }
        let marks = windowModel.bookmarkStore.bookmarks
        // Read before the pane goes: releasing it ends the session bound to it.
        let toolFollowing = tools.boundPane === (index == 0 ? windowModel.pane1 : windowModel.pane2)
            ? tools.activeIdentifier : nil
        tab.adoptPane(releasePane(at: index), bookmarks: marks)
        // A tab made for this pane starts with nothing in it, so there is
        // nothing for its tool-module to conflict with — the same reason the
        // marks are copied rather than dropped. The session itself does not
        // travel; the tool-module is opened again there and reads afresh.
        if let toolFollowing { tab.tools.activate(toolFollowing, animated: false) }
    }

    /// A pane let go on this window's New Tab strip: it leaves for a tab of its
    /// own beside this window, wherever it came from.
    func tearOffPaneToNewTab(draggedPaneID: UUID, copying: Bool = false) {
        // A fragment panel dragged out by its header is the other thing this
        // strip can be handed (`Design/FRAGMENT_PANELS_PLAN.md`). It is the
        // same move — the pane object goes, with its edits, its undo and the
        // link to the parent, which is the pane's own and so travels with it.
        if tearOffFragmentToNewTab(draggedPaneID: draggedPaneID, copying: copying) { return }
        guard let origin = paneLocation(ofPaneWith: draggedPaneID) else { return }
        guard copying else {
            origin.controller.tearOff(paneAt: origin.paneIndex, into: self)
            return
        }
        // Copied rather than moved: the pane stays where it is and a duplicate
        // of it opens in the new tab, the way Option means everywhere else.
        let source = origin.paneIndex == 0
            ? origin.controller.windowModel.pane1
            : origin.controller.windowModel.pane2
        guard source.isOpen, source.fileSize > 0, let tab = makeSiblingTab?() else { return }
        do {
            try tab.windowModel.pane1.openDuplicate(of: source,
                                                    named: unsavedName(for: source))
        } catch {
            presentFileError("Could not duplicate the pane.", error, url: nil)
            return
        }
        tab.windowModel.bookmarkStore.seed(origin.controller.windowModel.bookmarkStore.bookmarks)
        tab.apply(mode: .singleFile)
    }

    /// A fragment panel let go on this window's New Tab strip, moved or copied
    /// into a tab of its own. False when the drag was not a fragment panel's,
    /// which is how the caller knows to look among the window panes instead.
    ///
    /// The panel leaves the dock it was in, which need not be this window's:
    /// the strip that was aimed at decides where the tab goes, not where the
    /// panel came from — the same rule a torn-off pane follows.
    private func tearOffFragmentToNewTab(draggedPaneID: UUID, copying: Bool) -> Bool {
        guard let found = fragmentLocation(ofPaneWith: draggedPaneID) else { return false }
        guard let tab = makeSiblingTab?() else { return true }
        if copying {
            // A copy of a part has no claim to put bytes back: it is a new
            // document that happens to hold the same bytes, exactly as
            // Duplicate leaves one anywhere else.
            guard let source = found.controller.fragments.pane(found.panel), source.isOpen else {
                return true
            }
            do {
                try tab.windowModel.pane1.openDuplicate(of: source, named: unsavedName(for: source))
            } catch {
                presentFileError("Could not duplicate the panel.", error, url: nil)
                return true
            }
            tab.apply(mode: .singleFile)
            return true
        }
        guard let released = found.controller.fragments.release(found.panel) else { return true }
        tab.adoptPane(released.pane, bookmarks: released.bookmarks)
        return true
    }

    /// The window and fragment panel carrying `dragID` — this window's own when
    /// there is no registry, the way the pane lookup falls back.
    private func fragmentLocation(ofPaneWith dragID: UUID)
    -> (controller: MainViewController, panel: FragmentDock.PanelID)? {
        if let openDocuments {
            return openDocuments.location(ofFragmentWith: dragID)
        }
        return fragments.panel(withDragID: dragID).map { (self, $0) }
    }

    /// Copies `source` into this window's pane `index`, replacing whatever is
    /// there — the cross-window form of Duplicate, which `File ▸ Duplicate`
    /// itself never needs because it only ever copies within one window.
    private func copyPane(_ source: PaneViewModel, into index: Int) {
        let target = index == 0 ? windowModel.pane1 : windowModel.pane2
        guard confirmReplaceDirtyPane(target) else { return }
        do {
            try target.openDuplicate(of: source, named: unsavedName(for: source))
        } catch {
            presentFileError("Could not duplicate the pane.", error, url: nil)
            return
        }
        windowModel.setActivePane(index)
        apply(mode: windowModel.openPaneCount >= 2 ? .comparison : .singleFile)
    }

    /// Takes a pane torn off another window, with a copy of that window's marks.
    ///
    /// The marks are copied rather than shared or dropped: they were made
    /// against absolute offsets, and those offsets mean the same thing in the
    /// file that just arrived. From here the two lists are independent — a mark
    /// added in one window does not appear in the other.
    func adoptPane(_ pane: PaneViewModel, bookmarks: [Bookmark]) {
        windowModel.bookmarkStore.seed(bookmarks)
        windowModel.adopt(pane)
        apply(mode: .singleFile)
    }

    /// Brings this window to the front and makes `paneIndex` its active pane —
    /// what happens instead of a refusal when the file someone asked to open is
    /// already open in another window or tab (§4.1 rule 6).
    func revealOpenFile(inPane paneIndex: Int) {
        if mode == .comparison, paneIndex != windowModel.activePaneIndex {
            activatePane(at: paneIndex)
        }
        viewIfLoaded?.window?.makeKeyAndOrderFront(nil)
    }

    /// What letting the dragged pane go on this window's pane `index` would do
    /// (`Design/PANE_DRAG_PLAN.md`).
    ///
    /// The decision itself is `PaneDrop`'s and is pure; all this adds is finding
    /// where the dragged pane currently lives. A pane whose window has gone
    /// resolves to nothing, and the drop is refused.
    /// Which pane a single-file window's drop zone stands for, and in which
    /// band. The far half is the free second pane; the three bands are the one
    /// that is already open.
    static func singleFilePaneDrop(_ target: SingleFileDropTarget)
    -> (index: Int, band: SingleFileDropTarget) {
        target == .addSecond ? (1, .addSecond) : (0, target)
    }

    func paneDropOutcome(draggedPaneID: UUID, onPaneAt index: Int,
                         band: SingleFileDropTarget = .replace,
                         copying: Bool = false) -> PaneDrop.Outcome {
        guard let origin = paneLocation(ofPaneWith: draggedPaneID) else { return .none }
        let outcome = PaneDrop.outcome(
            draggingPaneAt: origin.paneIndex,
            onto: .pane(index: index, inOriginWindow: origin.controller === self, band: band),
            copying: copying)
        // A join needs both panes to hold something; the target's own emptiness
        // is the only case the pure rule cannot see.
        if case .join = outcome {
            let target = index == 0 ? windowModel.pane1 : windowModel.pane2
            guard target.isOpen else { return .none }
        }
        // A copy needs bytes to copy, and that is all it needs: where it lands
        // is the drop's business. `canDuplicate` is deliberately not asked here
        // — it speaks for the menu command, whose copy has to find a *free*
        // pane, while a drop names the pane itself and may replace an occupied
        // one, near or far, the way a move does.
        if case .duplicate = outcome {
            let source = origin.paneIndex == 0
                ? origin.controller.windowModel.pane1
                : origin.controller.windowModel.pane2
            guard source.isOpen, source.fileSize > 0 else { return .none }
            // One exception to "where it lands is the drop's business": the
            // `.addSecond` band *is* the free half of a single-file window's
            // zone. If that pane is not free the band is not on screen, and a
            // copy aimed at it has nowhere to go — unlike the middle band, which
            // names a pane outright and may replace it.
            if band == .addSecond {
                let target = index == 0 ? windowModel.pane1 : windowModel.pane2
                guard !target.isOpen else { return .none }
            }
        }
        return outcome
    }

    /// Performs whatever the drop means. Nothing here is a new operation —
    /// each case is a command that already exists.
    func performPaneDrop(draggedPaneID: UUID, onPaneAt index: Int,
                         band: SingleFileDropTarget = .replace,
                         copying: Bool = false) {
        switch paneDropOutcome(draggedPaneID: draggedPaneID, onPaneAt: index,
                               band: band, copying: copying) {
        case .swap:
            swapPanes()
        case .join(let intoPane, let position):
            guard let origin = paneLocation(ofPaneWith: draggedPaneID) else { return }
            let source = origin.paneIndex == 0
                ? origin.controller.windowModel.pane1
                : origin.controller.windowModel.pane2
            join(pane: source, at: position,
                 into: intoPane == 0 ? windowModel.pane1 : windowModel.pane2)
            refreshMode()
        case .move(let intoPane):
            guard let origin = paneLocation(ofPaneWith: draggedPaneID) else { return }
            movePaneHere(from: origin.controller, at: origin.paneIndex, into: intoPane,
                         onSaved: { [weak self] in
                             // Re-resolved rather than captured: the pane may
                             // have moved again while the save panel was up.
                             self?.performPaneDrop(draggedPaneID: draggedPaneID,
                                                   onPaneAt: intoPane)
                         })
        case .duplicate(let intoPane):
            guard let origin = paneLocation(ofPaneWith: draggedPaneID) else { return }
            let source = origin.paneIndex == 0
                ? origin.controller.windowModel.pane1
                : origin.controller.windowModel.pane2
            let target = intoPane == 0 ? windowModel.pane1 : windowModel.pane2
            // What decides is whether the slot is free, not which window it is
            // in. Into this window's free pane nothing new happens: it is `File
            // ▸ Duplicate`, which already reports itself and re-applies the
            // mode. Any occupied pane — this window's other one included — is
            // the replacing form, which asks before discarding unsaved work.
            if origin.controller === self, !target.isOpen {
                duplicate(from: source)
            } else {
                copyPane(source, into: intoPane)
            }
        case .none, .tearOff:
            // A tear-off never lands on a pane; the strip owns that one.
            break
        }
    }

    /// Where the pane with `dragID` is, asked of the whole app when there is a
    /// registry and of this window alone when there is not — the same fallback
    /// the already-open rule uses, and for the same reason: a controller built
    /// on its own must still answer for itself.
    private func paneLocation(ofPaneWith dragID: UUID)
    -> (controller: MainViewController, paneIndex: Int)? {
        if let openDocuments {
            return openDocuments.location(ofPaneWith: dragID)
        }
        return paneIndex(withDragID: dragID).map { (self, $0) }
    }

    /// The name an unsaved image made from `source` should wear (§23): a copy of
    /// it (§23), or `source` itself once a join has detached it (§22.2). Both
    /// are the pane's content plus or minus something, and both take the pane's
    /// name with the next free series suffix.
    ///
    /// Every name on screen anywhere in the app is off limits, not just this
    /// window's: two tabs each showing a `bios-2.bin` would be the confusion
    /// this naming exists to remove, only harder to spot.
    ///
    /// What decides is whether the source has a name, not whether it has a file.
    /// A copy is untitled from the moment it is made, so copying a copy has to
    /// read the name it is wearing: `bios-2.bin` gives `bios-3.bin` though
    /// neither is on disk yet. Only a document with no name of its own — `File ▸
    /// New File`, or a join — has nothing to be named after, and its copy stays
    /// untitled.
    func unsavedName(for source: PaneViewModel) -> String? {
        guard !source.isUntitled || source.untitledName != nil else { return nil }
        let controllers = openDocuments?.controllers ?? [self]
        let taken = Set(controllers.flatMap { controller in
            [controller.windowModel.pane1, controller.windowModel.pane2]
                .filter(\.isOpen)
                .map { $0.status.fileName }
        })
        return DuplicateName.next(after: source.status.fileName, taken: taken)
    }

    /// Which of this window's two panes this is. Pane 2 only when it *is* pane
    /// 2; anything else is pane 1, which is the one a single-file window has.
    func paneIndex(of pane: PaneViewModel) -> Int {
        pane === windowModel.pane2 ? 1 : 0
    }

    /// This window's pane at `index`. The other half of `paneIndex(of:)`, and
    /// the one place that knows pane 2 is the high index — so a caller that has
    /// an index (the tool panel's selector) does not spell the same pair out
    /// again.
    func pane(at index: Int) -> PaneViewModel? {
        switch index {
        case 0: return windowModel.pane1
        case 1: return windowModel.pane2
        default: return nil
        }
    }

    /// The index of this window's pane with `dragID`, if either has it — the
    /// pane half of the registry's question, beside the file half below.
    /// Internal so the registry can ask it of every window.
    func paneIndex(withDragID dragID: UUID) -> Int? {
        [windowModel.pane1, windowModel.pane2].firstIndex { $0.dragID == dragID }
    }

    /// The index of this window's pane holding `identity`, if either does.
    /// `excluding` skips one pane — the target of an open, which is never its
    /// own obstacle. Internal so the registry can ask it of every window.
    func paneIndex(holding identity: FileIdentity, excluding: Int?) -> Int? {
        for (index, pane) in [windowModel.pane1, windowModel.pane2].enumerated()
        where index != excluding {
            if pane.isOpen, pane.document?.identity == identity { return index }
        }
        return nil
    }

    /// Where the file at `url` is already open, skipping the pane an open is
    /// aimed at. Answered by the registry when the app has installed one, and by
    /// this window alone otherwise.
    private func documentLocation(of url: URL, excluding paneIndex: Int)
    -> (controller: MainViewController, paneIndex: Int)? {
        if let openDocuments {
            return openDocuments.location(of: url, excluding: (self, paneIndex))
        }
        return self.paneIndex(holding: FileIdentity(url: url), excluding: paneIndex)
            .map { (self, $0) }
    }
    private weak var activeFilePane: FilePaneView?
    private weak var comparisonView: ComparisonView?

    /// The pane views, keyed by the model they display. A view is created once
    /// and reused for its model's whole life — across mode changes, file
    /// changes (a data change the view already reloads, not a view change), and
    /// pane re-ordering (swap, close-promotion) (§3.3). Reusing it is what keeps
    /// a pane's scroll and focus from shifting when the other pane opens or
    /// closes: the old design rebuilt every pane on each `apply`, and the fresh
    /// view's init followed the caret to the top.
    private var paneViews: [ObjectIdentifier: FilePaneView] = [:]

    /// The non-modal Find bar shown at the top on Cmd+F (§11). It lives above
    /// the content area and pushes it down while visible; when hidden the
    /// content fills the window again.
    private let findBar = FindBarView()
    /// Host for the mode content (`setContentView` swaps what's inside).
    private let contentContainer = NSView()
    /// The tab's own content surface: the split that shares the content area
    /// between the tool panel, the dump and the minimap, and the three of them
    /// (`Design/FRAGMENT_PANELS_PLAN.md`). One today; a fragment panel is
    /// another one of these.
    ///
    /// Lazy so it can be handed its tab at birth rather than in `viewDidLoad`:
    /// a tab made for a pane torn off into it is asked to open a tool-module
    /// before anything has made it load its view.
    private(set) lazy var surface = DocumentSurface(host: self)

    // The surface's pieces under the names this file has always called them.
    // Forwarding rather than renaming three hundred call sites — here and
    // across the suite — in a change whose whole point is that nothing moves
    // on screen.
    var panelSplit: ALSplitView { surface.panelSplit }
    /// The left pane of the minimap split — the mode's content lives here, so
    /// the minimap panel can share the content area to its right (§19).
    var contentHost: NSView { surface.contentHost }
    var minimapView: MinimapView { surface.minimapView }
    var minimapPanel: MinimapPanelView { surface.minimapPanel }
    /// The tab's own tool-module: the panel down the left of the window.
    var tools: ToolController { surface.tools }

    /// The tool-module the Tools menu and its toolbar popup mean: the fragment
    /// panel's when one is up, the tab's otherwise
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// A panel covers the tab's own tool panel, so the one the commands act on
    /// is always the one on screen — there is never a choice of two.
    var frontTools: ToolController { fragments.frontSurface?.tools ?? surface.tools }

    /// The tool-module reading `pane`: a part's panel has its own, and a zone
    /// picked in a part belongs to the tool that drew it there.
    func tools(reading pane: PaneViewModel) -> ToolController {
        fragments.surface(holding: pane)?.tools ?? surface.tools
    }
    var minimapPanelVisible: Bool { surface.minimapPanelVisible }
    var minimapPreferredPanelWidth: CGFloat { surface.minimapPreferredPanelWidth }

    static var minimapDefaults: UserDefaults {
        get { DocumentSurface.minimapDefaults }
        set { DocumentSurface.minimapDefaults = newValue }
    }
    static var minimapWidthDefaultsKey: String { DocumentSurface.minimapWidthDefaultsKey }
    static var minimapMinPanelWidth: CGFloat { DocumentSurface.minimapMinPanelWidth }
    static var minimapMaxPanelWidth: CGFloat { DocumentSurface.minimapMaxPanelWidth }
    static var toolPaneIndex: Int { DocumentSurface.toolPaneIndex }
    static var contentPaneIndex: Int { DocumentSurface.contentPaneIndex }
    static var minimapPaneIndex: Int { DocumentSurface.minimapPaneIndex }
    static var toolDividerIndex: Int { DocumentSurface.toolDividerIndex }
    static var minimapDividerIndex: Int { DocumentSurface.minimapDividerIndex }

    // The tab's own map keeps its counters where the suite has always read
    // them. They live on the surface now, one set per map.
    var overviewRebuilds: Int { surface.minimap.overviewRebuilds }
    var overviewPatches: Int { surface.minimap.overviewPatches }
    var overviewRebuildsCompleted: Int { surface.minimap.overviewRebuildsCompleted }
    var overviewPassRowCount: Int { surface.minimap.overviewPassRowCount }
    var matchOverlayWalksForTesting: Int { surface.minimap.matchOverlayWalksForTesting }

    func toolPanelWidth() -> CGFloat { surface.toolPanelWidth() }

    func setToolPanelWidth(_ width: CGFloat, animated: Bool,
                           windowResize: ((CGFloat) -> Void)? = nil) {
        surface.setToolPanelWidth(width, animated: animated, windowResize: windowResize)
    }

    func setMinimapPanelWidth(_ width: CGFloat, animated: Bool = false,
                              windowResize: ((CGFloat) -> Void)? = nil) {
        surface.setMinimapPanelWidth(width, animated: animated, windowResize: windowResize)
    }

    /// Where fragment panels slide in: exactly the area the panes occupy, so a
    /// panel never covers the New Tab strip above it nor the dock below
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    private let fragmentHost = FragmentPanelHost()
    /// The dock along the bottom: one pill per fragment panel this tab holds.
    private let fragmentDockStrip = FragmentDockStrip()
    private var fragmentDockHeight: NSLayoutConstraint?

    /// The fragment panels this tab has open, and the dock they fold into.
    private(set) lazy var fragments = FragmentPanels(host: self,
                                                     container: fragmentHost,
                                                     strip: fragmentDockStrip)

    /// The window-level drop target under the tab bar: a file let go there opens
    /// in a tab of its own (`Design/PANE_DRAG_PLAN.md`).
    ///
    /// It sits above everything the window shows — both panes and the minimap —
    /// and takes its own height while a drag is in flight rather than lying over
    /// the content. Overlaying was tried and looked wrong: the strip covered the
    /// pane headers and the top of the column headers, and the bands below it no
    /// longer lined up with the dump they were describing.
    ///
    /// Moving the content is safe *because* the strip's visibility follows the
    /// drag session rather than which view the pointer is over. Tied to the
    /// pointer it would be a loop, and was: leaving the panes hid the strip, the
    /// content rose, the pointer was over a pane again, the strip came back.
    ///
    /// A `.bottom` titlebar accessory was tried first, to keep the strip out of
    /// the content entirely. AppKit places one **above** the tab bar, between it
    /// and the toolbar, where the pointer cannot reach it without crossing the
    /// bar. Nothing public places a view below the bar, and nothing public makes
    /// the bar itself a target.
    private let newTabDropStrip = NewTabDropStrip()

    /// The strip's height: zero between drags, `NewTabDropStrip.height` while
    /// one is in flight. Animated, so the content glides down rather than being
    /// snatched.
    private var newTabDropStripHeight: NSLayoutConstraint?

    /// The single-file mode's drop container, held so its bands can be inset by
    /// the strip's share the way the comparison's are. Nil in the other modes.
    private weak var singleFileDropView: SingleFileDropView?

    /// The empty mode's placeholder, held so the bookmark list it shows can be
    /// kept current. Nil in the other modes.
    private weak var emptyStateView: EmptyStateView?

    /// The newer-release check started for the landing screen that is up, if one
    /// is still running. Held only so that a test can wait for the answer rather
    /// than race it: nothing in the app waits on it, which is the point of it
    /// being a task at all.
    private(set) var releaseCheckTask: Task<Void, Never>?

    /// Re-reads the marks into the empty window's list and its title.
    private func refreshEmptyStateBookmarks() {
        guard mode == .empty else { return }
        emptyStateView?.setBookmarks(windowModel.bookmarkStore.bookmarks)
        updateWindowTitle()
    }

    private var contentTopToView: NSLayoutConstraint!
    private var contentTopToFindBar: NSLayoutConstraint!
    private var findTask: Task<Void, Never>?
    /// The active search operation, surfaced in the active pane's status bar
    /// while a search runs (§14.4).
    private var findOperation: BackgroundOperation?
    /// The background index of every occurrence, and the operation that shows
    /// its progress. Separate from `findTask` on purpose: a press of ‹ › while
    /// the index is still building runs its own scan, and cancelling the index
    /// to do so would mean it never finished (§11).
    private var indexTask: Task<Void, Never>?
    private var indexOperation: BackgroundOperation?
    /// The attempts a Smart Search is working through, while it is (§11). A
    /// second press of Enter during a pass has nothing to add: the pass *is*
    /// the answer to it, and starting another would only cancel this one.
    private var smartPassInFlight: [SmartSearch.Attempt]?

    /// Stops whatever find is in flight — a navigation scan or a Smart Search
    /// pass — and takes its operation off the status bar.
    private func cancelFind() {
        findTask?.cancel()
        findTask = nil
        findOperation?.finish()
        findOperation = nil
        smartPassInFlight = nil
    }
    /// The in-flight segment write (Save All / Save Segment, §21.5), surfaced in
    /// the active pane's status bar while it runs, like a search (§14.4).
    private var segmentWriteTask: Task<Void, Never>?
    private var segmentWriteOperation: BackgroundOperation?

    // MARK: - Segment save seams (§21.5)

    /// Where the Save All directory panel goes, so a test can drive it instead:
    /// a modal panel has no one to click it under XCTest. Called with the panel
    /// (already configured for directory mode); returns the chosen directory or
    /// nil when the user cancelled.
    var segmentDirectoryPanel: ((NSOpenPanel) -> URL?)?
    /// Where the Save Segment panel goes; the same shape, for one file.
    var segmentSavePanel: ((NSSavePanel) -> URL?)?
    /// Where the Replace Segment from File… open panel goes; the same shape as
    /// the save panel, for one file (§21.6).
    var segmentOpenPanel: ((NSOpenPanel) -> URL?)?
    /// Where the join's open panel goes (Append File… / Insert File at Start…,
    /// §22); the same shape as the replace panel, for one file.
    var joinOpenPanel: ((NSOpenPanel) -> URL?)?
    /// Where a tool-module's open panel goes (`ToolHost.requestFile`), the same
    /// shape as the join's and the segment panels': a modal panel has no one to
    /// click it under XCTest (Design/TOOL_MODULES_PLAN.md).
    var toolOpenPanel: ((NSOpenPanel) -> URL?)?
    /// Where a tool-module's save panel goes (`ToolHost.exportFile`).
    var toolSavePanel: ((NSSavePanel) -> URL?)?
    /// Where the context menu's Save Selection as… panel goes; the same shape
    /// as the tool save panel's, for the right-clicked pane's selected bytes.
    var selectionSavePanel: ((NSSavePanel) -> URL?)?
    /// Where the join's dirty-pane confirmation goes: the test captures the
    /// alert (its title and its two buttons — the operation's verb and Cancel)
    /// and decides. Returns the alert's response (§22.2).
    var joinConfirm: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Where Update in Parent's "the source changed there" question goes: the
    /// test captures the alert and decides (`UPDATE_IN_PARENT.md` §3).
    var updateConfirm: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Where the Save All confirmation goes: the test captures the alert (its
    /// preview names every part, and it names every file that would be replaced)
    /// and decides. Returns the alert's response.
    var segmentWriteConfirm: ((NSAlert) -> NSApplication.ModalResponse)?
    /// How the write runs. In production it is a background Task with a
    /// `BackgroundOperation` (status-bar progress and cancel, §14.4); a test
    /// replaces it with an inline run so it can assert on the written bytes
    /// without waiting on a task.
    var segmentWriteRunner: (([SegmentWriter.Part], any ByteStorage, URL) -> Void)?
    /// Monotonic token identifying the current Search All. Each new search
    /// bumps it; a running search compares its captured token against the live
    /// one before touching the results panel, so a superseded search can never
    /// clobber the results of a newer one (§11).
    private var searchAllGeneration = 0
    /// The pane the in-flight Search All targets — the owner of the panel whose
    /// × must stop that search. Nil once the Search All task ends, so closing a
    /// stale panel (an already-completed search, or the other pane's) never
    /// cancels an unrelated search (§11).
    /// Reacts to the Layout settings tab changing the default direction: an open
    /// comparison re-lays out live, like the Word Size/Appearance settings (§6).
    private var layoutSettingsObserver: NSObjectProtocol?
    private var comparisonSettingsObserver: NSObjectProtocol?
    /// Keeps the toolbar's word-size radio on the value in force when it is
    /// changed from somewhere else — the View menu, or the Layout settings tab
    /// (§24.2). The hex views have their own observers for the re-layout.
    private var wordSizeObserver: NSObjectProtocol?

    /// Builds the background block index for comparison mode. The provider
    /// returns the current storages on every start/rebuild, so a revert that
    /// swaps a document's storage is always re-read.
    private lazy var comparisonCoordinator: ComparisonCoordinator = {
        ComparisonCoordinator { [weak self] in
            guard let self, self.mode == .comparison else { return nil }
            guard let left = self.windowModel.pane1.byteStorage,
                  let right = self.windowModel.pane2.byteStorage else { return nil }
            return (left, right)
        }
    }()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Bound once so the closures wired below name this surface directly:
        // a `[weak self]` closure cannot reach a property through self, and
        // every one of them is about the tab's own map.
        let surface = surface
        wireExternalChangeDetection()
        // A bookmark changed: the panes have already repainted their row, and
        // what is left for the window is the edit popover, which must not
        // outlive the mark it is editing (§20.3), the open form's list, which has
        // to show what the store holds (§20.5), and the minimap's margins, where
        // the same list is marked (§19.4.3).
        windowModel.onBookmarksChanged = { [weak self] row in
            self?.dismissEditPopoverIfItsMarkIsGone(row: row)
            self?.openGoToForm?.reloadBookmarks()
            surface.minimap.syncBookmarks()
            // The empty window shows the list too, and it is the only thing it
            // shows — so a mark added or removed while no file is open has to
            // reach it, and the title that counts them (§3.1, §20).
            self?.refreshEmptyStateBookmarks()
        }
        // Apply the Layout settings tab's direction change to an open comparison
        // immediately; outside comparison mode the value is stored and the next
        // comparison opens with it (§6).
        layoutSettingsObserver = NotificationCenter.default.addObserver(
            forName: LayoutSettings.layoutDirectionDidChangeNotification,
            object: nil,
            queue: .main
        // Posted on the main queue and handled there — said so out loud, because
        // the closure is `@Sendable` and everything it touches is the window.
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The toolbar's layout icon names the arrangement the click will
                // produce, so it follows the direction wherever it was changed
                // (§24.3) — including outside comparison mode, where the value is
                // only stored.
                self.revalidateToolbar()
                guard self.mode == .comparison else { return }
                self.comparisonView?.setLayout(vertical: LayoutSettings.isVertical)
                // The pane arrangement changed (View menu or the Settings tab), so
                // the minimap's internal split flips with it (§19).
                surface.minimap.updateLayout()
            }
        }
        wordSizeObserver = NotificationCenter.default.addObserver(
            forName: WordSize.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidateToolbar() }
        }
        // The Comparison settings tab's grouping distance decides what counts as
        // one change for diff navigation (§10.3.1). Applied live: the coordinator
        // re-groups the blocks it already has, without rescanning the files.
        comparisonSettingsObserver = NotificationCenter.default.addObserver(
            forName: ComparisonSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer runs on the main queue, but the closure is not
            // statically main-actor isolated.
            MainActor.assumeIsolated {
                self?.comparisonCoordinator.groupingGap = ComparisonSettings.groupingGap
            }
        }
        // Re-evaluate navigation availability on every index-state transition
        // (build starts/completes/cancels/stops, edits applied) (§10.3). The
        // minimap is not in this path: it reads difference state per byte from
        // the panes, the same live comparison they paint with, so the background
        // index never feeds it (§19).
        comparisonCoordinator.onStateChanged = { [weak self] in
            self?.refreshDiffNavigation()
            // Latch the badge decision to the latest DETERMINED outcome before
            // the toolbar sync reads it: while a build is in flight the outcome
            // is undetermined and the plaque must keep what it last showed, not
            // fall back to the arrows (§10.3).
            self?.updateIdenticalBadgeState()
            // The "Files are identical" badge is index-driven, not caret-driven:
            // it must swap in/out on every index transition, not only on mode
            // changes. The sync is coalesced and deferred a run-loop turn.
            self?.syncDiffNavigationToolbarItem()
            // Detail reads difference state per byte from the panes, but the
            // overview takes it from this index — one query per block beats
            // re-reading both files (§19.4).
            surface.minimap.followIndexChange()
        }

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true  // shown by Cmd+F (§11)
        findBar.onSearch = { [weak self] request, direction in
            self?.runSearch(request, direction: direction)
        }
        findBar.onSearchAll = { [weak self] request in
            self?.toggleSearchResults(request)
        }
        findBar.onError = { [weak self] message in
            self?.showFindMessage(message)
        }
        findBar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        // A pattern being typed describes no search yet, so the one that was
        // running stops being shown — count and greys together (§11). Its set
        // stays: the file has not moved under it, so a results panel listing it
        // is still telling the truth, until the next search replaces it.
        findBar.onPatternEdited = { [weak self] in
            self?.activePane.endMatchHighlighting()
        }
        // Keeping a pattern needs the one thing the bar has not got — a name —
        // so the bar hands over what the field describes and a sheet asks for
        // the rest (§11).
        findBar.onAddToFavorites = { [weak self] entry in
            self?.askToKeepPattern(entry)
        }
        findBar.onManageFavorites = {
            (NSApp.delegate as? AppDelegate)?.showFavoritePatternSettings()
        }
        view.addSubview(findBar)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        contentTopToView = contentContainer.topAnchor.constraint(equalTo: view.topAnchor)
        contentTopToFindBar = contentContainer.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: view.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentTopToView,
        ])

        // The tab's own surface: the tool panel, the dump and the minimap in
        // one split, which is the surface's view. A child view controller, so a
        // tool-module's own controller has a parent to be added to and the
        // surface gets the appearance and lifecycle callbacks a view of this
        // size should have.
        addChild(surface)
        surface.panesInMapOrder = { [weak self] in self?.windowPanesInMapOrder() ?? [] }
        surface.activeMapIndex = { [weak self] in self?.windowModel.activePaneIndex ?? 0 }
        _ = surface.view

        newTabDropStrip.translatesAutoresizingMaskIntoConstraints = false
        newTabDropStrip.onDropFiles = { [weak self] urls in
            self?.openFilesInNewTab(urls)
        }
        newTabDropStrip.onCopyModifierChanged = { [weak self] copying in
            self?.setPaneDragCopyingEverywhere(copying)
        }
        newTabDropStrip.onPaneDropped = { [weak self] paneID, copying in
            self?.tearOffPaneToNewTab(draggedPaneID: paneID, copying: copying)
        }
        contentContainer.addSubview(newTabDropStrip)
        let stripHeight = newTabDropStrip.heightAnchor.constraint(equalToConstant: 0)
        newTabDropStripHeight = stripHeight
        contentContainer.addSubview(panelSplit)
        // The dock takes its own height along the bottom rather than lying over
        // the panes, the way the New Tab strip at the other end does: a dock
        // drawn over a pane's status bar would hide the one line that says
        // where the caret is. Zero-height until the tab has a panel.
        fragmentDockStrip.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(fragmentDockStrip)
        let dockHeight = fragmentDockStrip.heightAnchor.constraint(equalToConstant: 0)
        fragmentDockHeight = dockHeight
        // Over the panes, under nothing: added after the split, so a panel is
        // drawn on top of what it covers.
        fragmentHost.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(fragmentHost)
        NSLayoutConstraint.activate([
            // Above everything, across the whole window: the strip is about the
            // window's tabs, so it spans the minimap as well as the panes.
            newTabDropStrip.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            newTabDropStrip.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            newTabDropStrip.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            stripHeight,
            panelSplit.topAnchor.constraint(equalTo: newTabDropStrip.bottomAnchor),
            panelSplit.bottomAnchor.constraint(equalTo: fragmentDockStrip.topAnchor),
            panelSplit.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            panelSplit.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            fragmentDockStrip.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            fragmentDockStrip.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            fragmentDockStrip.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            dockHeight,
            fragmentHost.topAnchor.constraint(equalTo: panelSplit.topAnchor),
            fragmentHost.bottomAnchor.constraint(equalTo: panelSplit.bottomAnchor),
            fragmentHost.leadingAnchor.constraint(equalTo: panelSplit.leadingAnchor),
            fragmentHost.trailingAnchor.constraint(equalTo: panelSplit.trailingAnchor),
        ])
        surface.minimap.wire()
        surface.paneViewsInMapOrder = { [weak self] in
            guard let self else { return [] }
            if let comparison = self.comparisonView {
                return [comparison.paneView1, comparison.paneView2]
            }
            return self.activeFilePane.map { [$0] } ?? []
        }
        apply(mode: .empty)
    }

    /// Swaps the content area for the given window mode (§3 of REQUIREMENTS.md).
    func apply(mode: WindowMode) {
        let surface = surface
        let wasComparison = self.mode == .comparison
        self.mode = mode
        if mode == .comparison && !wasComparison {
            // A fresh comparison, not a rebuild of the running one: no index
            // for this file pair exists yet, so the plaque starts on the
            // (disabled) arrows rather than a badge a previous comparison left
            // latched — "Files are identical" must never show before its own
            // index confirms it. A rebuild (revert, a replaced file) keeps the
            // latch and shows its last determined state while it runs.
            showsIdenticalBadge = false
        }
        syncDiffNavigationToolbarItem()
        unwireComparison()
        // The strip beside each map mirrors the pane's partition (§19.4.4): a
        // cut, a removal, a moved cut, or a content edit that shifts one all
        // repaint it. The pane fires this on every partition change, so it is
        // set here — once per mode apply, on both panes — rather than where the
        // form happens to be open. It reloads the form when it is open and syncs
        // the strip whether or not it is.
        windowModel.pane1.onSegmentsChanged = { [weak self] in
            self?.openSegmentsForm?.reloadSegments()
            surface.minimap.syncSegments()
        }
        windowModel.pane2.onSegmentsChanged = { [weak self] in
            self?.openSegmentsForm?.reloadSegments()
            surface.minimap.syncSegments()
        }
        // The panes are about to be rebuilt, so a scan in flight would land its
        // set in a pane that is going away.
        cancelFind()
        endIndexing()
        // Panes are rebuilt on every apply, so the viewport mirrors must start
        // empty and fill in as the new panes report their visible ranges (§19).
        surface.minimap.clearViewports()
        surface.minimapView.setViewports([])

        switch mode {
        case .empty:
            activeFilePane = nil
            comparisonView = nil
            comparisonCoordinator.stop()
            // Returning to the launch state must also dismiss the find bar —
            // nothing is left to search (§11).
            hideFindBar()
            let emptyView = EmptyStateView()
            emptyStateView = emptyView
            emptyView.setBookmarks(windowModel.bookmarkStore.bookmarks)
            emptyView.onOpenFiles = { [weak self] urls in
                self?.handleEmptyDrop(urls)
            }
            // An empty window is the most obvious place to put a pane, and it
            // has only the first one to put it in.
            emptyView.paneDropOutcome = { [weak self] paneID, copying in
                guard let self,
                      self.paneLocation(ofPaneWith: paneID)?.controller !== self
                else { return .none }
                return self.paneDropOutcome(draggedPaneID: paneID, onPaneAt: 0,
                                            copying: copying)
            }
            emptyView.onPaneDropped = { [weak self] paneID, copying in
                self?.performPaneDrop(draggedPaneID: paneID, onPaneAt: 0, copying: copying)
            }
            emptyView.onCopyModifierChanged = { [weak self] copying in
                self?.setPaneDragCopyingEverywhere(copying)
            }
            setContentView(emptyView)
            announceNewerRelease(on: emptyView)

        case .singleFile:
            let paneModel = windowModel.pane1
            // Reuse the pane's view if it exists (closing the second pane
            // returns here with the same first file): only a first-ever open
            // builds it. Re-parenting it into the drop view keeps its scroll.
            let pane = paneView(for: paneModel)
            // Header right-click menu: acts on THIS pane (§4/§5).
            pane.paneMenu = makePaneMenu(for: paneModel)
            // Offset-column right-click menu ("Select Block from Here at «address»", §10.2).
            pane.offsetMenuProvider = { [weak self] offset in
                self?.makeOffsetMenu(for: paneModel, offset: offset) ?? NSMenu()
            }
            wireBookmarkDoubleClick(pane, for: paneModel)
            // Status bar: the size's tooltip and copy menu, and the OVR/INS
            // click, all resolving THIS pane (§3.4, §7.6).
            wireStatusBar(pane, for: paneModel)
            // Close button: closing the last file returns to empty mode (§3.5).
            pane.onClose = { [weak self] in self?.closePane(at: 0) }
            // The link to a parent document, in a tab opened from a part of one.
            pane.onRevealOrigin = { [weak self, weak paneModel] in
                guard let paneModel else { return }
                self?.revealOrigin(of: paneModel)
            }
            // The panel closed itself; the bar's toggle follows (§11).
            pane.onSearchResultsClose = { [weak self] _ in
                self?.syncFindBarToActivePane()
            }
            pane.onMatchesChanged = { [weak self] in
                self?.searchAppearanceChanged()
            }
            // The minimap's single map mirrors this pane: edits rebuild its
            // cells, a moved caret moves the selection overlay, and scrolling
            // moves the viewport rectangle (§19).
            surface.minimap.track(pane)
            paneModel.onEdit = { [weak self] edit in
                surface.minimap.repaint(after: edit, mapIndex: 0)
                self?.invalidateMatches(in: paneModel)
                self?.tools.paneEdited(paneModel, edit)
            }
            paneModel.onFullInvalidation = { [weak self] in
                self?.tools.paneReloaded(paneModel)
                self?.surface.minimapView.invalidateCells()
                surface.minimap.refreshMaps()
                self?.invalidateMatches(in: paneModel)
            }
            // A save moves the on-disk reference, so the map's red cells have to
            // clear even though no byte changed (§19).
            paneModel.onSavedStateChanged = { [weak self] in
                self?.surface.minimapView.invalidateCells()
                surface.minimap.refreshMaps()
            }
            paneModel.onCaretChanged = { [weak surface] in
                surface?.minimap.updateSelections()
            }
            // Wrap in the drop-target split view (§4.3 single-file mode). The
            // pane itself is NOT drop-registered here so the outer view wins.
            let dropView = SingleFileDropView(paneView: pane)
            singleFileDropView = dropView
            dropView.onDragSessionChanged = { [weak self] active in
                self?.setNewTabStripVisible(active)
            }
            dropView.onCopyModifierChanged = { [weak self] copying in
                self?.setPaneDragCopyingEverywhere(copying)
            }
            // A dragged pane gets the same four zones a file gets, and they
            // mean the same four things: the far half opens it as the second
            // pane, and the three bands over this file join it at either end or
            // put it in this pane's place.
            //
            // Which of those a pane from *this* window may do is `PaneDrop`'s to
            // say, not a blanket refusal here: its own pane can still be joined
            // to itself at either end, and only the middle band and the second
            // half are meaningless for it.
            dropView.paneDropOutcome = { [weak self] paneID, target, copying in
                guard let self else { return .none }
                let (index, band) = Self.singleFilePaneDrop(target)
                return self.paneDropOutcome(draggedPaneID: paneID, onPaneAt: index,
                                            band: band, copying: copying)
            }
            dropView.onPaneDropped = { [weak self] paneID, target, copying in
                let (index, band) = Self.singleFilePaneDrop(target)
                self?.performPaneDrop(draggedPaneID: paneID, onPaneAt: index,
                                      band: band, copying: copying)
            }
            dropView.onDrop = { [weak self] target, urls in
                self?.handleSingleFileDrop(target: target, urls: urls)
            }
            activeFilePane = pane
            comparisonView = nil
            comparisonCoordinator.stop()
            setContentView(dropView)
            pane.focusHexView()

        case .comparison:
            wireComparison()
            let pane1 = windowModel.pane1
            let pane2 = windowModel.pane2
            // Reuse each pane's view where it exists: opening the second file
            // comes here with the first pane already built, so only pane2 is
            // first-ever. Re-parenting the first view into the splitter keeps
            // its scroll and focus instead of resetting them (§3.3).
            let pane1View = paneView(for: pane1)
            let pane2View = paneView(for: pane2)
            // Header right-click menus act on their own pane (§4/§5).
            pane1View.paneMenu = makePaneMenu(for: pane1)
            pane2View.paneMenu = makePaneMenu(for: pane2)
            // Offset-column right-click menus ("Select Block from Here at «address»", §10.2).
            pane1View.offsetMenuProvider = { [weak self] offset in
                self?.makeOffsetMenu(for: pane1, offset: offset) ?? NSMenu()
            }
            pane2View.offsetMenuProvider = { [weak self] offset in
                self?.makeOffsetMenu(for: pane2, offset: offset) ?? NSMenu()
            }
            // A double click on an address marks that row, in whichever pane
            // was clicked (§20.3).
            wireBookmarkDoubleClick(pane1View, for: pane1)
            wireBookmarkDoubleClick(pane2View, for: pane2)
            // Each status bar's size menu and OVR/INS click act on their own
            // pane (§3.4, §7.6).
            wireStatusBar(pane1View, for: pane1)
            wireStatusBar(pane2View, for: pane2)
            // Each map's viewport rectangle mirrors its pane's visible slice (§19).
            surface.minimap.track(pane1View)
            surface.minimap.track(pane2View)
            let view = ComparisonView(
                coordinator: comparisonCoordinator,
                paneView1: pane1View,
                paneView2: pane2View
            )
            view.onPaneActivated = { [weak self] index in
                self?.activatePane(at: index)
            }
            // Comparison-mode drops target the hovered pane's bands (§22.4):
            // the three bands (insert / replace / append) are the drop targets,
            // so the panes themselves are not drop-registered.
            view.bands1.onDrop = { [weak self] target, urls in
                self?.handleComparisonBandDrop(targetPane: 0, target: target, urls: urls)
            }
            view.bands2.onDrop = { [weak self] target, urls in
                self?.handleComparisonBandDrop(targetPane: 1, target: target, urls: urls)
            }
            // The same overlays take a dragged pane, in the same three bands: a
            // pane holds a dump, so the ends mean what they mean for a file —
            // join this at the front, join it at the back — and only the middle
            // differs (`Design/PANE_DRAG_PLAN.md`).
            for (index, bands) in [(0, view.bands1!), (1, view.bands2!)] {
                bands.paneDropOutcome = { [weak self] paneID, band, copying in
                    self?.paneDropOutcome(draggedPaneID: paneID, onPaneAt: index,
                                          band: band, copying: copying) ?? .none
                }
                bands.onPaneDropped = { [weak self] paneID, band, copying in
                    self?.performPaneDrop(draggedPaneID: paneID, onPaneAt: index,
                                          band: band, copying: copying)
                }
                // A drag entering either pane raises the strip, so it is on
                // screen before the pointer could reach it.
                bands.onDragSessionChanged = { [weak self] active in
                    self?.setNewTabStripVisible(active)
                }
                bands.onCopyModifierChanged = { [weak self] copying in
                    self?.setPaneDragCopyingEverywhere(copying)
                }
            }
            pane1View.onClose = { [weak self] in self?.closePane(at: 0) }
            pane2View.onClose = { [weak self] in self?.closePane(at: 1) }
            pane1View.onRevealOrigin = { [weak self] in
                guard let self else { return }
                self.revealOrigin(of: self.windowModel.pane1)
            }
            pane2View.onRevealOrigin = { [weak self] in
                guard let self else { return }
                self.revealOrigin(of: self.windowModel.pane2)
            }
            // Closing a pane's Search All panel stops that search (§11). The
            // bar's toggle is re-read rather than turned off: in comparison
            // mode the panel that closed may be the *other* pane's, and the
            // button describes the active one.
            pane1View.onSearchResultsClose = { [weak self] _ in
                self?.syncFindBarToActivePane()
            }
            pane2View.onSearchResultsClose = { [weak self] _ in
                self?.syncFindBarToActivePane()
            }
            pane1View.onMatchesChanged = { [weak self] in
                self?.searchAppearanceChanged()
            }
            pane2View.onMatchesChanged = { [weak self] in
                self?.searchAppearanceChanged()
            }

            activeFilePane = windowModel.activePaneIndex == 0 ? pane1View : pane2View
            comparisonView = view
            setContentView(view)
            view.setActive(windowModel.activePaneIndex)
            // The minimap's stacked divider mirrors the panes' divider position,
            // so keep it glued whenever the panes' divider moves (§19).
            view.onFractionChanged = { [weak surface] in
                surface?.minimap.updateLayout()
            }
            comparisonCoordinator.start()
            activeFilePane?.focusHexView()
        }
        surface.minimap.updateLayout()
        surface.minimap.refreshMaps()
        // A different file can call for a different mode — a dump too large for
        // the detail window opens in overview (§19.4).
        applyPreferredMinimapMode()
        refreshDiffNavigation()
        // The empty state has no pane view to report a header, so the title is
        // set here too; with panes open this is the first of many, and the pane
        // views keep it current from then on.
        updateWindowTitle()
        // The panes were just rebuilt — new views, no results panels, and
        // possibly another active pane — so the bar is re-read rather than
        // left describing the panes that went away (§11).
        syncFindBarToActivePane()
    }

    /// Asks whether a newer release has been published, and — if one has — says
    /// so on the landing screen that is on it now.
    ///
    /// In the background, and it never holds the window up: the screen is set
    /// up and drawn first, and the line arrives after it, when it arrives at
    /// all. Nothing waits for it, and no failure of it is the window's problem
    /// — offline is the normal state of a bench, and a landing screen that
    /// reported its own errand would be a landing screen that has stopped being
    /// about the user's file (`ReleaseSource.newerRelease(than:)`).
    ///
    /// The answer is held for the run (`GitHubReleases`), so a window that goes
    /// back to empty — which is what closing the last file does — asks again of
    /// a value in memory rather than of github.com.
    @discardableResult
    private func announceNewerRelease(on emptyView: EmptyStateView) -> Task<Void, Never>? {
        releaseCheckTask = Task { [weak self, weak emptyView] in
            guard let release = await Self.releases
                .newerRelease(than: .current) else { return }
            // The answer is older than the question: a file may have been
            // opened, or another window drawn, since it was asked.
            guard let self, self.emptyStateView === emptyView else { return }
            emptyView?.showAvailableRelease(release)
        }
        return releaseCheckTask
    }

    /// Where the landing screen's check is asked: the app's own source, and a
    /// stub in a test that is about the check.
    ///
    /// Under test the default is a source with nothing to announce, so that the
    /// tests which are *not* about this — and every one of them that opens an
    /// empty window is not — neither reach github.com nor wait on it. A suite
    /// that needs the network fails on a train, for reasons that have nothing to
    /// do with what it was testing.
    static var releases: ReleaseSource = isRunningTests ? NoReleases() : GitHubReleases.shared

    /// Wires companion panes and coordinator callbacks for comparison mode.
    /// Runs on every comparison apply — pane objects are swapped by Swap Panels
    /// and close-promotion, so the callbacks must target the CURRENT panes.
    private func wireComparison() {
        let surface = surface
        windowModel.pane1.companion = windowModel.pane2
        windowModel.pane2.companion = windowModel.pane1
        windowModel.pane1.onEdit = { [weak self] edit in
            self?.comparisonCoordinator.record(edit: edit)
            surface.minimap.repaint(after: edit, mapIndex: 0)
            self?.invalidateMatches(in: self?.windowModel.pane1)
            self.map { $0.tools.paneEdited($0.windowModel.pane1, edit) }
        }
        windowModel.pane2.onEdit = { [weak self] edit in
            self?.comparisonCoordinator.record(edit: edit)
            surface.minimap.repaint(after: edit, mapIndex: 1)
            self?.invalidateMatches(in: self?.windowModel.pane2)
            self.map { $0.tools.paneEdited($0.windowModel.pane2, edit) }
        }
        // The tool-module hears first. It is the one that answers with a
        // progress bar, and everything else here either schedules its work or
        // only marks something dirty — so putting it last was the panel
        // waiting on a queue of things that were not waiting on it.
        windowModel.pane1.onFullInvalidation = { [weak self] in
            self.map { $0.tools.paneReloaded($0.windowModel.pane1) }
            self?.comparisonCoordinator.rebuild()
            self?.surface.minimapView.invalidateCells()
            surface.minimap.refreshMaps()
            self?.invalidateMatches(in: self?.windowModel.pane1)
        }
        windowModel.pane2.onFullInvalidation = { [weak self] in
            self.map { $0.tools.paneReloaded($0.windowModel.pane2) }
            self?.comparisonCoordinator.rebuild()
            self?.surface.minimapView.invalidateCells()
            surface.minimap.refreshMaps()
            self?.invalidateMatches(in: self?.windowModel.pane2)
        }
        // A save clears modified state without changing a byte, so the minimap's
        // red cells have to go even though the bytes stayed put (§19).
        windowModel.pane1.onSavedStateChanged = { [weak self] in
            self?.surface.minimapView.invalidateCells()
            surface.minimap.refreshMaps()
        }
        windowModel.pane2.onSavedStateChanged = { [weak self] in
            self?.surface.minimapView.invalidateCells()
            surface.minimap.refreshMaps()
        }
        // A moved caret changes whether a next/previous block still exists from
        // the new position, so navigation enablement follows it (§10.3); the
        // selection overlay on the minimap follows the caret too (§19).
        windowModel.pane1.onCaretChanged = { [weak self] in
            self?.refreshDiffNavigation()
            surface.minimap.updateSelections()
        }
        windowModel.pane2.onCaretChanged = { [weak self] in
            self?.refreshDiffNavigation()
            surface.minimap.updateSelections()
        }
    }

    private func unwireComparison() {
        windowModel.pane1.companion = nil
        windowModel.pane2.companion = nil
        windowModel.pane1.onEdit = nil
        windowModel.pane2.onEdit = nil
        windowModel.pane1.onFullInvalidation = nil
        windowModel.pane2.onFullInvalidation = nil
        windowModel.pane1.onSavedStateChanged = nil
        windowModel.pane2.onSavedStateChanged = nil
    }

    /// The `FilePaneView` for `model`, created on first use and reused
    /// thereafter — the view follows its model, so a mode change or pane
    /// re-ordering re-parents the same view instead of rebuilding it (§3.3).
    func paneView(for model: PaneViewModel) -> FilePaneView {
        let key = ObjectIdentifier(model)
        if let existing = paneViews[key] { return existing }
        let view = FilePaneView(viewModel: model)
        // A pane drag raises every window's strip, since any of them could take
        // the pane, and lowers them all when the session ends.
        view.onDragSessionChanged = { [weak self] active in
            self?.setNewTabStripVisibleEverywhere(active)
        }
        // The window is named after the files its panes hold, so the title
        // follows the very signal the pane headers follow — a file opened,
        // saved under a new name, reverted or detached by a join moves both at
        // once, and there is no second list of places to remember.
        view.onHeaderChanged = { [weak self] in
            self?.updateWindowTitle()
            // A fragment panel's pill is named after its pane and marked when
            // the parent has not got its bytes back, so both follow the very
            // signal the header follows.
            self?.fragments.refreshDock()
        }
        // The results panel is a child controller of this one: containment is
        // what makes its appear/disappear callbacks fire, and it is what will
        // let the same panel be presented some other way later. Its *view*
        // stays where the pane puts it — `addChild` does not care where a
        // child's view is installed, only who owns the child.
        addChild(view.searchResults)
        paneViews[key] = view
        return view
    }

    /// Drops the view built for `model` — what a closed fragment panel leaves
    /// behind. The window's own panes are persistent objects and never reach
    /// this; a panel's pane goes when the panel does.
    func forgetPaneView(of model: PaneViewModel) {
        paneViews.removeValue(forKey: ObjectIdentifier(model))
    }

    /// What the window (and so its tab) is called: the files it holds.
    ///
    /// A tab bar with nothing to read on it is not worth having, and the Window
    /// menu listing the app's name three times is no better. A window holding
    /// nothing says so — "Empty", which is what it is. Not the app's name, which
    /// says nothing about this window in particular, and not "Untitled", which
    /// already means a New File that has never been saved and would make an
    /// empty tab and a fresh document read alike.
    var windowTitle: String {
        switch mode {
        case .empty:
            // A window with no file is not necessarily a window with nothing in
            // it: the marks are the window's, not the file's (§20), so a window
            // kept open for them says how many it is keeping.
            let marks = windowModel.bookmarkStore.bookmarks.count
            guard marks > 0 else { return "Empty" }
            return marks == 1 ? "Empty (1 Bookmark)" : "Empty (\(marks) Bookmarks)"
        case .singleFile:
            return windowModel.pane1.status.fileName
        case .comparison:
            return "\(windowModel.pane1.status.fileName) ↔ \(windowModel.pane2.status.fileName)"
        }
    }

    private func updateWindowTitle() {
        viewIfLoaded?.window?.title = windowTitle
    }

    private func setContentView(_ newView: NSView) {
        surface.setContent(newView)
    }

    /// Opens the strip for a drag's lifetime, or closes it when the drag is over.
    ///
    /// Never in the empty mode: a window holding nothing has no reason to send a
    /// file somewhere else.
    ///
    /// The panes move down to make room rather than being covered, so the bands
    /// keep describing the dump they are drawn over — an overlay left them
    /// offset from the content by the strip's height, and hid the pane headers
    /// besides.
    /// Raises or lowers the strip in every open window.
    ///
    /// A file drag belongs to the window it is over, but a pane drag belongs to
    /// the app: the pane can land in any window, so every window has to offer
    /// somewhere to put it. With no registry — a controller built on its own —
    /// this window is the whole app.
    private func setNewTabStripVisibleEverywhere(_ visible: Bool) {
        for controller in openDocuments?.controllers ?? [self] {
            controller.setNewTabStripVisible(visible, forPane: true)
        }
    }

    /// Passes an Option press or release on to every drop zone the drag has put
    /// on screen, in this window and the others.
    ///
    /// Only the zone under the pointer hears the modifier: AppKit sends
    /// `draggingUpdated` to the destination the pointer is in and to no other,
    /// so the band being hovered re-labelled itself while the New Tab strip
    /// above it went on reading "Move to New Tab" until the pointer reached it.
    /// The zones are all promises about the same drop, and one of them saying
    /// "move" while another says "duplicate" means at least one is lying — so
    /// the news travels the same road the strip's own raising does.
    private func setPaneDragCopyingEverywhere(_ copying: Bool) {
        for controller in openDocuments?.controllers ?? [self] {
            controller.setPaneDragCopying(copying)
        }
    }

    /// This window's New Tab strip and its comparison overlays, so a test can
    /// read what every zone on screen is promising at once — which is the whole
    /// question the broadcast above answers.
    var newTabStripForTesting: NewTabDropStrip { newTabDropStrip }
    var comparisonBandsForTesting: (PaneDropBandsView, PaneDropBandsView)? {
        guard let view = comparisonView else { return nil }
        return (view.bands1, view.bands2)
    }

    /// Re-captions this window's zones for the modifier. Each one ignores it
    /// unless it has a pane in flight, so the mode's unused zones stay as they
    /// are, and none of them reports the change back — it came from a zone that
    /// already knows, and answering would be a loop.
    func setPaneDragCopying(_ copying: Bool) {
        newTabDropStrip.setPaneDragCopying(copying)
        singleFileDropView?.setPaneDragCopying(copying)
        comparisonView?.bands1.setPaneDragCopying(copying)
        comparisonView?.bands2.setPaneDragCopying(copying)
    }

    private func setNewTabStripVisible(_ visible: Bool, forPane isPane: Bool = false) {
        let wanted = visible && mode != .empty
        guard let stripHeight = newTabDropStripHeight else { return }
        let target: CGFloat = wanted ? NewTabDropStrip.height : 0
        guard stripHeight.constant != target else { return }
        newTabDropStrip.setDragActive(wanted, forPane: isPane)
        NSAnimationContext.runAnimationGroup { context in
            // Slightly quicker on the way out than in. It cannot beat a
            // cancelled drag's pill home — `endedAt` only arrives once the
            // pill has landed — so this is about the panes not dawdling once
            // the drag is over, nothing more.
            context.duration = wanted ? 0.12 : 0.10
            context.allowsImplicitAnimation = true
            stripHeight.animator().constant = target
            contentContainer.layoutSubtreeIfNeeded()
        }
    }

    /// Opens files in a tab of their own — the strip's whole purpose.
    func openFilesInNewTab(_ urls: [URL]) {
        guard let tab = makeSiblingTab?() else { return }
        tab.openFiles(urls)
    }

    /// How much of a pane overlay's top the strip covers, so its bands can start
    /// below it.
    ///
    /// **Zero in the arrangement that shipped**, where the strip takes its own
    /// height above everything and covers nothing. Kept, and kept measured, for
    /// the reason it was written: where the strip goes has already moved three
    /// times, and AppKit resolves a drop destination by frame among registered
    /// views rather than by hit-testing (`PaneDropBandsView` records a file
    /// silently discarded to that once). A geometric answer cannot disagree with
    /// where the strip actually is; a constant would, quietly, the next time it
    /// moves.
    private func dropStripInset(for overlay: NSView) -> CGFloat {
        guard newTabDropStrip.superview != nil, overlay.window != nil else { return 0 }
        let stripBottom = newTabDropStrip.convert(NSPoint(x: 0, y: newTabDropStrip.bounds.minY),
                                                  to: nil).y
        let overlayTop = overlay.convert(NSPoint(x: 0, y: overlay.bounds.maxY), to: nil).y
        return max(0, min(overlay.bounds.height, overlayTop - stripBottom))
    }

    /// Re-measures the strip's share of each pane overlay after a layout pass.
    private func updateDropStripInsets() {
        let overlays = [comparisonView?.bands1, comparisonView?.bands2,
                        singleFileDropView?.thisFileBands].compactMap { $0 }
        for bands in overlays {
            bands.topInset = dropStripInset(for: bands)
        }
    }

    // MARK: - Tools (Design/TOOL_MODULES_PLAN.md)

    /// How much of the dump's spare width each side panel is borrowing right
    /// now: the room it opened into instead of pushing the window's edge out.
    /// Kept so the way out mirrors the way in — a panel gives back what it
    /// borrowed before the window gives up anything.
    private var borrowedByToolPanel: CGFloat = 0
    private var borrowedByMinimap: CGFloat = 0

    /// The dump area's spare width: how much wider it is than the hex grid it
    /// is showing. A window the user has dragged wider than its content has
    /// room in it, and a side panel opens into that room before it costs the
    /// window anything.
    ///
    /// Zero when there is no content to measure (the empty state, or a layout
    /// that has not happened yet) and when the dump is already narrower than
    /// its grid — there the panel costs the window its full width, as it
    /// always did.
    ///
    /// Internal rather than private so the suite can set a window up with a
    /// known amount of room, or none.
    func dumpAreaSlack() -> CGFloat {
        let needed = standardContentWidth()
        guard needed > 0 else { return 0 }
        return max(0, contentHost.frame.width - needed)
    }

    /// What the window's width must change by for a side panel gaining or
    /// giving up `delta` points, and the borrow that goes with it.
    ///
    /// Growing, the panel spends the dump's spare width first and asks the
    /// window only for what is left over. Shrinking, it hands that spare width
    /// back before the window gives up anything: a panel that cost the window
    /// nothing to open must cost it nothing to close, or the window would end
    /// up narrower than it was before the panel was ever shown.
    private func windowDelta(forPanel delta: CGFloat, borrowed: inout CGFloat) -> CGFloat {
        if delta > 0 {
            let borrow = min(delta, dumpAreaSlack())
            borrowed += borrow
            return delta - borrow
        }
        let given = min(-delta, borrowed)
        borrowed -= given
        return delta + given
    }

    /// The window move that goes with opening or closing the tool panel: the
    /// window grows or shrinks by whatever the dump's own spare width cannot
    /// absorb, so the dump keeps the width its content needs. The mirror of the
    /// minimap's, and mirrored in the literal sense — the window's LEADING edge
    /// moves and the trailing one stays put, because the panel opens on the
    /// left.
    func toolPanelWindowResize(delta: CGFloat) -> ((CGFloat) -> Void)? {
        guard let window = view.window, delta != 0 else { return nil }
        // The split keeps its dividers whether a pane is 400 points wide or
        // none at all, so no seam appears or goes with the panel and the
        // panel's change is the width alone.
        let move = windowDelta(forPanel: delta, borrowed: &borrowedByToolPanel)
        guard move != 0 else { return nil }
        let start = window.frame
        let targetWidth = max(0, start.width + move)
        return { [weak window] progress in
            guard let window else { return }
            var frame = start
            frame.size.width = start.width + (targetWidth - start.width) * progress
            // The right edge stays where it is, so the left one carries the
            // whole change.
            frame.origin.x = start.maxX - frame.size.width
            if let visibleFrame = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX),
                                     visibleFrame.maxX - frame.size.width)
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// Tools ▸ ⟨module⟩ and Tools ▸ None. The item carries the tool-module's
    /// identifier in `representedObject`, and None carries nothing, so one
    /// action serves every row.
    @objc func activateTool(_ sender: NSMenuItem) {
        frontTools.activate(sender.representedObject as? String)
    }

    // MARK: - Files, for a tool-module (Design/TOOL_MODULES_PLAN.md)

    /// The largest file a tool-module may be handed. A component to place
    /// inside a dump is measured in kilobytes; the cap is here so a mistaken
    /// pick — a disk image, a video — is refused with a sentence rather than
    /// read into memory whole.
    static let toolFileSizeLimit: UInt64 = 64 * 1024 * 1024
    /// The cap in force, so a test can move it under a small file instead of
    /// writing a 64 MiB fixture.
    static var toolFileSizeLimitForTesting: UInt64 = toolFileSizeLimit

    /// Asks the user for a file and hands back its bytes, for
    /// `ToolHost.requestFile`.
    ///
    /// The panel is the app's, deliberately: what the user picks is reachable
    /// because *this process* was granted it, and a tool-module never has to be
    /// given a URL or a security scope of its own. It gets bytes.
    func requestFileForTool(kinds: [String], message: String?) -> ToolFile? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let message { panel.message = message }
        panel.allowedContentTypes = kinds.compactMap { UTType(filenameExtension: $0) }
        let url: URL?
        if let toolOpenPanel {
            url = toolOpenPanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return nil }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            guard size <= Self.toolFileSizeLimitForTesting else {
                presentAlert(title: "That file is too large",
                             message: "“\(url.lastPathComponent)” is \(size) bytes. "
                                + "A tool can be handed at most "
                                + "\(Self.toolFileSizeLimitForTesting) bytes.")
                return nil
            }
            return ToolFile(name: url.lastPathComponent, bytes: [UInt8](try Data(contentsOf: url)))
        } catch {
            presentFileError("Could not read the file.", error, url: url)
            return nil
        }
    }

    /// Offers bytes to the user as a file to save, for `ToolHost.exportFile`.
    func exportFileForTool(_ bytes: [UInt8], suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let url: URL?
        if let toolSavePanel {
            url = toolSavePanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return false }
        do {
            try Data(bytes).write(to: url, options: .atomic)
            return true
        } catch {
            presentFileError("Could not write the file.", error, url: url)
            return false
        }
    }

    /// Opens bytes a tool-module hands over as a panel over the file they came
    /// out of, for `ToolHost.openPart` — the untitled copy Open Zone makes, of
    /// bytes that are not a range of this file. The window's bookmarks stay
    /// behind: their offsets are the dump's, not these bytes'.
    func openPartForTool(
        _ bytes: [UInt8], named name: String, from pane: PaneViewModel,
        source: Range<UInt64>, layout: UEFIRootLayout, kind: DocumentOrigin.Kind,
        part: UEFIRebuild.Target?
    ) {
        openFragment(
            bytes,
            named: name,
            origin: DocumentOrigin(
                parent: pane, source: source,
                partName: Self.partName(ofTab: name, parent: pane.status.fileName),
                layout: layout, kind: kind, rebuildTarget: part, content: bytes
            )
        )
    }

    // MARK: - Fragment panels (Design/FRAGMENT_PANELS_PLAN.md)

    /// Opens a part of one of this tab's files as a panel over it: a zone, a
    /// decompressed body, bytes a tool-module handed over.
    ///
    /// The panel is where a part opens — there is no second route, and the tab
    /// stays what a tab is, a comparison.
    @discardableResult
    func openFragment(_ bytes: [UInt8], named name: String,
                      origin: DocumentOrigin? = nil,
                      animated: Bool = true) -> FragmentDock.PanelID? {
        fragments.open(bytes, named: name, origin: origin, animated: animated)
    }

    /// What the question a panel with something to put back asks answers with.
    /// Swappable so the suite does not have to drive a modal.
    var fragmentCloseConfirm: ((NSAlert) -> NSApplication.ModalResponse)?

    /// Closes a fragment panel, asking first if there is anything to lose.
    ///
    /// Two different questions, because there are two different losses. A part
    /// that holds an edit its parent has not got back is offered the thing it
    /// was opened for — Update in Parent — rather than a save panel for a file
    /// nobody wants on disk. A part with nowhere to put its bytes back gets the
    /// ordinary save/discard question.
    func closeFragment(_ id: FragmentDock.PanelID) {
        guard let pane = fragments.pane(id) else { return }
        // Parts taken out of this one lose their way back when it goes, and a
        // link that dies without a word is a link the reader meets later, when
        // Update in Parent refuses.
        //
        // One question at a time, in the order the consequences arrive: what
        // closing does to other panels, then what it does to this one's bytes.
        // Folded into one dialog they read as a single warning and the second
        // half goes unread — which is the same as not asking.
        let stranded = fragments.panelsLinked(to: pane).count
        if stranded > 0, !confirmStranding(stranded, closing: pane.status.fileName) { return }
        closeFragment(id, pane: pane)
    }

    /// Everything after the question about links: what closing does to this
    /// panel's own bytes, and then the closing.
    ///
    /// `done` says whether the panel really went — false where the reader
    /// cancelled. It does not run at all where the answer went to a sheet that
    /// was then abandoned (a Save As backed out of), which leaves whatever was
    /// waiting on it waiting, exactly as it does for a pane.
    ///
    /// Asked separately from the links question because closing the whole
    /// window asks this of every panel and asks the other of none: nothing is
    /// stranded when everything goes at once.
    private func closeFragment(_ id: FragmentDock.PanelID, pane: PaneViewModel,
                               then done: ((Bool) -> Void)? = nil) {
        if let origin = pane.origin, origin.hasChanges(in: pane) {
            switch confirmClosingUnreturnedPart(origin) {
            case .alertFirstButtonReturn:  // Update in Parent
                if let task = performUpdateInParent(of: pane) {
                    Task { [weak self] in
                        await task.value
                        self?.closeFragmentIfPutBack(id, pane: pane, origin: origin, then: done)
                    }
                    return
                }
                closeFragmentIfPutBack(id, pane: pane, origin: origin, then: done)
                return
            case .alertSecondButtonReturn:  // Close Anyway
                break
            default:  // Cancel
                done?(false)
                return
            }
        }
        if pane.status.isDirty, pane.origin == nil {
            switch confirmSaveDiscardCancel() {
            case .alertFirstButtonReturn:  // Save
                savePane(pane, onSaved: { [weak self] in
                    self?.fragments.close(id)
                    done?(true)
                }, onCancelled: { done?(false) })
                return
            case .alertSecondButtonReturn:  // Don't Save
                break
            default:  // Cancel
                done?(false)
                return
            }
        }
        fragments.close(id)
        done?(true)
    }

    /// Closes the panel only if the bytes really did go back. An update can be
    /// refused — a parent that is read-only, a part whose length changed — and
    /// it says so in an alert of its own; closing anyway would throw away the
    /// bytes the reader has just been told could not be put back.
    private func closeFragmentIfPutBack(_ id: FragmentDock.PanelID,
                                        pane: PaneViewModel, origin: DocumentOrigin,
                                        then done: ((Bool) -> Void)? = nil) {
        guard !origin.hasChanges(in: pane) else {
            fragments.refreshDock()
            done?(false)
            return
        }
        fragments.close(id)
        done?(true)
    }

    /// Every panel of the tab, parts before the panels they came out of.
    ///
    /// The order is what makes Update in Parent mean anything while the window
    /// is closing: a part put back into another panel has to find that panel
    /// still open, and the panel it lands in is then asked about the bytes it
    /// has just been handed.
    private var fragmentsInnermostFirst: [FragmentDock.PanelID] {
        let panels = fragments.dock.panels
        func depth(_ id: FragmentDock.PanelID, seen: Int = 0) -> Int {
            guard seen < panels.count, let parent = fragments.pane(id)?.origin?.parent,
                  let above = fragments.panel(holding: parent)
            else { return seen }
            return depth(above, seen: seen + 1)
        }
        return panels.sorted { depth($0) > depth($1) }
    }

    /// Whether closing `id` without a word would lose something: bytes its
    /// parent has not got back, or an edit to a part with nowhere to put it.
    /// Exactly the two cases closing a panel asks about.
    private func fragmentHasSomethingToLose(_ id: FragmentDock.PanelID) -> Bool {
        guard let pane = fragments.pane(id) else { return false }
        if let origin = pane.origin { return origin.hasChanges(in: pane) }
        return pane.status.isDirty
    }

    /// Asks about every panel holding something a close would lose, innermost
    /// first, and runs `done` once none is left. A cancelled question stops the
    /// run: `done` never fires, and everything still open stays open.
    ///
    /// The next panel is picked after each one goes rather than listed up
    /// front, because a panel put back into another hands that one bytes it did
    /// not have — and the panel that has just been handed them is then asked
    /// about them in its turn.
    ///
    /// Panels with nothing to lose are left where they are. They go with the
    /// window, and closing them here would throw them away for nothing if the
    /// question about the files is then cancelled.
    private func closeFragmentsHoldingSomething(then done: @escaping () -> Void) {
        guard let id = fragmentsInnermostFirst.first(where: fragmentHasSomethingToLose),
              let pane = fragments.pane(id)
        else {
            done()
            return
        }
        closeFragment(id, pane: pane) { [weak self] closed in
            guard closed else { return }
            self?.closeFragmentsHoldingSomething(then: done)
        }
    }

    private func confirmClosingUnreturnedPart(_ origin: DocumentOrigin) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Put “\(origin.partName)” back into \(origin.parentName)?"
        alert.informativeText = "It has changes \(origin.parentName) has not got. "
            + "Closing this panel without putting them back loses them."
        alert.addButton(withTitle: "Update in Parent")
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        if let fragmentCloseConfirm {
            return fragmentCloseConfirm(alert)
        }
        // Cancel in tests.
        return Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn)
    }

    /// Moves the keyboard to the panel that has just been raised, or back to
    /// the tab's own dump when the last one folds.
    ///
    /// Without this the dump behind a panel kept the first responder: every
    /// keystroke, every arrow, everything ⌘Z means went into the file the
    /// reader could not see (`Design/FRAGMENT_PANELS_PLAN.md`).
    func fragmentFocusChanged() {
        if let up = fragments.expanded, let pane = fragments.pane(up) {
            paneView(for: pane).focusHexView()
        } else {
            activeFilePane?.focusHexView()
        }
    }

    /// Whether the tab's own panes are taking orders. They are not while a
    /// fragment panel is in front of them: the panel covers them, and a command
    /// that rearranged or replaced something nobody can see is a command that
    /// looks like it did nothing.
    var windowPanesAreReachable: Bool { fragments.expanded == nil }

    /// What the reader is told about the parts that were taken out of a panel
    /// being closed.
    static func strandingSentence(_ count: Int) -> String {
        count == 1
            ? "One panel was opened out of it and will lose its way back. "
                + "Its bytes stay as they are; only the way back goes."
            : "\(count) panels were opened out of it and will lose their way back. "
                + "Their bytes stay as they are; only the way back goes."
    }

    /// What the button that goes ahead with it says. Not "Close": the button
    /// has to say what closing does that the reader would not have expected,
    /// and what it does is break the way back for something else.
    static func strandingCloseButton(_ count: Int) -> String {
        count == 1 ? "Close and Break Link" : "Close and Break Links"
    }

    /// Asked before a panel that other panels came out of is closed. Their link
    /// does not follow it anywhere: it simply stops leading somewhere, and
    /// Update in Parent stops being on offer for them.
    private func confirmStranding(_ count: Int, closing name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close “\(name)”?"
        alert.informativeText = Self.strandingSentence(count)
        alert.addButton(withTitle: Self.strandingCloseButton(count))
        alert.addButton(withTitle: "Cancel")
        if let fragmentCloseConfirm {
            return fragmentCloseConfirm(alert) == .alertFirstButtonReturn
        }
        // Cancel in tests.
        return Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)
            == .alertFirstButtonReturn
    }

    /// Puts the dock at the height it is about to have and lays the window out
    /// now, before a panel is placed or flown.
    ///
    /// The first panel of a tab is raised while the dock is still growing from
    /// nothing, so the stage it was measured against was a dock taller than the
    /// one it ended up on and the panel sat a dock's height too high. The dock
    /// arrives first, with its pill, and only then does the panel fly out of
    /// it — which is also the order the flight tells a story in.
    func settleFragmentDock() {
        guard let dockHeight = fragmentDockHeight else { return }
        let target: CGFloat = fragments.isEmpty ? 0 : FragmentDockStrip.height
        guard dockHeight.constant != target else { return }
        dockHeight.constant = target
        contentContainer.layoutSubtreeIfNeeded()
    }

    /// Gives the dock its height, or takes it away when the last panel closes.
    /// Called by the panels themselves, which know when that happens.
    func setFragmentDockVisible(_ visible: Bool) {
        guard let dockHeight = fragmentDockHeight else { return }
        let target: CGFloat = visible ? FragmentDockStrip.height : 0
        guard dockHeight.constant != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.12 : 0.10
            context.allowsImplicitAnimation = true
            dockHeight.animator().constant = target
            contentContainer.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Update in Parent

    /// File ▸ Update in Parent: the active tab's bytes go back where they were
    /// taken from (`Design/UEFI/UPDATE_IN_PARENT.md` §3).
    @objc func updateInParent() {
        performUpdateInParent(of: activePane)
    }

    /// The pane header's Update in Parent: the same, for that pane.
    @objc func updatePaneInParent(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        performUpdateInParent(of: pane)
    }

    /// Puts `pane`'s bytes back into the document they came out of, as one
    /// undo step there named after the tab. The parent becomes dirty; nothing
    /// is written to disk. What cannot be put back is said, and nothing moves.
    ///
    /// A part the image's structure is laid out again around — a decompressed
    /// body, a zone that is a volume, a file or a section — goes through the
    /// rebuild planner off the main actor (§6); the task is handed back for
    /// whoever has to wait on it.
    @discardableResult
    func performUpdateInParent(of pane: PaneViewModel) -> Task<Void, Never>? {
        guard let origin = pane.origin, origin.hasChanges(in: pane) else { return nil }
        let stepName = "Update from \(pane.status.fileName)"
        switch origin.planUpdate(from: pane) {
        case .refused(let title, let message):
            presentAlert(title: title, message: message)
            return nil

        case .overwrite(let offset, let bytes, let confirm):
            guard let parent = origin.parent else { return nil }
            if confirm, !confirmOverwritingChangedSource(of: origin) { return nil }
            if writeUpdate(bytes, at: offset, into: parent, for: origin, tabBytes: bytes,
                           sourceBytes: bytes, sourceRange: origin.sourceRange, named: stepName) {
                revealUpdateDestination(from: pane, to: parent)
            }
            return nil

        case .rebuild(let target, let bytes, let confirm):
            guard let parent = origin.parent, let document = parent.document,
                  let file = try? document.read(at: 0, length: Int(document.size))
            else { return nil }
            if confirm, !confirmOverwritingChangedSource(of: origin) { return nil }
            let generation = parent.contentGeneration
            let handle = UpdateHandle()
            let operation = beginUpdateOperation(in: parent, for: origin, handle: handle)
            let task = Task { [weak self] in
                // The parent's protected ranges, read by its tree: a change
                // inside the IBB is refused and one inside a range the
                // firmware checks is said (`UPDATE_IN_PARENT.md` §6.4).
                operation.rename("Reading the protected ranges of “\(origin.parentName)”")
                let protected = await self?.protectedRanges(of: parent)?.rebuildRanges
                let result = await Task.detached(priority: .userInitiated) {
                    UEFIRebuild.plan(bytes, at: target, in: file, protected: protected) { progress in
                        operation.rename(progress.phase)
                        operation.report(progress.fraction)
                    }
                }.value
                operation.finish()
                // Abandoned from the sheet: nothing was written, and nothing
                // will be.
                guard let self, !Task.isCancelled else { return }
                // Said on the parent's window — the tab the update landed in,
                // brought to the front for it — and as a sheet, so its panels
                // rebuild while the message is up.
                let sheetWindow = (Self.controller(holding: parent, among: self.openDocuments?.controllers ?? [])
                    ?? self).view.window
                switch result {
                case .failure(let refusal):
                    self.presentSheetAlert(title: "“\(origin.partName)” cannot be put back",
                                           message: refusal.message, on: sheetWindow)
                case .success(let plan):
                    // Worked out over the bytes as they were when asked.
                    guard parent.contentGeneration == generation, parent.document === document else {
                        self.presentSheetAlert(
                            title: "“\(origin.parentName)” changed",
                            message: "It changed while the update was being worked out. Nothing was written.",
                            on: sheetWindow
                        )
                        return
                    }
                    var rebuilt = file
                    rebuilt.replaceSubrange(Int(plan.offset)..<(Int(plan.offset) + plan.bytes.count),
                                            with: plan.bytes)
                    let source = Array(rebuilt[Int(plan.source.lowerBound)..<Int(plan.source.upperBound)])
                    guard self.writeUpdate(plan.bytes, at: plan.offset, into: parent, for: origin,
                                           tabBytes: bytes, sourceBytes: source,
                                           sourceRange: plan.source, named: stepName)
                    else { return }
                    self.revealUpdateDestination(from: pane, to: parent)
                    self.presentSheetAlert(
                        title: "Updated “\(origin.parentName)”",
                        message: plan.warnings.isEmpty
                            ? "Nothing was written inside a Boot Guard or vendor protected range."
                            : plan.warnings.joined(separator: "\n\n"),
                        on: sheetWindow
                    )
                }
            }
            handle.task = task
            return task
        }
    }

    /// The protected ranges of a pane's file, read by its shared tree — which
    /// is built for it when no panel has asked for one yet
    /// (`BOOT_GUARD_PROTECTED_RANGES.md` §9.2). Nil when there is no file.
    private func protectedRanges(of pane: PaneViewModel) async -> ProtectedRanges? {
        guard let storage = pane.document?.storage,
              let tree = pane.uefiState.tree(
                  makeSource: { LiveDocumentByteSource(storage: storage) },
                  layout: pane.origin?.layout ?? .image
              )
        else { return nil }
        await withCheckedContinuation { continuation in
            tree.resolveProtectedRanges { continuation.resume() }
        }
        return tree.protectedRanges
    }

    /// What the (×) of an update reaches the update through.
    private final class UpdateHandle {
        var task: Task<Void, Never>?
        weak var operation: BackgroundOperation?
    }

    /// Where an update is seen while it is worked out: the parent's tab comes
    /// to the front — the change lands there — and a sheet on its window says
    /// what is being done, how far it has got, with a Cancel that abandons it
    /// (`BlockingOperationSheet`). The sheet is modal to that window: the plan
    /// is worked out over the parent's bytes as they were when asked, and an
    /// edit made meanwhile would only be thrown away with it. Nothing is written
    /// until the plan is done, so abandoning costs nothing.
    private func beginUpdateOperation(
        in parent: PaneViewModel, for origin: DocumentOrigin, handle: UpdateHandle
    ) -> BackgroundOperation {
        let owner = Self.controller(holding: parent, among: openDocuments?.controllers ?? []) ?? self
        owner.view.window?.makeKeyAndOrderFront(nil)
        let operation = BackgroundOperation(
            name: "Getting ready"
        ) { [handle] in
            handle.task?.cancel()
            // The plan cannot be stopped halfway, but its result is thrown
            // away, so the sheet goes now rather than when it finishes.
            handle.operation?.finish()
        }
        handle.operation = operation
        BlockingOperationSheet.present(
            operation, title: "Updating “\(origin.parentName)” from “\(origin.partName)”", from: owner)
        return operation
    }

    /// Writes an update into the parent as one undo step, with the link moved
    /// on first — so the change notice the write posts finds the link intact
    /// and nothing left to put back — and moved back if the write fails.
    private func writeUpdate(
        _ bytes: [UInt8], at offset: UInt64, into parent: PaneViewModel, for origin: DocumentOrigin,
        tabBytes: [UInt8], sourceBytes: [UInt8], sourceRange: Range<UInt64>, named name: String
    ) -> Bool {
        let snapshot = origin.adopt(tabBytes: tabBytes, sourceBytes: sourceBytes, sourceRange: sourceRange)
        guard !bytes.isEmpty else { return true }
        do {
            try parent.applyToolWrites([(offset: offset, bytes: bytes)], named: name)
            return true
        } catch {
            origin.restore(snapshot)
            presentFileError("Could not update “\(origin.parentName)”.", error, url: parent.document?.url)
            return false
        }
    }

    /// The source changed in the parent after the tab was opened: overwriting
    /// those changes is the reader's call.
    private func confirmOverwritingChangedSource(of origin: DocumentOrigin) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(origin.partName)” has changed in \(origin.parentName)"
        alert.informativeText = "Its bytes there are no longer the ones this part was opened from. "
            + "Updating overwrites those changes with this part's bytes."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        if let updateConfirm {
            return updateConfirm(alert) == .alertFirstButtonReturn
        }
        // Cancel in tests.
        return Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)
            == .alertFirstButtonReturn
    }

    /// The Update in Parent items: named after the parent, enabled while there
    /// is something to put back into a parent that is still open.
    private func validateUpdateInParent(_ item: NSMenuItem, for pane: PaneViewModel?) -> Bool {
        guard let pane, let origin = pane.origin else {
            item.title = "Update in Parent"
            return false
        }
        item.title = "Update in “\(origin.parentName)”"
        return pane.isOpen && origin.state != .parentClosed && origin.hasChanges(in: pane)
    }

    /// What a tool-module's tab is a part of, for the link's tooltip: its name
    /// without the dump's stem in front and the extension behind —
    /// `bios_LZMA section.bin` from `bios.rom` is "LZMA section".
    static func partName(ofTab name: String, parent: String) -> String {
        var part = (name as NSString).deletingPathExtension
        let stem = (parent as NSString).deletingPathExtension + "_"
        if part.hasPrefix(stem), part.count > stem.count { part.removeFirst(stem.count) }
        return part
    }

    /// The link in a tab's header was clicked: the parent's window comes to the
    /// front with the source selected in its dump (`UPDATE_IN_PARENT.md` §2.2).
    /// Nothing happens once the parent is gone.
    ///
    /// A parent that is itself a fragment lives in this window's own dock — a
    /// nested panel and the panel it came out of share one — so it is raised
    /// here rather than hunted for as a window pane, which it is not.
    func revealOrigin(of pane: PaneViewModel) {
        guard let origin = pane.origin, origin.state != .parentClosed,
              let parent = origin.parent
        else { return }
        if let panel = fragments.panel(holding: parent) {
            fragments.expand(panel)
            revealForTool(origin.sourceRange, in: parent, select: true)
            return
        }
        guard let owner = Self.controller(holding: parent, among: openDocuments?.controllers ?? [])
        else { return }
        owner.view.window?.makeKeyAndOrderFront(nil)
        owner.revealForTool(origin.sourceRange, in: parent, select: true)
    }

    /// The window whose panes include `pane`: among the registry's windows, then
    /// among every window the app has — a window made outside the registry
    /// holds panes too.
    private static func controller(
        holding pane: PaneViewModel, among known: [MainViewController]
    ) -> MainViewController? {
        let windows = NSApp.windows.compactMap { $0.contentViewController as? MainViewController }
        return (known + windows).first {
            $0.windowModel.pane1 === pane || $0.windowModel.pane2 === pane
        }
    }

    /// Takes the dump to `range` for a tool-module — the same reveal a bookmark
    /// or a search result gets, in the pane the session is bound to rather than
    /// in the active one.
    func revealForTool(_ range: Range<UInt64>, in pane: PaneViewModel, select: Bool) {
        guard pane.isOpen else { return }
        if select, !range.isEmpty {
            pane.select(range: range)
        } else {
            pane.moveCaret(to: range.lowerBound)
        }
        filePaneView(for: pane)?.revealOffsetCentered(range.lowerBound)
    }

    /// Brings the start of the zone a tool-module has just focused into view:
    /// the scroll alone, and only when it is not on screen already.
    ///
    /// The caret and the selection are left where they are, deliberately.
    /// Picking a row in a tool-module's list is looking, not going — and the
    /// user may well be part-way through something in the dump. Going is the
    /// tool-module's own `reveal`, which centres and can select.
    func showZoneStartForTool(_ offset: UInt64, in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        filePaneView(for: pane)?.revealOffsetIfOffScreen(offset)
    }

    /// The published zone map changed — a publish, a focus moving, or a session
    /// ending and taking the map with it. The dump repaints from the pane's own
    /// hook (`PaneViewModel.onFullInvalidationOfZones`); the minimap's gutters
    /// are handed the map from here (§19.4.5).
    func toolZonesChanged(of surface: DocumentSurface?) {
        // The map that redraws is the one belonging to the surface whose
        // tool-module republished — a panel's zones are not the tab's.
        (surface ?? self.surface).minimap.syncZones()
    }

    /// The panel's header re-reads what it says about the file — called for
    /// anything that can change either half of it: a file opening, closing or
    /// being renamed, the two panes swapping places, a session starting,
    /// ending or being re-bound to another pane.
    ///
    /// Which pane is *active* is deliberately not on that list: the header
    /// names the file the session is bound to, and clicking the other pane does
    /// not take the session there.
    ///
    /// Free with no tool open (the header is a bare strip then), which is what
    /// lets the paths that cannot tell whether a panel happens to be up call it
    /// unconditionally.
    func refreshToolPanelHeader() {
        tools.refreshPanelHeader()
    }

    // MARK: - Minimap (§19)

    /// Toggles the right-hand minimap panel (the toolbar button). The panel is
    /// hidden by default and animated in/out; the split's divider keeps the
    /// user's chosen width between shows.
    @objc func toggleMinimap() {
        frontSurface.minimap.togglePanel(animated: true)
    }

    /// The surface the commands about "the minimap" mean: the fragment panel in
    /// front when one is up, the tab's otherwise. A panel covers the tab's own
    /// map, so the one the button toggles is always the one on screen.
    var frontSurface: DocumentSurface { fragments.frontSurface ?? surface }

    /// The window move that goes with showing or hiding the minimap: growing or
    /// shrinking by whatever the dump's own spare width cannot absorb, so the
    /// hex content area keeps the width its grid needs (§19). The window grows
    /// or shrinks from the right edge; the left edge stays put.
    ///
    /// Returns a function of progress rather than doing the move, so the panel's
    /// animation can drive it frame by frame on its own eased clock — a window
    /// that jumped to its new width while the panel glided in is what this
    /// replaces. Called with 1 it lands the window exactly where the instant
    /// version put it. Nil when there is no window to move.
    ///
    /// Every step is computed from the frame captured here rather than from the
    /// window's current one, so the on-screen clamp cannot accumulate across
    /// the steps.
    func minimapWindowResize(visible: Bool) -> ((CGFloat) -> Void)? {
        guard let window = view.window else { return nil }
        let width = minimapPreferredPanelWidth + panelSplit.dividerThickness
        let move = windowDelta(forPanel: visible ? width : -width,
                               borrowed: &borrowedByMinimap)
        guard move != 0 else { return nil }
        let start = window.frame
        let targetWidth = max(0, start.width + move)
        return { [weak window] progress in
            guard let window else { return }
            var frame = start
            frame.size.width = start.width + (targetWidth - start.width) * progress
            // Keep the window on the visible screen: when growing, the right
            // edge must not run off-screen; when shrinking, the left edge stays
            // put.
            if let visibleFrame = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX),
                                     visibleFrame.maxX - frame.size.width)
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// Makes pane `index` the active one: the window model, the active-pane
    /// pointer, the comparison view's chrome, and the focus all follow (§3.3).
    /// Driven by a header click and by a click on that pane's minimap.
    private func activatePane(at index: Int) {
        // The window model's pointer moves first, and the panel's header is
        // re-read beside it, at a point where the comparison view is not needed
        // — a pane can be activated while that view is down, a file opening
        // into the panes, say. Everything below needs the view; this does not.
        //
        // The header does not *follow* the activation — it names the file the
        // tool is bound to, which a click between panes does not change. It is
        // re-read here because a pane's file can have arrived by a route with
        // no hook of its own, and this is the moment the user has just turned
        // to the panes: the alternative is a menu that names the wrong file the
        // next time it is opened.
        windowModel.setActivePane(index)
        refreshToolPanelHeader()
        guard let comparisonView else { return }
        activeFilePane = index == 0 ? comparisonView.paneView1 : comparisonView.paneView2
        comparisonView.setActive(index)
        // Focus follows activation (e.g. a header click), so typing and the
        // active-pane pointer stay aligned (§3.3).
        activeFilePane?.focusHexView()
        // Navigation anchors on the active pane's caret — a pane switch can
        // change whether a next/previous block exists (§10.3).
        refreshDiffNavigation()
        // The count describes the active pane's search, and the search belongs
        // to the pane that was searched (§11).
        syncFindBarToActivePane()
        // The typing mode is per pane (§7.6), so the toolbar's toggle follows
        // the pane the keys now go to (§24.2).
        revalidateToolbar()
    }

    /// Makes pane `index` the active one, from the tests that need to drive a
    /// pane switch without a mouse — which is the only thing a click does that
    /// this does not.
    func activatePaneForTesting(_ index: Int) {
        activatePane(at: index)
    }

    // MARK: - Minimap overview (§19.4)



    /// The mode the file(s) now open call for: detail for a file small enough
    /// that it is the more informative view, overview for a dump detail could
    /// only ever show a sliver of (§19.4). Nothing is remembered — every open
    /// decides afresh, because the answer is a property of the file, not a
    /// preference; a toggle by the user holds only until the open files change.
    private func preferredMinimapMode() -> MinimapView.RenderMode {
        let size = [windowModel.pane1, windowModel.pane2]
            .compactMap { $0.isOpen ? $0.status.fileSize : nil }
            .max() ?? 0
        return size <= MinimapView.detailPreferredMaxSize ? .detail : .overview
    }

    /// Puts the minimap in the mode the current file calls for. Called whenever
    /// the open files change.
    private func applyPreferredMinimapMode() {
        surface.minimap.setRenderMode(preferredMinimapMode())
        surface.minimap.updateOverviewAvailability()
    }

    /// Puts the minimap in `mode`, the way the header switch does. Exposed
    /// (internal) so tests can exercise a mode directly.
    func setMinimapRenderModeForTesting(_ mode: MinimapView.RenderMode) {
        surface.minimap.setRenderMode(mode)
    }

    /// Toggles between the whole-file overview and the detail window. The choice
    /// holds until the open files change, which decides afresh (§19.4).
    @objc func toggleMinimapOverview() {
        guard surface.minimapView.renderMode == .overview || surface.minimapView.overviewIsInformative() else { return }
        surface.minimap.setRenderMode(surface.minimapView.renderMode == .overview ? .detail : .overview)
    }





    override func viewDidLayout() {
        super.viewDidLayout()
        surface.minimap.updateChrome()
        updateDropStripInsets()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The toolbar can only be reconfigured once it is up, which is not the
        // case while the window controller is still building (§10.3).
        syncDiffNavigationToolbarItem()
    }

    /// How many of `buffer[from..<to]` are neither 0x00 nor 0xFF — how "full"
    /// a cell's slice of the file is.
    ///
    /// The pass walks the whole file — every byte of a 16 MB dump, twice over for
    /// a comparison — so it counts eight bytes at a time instead of one, over a
    /// raw buffer. Through `Array`'s bounds-checked subscript, one byte at a
    /// time, this took 1.9 s per file in a debug build: the overview arrived
    /// seconds after it was asked for.
    nonisolated static func significantByteCount(
        _ buffer: UnsafeBufferPointer<UInt8>, from: Int, to: Int
    ) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        let word = 8
        var index = from
        var count = 0
        while index + word <= to {
            let bits = UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
            count += word - fillByteFlags(bits).nonzeroBitCount
            index += word
        }
        while index < to {
            if base[index] != 0x00, base[index] != 0xFF { count += 1 }
            index += 1
        }
        return count
    }

    /// One bit per byte of `word` that is a 0x00/0xFF fill — the byte's high bit,
    /// so `nonzeroBitCount` is the number of fill bytes in the word.
    ///
    /// `(b & 0x7F) + 0x7F` sets a byte's high bit exactly when `b` has any low bit
    /// set, and cannot carry into the next byte (0x7F + 0x7F = 0xFE); OR-ing `b`
    /// back in contributes its own high bit. So the high bit of each byte of that
    /// expression is set iff the byte is non-zero — inverted, iff it is 0x00. The
    /// same test on `~word` finds the 0xFF bytes, and no byte can be both.
    nonisolated private static func fillByteFlags(_ word: UInt64) -> UInt64 {
        let low: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        let high: UInt64 = 0x8080_8080_8080_8080
        let zeros = ~(((word & low) &+ low) | word) & high
        let inverted = ~word
        let ones = ~(((inverted & low) &+ low) | inverted) & high
        return zeros | ones
    }



    // MARK: - Minimap data (§19)







    // MARK: - The segment strip's legend (§19.4.4, §21.3)

    /// The pane a minimap map stands for, by map index — the strip's menu and
    /// hover both act through it. Nil in empty mode or for an index the mode
    /// does not use.
    /// The panes the tab's own map shows, which is what its mode says.
    private func windowPanesInMapOrder() -> [PaneViewModel] {
        switch mode {
        case .empty: return []
        case .singleFile: return [windowModel.pane1]
        case .comparison: return [windowModel.pane1, windowModel.pane2]
        }
    }

    /// The piece a strip-menu item acts on, carried in the item's
    /// `representedObject` — the way the offset menu carries its target.
    /// Internal so a test can verify the piece an item carries.
    final class SegmentMenuTarget: NSObject {
        let mapIndex: Int
        let pieceIndex: Int
        /// The pointer's own spot on the strip when the menu was opened, in the
        /// minimap's coordinates — the anchor the Edit popover points at, so it
        /// opens where the menu did rather than at the piece's whole block
        /// (§21.4).
        let point: NSPoint
        init(mapIndex: Int, pieceIndex: Int, point: NSPoint) {
            self.mapIndex = mapIndex
            self.pieceIndex = pieceIndex
            self.point = point
        }
    }

    /// The right-click menu the segment strip offers for a piece: what acts on
    /// the piece under the pointer (§21.3) — the form's row menu with the strip's
    /// own Select. Each item carries the piece it acts on in its
    /// `representedObject`, the way the offset menu carries its target.
    private func makeMinimapSegmentMenu(mapIndex: Int, pieceIndex: Int, point: NSPoint) -> NSMenu? {
        guard let pane = surface.mappedPane(at: mapIndex), pane.isOpen,
              pieceIndex < pane.segmentStore.segments.count else { return nil }
        let target = SegmentMenuTarget(mapIndex: mapIndex, pieceIndex: pieceIndex, point: point)
        // The piece's label names it in every item, so the menu says what it will
        // act on — "Select Segment S1", not a bare "Select Segment" (§21.3).
        let label = pane.segmentStore.segments[pieceIndex].label
        let menu = NSMenu()

        // Save Segment… writes one piece to a file (§21.5).
        let save = menu.addItem(withTitle: "Save Segment \(label)…",
                                action: #selector(minimapMenuSaveSegment(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = target

        // Replace Segment from File… reads one piece from a file (§21.6): the
        // donor-region swap, the inverse of Save Segment.
        let replace = menu.addItem(withTitle: "Replace Segment \(label) from File…",
                                   action: #selector(minimapMenuReplaceSegment(_:)), keyEquivalent: "")
        replace.target = self
        replace.representedObject = target

        menu.addItem(.separator())

        // Select Segment: the whole piece is selected — its full range, not a
        // caret at its start (§21.3).
        let select = menu.addItem(withTitle: "Select Segment \(label)",
                                  action: #selector(minimapMenuSelectSegment(_:)), keyEquivalent: "")
        select.target = self
        select.representedObject = target

        // Edit Segment: the popover that edits this piece — its offset and its
        // name — anchored where the menu opened, not the form with the table of
        // all segments (§21.4).
        let edit = menu.addItem(withTitle: "Edit Segment \(label)",
                                action: #selector(minimapMenuEditSegment(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = target

        // Merge: the piece's bytes merge into a neighbour that keeps its name
        // (§21.3) — the same act as the form's row menu. The title names both
        // the piece and the neighbour it merges into, so the menu says what it
        // will do without a second look.
        let remove = menu.addItem(withTitle: Segment.mergeTitle(for: pieceIndex),
                                  action: #selector(minimapMenuRemoveSegment(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = target
        return menu
    }

    // MARK: - The zone gutter's menu (§19.4.5)

    /// The zone a gutter-menu item acts on, carried in the item's
    /// `representedObject` — the way the strip's menu carries its piece.
    ///
    /// The *id* rather than the zone: a tool-module can republish between the
    /// menu opening and the item being picked, and the id is what survives that
    /// (a tool-module keeps its ids across a rebuild, `Zone.id`). The action
    /// looks the zone up again, so it acts on the file as it is now or on
    /// nothing at all.
    final class ZoneMenuTarget: NSObject {
        let mapIndex: Int
        let zoneID: Zone.ID
        init(mapIndex: Int, zoneID: Zone.ID) {
            self.mapIndex = mapIndex
            self.zoneID = zoneID
        }
    }

    /// The right-click menu the zone gutter offers for a bracket: what acts on
    /// the zone under the pointer (§19.4.5).
    ///
    /// The same two things the dump's own zone menu offers, because the reader
    /// asking from the gutter is asking about the same zone: select it, or take
    /// it out into a tab of its own. What is left of `Design/ZONES_IDEA.md` —
    /// replacing a zone from a file, and the rest — belongs to the tool-module
    /// that knows what the zone *is*, and wants a tool-module with something to
    /// say first (`Zone.kind`).
    private func makeMinimapZoneMenu(mapIndex: Int, zoneID: Zone.ID) -> NSMenu? {
        guard let pane = surface.mappedPane(at: mapIndex), pane.isOpen,
              let zone = pane.zones.zones.first(where: { $0.id == zoneID }) else { return nil }
        let menu = NSMenu()
        // The zone's name is in each title, so the menu says what it will act on
        // — the same rule the strip's items follow with their labels (§21.3). An
        // unnamed zone is named by where it starts, which is all there is.
        let named = zone.name.isEmpty
            ? "at \(zone.range.lowerBound.bareAddress)"
            : "“\(zone.name)”"

        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = ZoneMenuTarget(mapIndex: mapIndex, zoneID: zoneID)
            return item
        }
        _ = item("Select Zone \(named)", #selector(minimapMenuSelectZone(_:)))
        _ = item("Open Zone \(named)", #selector(minimapMenuOpenZone(_:)))
        return menu
    }

    /// Open Zone from the gutter's menu: the same act the dump's own menu
    /// performs, on the zone looked up again — a tool-module may have
    /// republished between the menu opening and the item being picked.
    @objc private func minimapMenuOpenZone(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ZoneMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex),
              let zone = pane.zones.zones.first(where: { $0.id == target.zoneID })
        else { return }
        openZone(zone, of: pane)
    }

    /// Select from the gutter's menu: the zone's whole range is selected and the
    /// tool-module that published it is told, which is the same pair of acts the
    /// dump's own zone menu performs (`selectZone`) — the bytes are the pane's
    /// to select, and what the zone *stands for* only the tool-module knows.
    @objc private func minimapMenuSelectZone(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ZoneMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex), pane.isOpen,
              let zone = pane.zones.zones.first(where: { $0.id == target.zoneID }) else { return }
        pane.select(range: zone.range)
        filePaneView(for: pane)?.revealOffsetCentered(zone.range.lowerBound)
        tools(reading: pane).zoneSelected(zone.id, in: pane)
    }

    /// Save Segment… from the strip's menu: the piece under the click, written to
    /// a file (§21.5) — the same act as the form's row menu.
    @objc private func minimapMenuSaveSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        // The Bool says whether the write actually started — the Segments form
        // reads it to decide whether to close itself (§21.5). A strip menu has
        // nothing to close, so it is deliberately dropped.
        _ = savePiece(pane.segmentStore.segments[target.pieceIndex], of: pane)
    }

    /// Replace Segment from File… from the strip's menu (§21.6): the piece under
    /// the click, its bytes replaced from a file — the same act as the form's row
    /// menu.
    @objc private func minimapMenuReplaceSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        // Dropped for the same reason as in `minimapMenuSaveSegment`.
        _ = replacePiece(pane.segmentStore.segments[target.pieceIndex], of: pane)
    }

    /// Select Segment from the strip's menu: the whole piece is selected — its
    /// full range, not a caret at its start (§21.3). The reveal puts the
    /// selection's start in view so the selection is seen to begin.
    @objc private func minimapMenuSelectSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        let piece = pane.segmentStore.segments[target.pieceIndex]
        pane.select(range: piece.range)
        filePaneView(for: pane)?.revealOffsetCentered(piece.range.lowerBound)
    }

    /// Edit… from the strip's menu: the popover that edits this piece — its
    /// offset (movable within the interval the cut bounds, locked to 0 for S0)
    /// and its name — anchored to the piece's own block on the strip (§21.4).
    /// Not the form with the table of all segments.
    @objc private func minimapMenuEditSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        let index = target.pieceIndex
        let segment = pane.segmentStore.segments[index]
        let store = pane.segmentStore
        let validate: (UInt64) -> Bool
        if index == 0 {
            // S0 has no cut to move: the offset is the file start, locked to 0,
            // so the editor renames the piece and nothing else.
            validate = { $0 == 0 }
        } else {
            // The cut at the piece's start bounds (the previous cut, the next cut
            // or the file's end); moving inside it keeps the partition whole
            // (§21.2). The current offset is legal, so the field opens not red.
            let lower = store.segments[index - 1].range.lowerBound
            let upper = index + 1 < store.segments.count
                ? store.segments[index + 1].range.lowerBound
                : store.contentSize
            validate = { offset in offset > lower && offset < upper }
        }
        let from = segment.range.lowerBound
        // The piece's label and range, above the two fields — "S1: 0001000-0600000"
        // — so the popover says what it is for before the offset is read (§21.4).
        let header = "\(segment.label): \(segment.range.lowerBound.bareAddress)-\(segment.range.lastByte.bareAddress)"
        let controller = CutEditPopoverController(
            prefillOffset: from, validate: validate,
            // The piece's current name, so editing a named piece opens with the
            // name to be changed rather than blank (§21.4).
            prefillDescription: segment.name,
            header: header,
            onCommit: { [weak pane] offset, name in
                guard let pane else { return }
                // Moving the cut and renaming the piece are one act: the piece
                // that opened at `from` is the one the description names, and its
                // name travels with the boundary (§21.2).
                if offset != from {
                    pane.segmentStore.moveCut(from: from, to: offset)
                }
                pane.segmentStore.rename(index, to: name)
            },
            onCancel: nil
        )
        // Anchor the popover at the pointer's own spot on the strip, so it opens
        // where the menu was opened — not at the piece's whole block (§21.4).
        // The point was captured when the menu was built and stored in the
        // target, so it is still here when the action fires.
        let anchor = NSRect(origin: target.point, size: .init(width: 0.1, height: 0.1))
        controller.show(relativeTo: anchor, of: surface.minimapView)
    }

    /// Merge from the strip's menu: the piece's bytes merge into a neighbour
    /// that keeps its name (§21.3) — the same act as the form's row menu, on
    /// the piece under the pointer.
    @objc private func minimapMenuRemoveSegment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SegmentMenuTarget,
              let pane = surface.mappedPane(at: target.mapIndex), pane.isOpen,
              target.pieceIndex < pane.segmentStore.segments.count else { return }
        pane.segmentStore.removePiece(at: target.pieceIndex)
    }

    // MARK: - Helpers

    /// The pane the commands that act on *what you are looking at* mean: the
    /// fragment panel in front when one is up, and the tab's own active pane
    /// otherwise (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// Editing, the caret and the selection, Find and Go To, the bookmarks, the
    /// segments, Save and Revert, Update in Parent: every one of them is about
    /// the document on screen, and with a panel up that is the panel's. ⌘Z into
    /// the dump behind a panel would undo an edit the reader cannot see.
    var activePane: PaneViewModel { fragments.frontPane ?? windowModel.activePane }

    /// The tab's own active pane, whatever is in front of it.
    ///
    /// The few commands that are about the tab's *panes* rather than about a
    /// document — joining a donor file into one, duplicating one into the pane
    /// beside it — mean this. A fragment panel has one pane and no pane beside
    /// it, so it is not what they are addressed to.
    private var windowActivePane: PaneViewModel { windowModel.activePane }

    private func focusActiveHexView() {
        activeFilePane?.focusHexView()
    }

    private func refreshMode() {
        let mode: WindowMode = windowModel.openPaneCount == 0 ? .empty : (windowModel.openPaneCount == 1 ? .singleFile : .comparison)
        // A drop that joins into the current pane (append / insert at start)
        // does not change the mode, and the join has already refreshed the pane
        // and centred the seam (§10.4, §22.5). Re-applying the same mode would
        // rebuild the pane from scratch, and the new pane's init follows the
        // caret to the top of the viewport, undoing the centring. Skip the
        // rebuild when the mode is unchanged: the operation that triggered this
        // has already updated the pane through its own channels.
        guard mode != self.mode else { return }
        apply(mode: mode)
    }

    // MARK: - File > Open (§4.1)

    @objc func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.openFiles(panel.urls)
        }
    }

    /// Opens the given URLs into panes. Internal so the app's open entry points
    /// share one pipeline: the Open panel, drops, and Launch Services
    /// "Open with" (AppDelegate.application(_:open:)) all land here.
    func openFiles(_ urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }

        // §4.1 rules 1–3, decided against the pre-open occupancy.
        let pane1WasOpen = windowModel.pane1.isOpen
        let pane2WasOpen = windowModel.pane2.isOpen
        let plan = OpenPlacement.plan(
            activePaneIndex: windowModel.activePaneIndex,
            pane1Open: pane1WasOpen,
            pane2Open: pane2WasOpen,
            fileCount: files.count
        )

        if let target = plan.firstFilePane {
            guard openIntoPane(index: target, url: first) else { return }
        }
        if plan.openSecond, files.count >= 2 {
            _ = openIntoPane(index: 1, url: files[1])
        }

        // Active pane follows the rule that decided placement.
        if !pane1WasOpen {
            windowModel.setActivePane(0)
        } else if !pane2WasOpen {
            windowModel.setActivePane(1)
        }

        if plan.ignoredCount > 0 {
            notifyIgnored(count: plan.ignoredCount)
        }
        refreshMode()
    }

    // MARK: - Drop handlers (§4.3)

    /// Empty-mode drop: first two files → panes 1/2, extras ignored (§4.3).
    private func handleEmptyDrop(_ urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: 0, url: first) else { return }
        if files.count >= 2 {
            _ = openIntoPane(index: 1, url: files[1])
        }
        windowModel.setActivePane(0)
        let ignored = max(0, files.count - 2)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Comparison-mode drop: first file → hovered pane; second file → other pane
    /// only if that pane is empty; extras (and an unplaceable second) ignored.
    private func handleComparisonDrop(targetPane: Int, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: targetPane, url: first) else { return }

        let otherIndex = 1 - targetPane
        let otherPane = otherIndex == 0 ? windowModel.pane1 : windowModel.pane2
        var ignored = max(0, files.count - 2)
        if files.count >= 2 {
            if otherPane.isOpen {
                ignored += 1  // the second file can't open — treated as ignored
            } else {
                _ = openIntoPane(index: otherIndex, url: files[1])
            }
        }
        windowModel.setActivePane(targetPane)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Comparison-mode drop onto one of a pane's three bands (§22.4): the
    /// replace band uses the existing comparison replace behaviour, and the two
    /// join bands join the first file into that pane (the rest ignored).
    /// Internal (not private) so a test can drive the routing directly.
    func handleComparisonBandDrop(targetPane: Int, target: SingleFileDropTarget, urls: [URL]) {
        switch target {
        case .replace, .addSecond:
            // The replace band (and the defensive addSecond — comparison mode
            // has no second-file target) use the existing replace behaviour.
            handleComparisonDrop(targetPane: targetPane, urls: urls)
        case .insertAtStart, .appendAtEnd:
            let files = openableFiles(from: urls)
            guard let first = files.first else { return }
            let pane = targetPane == 0 ? windowModel.pane1 : windowModel.pane2
            let position: JoinPosition = (target == .insertAtStart) ? .start : .end
            join(url: first, at: position, in: pane)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyJoinIgnored(count: ignored) }
            refreshMode()
        }
    }

    /// Single-file-mode drop onto one of the targets or bands (§4.3, §22.4).
    /// Internal (not private) so a test can drive the routing directly.
    func handleSingleFileDrop(target: SingleFileDropTarget, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        switch target {
        case .replace:
            // First replaces the current file; a second (if any) opens as pane 2.
            guard openIntoPane(index: 0, url: first) else { return }
            if files.count >= 2 {
                _ = openIntoPane(index: 1, url: files[1])
            }
            windowModel.setActivePane(0)
            let ignored = max(0, files.count - 2)
            if ignored > 0 { notifyIgnored(count: ignored) }
        case .addSecond:
            // First opens as pane 2; all additional files are ignored.
            guard openIntoPane(index: 1, url: first) else { return }
            windowModel.setActivePane(1)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyIgnored(count: ignored) }
        case .insertAtStart, .appendAtEnd:
            // First joins into the "this file" pane (pane 0 in single-file
            // mode); the rest are ignored — joining a list in one gesture is
            // deliberately not this (§22.4).
            let position: JoinPosition = (target == .insertAtStart) ? .start : .end
            join(url: first, at: position, in: windowModel.pane1)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyJoinIgnored(count: ignored) }
        }
        refreshMode()
    }

    private func openableFiles(from urls: [URL]) -> [URL] {
        let files = urls.filter(isOpenableFile)
        if files.count < urls.count {
            presentAlert(title: "Some files could not be opened",
                         message: "Directories and packages are not supported.")
        }
        return files
    }

    private func notifyIgnored(count: Int) {
        let noun = count == 1 ? "file was" : "files were"
        presentAlert(title: "Additional files ignored",
                     message: "\(count) \(noun) not opened because only two files can be compared at once.")
    }

    /// The join-band variant of the ignored-files notice (§22.4): a join takes
    /// one file, so the extras are not joined, not opened.
    private func notifyJoinIgnored(count: Int) {
        let noun = count == 1 ? "file was" : "files were"
        presentAlert(title: "Additional files ignored",
                     message: "\(count) \(noun) not joined because only one file can be joined at a time.")
    }

    /// Opens `url` into the pane at `index`, enforcing §4.1 rules 4–6 (dirty
    /// replacement confirmation, same-file reload, no same file in both panes).
    /// Returns false when the open was refused or failed.
    private func openIntoPane(index: Int, url: URL) -> Bool {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2

        // Rule 6: the same file is already open somewhere else.
        if let (holder, holdingPane) = documentLocation(of: url, excluding: index) {
            if holder === self {
                // The other pane of this window. There is nowhere to send the
                // user that they are not already looking at, so the refusal is
                // the whole answer.
                presentAlert(title: "File already open",
                             message: "“\(url.lastPathComponent)” is already open in the other pane and cannot be opened twice.")
            } else {
                // Another window or tab has it. "Cannot be opened twice" is true
                // but useless there — the file is on screen — and so is silently
                // jumping to it: the user asked to work on it *here*, and being
                // moved somewhere else without a word is its own surprise. Both
                // useful answers are offered instead.
                switch askAboutFileOpenElsewhere(named: url.lastPathComponent) {
                case .show:
                    holder.revealOpenFile(inPane: holdingPane)
                case .move:
                    return movePaneHere(from: holder, at: holdingPane, into: index,
                                        onSaved: { [weak self] in
                                            _ = self?.openIntoPane(index: index, url: url)
                                        })
                case .cancel:
                    break
                }
            }
            return false
        }

        // Rule 5: same file already open in the target pane → reload/no-op.
        if pane.isOpen, FileIdentity(url: url) == pane.document?.identity {
            if pane.status.isDirty {
                let response = confirmAlert(title: "Reload file?",
                                            message: "“\(url.lastPathComponent)” has unsaved changes. Reload and discard them?",
                                            confirmTitle: "Reload",
                                            destructive: true)
                guard response == .alertFirstButtonReturn else { return false }
            }
            do {
                // The same `open` every other route takes: the pane knows this
                // is the file it already holds and reloads it. The question
                // above is this route's own — asking is the controller's job,
                // doing is the pane's.
                try pane.open(url: url)
                return true
            } catch {
                presentError("Could not reload file.", error)
                return false
            }
        }

        // Rule 4: replacing a dirty pane requires confirmation. A dirty
        // untitled pane has no file yet, so Save As runs first and the open
        // re-continues once it completes.
        guard confirmReplaceDirtyPane(pane, onSaved: { [weak self] in
            _ = self?.openIntoPane(index: index, url: url)
        }) else { return false }

        do {
            try pane.open(url: url)
            SandboxBookmarkStore.shared.record(url)
            return true
        } catch {
            presentFileError("Could not open file.", error, url: url)
            return false
        }
    }

    /// §4.1 rule 4: replacing a dirty pane requires confirmation. Returns true
    /// when the replacement may proceed (the pane was saved or its changes were
    /// discarded). A dirty untitled pane cannot save inline — Save As runs as a
    /// sheet and `onSaved` is called when it completes, with false returned so
    /// the pending replacement re-runs via the callback.
    private func confirmReplaceDirtyPane(_ pane: PaneViewModel, onSaved: (() -> Void)? = nil) -> Bool {
        guard pane.isOpen, pane.status.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace unsaved changes?"
        alert.informativeText = "“\(pane.status.fileName)” has unsaved changes. Save and replace, or replace without saving?"
        alert.addButton(withTitle: "Save and Replace")
        alert.addButton(withTitle: "Replace Without Saving")
        alert.addButton(withTitle: "Cancel")
        switch Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn) {  // Cancel in tests
        case .alertFirstButtonReturn:  // Save and Replace
            if pane.isUntitled {
                presentSaveAs(for: pane, onSaved: onSaved)
                return false
            }
            do {
                try pane.save()
                return true
            } catch {
                presentError("Save failed.", error)
                return false
            }
        case .alertSecondButtonReturn:  // Replace Without Saving
            return true
        default:
            return false
        }
    }

    private func isOpenableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == false && values?.isPackage != true
    }

    // MARK: - File > Append File… / Insert File at Start… (§22)

    /// File > Append File…: joins the chosen file's bytes after the active
    /// pane's content (§22.1).
    @objc func appendFile() {
        joinFile(at: .end, in: windowActivePane)
    }

    /// File > Insert File at Start…: joins the chosen file's bytes before the
    /// active pane's content (§22.1).
    @objc func insertFileAtStart() {
        joinFile(at: .start, in: windowActivePane)
    }

    /// The pane-menu twins: the same join, acting on the pane the menu was built
    /// for (§22.1) rather than the active one.
    @objc func appendFileInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        joinFile(at: .end, in: pane)
    }

    @objc func insertFileAtStartInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        joinFile(at: .start, in: pane)
    }

    /// The join command, shared by the File-menu and pane-menu items (§22).
    /// Opens the one file, then joins it.
    private func joinFile(at position: JoinPosition, in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let verb = (position == .start) ? "Insert" : "Append"

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = verb
        panel.message = "Choose the file to \(position == .start ? "insert at the start of" : "append to") the pane's content."
        let url: URL?
        if let joinOpenPanel {
            url = joinOpenPanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        join(url: url, at: position, in: pane)
    }

    /// Joins the file at `url` into `pane`: the dirty-pane warning (Cancel and
    /// the operation's verb — §22.2), the join, and the transient status line.
    /// Shared by the menu commands (after the open panel) and the drop bands
    /// (§22.4), which already have the URL. An untitled dirty pane is joined
    /// without a warning: there is no saved state to diverge from.
    /// A file joined into the pane that already holds it doubles its content.
    ///
    /// Not refused: a join copies bytes, so none of the hazards §4.1 rule 6
    /// guards against apply — there is no second live document, no second
    /// watcher, and no piece table whose base moves underneath it. The result is
    /// one document that happens to be the dump twice, which is a thing someone
    /// could mean.
    ///
    /// But on a bench it is far more often a slip: the file was dragged onto the
    /// pane it is already open in. So it asks, and the default is to do nothing.
    private func confirmSelfJoin(url: URL, into pane: PaneViewModel, verb: String) -> Bool {
        guard let identity = pane.document?.identity, identity == FileIdentity(url: url) else {
            return true
        }
        return confirmJoinToItself(named: url.lastPathComponent, verb: verb)
    }

    /// The question itself, asked of a file dropped on the pane that already
    /// holds it and of a pane dropped on its own bands alike — it is the same
    /// act and deserves the same words.
    private func confirmJoinToItself(named name: String, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Join “\(name)” to itself?"
        alert.informativeText = "This doubles the content: the same bytes twice, one copy "
            + "after the other."
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        // Cancel in tests, and Cancel is where the Escape key lands.
        return Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)
            == .alertFirstButtonReturn
    }

    /// §22.2: a dirty pane is warned about before a join, with two buttons —
    /// Cancel and the operation's verb. An untitled dirty pane gets no alert:
    /// there is no saved state for the join to diverge from.
    private func confirmJoinWithUnsavedChanges(_ pane: PaneViewModel, verb: String) -> Bool {
        guard pane.status.isDirty, !pane.isUntitled else { return true }
        let alert = NSAlert()
        alert.messageText = "Join with unsaved changes?"
        alert.informativeText = "“\(pane.status.fileName)” has unsaved changes. They travel into the joined image; the file on disk keeps its saved bytes."
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        if let joinConfirm {
            return joinConfirm(alert) == .alertFirstButtonReturn
        }
        // Cancel in tests.
        return Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)
            == .alertFirstButtonReturn
    }

    private func join(url: URL, at position: JoinPosition, in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let verb = (position == .start) ? "Insert" : "Append"

        // Asked before anything else, because it is the question of whether the
        // join was meant at all; the unsaved-changes prompt below is about the
        // consequences of one already decided on.
        guard confirmSelfJoin(url: url, into: pane, verb: verb) else { return }
        guard confirmJoinWithUnsavedChanges(pane, verb: verb) else { return }

        // The name the pane's content carries now, remembered before the join
        // detaches the document — the status line names both sources (§22.2).
        let originalName = pane.status.fileName
        // What the detached image will be called (§22.2). Derived here, where
        // the names in use across the app can be seen, and only for a pane that
        // still has a file: one that is already untitled keeps its name.
        let joinedName = pane.isUntitled ? nil : unsavedName(for: pane)

        do {
            try pane.join(contentsOf: url, at: position, becoming: joinedName)
        } catch let error as JoinError {
            switch error {
            case .emptySource:
                presentAlert(title: "File is empty",
                             message: "“\(url.lastPathComponent)” has no bytes to join.")
            }
            return
        } catch {
            presentFileError("Could not join file.", error, url: url)
            return
        }

        // The seam (the caret, at the start of the added part) is centred in the
        // pane by the join's own `notify(centerCaret: true)` (§10.4, §22.5).

        // §22.2: the transient status line names both sources and the total
        // size, the way the app reports a search result, then yields back.
        let total = pane.fileSize
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        activateJoinedPane(pane)

        let message = (position == .start)
            ? "Inserted \(url.lastPathComponent) before \(originalName). Total: \(size)."
            : "Appended \(url.lastPathComponent) after \(originalName). Total: \(size)."
        filePaneView(for: pane)?.showTransientMessage(message)
    }

    /// Makes the pane that just received a join the active one.
    ///
    /// The join leaves the caret at its seam and centres it there (§22.5), so
    /// the eyes have already been sent to this pane; leaving the keys pointed at
    /// the other one splits the two. A no-op outside comparison mode, where
    /// there is only one pane to be active.
    private func activateJoinedPane(_ pane: PaneViewModel) {
        activatePane(at: paneIndex(pane))
    }

    /// Joins one open pane's bytes into another, at one end or the other — the
    /// same operation `join(url:at:in:)` performs, sourced from a pane instead
    /// of a file (`Design/PANE_DRAG_PLAN.md`).
    ///
    /// The source pane is left exactly as it was. A join **copies**: dropping a
    /// file to append it does not consume the file, and dropping a pane does not
    /// consume the pane. Its unsaved edits travel, because the bytes are read
    /// from the pane's live storage rather than from the disk underneath it.
    private func join(pane source: PaneViewModel, at position: JoinPosition,
                      into pane: PaneViewModel) {
        guard pane.isOpen, source.isOpen,
              let sourceStorage = source.byteStorage else { return }
        let verb = (position == .start) ? "Insert" : "Append"
        // A pane joined to itself is allowed, and asked about: the document
        // streams from its own storage, which `BinaryDocument.join` handles by
        // taking the source's size once and following the bytes as an insert at
        // the start moves them.
        if source === pane {
            guard confirmJoinToItself(named: pane.status.fileName, verb: verb) else { return }
        }
        guard confirmJoinWithUnsavedChanges(pane, verb: verb) else { return }

        let originalName = pane.status.fileName
        let sourceName = source.status.fileName
        // The detached image's name, for the reason the file join gives.
        let joinedName = pane.isUntitled ? nil : unsavedName(for: pane)
        do {
            try pane.join(contentsOf: sourceStorage, named: sourceName,
                          at: position, becoming: joinedName)
        } catch let error as JoinError {
            switch error {
            case .emptySource:
                presentAlert(title: "Pane is empty",
                             message: "“\(sourceName)” has no bytes to join.")
            }
            return
        } catch {
            presentError("Could not join the pane.", error)
            return
        }

        activateJoinedPane(pane)

        let size = ByteCountFormatter.string(fromByteCount: Int64(pane.fileSize), countStyle: .file)
        let message = (position == .start)
            ? "Inserted \(sourceName) before \(originalName). Total: \(size)."
            : "Appended \(sourceName) after \(originalName). Total: \(size)."
        filePaneView(for: pane)?.showTransientMessage(message)
    }

    // MARK: - File > Duplicate (§23)

    /// File ▸ Duplicate: the active pane's content is copied into the free pane
    /// as an untitled, never-saved document (§23). Single-file mode only — the
    /// copy needs a pane to land in.
    @objc func duplicateDocument() {
        duplicate(from: windowActivePane)
    }

    /// Rename from the pane's header menu (§23): the title turns into a field in
    /// the header, so the name is typed where it is read rather than in a sheet
    /// raised to hold one short string.
    ///
    /// Only an unsaved document has a name to change this way — the item is
    /// disabled otherwise — and the pane view owns the editing, since the field
    /// belongs to the header it stands in.
    @objc func renamePaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender), pane.canRename else { return }
        filePaneView(for: pane)?.beginRenaming()
    }

    /// The pane-menu twin: duplicates the pane the menu was built for rather
    /// than the active one (§23). In single-file mode they are the same pane;
    /// the item exists so the header carries every file-scoped command.
    @objc func duplicatePaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        duplicate(from: pane)
    }

    /// The duplicate command (§23), shared by the File-menu and pane-menu items.
    ///
    /// The copy lands in the other pane and becomes active — it is what the user
    /// just made, and it is the side they are about to edit — so the window
    /// switches to comparison mode with the copy on the right. No confirmation:
    /// nothing is replaced (the target pane is empty by the time this runs) and
    /// the source is not touched.
    func duplicate(from source: PaneViewModel) {
        guard canDuplicate(source) else { return }
        let targetIndex = paneIndex(source) == 0 ? 1 : 0
        let target = targetIndex == 0 ? windowModel.pane1 : windowModel.pane2
        // The name the source carries now, so the line below can name both ends
        // of the copy (§23).
        let sourceName = source.status.fileName

        do {
            try target.openDuplicate(of: source, named: unsavedName(for: source))
        } catch {
            presentFileError("Could not duplicate the file.", error, url: nil)
            return
        }

        windowModel.setActivePane(targetIndex)
        refreshMode()

        // §23: the transient line names the source and the size, the way a join
        // reports its result (§22.2), then yields the stats back. Set after the
        // mode apply, which rebuilds the pane views.
        let size = ByteCountFormatter.string(fromByteCount: Int64(target.fileSize), countStyle: .file)
        filePaneView(for: target)?.showTransientMessage(
            "Duplicated \(sourceName) as \(target.status.fileName). Size: \(size).")
    }

    /// Whether Duplicate can act on `pane` (§23): the copy needs a free pane to
    /// land in, so exactly one pane may be open, and an empty pane has nothing to
    /// copy.
    private func canDuplicate(_ pane: PaneViewModel) -> Bool {
        windowModel.openPaneCount == 1 && pane.isOpen && pane.fileSize > 0
    }

    // MARK: - File > New File

    /// File > New File (Cmd+N): opens a brand-new, empty document in memory into
    /// a pane, using the same placement rules as Open (§4.1) — an empty pane
    /// first, otherwise the active pane, with the standard dirty-replacement
    /// confirmation. Nothing is written to disk until the first Save / Save As;
    /// the pane header shows "Untitled" with a plus-badge glyph until then.
    @objc func newDocument() {
        newUntitledDocument()
    }

    /// Creates an untitled in-memory document and places it into a pane
    /// following the Open placement rules (§4.1). Split from `newDocument()` so
    /// tests can drive the whole flow without the menu.
    func newUntitledDocument() {
        let pane1WasOpen = windowModel.pane1.isOpen
        let pane2WasOpen = windowModel.pane2.isOpen
        let plan = OpenPlacement.plan(
            activePaneIndex: windowModel.activePaneIndex,
            pane1Open: pane1WasOpen,
            pane2Open: pane2WasOpen,
            fileCount: 1
        )
        guard let target = plan.firstFilePane else { return }
        guard newUntitledIntoPane(index: target) else { return }

        // Active pane follows the rule that decided placement.
        if !pane1WasOpen {
            windowModel.setActivePane(0)
        } else if !pane2WasOpen {
            windowModel.setActivePane(1)
        }
        refreshMode()
    }

    /// Opens an untitled document into the pane at `index`, applying §4.1 rule 4
    /// (dirty-replacement confirmation). Returns false when refused.
    private func newUntitledIntoPane(index: Int) -> Bool {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        guard confirmReplaceDirtyPane(pane, onSaved: { [weak self] in
            _ = self?.newUntitledIntoPane(index: index)
        }) else { return false }
        pane.openUntitled()
        return true
    }

    // MARK: - Save / Save As / Revert (§5)

    @objc func saveDocument() {
        saveDocumentOfPane(activePane)
    }

    /// Saves the pane that owns the menu item — the header context menu's Save
    /// routes here so it always targets its own pane, never the active one
    /// (§4/§5). Both the menu bar and the context menu share
    /// `saveDocumentOfPane(_:)`.
    @objc func savePaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        saveDocumentOfPane(pane)
    }

    private func saveDocumentOfPane(_ pane: PaneViewModel) {
        guard pane.isOpen else { return }
        // An untitled document has no file to save to — Cmd+S is a Save As.
        if pane.isUntitled {
            presentSaveAs(for: pane)
            return
        }
        do {
            try pane.save()
        } catch DocumentError.fileIsReadOnly {
            presentSaveAs(for: pane)  // §5.4: read-only file auto-redirects to Save As
        } catch {
            presentFileError("Save failed.", error, url: pane.document?.url)
        }
    }

    @objc func saveDocumentAs() {
        presentSaveAs(for: activePane)
    }

    @objc func savePaneDocumentAs(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        presentSaveAs(for: pane)
    }

    /// Runs a Save As sheet for the given pane (active pane, or a specific pane
    /// from an external-change conflict or a deferred untitled save, §5.5).
    /// `onSaved` fires after a successful save — it continues a flow that had
    /// to wait for the untitled document to get a location.
    ///
    /// `onCancelled` fires where nothing was written: the sheet was backed out
    /// of, or the write failed and has been reported. A flow that only wants to
    /// carry on after a save leaves it out; one that has to *answer* either way
    /// — closing, quitting — passes it, and must, or it waits for ever.
    private func presentSaveAs(for pane: PaneViewModel, onSaved: (() -> Void)? = nil,
                               onCancelled: (() -> Void)? = nil) {
        guard pane.isOpen else {
            onCancelled?()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pane.status.fileName
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                onCancelled?()
                return
            }
            do {
                try pane.saveAs(to: url)
                SandboxBookmarkStore.shared.record(url)
                onSaved?()
            } catch {
                self.presentFileError("Save As failed.", error, url: url)
                onCancelled?()
            }
        }
    }

    /// Saves `pane` to disk, routing untitled documents (which have no file
    /// yet) through a Save As sheet. Returns true when the save happened inline
    /// (and `onSaved` has run); false when it is deferred to a sheet (the
    /// completion will call `onSaved`) or failed (error already shown).
    @discardableResult
    private func savePane(_ pane: PaneViewModel, onSaved: @escaping () -> Void,
                          onCancelled: (() -> Void)? = nil) -> Bool {
        if pane.isUntitled {
            presentSaveAs(for: pane, onSaved: onSaved, onCancelled: onCancelled)
            return false
        }
        do {
            try pane.save()
            onSaved()
            return true
        } catch {
            presentFileError("Save failed.", error, url: pane.document?.url)
            onCancelled?()
            return false
        }
    }

    /// Saves `panes` one at a time; each untitled pane goes through its own Save
    /// As sheet, then the next saves, then `then` runs. Stops on the first
    /// failure or backed-out sheet (the error has already been shown), which is
    /// what `onCancelled` is told about.
    private func saveAllThen(_ panes: [PaneViewModel], then: @escaping () -> Void,
                             onCancelled: (() -> Void)? = nil) {
        guard let first = panes.first else { then(); return }
        savePane(first, onSaved: { [weak self] in
            self?.saveAllThen(Array(panes.dropFirst()), then: then, onCancelled: onCancelled)
        }, onCancelled: onCancelled)
    }

    @objc func revertDocument() {
        revertDocumentOfPane(activePane)
    }

    /// Reverts the pane that owns the menu item — the header context menu's
    /// Revert routes here so it always targets its own pane (§4/§5). Both the
    /// menu bar and the context menu share `revertDocumentOfPane(_:)`.
    @objc func revertPaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        revertDocumentOfPane(pane)
    }

    private func revertDocumentOfPane(_ pane: PaneViewModel) {
        if pane.canRevertToOriginal {
            revertToOriginal(pane)
            return
        }
        guard pane.isOpen, !pane.isUntitled else { return }  // nothing on disk to revert to
        if pane.status.isDirty {
            let response = confirmAlert(
                title: "Revert to saved version?",
                message: "All unsaved changes will be discarded.",
                confirmTitle: "Revert",
                destructive: true
            )
            guard response == .alertFirstButtonReturn else { return }
        }
        do {
            try pane.revert()
        } catch {
            presentFileError("Revert failed.", error, url: pane.document?.url)
        }
    }

    /// Revert to Original: what Revert to Saved is in a tab opened from a part
    /// of another document, which has no file but has the bytes it was opened
    /// with.
    private func revertToOriginal(_ pane: PaneViewModel) {
        guard let origin = pane.origin else { return }
        if pane.status.isDirty {
            let response = confirmAlert(
                title: "Revert to the original bytes?",
                message: "Every change made since “\(origin.partName)” was opened from \(origin.parentName) will be discarded.",
                confirmTitle: "Revert",
                destructive: true
            )
            guard response == .alertFirstButtonReturn else { return }
        }
        pane.revertToOriginal()
    }

    /// Revert to Saved for a file, Revert to Original for a part of another
    /// document — one item, titled for the pane it acts on.
    private func validateRevert(_ item: NSMenuItem, for pane: PaneViewModel?) -> Bool {
        guard let pane else { return false }
        if pane.canRevertToOriginal {
            item.title = "Revert to Original"
            return true
        }
        item.title = "Revert to Saved"
        // Nothing on disk to revert an untitled document to.
        return pane.isOpen && !pane.isUntitled
    }

    /// Reveals the right-clicked pane's file in the Finder (header context
    /// menu). Resolves the pane the menu item was built for — so it shows the
    /// file even when another pane is active — and needs a real file on disk:
    /// an empty pane has nothing, and an untitled document has no URL to reveal.
    @objc func showPaneInFinder(_ sender: Any?) {
        guard let pane = pane(from: sender),
              pane.isOpen,
              !pane.isUntitled,
              let url = pane.document?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The on-disk URL behind the pane a header context-menu item was built for,
    /// when there is one to copy. Empty panes have nothing, and an untitled
    /// document's only URL is a placeholder with no file behind it — both need
    /// the menu item to stay disabled (validation), so nil here is unreachable
    /// for an enabled item and merely makes the action a no-op.
    private func copyableURL(from sender: Any?) -> URL? {
        guard let pane = pane(from: sender), pane.isOpen, !pane.isUntitled else { return nil }
        return pane.document?.url
    }

    /// Header context menu > Copy File Name: copies just the right-clicked
    /// pane's file name ("bios.bin", no directory) to the clipboard. Resolves
    /// the pane the item was built for, so it copies that pane's file even when
    /// another pane is active.
    @objc func copyPaneFileName(_ sender: Any?) {
        guard let url = copyableURL(from: sender) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.lastPathComponent, forType: .string)
    }

    /// Header context menu > Copy Full Path: copies the right-clicked pane's
    /// file's full POSIX path ("/Users/…/bios.bin") to the clipboard. Like Copy
    /// File Name it resolves the item's own pane, never the active pane.
    @objc func copyPaneFullPath(_ sender: Any?) {
        guard let url = copyableURL(from: sender) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    // MARK: - External change detection (§5.5)

    /// Wires each pane's watcher to the conflict prompt. Closures capture the
    /// specific pane objects, not indices, because closing pane 1 swaps the
    /// pane1/pane2 objects in WindowViewModel.
    private func wireExternalChangeDetection() {
        let pane1 = windowModel.pane1
        let pane2 = windowModel.pane2
        // Capture the pane objects weakly: the closures live on the panes, so a
        // strong capture would be a retain cycle. Weak keeps them equal-lifetime.
        pane1.onExternalChange = { [weak self, weak pane1] in
            guard let pane1 else { return }
            self?.presentExternalChange(for: pane1)
        }
        pane2.onExternalChange = { [weak self, weak pane2] in
            guard let pane2 else { return }
            self?.presentExternalChange(for: pane2)
        }
    }

    /// Prompt for a file that changed on disk (§5.5): reload/keep when clean;
    /// reload-and-discard / keep / save-as when dirty. In test mode the prompt
    /// resolves to "keep" (never reload) so a stray watcher event cannot mutate
    /// a pane mid-test. Exposed (internal) so tests can pin that contract.
    func presentExternalChange(for pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let name = pane.status.fileName
        if pane.status.isDirty {
            let alert = NSAlert()
            alert.messageText = "File changed on disk"
            alert.informativeText = "“\(name)” has been changed by another program and has unsaved local changes."
            alert.addButton(withTitle: "Reload and Discard Changes")
            alert.addButton(withTitle: "Keep Local Changes")
            alert.addButton(withTitle: "Save As…")
            switch Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn) {  // Keep Local Changes in tests
            case .alertFirstButtonReturn:
                do {
                    try pane.revert()
                } catch {
                    presentFileError("Reload failed.", error, url: pane.document?.url)
                }
            case .alertThirdButtonReturn:
                presentSaveAs(for: pane)
            default:
                break  // keep local changes
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "File changed on disk"
            alert.informativeText = "“\(name)” has been changed by another program. Reload to see the latest version?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Current Contents")
            if Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn) == .alertFirstButtonReturn {  // Keep in tests
                do {
                    try pane.revert()
                } catch {
                    presentFileError("Reload failed.", error, url: pane.document?.url)
                }
            }
        }
    }

    // MARK: - Pane / window closing (§3.5/3.6)

    /// File > Close (Cmd+W, "close document"): the active pane is the
    /// document, so it closes — in comparison mode this returns to single-file
    /// mode (with pane 2 promoted when pane 1 closes); closing the last pane
    /// returns to empty mode. With no panes open there is nothing to close, so
    /// the window closes instead.
    @objc func closeDocument() {
        // A panel in front is the document in front, so ⌘W closes that first —
        // the same step-at-a-time rule the panes and the tab already follow
        // (`Design/FRAGMENT_PANELS_PLAN.md`).
        if let up = fragments.expanded {
            closeFragment(up)
            return
        }
        guard windowModel.hasOpenFile else {
            view.window?.performClose(nil)
            return
        }
        closePane(at: windowModel.activePaneIndex)
    }

    /// File ▸ Close Window (⇧⌘W): this window and every tab in it.
    ///
    /// ⌘W is the step-at-a-time version — the active pane, then the tab once no
    /// pane is left, then the window once no tab is — which needed no change for
    /// tabs: closing a window that is a tab closes that tab, and closing the last
    /// tab closes the window. This is the one gesture that skips to the end.
    ///
    /// Each tab is asked to close in the ordinary way, so each still puts up its
    /// own unsaved-changes prompt; a tab whose prompt is cancelled stays, and the
    /// window stays with it.
    @objc func closeWindow(_ sender: Any?) {
        guard let window = view.window else { return }
        for tab in window.tabGroup?.windows ?? [window] {
            tab.performClose(nil)
        }
    }

    /// Closes the pane at `index` after the standard dirty prompt. An untitled
    /// pane's "Save" picks a location first (Save As sheet); the pane closes
    /// once that completes.
    func closePane(at index: Int) {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        guard pane.isOpen else { return }
        // Parts opened out of this pane lose their way back when its document
        // goes, exactly as they do when a panel they came out of closes — so
        // the same question is asked here, and asked first, before the one
        // about this pane's own bytes.
        let stranded = fragments.panelsLinked(to: pane).count
        if stranded > 0, !confirmStranding(stranded, closing: pane.status.fileName) { return }
        if pane.status.isDirty {
            switch confirmSaveDiscardCancel() {
            case .alertFirstButtonReturn:  // Save
                savePane(pane, onSaved: { [weak self] in
                    self?.performClosePane(at: index)
                })
                return  // closes now or after the Save As sheet
            case .alertSecondButtonReturn:  // Don't Save
                break
            default:  // Cancel
                return
            }
        }
        performClosePane(at: index)
        // A closed pane keeps its entry in the selector but is disabled, and
        // with one file left there is nowhere to move the tool, so the whole
        // header is re-read — whether the session ended with the file that
        // closed or is still reading the one beside it.
        refreshToolPanelHeader()
    }

    /// Performs the pane close after the dirty prompt succeeded.
    private func performClosePane(at index: Int) {
        // Before the model forgets which pane this was: a session bound to it
        // has nothing left to read (Design/TOOL_MODULES_PLAN.md).
        tools.paneClosed(index == 0 ? windowModel.pane1 : windowModel.pane2)
        windowModel.closePane(index)
        refreshMode()
        if mode == .singleFile {
            activeFilePane?.focusHexView()
        }
    }

    // MARK: - Pane header context menu (§4/§5)

    /// Builds the right-click menu for a pane's header. It carries the same
    /// items as the menu bar's File submenu (plus the header-only Copy File
    /// Name / Copy Full Path and Show in Finder), and every item's action
    /// resolves the pane captured here (via `representedObject`) — so New,
    /// Open, Save and Close always act on the header that was right-clicked,
    /// even when another pane is active or only one pane is open. A final
    /// separate block holds Swap Panels, which is mode-scoped (comparison only)
    /// and so carries no `representedObject`.
    func makePaneMenu(for pane: PaneViewModel) -> NSMenu {
        let menu = NSMenu(title: "File")
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.representedObject = pane
        }
        add("New File", #selector(newDocumentInPane(_:)), "n")
        add("Open…", #selector(openInPane(_:)), "o")
        menu.addItem(.separator())
        add("Save", #selector(savePaneDocument(_:)), "s")
        add("Save As…", #selector(savePaneDocumentAs(_:)), "S")
        // Rename (§23) sits with the two Saves because it is the third thing
        // that decides what this document is called — and the only one of them
        // that writes nothing. Enabled for an unsaved document alone; a file's
        // name is its file's.
        add("Rename", #selector(renamePaneDocument(_:)), "")
        add("Revert to Saved", #selector(revertPaneDocument(_:)), "")
        // Update in Parent (`Design/UEFI/UPDATE_IN_PARENT.md` §3): with the
        // Saves, for a tab opened from a part of another document.
        add("Update in Parent", #selector(updatePaneInParent(_:)), "")
        menu.addItem(.separator())
        // The join twins (§22.1): beside the file-scoped commands, acting on
        // THIS pane (the menu's representedObject) rather than the active one.
        // Insert (at the start) is grouped with the edit commands above;
        // Append (at the end) sits in its own block — the menu bar's File
        // submenu's order, mirrored here.
        add("Insert File at Start…", #selector(insertFileAtStartInPane(_:)), "")
        add("Append File…", #selector(appendFileInPane(_:)), "")
        menu.addItem(.separator())
        // Duplicate (§23): the other direction from the joins — this pane's
        // content goes out into the free pane, rather than a file coming in. Its
        // own block, because it is the only item here that is about the window's
        // second pane.
        add("Duplicate", #selector(duplicatePaneDocument(_:)), "")
        // Open in New Tab: the same subject as Duplicate — where this document
        // lives — pointing the other way. Duplicate sends a copy into the free
        // pane; this sends the document itself out to a tab of its own, leaving
        // the comparison behind as a single file (`Design/TABS_PLAN.md`).
        add("Open in New Tab", #selector(openPaneInNewTab(_:)), "")
        menu.addItem(.separator())
        // Copy File Name / Copy Full Path are header-only, like Show in Finder
        // below: they put THIS pane's file's name (or its whole path) on the
        // clipboard, which is a per-pane act, so the menu bar's File submenu
        // (active-pane) doesn't duplicate them. They need a real file to copy —
        // nothing for an empty pane, no name or path for an untitled document —
        // so validation disables them there, the same rule as Show in Finder.
        add("Copy File Name", #selector(copyPaneFileName(_:)), "")
        add("Copy Full Path", #selector(copyPaneFullPath(_:)), "")
        menu.addItem(.separator())
        // Show in Finder is header-only: it reveals THIS pane's file in the
        // Finder, which is a per-pane act, so the menu bar's File submenu
        // (active-pane) doesn't duplicate it. It keeps its own block between
        // the two join commands.
        add("Show in Finder", #selector(showPaneInFinder(_:)), "")
        add("Close", #selector(closePaneDocument(_:)), "w")
        // Swap Panels is a comparison-mode command, not a per-pane File action,
        // so it gets its own block and targets `swapPanes` directly.
        menu.addItem(.separator())
        let swapItem = menu.addItem(withTitle: "Swap Panels",
                                    action: #selector(swapPanes),
                                    keyEquivalent: "")
        swapItem.target = self
        return menu
    }

    /// Builds the context menu for a right-clicked address in the Offset column:
    /// "Copy offset" (copies the hex offset to the clipboard), then "Select Block
    /// from Here at «address»", both resolving THIS pane (the header-menu pattern of
    /// §4/§5) and the clicked offset (§10.2). When the clicked byte lies inside
    /// the pane's current selection, the menu instead leads with selection-scoped
    /// actions — Copy, Fill Selection with…, Delete Bytes — that act on the
    /// right-clicked pane's selection, never the active pane's (§10.2).
    func makeOffsetMenu(for pane: PaneViewModel, offset: UInt64) -> NSMenu {
        let menu = NSMenu(title: "Offset")
        let selection = pane.hexSelection()
        if !selection.isEmpty, offset >= selection.start, offset < selection.end {
            addSelectionMenuItems(to: menu, for: pane, offset: offset)
            menu.addItem(.separator())
        }
        let copy = menu.addItem(withTitle: "Copy offset",
                                action: #selector(copyOffset(_:)),
                                keyEquivalent: "")
        copy.target = self
        copy.representedObject = OffsetContextTarget(pane: pane, offset: offset)
        menu.addItem(.separator())
        let select = menu.addItem(withTitle: "Select Block from Here at \(offset.bareAddress)",
                                  action: #selector(selectBlockFromHere(_:)),
                                  keyEquivalent: "")
        select.target = self
        select.representedObject = OffsetContextTarget(pane: pane, offset: offset)
        addZoneMenuItems(to: menu, for: pane, offset: offset)
        // The segment block (§21.3): the commands that shape the file's
        // partition, set off from the address-scoped commands above and the
        // bookmark commands below by their own separators.
        menu.addItem(.separator())
        addSegmentMenuItems(to: menu, for: pane, offset: offset)
        menu.addItem(.separator())
        addBookmarkMenuItems(to: menu, for: pane, offset: offset)
        return menu
    }

    /// The status bar's right-click menu on a pane's file size: copying the
    /// half of the size that was clicked on, in that half's own format.
    ///
    /// The bar abbreviates ("2 MB"), which is what a glance wants and not what
    /// a clipboard wants — an offset, a tool panel's address, or a size typed
    /// into another tool has to be exact. So putting the pointer on the size
    /// turns the bar into the Details view's exact form — `0x200000 (2097152
    /// bytes)` — and the two halves of that form are separately copyable: the
    /// hex address as hex, the decimal count as decimal.
    ///
    /// Each item names the form it copies and then the value, "Copy hex size
    /// 200000" and "Copy size 2097152", so what lands on the pasteboard is
    /// readable in the menu that offered it, the way "Copy offset" is (§3.4) —
    /// and the names are there because the two values are the same file size:
    /// one number, two readings of it, and the menu has to say which is which.
    /// The hex one is bare, without the prefix the readout above it wears.
    func makeSizeMenu(size: UInt64, form: StatusLabel.SizeForm) -> NSMenu {
        let menu = NSMenu(title: "File Size")
        let named = form == .hex ? "Copy hex size" : "Copy size"
        let copy = menu.addItem(withTitle: "\(named) \(StatusLabel.copyText(size, as: form))",
                                action: #selector(copyStatusValue(_:)),
                                keyEquivalent: "")
        copy.target = self
        copy.representedObject = StatusLabel.copyText(size, as: form)
        return menu
    }

    /// The status bar's right-click menu on the caret's offset: copying the
    /// address as the bar draws it (§3.4).
    ///
    /// The bar pads the address to the width of the file's largest address so
    /// that the offsets in the line read as aligned columns (§21.3), and what
    /// it copies is those digits — the ones the user read — rather than a second
    /// formatting of the same number. The padding is harmless where the value
    /// goes next: an offset field takes `0x` followed by hex, and leading zeros
    /// are hex.
    func makeStatusOffsetMenu(digits: String) -> NSMenu {
        let menu = NSMenu(title: "Offset")
        let copy = menu.addItem(withTitle: "Copy offset \(digits)",
                                action: #selector(copyStatusValue(_:)),
                                keyEquivalent: "")
        copy.target = self
        copy.representedObject = digits
        return menu
    }

    /// Status bar menu > Copy …: puts the value the item was titled with on the
    /// clipboard — the value read when the menu was opened, rather than the
    /// pane's read again at click time, which the bar may have changed under the
    /// open menu (§3.4). One action for both of the bar's copyable parts: what
    /// reaches the pasteboard is the item's own payload either way.
    @objc func copyStatusValue(_ sender: Any?) {
        guard let text = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The zone block: a right-click inside a zone a tool-module published
    /// offers that zone by name (`Design/TOOL_MODULES_PLAN.md`). Nothing at all
    /// where there are no zones — which is most files, most of the time.
    ///
    /// Zones nest, so a byte is often inside several: the FIT table, the row in
    /// it, the microcode a row points at. All of them are offered, innermost
    /// first, because the smallest zone under the pointer is the one being
    /// aimed at.
    private func addZoneMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let zones = pane.zones.zones(containing: offset).reversed().map { $0 }
        guard !zones.isEmpty else { return }
        menu.addItem(.separator())

        func item(_ title: String, _ action: Selector, _ zone: Zone) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = ZoneContextTarget(pane: pane, zone: zone)
            return item
        }
        // One zone is a single named item — there is nothing to choose between —
        // and several become a submenu, innermost first, listing every zone.
        if zones.count > 1 {
            let parent = menu.addItem(withTitle: "Select Zone", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Select Zone")
            for zone in zones { submenu.addItem(item(zone.name, #selector(selectZone(_:)), zone)) }
            parent.submenu = submenu
        } else {
            menu.addItem(item("Select Zone “\(zones[0].name)”", #selector(selectZone(_:)), zones[0]))
        }
        // Open Zone mirrors the choice, taking the picked zone's bytes
        // out into a document of their own.
        if zones.count > 1 {
            let parent = menu.addItem(withTitle: "Open Zone",
                                      action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Open Zone")
            for zone in zones {
                submenu.addItem(item(zone.name, #selector(openZoneInPanel(_:)), zone))
            }
            parent.submenu = submenu
        } else {
            menu.addItem(item("Open Zone “\(zones[0].name)”",
                              #selector(openZoneInPanel(_:)), zones[0]))
        }
        // Save Zone as… mirrors the choice, writing the picked zone's bytes out.
        if zones.count > 1 {
            let parent = menu.addItem(withTitle: "Save Zone as…", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Save Zone as…")
            for zone in zones { submenu.addItem(item(zone.name, #selector(saveZone(_:)), zone)) }
            parent.submenu = submenu
        } else {
            menu.addItem(item("Save Zone “\(zones[0].name)” as…", #selector(saveZone(_:)), zones[0]))
        }
    }

    /// Selects a zone's bytes, and tells the tool-module that published it —
    /// the panel is where the zone means something, and the row it stands for
    /// should come to the front there.
    @objc func selectZone(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ZoneContextTarget else { return }
        target.pane.select(range: target.zone.range)
        tools(reading: target.pane).zoneSelected(target.zone.id, in: target.pane)
    }

    /// The segment block of the offset context menu (§21.3): *Split Here at «address»* opens
    /// the Add Cut popover pre-filled with the right-clicked byte or address,
    /// and *Merge* merges the piece that position sits into its neighbour. Both
    /// act on the right-clicked position — the thing the menu was opened on.
    /// The Merge item's title is renamed by validation to name the piece and its
    /// neighbour ("Merge S1 into S0").
    private func addSegmentMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let target = OffsetContextTarget(pane: pane, offset: offset)
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        add("Split Here at \(offset.bareAddress)", #selector(splitHere(_:)))
        add("Merge", #selector(removeSegment(_:)))
    }

    /// The bookmark block of the offset context menu (§20.3). One item marks and
    /// unmarks — *Toggle Bookmark at «address»*, the same command ⌘D is, so there
    /// is one thing to learn — and a marked row is offered *Edit Bookmark…*
    /// besides. The address is the ROW's, not the clicked byte's: a right-click on
    /// a byte marks its row (§20.1), and the title is what says so.
    private func addBookmarkMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let target = OffsetContextTarget(pane: pane, offset: offset)
        let address = BookmarkStore.row(containing: offset).bareAddress
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
        }
        add("Toggle Bookmark at \(address)", #selector(toggleBookmarkAtOffset(_:)))
        if windowModel.bookmarkStore.bookmark(atRowContaining: offset) != nil {
            add("Edit Bookmark…", #selector(editBookmarkAtOffset(_:)))
        }
    }

    /// The three selection-scoped context-menu items (§10.2). Each carries the
    /// right-clicked pane (plus offset) so its action resolves THIS pane's
    /// selection, exactly as the offset items below resolve the pane.
    private func addSelectionMenuItems(to menu: NSMenu, for pane: PaneViewModel, offset: UInt64) {
        let target = OffsetContextTarget(pane: pane, offset: offset)
        let copy = menu.addItem(withTitle: "Copy",
                                action: #selector(copyPaneSelection(_:)),
                                keyEquivalent: "")
        copy.target = self
        copy.representedObject = target
        let save = menu.addItem(withTitle: "Save Selection as…",
                                action: #selector(savePaneSelectionAs(_:)),
                                keyEquivalent: "")
        save.target = self
        save.representedObject = target
        let fill = menu.addItem(withTitle: "Fill Selection with…",
                                action: #selector(fillPaneSelection(_:)),
                                keyEquivalent: "")
        fill.target = self
        fill.representedObject = target
        let delete = menu.addItem(withTitle: "Delete Bytes…",
                                  action: #selector(deletePaneSelection(_:)),
                                  keyEquivalent: "")
        delete.target = self
        delete.representedObject = target
    }

    /// The pane carried by a context-menu item (`representedObject`), or nil for
    /// menu-bar items, which act on the active pane instead.
    private func pane(from sender: Any?) -> PaneViewModel? {
        (sender as? NSMenuItem)?.representedObject as? PaneViewModel
    }

    /// The offset-context target carried by a right-click menu item, or nil.
    private func offsetContextTarget(from sender: Any?) -> OffsetContextTarget? {
        (sender as? NSMenuItem)?.representedObject as? OffsetContextTarget
    }

    /// The window-model index of `pane` (0 or 1). The pane objects are swapped
    /// by Swap Panels / pane-1 close promotion, so the comparison is by identity
    /// at action time, never a captured index.
    private func paneIndex(_ pane: PaneViewModel) -> Int {
        pane === windowModel.pane1 ? 0 : 1
    }

    /// The `FilePaneView` hosting `pane`, or nil when the pane has no view right
    /// now. Used to scroll the right-clicked pane's dump, which may not be the
    /// active one (§10.2).
    func filePaneView(for pane: PaneViewModel) -> FilePaneView? {
        // A fragment panel's pane is neither of the tab's two, and answering
        // with pane 2's view — which in single-file mode is nothing at all — is
        // how Rename in a panel came to do nothing. Its view is the one built
        // for it, which is what `paneView(for:)` has been holding all along.
        if fragmentPanel(of: pane) != nil { return paneViews[ObjectIdentifier(pane)] }
        if pane === windowModel.pane1 { return comparisonView?.paneView1 ?? activeFilePane }
        return comparisonView?.paneView2
    }

    /// Offset context menu > Select Block from Here at «address»: opens the Select Block
    /// sheet for the pane that was right-clicked — Start pre-filled with the
    /// clicked address, the Length option active, and the cursor in the Length
    /// field (§10.2).
    @objc func selectBlockFromHere(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? OffsetContextTarget,
              target.pane.isOpen else { return }
        let pane = target.pane
        let sheet = SelectBlockSheetController(fileSize: pane.fileSize, presetStart: target.offset) { [weak self] selection in
            pane.setSelection(selection)
            // §10.2: show the block's START mid-pane — in the pane that was
            // right-clicked, not the active one.
            self?.filePaneView(for: pane)?.revealOffsetCentered(selection.start)
        }
        presentAsSheet(sheet)
    }

    /// Offset context menu > Copy offset: copies the right-clicked offset to
    /// the clipboard as bare hex digits ("10", not "0x10"). The offset fields
    /// already carry a "0x" prefix with the caret right after it, so pasting a
    /// prefixed value would double it ("0x0x10"); bare digits paste straight
    /// into Go To Position / Select Block / Find (§10.2).
    @objc func copyOffset(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? OffsetContextTarget else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(format: "%X", target.offset), forType: .string)
    }

    /// Header context menu > New File: a brand-new untitled document lands in
    /// THIS pane — not a placement-chosen one — and the pane becomes active.
    @objc func newDocumentInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        let index = paneIndex(pane)
        guard newUntitledIntoPane(index: index) else { return }
        // The pane that received the new file becomes active, so focus follows
        // (§3.3). A dirty pane defers through its Save As sheet and re-enters
        // `newUntitledIntoPane` once that completes.
        windowModel.setActivePane(index)
        refreshMode()
    }

    /// Header context menu > Open…: opens into THIS pane, even when only one
    /// pane is open (single-file mode replaces the current file).
    @objc func openInPane(_ sender: Any?) {
        guard let pane = pane(from: sender) else { return }
        let index = paneIndex(pane)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.openFiles(into: index, urls: panel.urls)
        }
    }

    /// Opens the first chosen file into the pane at `index` (its header's pane),
    /// a second into the other pane only when that one is empty; extras (and an
    /// unplaceable second) are ignored. Mirrors the drop rules of §4.3.
    /// Internal (not private) so a test can drive this route the way it drives
    /// the others — every entry point deserves the same proof.
    func openFiles(into index: Int, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: index, url: first) else { return }

        let otherIndex = 1 - index
        let otherPane = otherIndex == 0 ? windowModel.pane1 : windowModel.pane2
        var ignored = max(0, files.count - 2)
        if files.count >= 2 {
            if otherPane.isOpen {
                ignored += 1  // the second file can't open — treated as ignored
            } else {
                _ = openIntoPane(index: otherIndex, url: files[1])
            }
        }
        windowModel.setActivePane(index)
        if ignored > 0 { notifyIgnored(count: ignored) }
        // A file arriving in a pane changes the pane's name, so the selector
        // has to re-read it. `refreshMode` cannot be the hook for this: it
        // returns early when the mode has not changed, which is the common case
        // here — a second file opening into a window that already has one.
        refreshToolPanelHeader()
        refreshMode()
    }

    /// Header context menu > Close: closes THIS pane (the active-pane Close in
    /// the menu bar keeps its own behavior).
    @objc func closePaneDocument(_ sender: Any?) {
        guard let pane = pane(from: sender), pane.isOpen else { return }
        // A panel's pane is not one of the tab's two, so closing it means
        // closing the panel — with the questions that closing a panel asks.
        if let panel = fragmentPanel(of: pane) {
            closeFragment(panel)
            return
        }
        closePane(at: paneIndex(pane))
    }

    // MARK: - Edit commands (§7, §12)

    @objc func undoEdit() {
        _ = try? activePane.undo()
    }

    @objc func redoEdit() {
        _ = try? activePane.redo()
    }

    @objc func selectAllBytes() {
        activePane.selectAll()
        focusActiveHexView()
    }

    /// Edit > Copy (⌘C): copies the ACTIVE pane's selection.
    @objc func copySelection() {
        copySelectionBytes(of: activePane)
    }

    /// Context menu > Copy: copies the RIGHT-CLICKED pane's selection (§10.2).
    @objc func copyPaneSelection(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        copySelectionBytes(of: target.pane)
    }

    /// Copies `pane`'s selection to the clipboard: raw bytes (primary, §12.1)
    /// plus uppercase hex text.
    private func copySelectionBytes(of pane: PaneViewModel) {
        guard let doc = pane.document, !doc.selection.isEmpty else { return }
        let range = doc.selection.start..<doc.selection.end
        guard let bytes = try? doc.read(at: range.lowerBound, length: Int(range.count)) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(bytes), forType: .rawBytes)  // raw bytes: primary (§12.1)
        pasteboard.setString(ClipboardCodec.hexText(from: bytes), forType: .string)
    }

    /// Context menu > Save Selection as…: writes the RIGHT-CLICKED pane's
    /// selected bytes to a file the user names (§10.2). A read of the selection
    /// only — the source file is never written by this command, so it is offered
    /// whether or not the pane is writable, and what is saved is what is shown,
    /// edits and all.
    @objc func savePaneSelectionAs(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        guard let doc = target.pane.document, !doc.selection.isEmpty else { return }
        let range = doc.selection.start..<doc.selection.end
        saveRange(range, of: target.pane,
                  suggestedName: exportName(fileName: target.pane.status.fileName, range: range),
                  purpose: "the selection")
    }

    /// Context menu > Save Zone as…: writes a zone a tool-module published to a
    /// file the user names. The same read-only export as Save Selection as…: the
    /// pane's source is never written, and the bytes saved are what is on
    /// screen, edits and all. The name leads with the zone's own name — that is
    /// what the user is looking for — over the offsets.
    @objc func saveZone(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ZoneContextTarget, target.pane.isOpen else { return }
        let zone = target.zone
        saveRange(zone.range, of: target.pane,
                  suggestedName: zoneExportName(fileName: target.pane.status.fileName,
                                                zoneName: zone.name, range: zone.range),
                  purpose: "the zone")
    }

    /// Takes a zone's bytes out into a panel of their own.
    ///
    /// A zone is a structure somebody found in the file — a volume, a FIT table,
    /// a microcode — and the way to study one is often to look at it as a file
    /// rather than at its offsets inside a bigger one. The panel holds a copy:
    /// it is untitled and unsaved, so editing it cannot reach back into the
    /// dump it was taken from, and Save routes through Save As. What does reach
    /// back is Update in Parent, which is why the panel opens over the parent
    /// rather than beside it (`Design/FRAGMENT_PANELS_PLAN.md`).
    @objc func openZoneInPanel(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ZoneContextTarget else { return }
        openZone(target.zone, of: target.pane)
    }

    /// The act both zone menus perform — the dump's and the minimap gutter's.
    /// One reading of the bytes, one panel, one set of rules about what the
    /// copy is, wherever the reader asked from.
    private func openZone(_ zone: Zone, of pane: PaneViewModel) {
        guard pane.isOpen, let doc = pane.document else { return }
        let bytes: [UInt8]
        do {
            bytes = try doc.read(at: zone.range.lowerBound, length: Int(zone.range.count))
        } catch {
            presentFileError("Could not read the zone.", error, url: doc.url)
            return
        }
        // Linked back to the zone, and told what the bytes are when the file's
        // UEFI tree knows (`Design/UEFI/UPDATE_IN_PARENT.md` §2.1).
        let layout = pane.uefiState.tree.map {
            UEFIRootLayout.forFileRange(zone.range, in: $0.image())
        } ?? .image
        openFragment(
            bytes,
            named: zoneExportName(fileName: pane.status.fileName,
                                  zoneName: zone.name, range: zone.range),
            origin: DocumentOrigin(parent: pane, source: zone.range,
                                   partName: zone.name, layout: layout, kind: .copy,
                                   // A zone that is a volume, a file or a section
                                   // goes back through the rebuild planner (§6).
                                   rebuildTarget: pane.uefiState.tree.flatMap {
                                       UEFIRebuild.target(forFileRange: zone.range, in: $0.image())
                                   },
                                   content: bytes)
        )
    }

    /// The tail shared by Save Selection as… and Save Zone as…: reads `range`
    /// out of `pane`'s document and offers the bytes as a file to save. `purpose`
    /// names the range in the error strings ("the selection", "the zone").
    private func saveRange(_ range: Range<UInt64>, of pane: PaneViewModel,
                           suggestedName: String, purpose: String) {
        guard let doc = pane.document else { return }
        let bytes: [UInt8]
        do {
            bytes = try doc.read(at: range.lowerBound, length: Int(range.count))
        } catch {
            presentFileError("Could not read \(purpose).", error, url: doc.url)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let url: URL?
        if let selectionSavePanel {
            url = selectionSavePanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        do {
            try Data(bytes).write(to: url, options: .atomic)
        } catch {
            presentFileError("Could not save \(purpose).", error, url: url)
        }
    }

    /// The name the Save panel suggests for a saved selection: the source file's
    /// name with the exported range appended, so a save of even the whole file
    /// cannot silently land on the file that is open.
    private func exportName(fileName: String, range: Range<UInt64>) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let bounds = "\(range.lowerBound.bareAddress)-\(range.upperBound.bareAddress)"
        return "\(stem)_\(bounds).bin"
    }

    /// The name the Save panel suggests for a saved zone: the source file's name
    /// with the zone's own name appended. A nameless zone falls back to its
    /// range, so the export still cannot silently land on the file that is open.
    private func zoneExportName(fileName: String, zoneName: String,
                                range: Range<UInt64>) -> String {
        guard !zoneName.isEmpty else { return exportName(fileName: fileName, range: range) }
        let stem = (fileName as NSString).deletingPathExtension
        return "\(stem)_\(zoneName).bin"
    }

    /// The standard "Paste" menu item (⌘V → `paste:`) dispatches through the
    /// responder chain (§11). A focused text field's editor implements
    /// `paste:` and pastes text, so the message only reaches this controller
    /// when the first responder has no text-paste of its own — i.e. the hex
    /// view. Paste-write into the dump therefore happens only while a hex
    /// pane holds focus; everywhere else ⌘V is the standard system paste.
    @objc func paste(_ sender: Any?) {
        guard view.window?.firstResponder is HexView, activePane.isOpen else { return }
        pasteWrite()
    }

    @objc func pasteWrite() {
        let pane = activePane
        guard pane.isOpen else { return }
        do {
            let bytes = try pasteboardBytes()
            try pane.pasteWrite(bytes)
        } catch {
            presentError("Paste", error)
        }
    }

    @objc func pasteInsert() {
        let pane = activePane
        guard pane.isOpen else { return }
        let bytes: [UInt8]
        do {
            bytes = try pasteboardBytes()
        } catch {
            presentError("Paste Insert", error)
            return
        }
        guard !bytes.isEmpty else { return }
        let offset = pane.caretOffset
        let response = confirmAlert(
            title: "Paste Insert?",
            message: "Insert \(bytes.count) byte(s) at offset \(String(format: "0x%X", offset)). Existing bytes from this offset on will shift.",
            confirmTitle: "Insert",
            destructive: true,
            suppressible: true
        )
        guard response == .alertFirstButtonReturn else { return }
        do {
            try pane.pasteInsert(bytes)
        } catch {
            presentError("Paste Insert failed.", error)
        }
    }

    /// Edit > Fill Selection with…: fills the ACTIVE pane's selection.
    @objc func fillSelectionWithBytes() {
        presentFillSheet(for: activePane)
    }

    /// Context menu > Fill Selection with…: fills the RIGHT-CLICKED pane's
    /// selection (§10.2). The sheet's completion captures that pane directly, so
    /// a selection in a non-active pane is still the one that gets filled.
    @objc func fillPaneSelection(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        presentFillSheet(for: target.pane)
    }

    private func presentFillSheet(for pane: PaneViewModel) {
        guard pane.isOpen, !pane.hexSelection().isEmpty else { return }
        let sheet = FillSheetController(selectionCount: pane.hexSelection().count) { pattern in
            pane.fillSelection(with: pattern)
        }
        presentAsSheet(sheet)
    }

    /// Edit > Delete Bytes…: deletes the ACTIVE pane's selection, or the caret
    /// byte when the selection is empty.
    @objc func deleteBytes() {
        deleteSelectionOrCaret(in: activePane)
    }

    /// Context menu > Delete Bytes…: deletes the RIGHT-CLICKED pane's selection
    /// (§10.2). Only offered when the selection is non-empty, so the single-byte
    /// caret fallback never applies here.
    @objc func deletePaneSelection(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender), target.pane.isOpen else { return }
        deleteSelectionOrCaret(in: target.pane)
    }

    private func deleteSelectionOrCaret(in pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let selection = pane.hexSelection()
        let start = selection.start
        let count = selection.isEmpty ? 1 : selection.count
        let response = confirmAlert(
            title: "Delete \(count) byte(s)?",
            message: "Bytes from offset \(String(format: "0x%X", start)) will be removed. Subsequent offsets will shift — the file structure may be affected.",
            confirmTitle: "Delete",
            destructive: true,
            suppressible: true
        )
        guard response == .alertFirstButtonReturn else { return }
        do {
            try pane.deleteBytes(in: start..<(start + count))
        } catch {
            presentError("Delete failed.", error)
        }
    }

    /// Edit > Insert Mode: flips the typing mode of the ACTIVE pane. The mode is
    /// per pane and never persisted — one file can be typed into while the other
    /// is being read, and each pane's status bar says which mode it is in (§7.6).
    ///
    /// When on, typing inserts a byte at the caret and shifts the tail right; the
    /// caret becomes a red vertical line at the byte boundary. The one-time
    /// "this shifts the file" warning is injected here rather than at pane
    /// creation, which guarantees the callback exists before any insert-mode
    /// keystroke; it is mode-independent, so re-enabling after a toggle-off never
    /// re-arms it within the same file.
    @objc func toggleInsertMode(_ sender: Any?) {
        flipInsertMode(of: activePane)
    }

    /// Flips the typing mode of `pane` — the Edit menu acts on the active one, a
    /// click on a pane's status-bar indicator on the pane that was clicked
    /// (§7.6). The mode is per pane either way, and the pane whose mode changed
    /// is the one that redraws its OVR/INS indicator.
    func flipInsertMode(of pane: PaneViewModel) {
        pane.isInsertMode.toggle()
        pane.confirmInsertModeWarning = { [weak self, weak pane] in
            guard let self, let pane else { return true }
            let offset = pane.caretOffset
            let response = self.confirmAlert(
                title: "Insert?",
                message: "Inserting at offset \(String(format: "0x%X", offset)) shifts every byte from here on — the file structure may be affected.",
                confirmTitle: "Insert",
                destructive: true,
                suppressible: true
            )
            return response == .alertFirstButtonReturn
        }
    }

    /// Adds or removes the toolbar's Prev/Next Difference block to match the
    /// mode. Difference navigation exists only with two files open, and a block
    /// of buttons that can never do anything is worse than no block: disabled
    /// they still read as something the window offers (§10.3). The menu items
    /// stay, disabled — a menu is a list of what exists, and it says why.
    ///
    /// Called on every mode change and once the toolbar exists (the window
    /// controller builds it after the view is loaded).
    func syncDiffNavigationToolbarItem() {
        // Deferred by a run-loop turn, and coalesced. Called from `apply(mode:)`
        // this would land while AppKit is still reconfiguring the toolbar from
        // the previous change, and mutating it then raises on the item index.
        guard !diffToolbarSyncScheduled else { return }
        diffToolbarSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.diffToolbarSyncScheduled = false
            self?.applyDiffNavigationToolbarItem()
        }
    }

    private func applyDiffNavigationToolbarItem() {
        // Only a toolbar on screen can be reconfigured: before the window is
        // shown, `items` reports the configured identifiers while the toolbar's
        // own list is still empty. A window that appears later syncs from
        // `viewDidAppear`.
        guard let window = viewIfLoaded?.window, window.isVisible,
              let toolbar = window.toolbar else { return }
        // Exactly one of the two occupies the slot: the Prev/Next Difference
        // block, or — when the comparison holds no differences at all — the
        // "Files are identical" badge in its place (§10.3).
        let wanted: NSToolbarItem.Identifier? =
            mode == .comparison ? (showsIdenticalBadge ? .filesIdentical : .diffNavigation) : nil
        // Insert the wanted item first, then drop the other. Inserting before
        // removing keeps every mutation on a toolbar that still carries its
        // full item set, which is the order NSToolbar's internal item indexing
        // tolerates: removing first and then inserting in the same pass leaves
        // a stale index and raises in -[_itemAtIndex:].
        if let wanted,
           !toolbar.items.contains(where: { $0.itemIdentifier == wanted }) {
            // Right after the flexible space, which is where the plaque's slot
            // is (§24): the left-hand group has a standard space of its own, so
            // anchoring on the first `.space` would drop the block in there.
            let insertAt = toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace }
                .map { $0 + 1 } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: wanted, at: insertAt)
        }
        for identifier in [NSToolbarItem.Identifier.diffNavigation, .filesIdentical]
        where identifier != wanted {
            if let i = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
                toolbar.removeItem(at: i)
            }
        }
        // A freshly inserted item starts enabled — AppKit's default validation
        // only asks whether the target responds to the action — so it would
        // offer a live-looking Prev Diff until the next validation pass (§10.3).
        toolbar.validateVisibleItems()
    }

    /// Whether the toolbar shows the "Files are identical" badge instead of the
    /// Prev/Next Difference arrows — the last DETERMINED comparison outcome:
    /// the index built and reported no differences.
    ///
    /// Stored, not computed: while the index is building the outcome is
    /// undetermined, and a computed `!isBuilding && …` would drop the plaque
    /// back to the arrows on every rebuild — which is what made the buttons
    /// flicker while typing, each edit re-running the comparison. The plaque
    /// therefore keeps its last determined state through a build and changes
    /// only when a new one lands: differences (arrows), no differences (badge),
    /// or the mode leaving comparison (no block at all).
    private var showsIdenticalBadge = false

    /// Moves `showsIdenticalBadge` to the current outcome, but only when that
    /// outcome is determined — comparison mode, index built, build finished.
    /// Fired from the coordinator's state hook, which also covers the
    /// incremental applies that land an edited index without a full build.
    private func updateIdenticalBadgeState() {
        guard mode == .comparison,
              !comparisonCoordinator.isBuilding,
              let index = comparisonCoordinator.index else { return }
        showsIdenticalBadge = !index.hasDifferences
    }

    // MARK: - Comparison navigation (§10.3)

    @objc func nextDifference() { navigateBlock(kind: .different, direction: .forward) }
    @objc func previousDifference() { navigateBlock(kind: .different, direction: .backward) }
    @objc func nextSameBlock() { navigateBlock(kind: .same, direction: .forward) }
    @objc func previousSameBlock() { navigateBlock(kind: .same, direction: .backward) }

    /// Recomputes `diffNavigationState` from the current mode, index build
    /// state, and active caret — the same `from` and search rules
    /// `navigateBlock` uses, so a menu item is enabled exactly when the action
    /// would find a block. Fired on mode changes, index transitions, pane
    /// switches, and caret moves; the menu items read the result via
    /// `validateMenuItem` (§10.3).
    private func refreshDiffNavigation() {
        var state = DiffNavigationState()
        if mode == .comparison, !comparisonCoordinator.isBuilding {
            // Ask through the coordinator, so enablement and the action itself
            // agree on the unit they step by — grouped hunks (§10.3.1).
            let from = windowModel.activePane.caretOffset
            func exists(_ kind: DiffBlock.Kind, _ direction: SearchDirection) -> Bool {
                comparisonCoordinator.findBlock(kind: kind, direction: direction, from: from) != nil
            }
            state.previousDifference = exists(.different, .backward)
            state.nextDifference = exists(.different, .forward)
            state.previousSameBlock = exists(.same, .backward)
            state.nextSameBlock = exists(.same, .forward)
        }
        guard state != diffNavigationState else { return }
        diffNavigationState = state
        // Menu items are validated when the menu opens, but the toolbar's arrows
        // are on screen the whole time: AppKit revalidates them on its own idle
        // schedule, so ask for it here and they follow the caret at once (§10.3).
        viewIfLoaded?.window?.toolbar?.validateVisibleItems()
    }

    private func navigateBlock(kind: DiffBlock.Kind, direction: SearchDirection) {
        guard mode == .comparison else { return }
        let from = windowModel.activePane.caretOffset
        Task {
            guard let block = comparisonCoordinator.findBlock(kind: kind, direction: direction, from: from) else {
                let what = kind == .different ? "difference" : "same block"
                NSSound.beep()
                comparisonView?.showNavigationMessage("No more \(what)")
                return
            }
            // Forward navigation lands on the block start; backward navigation
            // lands on the block's LAST byte (not the byte past it), so a
            // repeated previous press skips the current block and finds the one
            // before it — landing past the block would re-find it (§10.3).
            let target = direction == .backward ? block.range.upperBound - 1 : block.range.lowerBound
            windowModel.pane1.moveCaret(to: target)
            windowModel.pane2.moveCaret(to: target)
            comparisonView?.refreshComparisonInfo()
            // Show the block start mid-pane, the way the Find bar centres a
            // match; the panes' synchronized scroll (§9) centres both (§10.3).
            activeFilePane?.revealSelectionCentered()
            focusActiveHexView()
        }
    }

    /// View > Toggle Pane Layout (§3.3).
    @objc func togglePaneLayout() {
        guard mode == .comparison else { return }
        comparisonView?.toggleLayout()
        // `setLayout` persists the direction, which the layout observer picks up
        // and revalidates on — but only for a change that actually landed. Ask
        // here too, so the toolbar's icon flips with the click (§24.3).
        revalidateToolbar()
    }

    /// View > Swap Panels: exchanges pane 1 and pane 2 (comparison mode). The
    /// active pane follows its document, so the file the user was working on
    /// stays active. Re-applying the mode re-points the panes (which follow
    /// their models) to the swapped positions and rebuilds the diff index
    /// against the swapped storages.
    @objc func swapPanes() {
        guard mode == .comparison else { return }
        windowModel.swapPanes()
        // The panel's header lists the panes in pane order, and the session
        // stays bound to its own pane — which has just moved to the other
        // position. Without this the tick would sit on the file the tool is
        // *not* reading, which is the one thing the header exists to say.
        refreshToolPanelHeader()
        // Swap exchanges the models in position but leaves the mode unchanged,
        // so `refreshMode()`'s skip-when-unchanged guard would not re-apply —
        // and the panes would stay put while the model→position mapping
        // changes, desyncing every position-based operation (a drop onto the
        // right pane would hit the model now in the left). Re-apply directly
        // so the views follow the swapped models (§3.3).
        apply(mode: .comparison)
    }

    /// View > Word Size (§6): re-groups the hex dump into words of this size.
    /// The size travels as the sender's tag, from the menu item or from the
    /// toolbar's menu button (§24.2) — one action for both.
    @objc func setWordSize(_ sender: Any?) {
        let tag: Int?
        switch sender {
        case let menuItem as NSMenuItem: tag = menuItem.tag
        case let button as NSPopUpButton: tag = button.selectedTag()
        default: tag = nil
        }
        guard let size = tag.flatMap({ WordSize(rawValue: $0) }) else { return }
        WordSize.set(size)
    }

    // MARK: - Bookmarks (§20)

    /// Edit > Toggle Bookmark (⌘D), and the offset menu's item: toggles the mark
    /// on `pane`'s row containing `offset` (§20.3). A bookmark marks a row, not a
    /// byte — the offset is rounded down to its row — and the list is shared by
    /// both panes, so the same row is marked in both panes of a comparison.
    ///
    /// Marking a row opens the naming popover on the new mark: Return saves it
    /// (unnamed if nothing was typed), Esc removes it again. That is what makes
    /// **⌘D, Return** the whole gesture for "mark this row" and ⌘D, a name,
    /// Return the one for "mark it and call it this". A row that is already
    /// marked is unmarked on the spot, with no popover to dismiss.
    private func toggleBookmarkInPane(_ pane: PaneViewModel, rowContaining offset: UInt64) {
        guard pane.isOpen else { return }
        if windowModel.bookmarkStore.remove(rowContaining: offset) { return }
        markAndNameBookmark(in: pane, rowContaining: offset)
    }

    /// Marks the row containing `offset` and opens the naming popover on the new
    /// mark. The mark is made first, so it is visible while its name is typed —
    /// and `existingName: nil` is what tells the popover it is naming a mark that
    /// was just made, so its Esc removes it rather than keeping a name (§20.3).
    ///
    /// The caret and the viewport are not moved here: the popover is about to
    /// take the focus, so a caret move now would be hidden behind it and lost.
    /// They land on the new mark only once the naming is committed — see
    /// `onCommit` below, which acts on the row the popover settled on.
    private func markAndNameBookmark(in pane: PaneViewModel, rowContaining offset: UInt64) {
        let store = windowModel.bookmarkStore
        let row = BookmarkStore.row(containing: offset)
        store.add(rowContaining: row)
        presentBookmarkEditPopover(
            in: pane, row: row, existingName: nil,
            onCommit: { [weak self] target, name in
                self?.applyBookmarkEdit(from: row, to: target, name: name)
                self?.revealBookmark(at: target, in: pane)
            },
            onCancel: { store.remove(rowContaining: row) }
        )
    }

    /// Lands the caret on a just-created bookmark and reveals it — centred when
    /// it fell off-screen, left in place when it is already on the user's eye
    /// (`moveCaret`'s centred reveal). Done on the commit, once the naming
    /// popover has released the focus: a bookmark is made on a row, and that row
    /// is where the user's eye should land now that the act is done.
    private func revealBookmark(at row: UInt64, in pane: PaneViewModel) {
        pane.moveCaret(to: row)
    }

    /// A double click on an address opens the edit popover on that row: it marks
    /// the row first when it carries no mark, so the gesture is ⌘D's with the
    /// mouse, and it edits the mark that is there otherwise — a double click on
    /// a mark is how a mark is opened everywhere else in the app (§20.5's list
    /// does the same on a name).
    ///
    /// What it never does is unmark: the pointer covers the mark it is aimed at,
    /// so a toggle here would silently take an existing bookmark away on a click
    /// landing a row off.
    func handleOffsetDoubleClick(in pane: PaneViewModel, rowContaining offset: UInt64) {
        guard pane.isOpen else { return }
        if windowModel.bookmarkStore.bookmark(atRowContaining: offset) != nil {
            editBookmarkInPane(pane, rowContaining: offset)
        } else {
            markAndNameBookmark(in: pane, rowContaining: offset)
        }
    }

    /// Wires a pane view's Offset-column double click to the bookmark gesture, so
    /// it resolves THIS pane even when it is not the active one (§20.3).
    func wireBookmarkDoubleClick(_ paneView: FilePaneView, for pane: PaneViewModel) {
        paneView.onOffsetDoubleClick = { [weak self] offset in
            self?.handleOffsetDoubleClick(in: pane, rowContaining: offset)
        }
    }

    /// Wires a pane view's status-bar controls, each of which acts on THIS pane
    /// rather than on the active one: the file size's and the offset's copy
    /// menus (§3.4), and the OVR/INS indicator's click, which flips the mode of
    /// the pane it is drawn in (§7.6).
    func wireStatusBar(_ paneView: FilePaneView, for pane: PaneViewModel) {
        paneView.statusSizeMenuProvider = { [weak self] size, form in
            self?.makeSizeMenu(size: size, form: form) ?? NSMenu()
        }
        paneView.statusOffsetMenuProvider = { [weak self] digits in
            self?.makeStatusOffsetMenu(digits: digits) ?? NSMenu()
        }
        paneView.onTypingModeToggle = { [weak self] in
            self?.flipInsertMode(of: pane)
        }
    }

    /// Edits the mark on `pane`'s row containing `offset` — its address and its
    /// name — in the same popover (§20.3). Only for a row that carries one: Esc
    /// leaves the bookmark exactly as it was.
    private func editBookmarkInPane(_ pane: PaneViewModel, rowContaining offset: UInt64) {
        guard pane.isOpen,
              let existing = windowModel.bookmarkStore.bookmark(atRowContaining: offset) else { return }
        let store = windowModel.bookmarkStore
        presentBookmarkEditPopover(
            in: pane, row: existing.row, existingName: existing.name,
            onCommit: { [weak self] target, name in
                self?.applyBookmarkEdit(from: existing.row, to: target, name: name)
            },
            onCancel: {},
            // Removing is offered only here, on a bookmark that already exists:
            // a mark still being named is taken away by its Esc (§20.3).
            onDelete: { store.remove(rowContaining: existing.row) }
        )
    }

    /// Applies what the popover was edited to: the name, and the address when it
    /// changed. A moved bookmark is the same bookmark — it leaves the old row and
    /// arrives on the new one named, rather than being removed and re-made, so
    /// nothing in between sees a bookmark without its name (§20.3).
    private func applyBookmarkEdit(from row: UInt64, to target: UInt64, name: String) {
        windowModel.bookmarkStore.edit(rowContaining: row, to: target, name: name)
    }

    /// A request to edit a bookmark: which row, in which pane, the name it
    /// starts with (nil when the mark was just created, which is what makes Esc
    /// remove it), and what the two keys do. `commit` takes the row the popover
    /// was edited to, which is not always the row it opened on (§20.3).
    struct BookmarkEditRequest {
        let pane: PaneViewModel
        let row: UInt64
        let existingName: String?
        let commit: (UInt64, String) -> Void
        let cancel: () -> Void
        /// Removes the bookmark — nil for a mark that was just made, whose Esc
        /// already does that (§20.3).
        let delete: (() -> Void)?
    }

    /// Where an edit request goes, returning how to dismiss what it presented.
    /// Nil means the real popover on the pane's mark; a test replaces it to
    /// capture the request instead, because a popover anchored in a window that
    /// is never on screen closes the instant it opens — the commands' own
    /// behaviour is what those tests are about.
    var bookmarkEditPresenter: ((BookmarkEditRequest) -> () -> Void)?

    /// The editing session on screen: the row it is about, and how to close it
    /// without saving. Held because it must not outlive its mark (§20.3).
    private var openEditing: (row: UInt64, dismiss: () -> Void)?

    /// The row an edit popover is open for, if any.
    var editingRow: UInt64? { openEditing?.row }

    /// Presents the edit popover on `pane`'s mark (§20.3), replacing any session
    /// already on screen — ⌘D on another row while one is open would otherwise
    /// leave two panels up, one of them about a row the user has moved on from.
    private func presentBookmarkEditPopover(
        in pane: PaneViewModel, row: UInt64, existingName: String?,
        onCommit: @escaping (UInt64, String) -> Void, onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        openEditing?.dismiss()
        openEditing = nil
        let request = BookmarkEditRequest(
            pane: pane, row: row, existingName: existingName,
            commit: { [weak self] target, name in
                self?.openEditing = nil
                onCommit(target, name)
            },
            cancel: { [weak self] in
                self?.openEditing = nil
                onCancel()
            },
            delete: onDelete.map { delete in
                { [weak self] in
                    self?.openEditing = nil
                    delete()
                }
            }
        )
        if let bookmarkEditPresenter {
            openEditing = (row, bookmarkEditPresenter(request))
            return
        }
        guard let paneView = filePaneView(for: pane) else { return }
        let store = windowModel.bookmarkStore
        let controller = paneView.presentBookmarkEditPopover(
            rowContaining: row, existingName: existingName,
            // One row holds one bookmark (§20.1), so an address already marked is
            // not an address this bookmark can be given.
            rowIsFree: { store.bookmark(atRowContaining: $0) == nil },
            onCommit: request.commit, onCancel: request.cancel, onDelete: request.delete
        )
        openEditing = (row, { controller.abandon() })
    }

    /// Closes the edit popover when the mark it is editing disappears. Every
    /// removal arrives here through the window's bookmark signal — ⌘D (whose key
    /// equivalent reaches the menu through an open popover), the context menu,
    /// and the form's list — so no removal path has to remember to do this
    /// (§20.3).
    private func dismissEditPopoverIfItsMarkIsGone(row: UInt64) {
        guard let openEditing, openEditing.row == row,
              windowModel.bookmarkStore.bookmark(atRowContaining: row) == nil else { return }
        self.openEditing = nil
        openEditing.dismiss()
    }

    /// ⌘D: the active pane's caret row.
    @objc func toggleBookmark() {
        toggleBookmarkInPane(activePane, rowContaining: activePane.hexSelection().start)
    }

    /// ⇧⌘D: edits the mark on the active pane's caret row — its address and its
    /// name. Enabled only when that row carries one: ⌘D is how a mark is made,
    /// and it opens the same popover, so this command only ever edits (§20.3).
    @objc func editBookmark() {
        editBookmarkInPane(activePane, rowContaining: activePane.hexSelection().start)
    }

    /// Offset context menu > Toggle Bookmark: the same act on the row that was
    /// right-clicked rather than the caret's, in the pane that was right-clicked.
    @objc func toggleBookmarkAtOffset(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender) else { return }
        toggleBookmarkInPane(target.pane, rowContaining: target.offset)
    }

    /// Offset context menu > Edit Bookmark…: the edit popover for the
    /// right-clicked row's existing mark.
    @objc func editBookmarkAtOffset(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender) else { return }
        editBookmarkInPane(target.pane, rowContaining: target.offset)
    }

    // MARK: - Segments (§21)

    /// The cut edit request: the pane, the offset the field starts at, where the
    /// popover anchors, and what committing means.
    struct CutEditRequest {
        let pane: PaneViewModel
        let prefillOffset: UInt64
        let anchoredToOffset: Bool
        let commit: (UInt64, String) -> Void
    }

    /// Where a cut edit request goes. Nil means the real popover on the caret's
    /// cell; a test replaces it to capture the request instead, because a
    /// popover anchored in a window that is never on screen closes the instant
    /// it opens — the commands' own behaviour is what those tests are about.
    var cutEditPresenter: ((CutEditRequest) -> Void)?

    /// Edit ▸ Add Cut…: the caret's offset, in a popover with a description —
    /// the cut for an offset you know as a number rather than as a position
    /// (§21.3). No key equivalent: a deliberate act reached from the menu. The
    /// popover is centred in the pane, not anchored to the caret: it is a dialog
    /// pre-filled with a number, not a pointer at a byte.
    @objc func addCut() {
        let pane = activePane
        presentCutEditPopover(in: pane, prefill: pane.caretOffset, anchoredToOffset: false)
    }

    /// Merge: merges the piece a position sits in into its neighbour (§21.3). It
    /// acts on a position *inside* a piece — the caret's, from the Edit menu; the
    /// right-clicked byte or address, from the context menu — not on a cut point.
    /// The bytes are untouched: merging a piece changes how the file is read, not
    /// the file. The menu title names the piece and the neighbour it merges into
    /// ("Merge S1 into S0"), so it is never confused with deleting data.
    @objc func removeSegment(_ sender: Any?) {
        let (pane, position): (PaneViewModel, UInt64)
        if let target = offsetContextTarget(from: sender) {
            (pane, position) = (target.pane, target.offset)
        } else {
            pane = activePane
            position = pane.caretOffset
        }
        guard let piece = pane.segmentStore.segment(containing: position) else { return }
        pane.segmentStore.removePiece(at: piece.index)
    }

    /// Offset context menu ▸ Split Here at «address»: the Add Cut popover, opened on the
    /// right-clicked byte or address and pre-filled with it (§21.3) — the same
    /// dialog as Edit ▸ Add Cut…, so a cut made from the menu and one made from
    /// the bar are the same act. This is how a cut normally gets made.
    @objc func splitHere(_ sender: Any?) {
        guard let target = offsetContextTarget(from: sender) else { return }
        presentCutEditPopover(in: target.pane, prefill: target.offset)
    }

    /// Presents the cut popover for `pane` (§21.3). The offset starts at
    /// `prefill` (the caret's, or the right-clicked byte's) and is validated as
    /// it is typed; committing makes the cut and names the piece that starts
    /// there. With `anchoredToOffset` the popover hangs off that byte; without
    /// it (Add Cut…) it is centred in the pane's visible area.
    private func presentCutEditPopover(in pane: PaneViewModel, prefill: UInt64,
                                       anchoredToOffset: Bool = true) {
        let request = CutEditRequest(
            pane: pane, prefillOffset: prefill, anchoredToOffset: anchoredToOffset,
            commit: { offset, name in
                guard pane.segmentStore.addCut(at: offset) else { return }
                // The cut splits the piece at `offset`; the new piece is the one
                // that *starts* there, so it is the one the description names.
                if let piece = pane.segmentStore.segment(containing: offset) {
                    pane.segmentStore.rename(piece.index, to: name)
                }
            }
        )
        if let cutEditPresenter {
            cutEditPresenter(request)
            return
        }
        guard let paneView = filePaneView(for: pane) else { return }
        paneView.presentCutEditPopover(
            prefillOffset: prefill, fileSize: pane.fileSize,
            isAlreadyACut: { pane.segmentStore.cuts.contains($0) },
            onCommit: request.commit, anchoredToOffset: anchoredToOffset
        )
    }

    // MARK: - Dialogs (§10)

    /// ⌘L: the Go To / Bookmarks form with the offset field focused — the fast
    /// path is unchanged, ⌘L, type, Return (§10.1). Tab moves the keyboard to
    /// the bookmark list, the other half of the same window (§20.5).
    @objc func goToPosition() {
        presentGoToForm(focus: .offsetField)
    }

    /// Where the form goes, so a test can drive it instead: it is presented in a
    /// modal window, and a modal window has no one to dismiss it under XCTest.
    var goToFormPresenter: ((GoToBookmarksController) -> Void)?

    /// The form on screen, so a bookmark changed under it (from its own list, or
    /// from anywhere the store is touched) refreshes what it shows (§20.2).
    private weak var openGoToForm: GoToBookmarksController?

    private func presentGoToForm(focus: GoToBookmarksController.Focus) {
        guard activePane.isOpen else { return }
        let form = GoToBookmarksController(
            store: windowModel.bookmarkStore, focus: focus,
            rowBytes: { [weak self] row in self?.bookmarkRowBytes(row) },
            onGo: { [weak self] offset in self?.goTo(offset: offset) }
        )
        openGoToForm = form
        if let goToFormPresenter {
            goToFormPresenter(form)
            return
        }
        // A window, not a sheet: it holds a list the user manages, and it is
        // centred over the window it navigates.
        presentAsModalWindow(form)
    }

    /// Segments…: the partition's own form — the pieces in a table with a row
    /// editor, a +/− footer, and the Save All button (§21.4). Presented like
    /// the Go To form: a modal window that follows the pane's store, so a cut
    /// made under it from the dump's own context menu is seen in the list.
    @objc func showSegments() {
        presentSegmentsForm()
    }

    /// Where the form goes, so a test can drive it instead: it is presented in
    /// a modal window, and a modal window has no one to dismiss it under XCTest.
    var segmentsFormPresenter: ((SegmentsFormController) -> Void)?

    /// The form on screen, so a cut made under it (from the dump's context
    /// menu, or from the form's own +/−) refreshes what it shows (§21.4).
    private weak var openSegmentsForm: SegmentsFormController?

    private func presentSegmentsForm(pane: PaneViewModel? = nil, selecting pieceIndex: Int? = nil) {
        let pane = pane ?? activePane
        guard pane.isOpen else { return }
        let form = SegmentsFormController(
            pane: pane,
            // The app's own jump (§10.1): both panes in comparison mode, the
            // row revealed, the hex view focused — the same act as the Go To
            // form's Return.
            onGo: { [weak self] offset in self?.goTo(offset: offset) }
        )
        // The save actions live here, not in the form (§21.5): the form is
        // modal and has no status bar of its own, so the panels, the overwrite
        // confirmation and the write's progress all run from the window.
        form.saveAll = { [weak self] in self?.saveAllPieces(of: pane) ?? false }
        form.savePiece = { [weak self] piece in self?.savePiece(piece, of: pane) ?? false }
        form.replacePiece = { [weak self] piece in self?.replacePiece(piece, of: pane) ?? false }
        // The pane's `onSegmentsChanged` is set once per mode apply (§19.4.4):
        // it reloads this form when it is open and syncs the minimap's strip
        // whether or not it is, so a cut made here repaints the legend too.
        openSegmentsForm = form
        if let segmentsFormPresenter {
            segmentsFormPresenter(form)
        } else {
            // A window, not a sheet: it holds a list the user manages, and it is
            // centred over the window it edits.
            presentAsModalWindow(form)
        }
        // The strip's Edit… opens the form on the piece under the pointer.
        if let pieceIndex {
            form.selectSegment(atIndex: pieceIndex)
        }
    }

    // MARK: - Writing pieces out (§21.5)

    /// Save All as Separate Files…: writes the whole partition out as its pieces.
    /// The directory is chosen in directory mode (a save panel grants access to
    /// one file and this writes N — the sandbox would refuse the rest), the base
    /// name comes from the document, and one confirmation previews what will be
    /// written and names every file that would be replaced, before anything is
    /// written. Returns whether the write actually started — the form closes on
    /// true and stays open when the user cancelled a panel.
    private func saveAllPieces(of pane: PaneViewModel) -> Bool {
        guard pane.isOpen, let storage = pane.byteStorage else { return false }
        let segments = pane.segmentStore.segments
        guard !segments.isEmpty else { return false }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder the segments will be written to."
        let directory: URL?
        if let segmentDirectoryPanel {
            directory = segmentDirectoryPanel(panel)
        } else {
            directory = panel.runModal() == .OK ? panel.url : nil
        }
        guard let directory else { return false }

        // One file per piece, named for the document: `bios_S0.bin`, `bios_S1.bin`, …
        // The name the header shows, not the document's URL: an unsaved document
        // has no URL worth reading (it points at a temporary file called
        // "Untitled"), and its name is the label — which the user can set, and
        // for this above all, since a directory is the only other thing this
        // command asks for (§23).
        let baseName = pane.status.fileName
        let parts = segments.map {
            SegmentWriter.Part(range: $0.range, name: "\(baseName)_\($0.label).bin")
        }

        guard confirmSegmentWrite(parts: parts, in: directory) else { return false }
        runSegmentWrite(parts: parts, from: storage, to: directory)
        return true
    }

    /// Save Segment…: writes the one piece under the click to a file — the
    /// ordinary save panel, one file. The panel's own replace confirmation covers
    /// the overwrite, so there is no separate one here. Returns whether the write
    /// actually started.
    private func savePiece(_ piece: Segment, of pane: PaneViewModel) -> Bool {
        guard pane.isOpen, let storage = pane.byteStorage else { return false }
        // The header's name, for the reason `saveAllPieces` gives.
        let baseName = pane.status.fileName

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName)_\(piece.label).bin"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        let url: URL?
        if let segmentSavePanel {
            url = segmentSavePanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return false }

        let part = SegmentWriter.Part(range: piece.range, name: url.lastPathComponent)
        runSegmentWrite(parts: [part], from: storage, to: url.deletingLastPathComponent())
        return true
    }

    /// Replace Segment from File…: reads the one piece under the click from a
    /// file (§21.6) — the ordinary open panel, one file, replacing the piece's
    /// bytes. The file must match the piece's length; a mismatch is refused with
    /// both sizes named, because making it an insert-and-shift is a decision, not
    /// a default. Returns whether the swap actually started.
    private func replacePiece(_ piece: Segment, of pane: PaneViewModel) -> Bool {
        guard pane.isOpen else { return false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        panel.message = "Choose the file whose bytes replace \(piece.label)."
        let url: URL?
        if let segmentOpenPanel {
            url = segmentOpenPanel(panel)
        } else {
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return false }

        do {
            try pane.replaceSegment(piece, withContentsOf: url)
            return true
        } catch let error as SegmentReplaceError {
            switch error {
            case .lengthMismatch(let pieceLength, let donorLength):
                presentAlert(
                    title: "File size does not match the segment",
                    message: "\(piece.label) is \(FilePaneView.friendlySize(pieceLength)) bytes, "
                        + "but the file is \(FilePaneView.friendlySize(donorLength)). "
                        + "The file must be exactly the same length to replace the piece."
                )
            }
            return false
        } catch {
            presentFileError("Replacing the segment failed.", error, url: url)
            return false
        }
    }

    /// The one confirmation before a Save All writes (§21.5): a preview of every
    /// part — `S0 → bios_S0.bin (4 MB)` — and, when any of the target files
    /// already exist, the names of the ones that would be replaced. Shown before
    /// anything is written.
    private func confirmSegmentWrite(parts: [SegmentWriter.Part], in directory: URL) -> Bool {
        let fileManager = FileManager.default
        // The parts are in file order (S0, S1, …), so the position is the label.
        let lines = parts.enumerated().map { index, part in
            "\(Segment.label(for: index)) → \(part.name) (\(FilePaneView.friendlySize(UInt64(part.range.count))))"
        }
        let existing = parts.filter {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.name).path)
        }
        let alert = NSAlert()
        alert.messageText = "Save \(parts.count) Segment\(parts.count == 1 ? "" : "s")?"
        var informative = lines.joined(separator: "\n")
        if !existing.isEmpty {
            informative += "\n\nThese files will be replaced:\n"
                + existing.map(\.name).joined(separator: "\n")
        }
        alert.informativeText = informative
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let segmentWriteConfirm {
            response = segmentWriteConfirm(alert)
        } else {
            response = Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)  // Cancel in tests
        }
        return response == .alertFirstButtonReturn
    }

    /// Runs the write off the main thread, with the name, progress and (×) in the
    /// active pane's status bar while it runs (§14.4). A new write cancels any
    /// in-flight one. The write is all or nothing (§21.5): a failure or a cancel
    /// publishes nothing and leaves the directory as it was.
    private func runSegmentWrite(parts: [SegmentWriter.Part], from storage: any ByteStorage,
                                 to directory: URL) {
        if let segmentWriteRunner {
            segmentWriteRunner(parts, storage, directory)
            return
        }
        segmentWriteTask?.cancel()
        segmentWriteOperation?.finish()
        let operation = BackgroundOperation(name: "Writing \(parts.count) segment\(parts.count == 1 ? "" : "s")…") { [weak self] in
            self?.segmentWriteTask?.cancel()
        }
        segmentWriteOperation = operation
        activeFilePane?.beginOperation(operation)
        segmentWriteTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SegmentWriter.write(
                        parts, from: storage, to: directory,
                        shouldCancel: { Task.isCancelled },
                        progress: { operation.report($0) }
                    )
                }.value
                operation.finish()
            } catch is CancellationError {
                operation.finish()
            } catch {
                operation.finish()
                self?.presentFileError("Saving segments failed.", error, url: directory)
            }
        }
    }

    /// The bytes on a bookmarked row of the ACTIVE pane, for the list to show
    /// where an unnamed bookmark's name would be (§20.5). Nil when the row is
    /// past that pane's end: a bookmark is an absolute address and stays in the
    /// list even where the file does not reach (§9). Read live, per row, so the
    /// list shows the pane's current content, edits included.
    private func bookmarkRowBytes(_ row: UInt64) -> [UInt8]? {
        let pane = activePane
        guard pane.isOpen, row < pane.fileSize, let storage = pane.byteStorage else { return nil }
        let length = Int(min(UInt64(HexLayout.bytesPerRow), pane.fileSize - row))
        return (try? storage.read(at: row, length: length)) ?? []
    }

    /// The jump itself (§10.1) — the same act whether the offset was typed or
    /// picked from the bookmark list.
    private func goTo(offset: UInt64) {
        let largerSize = max(windowModel.pane1.fileSize, windowModel.pane2.fileSize)
        if offset > largerSize {
            presentAlert(
                title: "Offset beyond end of file",
                message: "Offset \(String(format: "0x%X", offset)) is beyond the end of the file(s) (\(String(format: "0x%X", largerSize)) bytes). Moved to the end."
            )
        }
        let target = min(offset, largerSize)
        if mode == .comparison {
            // §10.1: move both panes; each clamps to its own EOF.
            windowModel.pane1.moveCaret(to: target)
            windowModel.pane2.moveCaret(to: target)
        } else {
            activePane.moveCaret(to: target)
        }
        // The row has to be where the user is looking, not wherever it happened
        // to be before the jump (§10.1).
        activeFilePane?.revealOffsetCentered(target)
        focusActiveHexView()
    }

    @objc func selectBlock() {
        let pane = activePane
        guard pane.isOpen else { return }
        let sheet = SelectBlockSheetController(fileSize: pane.fileSize) { [weak self] selection in
            pane.setSelection(selection)
            // §10.2: show the block's START mid-pane, the way the Find bar
            // centres a match — the block begins where the user looks.
            self?.activeFilePane?.revealOffsetCentered(selection.start)
        }
        presentAsSheet(sheet)
    }

    /// Edit > Find (Cmd+F): shows the non-modal Find bar at the top of the
    /// window (§11).
    @objc func findPattern() {
        let pane = activePane
        guard pane.isOpen else { return }
        showFindBar()
    }

    /// The longest selection that can become a find pattern (§11).
    ///
    /// A pattern is a thing to compare a file against, not a piece of the file:
    /// past a kilobyte the field holds three thousand characters of hex that
    /// nobody can read, correct or keep, and the command has stopped being
    /// "search for this". A Select All followed by ⌘E is the case this catches,
    /// and it is answered in words rather than by quietly searching for the
    /// first kilobyte of it — a truncated pattern would find places the user
    /// never asked about.
    static let maxSelectionFindBytes: UInt64 = 1024

    /// Edit > Use Selection for Find (⌘E): the selection becomes the pattern to
    /// search for, and that is all it does — the bar is deliberately **not**
    /// opened, no search is run, and the focus stays in the dump (§11).
    ///
    /// The column the selection was made in is the whole question. In the hex
    /// column the pattern is the bytes, written as a dump writes them; in the
    /// decoded-text column it is the text they read as — and where they read as
    /// no text at all, the bytes again, because a pattern of replacement
    /// characters finds nothing that is in the file. Both readings belong to
    /// `SelectionFindPattern`, which is pure and tested on its own.
    ///
    /// It says nothing while it works. The command is a preparation, run by a
    /// reader who is going on reading, and a plate over the dump for it would
    /// be the effect that ⌘E exists not to have — the field is where the answer
    /// is, for anyone who opens the bar to look.
    @objc func useSelectionForFind() {
        let pane = activePane
        guard pane.isOpen, let doc = pane.document else { return }
        let selection = doc.selection
        guard !selection.isEmpty else { return }
        guard selection.count <= Self.maxSelectionFindBytes else {
            showNotice(symbol: "exclamationmark.triangle", lines: [
                "Selection too long to search for",
                "Up to \(Self.maxSelectionFindBytes) bytes can be used as a find pattern.",
            ])
            return
        }
        guard let bytes = try? doc.read(at: selection.start, length: Int(selection.count)) else {
            return
        }
        // Where the caret was typing is where the selection was made (§7): the
        // hex column asks about bytes, the decoded-text column about text.
        let pattern = pane.inputRegion == .ascii
            ? SelectionFindPattern.forText(bytes)
            : SelectionFindPattern.forBytes(bytes)
        findBar.stage(pattern)
    }

    /// The pattern ⌘E loaded, for tests.
    var stagedFindPatternForTests: SelectionFindPattern? { findBar.stagedPatternForTests }

    /// The toolbar's Find button, which is a switch rather than a command: it
    /// is a thing on screen that is either pressed or not, and pressing it
    /// again is Done.
    ///
    /// ⌘F deliberately does not do this. On an open bar it means "take me to
    /// the field" — the keystroke a reader presses to get back to a pattern
    /// they are editing — and a ⌘F that closed the bar instead would make the
    /// second press undo the first.
    @objc func toggleFindBar() {
        let pane = activePane
        guard pane.isOpen else { return }
        if findBar.isHidden {
            showFindBar()
        } else {
            hideFindBar()
        }
    }

    /// ⌘F (§11). On a bar that is already open it focuses the field and selects
    /// what is in it — it does **not** prefill.
    ///
    /// Prefilling from the history belongs to *opening* the bar. Doing it on
    /// every ⌘F threw away the pattern the user had come back to fix: a search
    /// that found nothing records nothing (there is no encoding to record it
    /// under), so "the last search" was an older, successful one, and it
    /// replaced what was in the field.
    private func showFindBar() {
        let wasHidden = findBar.isHidden
        contentTopToView.isActive = false
        contentTopToFindBar.isActive = true
        findBar.isHidden = false
        // The bar lives in the hierarchy between shows, hidden. A layer colour
        // is resolved when it is assigned, and what reaches a view that nobody
        // is drawing is not something to rely on — so the bar re-resolves its
        // own as it appears, and is never the last theme's white bar over a
        // dark window.
        findBar.refreshThemeColors()
        syncFindBarToActivePane()
        view.layoutSubtreeIfNeeded()
        if wasHidden {
            findBar.prepareForShow()
        } else {
            findBar.focusForEditing()
        }
    }

    private func hideFindBar() {
        // A plate reporting a search outlives the bar it was about by four
        // seconds otherwise (§11).
        notices.dismiss()
        findBar.isHidden = true
        contentTopToFindBar.isActive = false
        contentTopToView.isActive = true
        cancelFind()
        endIndexing()
        // The highlighting ends with the bar, always: Done and Esc mean "I am
        // finished searching", and greys left on the dump after that claim a
        // search is still running. The *set* survives, so an open results panel
        // goes on listing the search that was actually run — its offsets are
        // still true — until an edit invalidates it or a new search replaces it
        // (§11).
        for pane in [windowModel.pane1, windowModel.pane2] {
            pane.endMatchHighlighting()
        }
        focusActiveHexView()
    }

    /// Escape pressed while the dump has the focus — not the pattern field — is
    /// the same "I am done searching" as Escape in the bar: it closes the bar
    /// and ends the highlighting, but the set, and a results panel listing it,
    /// survive, exactly as `Done` and the bar's own Escape leave them (§11).
    ///
    /// The pattern field is the one place Escape must NOT close the bar: there
    /// it is the field's own key (it clears the field, which ends the search as
    /// a text change). The field sits in the bar's subtree, so its Escape is
    /// consumed before it climbs to here; this only ever sees the Escape the
    /// dump lets through. With no bar up, Escape has nothing to dismiss, so it
    /// passes on untouched.
    override func cancelOperation(_ sender: Any?) {
        if !findBar.isHidden {
            hideFindBar()
        } else if fragments.expanded != nil {
            // Escape means "let me see what is behind this", so it folds the
            // panel into its pill rather than closing it: nothing is lost, and
            // the pill is right there to bring it back
            // (`Design/FRAGMENT_PANELS_PLAN.md`).
            fragments.collapse()
        } else {
            super.cancelOperation(sender)
        }
    }

    /// A press of Find Next / Find Previous (§11).
    ///
    /// There are two ways to find the next occurrence, and the model owns both:
    /// a **step** through a finished index (`MatchSet.step`), which is instant,
    /// and a **pass** of scans (`SmartSearch.firstMatch`), which is what runs
    /// when there is no index to step through yet. Each handles both directions
    /// and each says whether it had to come round the end of the file, so
    /// nothing here has to work that out — or work it out twice.
    private func runSearch(_ request: FindBarView.Request, direction: SearchDirection) {
        let pane = activePane
        guard pane.isOpen, let attempts = attempts(for: request) else { return }
        // A pass already looking for exactly this is the answer to this press.
        guard smartPassInFlight != attempts else { return }
        // A search already running here is stepped rather than started again —
        // including the one a Smart Search settled on, whose attempt is
        // usually not the first (the popup names it).
        if steppable(attempts, of: request)
            .contains(where: { pane.hasMatches(for: $0.pattern, folding: $0.folding) }) {
            stepMatch(direction: direction, in: pane)
            return
        }
        beginPass(attempts: attempts, direction: direction, goal: .showTheMatch, in: pane)
    }

    /// Which of the attempts a press may *step* through rather than scan for:
    /// all of them, or — where the user has named an encoding — only that one.
    ///
    /// Switching the popup to UTF-16 while standing on an ASCII match means
    /// "find this as UTF-16", not "the next ASCII one". A session in another
    /// encoding is no answer to a press that named this one, however well
    /// indexed it is (§11).
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
                findBar.reportNoUsablePattern()
                return nil
            }
            return attempts
        }
    }

    /// What a pass does once it knows which encoding to use.
    private enum SearchPassGoal {
        /// A press of Enter or ‹ ›: put the user on the match.
        case showTheMatch
        /// A press of the results button: list them, and leave the caret alone.
        case listTheMatches
    }

    /// Scans for the attempts in order until one of them finds something (§11).
    ///
    /// One entry point for every search that has to scan: a chosen encoding is
    /// a pass of one attempt, and Smart Search is a pass of several. The pass
    /// itself is the model's — the order, the two scans per attempt, the wrap
    /// and the progress accounting — and what is left here is what to do with
    /// its answer.
    ///
    /// The whole pass is one operation in the status bar, with its progress and
    /// its (×): a scan of the file is a wait worth being able to stop, and a
    /// wrong guess about an encoding costs one each (§14.4).
    private func beginPass(attempts: [SmartSearch.Attempt], direction: SearchDirection,
                           goal: SearchPassGoal, in pane: PaneViewModel) {
        guard let first = attempts.first, let storage = pane.document?.storage else { return }
        // Whatever a plate is saying is about the search before this one (§11).
        notices.dismiss()
        cancelFind()
        endIndexing()
        // A session that is looking rather than one that has found: the dump
        // greys nothing, the bar counts nothing, and the results panel says
        // "searching" instead of going on listing the pattern before this one.
        // It stands in the first attempt's name until an attempt wins, and it
        // is what makes a second press find a search already under way.
        pane.setMatches(MatchSet(pattern: first.pattern, folding: first.folding,
                                 extent: pane.fileSize, starts: [], indexedUpTo: 0))
        let operation = BackgroundOperation(name: "Searching…") { [weak self] in
            self?.cancelFind()
        }
        findOperation = operation
        smartPassInFlight = attempts
        filePaneView(for: pane)?.beginOperation(operation)
        let anchor = searchAnchor(in: pane, direction: direction)
        let chunkSize = Self.searchChunkSize
        findTask = Task { [weak self] in
            guard let self else { return }
            let scan = Task.detached(priority: .userInitiated) {
                try? SmartSearch.firstMatch(among: attempts, in: storage, from: anchor,
                                            direction: direction, chunkSize: chunkSize,
                                            shouldCancel: { Task.isCancelled },
                                            progress: { operation.report($0) })
            }
            let outcome = await withTaskCancellationHandler(
                operation: { await scan.value },
                onCancel: { scan.cancel() }
            )
            operation.finish()
            self.smartPassInFlight = nil
            guard !Task.isCancelled, pane.isOpen else { return }
            switch outcome {
            case .found(let attempt, let range, let wrapped):
                self.adopt(attempt: attempt, foundAt: range, wrapped: wrapped,
                           direction: direction, goal: goal, in: pane)
            default:
                self.reportNothingFound(attempts: attempts, goal: goal, in: pane)
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

    /// Makes the attempt that found something *the* search: the session is its
    /// pattern's from here on, the bar's popup says which encoding it was, and
    /// the index of every other occurrence starts behind it (§11).
    private func adopt(attempt: SmartSearch.Attempt, foundAt range: Range<UInt64>,
                       wrapped: Bool, direction: SearchDirection, goal: SearchPassGoal,
                       in pane: PaneViewModel) {
        pane.setMatches(MatchSet(pattern: attempt.pattern, folding: attempt.folding,
                                 extent: pane.fileSize, starts: [], indexedUpTo: 0))
        findBar.adopt(encoding: attempt.encoding)
        // A match in hand is the strongest answer there is, so the search goes
        // into the history here (§11).
        findBar.recordFoundSearch(encoding: attempt.encoding)
        switch goal {
        case .showTheMatch:
            show(match: range, in: pane)
            if wrapped { showWrapNotice(direction: direction) }
        case .listTheMatches:
            // The results button is not a Find Next: the caret stays where it
            // is, and the panel opens on the index as it fills (§11).
            presentSearchResults(for: pane)
        }
        startIndexing(pattern: attempt.pattern, folding: attempt.folding, in: pane)
        handOffFocusAfterFind()
    }

    /// A pass where every attempt came back empty (§11).
    ///
    /// The session becomes a *finished* search with no matches, so the bar says
    /// `Not found` and the panel `No matches.` — both true of every attempt.
    /// Where there was a choice of encodings, a plate says which ones were
    /// tried, because that answer is about the pass and not about any one of
    /// its scans.
    private func reportNothingFound(attempts: [SmartSearch.Attempt], goal: SearchPassGoal,
                                    in pane: PaneViewModel) {
        if let last = attempts.last {
            pane.setMatches(MatchSet(pattern: last.pattern, folding: last.folding,
                                     extent: pane.fileSize, starts: []))
        }
        // The button opens the panel whatever the search has to say (§11) —
        // here, that nothing came back.
        if goal == .listTheMatches { presentSearchResults(for: pane) }
        if attempts.count > 1 {
            showNotice(symbol: "wand.and.sparkles",
                       lines: ["Smart search."]
                           + attempts.map { "\($0.label) — no results." })
        }
        handOffFocusAfterFind()
    }
    /// Starts a search's index without going anywhere: what the results button
    /// asks for. Pressing it is not a Find Next, so the caret stays where it is
    /// and the panel opens on the rows as they arrive (§11).
    /// An index that turned up matches is a search that found something, so it
    /// is remembered (§11).
    ///
    /// This is the results button's own case: with one thing to look for it
    /// starts an index and no first-hit scan, so nothing else is in a position
    /// to say the search succeeded. A no-op once the search has been recorded,
    /// and for a pattern that occurs nowhere it never fires at all — which is
    /// the point.
    private func noteIndexFound(_ pattern: SearchPattern, in pane: PaneViewModel) {
        guard pane.matchSet?.isEmpty == false else { return }
        findBar.recordFoundSearch(encoding: pattern.encoding)
    }

    private func beginIndexing(pattern: SearchPattern, folding: CaseFolding,
                               in pane: PaneViewModel) {
        notices.dismiss()
        cancelFind()
        // An index covering nothing yet, so the session exists from this
        // instant: a second press finds a search already under way and steps
        // within it instead of starting another.
        pane.setMatches(MatchSet(pattern: pattern, folding: folding,
                                 extent: pane.fileSize, starts: [], indexedUpTo: 0))
        startIndexing(pattern: pattern, folding: folding, in: pane)
    }

    /// Builds the index of every occurrence behind the answer, publishing it as
    /// it fills (§11).
    ///
    /// Each instalment is a stretch of file the scan has covered: the greys for
    /// it are exact, so the dump can paint them (and repaints only the rows the
    /// user is actually looking at), the panel lists them, and the map marks
    /// them. What waits for the end is everything that is about the *whole*
    /// file — the count, the wrap, an ordinal, and stepping by index.
    private func startIndexing(pattern: SearchPattern, folding: CaseFolding,
                               in pane: PaneViewModel) {
        endIndexing()
        guard let storage = pane.document?.storage else { return }
        // The one operation a search shows (§14.4). The first-hit scan runs
        // without one: it is a millisecond on a dump this side of a gigabyte,
        // and where it is not, this covers the same ground and reports the same
        // progress. Cancelling it stops both.
        let operation = BackgroundOperation(name: "Searching…") { [weak self] in
            self?.indexTask?.cancel()
            self?.findTask?.cancel()
        }
        indexOperation = operation
        filePaneView(for: pane)?.beginOperation(operation)
        let extent = storage.size
        let chunkSize = Self.searchChunkSize
        indexTask = Task { [weak self] in
            let stream = SearchEngine.matchStartsStream(
                pattern: pattern.bytes, in: storage, folding: folding, chunkSize: chunkSize,
                shouldCancel: { Task.isCancelled },
                progress: { operation.report($0) })
            var builder = MatchSetBuilder(pattern: pattern, folding: folding, extent: extent)
            var publishedUpTo: UInt64 = 0
            var lastPublish = Date.distantPast
            do {
                for try await batch in stream {
                    builder.add(batch.starts)
                    // On a cadence, not per instalment: a common byte yields
                    // thousands of them, and each publish copies the index's
                    // representation.
                    guard Date().timeIntervalSince(lastPublish) >= Self.indexPublishInterval,
                          batch.scannedUpTo > publishedUpTo else { continue }
                    let filled = publishedUpTo..<batch.scannedUpTo
                    let snapshot = builder.snapshot(indexedUpTo: batch.scannedUpTo)
                    publishedUpTo = batch.scannedUpTo
                    lastPublish = Date()
                    await MainActor.run { [weak self] in
                        pane.fillMatches(snapshot, filled: filled)
                        self?.noteIndexFound(pattern, in: pane)
                    }
                }
            } catch {
                // A failed read leaves the index where it got to: the search
                // itself already answered, and the greys that landed are true.
            }
            let complete = !Task.isCancelled
            await MainActor.run { [weak self] in
                operation.finish()
                self?.indexOperation = nil
                self?.indexTask = nil
                guard complete, pane.isOpen else { return }
                pane.fillMatches(builder.finish(), filled: publishedUpTo..<max(publishedUpTo, extent))
                self?.noteIndexFound(pattern, in: pane)
            }
        }
    }

    /// Stops an index in flight — a new search, an edit, a closed bar.
    private func endIndexing() {
        indexTask?.cancel()
        indexTask = nil
        indexOperation?.finish()
        indexOperation = nil
    }

    /// How often a half-built index is published. Often enough that the greys
    /// follow the scan visibly, rarely enough that the copy each publish costs
    /// stays a rounding error next to the scan itself.
    static let indexPublishInterval: TimeInterval = 0.1

    /// Moves to the next or previous match (§11).
    ///
    /// Answered from the **index** wherever the index can answer: that is a
    /// rank/select step, so it is instant, it leaves the greys and the count
    /// alone, and it costs the file nothing. `MatchSet.step` owns both
    /// directions and the wrap.
    ///
    /// A half-built index answers for the part of the file it has covered —
    /// every match below `indexedUpTo` is exact — so stepping through the
    /// beginning of a big dump works while the rest of it is still being
    /// indexed. Only a step it *cannot* answer is scanned for: nothing found
    /// ahead in what is covered, or a set past the ceiling where positions
    /// were never kept.
    private func stepMatch(direction: SearchDirection, in pane: PaneViewModel) {
        guard let set = pane.matchSet else { return }
        let anchor = searchAnchor(in: pane, direction: direction)
        if set.isHighlightable, let step = set.step(direction, from: anchor),
           // A wrap is only true when the index is finished: while it is still
           // filling, "nothing ahead" may mean "not found yet".
           !step.wrapped || set.isComplete {
            land(step, direction: direction, in: pane)
            return
        }
        // A finished index with nothing in it has nothing to step to, and the
        // bar already says so.
        guard !set.isComplete || !set.isHighlightable else { return }
        scanForStep(in: pane, direction: direction)
    }

    /// Puts the user on a step the index answered.
    private func land(_ step: MatchSet.Step, direction: SearchDirection,
                      in pane: PaneViewModel) {
        pane.select(range: step.range)
        // A step is a search being shown again, which it may not have been: the
        // set outlives its highlighting, so `Done` then Enter steps through the
        // set the pane still holds and lights it back up (§11).
        pane.highlightMatches(current: step.index)
        // A match already on screen moves the highlight, not the page; one off
        // screen is centred. The caret's own rule (§10.4) — and the reason a
        // walk through a cluster of matches no longer jerks the view a row at a
        // time.
        filePaneView(for: pane)?.revealSelectionCenteredIfNeeded()
        // The pop answers the key press — including when a lone match wraps
        // onto itself, where no index changed (§11). Started *after* the
        // reveal, so its first frame is never drawn into a pass a scroll is
        // still rearranging.
        filePaneView(for: pane)?.bounceFindIndicator()
        // Said after the move, not instead of it: the plate is the answer and
        // this is the footnote (§11).
        if step.wrapped { showWrapNotice(direction: direction) }
        handOffFocusAfterFind()
    }

    /// A step the index could not answer: one scan for the search's own
    /// pattern, wrapping, and nothing else touched (§11).
    ///
    /// Deliberately *not* a pass. A pass activates a search: it replaces the
    /// session with one that is still looking, which puts every grey out and
    /// back, and it stops the index being built. Navigating inside a search
    /// that already exists must do neither — the index still filling behind
    /// this press is the same search's, and killing it on every ‹ › meant a
    /// common pattern in a large dump never finished indexing and every press
    /// looked like a fresh search.
    private func scanForStep(in pane: PaneViewModel, direction: SearchDirection) {
        guard let set = pane.matchSet, let storage = pane.document?.storage else { return }
        let attempt = SmartSearch.Attempt(pattern: set.pattern, folding: set.folding,
                                          encodings: [set.pattern.encoding])
        // Only the navigation task: `endIndexing()` is not called here, and
        // that is the point.
        cancelFind()
        let operation = BackgroundOperation(name: "Searching…") { [weak self] in
            self?.cancelFind()
        }
        findOperation = operation
        filePaneView(for: pane)?.beginOperation(operation)
        let anchor = searchAnchor(in: pane, direction: direction)
        let chunkSize = Self.searchChunkSize
        findTask = Task { [weak self] in
            guard let self else { return }
            let scan = Task.detached(priority: .userInitiated) {
                try? SmartSearch.firstMatch(of: attempt, in: storage, from: anchor,
                                            direction: direction, chunkSize: chunkSize,
                                            shouldCancel: { Task.isCancelled },
                                            progress: { operation.report($0) })
            }
            let outcome = await withTaskCancellationHandler(
                operation: { await scan.value },
                onCancel: { scan.cancel() }
            )
            operation.finish()
            guard !Task.isCancelled, pane.isOpen else { return }
            guard case .found(_, let range, let wrapped) = outcome else {
                self.showFindMessage("Not found.")
                return
            }
            self.show(match: range, in: pane)
            if wrapped { self.showWrapNotice(direction: direction) }
            self.handOffFocusAfterFind()
        }
    }


    /// Puts the user on a match a scan found: selected, revealed, and under the
    /// plate — the answer looks the same whether or not the index behind it
    /// exists yet (§11).
    private func show(match range: Range<UInt64>, in pane: PaneViewModel) {
        pane.select(range: range)
        pane.highlightMatches(onMatch: range)
        filePaneView(for: pane)?.revealSelectionCenteredIfNeeded()
        filePaneView(for: pane)?.bounceFindIndicator()
    }

    /// A search launched from the find bar leaves focus in the pattern field so
    /// a subsequent Enter re-searches; only when the bar is hidden does the
    /// search hand focus to the hex view.
    private func handOffFocusAfterFind() {
        if findBar.isHidden {
            focusActiveHexView()
        } else {
            findBar.focusPatternField()
        }
    }

    /// Hands the Find bar the active pane's session: "3 of 128", "Not found",
    /// or nothing at all (§11). Driven by every change to the set or the
    /// current match, and by the bar opening.
    /// Something about how the search *looks* changed — a set arrived or went,
    /// the highlighting came or ended, the indicator stepped. The count is
    /// re-read and the map re-marked; the dump repaints itself, through the
    /// pane's own view (§11).
    ///
    /// Everything here is skipped while the minimap panel is closed: it paints
    /// nothing, and a press of ‹ › used to invalidate its cells and rebuild its
    /// overlay regardless.
    ///
    /// `surface` is the map to re-mark — the tab's by default, or a fragment's
    /// own when the search lives in a panel, so a panel's matches never re-mark
    /// the dump behind it.
    private func searchAppearanceChanged(on surface: DocumentSurface? = nil) {
        syncFindBarToActivePane()
        let map = surface ?? self.surface
        guard map.minimapPanelVisible else { return }
        // No byte range describes a set arriving or a plate moving to another
        // part of the file, so in detail mode every cell it draws is suspect.
        map.minimapView.invalidateCells()
        map.minimap.scheduleMatchSync()
    }

    /// Points the Find bar at the active pane (§11).
    ///
    /// The bar is one strip serving whichever pane is in front, so everything
    /// on it that describes a search — the count, and whether that pane's
    /// results panel is up — is read off that pane, here, in one place. Called
    /// wherever the active pane changes, wherever its search changes, and when
    /// the bar opens; every reading is derived on the spot rather than
    /// remembered, so there is no second copy to fall behind.
    ///
    /// That is what the results button had done: it kept whatever the last
    /// press had set, so moving to a pane whose list was already up left the
    /// bar offering to *show* what was on screen — and pressing it closed the
    /// list. A per-reading refresher would have fixed that one button and left
    /// the next reading to be forgotten in the same places.
    private func syncFindBarToActivePane() {
        let pane = activePane
        findBar.apply(FindBarView.PaneContext(
            count: FindCount.reading(of: pane.highlightedMatchSet,
                                     current: pane.currentMatchIndex),
            resultsShown: filePaneView(for: pane)?.searchResultsPanelVisible == true))
    }

    /// Drops a pane's match set: the bytes under it moved, so every offset in it
    /// is a guess. The greys go rather than shift — a grey in the wrong place is
    /// worse than no grey — and the next press of Find Next scans afresh.
    ///
    /// An overwrite could in principle be patched in place (`MatchSet.splice`),
    /// which is what the plan's edit stage is for; until then any edit ends the
    /// session — and takes an open results panel with it, since the pane's view
    /// follows the set it is listing (§11).
    private func invalidateMatches(in pane: PaneViewModel?) {
        // An index still being built is being built over bytes that just
        // moved, so it stops rather than finishing into a file it no longer
        // describes (§11).
        endIndexing()
        pane?.clearMatches()
    }

    /// The Find bar's results button (§11): shows or hides the pane's results
    /// panel.
    ///
    /// It is no longer a search. Activating a search already started the index
    /// — the same one that feeds the dump's highlighting — so this presents
    /// what that index holds, and goes on presenting it as the index fills.
    /// When the field holds a pattern nothing has looked for yet, the search
    /// starts here and the panel opens on it.
    private func toggleSearchResults(_ request: FindBarView.Request) {
        let pane = activePane
        guard pane.isOpen, let paneView = filePaneView(for: pane) else { return }
        if paneView.searchResultsPanelVisible {
            paneView.hideSearchResults()
            syncFindBarToActivePane()
            return
        }
        // The button also *activates* the pattern in the field: a pattern
        // typed but not yet searched by Enter or ‹ › is searched here, so the
        // panel is never a list of the previous pattern's matches (§11).
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
            beginIndexing(pattern: attempts[0].pattern, folding: attempts[0].folding, in: pane)
            findBar.adopt(encoding: attempts[0].encoding)
            presentSearchResults(for: pane)
            return
        }
        // Which encoding to list is the same question Smart Search answers for
        // a jump, so it is answered the same way — and the panel opens on the
        // encoding that turned out to occur (§11).
        beginPass(attempts: attempts, direction: .forward, goal: .listTheMatches, in: pane)
    }

    /// Opens the pane's results panel on its current set: the matches as rows,
    /// or — past the listing limit — the count and the reason there are no rows
    /// (§11).
    ///
    /// The button opens the panel, whatever the search has to say. One still
    /// running opens on what it has and fills as the index does; one that found
    /// nothing opens saying so, where the rows would have been. Refusing to
    /// open would leave the press with no effect at all, which reads as a
    /// broken button.
    private func presentSearchResults(for pane: PaneViewModel) {
        guard let paneView = filePaneView(for: pane), pane.matchSet != nil else { return }
        // Nothing is handed over: the panel lists the pane's own set, and stays
        // level with it from then on — a new search rewrites its rows, and an
        // invalidation takes it down (§11).
        paneView.showSearchResults()
        syncFindBarToActivePane()
    }

    /// Says that a search came round the end of the file: one large glyph
    /// turning the way the search was going, and nothing to read (§11).
    ///
    /// Wrapping is the one thing about a step that the dump cannot show. The
    /// plate moves and the page moves, exactly as they do for the next match
    /// in line, so without this the difference between "the next one" and "the
    /// first one, again" is invisible. Turning back to the top of a file is
    /// what a circular arrow means everywhere else on the platform.
    func showWrapNotice(direction: SearchDirection) {
        notices.show(glyph: direction == .forward
            ? Self.wrapForwardGlyph : Self.wrapBackwardGlyph)
    }

    /// The plate a wrapped search shows: an arrow round a capsule, whose head
    /// says which end the search came round — top right for one that ran off
    /// the end, bottom left for one that ran off the start. The plain circular
    /// arrows stand in on a macOS that does not have them: the glyphs arrived
    /// in SF Symbols 6, and the app runs on 14.
    static let wrapForwardGlyph = symbolName(
        "arrow.trianglehead.topright.capsulepath.clockwise", or: "arrow.clockwise")
    static let wrapBackwardGlyph = symbolName(
        "arrow.trianglehead.bottomleft.capsulepath.clockwise", or: "arrow.counterclockwise")

    /// `preferred` where this system draws it, `fallback` where it does not.
    private static func symbolName(_ preferred: String, or fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil
            ? preferred : fallback
    }

    /// Shows a transient notice over the window (§11) — a report about an
    /// operation the window ran, rather than about the place the user is
    /// looking. Where it goes and how it comes and goes is the presenter's, so
    /// every plate of the kind behaves the same.
    ///
    /// It belongs to the window rather than to a pane: in comparison mode a
    /// pane-owned plate would have to pick which pane the answer was about.
    func showNotice(symbol: String, lines: [String]) {
        notices.show(symbol: symbol, lines: lines)
    }

    /// The window's notices, one at a time.
    private(set) lazy var notices = TransientNoticePresenter(host: view)

    /// The notice on screen, if any — for tests.
    var transientNotice: TransientNoticeView? { notices.current }

    private func showFindMessage(_ message: String) {
        NSSound.beep()
        activeFilePane?.showTransientMessage(message)
    }

    /// Keeps the pattern in the Find bar under a name (§11).
    ///
    /// The sheet does the asking and the checking — including the one refusal
    /// that matters, the same search kept twice — so what is left here is the
    /// keeping itself and saying it happened, in the same plate the searches
    /// answer in.
    private func askToKeepPattern(_ entry: SearchPatternEntry) {
        let sheet = NamePatternSheetController(entry: entry) { [weak self] kept in
            guard FavoritePatternStore.add(kept) else { return }
            self?.showNotice(symbol: "star.fill", lines: ["Added to Favorites", kept.name])
        }
        presentAsSheet(sheet)
    }

    // MARK: - Test mode

    /// True when the app runs inside the XCTest runner (a test host). A modal
    /// alert has no human to click it there, so every blocking prompt must
    /// short-circuit to a conservative default — otherwise a stray prompt (the
    /// file-changed Reload/Keep alert, an error) hangs the test suite forever.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    /// Answers alerts in place of the user, so a test can choose a specific
    /// button rather than living with the call site's default — needed wherever
    /// the buttons do three different things and each has to be covered.
    ///
    /// Consulted only under test, so it can never intercept a real alert.
    static var modalResponder: ((NSAlert) -> NSApplication.ModalResponse)?

    /// Presents `alert` modally, or returns `defaultInTest` immediately when
    /// running under XCTest. Callers pick a response that leaves the document
    /// untouched (Cancel / Keep Current Contents) so a stray alert can never
    /// discard edits or reload a file mid-test. Exposed (internal) so a test
    /// can pin the suppression contract.
    @discardableResult
    static func presentModal(_ alert: NSAlert, defaultInTest: NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        guard !isRunningTests else { return modalResponder?(alert) ?? defaultInTest }
        return alert.runModal()
    }

    // MARK: - Alerts

    @discardableResult
    private func confirmAlert(title: String, message: String, confirmTitle: String,
                              destructive: Bool = false,
                              suppressible: Bool = false) -> NSApplication.ModalResponse {
        // A suppressible confirmation is one of the §7.2 shifting-edit warnings.
        // With the warnings switched off it does not appear at all and the edit
        // proceeds: the user has said, once, that they know what these edits do.
        if suppressible, !EditingSettings.warnsBeforeShiftingEdits {
            return .alertFirstButtonReturn
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if destructive {
            alert.buttons.first?.hasDestructiveAction = true
        }
        if suppressible {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
        }
        let response = Self.presentModal(alert, defaultInTest: .alertSecondButtonReturn)  // Cancel in tests
        if suppressible { Self.applySuppression(of: alert) }
        return response
    }

    /// Honours an alert's "Do not ask again" checkbox by switching the
    /// shifting-edit warnings off — the same switch as Settings ▸ Editing.
    /// Whichever button dismissed the alert: ticking the box and then cancelling
    /// still means "stop asking me". Internal so a test can pin the wiring,
    /// which is otherwise unreachable (a test never shows the alert).
    static func applySuppression(of alert: NSAlert) {
        guard alert.suppressionButton?.state == .on else { return }
        EditingSettings.set(warnsBeforeShiftingEdits: false)
    }

    @discardableResult
    private func confirmSaveDiscardCancel() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Do you want to save the changes you made?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        return Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn)  // Cancel in tests
    }

    /// The title of the last informational alert. A modal alert is
    /// short-circuited under XCTest (see `presentModal`), so this is the only
    /// trace it leaves — and some of it is behaviour worth pinning, like the
    /// past-EOF warning a Go To leaves behind (§10.1).
    private(set) var lastAlertTitle: String?

    private func presentAlert(title: String, message: String) {
        lastAlertTitle = title
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        Self.presentModal(alert, defaultInTest: .alertFirstButtonReturn)  // OK in tests, result ignored
    }

    /// The same, as a sheet on `window` — for what is said after work that
    /// changed the file. A modal alert runs its own loop, and everything the
    /// change set in motion on the main actor waits behind it: the UEFI tree,
    /// invalidated by the write, sat half rebuilt — rows with no names — until
    /// the alert was dismissed. A sheet lets the panels finish while it is up.
    private func presentSheetAlert(title: String, message: String, on window: NSWindow?) {
        guard !Self.isRunningTests, let window else {
            presentAlert(title: title, message: message)
            return
        }
        lastAlertTitle = title
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        Self.presentModal(alert, defaultInTest: .alertFirstButtonReturn)  // OK in tests, result ignored
    }

    /// Shows a file-operation error, upgrading sandbox/permission denials to a
    /// clear "grant access" prompt (§16 sandbox access denied).
    func presentFileError(_ title: String, _ error: Error, url: URL?) {
        if isSandboxAccessDenied(error) {
            let name = url?.lastPathComponent ?? "the file"
            presentAlert(title: "Access denied",
                         message: "ByteRipper cannot access “\(name)”. Choose it again with File > Open to grant access.")
        } else {
            presentError(title, error)
        }
    }

    private func isSandboxAccessDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == EACCES {
            return true
        }
        return false
    }

    /// How much of the file one scan step reads (§11). The default is the
    /// engine's own; a `var` so a test can make a search take a while without
    /// writing a gigabyte to disk to do it — the property under test is that a
    /// long scan keeps the main thread responsive, and chunk count is what makes
    /// a scan long.
    static var searchChunkSize = SearchEngine.defaultChunkSize

    // MARK: - Zoom-to-fit (§3.1)

    /// The content width the launch window fits to (§3.1): **one** hex grid at
    /// the saved word size, whatever the saved pane arrangement. The window
    /// opens empty, and it opens on one file far more often than on two, so
    /// fitting two grids would make every single-file session start too wide;
    /// opening a second file is what asks for the extra width, and Window > Zoom
    /// gives it from the real content. No file is open yet at launch, so the
    /// offset column uses its default width. The window controller uses this for
    /// the launch frame.
    ///
    /// Never narrower than the toolbar, though: see `toolbarFitWidth`.
    static func launchContentWidth() -> CGFloat {
        let font = AppearanceSettings.font()
        let charWidth = AppearanceSettings.charWidth(for: font)
        let layout = HexLayout(charWidth: charWidth, rowHeight: 0, wordSize: WordSize.current.rawValue)
        return max(layout.contentWidth + FilePaneView.contentFitSlack, toolbarFitWidth)
    }

    /// The width the toolbar needs before AppKit starts moving its trailing
    /// items into the overflow menu: both groups, the difference block included
    /// (§24.4). A floor under the launch width — a window that opens with its
    /// own minimap toggle already hidden behind a chevron reads as a bug, and a
    /// large word size makes the hex grid narrow enough for that to happen.
    ///
    /// Measured, not computed: the items' widths are AppKit's, and they differ
    /// between releases. 600 pt clears the measured threshold (570 pt on macOS
    /// 26, less on 14, where the toolbar metrics are tighter) with a margin.
    static let toolbarFitWidth: CGFloat = 600

    /// Ideal content width the window should be when zoomed (double-click on the
    /// title bar / Window > Zoom): the hex grid width for a single pane, or
    /// both grids plus the splitter divider for a left/right comparison. A
    /// stacked comparison keeps the wider of the two panes' grids.
    private func standardContentWidth() -> CGFloat {
        switch mode {
        case .singleFile:
            return activeFilePane?.contentFitWidth ?? 0
        case .comparison:
            guard let comparisonView else { return 0 }
            let w1 = comparisonView.paneView1.contentFitWidth
            let w2 = comparisonView.paneView2.contentFitWidth
            // Same source of truth as ComparisonView's layout toggle (§3.3).
            let isVertical = LayoutSettings.isVertical
            return isVertical ? w1 + w2 + comparisonView.splitView.dividerThickness : max(w1, w2)
        case .empty:
            return 0
        }
    }

    /// What the tool panel claims of a zoomed window's content width: its own
    /// width plus the divider, or nothing at all when no tool-module is open
    /// (§3.1, `Design/TOOL_MODULES_PLAN.md`).
    ///
    /// The width it *has*, not the width it would open at: zoom fits the window
    /// around what is on screen, and the user may well have dragged the panel
    /// wider than the tool-module asked for. Before the first layout the
    /// divider has no position to read, so the width the panel will open at
    /// stands in — which is what it is about to become.
    private func toolPanelFitWidth() -> CGFloat {
        guard tools.isPanelVisible else { return 0 }
        let live = toolPanelWidth()
        let width = live > 0
            ? live
            : (tools.activeModule.map { tools.preferredWidth(for: $0) } ?? 0)
        guard width > 0 else { return 0 }
        return width + panelSplit.dividerThickness
    }

    /// Ideal content height the window should be when zoomed (double-click on
    /// the title bar / Window > Zoom): the taller pane's full hex content plus
    /// its header and status bar — the height needed to show the biggest loaded
    /// file without scrolling. The empty state has no content, so the default
    /// zoom frame is kept.
    private func standardContentHeight() -> CGFloat {
        switch mode {
        case .singleFile:
            return activeFilePane?.contentFitHeight ?? 0
        case .comparison:
            guard let comparisonView else { return 0 }
            return max(comparisonView.paneView1.contentFitHeight,
                       comparisonView.paneView2.contentFitHeight)
        case .empty:
            return 0
        }
    }
}

// MARK: - Window closing (§3.6)

extension MainViewController: NSWindowDelegate {
    /// Double-click on the title bar / Window > Zoom sizes the window to the
    /// hex content instead of the default zoom-to-max: the width fits the hex
    /// grid(s), and the height stretches to show the taller loaded file's hex
    /// grid without scrolling — both capped at the screen's visible size when
    /// the content is larger (§3.1). The top edge stays put so the window grows
    /// or shrinks from the bottom. In the empty state there is no hex content,
    /// so the default zoom frame is kept.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let contentWidth = standardContentWidth()
        let contentHeight = standardContentHeight()
        guard contentWidth > 0, contentHeight > 0 else { return defaultFrame }

        // A visible minimap panel shares the content area, so the fitted window
        // must make room for it on top of the hex grids: the hex panes keep
        // their fitted width and the panel takes its preferred width (plus the
        // divider) beside them. A hidden panel adds nothing.
        let minimapWidth = surface.minimapPanelVisible
            ? minimapPreferredPanelWidth + panelSplit.dividerThickness
            : 0
        // The tool panel is the same claim on the leading edge
        // (`Design/TOOL_MODULES_PLAN.md`), so it is added the same way — the
        // fit is about the whole content area, and a panel left out of it is a
        // window that zooms to a width the dump does not actually get.
        let fitWidth = contentWidth + minimapWidth + toolPanelFitWidth()

        var frame = window.frame
        let oldTop = frame.origin.y + frame.height
        let screen = window.screen ?? NSScreen.main
        // Convert the needed content height to a window-frame height (adds the
        // title bar, the only chrome outside the pane itself).
        let frameHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: contentHeight)).height
        frame.size.width = min(fitWidth, screen?.visibleFrame.width ?? fitWidth)
        frame.size.height = min(frameHeight, screen?.visibleFrame.height ?? frameHeight)
        // Anchor the top edge and keep the window fully on the visible screen.
        frame.origin.y = oldTop - frame.size.height
        if let screen {
            frame.origin.y = min(max(frame.origin.y, screen.visibleFrame.minY),
                                 screen.visibleFrame.maxY - frame.size.height)
        }
        return frame
    }

    /// Combined dirty prompt on window close: list every modified file, offer
    /// Save / Don't Save / Cancel. Aborts the close when a save fails so no
    /// change is ever lost silently.
    ///
    /// The panels come first, and each is asked about on its own. They are
    /// documents too — a part holds bytes that exist nowhere else until they
    /// are put back — but they are not files, so they cannot be listed among
    /// the files here and they are not answered by one Save. Closing the
    /// window used to take them without a word.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // True while this call is still on the stack: a tab that can answer
        // everything on the spot is answered here, rather than by closing the
        // window from inside its own delegate callback.
        var inThisCall = true
        var answer: Bool?
        confirmClose { [weak sender] agreed in
            answer = agreed
            if !inThisCall, agreed { sender?.close() }
        }
        inThisCall = false
        // Nothing yet means an answer went to a sheet: the window stays until
        // that sheet comes back.
        return answer ?? false
    }

    /// How many documents of this tab closing it would ask about: its modified
    /// files, and the parts holding something a close would lose.
    ///
    /// Counted so that quitting can say how much is at stake before it starts
    /// asking — the reader deciding whether to go through four questions wants
    /// to know there are four.
    var unsavedDocumentCount: Int {
        let files = [windowModel.pane1, windowModel.pane2]
            .filter { $0.isOpen && $0.status.isDirty }
            .count
        return files + fragments.dock.panels.filter(fragmentHasSomethingToLose).count
    }

    /// Everything the tab has to ask before it can go: the parts it holds,
    /// then its files. `done(true)` when there is nothing left in the way,
    /// `done(false)` when the reader said no.
    ///
    /// `done` does not run at all where an answer went to a sheet that was then
    /// abandoned — a Save As backed out of — which leaves whatever was waiting
    /// on it waiting, and the tab where it is.
    ///
    /// Asked in this shape, rather than as a Bool, because quitting asks it of
    /// every window in turn and a window may take a sheet to answer.
    func confirmClose(then done: @escaping (Bool) -> Void) {
        closeFragmentsHoldingSomething { [weak self] in
            guard let self else {
                done(false)
                return
            }
            self.confirmClosingFiles(then: done)
        }
    }

    private func confirmClosingFiles(then done: @escaping (Bool) -> Void) {
        let panes = [windowModel.pane1, windowModel.pane2]
        let dirty = panes.filter { $0.isOpen && $0.status.isDirty }
        guard !dirty.isEmpty else {
            done(true)
            return
        }

        let names = dirty.map { "“\($0.status.fileName)”" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "The following files have unsaved changes: \(names)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch Self.presentModal(alert, defaultInTest: .alertThirdButtonReturn) {  // Cancel in tests (abort close)
        case .alertFirstButtonReturn:
            // Untitled panes have no file yet, so their "Save" runs a Save As
            // sheet; the answer comes once every pane is on disk. When every
            // save can happen inline, it comes right away.
            if dirty.contains(where: { $0.isUntitled }) {
                saveAllThen(dirty, then: { done(true) }, onCancelled: { done(false) })
                return
            }
            for pane in dirty {
                do {
                    try pane.save()
                } catch {
                    presentFileError("Could not save “\(pane.status.fileName)”.", error, url: pane.document?.url)
                    done(false)
                    return
                }
            }
            done(true)
        case .alertSecondButtonReturn:
            done(true)
        default:
            done(false)
        }
    }
}

// MARK: - Toolbar validation

extension MainViewController: NSToolbarItemValidation {
    /// Asks AppKit to revalidate the toolbar now instead of on its own idle
    /// schedule. Called wherever something a toolbar item reports has changed:
    /// enablement, and the state the stateful items show (§24).
    func revalidateToolbar() {
        viewIfLoaded?.window?.toolbar?.validateVisibleItems()
    }

    /// The toolbar's items follow the menu items they mirror (§10.3, §24), and
    /// the word-size control, which carries a state, is pushed to here.
    ///
    /// Pushing `isEnabled` onto the items from our own state does not work:
    /// AppKit revalidates every visible item on each run-loop pass, and the
    /// default validation sets the state back to "the target responds to the
    /// action" — always true here. The state has to be answered where validation
    /// asks for it. That makes this the natural place for the state a control
    /// displays as well, the way `validateMenuItem` sets the checkmarks.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(nextDifference):
            return windowPanesAreReachable && diffNavigationState.nextDifference
        case #selector(previousDifference):
            return windowPanesAreReachable && diffNavigationState.previousDifference
        case #selector(goToPosition),
             #selector(findPattern),
             #selector(toggleFindBar),
             #selector(showSegments):
            // The document commands need a dump to act on, exactly like the menu
            // items they mirror (§24.1).
            return activePane.isOpen
        case #selector(activateTool(_:)):
            // The pull-down's first row is what it displays, so the name of the
            // tool-module in force is written there rather than selected
            // (Design/TOOL_MODULES_PLAN.md). Re-sized when it changes: the
            // toolbar lays a view-backed item out at the view's own width.
            if let button = item.view as? NSPopUpButton, let title = button.menu?.items.first {
                let name = frontTools.activeModule?.title ?? MainWindowController.noToolTitle
                if title.title != name {
                    title.title = name
                    button.sizeToFit()
                    button.invalidateIntrinsicContentSize()
                }
            }
            return activePane.isOpen
        case #selector(setWordSize(_:)):
            // The button names the size in force, the way the View > Word Size
            // items carry the radio check (§6). Always enabled: a view setting,
            // not something done to a file (§24.2).
            (item.view as? NSPopUpButton)?.selectItem(withTag: WordSize.current.rawValue)
            return true
        case #selector(togglePaneLayout):
            // The icon names the arrangement the click will produce, the way the
            // Show/Hide Minimap item's title names its act (§24.3): stacked
            // panes while they are side by side, side by side while stacked. The
            // tooltip says it in words.
            let offersStacked = LayoutSettings.isVertical
            item.image = NSImage(systemSymbolName: offersStacked ? "square.split.1x2" : "square.split.2x1",
                                 accessibilityDescription: offersStacked ? "Stack Panes" : "Side-by-Side Panes")
            item.toolTip = offersStacked ? "Stack the panes" : "Place the panes side by side"
            return windowPanesAreReachable && mode == .comparison
        default:
            return true
        }
    }
}

// MARK: - Menu validation

/// What a surface's map asks of the tab it lives in
/// (`Design/FRAGMENT_PANELS_PLAN.md`). Everything else it needs it asks of its
/// own surface, which is the point: nothing here offers it the window's mode.
extension MainViewController: MinimapHost {
    /// Two maps follow the panes they map: side by side, or stacked at the
    /// panes' own divider so the two lines meet (§19).
    func minimapPairLayout() -> MinimapView.MapLayout {
        guard let comparisonView else { return .single }
        return comparisonView.splitView.isVertical
            ? .sideBySide
            : .stacked(fraction: comparisonView.currentFraction)
    }

    func overviewSource(for pane: PaneViewModel) -> SurfaceMinimapController.OverviewSource {
        SurfaceMinimapController.OverviewSource(
            storage: pane.byteStorage, saved: pane.savedStorage, size: pane.fileSize,
            edited: pane.editedRanges, marksModified: pane.marksModifiedBytes,
            differences: comparisonCoordinator.index)
    }

    var comparisonIndexBuild: Int { comparisonCoordinator.indexBuildCount }

    func activatePane(showingMapAt index: Int) {
        guard mode == .comparison, index != windowModel.activePaneIndex else { return }
        activatePane(at: index)
    }

    func minimapSegmentMenu(mapIndex: Int, pieceIndex: Int, point: NSPoint) -> NSMenu? {
        makeMinimapSegmentMenu(mapIndex: mapIndex, pieceIndex: pieceIndex, point: point)
    }

    func minimapZoneMenu(mapIndex: Int, zoneID: Zone.ID) -> NSMenu? {
        makeMinimapZoneMenu(mapIndex: mapIndex, zoneID: zoneID)
    }
}

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(activateTool(_:)):
            // A radio group: the active tool-module is checked, and a
            // tool-module needs a file to work on. None is always available —
            // it is how the panel is closed.
            let (enabled, state) = frontTools.menuState(for: menuItem.representedObject as? String,
                                                        fileIsOpen: activePane.isOpen)
            menuItem.state = state
            return enabled
        case #selector(toggleMinimapOverview):
            // A check, because both modes are a minimap. Disabled for a file the
            // overview could only magnify — the same rule that greys out the
            // header switch's Overview half (§19.4).
            menuItem.state = surface.minimapView.renderMode == .overview ? .on : .off
            return surface.minimapView.renderMode == .overview || surface.minimapView.overviewIsInformative()
        case #selector(toggleMinimap):
            // A Show/Hide item names what it will do, so the title flips with
            // the panel's state (§19). Always enabled: the minimap works with
            // no file open too (it just has nothing to draw).
            menuItem.title = surface.minimapPanelVisible ? "Hide Minimap" : "Show Minimap"
            return true
        case #selector(toggleInsertMode):
            // A checked toggle reading the ACTIVE pane's mode: the mode is per
            // pane (§7.6), so the checkmark follows the pane the keys go to.
            // Always enabled — it is a mode switch, meaningful even with no file
            // open.
            menuItem.state = activePane.isInsertMode ? .on : .off
            return true
        case #selector(undoEdit):
            // A step made on the user's behalf by something with a name of its
            // own says what it was — "Undo Add Microcode" (§26). Ordinary
            // editing has no name, and the item stays the bare verb.
            menuItem.title = activePane.undoLabel.map { "Undo \($0)" } ?? "Undo"
            return activePane.isOpen
        case #selector(redoEdit):
            menuItem.title = activePane.redoLabel.map { "Redo \($0)" } ?? "Redo"
            return activePane.isOpen
        case #selector(saveDocument),
             #selector(saveDocumentAs),
             #selector(pasteInsert),
             #selector(deleteBytes),
             #selector(selectBlock),
             #selector(goToPosition),
             #selector(findPattern),
             #selector(selectAllBytes),
             #selector(toggleBookmark):
            return activePane.isOpen
        case #selector(editBookmark):
            // There is nothing to edit on a row that carries no mark, and ⌘D is
            // what makes one (§20.3).
            return activePane.isOpen
                && windowModel.bookmarkStore.bookmark(atRowContaining: activePane.hexSelection().start) != nil
        case #selector(addCut):
            // A cut needs bytes to split: an empty pane has none (§21.3).
            return activePane.isOpen && activePane.fileSize > 0
        case #selector(removeSegment(_:)):
            // A piece can be removed only when there is a neighbour to merge it
            // into (§21.3) — the first piece into the one below, any other into
            // the one above. The position is the right-clicked one from the
            // context menu, or the caret from the Edit menu.
            let (pane, position): (PaneViewModel, UInt64)
            if let target = menuItem.representedObject as? OffsetContextTarget {
                (pane, position) = (target.pane, target.offset)
            } else {
                pane = activePane
                position = pane.caretOffset
            }
            guard pane.isOpen else { return false }
            let piece = pane.segmentStore.segment(containing: position)
            // Name the piece and the neighbour it merges into, so the menu says
            // what it will do (§21.3) — "Merge S1 into S0", not a bare "Merge".
            menuItem.title = piece.map { $0.mergeTitle } ?? "Merge"
            return piece != nil && pane.segmentStore.current.pieces.count > 1
        case #selector(updateInParent):
            return validateUpdateInParent(menuItem, for: activePane)
        case #selector(updatePaneInParent(_:)):
            return validateUpdateInParent(menuItem, for: pane(from: menuItem))
        case #selector(revertDocument):
            return validateRevert(menuItem, for: activePane)
        case #selector(appendFile),
             #selector(insertFileAtStart):
            // A join needs content to join into: an empty pane has nothing
            // (§22.1). The File-menu items act on the tab's active pane — a
            // join is about the panes, not about whatever is in front of them,
            // and while something is in front of them they take no orders.
            return windowPanesAreReachable && windowActivePane.isOpen
        case #selector(appendFileInPane(_:)),
             #selector(insertFileAtStartInPane(_:)):
            // Context-menu items act on the pane they were built for.
            return pane(from: menuItem)?.isOpen ?? false
        case #selector(duplicateDocument):
            // The copy needs a free pane and bytes to copy (§23), which is
            // the pane beside the tab's own — a panel has none, and while one
            // is in front the panes take no orders.
            return windowPanesAreReachable && canDuplicate(windowActivePane)
        case #selector(duplicatePaneDocument(_:)):
            // Not in a panel: a part has no pane beside it to be copied into,
            // and what the command reached for was one of the tab's, which is
            // the file behind the panel being replaced by a copy of the part.
            guard let pane = pane(from: menuItem), fragmentPanel(of: pane) == nil else {
                return false
            }
            return canDuplicate(pane)
        case #selector(newDocumentInPane(_:)),
             #selector(openInPane(_:)):
            // Same reason: both put a document *into a pane*, and a panel's
            // pane is not one of the tab's two to put anything into.
            guard let pane = pane(from: menuItem) else { return false }
            return fragmentPanel(of: pane) == nil
        case #selector(renamePaneDocument(_:)):
            // A saved document's name belongs to its file; only the label of an
            // unsaved one is the app's to change (§23).
            return pane(from: menuItem)?.canRename ?? false
        case #selector(openPaneInNewTab(_:)):
            // Only a comparison has a pane to spare. In single-file mode the
            // command would move the window's only document into a new tab and
            // leave an empty window behind — a move that separates nothing.
            // `makeSiblingTab` is nil in a controller with no window to put a
            // tab beside.
            guard let pane = pane(from: menuItem), makeSiblingTab != nil else { return false }
            // A fragment panel is always spare: moving it out leaves the tab
            // exactly as it was, with one pill fewer.
            if fragments.panel(withDragID: pane.dragID) != nil { return pane.isOpen }
            return mode == .comparison && pane.isOpen
        case #selector(savePaneDocument(_:)),
             #selector(savePaneDocumentAs(_:)):
            // Context-menu items act on the pane they were built for.
            return pane(from: menuItem)?.isOpen ?? false
        case #selector(revertPaneDocument(_:)):
            return validateRevert(menuItem, for: pane(from: menuItem))
        case #selector(showPaneInFinder(_:)):
            // A file must be on disk to reveal it in the Finder — an empty pane
            // has nothing, and an untitled document has no URL.
            guard let pane = pane(from: menuItem) else { return false }
            return pane.isOpen && !pane.isUntitled
        case #selector(copyPaneFileName(_:)),
             #selector(copyPaneFullPath(_:)):
            // A file must be on disk to have a name or a path to copy — an
            // empty pane has nothing, and an untitled document has no file.
            // The same rule as Show in Finder, for the same reason.
            guard let pane = pane(from: menuItem) else { return false }
            return pane.isOpen && !pane.isUntitled
        case #selector(copyPaneSelection(_:)),
             #selector(savePaneSelectionAs(_:)),
             #selector(fillPaneSelection(_:)),
             #selector(deletePaneSelection(_:)):
            // Right-click selection actions act on the pane they were built for.
            return (menuItem.representedObject as? OffsetContextTarget)?.pane.isOpen ?? false
        case #selector(splitHere(_:)):
            // Split Here at «address» opens the Add Cut popover pre-filled with the
            // right-clicked offset; the popover validates the offset as it is
            // typed, so a file is all the menu item needs (§21.3).
            guard let target = menuItem.representedObject as? OffsetContextTarget,
                  target.pane.isOpen else { return false }
            return target.pane.fileSize > 0
        case #selector(fillSelectionWithBytes):
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        case #selector(copySelection),
             #selector(useSelectionForFind):
            // Both act on the selection, so both are dimmed without one: ⌘E
            // with nothing selected would have nothing to take (§11).
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        case #selector(NSText.paste(_:)):
            // ⌘V pastes text into a focused field editor (standard system
            // paste) or, when the hex dump holds focus, writes bytes into
            // the active pane via HexView.paste(_:) (§11). Everywhere else
            // the item is disabled, so paste never fires on the wrong target.
            if viewIfLoaded?.window?.firstResponder is NSTextView { return true }
            if viewIfLoaded?.window?.firstResponder is HexView { return activePane.isOpen }
            return false
        case #selector(nextDifference):
            return windowPanesAreReachable && diffNavigationState.nextDifference
        case #selector(previousDifference):
            return windowPanesAreReachable && diffNavigationState.previousDifference
        case #selector(nextSameBlock):
            return windowPanesAreReachable && diffNavigationState.nextSameBlock
        case #selector(previousSameBlock):
            return windowPanesAreReachable && diffNavigationState.previousSameBlock
        case #selector(togglePaneLayout),
             #selector(swapPanes):
            // Layout and swap depend only on comparison mode, not the index —
            // and on the panes being reachable, which they are not while a
            // fragment panel is in front of them.
            return windowPanesAreReachable && mode == .comparison
        case #selector(setWordSize(_:)):
            // Radio state: check the item matching the current word size (§6).
            menuItem.state = menuItem.tag == WordSize.current.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - Clipboard

enum PasteError: LocalizedError {
    case noClipboardData

    var errorDescription: String? {
        switch self {
        case .noClipboardData:
            return "The clipboard does not contain raw bytes or a valid hex byte sequence."
        }
    }
}

/// Custom pasteboard type carrying raw bytes (§12.1). `public.data` is not a
/// defined PasteboardType member, and system types like `public.utf8-plain-text`
/// are interpreted by other apps as text, not bytes.
extension NSPasteboard.PasteboardType {
    static let rawBytes = NSPasteboard.PasteboardType("dev.maxik.ByteRipper.rawBytes")
}

private func pasteboardBytes() throws -> [UInt8] {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: .rawBytes) {
        return [UInt8](data)
    }
    if let text = pasteboard.string(forType: .string) {
        return try ClipboardCodec.bytes(fromHexText: text)
    }
    throw PasteError.noClipboardData
}

/// Boxes the pane and clicked offset carried by a "Select Block from Here at «address»"
/// menu item — `NSMenuItem.representedObject` can't hold a tuple (§10.2).
/// What a zone menu item carries: the pane it was opened in, and the zone.
private final class ZoneContextTarget: NSObject {
    let pane: PaneViewModel
    let zone: Zone

    init(pane: PaneViewModel, zone: Zone) {
        self.pane = pane
        self.zone = zone
    }
}

private final class OffsetContextTarget: NSObject {
    let pane: PaneViewModel
    let offset: UInt64

    init(pane: PaneViewModel, offset: UInt64) {
        self.pane = pane
        self.offset = offset
    }
}

