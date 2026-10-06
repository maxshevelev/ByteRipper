import ALSplitView
import AppKit
import HelpUI
import Localization

/// The view that frames a tool-module's panel, header and body together. The
/// large view of the details keeps clear of it, and a click inside it leaves
/// the large view open.
@MainActor public protocol ToolPanelFrame: NSView {}

extension Notification.Name {
    /// A fragment panel opened or rose over the window, posted with the
    /// window as its object. The large view of the details folds: it would
    /// stand over the panel.
    public static let fragmentPanelRaised = Notification.Name("ToolModuleKit.fragmentPanelRaised")
}

/// A panel's detail list in its splitter, and the large view it opens into —
/// the Quick Look of a row's detail.
///
/// A row's detail keeps growing — a descriptor's straps, a store's variable
/// history, a picture — and the lower third of a panel beside the dump is a
/// keyhole onto it. **Space** on the row in focus, or the expand button in the
/// list's corner, opens the same list as a large card over the window; **Space**
/// again, **Esc**, the close button in the corner, a click outside the card and
/// the tool panel, a link followed from it or a fragment panel opening closes
/// it. While it is open the arrow keys still move the table's selection, and
/// the card follows.
///
/// The card keeps clear of the tool panel it belongs to — the header, the
/// table, the search and the legend — so everything in the panel stays in
/// reach while the card is out: a click on a row, the triangle that opens one,
/// a menu, the search or the legend does what it was for and leaves the card
/// where it is, and the card shows the row selected. The panel is the view
/// that adopts `ToolPanelFrame`; where there is none, the card has the window
/// to itself.
///
/// The card flies out of the pane and back into it. The pane folds away while
/// the card is out — the table above takes the whole height, which is what a
/// reader looking at the card and moving through the rows wants — and the
/// card's flight runs on the splitter's own animation clock, so the two move
/// as one rather than as two animations drifting apart. The card is two
/// thirds of the window wide and stands to the right, clear of the window's
/// top edge by a margin and of its bottom and right edges by a tighter one,
/// leaving the
/// panel's table in view on its left; it is not dimmed around, so the dump
/// and the table stay readable beside it.
///
/// The card holds **the list itself**, moved out of its pane and back, not a
/// second copy of it. A copy would need every panel to render twice, and
/// would lose what one list keeps for free: its scroll, its selection, its
/// `?`, a picture's chosen background, a re-render at a new zoom. On the
/// flight out the list is already at the card's final size, clipped by the
/// growing card, so its rows do not re-wrap on every frame; on the flight
/// back the card lands exactly on the pane and the list is put back there in
/// the same moment, so the pane is never seen empty.
///
/// The card lives in the window's content view, not in a window of its own:
/// a borderless child window takes the key focus from the table the arrow
/// keys must keep moving, and is one more window for the tests to wait on.
@MainActor public final class ToolDetailPane: NSView {
    /// The list. A panel fills it exactly as it would a bare `ToolDetailScroll`.
    public let detail = ToolDetailScroll()

    /// The table whose rows the list details: Space on it opens and closes
    /// the large view, and the arrow keys pressed while it is open move it.
    private weak var table: NSTableView?

    /// The card, from the moment it leaves the pane until it is back in it.
    private var card: QuickLookCard?
    /// Whether the card has landed and follows the window's size.
    private var cardIsResting = false
    /// The window's content view resizing, watched while the card is out.
    private var hostObserver: NSObjectProtocol?
    /// The tool panel's frame changing — its divider dragged — watched while
    /// the card is out, so the card keeps clear of it.
    private var panelObserver: NSObjectProtocol?
    /// A fragment panel rising, watched while the card is out.
    private var raisedObserver: NSObjectProtocol?
    /// The splitter's policy for the pane before it folded away, put back
    /// when the pane opens again. Nil while the pane is open.
    private var unfoldedLayout: ALSplitView.PaneLayout?
    /// Space on the table, watched while the pane is in a window.
    private var spaceMonitor: Any?
    /// The keys and clicks the large view answers, watched while it is shown.
    private var shownMonitors: [Any] = []
    /// Counts the transitions, so the tick of one a later one replaced does
    /// nothing.
    private var generation = 0

    /// How long the card takes to fly out or back.
    static let flight: TimeInterval = 0.25
    /// The card's margin to the window's top and left edges: the toolbar
    /// above it wants the air.
    static let margin: CGFloat = 30
    /// The card's margin to the window's right and bottom edges, tighter —
    /// the card has nothing there to keep apart from but the window's frame.
    static let edgeMargin: CGFloat = 12
    /// What is left clear between the card and the tool panel beside it.
    static let gap: CGFloat = 12
    /// The narrowest the card is drawn, however little room the panel leaves.
    static let minimumWidth: CGFloat = 200
    /// How much of the window's width the card takes. What is left lies on
    /// its left, so the panel's table stays in view.
    static let widthShare: CGFloat = 2.0 / 3

