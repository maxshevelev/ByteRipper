import Cocoa

/// The tab's fragment panels: the dock's model, the surfaces behind the pills,
/// and the slide that raises one and folds another
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// It lives here rather than in `MainViewController` for the ordinary reason —
/// that file is long enough — and for the same specific one the tool controller
/// was moved out for: a panel has a life of its own, from the bytes it was
/// opened with to the pill it folds into, and the tab's part in it is one
/// stored property.
@MainActor final class FragmentPanels {
    /// How long the slide takes. Long enough to read as one thing rising while
    /// another goes down, short enough that folding a panel to glance at the
    /// dump behind it is not a wait.
    static var slideDuration: TimeInterval = 0.22

    /// What a panel is made of, beyond its id.
    private final class Entry {
        let pane: PaneViewModel
        let surface: DocumentSurface
        let paneView: FilePaneView
        let view: FragmentPanelView
        /// The panel's own marks. A part's offsets are its own, so it does not
        /// read the window's list (§20, and the rule the tab route already
        /// followed).
        let bookmarks: BookmarkStore

        init(pane: PaneViewModel, surface: DocumentSurface, paneView: FilePaneView,
             view: FragmentPanelView, bookmarks: BookmarkStore) {
            self.pane = pane
            self.surface = surface
            self.paneView = paneView
            self.view = view
            self.bookmarks = bookmarks
        }
    }

    private(set) var dock = FragmentDock()
    private var entries: [FragmentDock.PanelID: Entry] = [:]

    private weak var host: MainViewController?
    private let container: FragmentPanelHost
    private let strip: FragmentDockStrip

    init(host: MainViewController, container: FragmentPanelHost, strip: FragmentDockStrip) {
        self.host = host
        self.container = container
        self.strip = strip
        container.isHidden = true
        container.onLayout = { [weak self] in self?.layoutPanels() }
        strip.onSelect = { [weak self] id in self?.toggle(id) }
        // Through the tab, not straight to `close`: a pill's ✕ has to ask the
        // same question ⌘W does about bytes the parent has not got back.
        strip.onClose = { [weak self] id in self?.host?.closeFragment(id) }
        strip.onTearOff = { [weak self] id in self?.host?.tearOffFragment(id) }
        refreshDock()
    }

    // MARK: - What is open

    var isEmpty: Bool { dock.isEmpty }
    var count: Int { dock.count }
    var expanded: FragmentDock.PanelID? { dock.expanded }

    /// The pane behind a pill — what the commands aimed at the front surface
    /// act on, and what the suite reads.
    func pane(_ id: FragmentDock.PanelID) -> PaneViewModel? { entries[id]?.pane }
    func surface(_ id: FragmentDock.PanelID) -> DocumentSurface? { entries[id]?.surface }
    func panelView(_ id: FragmentDock.PanelID) -> FragmentPanelView? { entries[id]?.view }

    /// The surface of the panel that is up, if one is — the surface the front
    /// of the window belongs to.
    var frontSurface: DocumentSurface? { dock.expanded.flatMap { entries[$0]?.surface } }
    /// The pane of the panel that is up, if one is.
    var frontPane: PaneViewModel? { dock.expanded.flatMap { entries[$0]?.pane } }

    // MARK: - Opening

    /// Opens `bytes` as a panel of its own and raises it.
    ///
    /// What the part *is* — a zone, a decompressed body, the link back to the
    /// parent — is decided by whoever asked for it; this makes the document and
    /// puts it on screen.
    @discardableResult
    func open(_ bytes: [UInt8], named name: String, origin: DocumentOrigin? = nil,
              animated: Bool = true) -> FragmentDock.PanelID? {
        let pane = PaneViewModel()
        let marks = BookmarkStore()
        pane.bookmarkStore = marks
        pane.openBytes(bytes, named: name, origin: origin)
        return adopt(pane, bookmarks: marks, animated: animated)
    }

    /// Takes a pane that already exists as a panel of its own and raises it —
    /// the other half of `release`, and what a panel dragged back in from
    /// somewhere else will arrive through.
    @discardableResult
    func adopt(_ pane: PaneViewModel, bookmarks: BookmarkStore? = nil,
               animated: Bool = true) -> FragmentDock.PanelID? {
        guard let host else { return nil }
        let bookmarks = bookmarks ?? BookmarkStore()
        pane.bookmarkStore = bookmarks
        let surface = DocumentSurface(host: host)
        // The panel's tool-module reads the part, not whatever the tab's active
        // pane is — the panel is a surface with exactly one pane.
        surface.pinnedPane = pane
        host.addChild(surface)
        let paneView = host.paneView(for: pane)
        surface.setContent(paneView)
        let view = FragmentPanelView(content: surface.view)
        let opened = dock.open()
        entries[opened.id] = Entry(pane: pane, surface: surface, paneView: paneView,
                                   view: view, bookmarks: bookmarks)
        // After the id exists: the ✕ closes *this* panel, and the tool that
        // hears about an edit is this surface's.
        host.wireFragmentPaneView(paneView, for: pane, panel: opened.id, surface: surface)
        apply(opened.transition, animated: animated)
        return opened.id
    }

    // MARK: - Raising and folding

    /// The pill's own click: the panel that is up folds, any other rises.
    func toggle(_ id: FragmentDock.PanelID, animated: Bool = true) {
        if dock.expanded == id {
            collapse(animated: animated)
        } else {
            expand(id, animated: animated)
        }
    }

