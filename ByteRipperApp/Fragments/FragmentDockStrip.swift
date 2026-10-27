import Cocoa
import HelpUI
import Localization
import ToolModuleKit

/// One pill in the dock: a folded fragment panel, or the one that is up
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// It wears the shape a pane wears when it is dragged — a fully rounded plate
/// with a document glyph and a name — because it is the same idea: a document
/// held in the hand rather than laid out on the bench.
final class FragmentPillView: NSView {
    static let height: CGFloat = 24
    /// Past this the name truncates rather than the pill taking the whole dock.
    /// Wide enough for a module's section with its codec badge,
    /// `S3RestoreAcpiPei ▸ LZMA compressed section` with **LZMA**.
    static let maximumWidth: CGFloat = 360
    private static let textInset: CGFloat = 10
    private static let iconGap: CGFloat = 5

    let id: FragmentDock.PanelID
    /// Whether this is the panel on screen. Filled rather than outlined, so the
    /// dock says at a glance which pill the panel in front belongs to.
    var isUp = false {
        didSet {
            needsDisplay = true
            updateShadow()
        }
    }
    /// Whether the part holds bytes the parent has not got back yet. A dot, not
    /// a word: the pill has room for a name and a codec's word and no more.
    var hasChanges = false {
        didSet {
            dot.isHidden = !hasChanges
            dotCollapsed.isActive = !hasChanges
            dotGap.constant = hasChanges ? 3 : 0
        }
    }
    /// The codec the part's bytes went through — `LZMA`, `XOR 77` — in a
    /// capsule after the name, and the sentence under the pointer; nil for a
    /// part that holds the file's own bytes. What the name used to say with
    /// `decompressed` or `(decoded)`, said once for every kind of part.
    /// The badge after the name: a codec's transform, or the panel's kind
    /// (`Code`), with the sentence under the pointer.
    var transform: (text: String, explanation: String?, symbolName: String?,
                    isTransform: Bool)? {
        didSet {
            badge.text = transform?.text ?? ""
            badge.symbolName = transform?.symbolName
            badge.isTransform = transform?.isTransform ?? false
            ControlHelp.describe(badge, name: transform?.text ?? "", tooltip: transform?.explanation)
            badge.isHidden = transform == nil
            badgeCollapsed.isActive = transform == nil
            badgeGap.constant = transform == nil ? 0 : Self.iconGap
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Right-click ▸ Open in New Tab, the menu's way out to a tab.
    var onTearOff: (() -> Void)?
    /// The pill has been dragged past the threshold: the panel's pane is
    /// carried off as its header carries it — onto the New Tab strip, into
    /// another window or tab — with the event that began the drag and the
    /// pill it began on.
    var onDrag: ((NSEvent, NSView) -> Void)?
    /// Where the press that may become a drag began; nil once it has.
    private var pressOrigin: NSPoint?
    /// Whether there is a window to put a tab beside.
    var canTearOff = true

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = PartBadgeView(isTransform: true)
    private lazy var badgeGap = badge.leadingAnchor.constraint(equalTo: label.trailingAnchor)
    /// A hidden badge still has its insets' width: without a part's codec it
    /// takes none, so the dot and the ✕ sit where they did.
    private lazy var badgeCollapsed = badge.widthAnchor.constraint(equalToConstant: 0)
    private let dot = ChangeDotView()
    /// A hidden dot, like a hidden badge, still has its width: without
    /// changes it takes none, so the ✕ sits right after the name or the badge.
    private lazy var dotGap = dot.leadingAnchor.constraint(equalTo: badge.trailingAnchor)
    private lazy var dotCollapsed = dot.widthAnchor.constraint(equalToConstant: 0)
    private let closeButton = NSButton()

    init(id: FragmentDock.PanelID, title: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        // A folded pill stands slightly off the dock, like a card laid on it;
        // the one that is up is filled and needs nothing more to stand out.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        updateShadow()

        icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = title
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The badge keeps its word whole; the name gives way to it.
        badge.isHidden = true
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        dot.isHidden = true
        dot.setContentHuggingPriority(.required, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close"))
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        ControlHelp.describe(closeButton, L("Close “%1$@”", title))

        for subview in [icon, label, badge, dot, closeButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.iconGap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeGap,
            badgeCollapsed,
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotGap,
            dotCollapsed,
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            ControlHelp.describe(closeButton, L("Close “%1$@”", newValue))
        }
    }

    private func updateShadow() {
        layer?.shadowOpacity = isUp ? 0 : 0.2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A theme change zeroes the layer's shadow opacity — AppKit resets it
        // from the view's own `shadow`, which is nil — before this is called,
        // so the shadow has to be put back here or it is gone.
        updateShadow()
    }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        layer?.shadowPath = CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                                   cornerHeight: rect.height / 2, transform: nil)
    }

    /// A folded pill's plate: white in a light window. A dark window has no
    /// white that does not glare, so there it is a step lighter than the dock.
    private var foldedFill: NSColor {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.3, alpha: 1)
            : .white
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func tearOffTapped() { onTearOff?() }

    /// A press is a click until it moves: the pill is chosen when the button
    /// comes up, so a drag never folds or raises a panel on its way out.
    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, let onDrag else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard hypot(dx, dy) >= PaneHeaderView.dragThreshold else { return }
        // One drag per press: the session takes the mouse from here.
        pressOrigin = nil
        onDrag(event, self)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressOrigin != nil else { return }
        pressOrigin = nil
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Built here rather than validated through the responder chain: the
        // pill is not a control the menu bar knows about, and both items act on
        // this panel alone.
        menu.autoenablesItems = false
        let tearOff = menu.addItem(withTitle: L("Open in New Tab"),
                                   action: #selector(tearOffTapped), keyEquivalent: "")
        tearOff.target = self
        tearOff.isEnabled = canTearOff
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: L("Close “%1$@”", title),
                                 action: #selector(closeTapped), keyEquivalent: "")
        close.target = self
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect,
                                xRadius: rect.height / 2, yRadius: rect.height / 2)
        if isUp {
            NSColor.selectedContentBackgroundColor.setFill()
            pill.fill()
        } else {
            foldedFill.setFill()
            pill.fill()
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            pill.lineWidth = 0.5
            pill.stroke()
        }
        let ink: NSColor = isUp ? .alternateSelectedControlTextColor : .labelColor
        label.textColor = ink
        icon.contentTintColor = isUp ? ink : .secondaryLabelColor
        dot.color = isUp ? ink : .secondaryLabelColor
        closeButton.contentTintColor = isUp ? ink : .secondaryLabelColor
        badge.ink = isUp ? ink : nil
    }
}

