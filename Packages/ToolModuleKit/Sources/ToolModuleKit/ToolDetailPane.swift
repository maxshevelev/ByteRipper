import AppKit
import HelpUI
import Localization

/// A panel's detail list in its splitter, and the large view it opens into —
/// the Quick Look of a row's detail.
///
/// A row's detail keeps growing — a descriptor's straps, a store's variable
/// history, a picture — and the lower third of a panel beside the dump is a
/// keyhole onto it. **Space** on the row in focus, or the expand button in the
/// list's corner, opens the same list as a large card in the middle of the
/// window, over a dimmed window; **Space** again, **Esc**, the close button in
/// the corner or a click outside the card closes it. While it is open the
/// arrow keys still move the table's selection, and the card follows, as
/// Finder's Quick Look follows Finder's.
///
/// The card holds **the list itself**, moved out of its pane and back, not a
/// second copy of it. A copy would need every panel to render twice, and
/// would lose what one list keeps for free: its scroll, its selection, its
/// `?`, a picture's chosen background, a re-render at a new zoom.
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

    /// The dimmed layer over the window and the card on it, while shown.
    private var overlay: QuickLookOverlay?
    /// Space on the table, watched while the pane is in a window.
    private var spaceMonitor: Any?
    /// The keys and clicks the large view answers, watched while it is shown.
    private var shownMonitors: [Any] = []
    /// Counts the shows and closes, so a fade-out that finishes after the
    /// view was opened again does not take the reopened card down with it.
    private var generation = 0

    /// Whether the large view is open.
    public private(set) var isQuickLookShown = false

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        place(detail, in: self, inset: 0)
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

    /// Opens the large view over the window. False when there is nothing to
    /// show in it.
    @discardableResult
    public func showQuickLook() -> Bool {
        guard !isQuickLookShown, detail.hasRows, let host = window?.contentView else { return false }
        isQuickLookShown = true
        generation += 1

        // A fade-out still running is the same overlay, holding the list:
        // it comes back rather than being built again.
        let overlay = self.overlay ?? QuickLookOverlay()
        if self.overlay == nil {
            self.overlay = overlay
            overlay.onOutsideClick = { [weak self] in self?.closeQuickLook() }
            overlay.alphaValue = 0
            place(overlay, in: host, inset: 0)
            detail.borderType = .noBorder
            place(detail, in: overlay.card, inset: 0)
        }
        detail.isExpanded = true
        fade(overlay, to: 1, then: nil)
        if let table { window?.makeFirstResponder(table) }
        watchWhileShown()
        return true
    }

    /// Closes the large view, and puts the list back in its pane.
    public func closeQuickLook() {
        guard isQuickLookShown else { return }
        isQuickLookShown = false
        generation += 1
        stopWatchingWhileShown()
        detail.isExpanded = false
        let closing = generation
        guard let overlay else { return }
        fade(overlay, to: 0) { [weak self] in
            guard let self, self.generation == closing else { return }
            self.takeBack()
        }
        // The focus goes back to the table, which is where Space came from
        // and where a selectable value in the card would otherwise keep it.
        if let table, table.window != nil { table.window?.makeFirstResponder(table) }
    }

    /// The list back in its pane, the overlay gone — at once, with no fade.
    private func takeBack() {
        guard let overlay else { return }
        self.overlay = nil
        overlay.removeFromSuperview()
        detail.borderType = .bezelBorder
        place(detail, in: self, inset: 0)
    }

    private func fade(_ overlay: NSView, to alpha: CGFloat, then done: (@MainActor @Sendable () -> Void)?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.15
            overlay.animator().alphaValue = alpha
        }, completionHandler: {
            guard let done else { return }
            MainActor.assumeIsolated { done() }
        })
    }

    /// Pins `view` to every edge of `container`, moving it there first.
    private func place(_ view: NSView, in container: NSView, inset: CGFloat) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: - The keys and clicks

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // A panel closed or swapped with the view open: nothing is left
            // for the card to be about, and the list must be home before the
            // pane is shown again.
            if isQuickLookShown { closeQuickLook() }
            takeBack()
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
    /// Space, unmodified, on the table while it has the focus opens it. True
    /// when it was taken.
    func handleKeyWhileShut(_ event: NSEvent) -> Bool {
        guard !isQuickLookShown, let table, let window = table.window,
              event.window === window, window.firstResponder === table,
              Self.isPlainSpace(event)
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
    }

    private func stopWatchingWhileShown() {
        shownMonitors.forEach(NSEvent.removeMonitor)
        shownMonitors.removeAll()
    }

    /// Key codes of the arrows, which still move the table under the card.
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
    private static let escapeKey: UInt16 = 53

    /// What a key pressed in the window does while the large view is open.
    /// True when it was taken. A key in another window — the `?`'s popover,
    /// the help — is that window's.
    func handleKeyWhileShown(_ event: NSEvent) -> Bool {
        guard isQuickLookShown, event.window === window else { return false }
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

    /// A click in the window outside the card closes the large view. One on
    /// the dimmed layer is the overlay's own, and stops there; one on the
    /// window's toolbar is closed for here and still does what it was for.
    func handleClickWhileShown(_ event: NSEvent) {
        guard isQuickLookShown, let overlay, event.window === window,
              let frame = window?.contentView?.superview
        else { return }
        let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        guard hit?.isDescendant(of: overlay) != true else { return }
        closeQuickLook()
    }

    // MARK: - For the tests

    /// The card the list sits in while the large view is open.
    public var quickLookCardForTesting: NSView? { overlay?.card }

    /// Ends a fade at once, so a test sees the state it waits for.
    public func finishFadeForTesting() {
        if !isQuickLookShown { takeBack() } else { overlay?.alphaValue = 1 }
    }
}

/// The large view's two layers: a dimmed sheet over the whole window, which a
/// click closes, and the card in its middle, which holds the list.
@MainActor private final class QuickLookOverlay: NSView {
    let card = QuickLookCard()
    var onOutsideClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Large, but never to the window's edge: a margin of the dimmed
        // window around it says this is over the dump, not instead of it.
        // The share of the window is what gives way when it is small.
        let wide = card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.75)
        let tall = card.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.8)
        wide.priority = .defaultHigh
        tall.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -40),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            wide, tall,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.25).cgColor
    }

    // The dump under the sheet is out of reach while the card is up: a click
    // closes the card, and the wheel scrolls nothing behind it.
    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
    override func rightMouseDown(with event: NSEvent) { onOutsideClick?() }
    override func otherMouseDown(with event: NSEvent) { onOutsideClick?() }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The card: rounded, framed, the window's background behind the list.
@MainActor private final class QuickLookCard: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Details"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // A click on the card is the card's: passed up, it would reach the
    // dimmed sheet behind and close the view it landed in.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}
