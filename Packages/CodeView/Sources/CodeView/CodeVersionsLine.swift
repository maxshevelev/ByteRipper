import AppKit

/// The line under the module's name that says what produced the analysis:
/// an archive box, the recipe and the Ghidra version in the quiet grey of the
/// line and, when the line opens a menu, a small up-and-down chevron after
/// it — a jump bar's line.
///
/// A label and image views, not a borderless button: a button measures its
/// title late, and a stack that asked for its size before then keeps the line
/// at the chevron's width and drops the text. A label measures the way the
/// plain line does, so the text stays at every width the header gives.
final class CodeVersionsLine: NSControl {
    /// The ground under the pointer, when the line opens a menu: a shade of
    /// the text's own colour, light in the light appearance and light on the
    /// dark one.
    static let ground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.06)
    }

    /// How far the ground reaches past the line, so it has air around it, and
    /// the gaps between the parts of the line. The icon sits close to the
    /// text it stands for; the chevron keeps a little more room.
    private static let groundOverhang: CGFloat = 4
    private static let iconGap: CGFloat = 2
    private static let chevronGap: CGFloat = 4

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isUnderPointer = false { didSet { needsDisplay = true } }

    /// The line was clicked, or opened from the keyboard: show the menu.
    /// A line with no way to open draws no ground and takes no click.
    var onOpen: (() -> Void)?

    /// The menu the line opened is up. The ground stays while it is, and goes
    /// when it closes — chosen from, or dismissed untouched.
    private(set) var isMenuOpen = false { didSet { needsDisplay = true } }

    func menuOpened() { isMenuOpen = true }

    /// The menu closed: the ground follows the pointer again, wherever it is
    /// now. A tracking area under a menu can miss the exit, so the pointer is
    /// read afresh rather than trusted to the last event.
    func menuClosed() {
        if let window {
            isUnderPointer = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            isUnderPointer = false
        }
        isMenuOpen = false
    }

    /// The summary the line shows.
    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.contentTintColor = .secondaryLabelColor
        icon.isHidden = true
        addSubview(icon)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.isHidden = true
        addSubview(chevron)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setIcon(_ image: NSImage?) {
        icon.image = image
        icon.isHidden = image == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func setFont(_ font: NSFont) {
        label.font = font
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func setChevron(_ image: NSImage?) {
        chevron.image = image
        chevron.isHidden = image == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// What the text needs: the cell's own measure, which is a few points
    /// wider than `intrinsicContentSize` — a label asked the latter loses the
    /// tail of the line to a needless ellipsis.
    private var textSize: NSSize {
        label.cell?.cellSize ?? label.intrinsicContentSize
    }

    override var intrinsicContentSize: NSSize {
        let text = textSize
        // A point of slack: the cell measures in fractions, and a label set
        // to exactly that width cuts the last glyph off.
        var width = ceil(text.width) + 1
        var height = text.height
        if let size = icon.image?.size, !icon.isHidden {
            width += Self.iconGap + size.width
            height = max(height, size.height)
        }
        if let size = chevron.image?.size, !chevron.isHidden {
            width += Self.chevronGap + size.width
            height = max(height, size.height)
        }
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func layout() {
        super.layout()
        let middleY = { (height: CGFloat) in floor((self.bounds.height - height) / 2) }
        var x: CGFloat = 0
        if let size = icon.image?.size, !icon.isHidden {
            icon.frame = NSRect(x: x, y: middleY(size.height), width: size.width, height: size.height)
            x += size.width + Self.iconGap
        }
        let chevronWidth = chevron.isHidden ? 0 : (chevron.image?.size.width ?? 0) + Self.chevronGap
        let text = textSize
        label.frame = NSRect(x: x, y: middleY(text.height),
                             width: max(0, bounds.width - x - chevronWidth), height: text.height)
        if !chevron.isHidden, let size = chevron.image?.size {
            chevron.frame = NSRect(x: bounds.width - size.width, y: middleY(size.height),
                                   width: size.width, height: size.height)
        }
    }

    // MARK: - Opening

    /// A click opens the menu and does not take the keyboard: a line that
    /// kept the focus would wear its ground after the menu closed.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let onOpen else { return }
        onOpen()
    }

    override var acceptsFirstResponder: Bool { onOpen != nil }

    override func keyDown(with event: NSEvent) {
        // Return and Space open the menu, as they do a button.
        if isEnabled, let onOpen, event.keyCode == 36 || event.keyCode == 49 {
            onOpen()
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { needsDisplay = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    // MARK: - The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isUnderPointer = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isUnderPointer = false
    }

    /// The label is a view of its own and would take the click; the line is
    /// what is pressed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onOpen != nil, !isHidden, alphaValue > 0 else { return nil }
        let own = convert(point, from: superview)
        return bounds.contains(own) ? self : nil
    }

    /// Whether the line wears its ground now: under the pointer, while its
    /// menu is up, or with the keyboard on it.
    var showsGround: Bool { isUnderPointer || isMenuOpen || window?.firstResponder === self }

    override func draw(_ dirtyRect: NSRect) {
        guard onOpen != nil else { return }
        if showsGround {
            Self.ground.setFill()
            let ground = bounds.insetBy(dx: -Self.groundOverhang, dy: -1)
            NSBezierPath(roundedRect: ground, xRadius: 5, yRadius: 5).fill()
        }
    }
}
