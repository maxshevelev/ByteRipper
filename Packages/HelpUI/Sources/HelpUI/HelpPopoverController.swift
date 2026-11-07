import AppKit

/// What every help popover does around its words: shows itself off a button,
/// follows the Zoom while it is on screen, and lets go of itself once it is
/// closed.
///
/// The words are a subclass's (`makeContent`); they sit in a view of this
/// controller's own that stays the popover's for its whole life. A Zoom swaps
/// what is inside that view rather than the view itself: `NSPopover` installs
/// its controller's view when it is shown and does not look at the property
/// again, so a new view assigned to an open popover was never drawn.
///
/// Nothing but the popover holds a popover's controller, and the controller
/// holds the popover — the pair keeps itself alive while it is on screen. The
/// close breaks that: the popover lets go of the controller, which goes, and
/// with it the Zoom observer. Left joined, every popover a reader had ever
/// opened stayed in memory and rebuilt its words at every Zoom step.
@MainActor open class HelpPopoverController: NSViewController, NSPopoverDelegate {
    private let popover = NSPopover()
    private var zoomObserver: NSObjectProtocol?

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The popover's words at the current size — built again at every Zoom
    /// while the popover is open.
    open func makeContent() -> NSView { NSView() }

    public final override func loadView() {
        view = NSView()
        fill()
    }

    /// Puts a freshly built content into the controller's own view.
    private func fill() {
        view.subviews.forEach { $0.removeFromSuperview() }
        let content = makeContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Shows the popover off `anchor`, the button the reader pressed.
    public func present(from anchor: NSView, edge: NSRectEdge = .maxY) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.delegate = self
        zoomObserver = HelpPopoverLayout.observeTextSize { [weak self] in
            self?.followZoom()
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    /// The Zoom moved: the words again at the new size, and the popover as big
    /// as they now are.
    private func followZoom() {
        fill()
        popover.contentSize = view.fittingSize
    }

    public func popoverDidClose(_ notification: Notification) {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
        zoomObserver = nil
        // The popover's hold on this controller is the last one; released
        // here, the controller would go in the middle of its own call.
        withExtendedLifetime(self) { popover.contentViewController = nil }
    }

    /// Closes the popover, where it is open.
    public func close() { popover.performClose(nil) }

    public var isShown: Bool { popover.isShown }

    /// Whether the Zoom is being followed — from the show to the close. For
    /// the tests.
    public var followsZoom: Bool { zoomObserver != nil }
}