    /// Whether the large view is open.
    public private(set) var isQuickLookShown = false

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        Self.place(detail, in: self)
        detail.onExpand = { [weak self] in self?.toggleQuickLook() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Names the table whose rows the list details. Space on it — with no
    /// modifier, while it has the focus — opens the large view.
    public func attach(to table: NSTableView) {
        self.table = table
    }

    /// Opens the large view, or closes it. False — the key is not taken — when
    /// it is shut and there is nothing to show: no row in focus, or a pane
    /// that is not in a window.
    // help: panel.detail-quick-look
    @discardableResult
    public func toggleQuickLook() -> Bool {
        if isQuickLookShown {
            closeQuickLook()
            return true
        }
        return showQuickLook()
    }

    /// Opens the large view: the card flies out of the pane, and the pane
    /// folds away. False when there is nothing to show in it.
    @discardableResult
    public func showQuickLook() -> Bool {
        guard !isQuickLookShown, detail.hasRows, let host = window?.contentView else { return false }
        isQuickLookShown = true
        generation += 1
        let flight = generation

        // A flight back still under way is the same card, holding the list:
        // it turns round where it is rather than starting from the pane.
        let card = self.card ?? takeOut(into: host)
        cardIsResting = false
        detail.isExpanded = true
        let start = card.frame
        let target = restingFrame(in: host)
        card.contentFollowsFrame = false
        card.setContentSize(target.size)

        fold { [weak self] progress in
            guard let self, self.generation == flight else { return }
            card.frame = Self.interpolate(start, target, progress)
            if progress >= 1 {
                self.cardIsResting = true
                card.contentFollowsFrame = true
            }
        }
        // The focus goes to the table, wherever Space came from — the table
        // or the details — so the arrows move its selection while the card
        // is out.
        if let table { window?.makeFirstResponder(table) }
        watchWhileShown()
        return true
    }

    /// Closes the large view: the pane opens again, and the card flies back
    /// into it, giving it the list as it lands.
    public func closeQuickLook() {
        guard isQuickLookShown else { return }
        isQuickLookShown = false
        generation += 1
        let flight = generation
        stopWatchingWhileShown()
        detail.isExpanded = false
        // The focus goes back to the table, which is where Space came from
        // and where a selectable value in the card would otherwise keep it.
        if let table, table.window != nil { table.window?.makeFirstResponder(table) }
        guard let card, let host = card.superview else {
            takeBack()
            return
        }
        cardIsResting = false
        // Flying back, the card shrinks round a list that stays the size it
        // is, as it flew out.
        card.contentFollowsFrame = false
        let start = card.frame
        unfold(landing: { [weak self] in
            self.map { $0.convert($0.bounds, to: host) } ?? start
        }, tick: { [weak self] progress, landing in
            guard let self, self.generation == flight else { return }
            card.frame = Self.interpolate(start, landing, progress)
            // The table gives back the room the pane takes: the row the
            // arrows moved to while the card was out stays on screen.
            self.keepSelectionInView()
            if progress >= 1 { self.takeBack() }
        })
    }

    /// Scrolls the table to its selected row, if it has one.
    private func keepSelectionInView() {
        guard let table, table.selectedRow >= 0 else { return }
        // At the size the table has now, not the one the last layout left it.
        splitter?.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(table.selectedRow)
    }

    // MARK: - The card

    /// The list, moved out of the pane into a new card standing where the
    /// pane is.
    private func takeOut(into host: NSView) -> QuickLookCard {
        let card = QuickLookCard()
        card.frame = convert(bounds, to: host)
        host.addSubview(card)
        self.card = card
        detail.borderType = .noBorder
        card.hold(detail)
        host.postsFrameChangedNotifications = true
        hostObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: host, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTheWindow() }
        }
        if let panel = toolPanel {
            panel.postsFrameChangedNotifications = true
            panelObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.followTheWindow() }
            }
        }
        return card
    }

    /// The list back in its pane, laid out there at once, and the card gone.
    private func takeBack() {
        if let hostObserver { NotificationCenter.default.removeObserver(hostObserver) }
        hostObserver = nil
        if let panelObserver { NotificationCenter.default.removeObserver(panelObserver) }
        panelObserver = nil
        cardIsResting = false
        guard let card else { return }
        self.card = nil
        // The list home before the card goes: taken away holding it, the
        // card would take the list out of the window with it.
        detail.borderType = .bezelBorder
        card.releaseContentSize()
        Self.place(detail, in: self)
        card.removeFromSuperview()
        // Now, not on the next pass: the card has just landed on the pane,
        // and a pane drawn empty for one frame is the gap a reader sees.
        layoutSubtreeIfNeeded()
        detail.display()
        keepSelectionInView()
    }

    /// A landed card keeps its place as the window is resized.
    private func followTheWindow() {
        guard cardIsResting, let card, let host = card.superview else { return }
        let target = restingFrame(in: host)
        card.setContentSize(target.size)
        card.frame = target
    }

    /// The tool panel the pane is in, if it is in one: the nearest view above
    /// it that frames a panel.
    private var toolPanel: NSView? {
        var view = superview
        while let candidate = view {
            if candidate is ToolPanelFrame { return candidate }
            view = candidate.superview
        }
        return nil
    }

    /// Where the card stands once it has landed: two thirds of the window's
    /// width, a margin from its top edge and a tighter one from its bottom and
    /// right edges, and clear of the
    /// tool panel — on the far side of it from the window's middle, a gap from
    /// its edge — so the width is what the panel leaves when it is wider than
    /// a third of the window.
    private func restingFrame(in host: NSView) -> NSRect {
        let bounds = host.bounds
        var left = bounds.minX + Self.margin
        var right = bounds.maxX - Self.edgeMargin
        var anchoredRight = true
        if let panel = toolPanel {
            let frame = panel.convert(panel.bounds, to: host)
            if frame.midX <= bounds.midX {
                left = max(left, frame.maxX + Self.gap)
            } else {
                right = min(right, frame.minX - Self.gap)
                anchoredRight = false
            }
        }
        let width = max(Self.minimumWidth, min((bounds.width * Self.widthShare).rounded(), right - left))
        return NSRect(x: anchoredRight ? right - width : left,
                      y: bounds.minY + Self.edgeMargin,
                      width: width,
                      height: max(120, bounds.height - Self.margin - Self.edgeMargin))
    }

    private static func interpolate(_ from: NSRect, _ to: NSRect, _ progress: CGFloat) -> NSRect {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return NSRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height)).integral
    }

    // MARK: - The pane folding

    /// The splitter the pane is the last pane of — the one it folds in — or
    /// nil when it is anywhere else.
    private var splitter: ALSplitView? {
        guard let split = superview as? ALSplitView, split.panes.last === self else { return nil }
        return split
    }

    /// Folds the pane away, handing `tick` the eased progress of each frame.
    /// At once, with one tick of 1, when there is no splitter to fold in.
    private func fold(tick: @escaping (CGFloat) -> Void) {
        guard let splitter else {
            tick(1)
            return
        }
        let index = splitter.panes.count - 1
        if unfoldedLayout == nil { unfoldedLayout = splitter.paneLayouts[index] }
        let flight = generation
        splitter.animateTrailingPaneSize(to: 0, duration: Self.flight) { [weak self] progress in
            tick(progress)
            guard progress >= 1 else { return }
            // Folded by a fixed zero rather than whatever share the last
            // frame left, so the splitter drops the divider at its edge.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == flight else { return }
                    splitter.setPaneLayout(.fixed(0), at: index)
                }
            }
        }
    }

    /// Opens the pane again to the size it had, handing `tick` the eased
    /// progress of each frame and where the pane will be once open, in the
    /// card's coordinates (`landing`).
    private func unfold(landing: () -> NSRect, tick: @escaping (CGFloat, NSRect) -> Void) {
        guard let splitter, let unfolded = unfoldedLayout else {
            tick(1, landing())
            return
        }
        let index = splitter.panes.count - 1
        // Where the pane lands is where its policy puts it: laid out once
        // under that policy to read it, and put back as it was before
        // anything is drawn.
        let folded = splitter.paneLayouts[index]
        splitter.setPaneLayout(unfolded, at: index)
        let size = frame.height
        let target = landing()
        splitter.setPaneLayout(folded, at: index)

        let flight = generation
        splitter.animateTrailingPaneSize(to: size, duration: Self.flight) { [weak self] progress in
            tick(progress, target)
            guard progress >= 1 else { return }
            // The policy itself back, not only the size it came to: a share
            // keeps its share as the window is resized.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == flight else { return }
                    splitter.setPaneLayout(unfolded, at: index)
                    self.unfoldedLayout = nil
                }
            }
        }
    }

    /// Ends whatever the pane and the card are doing, at once: the card
    /// landed or gone, the pane folded or open.
    private func settle() {
        generation += 1
        if let splitter {
            let index = splitter.panes.count - 1
            // A size it already has stops the running animation and moves
            // nothing.
            splitter.animateTrailingPaneSize(to: frame.height, duration: 0)
            if isQuickLookShown {
                splitter.setPaneLayout(.fixed(0), at: index)
            } else if let unfolded = unfoldedLayout {
                splitter.setPaneLayout(unfolded, at: index)
                unfoldedLayout = nil
            }
        }
        if isQuickLookShown {
            cardIsResting = true
            card?.contentFollowsFrame = true
            followTheWindow()
        } else {
            takeBack()
        }
    }

    /// Pins `view` to every edge of `container`, moving it there first.
    ///
    /// Moved by `addSubview` alone, never `removeFromSuperview` first: taken
    /// out, the list leaves the window for a moment, and the window then
    /// re-adds and re-solves every constraint of its hundreds of views —
    /// measured on a descriptor's straps at 0.4 to 1.2 seconds a move, which
    /// is the card standing still before it flies. Moved directly, it stays
    /// in the window and keeps its layout: a few milliseconds.
    static func place(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - The keys and clicks

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, window != nil else { return }
        // A panel closed or swapped with the view open: nothing is left for
        // the card to be about, and the list and the pane must be as they
        // were before the panel is shown again.
        if isQuickLookShown {
            isQuickLookShown = false
            stopWatchingWhileShown()
            detail.isExpanded = false
        }
        settle()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        } else if spaceMonitor == nil {
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handleKeyWhileShut(event) == true }
                return taken ? nil : event
            }
        }
    }

    /// What a key pressed in the window does while the large view is shut:
    /// Space, unmodified, opens it while the focus is on the table or in the
    /// details under it — a reader who has clicked into the details to
    /// select a value is reading them, and wants them larger just as much.
    /// True when it was taken.
    func handleKeyWhileShut(_ event: NSEvent) -> Bool {
        guard !isQuickLookShown, let table, let window = table.window,
              event.window === window, Self.isPlainSpace(event),
              let focus = window.firstResponder as? NSView,
              focus === table || focus.isDescendant(of: detail)
        else { return false }
        return showQuickLook()
    }

    private static func isPlainSpace(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == " "
            && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
    }

    private func watchWhileShown() {
        guard shownMonitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.handleKeyWhileShown(event) == true }
            return taken ? nil : event
        }) {
            shownMonitors.append(keys)
        }
        if let clicks = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleClickWhileShown(event) }
                return event
            }
        ) {
            shownMonitors.append(clicks)
        }
        // A fragment panel opening or rising is a new thing to look at, and
        // the card would stand over it.
        raisedObserver = NotificationCenter.default.addObserver(
            forName: .fragmentPanelRaised, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeQuickLook() }
        }
    }

    private func stopWatchingWhileShown() {
        shownMonitors.forEach(NSEvent.removeMonitor)
        shownMonitors.removeAll()
        if let raisedObserver { NotificationCenter.default.removeObserver(raisedObserver) }
        raisedObserver = nil
    }

    /// Key codes of the arrows, which still move the table beside the card.
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
    private static let escapeKey: UInt16 = 53

    /// Whether the focus is in text being edited — the search field — where
    /// Space, Esc and the arrows are the field's. A selectable value in the
    /// details is not: its field editor does not edit.
    private var isEditingText: Bool {
        (window?.firstResponder as? NSTextView)?.isEditable == true
    }

    /// What a key pressed in the window does while the large view is open.
    /// True when it was taken. A key in another window — the `?`'s popover,
    /// the help — is that window's, and a key typed into a field is the field's.
    func handleKeyWhileShown(_ event: NSEvent) -> Bool {
        guard isQuickLookShown, event.window === window, !isEditingText else { return false }
        if event.keyCode == Self.escapeKey || Self.isPlainSpace(event) {
            closeQuickLook()
            return true
        }
        if Self.arrowKeys.contains(event.keyCode), let table {
            table.keyDown(with: event)
            return true
        }
        return false
    }

    /// A click in the window outside the card and the tool panel closes the
    /// large view, and still does what it was for: nothing is dimmed or
    /// covered, so a click on the dump or the toolbar lands there. A click in
    /// the tool panel — a row, the triangle of one, a menu, the search, the
    /// legend — is the panel's, and the card stays.
    func handleClickWhileShown(_ event: NSEvent) {
        guard isQuickLookShown, let card, event.window === window,
              let content = window?.contentView, let frame = content.superview
        else { return }
        let point = frame.convert(event.locationInWindow, from: nil)
        let hit = frame.hitTest(point)
        guard hit?.isDescendant(of: card) != true else { return }
        if let panel = toolPanel, hit?.isDescendant(of: panel) == true { return }
        // Moving or resizing the window is not a click on anything: the
        // title bar and the toolbar's bare ground drag it, the window's
        // buttons act on it, and a few points at its edges take hold of it
        // to resize. The card follows the window; folding it there made the
        // reader open it again after every move.
        if !content.frame.insetBy(dx: Self.edgeGrab, dy: Self.edgeGrab).contains(point) {
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let isWindowButton = buttons.contains { window?.standardWindowButton($0) === hit }
            var isControl = false
            var view = hit
            while let current = view, !isControl {
                isControl = current is NSControl
                view = current.superview
            }
            if isWindowButton || !isControl { return }
        }
        closeQuickLook()
    }

    /// How far inside the window's edge a press still takes hold of the edge
    /// to resize the window.
    private static let edgeGrab: CGFloat = 6

    // MARK: - For the tests

    /// The card the list sits in while the large view is open.
    public var quickLookCardForTesting: NSView? { card }

    /// Ends a flight at once, so a test sees the state it waits for.
    public func finishTransitionForTesting() {
        settle()
    }
}

