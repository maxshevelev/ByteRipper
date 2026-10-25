import ALSplitView
import Cocoa
import CodeAnalysis
import CodeView
import Localization
import ToolModuleKit

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

    /// How long a panel takes to rise from the dock edge to rest. A little
    /// longer than the fold: the rise is the moment that has to say "this is
    /// laid over the panes", and it covers the whole height of the window.
    static var riseDuration: TimeInterval { 0.3 * slowMotion }

    /// What a panel is made of, beyond its id.
    private final class Entry {
        let id: FragmentDock.PanelID
        let pane: PaneViewModel
        let surface: DocumentSurface
        let paneView: FilePaneView
        let codePane: CodePaneView?
        let view: FragmentPanelView

        init(id: FragmentDock.PanelID, pane: PaneViewModel, surface: DocumentSurface,
             paneView: FilePaneView, codePane: CodePaneView?, view: FragmentPanelView) {
            self.id = id
            self.pane = pane
            self.surface = surface
            self.paneView = paneView
            self.codePane = codePane
            self.view = view
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
        container.onBackgroundClick = { [weak self] in self?.collapse() }
        strip.onSelect = { [weak self] id in self?.toggle(id) }
        // Through the tab, not straight to `close`: a pill's ✕ has to ask the
        // same question ⌘W does about bytes the parent has not got back.
        strip.onClose = { [weak self] id in self?.host?.closeFragment(id) }
        strip.onTearOff = { [weak self] id in self?.host?.tearOffFragment(id) }
        // The pill carries off the panel's pane exactly as its header does:
        // the same session, so every destination already knows what it is.
        strip.onDrag = { [weak self] id, event, pill in
            self?.entries[id]?.paneView.beginPaneDrag(with: event, from: pill)
        }
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
    /// The code pane a code panel carries, nil for any other part.
    func codePane(_ id: FragmentDock.PanelID) -> CodePaneView? { entries[id]?.codePane }

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
        pane.openBytes(bytes, named: name, origin: origin)
        return adopt(pane, animated: animated)
    }

    /// Opens a module's bytes with the code pane beside them — the panel
    /// `Open with Code` asks for (`Design/CODE_PANEL_PLAN.md`). The bytes are
    /// the same part a body would open; the analysis is read-only and the code
    /// pane is the additional view.
    @discardableResult
    func openCode(_ bytes: [UInt8], named name: String, origin: DocumentOrigin,
                  manifest: AnalysisManifest,
                  animated: Bool = true) -> FragmentDock.PanelID? {
        let pane = PaneViewModel()
        pane.openBytes(bytes, named: name, origin: origin)
        return adopt(pane, codePane: CodePaneView(manifest: manifest), animated: animated)
    }

    /// Takes a pane that already exists as a panel of its own and raises it —
    /// the other half of `release`, and what a panel dragged back in from
    /// somewhere else will arrive through.
    @discardableResult
    func adopt(_ pane: PaneViewModel, animated: Bool = true) -> FragmentDock.PanelID? {
        adopt(pane, codePane: nil, animated: animated)
    }

    private func adopt(_ pane: PaneViewModel, codePane: CodePaneView?,
                       animated: Bool) -> FragmentDock.PanelID? {
        guard let host else { return nil }
        pane.bookmarks = bookmarkSpace(for: pane, in: host)
        let surface = DocumentSurface(host: host)
        // The panel's tool-module reads the part, not whatever the tab's active
        // pane is — the panel is a surface with exactly one pane.
        surface.pinnedPane = pane
        // The panel's side margins come out of its tool panel, not its dump.
        surface.toolPanelWidthAllowance = FragmentPanelLayout.sideInset * 2
        host.addChild(surface)
        let paneView = host.paneView(for: pane)
        if let codePane {
            let split = ALSplitView()
            split.isVertical = true
            split.dividerThickness = 1
            split.addPane(paneView)
            split.addPane(codePane)
            split.setPaneLayout(.fill, at: 0)
            split.setPaneLayout(.fixed(360), at: 1)
            surface.setContent(split)
        } else {
            surface.setContent(paneView)
        }
        // The pane's title bar goes across the whole panel, over the tool and
        // the map as well as the dump.
        let view = FragmentPanelView(header: paneView.hoistHeader(), content: surface.view)
        let opened = dock.open()
        entries[opened.id] = Entry(id: opened.id, pane: pane, surface: surface,
                                   paneView: paneView, codePane: codePane, view: view)
        // After the id exists: the ✕ closes *this* panel, and the tool that
        // hears about an edit is this surface's.
        host.wireFragmentPaneView(paneView, for: pane, panel: opened.id, surface: surface)
        // The tool panel's header is a handle too, when the panel has one open.
        surface.tools.panel.onHeaderPulledDown = { [weak self] event in
            self?.beginPullDown(opened.id, from: event)
        }
        host.prepareFragmentMinimap(of: surface, pane: pane, paneView: paneView)
        // The first showing slides up from below; every later raise grows out
        // of the pill, which by then is what says where the panel lives.
        apply(opened.transition, animated: animated, risesFromBelow: true)
        return opened.id
    }

    /// Where a part's marks live: the window's list, at the part's own offsets
    /// (§20.7).
    ///
    /// The list is shared, so a mark made in the dump shows in the panel at the
    /// offset the part has it at, and one made in the panel shows in the dump at
    /// the offset the file has it at. The offset is the parent's own plus the
    /// part's within it, which is what makes a part opened out of a part come
    /// out right without this having to know how deep it is.
    ///
    /// Nil — no marks at all — for a decompressed body, and for anything opened
    /// out of one: its bytes are not the file's bytes, so the file's offsets do
    /// not reach them and a mark in either place would mean nothing in the
    /// other.
    private func bookmarkSpace(for pane: PaneViewModel,
                               in host: MainViewController) -> BookmarkSpace? {
        guard let origin = pane.origin else {
            // Not a part of anything: it reads the window's list as the dump
            // does, at the dump's own offsets.
            return BookmarkSpace(store: host.windowModel.bookmarkStore)
        }
        guard origin.codec.keepsOffsets, let parent = origin.parent?.bookmarks else { return nil }
        return BookmarkSpace(store: parent.store,
                             origin: parent.origin + origin.sourceRange.lowerBound)
    }

    /// A mark changed in the list the panels share: every panel the row falls
    /// in repaints it at its own offset, and its map's margin follows (§20.7).
    ///
    /// The tab's own two panes are told by the window; this is the rest of the
    /// same fan-out, and it runs per panel because each has its own offset into
    /// the one list.
    func bookmarksChanged(atStoreRow row: UInt64) {
        for id in dock.panels {
            guard let entry = entries[id], let space = entry.pane.bookmarks,
                  let local = space.localRow(forStoreRow: row) else { continue }
            entry.pane.onBookmarksChanged?(local)
            host?.syncFragmentMinimapBookmarks(of: entry.surface)
        }
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

    /// Raises `id`, folding whatever was up.
    ///
    /// Switching from one panel to another is not animated, however it is
    /// asked for — a pill clicked, or an update sending the reader to the panel
    /// it landed in. The flight of a panel says where it went; between two
    /// panels there is nowhere to go, and watching one fall into its pill so
    /// the next can climb out of its own is a wait in the middle of a glance.
    /// The flights that say something stay: a panel arriving, a panel folding
    /// to show the dump, a pull let go of.
    func expand(_ id: FragmentDock.PanelID, animated: Bool = true) {
        let switching = dock.expanded != nil && dock.expanded != id
        apply(dock.expand(id), animated: animated && !switching)
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
    /// Its marks come too, as a copy at the part's own offsets: what the panel
    /// showed is what the tab will show, and the tab is about those bytes, so
    /// its list is in their offsets rather than the parent file's (§20.7). A
    /// panel with no list of its own — a decompressed body — brings none. The
    /// pane itself leaves without one, because it is about to be given its new
    /// home's.
    func release(_ id: FragmentDock.PanelID,
                 animated: Bool = true) -> (pane: PaneViewModel, bookmarks: [Bookmark])? {
        guard let entry = entries[id] else { return nil }
        let marks = entry.pane.bookmarks?.bookmarks ?? []
        entry.pane.bookmarks = nil
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
        // Where the hand last was and which way it went — measured over the
        // movement itself rather than over a window of time, so a nudge
        // followed by a pause is still a nudge. How fast it went is the other
        // question, and that one is asked of the last tenth of a second
        // (`PullDown.flickWindow`).
        var anchor = start
        var movement = PullDown.Movement()
        var samples = [PullDown.Sample(y: start, time: event.timestamp)]

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: .greatestFiniteMagnitude, mode: .eventTracking) { tracked, stop in
            guard let tracked else { stop.pointee = true; return }
            let y = tracked.locationInWindow.y
            samples.append(PullDown.Sample(y: y, time: tracked.timestamp))
            samples.removeAll { $0.time < tracked.timestamp - PullDown.flickWindow * 2 }
            if let direction = PullDown.Direction.of(offset: y - anchor) {
                movement.direction = direction
                anchor = y
            }
            let recent = PullDown.recentTravel(samples, direction: movement.direction)
            movement.distance = recent.distance
            movement.speed = recent.speed
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
            // At the hand's own speed: the fold carries the throw on rather
            // than starting a movement of its own.
            apply(dock.collapse(), animated: true, duration: duration,
                  throwSpeed: movement.direction == .down ? movement.speed : nil)
        }
    }

    // MARK: - Running a transition

    private func apply(_ transition: FragmentDock.Transition, animated: Bool,
                       duration: TimeInterval? = nil, closesDocument: Bool = false,
                       risesFromBelow: Bool = false, throwSpeed: CGFloat? = nil) {
        // In flight from this moment, before anything below can run a layout
        // pass — asking where the pill is lays the window out, and so does
        // refreshing the dock. A pass that ran first found the panel no longer
        // up and put it at its folded frame under the dock, so the fold
        // started from where it was meant to end and the panel just vanished.
        if animated, let folding = transition.folding { flying.insert(folding) }
        // Where a folding panel is flying to, read before the dock is brought
        // in line: a panel that is closing takes its pill with it.
        let foldTarget = transition.folding.flatMap { pillRect(for: $0) }
        // And the dock first, so a panel that has just been opened has a pill
        // to grow out of — at its full height and laid out, so the stage the
        // panel is measured against is the one it will stand on.
        refreshDock()
        if transition.raising != nil {
            host?.settleFragmentDock()
            // A panel coming up is what the reader is to look at: the large
            // view of a row's details, standing over the window, folds.
            NotificationCenter.default.post(name: .fragmentPanelRaised, object: host?.view.window)
        }
        let span = duration ?? Self.slideDuration
        // The scrim follows the stage: up while any panel is up, clear once the
        // last one has folded. A switch between two panels leaves it where it
        // is.
        let rising = risesFromBelow && transition.folding == nil
        container.setScrim(dock.expanded != nil ? 1 : 0,
                           duration: animated ? (rising ? Self.riseDuration : span) : nil)

        let raise: () -> Void = { [weak self] in
            guard let self, let raising = transition.raising,
                  let entry = self.entries[raising], self.dock.expanded == raising else { return }
            self.container.isHidden = false
            let resting = FragmentPanelView.restingFrame(in: self.container)
            if entry.view.superview !== self.container { self.container.addSubview(entry.view) }
            entry.view.frame = resting
            guard animated else { return }
            if risesFromBelow {
                self.flying.insert(raising)
                self.rise(entry.view, duration: duration ?? Self.riseDuration) { [weak self] in
                    self?.flying.remove(raising)
                }
                return
            }
            guard let pill = self.pillRect(for: raising) else { return }
            self.flying.insert(raising)
            self.fly(entry.view, to: pill, duration: span, out: false) { [weak self] in
                self?.flying.remove(raising)
            }
        }

        if let folding = transition.folding, let entry = entries[folding] {
            let land: () -> Void = { [weak self] in
                guard let self else { return }
                self.flying.remove(folding)
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
                fly(entry.view, to: pill, duration: span, out: true,
                    throwSpeed: throwSpeed) { [weak self] in
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
    /// the moment a panel is being opened — or has one not laid out yet, with
    /// no size: a flight onto that is a transform scaling the panel to zero,
    /// and a label inside it drawn in that state trips AppKit's
    /// "contentsScale != 0" assertion (macOS 15), killing the process.
    private func pillRect(for id: FragmentDock.PanelID) -> NSRect? {
        guard let inStrip = strip.pillFrame(for: id),
              inStrip.width > 0, inStrip.height > 0 else { return nil }
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
                     out: Bool, throwSpeed: CGFloat? = nil,
                     completion: @escaping () -> Void) {
        let frame = view.frame
        guard frame.width > 0, frame.height > 0, let layer = view.layer else {
            completion()
            return
        }
        let shrunk = CATransform3DMakeAffineTransform(
            PanelLanding.transform(from: frame, on: pill, anchor: layer.anchorPoint))
        let full = CATransform3DIdentity

        container.layer?.masksToBounds = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            if out {
                layer.transform = full
                layer.opacity = 1
            }
            self?.container.layer?.masksToBounds = true
            completion()
        }
        // Both ends written out rather than left to the implicit animation.
        // Setting the starting value and the finishing one in the same turn of
        // the run loop leaves Core Animation interpolating from what is on
        // screen — which is the finishing value, so the panel did not fly at
        // all and the opacity was the only thing moving.
        let flight = CABasicAnimation(keyPath: "transform")
        flight.fromValue = NSValue(caTransform3D: out ? full : shrunk)
        flight.toValue = NSValue(caTransform3D: out ? shrunk : full)
        flight.duration = duration
        let timing = throwSpeed.map {
            Self.throwTiming(speed: $0, travel: frame.maxY - pill.maxY, duration: duration)
        } ?? CAMediaTimingFunction(name: out ? .easeIn : .easeOut)
        flight.timingFunction = timing
        layer.transform = out ? shrunk : full
        layer.add(flight, forKey: "flight")

        // A fade on the way down only, and a shallow one: the panel is landing
        // on a pill, not evaporating, and on the way up a fade would blur the
        // one thing the flight is there to say.
        if out {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.35
            fade.duration = duration
            fade.timingFunction = throwSpeed == nil ? CAMediaTimingFunction(name: .easeIn) : timing
            layer.opacity = 0.35
            layer.add(fade, forKey: "fade")
        } else {
            layer.opacity = 1
        }
        CATransaction.commit()
    }

    /// Brings a panel up from under the dock edge to where it rests: a slide,
    /// not a growth out of its pill, because what the rise has to say is that
    /// the panel comes from below and lies over the panes — and a sheet that
    /// slides up is how that is said everywhere else.
    ///
    /// The layer's transform does the moving, as in `fly`, so the panel is laid
    /// out once at its resting size and not re-laid out on the way.
    private func rise(_ view: FragmentPanelView, duration: TimeInterval,
                      completion: @escaping () -> Void) {
        let frame = view.frame
        guard frame.height > 0, let layer = view.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }
        let below = CATransform3DMakeTranslation(0, -frame.maxY, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: below)
        slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        slide.duration = duration
        // Quick off the mark, settling gently: the panel arrives, it does not
        // bounce.
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(slide, forKey: "flight")
        CATransaction.commit()
    }

    /// A curve that starts at the speed the hand let go at, for a fold that
    /// carries a throw on.
    ///
    /// An ease-in fold out of a throw starts from rest, and the panel visibly
    /// stopped between the hand and the animation. The first control point's
    /// slope is the starting speed, as a share of the fold per share of its
    /// time: the panel's top edge has `travel` points to cover in `duration`,
    /// and starts covering them at `speed` — or at the fold's own average
    /// speed, whichever is faster. A throw is usually the slower of the two
    /// (1000–1500 points a second against some 4000 for the fold), and
    /// starting at it would be a visible acceleration out of the hand. Then it
    /// eases out onto the pill. Capped so a hard throw is a fast start, not a
    /// curve that overshoots its end.
    static func throwTiming(speed: CGFloat, travel: CGFloat,
                            duration: TimeInterval) -> CAMediaTimingFunction {
        guard travel > 0, duration > 0 else { return CAMediaTimingFunction(name: .linear) }
        let slope = max(1, Float(speed * CGFloat(duration) / travel))
        let x1: Float = 0.25
        return CAMediaTimingFunction(controlPoints: x1, min(x1 * slope, 0.9), 0.6, 1)
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
            let transform = Self.transform(of: entry.pane)
            return FragmentDockStrip.Item(
                id: id,
                title: entry.pane.status.fileName,
                isUp: dock.expanded == id,
                hasChanges: entry.pane.origin?.hasChanges(in: entry.pane)
                    ?? entry.pane.status.isDirty,
                canTearOff: host?.canTearOffFragment ?? false,
                transform: transform?.text,
                transformExplanation: transform?.explanation
            )
        })
        host?.setFragmentDockVisible(!dock.isEmpty)
        // The Tools popup names the tool-module of whatever is in front, so
        // raising or folding a panel changes what it should read.
        host?.revalidateToolbar()
    }

    /// The codec `pane`'s bytes went through on their way out of the file,
    /// for its pill: its own codec's, or — for a part taken out of a part
    /// that was decompressed or decoded, whose own codec only copies — the
    /// nearest such part's. A node opened out of a decompressed body holds
    /// decompressed bytes as much as the body does.
    static func transform(of pane: PaneViewModel) -> (text: String, explanation: String?)? {
        guard let origin = pane.origin else { return nil }
        if let own = origin.codec.transform {
            return (own.text, origin.codec.badge?.explanation.text)
        }
        var holder = origin.parent
        while let part = holder, let outer = part.origin {
            if let inherited = outer.codec.transform {
                return (inherited.text,
                        L("Part of “%1$@”, whose bytes were converted with %2$@ when taken out of the file.",
                          part.status.fileName, inherited.text))
            }
            holder = outer.parent
        }
        return nil
    }
}
