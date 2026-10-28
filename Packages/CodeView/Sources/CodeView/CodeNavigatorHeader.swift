import AppKit
import ToolModuleKit

/// The header over the navigator's columns — POST codes and strings — drawn
/// as part of the panel rather than as AppKit's bar: the panel's background,
/// the titles in the panel's grey at the list's size, each title starting where the
/// text under it starts, and a hairline under them.
///
/// AppKit's header draws its own light bar with the titles inset by its own
/// amount, which over the grey navigator read as a foreign strip and put each
/// title a few points off its column's text. Dragging a column's edge still
/// goes through `NSTableHeaderView`.
final class CodeNavigatorHeader: NSTableHeaderView {
    /// How far a cell's text starts into its cell view: the field's leading
    /// inset in the cell. The constraint places the label's alignment rect,
    /// which starts at its first glyph (measured, in a rendered navigator).
    static let cellTextInset: CGFloat = 4

    /// The header keeps the panel's height for it, whatever the scroll view
    /// tiles it to.
    override var frame: NSRect {
        get { super.frame }
        set {
            var frame = newValue
            frame.size.height = max(CodePaneView.navigatorRowHeight, 17)
            super.frame = frame
        }
    }

    /// Takes the height the zoom asks for.
    func zoomChanged() {
        frame = frame
        enclosingScrollView?.tile()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        let lineY = isFlipped ? bounds.maxY - 1 : bounds.minY
        NSRect(x: bounds.minX, y: lineY, width: bounds.width, height: 1).fill()
        guard let tableView else { return }

        let font = CodePaneView.navigatorFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
        ]
        let inset = Self.titleInset(in: tableView)
        let height = ceil(font.ascender - font.descender)
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            let title = NSRect(x: rect.minX + inset, y: rect.midY - height / 2,
                               width: max(0, rect.width - inset - 4), height: height)
            (column.title as NSString).draw(with: title, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: attributes)
            // A short rule at the column's edge, where a drag resizes it.
            if index < tableView.tableColumns.count - 1 {
                NSColor.separatorColor.setFill()
                NSRect(x: rect.maxX - 1, y: rect.minY + 5, width: 1, height: max(0, rect.height - 10)).fill()
            }
        }
    }

    /// Where a column's title starts in its header rect: half the gap between
    /// columns — the cell view starts there — then the cell's text inset.
    static func titleInset(in tableView: NSTableView) -> CGFloat {
        tableView.intercellSpacing.width / 2 + cellTextInset
    }
}