/// The card: rounded, framed and shadowed, the window's background behind
/// the list. Frame-based — the pane places it, frame by frame in flight —
/// with the list inside at the size the card will have once it has landed,
/// pinned to the top left, so a card smaller than that clips it rather than
/// re-wrapping it.
@MainActor private final class QuickLookCard: NSView {
    /// The rounded body: what clips the list and carries the frame line. The
    /// shadow is the card's own, outside it — a layer that clips cannot cast
    /// one.
    private let body = QuickLookCardBody()
    private var contentWidth: NSLayoutConstraint?
    private var contentHeight: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
        wantsLayer = true
        layer?.masksToBounds = false
        // Sized by `setFrameSize`, not by an autoresizing mask: the mask
        // scales the body by the ratio of the old size to the new, and a
        // card resized in fractional steps drifted from its body by a
        // fraction of a point at each one.
        body.frame = bounds
        body.autoresizingMask = []
        addSubview(body)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Details"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Puts `content` in the card, pinned to its top left.
    func hold(_ content: NSView) {
        // Not taken out first, for the reason `ToolDetailPane.place` gives.
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        let width = content.widthAnchor.constraint(equalToConstant: max(1, bounds.width))
        let height = content.heightAnchor.constraint(equalToConstant: max(1, bounds.height))
        contentWidth = width
        contentHeight = height
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: body.topAnchor),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            width, height,
        ])
    }

    /// Lets go of the content's size: the card's own width and height
    /// constraints are on the content itself, and stay active when it is moved
    /// back to the pane. The next card added its own beside them, the two
    /// disagreed once the window had changed size, and the old size won — a
    /// big card round a list as big as the window used to be.
    func releaseContentSize() {
        let sizes = [contentWidth, contentHeight].compactMap { $0 }
        NSLayoutConstraint.deactivate(sizes)
        contentWidth = nil
        contentHeight = nil
        contentFollowsFrame = false
    }

    /// The size the content is laid out at: the card's once it has landed.
    func setContentSize(_ size: NSSize) {
        contentWidth?.constant = size.width
        contentHeight?.constant = size.height
        body.layoutSubtreeIfNeeded()
    }

    /// Whether the content is the card's own size, whatever sets the card's
    /// frame: true once the card has landed. Out on its flight the content is
    /// already at its final size and the card still smaller, clipping it.
    ///
    /// A resting card whose frame was set by anything but the pane's own
    /// following of the window — the window animating, a split moving —
    /// left the list at the size it had landed at, with the card's bigger
    /// body showing grey round it.
    var contentFollowsFrame = false {
        didSet { if contentFollowsFrame { setContentSize(bounds.size) } }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        body.frame = NSRect(origin: .zero, size: newSize)
        if contentFollowsFrame { setContentSize(newSize) }
        // A corner no larger than half a side: a card still leaving a pane
        // a few points tall is a rectangle a full radius does not fit.
        let radius = max(0, min(QuickLookCardBody.radius, newSize.width / 2, newSize.height / 2))
        layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: newSize),
                                   cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.6 : 0.3
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    // A click on the card is the card's: passed up the responder chain it
    // would reach views that are not about it.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}

@MainActor private final class QuickLookCardBody: NSView {
    static let radius: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
