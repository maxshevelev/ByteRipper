import Cocoa
import Localization

/// Single-file mode's content view (§4.3, amended by §22.4): wraps the
/// `FilePaneView` and splits the window into two targeted drop regions along
/// the current or default pane layout (left/right ⇄ top/bottom). The "this
/// file" half is divided into three horizontal bands — Insert at Start (top),
/// Replace Current File (middle), Append at End (bottom) — and the "second
/// file" half is the single Open for Comparison target.
///
/// This view is a plain container: it is NOT drop-registered. Each half is a
/// self-contained drop region (`PaneDropBandsView` and `DropZoneView`) that is
/// always present and transparent, shows its visuals only for the drag's
/// lifetime, and fires its own `onDrop`. Dropping outside a drag, or leaving
/// the window, restores the normal pane with no change.
final class SingleFileDropView: NSView {
    /// Fired when the user drops on one of the targets or bands.
    var onDrop: ((SingleFileDropTarget, [URL]) -> Void)?

    /// The two halves' split, and the whole-view alternative to it. A drop that
    /// cannot use the second half gets no second half — the bands take the room
    /// rather than leaving a reserved space for something that will not happen.
    private var bandsShareHalf: NSLayoutConstraint?
    private var bandsTakeAll: NSLayoutConstraint?

    /// Whether the second-pane half is on offer, and so whether the bands share
    /// the view with it.
    private func setSecondHalfOffered(_ offered: Bool) {
        guard bandsShareHalf?.isActive != offered else { return }
        bandsShareHalf?.isActive = offered
        bandsTakeAll?.isActive = !offered
        addTarget.isHidden = !offered
        applyAdjoiningEdges()
        layoutSubtreeIfNeeded()
    }

    /// The pane being dragged over this view, or nil when what is in flight is
    /// not a pane.
    ///
    /// A pane gets the **same four zones a file gets** — the three bands over
    /// this file and the second-pane half beside them — because they mean the
    /// same four things. A pane holds a dump: joining it at either end is the
    /// two-chip round trip (§22), replacing puts it in this pane's place, and
    /// the far half opens it as the second pane, which is the comparison.
    private var draggedPaneID: UUID?

    /// Asks what letting the dragged pane go here would do. A single-file window
    /// has a free second pane, so the answer is normally "move it in beside this
    /// one" — but it is the controller's to give, and it says no to a pane from
    /// this very window, which has nowhere else to be.
    var paneDropOutcome: ((_ draggedPaneID: UUID, _ target: SingleFileDropTarget,
                           _ copying: Bool) -> PaneDrop.Outcome)?

    /// Fired when a dragged pane is let go here, in the zone it landed in.
    var onPaneDropped: ((_ draggedPaneID: UUID, _ target: SingleFileDropTarget,
                        _ copying: Bool) -> Void)?

    /// Whether the drag in flight is asking to copy — the Option key, re-read on
    /// every update so the zones re-label as it is pressed and released.
    private var draggedPaneIsCopying = false

    /// Fired when Option goes down or up over this view, which is the only place
    /// the news arrives while the pointer is here. See
    /// `PaneDropBandsView.onCopyModifierChanged`.
    var onCopyModifierChanged: ((Bool) -> Void)?

    /// Fired when a drag session starts here and when it ends — never when it
    /// merely leaves. See `PaneDropBandsView.onDragSessionChanged`: leaving is
    /// what aiming at the New Tab strip looks like from here.
    var onDragSessionChanged: ((Bool) -> Void)?

    /// Fired as a file drag comes over this view, leaves it, and ends. See
    /// `PaneDropBandsView.onFileDragPresence`.
    var onFileDragPresence: ((FileDragPresence) -> Void)?
    private var carryingFiles = false

    let paneView: FilePaneView

    /// The three bands of the "this file" half — a self-contained drop region.
    /// The three-band overlay over the pane's own half. Internal so the window
    /// can inset its bands by the New Tab strip's share, the way it does for the
    /// comparison's two overlays (`Design/PANE_DRAG_PLAN.md`).
    let thisFileBands = PaneDropBandsView()
    /// The "second file" half — a self-contained single-target drop region.
    private let addTarget = DropZoneView(title: SingleFileDropTarget.addSecond.title)

    /// The constraints that split this view into its two halves, held so the
    /// split can be re-made when the pane layout direction changes.
    private var splitConstraints: [NSLayoutConstraint] = []
    private var layoutDirectionObserver: NSObjectProtocol?

