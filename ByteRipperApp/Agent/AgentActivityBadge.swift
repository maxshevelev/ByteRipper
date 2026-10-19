import Cocoa
import Localization

/// A red dot on the corner of the toolbar's Agent button that blinks while an
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
        NSColor.systemRed.setFill()
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
        frame = NSRect(x: button.bounds.maxX - Self.side,
                       y: button.isFlipped ? 0 : button.bounds.maxY - Self.side,
                       width: Self.side, height: Self.side)
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
