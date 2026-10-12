import Cocoa

/// A strip of chrome that a fragment panel can be pulled down by
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// The pane's own header is one such handle and has its gesture built into it,
/// because there it has to be told apart from carrying the pane off to a tab.
/// This is for the headers that have no second meaning — the tool panel's —
/// where a downward drag is a pull and nothing else.
final class PullDownHandleView: NSView {
    /// Fired once the press has moved far enough, and downward, to be a pull.
    /// Nil leaves the view what it was: a strip that does nothing.
    var onPulledDown: ((NSEvent) -> Void)?

    private var pressOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, onPulledDown != nil else {
            super.mouseDragged(with: event)
            return
        }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard hypot(dx, dy) >= PaneHeaderView.dragThreshold else { return }
        // One gesture per press, and only a downward one: a window's y grows
        // upward, so down is negative. Sideways over this header means nothing,
        // and a press that went sideways is not turned into a pull.
        pressOrigin = nil
        guard dy < 0, -dy > abs(dx) else { return }
        onPulledDown?(event)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        super.mouseUp(with: event)
    }
}