    init(paneView: FilePaneView) {
        self.paneView = paneView
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        addSubview(paneView)
        paneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: topAnchor),
            paneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            paneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        thisFileBands.translatesAutoresizingMaskIntoConstraints = false
        addTarget.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thisFileBands)
        addSubview(addTarget)

        applySplit(isVertical: LayoutSettings.isVertical)
        // The direction is settings, not a constant, and it can change while
        // this view is on screen — with one file open there is no comparison for
        // the controller to re-apply it to, so nothing else would rebuild this
        // split. Read once at construction, it went on offering the old
        // arrangement: a drop overlay divided side by side over panes that had
        // been told to stack.
        layoutDirectionObserver = NotificationCenter.default.addObserver(
            forName: LayoutSettings.layoutDirectionDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySplit(isVertical: LayoutSettings.isVertical)
            }
        }

        // `.pane` as well as the file types: a pane dragged here goes into the
        // free second pane, which is the comparison the gesture was for. Handling
        // it without registering for it is silent — AppKit simply never delivers
        // the drag, and the zone never appears (`Design/PANE_DRAG_PLAN.md`).
        registerForDraggedTypes([.fileURL, .fileNames, .pane])
    }

    deinit {
        if let layoutDirectionObserver {
            NotificationCenter.default.removeObserver(layoutDirectionObserver)
        }
    }

    /// Divides the view into its two halves along `isVertical`: side by side
    /// (left/right) or stacked (top/bottom), matching how the panes themselves
    /// are arranged (§4.3). The "this file" half holds the three bands; the
    /// "second file" half holds the single Open for Comparison target.
    private func applySplit(isVertical: Bool) {
        NSLayoutConstraint.deactivate(splitConstraints)
        bandsShareHalf?.isActive = false
        bandsTakeAll?.isActive = false

        let half: NSLayoutConstraint
        let all: NSLayoutConstraint
        var constraints: [NSLayoutConstraint]
        if isVertical {
            half = thisFileBands.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5)
            all = thisFileBands.widthAnchor.constraint(equalTo: widthAnchor)
            constraints = [
                thisFileBands.leadingAnchor.constraint(equalTo: leadingAnchor),
                thisFileBands.topAnchor.constraint(equalTo: topAnchor),
                thisFileBands.bottomAnchor.constraint(equalTo: bottomAnchor),
                addTarget.leadingAnchor.constraint(equalTo: thisFileBands.trailingAnchor),
                addTarget.trailingAnchor.constraint(equalTo: trailingAnchor),
                addTarget.topAnchor.constraint(equalTo: topAnchor),
                addTarget.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            half = thisFileBands.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5)
            all = thisFileBands.heightAnchor.constraint(equalTo: heightAnchor)
            constraints = [
                thisFileBands.leadingAnchor.constraint(equalTo: leadingAnchor),
                thisFileBands.trailingAnchor.constraint(equalTo: trailingAnchor),
                thisFileBands.topAnchor.constraint(equalTo: topAnchor),
                addTarget.topAnchor.constraint(equalTo: thisFileBands.bottomAnchor),
                addTarget.bottomAnchor.constraint(equalTo: bottomAnchor),
                addTarget.leadingAnchor.constraint(equalTo: leadingAnchor),
                addTarget.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }
        bandsShareHalf = half
        bandsTakeAll = all
        splitIsVertical = isVertical
        // The half is the resting state; `setSecondHalfOffered` swaps to `all`
        // when a drop has nothing to put in the second half.
        half.isActive = true
        constraints.append(half)
        NSLayoutConstraint.activate(constraints)
        splitConstraints = constraints
        applyAdjoiningEdges()
    }

    /// Which way the halves are split, for the edge they share.
    private var splitIsVertical = true

    /// Tells both halves which edge they share, so the gap between their
    /// plates is the padding once rather than twice. With the second half not
    /// on offer, the bands have every edge to themselves.
    private func applyAdjoiningEdges() {
        let shared = bandsShareHalf?.isActive ?? true
        thisFileBands.adjoiningEdge = shared ? (splitIsVertical ? .maxX : .minY) : nil
        addTarget.setAdjoiningEdge(splitIsVertical ? .minX : .maxY)
    }

    /// The "second file" half, so a test can read whether it is up and lit.
    var secondHalfForTesting: DropZoneView { addTarget }

    /// Which way this view is split (for tests).
    var isSplitVerticallyForTesting: Bool {
        bandsShareHalf?.firstAttribute == .width
    }

    // MARK: - Drag targeting (§4.3)

    /// The drop destination for the whole single-file content area. The two
    /// overlay halves (`thisFileBands`, `addTarget`) are purely visual and pass
    /// mouse events through to the hex dump; the file drag is owned here, by the
    /// always-present container that is the hex view's ancestor, so the drag
    /// system reaches it by walking up from the hex view (§4.3).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A pane, unlike a file, is not joined at one end or the other: there is
        // one free pane in a single-file window and that is where it goes, so
        // the whole view is one target rather than the file bands.
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            draggedPaneID = paneID
            notePaneDragCopying(sender.isCopyRequested)
            return paneOperation(at: sender.draggingLocation)
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        carryingFiles = true
        onDragSessionChanged?(true)
        onFileDragPresence?(.entered)
        updateDragTarget(at: sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPaneID != nil {
            notePaneDragCopying(sender.isCopyRequested)
            return paneOperation(at: sender.draggingLocation)
        }
        updateDragTarget(at: sender.draggingLocation)
        return .copy
    }

    /// Lights the zone under the pointer and reports what letting go there would
    /// mean. A join is a copy — the pane it came from is left as it was — while
    /// replacing and opening as the second pane move it.
    private func paneOperation(at windowPoint: NSPoint) -> NSDragOperation {
        guard let paneID = draggedPaneID else { return [] }
        // A pane that cannot become this window's second one — because it is
        // already in this window — leaves that half with nothing to say, so the
        // bands take the whole view instead of standing beside a reserved space
        // for something that will not happen.
        let secondHalf = paneDropOutcome?(paneID, .addSecond, draggedPaneIsCopying) ?? .none
        setSecondHalfOffered(secondHalf != .none)
        let target = dropTarget(at: windowPoint) ?? .addSecond
        let outcome = paneDropOutcome?(paneID, target, draggedPaneIsCopying) ?? .none
        retitlePaneZones(for: paneID, secondHalf: secondHalf)
        // A zone with nothing to offer is not shown, and the cursor refuses;
        // the other zones stay up — taking them all down there hid the places
        // the pane could go. The second half with nothing to offer is not there
        // at all.
        updateDragTarget(at: windowPoint)
        switch outcome {
        // A join and a duplicate both copy — the pane they came from is left
        // as it was — so the cursor carries the + that says so.
        case .join, .duplicate: return .copy
        case .swap, .move: return .move
        case .none, .tearOff: return []
        }
    }

    /// Captions the four zones from what each of them would do.
    ///
    /// `secondHalf` is that zone's outcome, passed in when the caller has just
    /// asked for it rather than asked for again.
    private func retitlePaneZones(for paneID: UUID, secondHalf: PaneDrop.Outcome? = nil) {
        // This view owns the provider, so it is the one that can answer for a
        // band; the overlay's own is nil here.
        thisFileBands.retitleBands(forPane: paneID) { [weak self] band in
            guard let self else { return .none }
            return self.paneDropOutcome?(paneID, band, self.draggedPaneIsCopying) ?? .none
        }
        // Captioned from what it will do, like the bands are. A pane from
        // elsewhere becomes this window's second one, so the zone's own name is
        // the right words for it; the window's own pane is copied, and "Open as
        // Second Pane" would say nothing about the copy being made.
        let second = secondHalf
            ?? paneDropOutcome?(paneID, .addSecond, draggedPaneIsCopying)
            ?? .none
        addTarget.setTitle(second.isDuplicate
                           ? L("Duplicate Here")
                           : SingleFileDropTarget.addSecond.title)
    }

    /// Records the modifier and tells the window when it changed, so the zones
    /// that are not under the pointer can be re-captioned too.
    private func notePaneDragCopying(_ copying: Bool) {
        guard draggedPaneIsCopying != copying else { return }
        draggedPaneIsCopying = copying
        onCopyModifierChanged?(copying)
    }

    /// Takes a modifier change heard by another zone — the New Tab strip above,
    /// or a zone in another window — and re-captions these ones from it. Silent
    /// when no pane is in flight here, and never fires `onCopyModifierChanged`:
    /// this is the news arriving, not being made.
    func setPaneDragCopying(_ copying: Bool) {
        guard let paneID = draggedPaneID, draggedPaneIsCopying != copying else { return }
        draggedPaneIsCopying = copying
        retitlePaneZones(for: paneID)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // A pane's zones stay up unlit while its drag goes on: the window put
        // them up for it.
        if paneSessionShown {
            thisFileBands.clearHover()
            addTarget.setHighlighted(false)
            return
        }
        endPaneDrag()
        clearDragTarget()
        // A file's zones come back unlit at once: the window shows every zone
        // while the file is over any of them.
        if carryingFiles {
            carryingFiles = false
            onFileDragPresence?(.exited)
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragSessionChanged?(false)
        paneSessionShown = false
        endPaneDrag()
        clearDragTarget()
        carryingFiles = false
        onFileDragPresence?(.ended)
    }

    /// Whether the window has put the zones up for a pane drag in flight
    /// anywhere. See `PaneDropBandsView.showForPaneDrag`.
    private var paneSessionShown = false

    /// Puts the zones up, unlit, for the pane with `paneID` being dragged
    /// anywhere in the app — each saying what letting it go there would do, a
    /// zone that would refuse it left off — or takes them down for nil.
    func showForPaneDrag(_ paneID: UUID?, copying: Bool) {
        guard let paneID else {
            guard paneSessionShown else { return }
            paneSessionShown = false
            endPaneDrag()
            clearDragTarget()
            return
        }
        paneSessionShown = true
        draggedPaneID = paneID
        draggedPaneIsCopying = copying
        let secondHalf = paneDropOutcome?(paneID, .addSecond, copying) ?? .none
        setSecondHalfOffered(secondHalf != .none)
        retitlePaneZones(for: paneID, secondHalf: secondHalf)
        thisFileBands.setDragActive(true)
        thisFileBands.clearHover()
        addTarget.setDragActive(true)
        addTarget.setHighlighted(false)
    }

    /// Shows both halves unlit for a file that is over another of the window's
    /// zones, or takes them down when it has gone (§4.3). The zone under the
    /// pointer lights itself; this leaves its highlight alone. Silent while a
    /// pane is in flight here.
    func showForFileDrag(_ shown: Bool) {
        guard draggedPaneID == nil else { return }
        if shown {
            thisFileBands.setDragActive(true)
            addTarget.setDragActive(true)
        } else {
            clearDragTarget()
        }
    }

    /// Forgets the pane in flight and puts the zones' captions back to the ones
    /// a file gets, so the next file drag does not read as a join of panes.
    private func endPaneDrag() {
        draggedPaneID = nil
        setSecondHalfOffered(true)
        thisFileBands.retitleBandsForFile()
        addTarget.setTitle(SingleFileDropTarget.addSecond.title)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            let target = dropTarget(at: sender.draggingLocation) ?? .addSecond
            let copying = sender.isCopyRequested
            paneSessionShown = false
            endPaneDrag()
            clearDragTarget()
            onPaneDropped?(paneID, target, copying)
            return true
        }
        let urls = sender.draggingPasteboard.droppedFileURLs
        onDragSessionChanged?(false)
        clearDragTarget()
        carryingFiles = false
        onFileDragPresence?(.ended)
        guard !urls.isEmpty else { return true }
        let target = dropTarget(at: sender.draggingLocation) ?? .addSecond
        onDrop?(target, urls)
        return true
    }

    /// The drop target under the window point: one of the three bands when the
    /// pointer is in the "this file" half, or the Open for Comparison target when it
    /// is in the "second file" half.
    private func dropTarget(at windowPoint: NSPoint) -> SingleFileDropTarget? {
        if let band = thisFileBands.band(at: windowPoint) { return band }
        // The pointer is in the "second file" half (outside the bands' bounds).
        return .addSecond
    }

    /// Shows both halves and lights the band or target under the pointer; the
    /// rest stay up, unlit, so every place the file can go is in view (§4.3).
    private func updateDragTarget(at windowPoint: NSPoint) {
        thisFileBands.setDragActive(true)
        addTarget.setDragActive(true)
        if thisFileBands.band(at: windowPoint) != nil {
            thisFileBands.updateHover(at: windowPoint)
            addTarget.setHighlighted(false)
        } else {
            thisFileBands.clearHover()
            addTarget.setHighlighted(true)
        }
    }

    private func clearDragTarget() {
        thisFileBands.setDragActive(false)
        thisFileBands.clearHover()
        addTarget.setDragActive(false)
        addTarget.setHighlighted(false)
    }
}
