import AppKit

/// The cells and icons of a tool panel's table, whose tooltips show only while
/// the pointer is over them and not over something lying on top of them.
///
/// AppKit shows a covered view's tooltip as if nothing lay over it: a row of
/// the UEFI tree under the Code panel kept saying "Decompressed from … at …"
/// over the panel's code. An empty tooltip the panel host lays over the panes
/// does not settle it — the tree sets its rows' tooltips again whenever it
/// reloads, after the cover, and the tree's then win. So the row asks, when
/// the tooltip is about to show, whether the window's hit test lands on it.
///
/// `toolTip` reads and writes as usual; only AppKit's own rect is replaced by
/// one that asks first.
final class ToolPanelCellView: NSTableCellView {
    private lazy var gate = ToolTipGate(view: self)

    override var toolTip: String? {
        get { gate.phrase }
        set { gate.phrase = newValue }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        gate.cover()
    }

    /// What the pointer at `point`, in the cell's coordinates, would read.
    func shownToolTip(at point: NSPoint) -> String { gate.string(at: point) }
}

/// A tool panel's icon — a warning, a badge, a marker — with the same tooltip
/// as `ToolPanelCellView`.
final class ToolPanelIconView: NSImageView {
    private lazy var gate = ToolTipGate(view: self)

    override var toolTip: String? {
        get { gate.phrase }
        set { gate.phrase = newValue }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        gate.cover()
    }
}

/// One view's tooltip, answered only when the view is what the pointer is on.
@MainActor private final class ToolTipGate: NSObject, NSViewToolTipOwner {
    private unowned let view: NSView
    var phrase: String? {
        didSet { cover() }
    }

    init(view: NSView) {
        self.view = view
    }

    /// The rect over the whole view, or none while there is nothing to say.
    func cover() {
        view.removeAllToolTips()
        guard phrase != nil else { return }
        view.addToolTip(view.bounds, owner: self, userData: nil)
    }

    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                          point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { string(at: point) }
    }

    func string(at point: NSPoint) -> String {
        isUncovered(at: point) ? phrase ?? "" : ""
    }

    /// Whether the window's hit test at `point` lands on the view or inside
    /// it. The frame view's superview is nil, so it hit-tests in the window's
    /// own coordinates.
    private func isUncovered(at point: NSPoint) -> Bool {
        guard let frameView = view.window?.contentView?.superview,
              let hit = frameView.hitTest(view.convert(point, to: nil)) else { return false }
        return hit === view || hit.isDescendant(of: view)
    }
}
