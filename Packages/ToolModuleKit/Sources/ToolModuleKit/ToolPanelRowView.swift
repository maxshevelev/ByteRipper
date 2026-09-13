import AppKit

/// A firmware panel's row: the background and the rail of
/// `Design/ROW_MARKS.md` drawn behind the cells.
///
/// The background goes under everything — the alternating row colour first,
/// the tint over it — and the system selection replaces it, as on every table.
/// The rail is drawn over the selection too, because where a row's bytes live
/// does not stop being true when the row is picked.
@MainActor public final class ToolPanelRowView: NSTableRowView {
    /// How wide the rail is, and what the legend's sample draws.
    public static let railWidth: CGFloat = 3

    public var marks: ToolRowMarks = .none {
        didSet { if marks != oldValue { needsDisplay = true } }
    }

    /// Off when the panel's Show Markings switch is: the row draws as a plain
    /// row, and its icons — which are the cells' — stay.
    public var showsMarkings = true {
        didSet { if showsMarkings != oldValue { needsDisplay = true } }
    }

    override public func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsMarkings else { return }
        if let protection = marks.protection {
            protection.mark.tint.setFill()
            bounds.fill(using: .sourceOver)
        }
        drawRail()
    }

    override public func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        if showsMarkings { drawRail() }
    }

    private func drawRail() {
        guard marks.hasRail else { return }
        ToolRowMark.decompressed.tint.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: Self.railWidth, height: bounds.height)
            .fill(using: .sourceOver)
    }
}
