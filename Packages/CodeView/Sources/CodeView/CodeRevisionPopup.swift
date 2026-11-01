import AppKit

/// The revision picker in the dump bar, drawn as Xcode draws its own: no
/// bezel, the name and the chevron on the bar itself, and a rounded plate
/// behind them while the pointer is on the control or its menu is open.
final class CodeRevisionPopup: NSPopUpButton {
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private var pressing = false {
        didSet { if pressing != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp,
                                                         .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        defer {
            pressing = false
            needsDisplay = true
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsPlate {
            // A step in from the control on every side: the plate hugs the
            // words without touching the bar's edges.
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Whether the plate is drawn now — for a test, and for the pointer.
    var showsPlate: Bool { hovering || pressing }
    /// For a test: the plate as a pointer arriving and leaving would set it.
    func setPointerOnIt(_ on: Bool) { hovering = on }
}