    func expand(_ id: FragmentDock.PanelID, animated: Bool = true) {
        apply(dock.expand(id), animated: animated)
    }

    /// Folds whatever is up. What Esc does, and what the dump behind is for.
    func collapse(animated: Bool = true) {
        apply(dock.collapse(), animated: animated)
    }

    /// Takes a panel out of the dock and lets go of everything behind it.
    ///
    /// The caller has already asked whatever had to be asked — unsaved edits,
    /// bytes not yet put back. This is the act, not the question.
    func close(_ id: FragmentDock.PanelID, animated: Bool = true) {
        apply(dock.remove(id), animated: animated)
    }

    /// The panel whose pane is being dragged, or nil when the drag is not one
    /// of this dock's.
    func panel(withDragID dragID: UUID) -> FragmentDock.PanelID? {
        dock.panels.first { entries[$0]?.pane.dragID == dragID }
    }

    /// Lets go of a panel without closing its document: what tearing one off
    /// into a tab of its own leaves behind. The pane is handed back so the
    /// caller can put it somewhere, with everything it carries — its edits, its
    /// undo, and the link to the parent, which is the pane's own property and
    /// so travels with it.
    ///
    /// Its marks come too, as a copy: they were made against the part's own
    /// offsets and mean the same rows wherever it lands. The pane itself leaves
    /// with no list, because it is about to be given its new home's.
    func release(_ id: FragmentDock.PanelID,
                 animated: Bool = true) -> (pane: PaneViewModel, bookmarks: [Bookmark])? {
        guard let entry = entries[id] else { return nil }
        let marks = entry.bookmarks.bookmarks
        entry.pane.bookmarkStore = nil
        apply(dock.remove(id), animated: animated)
        return (entry.pane, marks)
    }

    // MARK: - Running a transition

    private func apply(_ transition: FragmentDock.Transition, animated: Bool) {
        if let raising = transition.raising, let entry = entries[raising] {
            container.isHidden = false
            if entry.view.superview !== container {
                entry.view.frame = FragmentPanelView.foldedFrame(in: container)
                container.addSubview(entry.view)
            }
            move(entry.view, to: FragmentPanelView.restingFrame(in: container), animated: animated)
        }
        if let folding = transition.folding, let entry = entries[folding] {
            move(entry.view, to: FragmentPanelView.foldedFrame(in: container),
                 animated: animated) { [weak self] in
                guard let self else { return }
                // Unless it has been raised again in the meantime: a pill
                // clicked twice while the slide was still running must not take
                // the panel it just brought back off the screen.
                guard self.dock.expanded != folding else { return }
                entry.view.removeFromSuperview()
                self.hideContainerIfClear()
            }
        }
        if let removed = transition.removed, let entry = entries.removeValue(forKey: removed) {
            let tearDown = { [weak self] in
                entry.view.removeFromSuperview()
                entry.surface.removeFromParent()
                entry.paneView.searchResults.removeFromParent()
                self?.host?.forgetPaneView(of: entry.pane)
                self?.hideContainerIfClear()
            }
            // A panel that was up folds out of sight before it is taken apart;
            // one that was already a pill has nothing to animate.
            if transition.folding == removed, animated {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration, execute: tearDown)
            } else {
                tearDown()
            }
        }
        refreshDock()
    }

    private func hideContainerIfClear() {
        guard dock.expanded == nil else { return }
        container.isHidden = true
    }

    /// Slides `view` to `frame`.
    ///
    /// The **size** is set at once and only the origin is animated. A panel
    /// does not change shape on its way up — it is the same panel, lower down —
    /// and animating the frame whole made the size animate too: everything
    /// inside it, the surface's split included, spent the slide growing from
    /// nothing, and anything that asked how wide the pane was mid-slide was
    /// told almost zero. Laying the subtree out before the slide starts means
    /// the first frame drawn is already the panel as it will be.
    private func move(_ view: NSView, to frame: NSRect, animated: Bool,
                      completion: (() -> Void)? = nil) {
        view.setFrameSize(frame.size)
        view.layoutSubtreeIfNeeded()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.setFrameOrigin(frame.origin)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().setFrameOrigin(frame.origin)
        } completionHandler: {
            completion?()
        }
    }

    // MARK: - Layout

    /// Re-places the panels after the area they live in has changed size. The
    /// one that is up sits at rest; the folded ones wait below, where a window
    /// resize must not leave them showing.
    private func layoutPanels() {
        for (id, entry) in entries where entry.view.superview === container {
            entry.view.frame = dock.expanded == id
                ? FragmentPanelView.restingFrame(in: container)
                : FragmentPanelView.foldedFrame(in: container)
        }
    }

    // MARK: - The dock's pills

    /// Brings the pills in line with what the panels hold — names, the one that
    /// is up, and which of them have bytes the parent has not got back.
    func refreshDock() {
        strip.setItems(dock.panels.compactMap { id in
            guard let entry = entries[id] else { return nil }
            return FragmentDockStrip.Item(
                id: id,
                title: entry.pane.status.fileName,
                isUp: dock.expanded == id,
                hasChanges: entry.pane.origin?.hasChanges(in: entry.pane)
                    ?? entry.pane.status.isDirty,
                canTearOff: host?.canTearOffFragment ?? false
            )
        })
        host?.setFragmentDockVisible(!dock.isEmpty)
    }
}