/// The pill's mark for a part with changes the parent has not got back: a
/// disc drawn on the pill's centre line. A `•` in a text field sits where
/// the font puts it — below the middle of the line, so below the name's
/// middle too.
final class ChangeDotView: NSView {
    static let diameter: CGFloat = 5

    var color: NSColor = .secondaryLabelColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height, Self.diameter)
        guard side > 0 else { return }
        let disc = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        color.setFill()
        NSBezierPath(ovalIn: disc).fill()
    }
}

/// The dock along the bottom of the window: one pill per fragment panel the tab
/// has open (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// It takes its own height rather than lying over the panes, the way the New
/// Tab strip at the other end does: a dock drawn over a pane's status bar would
/// hide the one line that says where the caret is.
// help: window.fragments
final class FragmentDockStrip: NSView {
    static let height: CGFloat = 36

    /// What the dock shows, in the dock's own order.
    struct Item: Equatable {
        let id: FragmentDock.PanelID
        var title: String
        var isUp: Bool
        var hasChanges: Bool
        var canTearOff: Bool
        /// The word for what the panel is — a codec's transform, or `Code` —
        /// and its badge's sentence; nil for the file's own bytes.
        var transform: String? = nil
        var transformExplanation: String? = nil
        var transformSymbol: String? = nil
        var transformIsTransform = true
    }

