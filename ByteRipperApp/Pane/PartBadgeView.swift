import AppKit

/// A word in a capsule, for a pane header: what a part panel's codec says its
/// bytes are (`PartCodec.badge`).
///
/// Drawn rather than built from a layer, so the fill follows the appearance:
/// a layer's colour is a `CGColor` fixed when it was set, and a capsule that
/// stays light after the window goes dark is a capsule nobody can read.
final class PartBadgeView: NSView {
    var text = "" {
        didSet {
            label.stringValue = text
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let label = NSTextField(labelWithString: "")
    private static let inset = NSSize(width: 6, height: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Breakable: a header with no badge collapses this view to no width,
        // and two required insets inside nothing are a conflict the engine
        // resolves by breaking something of the window's instead.
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.width)
        let trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset.width)
        leading.priority = .defaultHigh
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([leading, trailing, label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 2 * Self.inset.width, height: size.height + 2 * Self.inset.height)
    }

    override func accessibilityValue() -> Any? { text }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
    }
}
