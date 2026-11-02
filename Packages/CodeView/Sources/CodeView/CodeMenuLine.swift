import AppKit

/// A line of the code panel that says what is chosen and opens the choices —
/// the analysis, the revision compared with, the section of the description —
/// so that all of them look and behave alike. The platform's borderless
/// pop-up button, as a jump bar's line reads: an optional icon, the choice in
/// the line's font and colour and the system's up-and-down chevron. It reads as
/// plain text until the pointer is on it, and then takes a rounded ground.
/// With no choices it is only text, and takes no click.
///
/// What the line shows is an item of its own (`usesItemFromMenu` off), not the
/// chosen entry of the menu: the line's font, colour and icon stay out of the
/// menu, and the line changes only when the owner says the choice came to
/// something.
final class CodeMenuLine: NSPopUpButton {
    /// One entry of the menu; `tag` is what `onChoose` is told.
    struct Choice: Equatable {
        let title: String
        let tag: Int
        var isEnabled = true
        /// How far the entry is indented, as a heading under another.
        var indentation = 0
        /// A separator goes before it.
        var startsGroup = false
    }

    /// The ground under the pointer: a shade of the text's own colour, light
    /// in the light appearance and light on the dark one.
    static let ground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.06)
    }

    private(set) var choices: [Choice] = []
    private(set) var chosenTag: Int?
    /// An entry was chosen. The line shows it once `select` says so.
    var onChoose: ((Int) -> Void)?
    /// Whether the line opens a menu; otherwise it takes no click.
    var opensMenu: Bool { !choices.isEmpty }

    private let shown = NSMenuItem()
    private var shownTitle = ""
    private var color: NSColor = .secondaryLabelColor
    private var isUnderPointer = false { didSet { needsDisplay = true } }
    private(set) var isMenuOpen = false { didSet { needsDisplay = true } }
    private var popUpCell: NSPopUpButtonCell? { cell as? NSPopUpButtonCell }

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: false)
        isBordered = false
        autoenablesItems = false
        imagePosition = .imageLeft
        popUpCell?.usesItemFromMenu = false
        popUpCell?.menuItem = shown
        popUpCell?.altersStateOfSelectedItem = false
        popUpCell?.alignment = .left
        popUpCell?.lineBreakMode = .byTruncatingTail
        popUpCell?.arrowPosition = .noArrow
    }

    override convenience init(frame frameRect: NSRect) { self.init(frame: frameRect, pullsDown: false) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What the line offers, and the one it shows.
    func setChoices(_ choices: [Choice], chosen: Int?) {
        self.choices = choices
        menu = makeMenu()
        popUpCell?.usesItemFromMenu = false
        popUpCell?.menuItem = shown
        popUpCell?.arrowPosition = choices.isEmpty ? .noArrow : .arrowAtCenter
        select(chosen)
    }

    /// Shows the entry with this tag as chosen, or the first if none has it.
    func select(_ tag: Int?) {
        let choice = choices.first { $0.tag == tag } ?? choices.first
        chosenTag = choice?.tag
        for item in menu?.items ?? [] where !item.isSeparatorItem {
            item.state = item.tag == chosenTag ? .on : .off
            if item.state == .on { select(item) }
        }
        if let choice { title = choice.title }
    }

    /// What the line says. With choices it is the chosen one's title.
    override var title: String {
        get { shownTitle }
        set {
            shownTitle = newValue
            drawShown()
        }
    }

    func setFont(_ font: NSFont) {
        self.font = font
        controlSize = font.pointSize < 12 ? .small : .regular
        drawShown()
    }

    func setTextColor(_ color: NSColor) {
        self.color = color
        drawShown()
    }

    var textColor: NSColor? { color }

    func setIcon(_ image: NSImage?) {
        shown.image = image
        invalidateIntrinsicContentSize()
    }

    /// The line lines up by what it draws, not by its frame: the cell sets its
    /// icon and title in from its edge, and the ground reaches past them.
    override var alignmentRectInsets: NSEdgeInsets {
        var insets = super.alignmentRectInsets
        guard let cell = popUpCell else { return insets }
        let frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        insets.left = shown.image == nil ? cell.titleRect(forBounds: frame).minX : cell.imageRect(forBounds: frame).minX
        return insets
    }

    private func drawShown() {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if let font { attributes[.font] = font }
        shown.attributedTitle = NSAttributedString(string: shownTitle, attributes: attributes)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The menu of the choices, the chosen one ticked. Each entry names the
    /// menu's font, or it would take the line's.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices {
            if choice.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.title, action: #selector(entryChosen(_:)), keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: choice.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            item.target = self
            item.tag = choice.tag
            item.isEnabled = choice.isEnabled
            item.indentationLevel = choice.indentation
            item.state = choice.tag == chosenTag ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func entryChosen(_ item: NSMenuItem) { onChoose?(item.tag) }

    func menuOpened() { isMenuOpen = true }

    /// A tracking area under a menu can miss the exit, so the pointer is read
    /// afresh rather than trusted to the last event.
    func menuClosed() {
        if let window {
            isUnderPointer = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            isUnderPointer = false
        }
        isMenuOpen = false
    }

    /// `super` tracks the menu and returns when it has closed.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, opensMenu else { return }
        menuOpened()
        defer { menuClosed() }
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        opensMenu ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
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

    var showsGround: Bool { isUnderPointer || isMenuOpen }

    /// The ground: a little past what the line draws on the left, not all the
    /// way to the frame, where the cell's inset would leave a wide margin.
    var groundRect: NSRect {
        var rect = bounds
        let cut = max(0, alignmentRectInsets.left - Self.groundOverhang)
        rect.origin.x += cut
        rect.size.width = max(0, rect.width - cut)
        return rect
    }
    private static let groundOverhang: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        if opensMenu, showsGround {
            Self.ground.setFill()
            NSBezierPath(roundedRect: groundRect, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
