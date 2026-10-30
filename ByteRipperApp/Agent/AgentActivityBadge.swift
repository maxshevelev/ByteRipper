import Cocoa
import AppPalette
import Localization

/// A dot on the corner of the toolbar's Agent button that blinks while an
/// agent is at work (`AgentService.isActive`): the person sees that the
/// program is being driven before a view moves under their hands.
///
/// Laid on the button the toolbar drew for the item, as the Annotations
/// button's count is (`MainWindowController.syncNotesBadge`), and found again
/// each time, since the toolbar may draw it anew. With Reduce Motion on the
/// dot is steady.
// help: toolbar.agent
final class AgentActivityBadge: NSView {
    static let side: CGFloat = 8

    /// How far the dot reaches past the button's right edge before macOS 26:
    /// there the toolbar's button is hardly wider than its symbol, and a dot
    /// inside its corner sat on the symbol. The view does not clip its
    /// subviews, so the part outside is still drawn.
    static let overhang: CGFloat = 4

    /// How far inside the glass's edge the dot stays from macOS 26.
    static let inset: CGFloat = 1

    /// Where the dot sits on a button with `bounds`.
    ///
    /// From macOS 26 the button lies in a glass circle (a capsule when wider
    /// than tall) that clips what is drawn outside it, and the corner of the
    /// button's bounds is outside: the dot sits on the diagonal from the right
    /// end cap's centre towards that corner, `inset` short of the edge.
    /// Measured on macOS 27: a 36 × 36 button in a 36 × 36 glass.
    static func frame(in bounds: NSRect, flipped: Bool) -> NSRect {
        if #available(macOS 26, *) {
            let radius = min(bounds.width, bounds.height) / 2
            let reach = (radius - side / 2 - inset) / 2.squareRoot()
            let centre = NSPoint(x: bounds.maxX - radius + reach,
                                 y: bounds.midY + (flipped ? -reach : reach))
            return NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        }
        return NSRect(x: bounds.maxX - side + overhang,
                      y: flipped ? 0 : bounds.maxY - side,
                      width: side, height: side)
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("The agent is at work"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        // Something mid-flight, in the palette's words: the agent is at work.
        SemanticColors.caution.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the dot on `window`'s Agent button while `active`, and hides it
    /// otherwise or when the toolbar shows no such button.
    func sync(in window: NSWindow?, active: Bool) {
        guard active, let button = Self.agentButton(in: window) else {
            stopBlinking()
            isHidden = true
            return
        }
        if superview !== button { button.addSubview(self) }
        frame = Self.frame(in: button.bounds, flipped: button.isFlipped)
        isHidden = false
        startBlinking()
    }

    var isBlinking: Bool { layer?.animation(forKey: Self.blinkKey) != nil }

    private static let blinkKey = "blink"

    private func startBlinking() {
        guard let layer, !isBlinking,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.15
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(blink, forKey: Self.blinkKey)
    }

    private func stopBlinking() {
        layer?.removeAnimation(forKey: Self.blinkKey)
    }

    /// The button the toolbar drew for the Agent item.
    static func agentButton(in window: NSWindow?) -> NSButton? {
        guard let frame = window?.contentView?.superview else { return nil }
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == #selector(AppDelegate.showAgentWindow(_:)) {
                return button
            }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(frame)
    }
}
