import Cocoa

/// One pill in the dock: a folded fragment panel, or the one that is up
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// It wears the shape a pane wears when it is dragged — a fully rounded plate
/// with a document glyph and a name — because it is the same idea: a document
/// held in the hand rather than laid out on the bench.
final class FragmentPillView: NSView {
    static let height: CGFloat = 24
    /// Past this the name truncates rather than the pill taking the whole dock.
    static let maximumWidth: CGFloat = 220
    private static let textInset: CGFloat = 10
    private static let iconGap: CGFloat = 5

    let id: FragmentDock.PanelID
    /// Whether this is the panel on screen. Filled rather than outlined, so the
    /// dock says at a glance which pill the panel in front belongs to.
    var isUp = false { didSet { needsDisplay = true } }
    /// Whether the part holds bytes the parent has not got back yet. A dot, not
    /// a word: the pill has room for a name and no more.
    var hasChanges = false { didSet { dot.isHidden = !hasChanges } }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Right-click ▸ Open in New Tab. The only way a *folded* panel leaves for
    /// a tab: a pill has no header to drag onto the New Tab strip.
    var onTearOff: (() -> Void)?
    /// Whether there is a window to put a tab beside.
    var canTearOff = true

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "•")
    private let closeButton = NSButton()

    init(id: FragmentDock.PanelID, title: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true

        icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = title
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dot.font = .systemFont(ofSize: 13, weight: .bold)
        dot.textColor = .secondaryLabelColor
        dot.isHidden = true
        dot.setContentHuggingPriority(.required, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityLabel("Close “\(title)”")
        closeButton.toolTip = "Close “\(title)”"

        for subview in [icon, label, dot, closeButton] as [NSView] {
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
            dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
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
            closeButton.setAccessibilityLabel("Close “\(newValue)”")
            closeButton.toolTip = "Close “\(newValue)”"
        }
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func tearOffTapped() { onTearOff?() }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Built here rather than validated through the responder chain: the
        // pill is not a control the menu bar knows about, and both items act on
        // this panel alone.
        menu.autoenablesItems = false
        let tearOff = menu.addItem(withTitle: "Open in New Tab",
                                   action: #selector(tearOffTapped), keyEquivalent: "")
        tearOff.target = self
        tearOff.isEnabled = canTearOff
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "Close “\(title)”",
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
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            pill.fill()
            NSColor.separatorColor.setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
        let ink: NSColor = isUp ? .alternateSelectedControlTextColor : .labelColor
        label.textColor = ink
        icon.contentTintColor = isUp ? ink : .secondaryLabelColor
        dot.textColor = isUp ? ink : .secondaryLabelColor
        closeButton.contentTintColor = isUp ? ink : .secondaryLabelColor
    }
}

/// The dock along the bottom of the window: one pill per fragment panel the tab
/// has open (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// It takes its own height rather than lying over the panes, the way the New
/// Tab strip at the other end does: a dock drawn over a pane's status bar would
/// hide the one line that says where the caret is.
final class FragmentDockStrip: NSView {
    static let height: CGFloat = 36

    /// What the dock shows, in the dock's own order.
    struct Item: Equatable {
        let id: FragmentDock.PanelID
        var title: String
        var isUp: Bool
        var hasChanges: Bool
        var canTearOff: Bool
    }

    var onSelect: ((FragmentDock.PanelID) -> Void)?
    var onClose: ((FragmentDock.PanelID) -> Void)?
    var onTearOff: ((FragmentDock.PanelID) -> Void)?

    private let row = NSStackView()
    private var pills: [FragmentDock.PanelID: FragmentPillView] = [:]

    /// The pills on screen, in their order — read by the suite.
    var pillsForTesting: [FragmentPillView] {
        row.arrangedSubviews.compactMap { $0 as? FragmentPillView }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        // The same rule the pane header draws along its own edge, so the dock
        // reads as chrome of the same kind.
        PaneHeaderView.headerRuleColor().setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
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
        pills[item.id] = pill
        return pill
    }
}
