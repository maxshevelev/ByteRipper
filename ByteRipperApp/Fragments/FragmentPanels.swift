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
    /// A multiplier on every panel animation, for watching one in detail:
    ///
    ///     defaults write dev.maxik.DumpCompare FragmentPanelSlowMotion 8
    ///
    /// Absent or one is the real speed. It exists because these animations say
    /// *where* a panel went, and whether they say it truthfully cannot be read
    /// at a fifth of a second.
    static var slowMotion: Double {
        max(1, UserDefaults.standard.double(forKey: "FragmentPanelSlowMotion"))
    }

    /// How long the flight takes. Long enough to read as one thing arriving
    /// while another leaves, short enough that folding a panel to glance at the
    /// dump behind it is not a wait.
    static var slideDuration: TimeInterval { 0.22 * slowMotion }

    /// What a panel is made of, beyond its id.
    private final class Entry {
        let id: FragmentDock.PanelID
        let pane: PaneViewModel
        let surface: DocumentSurface
        let paneView: FilePaneView
        let view: FragmentPanelView
        /// The panel's own marks. A part's offsets are its own, so it does not
        /// read the window's list (§20, and the rule the tab route already
        /// followed).
        let bookmarks: BookmarkStore

        init(id: FragmentDock.PanelID, pane: PaneViewModel, surface: DocumentSurface,
             paneView: FilePaneView, view: FragmentPanelView, bookmarks: BookmarkStore) {
            self.id = id
            self.pane = pane
            self.surface = surface
            self.paneView = paneView
            self.view = view
            self.bookmarks = bookmarks
        }
    }

    private(set) var dock = FragmentDock()

    /// The panel being pulled down by hand, whose frame is the gesture's to set
    /// until it is let go.
    private var pulling: FragmentDock.PanelID?

    /// The panels in flight between the dock and the stage. Their frames stand
    /// still while their layers do the moving, so a layout pass must leave them
    /// alone — putting a folding panel back at its folded frame mid-flight is a
    /// jump out of the middle of the animation.
    private var flying: Set<FragmentDock.PanelID> = []
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

    /// The panel `pane` belongs to, or nil for one of the tab's own panes.
    func panel(holding pane: PaneViewModel) -> FragmentDock.PanelID? {
        dock.panels.first { entries[$0]?.pane === pane }
    }

    /// The panels whose way back leads to `pane` — the parts taken out of it.
    /// What closing it would strand.
    func panelsLinked(to pane: PaneViewModel) -> [FragmentDock.PanelID] {
        dock.panels.filter { entries[$0]?.pane.origin?.parent === pane }
    }

    /// The surface of the panel holding `pane`, or nil when `pane` is not a
    /// part this dock has open — which is the answer for the tab's own panes.
    func surface(holding pane: PaneViewModel) -> DocumentSurface? {
        for id in dock.panels where entries[id]?.pane === pane {
            return entries[id]?.surface
        }
        return nil
    }

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
        entries[opened.id] = Entry(id: opened.id, pane: pane, surface: surface,
                                   paneView: paneView, view: view, bookmarks: bookmarks)
        // After the id exists: the ✕ closes *this* panel, and the tool that
        // hears about an edit is this surface's.
        host.wireFragmentPaneView(paneView, for: pane, panel: opened.id, surface: surface)
        // The tool panel's header is a handle too, when the panel has one open.
        surface.tools.panel.onHeaderPulledDown = { [weak self] event in
            self?.beginPullDown(opened.id, from: event)
        }
        host.prepareFragmentMinimap(of: surface, pane: pane, paneView: paneView)
        // The panel's own list, and the only thing reading it: the pane it
        // marks and the map beside it.
        bookmarks.onChange = { [weak self, weak pane, weak surface] row in
            pane?.onBookmarksChanged?(row)
            if let surface { self?.host?.syncFragmentMinimapBookmarks(of: surface) }
        }
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
        apply(dock.remove(id), animated: animated, closesDocument: true)
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

    // MARK: - Pulling the panel down

    /// How long a spring back takes. Shorter than the flight: nothing changed,
    /// so the panel should look like it never left.
    static var springBackDuration: TimeInterval { 0.2 * slowMotion }

    /// The panel's header has been pulled down: it follows the pointer until
    /// the button comes up, and then either springs back or carries on into its
    /// pill (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// The pointer is tracked here rather than through the responder chain
    /// because the gesture belongs to the panel while it lasts: the header it
    /// started on is scrolling away under the hand.
    func beginPullDown(_ id: FragmentDock.PanelID, from event: NSEvent) {
        guard dock.expanded == id, let entry = entries[id],
              let window = entry.view.window else { return }
        let start = event.locationInWindow.y
        // Where the hand last was, when it was there, and what it did on the
        // way — measured over the movement itself rather than over a window of
        // time, so a nudge followed by a pause is still a nudge.
        var anchor = start
        var anchorTime = event.timestamp
        var movement = PullDown.Movement()

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: .greatestFiniteMagnitude, mode: .eventTracking) { tracked, stop in
            guard let tracked else { stop.pointee = true; return }
            let y = tracked.locationInWindow.y
            if let direction = PullDown.Direction.of(offset: y - anchor) {
                let distance = abs(y - anchor)
                // A floor under the interval: two events can share a timestamp,
                // and a division by nothing is not a speed.
                let seconds = max(tracked.timestamp - anchorTime, 1.0 / 240)
                movement = PullDown.Movement(direction: direction, distance: distance,
                                             speed: distance / CGFloat(seconds))
                anchor = y
                anchorTime = tracked.timestamp
            }
            switch tracked.type {
            case .leftMouseDragged:
                self.pullPanel(id, by: y - start)
            default:
                stop.pointee = true
                self.endPull(id, movement: movement)
            }
        }
    }

    /// Puts the panel where the hand has it, `offset` from where it was
    /// grabbed (negative is down).
    ///
    /// Internal because the gesture runs a nested tracking loop, which a test
    /// cannot enter: driving the pull through these two is how the suite gets
    /// at it.
    func pullPanel(_ id: FragmentDock.PanelID, by offset: CGFloat) {
        guard dock.expanded == id, let entry = entries[id] else { return }
        pulling = id
        var frame = FragmentPanelView.restingFrame(in: container)
        frame.origin.y = PullDown.position(restingY: frame.origin.y, offset: offset)
        entry.view.frame = frame
    }

    /// Lets the pull go, `movement` being what the hand last did.
    func endPull(_ id: FragmentDock.PanelID, movement: PullDown.Movement) {
        guard pulling == id, let entry = entries[id] else { return }
        pulling = nil
        let resting = FragmentPanelView.restingFrame(in: container)
        finishPullDown(id, entry: entry, resting: resting,
                       travelled: resting.origin.y - entry.view.frame.origin.y,
                       movement: movement)
    }

    private func finishPullDown(_ id: FragmentDock.PanelID, entry: Entry, resting: NSRect,
                                travelled: CGFloat, movement: PullDown.Movement) {
        switch PullDown.outcome(travelled: travelled, height: resting.height,
                                movement: movement) {
        case .springBack:
            move(entry.view, to: resting, animated: true, duration: Self.springBackDuration)
        case .collapse:
            // From wherever the hand left it, so the rest of the way takes the
            // rest of the time: a panel already most of the way down must not
            // dawdle through a full slide.
            let remaining = max(0, resting.height - travelled)
            let share = resting.height > 0 ? remaining / resting.height : 1
            let duration = max(0.1, Self.slideDuration * Double(share))
            apply(dock.collapse(), animated: true, duration: duration)
        }
    }

    // MARK: - Running a transition

    private func apply(_ transition: FragmentDock.Transition, animated: Bool,
                       duration: TimeInterval? = nil, closesDocument: Bool = false) {
        // Where a folding panel is flying to, read before the dock is brought
        // in line: a panel that is closing takes its pill with it.
        let foldTarget = transition.folding.flatMap { pillRect(for: $0) }
        // And the dock first, so a panel that has just been opened has a pill
        // to grow out of.
        refreshDock()
        let span = duration ?? Self.slideDuration

        let raise: () -> Void = { [weak self] in
            guard let self, let raising = transition.raising,
                  let entry = self.entries[raising], self.dock.expanded == raising else { return }
            self.container.isHidden = false
            let resting = FragmentPanelView.restingFrame(in: self.container)
            if entry.view.superview !== self.container { self.container.addSubview(entry.view) }
            entry.view.frame = resting
            guard animated, let pill = self.pillRect(for: raising) else { return }
            self.flying.insert(raising)
            self.fly(entry.view, to: pill, duration: span, out: false) { [weak self] in
                self?.flying.remove(raising)
            }
        }

        if let folding = transition.folding, let entry = entries[folding] {
            let land: () -> Void = { [weak self] in
                guard let self else { return }
                // Unless it has been raised again in the meantime: a pill
                // clicked twice while the flight was still running must not
                // take the panel it just brought back off the stage.
                if self.dock.expanded != folding {
                    entry.view.removeFromSuperview()
                    self.hideContainerIfClear()
                }
                if transition.removed == folding { self.tearDown(entry, closesDocument: closesDocument) }
                // One at a time: the panel that is leaving finishes leaving
                // before the next one starts arriving, or the two flights read
                // as one muddle.
                raise()
            }
            if animated, let pill = foldTarget {
                flying.insert(folding)
                fly(entry.view, to: pill, duration: span, out: true) { [weak self] in
                    self?.flying.remove(folding)
                    land()
                }
            } else {
                move(entry.view, to: FragmentPanelView.foldedFrame(in: container),
                     animated: animated, duration: duration, completion: land)
            }
        } else {
            raise()
            if let removed = transition.removed, let entry = entries.removeValue(forKey: removed) {
                tearDown(entry, closesDocument: closesDocument)
            }
        }

        invalidateCursors()
        // The panel in front takes the keyboard; folding the last one gives it
        // back to the dump. Without it the file behind kept the caret.
        host?.fragmentFocusChanged()
    }

    /// Lets go of everything behind a panel that has left the dock.
    private func tearDown(_ entry: Entry, closesDocument: Bool) {
        entries.removeValue(forKey: entry.id)
        entry.view.removeFromSuperview()
        entry.surface.removeFromParent()
        entry.paneView.searchResults.removeFromParent()
        host?.forgetPaneView(of: entry.pane)
        // The panel's own tool-module has nothing left to read: end it the way
        // a pane closing or leaving a tab ends the tab's.
        if closesDocument {
            entry.surface.tools.paneClosed(entry.pane)
        } else {
            entry.surface.tools.paneLeft(entry.pane)
        }
        // A closed panel's document closes with it, and that is what a part
        // opened *out of* this one has to be told: its link goes dead, its
        // header says so, and Update in Parent refuses rather than writing into
        // a document nobody can see. A panel let go of rather than closed keeps
        // its document — it is on its way to a tab of its own.
        if closesDocument { entry.pane.close() }
        refreshDock()
        hideContainerIfClear()
    }

    /// The cursors over the covered panes change with the panel arriving or
    /// leaving, and AppKit only re-asks when told.
    private func invalidateCursors() {
        container.window?.invalidateCursorRects(for: container)
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
    /// The rectangle a panel folds into: its pill, in the coordinates the panel
    /// itself is placed in. Nil when the dock has no pill for it yet, which is
    /// the moment a panel is being opened.
    private func pillRect(for id: FragmentDock.PanelID) -> NSRect? {
        guard let inStrip = strip.pillFrame(for: id) else { return nil }
        return container.convert(inStrip, from: strip)
    }

    /// Folds a panel into its pill, or grows it out of one.
    ///
    /// A shrink onto the pill rather than a slide off the bottom, because every
    /// pill in the dock looks like every other and the panel going into one is
    /// the only thing that says which. Done with the layer's transform rather
    /// than the frame: a frame animation re-lays the panel out at every size on
    /// the way, which is a hex grid reflowing sixty times a second to arrive
    /// somewhere nobody will read.
    ///
    /// The host clips, so it stops clipping for the length of the flight —
    /// otherwise the last part of it, the part over the dock, is cut off at the
    /// very moment it is saying where the panel went.
    private func fly(_ view: FragmentPanelView, to pill: NSRect, duration: TimeInterval,
                     out: Bool, completion: @escaping () -> Void) {
        let frame = view.frame
        guard frame.width > 0, frame.height > 0, let layer = view.layer else {
            completion()
            return
        }
        let shrunk = CATransform3DMakeAffineTransform(
            PanelLanding.transform(from: frame, on: pill, anchor: layer.anchorPoint))

        container.layer?.masksToBounds = false
        let restoreClip = { [weak self] in self?.container.layer?.masksToBounds = true }
        layer.transform = out ? CATransform3DIdentity : shrunk
        layer.opacity = out ? 1 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: out ? .easeIn : .easeOut)
            context.allowsImplicitAnimation = true
            layer.transform = out ? shrunk : CATransform3DIdentity
            layer.opacity = 1
        } completionHandler: {
            if out { layer.transform = CATransform3DIdentity }
            restoreClip()
            completion()
        }
    }

    private func move(_ view: NSView, to frame: NSRect, animated: Bool,
                      duration: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        view.setFrameSize(frame.size)
        view.layoutSubtreeIfNeeded()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.setFrameOrigin(frame.origin)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration ?? Self.slideDuration
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
            // Not the one in the hand: a pull sets the panel's frame on every
            // mouse move, and a layout pass that put it back to rest was the
            // panel shaking instead of following.
            guard !flying.contains(id) else { continue }
            guard id != pulling else {
                var frame = FragmentPanelView.restingFrame(in: container)
                frame.origin.y = entry.view.frame.origin.y
                entry.view.frame = frame
                continue
            }
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
        // The Tools popup names the tool-module of whatever is in front, so
        // raising or folding a panel changes what it should read.
        host?.revalidateToolbar()
    }
}
