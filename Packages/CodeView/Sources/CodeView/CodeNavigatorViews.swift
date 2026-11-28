import ALSplitView
import AnalysisProfiles
import AppKit
import AppPalette
import CodeAnalysis
import Find
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

// The navigator's rows, cells, bars and buttons: what the code navigator's
// lists and tabs are drawn with.


/// A navigator row. The call tree selects a function at each of its places, and
/// that many full-width bands would bury the tree: there the selection marks the
/// node alone, its mark and name. The place being read has the colour the code
/// selects text in, the function's other places a light grey. Every other list
/// keeps the table's own band.
final class CodeNavigatorRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("code-navigator-row")

    var marksNode = false {
        didSet { needsDisplay = true }
    }

    var isOpenPlace = false {
        didSet {
            if isOpenPlace != oldValue { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    /// A node's mark and name stay as they read on the page: the colour behind
    /// them is the text selection's, which takes ordinary ink.
    override var isEmphasized: Bool {
        get { marksNode ? false : super.isEmphasized }
        set { super.isEmphasized = newValue }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard marksNode else {
            super.drawSelection(in: dirtyRect)
            return
        }
        guard let cell = subviews.lazy.compactMap({ $0 as? CodeNavigatorCell }).first else { return }
        let color: NSColor = !isOpenPlace ? .unemphasizedSelectedContentBackgroundColor
            : window?.isKeyWindow == true ? .selectedTextBackgroundColor
            : .unemphasizedSelectedTextBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: convert(cell.nodeFrame, from: cell), xRadius: 4, yRadius: 4).fill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A navigator row's cell. A call tree's function starts further in the deeper
/// it is — the indent is the row's, so a reused cell takes the next row's —
/// and one whose calls the tree holds carries the triangle that opens them.
/// A function that changed in a revision the panel received reads bold, with
/// **New** in a capsule until the reader opens it and moves off it.
class CodeNavigatorCell: NSTableCellView {
    let disclosure = CodeDisclosureButton()
    let icon = NSImageView()
    let badge = PartBadgeView(text: "")
    /// What the row's mark stands for — `function`, or `group.<level>` —
    /// for a test to read.
    private(set) var iconName: String?
    private var leading: NSLayoutConstraint!
    private var disclosureWidth: NSLayoutConstraint!
    private var disclosureGap: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    private var iconGap: NSLayoutConstraint!
    private var fieldToEdge: NSLayoutConstraint!
    private var fieldToBadge: NSLayoutConstraint!
    /// What the triangle does, for the row it is drawn in.
    var onToggle: (() -> Void)?
    /// How far the row starts past the cell's own edge, in points.
    var indent: CGFloat = 0 {
        didSet { leading.constant = 4 + indent }
    }
    /// A control standing right after the row's words — a branch's (i), a
    /// heading's (?) — not at the trailing edge: the words keep their own
    /// width, cut only when the row is too narrow for both.
    private(set) var accessory: NSView?
    private var fieldWidth: NSLayoutConstraint!
    private var accessoryConstraints: [NSLayoutConstraint] = []

    func showsAccessory(_ view: NSView?) {
        if accessory !== view {
            NSLayoutConstraint.deactivate(accessoryConstraints)
            accessoryConstraints = []
            if let old = accessory, old.superview === self { old.removeFromSuperview() }
            accessory = view
            if let view {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                accessoryConstraints = [
                    view.leadingAnchor.constraint(equalTo: textField!.trailingAnchor, constant: 3),
                    view.centerYAnchor.constraint(equalTo: centerYAnchor)
                ]
                NSLayoutConstraint.activate(accessoryConstraints)
            }
        }
        // The chain the row is leaving is let go before the other takes hold
        // (see `showsBadge`).
        if view != nil {
            fieldToEdge.isActive = false
            fieldWidth.isActive = true
        } else {
            fieldWidth.isActive = false
            fieldToEdge.isActive = badge.isHidden
        }
        needsLayout = true
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A chevron that turns down as the row opens.
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        // Decorative: the name beside it is what the row is.
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false

        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.ink = .controlAccentColor
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField = field
        for subview in [disclosure, icon, field, badge] { addSubview(subview) }
        leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        disclosureWidth = disclosure.widthAnchor.constraint(equalToConstant: 13)
        disclosure.heightAnchor.constraint(equalToConstant: 13).isActive = true
        disclosureGap = icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 0)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        iconGap = field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        fieldToEdge = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        fieldToBadge = field.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4)
        fieldWidth = field.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            leading,
            disclosureWidth,
            disclosureGap,
            iconWidth,
            iconGap,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        showsDisclosure(false)
        showsIcon(nil)
        showsBadge(false)
    }

    /// The mark the row carries, drawn again when the row is selected or
    /// let go.
    private var mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)?

    /// A selected row draws its mark again, on a light plate and keeping its
    /// own colours, as a library badge draws there. The New badge does the
    /// same, in the dock pill's manner: its word and capsule turn to the
    /// selection's white.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue else { return }
            drawMark()
            drawBadge()
        }
    }

    private func drawBadge() {
        badge.ink = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor : .controlAccentColor
    }

    private func drawMark() {
        // A system symbol (`showsSymbol`) has no mark to draw again: it keeps
        // its image and takes the selection's colour, or it would be lost on
        // the selection's fill.
        guard let mark else {
            icon.contentTintColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor : .secondaryLabelColor
            return
        }
        let side = CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize)
        icon.image = Optional(mark).map {
            CodeNavigatorIcon.image($0.glyph, color: $0.color, side: side,
                                    inverted: backgroundStyle == .emphasized)
        }
    }

    /// What a selected node of the call tree is marked over, in the cell's own
    /// terms: from the mark to the end of the name or the badge after it, no
    /// further than the room the name has.
    var nodeFrame: NSRect {
        guard let field = textField else { return bounds }
        let start = icon.isHidden ? field.frame.minX : icon.frame.minX
        let end = badge.isHidden
            ? field.frame.minX + min(field.intrinsicContentSize.width, field.frame.width)
            : badge.frame.maxX
        let left = start - 3
        return NSRect(x: left, y: bounds.minY + 1, width: min(end + 8, bounds.maxX) - left, height: bounds.height - 2)
    }

    /// The row draws the mark under the cell, from the frames set here.
    override func layout() {
        if let accessory, let field = textField {
            // The words as wide as they are, in whole points (a field at half
            // points draws blurred), no further than leaves the control room.
            let room = bounds.width - field.frame.minX - 3 - accessory.intrinsicContentSize.width - 6
            fieldWidth.constant = max(0, min(field.intrinsicContentSize.width.rounded(.up), room.rounded(.down)))
        }
        super.layout()
        superview?.needsDisplay = true
    }

    /// The room the chevron and its gap take before a row's mark.
    static let disclosureRoom: CGFloat = 13 + 4

    /// Makes room for the disclosure column — the call tree alone. The room
    /// stays for a function without calls, so names line up under names.
    func showsDisclosure(_ shows: Bool) {
        disclosureWidth.constant = shows ? 13 : 0
        disclosureGap.constant = shows ? 4 : 0
        if !shows { disclosure.isHidden = true }
    }

    /// The triangle's own state for a row: a function with calls shows it,
    /// open or closed; one without shows nothing in the room kept for it.
    func showsCalls(expandable: Bool, expanded: Bool) {
        disclosure.isHidden = !expandable
        disclosure.setOpen(expanded, animated: false)
    }

    /// The row's mark: a function's `f`, or a review group's level, each a
    /// glyph on a coloured square. Nil for a row that is not a function.
    func showsIcon(_ name: String?) {
        iconName = name
        let mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? = switch name {
        case "function"?: CodeNavigatorIcon.function
        case "function.partial"?: CodeNavigatorIcon.partialFunction
        case "function.decompiled"?: CodeNavigatorIcon.decompiledFunction
        case "function.noBody"?: CodeNavigatorIcon.bodylessFunction
        case let name? where name.hasPrefix("library."):
            CodeReaderState.LibrarySection.allCases.lazy.compactMap { section -> (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? in
                let badge = CodePaneView.badge(of: section)
                switch name {
                case "library.\(section).entry": return CodeNavigatorIcon.library(badge)
                default: return nil
                }
            }.first
        case let name? where name.hasPrefix("group."):
            CodeReaderState.FunctionGroup.allCases
                .first { "group.\($0)" == name }
                .map(CodeNavigatorIcon.group)
        default: nil
        }
        showsMark(mark)
    }

    /// A mark of the navigator's kind for a row that is not a function — a
    /// heading or an interface of the Interfaces tab: a glyph on a coloured
    /// square, drawn again on a selected row as a function's is.
    func showsMark(_ mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)?, named name: String? = nil) {
        if let name { iconName = name }
        self.mark = mark
        let side = CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize)
        drawMark()
        icon.isHidden = mark == nil
        iconWidth.constant = mark.map { CodeNavigatorIcon.width(of: $0.glyph, side: side) } ?? 0
        iconGap.constant = mark == nil ? 0 : 5
    }

    /// A system symbol for a row that is not a function — the Search tab's
    /// description, a book — in the mark's place and size.
    func showsSymbol(_ symbol: String) {
        iconName = symbol
        mark = nil
        let side = CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side - 2, weight: .regular))
        icon.isHidden = false
        drawMark()
        iconWidth.constant = side
        iconGap.constant = 5
    }

    /// The capsule a revision puts on a function it changed.
    func showsBadge(_ shows: Bool) {
        badge.isHidden = !shows
        // The row carries one horizontal chain, never two. The table lays its
        // rows out by configuring the cells inside that pass, and an
        // activation made there is solved while the constraint it replaces is
        // still live: with the field pinned both to the row's trailing edge
        // and to the badge's leading edge, the badge is left a negative width
        // to have, the engine breaks a constraint and the name runs under the
        // capsule. So the chain the row is leaving is let go before the other
        // takes hold, and a hidden badge leaves the field at the row's edge
        // while a shown one keeps its four points before it.
        if shows {
            fieldToEdge.isActive = false
            fieldToBadge.isActive = true
        } else {
            fieldToBadge.isActive = false
            fieldToEdge.isActive = true
        }
        if shows { drawBadge() }
    }

    /// Opens or closes `item` as every tab of the navigator does: the rows
    /// slide in and out over 0.2 s, never jump.
    static func toggle(_ item: Any, in outline: NSOutlineView) {
        let opening = !outline.isItemExpanded(item)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            if opening {
                outline.animator().expandItem(item)
            } else {
                outline.animator().collapseItem(item)
            }
        }
    }

    /// The settings every list of the navigator's tabs shares: one column, no
    /// header, the inset style with the system's rounded selection, the
    /// navigator's row height, no indentation of AppKit's own (a cell indents
    /// by `indent`) and no gaps between cells.
    static func dress(_ outline: NSOutlineView) {
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.style = .inset
        outline.backgroundColor = .clear
        outline.rowHeight = CodePaneView.navigatorRowHeight
        outline.indentationPerLevel = 0
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.floatsGroupRows = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    /// A heading's words: one weight up, in grey.
    static func headingAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: CodePaneView.navigatorSize, weight: .semibold),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// The click has already flipped the button's state: the chevron turns
    /// to it, and the rows follow.
    @objc private func toggle() {
        disclosure.setOpen(disclosure.state == .on, animated: true)
        onToggle?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The bar under the navigator's list: the panel's background and a hairline
/// over it, where the list scrolls under — Xcode's filter bar.
/// One of the navigator's function-view buttons: a flat symbol and nothing
/// around it, in the accent colour for the one whose layout is in front.
///
/// The three layouts are three buttons, not the segments of one control: the
/// bar reads as a row of separate buttons, and a segmented control would draw
/// them as a single joined frame with dividers — chrome the bar does not have.
/// The navigator's column: a tool panel's frame, so the large view of a
/// record's details keeps clear of it and is as wide as the sidebar's divider
/// leaves, as it is beside a tool panel.
final class CodeNavigatorFrame: NSView, ToolPanelFrame {}

/// A view that takes no click: what it shows lies over a control.
final class CodeClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CodeOrderButton: NSButton {
    /// The tint while the button is not chosen.
    var idleTint: NSColor = .secondaryLabelColor {
        didSet { if !isChosen { contentTintColor = idleTint } }
    }

    /// Whether this button's layout is the one shown. The button's own state
    /// follows it, which is what a screen reader reads as selected.
    var isChosen: Bool = false {
        didSet {
            // Before the guard: a press on the chosen button has flipped the
            // state, and it is chosen still.
            state = isChosen ? .on : .off
            guard isChosen != oldValue else { return }
            contentTintColor = isChosen ? .controlAccentColor : idleTint
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class CodeNavigatorBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