    var onSelect: ((FragmentDock.PanelID) -> Void)?
    var onClose: ((FragmentDock.PanelID) -> Void)?
    var onTearOff: ((FragmentDock.PanelID) -> Void)?
    var onDrag: ((FragmentDock.PanelID, NSEvent, NSView) -> Void)?

    private let row = NSStackView()
    private var pills: [FragmentDock.PanelID: FragmentPillView] = [:]

    /// The pills on screen, in their order — read by the suite.
    var pillsForTesting: [FragmentPillView] {
        row.arrangedSubviews.compactMap { $0 as? FragmentPillView }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Cast upward, over the panes and over the panel that is up: the dock
        // lies on top of everything, and the panel comes out from under it.
        // Drawn above its siblings for the same reason — the panel host is
        // added after it and would otherwise cover the shadow.
        layer?.zPosition = Self.zPosition
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Self.shadowOpacity
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Where the dock stands among its siblings' layers: over the panel host,
    /// so the panel reads as coming out from under it.
    static let zPosition: CGFloat = 1
    private static let shadowOpacity: Float = 0.22

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A theme change zeroes the layer's shadow opacity — AppKit resets it
        // from the view's own `shadow`, which is nil — before this is called,
        // so the shadow has to be put back here or it is gone.
        layer?.shadowOpacity = Self.shadowOpacity
    }

    override func layout() {
        super.layout()
        // An explicit path: without one Core Animation works the shadow out
        // from the drawn content on every frame.
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        // The same rule the pane header draws along its own edge, so the dock
        // reads as chrome of the same kind.
        PaneHeaderView.headerRuleColor().setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// Where a panel's pill sits, in this strip's own coordinates, or nil when
    /// the dock has no pill for it. What a folding panel flies into.
    ///
    /// Laid out before it answers: a pill added a moment ago has no frame yet,
    /// and until the row arranges them every pill sits at its leading edge —
    /// which is why every new panel flew out of the leftmost position instead
    /// of out of its own.
    func pillFrame(for id: FragmentDock.PanelID) -> NSRect? {
        guard let pill = pills[id] else { return nil }
        window?.layoutIfNeeded()
        return pill.convert(pill.bounds, to: self)
    }

    /// Brings the pills in line with `items`, reusing the ones already there:
    /// a pill rebuilt on every change would lose its tracking and flicker on a
    /// name that did not change.
    func setItems(_ items: [Item]) {
        let wanted = Set(items.map(\.id))
        for (id, pill) in pills where !wanted.contains(id) {
            row.removeArrangedSubview(pill)
            pill.removeFromSuperview()
            pills.removeValue(forKey: id)
        }
        for (index, item) in items.enumerated() {
            let pill = pills[item.id] ?? makePill(item)
            pill.title = item.title
            pill.isUp = item.isUp
            pill.hasChanges = item.hasChanges
            let wantedTransform = item.transform.map {
                (text: $0, explanation: item.transformExplanation,
                 symbolName: item.transformSymbol,
                 isTransform: item.transformIsTransform)
            }
            if pill.transform?.text != wantedTransform?.text
                || pill.transform?.explanation != wantedTransform?.explanation
                || pill.transform?.symbolName != wantedTransform?.symbolName
                || pill.transform?.isTransform != wantedTransform?.isTransform {
                pill.transform = wantedTransform
            }
            pill.canTearOff = item.canTearOff
            if row.arrangedSubviews.firstIndex(of: pill) != index {
                row.insertArrangedSubview(pill, at: index)
            }
        }
    }

    private func makePill(_ item: Item) -> FragmentPillView {
        let pill = FragmentPillView(id: item.id, title: item.title)
        pill.onSelect = { [weak self] in self?.onSelect?(item.id) }
        pill.onClose = { [weak self] in self?.onClose?(item.id) }
        pill.onTearOff = { [weak self] in self?.onTearOff?(item.id) }
        pill.onDrag = { [weak self] event, pill in self?.onDrag?(item.id, event, pill) }
        pills[item.id] = pill
        return pill
    }
}
