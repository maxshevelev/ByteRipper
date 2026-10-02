import AppKit

/// A label that wraps inside whatever width the layout gives it.
///
/// An `NSTextField` decides how tall it wants to be from
/// `preferredMaxLayoutWidth`, and nothing sets that for a label whose width is
/// decided by constraints — so a multi-line label in a stack either stays one
/// long line or reports a height for a width it does not have. This one reads
/// its own laid-out width back into that property and asks for a new height
/// when it changes, which is the standard way round it.
///
/// It is a *label*: word-wrapping, no line limit, selectable text left to the
/// caller. A table cell must never use it — a cell that wraps grows past its
/// row and draws over the rows around it (see `ToolPanelTable.makeCell`).
@MainActor public final class ToolWrappingLabel: NSTextField {
    public init(string: String) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        stringValue = string
        // The two that make it a paragraph rather than a line.
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        // The width belongs to the layout, the height to the text: give the
        // width up readily and never let the height be squeezed.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        // And take up any width on offer. Once it has wrapped, its intrinsic
        // width is the narrow width it wrapped at, and a hugging priority equal
        // to the stack view's own — both `.defaultLow` — is a tie the engine
        // settles by keeping the last answer: a panel dragged narrow and then
        // wide again left the value in its narrow column, with the rest of the
        // row empty beside it.
        setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The height its cell draws the text in at the width it is laid out at.
    ///
    /// `NSTextField` works its own out as if the whole width were the
    /// text's, but it draws inside the cell's insets — so a text that only
    /// just fits a line in the first reckoning wraps in the second, and the
    /// extra line runs out of the frame. It came back on a click, when the
    /// field editor drew it. Measured with the cell that draws it, the two
    /// cannot disagree.
    override public var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard preferredMaxLayoutWidth > 0, let cell else { return size }
        let drawn = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: preferredMaxLayoutWidth,
                                                   height: .greatestFiniteMagnitude))
        return NSSize(width: size.width, height: ceil(drawn.height))
    }

    override public func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}
