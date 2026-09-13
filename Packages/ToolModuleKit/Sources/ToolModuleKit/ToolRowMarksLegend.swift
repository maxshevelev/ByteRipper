import AppKit

/// The legend every panel that marks its rows carries (`Design/ROW_MARKS.md`
/// §6): a disclosure strip under the table, one line collapsed, a line per mark
/// the panel draws expanded, with the Show Markings switch in its header.
///
/// Its lines come from the same catalogue the cells are dressed from
/// (`ToolRowMark`), so what it says a mark means is what the rows mean by it.
/// Both its states — open or shut, markings on or off — are remembered per
/// panel, in the store every panel setting lives in (`ToolPanelFont.defaults`).
@MainActor public final class ToolRowMarksLegend: NSView {
    /// A line only one panel has: a verdict symbol and what it says.
    public struct VerdictEntry {
        public var symbol: String
        public var tint: NSColor
        public var meaning: String

        public init(symbol: String, tint: NSColor, meaning: String) {
            self.symbol = symbol
            self.tint = tint
            self.meaning = meaning
        }
    }

    /// Called when the reader turns the markings off or on.
    public var onShowMarkingsChanged: ((Bool) -> Void)?
    public private(set) var showsMarkings: Bool
    public private(set) var isExpanded: Bool

    private let panel: String
    private var marks: [ToolRowMark]
    private let verdicts: [VerdictEntry]
    private let disclosure = NSButton()
    private let titleButton = NSButton()
    private let showSwitch = NSButton(checkboxWithTitle: "Show markings", target: nil, action: nil)
    private let entries = NSStackView()
    private var zoomObserver: NSObjectProtocol?

    /// Room above the header and below the last line, between the header and
    /// the list, and between the list's lines.
    static let margin: CGFloat = 6
    static let bodyGap: CGFloat = 8
    static let lineSpacing: CGFloat = 5

    static func expandedKey(_ panel: String) -> String { "RowMarksLegendExpanded.\(panel)" }
    static func showsMarkingsKey(_ panel: String) -> String { "RowMarksShown.\(panel)" }

    /// - Parameters:
    ///   - panel: the key the legend's states are remembered under.
    ///   - marks: every mark this panel draws — and nothing it does not.
    ///   - verdicts: the panel's own verdict lines, listed in the verdict
    ///     channel's place.
    public init(panel: String, marks: [ToolRowMark], verdicts: [VerdictEntry] = []) {
        self.panel = panel
        self.marks = marks
        self.verdicts = verdicts
        let defaults = ToolPanelFont.defaults
        // Collapsed until the reader opens it: a reader who has learnt the
        // marks stops paying the room.
        isExpanded = defaults.object(forKey: Self.expandedKey(panel)) as? Bool ?? false
        showsMarkings = defaults.object(forKey: Self.showsMarkingsKey(panel)) as? Bool ?? true
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    /// Changes what the legend lists — when a panel starts drawing a mark.
    public func setMarks(_ marks: [ToolRowMark]) {
        self.marks = marks
        rebuildEntries()
    }

    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        ToolPanelFont.defaults.set(expanded, forKey: Self.expandedKey(panel))
        applyState()
    }

    public func setShowsMarkings(_ shows: Bool) {
        guard shows != showsMarkings else { return }
        showsMarkings = shows
        ToolPanelFont.defaults.set(shows, forKey: Self.showsMarkingsKey(panel))
        applyState()
        rebuildEntries()
        onShowMarkingsChanged?(shows)
    }

    /// The meanings listed, in order — what a test reads.
    var listedMeanings: [String] {
        entries.arrangedSubviews.compactMap { line in
            line.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
        }
    }

    // MARK: - Building

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked)
        disclosure.setAccessibilityLabel("Legend")

        titleButton.isBordered = false
        titleButton.target = self
        titleButton.action = #selector(titleClicked)

        showSwitch.controlSize = .small
        showSwitch.target = self
        showSwitch.action = #selector(switchClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [disclosure, titleButton, spacer, showSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 2

        entries.orientation = .vertical
        // Every line as wide as the list, so no line's width is left open.
        entries.alignment = .width
        entries.spacing = Self.lineSpacing
        // Under the title, not under the chevron.
        entries.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let stack = NSStackView(views: [header, entries])
        stack.orientation = .vertical
        stack.alignment = .leading
        // A hidden list takes its gap with it, so shut the strip is the header
        // and its margins alone.
        stack.spacing = Self.bodyGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.margin),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.margin),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // As wide as the legend, so a line's width has one answer: its
            // content, up to here.
            entries.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        applyFont()
        applyState()
        rebuildEntries()
        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyFont()
            self?.rebuildEntries()
        }
    }

    private func applyFont() {
        titleButton.attributedTitle = NSAttributedString(string: "Legend", attributes: [
            .font: ToolPanelFont.body(),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        showSwitch.font = ToolPanelFont.body()
    }

    private func applyState() {
        disclosure.state = isExpanded ? .on : .off
        showSwitch.state = showsMarkings ? .on : .off
        entries.isHidden = !isExpanded
    }

    /// One line per mark, in the order of the channels; the panel's verdicts
    /// where the verdict channel falls.
    private func rebuildEntries() {
        entries.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let sorted = marks.enumerated()
            .sorted { ($0.element.channel, $0.offset) < ($1.element.channel, $1.offset) }
            .map(\.element)
        var addedVerdicts = verdicts.isEmpty
        for mark in sorted {
            if !addedVerdicts, mark.channel > .verdict {
                verdicts.forEach(addVerdict)
                addedVerdicts = true
            }
            add(mark)
        }
        if !addedVerdicts { verdicts.forEach(addVerdict) }
    }

    private func add(_ mark: ToolRowMark) {
        let isPaint = mark.channel == .background || mark.channel == .rail
        let sample: NSView
        switch mark.channel {
        case .background: sample = LegendSample(kind: .swatch(mark.tint))
        case .rail: sample = LegendSample(kind: .rail(mark.tint))
        default: sample = symbolView(mark.symbol ?? "", tint: mark.tint)
        }
        // With the markings off, the paint the switch hid stays listed, greyed,
        // so the switch explains what it has hidden.
        let hidden = isPaint && !showsMarkings
        sample.alphaValue = hidden ? 0.4 : 1
        addLine(sample: sample, meaning: mark.meaning, greyed: hidden)
    }

    private func addVerdict(_ verdict: VerdictEntry) {
        addLine(sample: symbolView(verdict.symbol, tint: verdict.tint),
                meaning: verdict.meaning, greyed: false)
    }

    private func addLine(sample: NSView, meaning: String, greyed: Bool) {
        let side = ToolPanelFont.size + 2
        sample.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sample.widthAnchor.constraint(equalToConstant: side + 4),
            sample.heightAnchor.constraint(equalToConstant: side)
        ])
        let label = NSTextField(labelWithString: meaning)
        label.font = ToolPanelFont.body()
        label.textColor = greyed ? .tertiaryLabelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        // Its own width, cut short only when the legend is narrower.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        // A plain view with every edge said, not a stack of two: a horizontal
        // stack inside a leading-aligned one has a width anywhere from its
        // content to the list's, and a panel in a window reports each such
        // line as ambiguous (measured, in the UEFI panel).
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(sample)
        line.addSubview(label)
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            sample.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: sample.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: line.trailingAnchor),
            label.topAnchor.constraint(equalTo: line.topAnchor),
            label.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualTo: sample.heightAnchor)
        ])
        entries.addArrangedSubview(line)
    }

    private func symbolView(_ symbol: String, tint: NSColor) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.image?.isTemplate = true
        image.contentTintColor = tint
        image.symbolConfiguration = .init(pointSize: ToolPanelFont.size, weight: .regular)
        image.imageScaling = .scaleProportionallyUpOrDown
        return image
    }

    // MARK: - Actions

    @objc private func disclosureClicked() {
        setExpanded(disclosure.state == .on)
    }

    @objc private func titleClicked() {
        setExpanded(!isExpanded)
    }

    @objc private func switchClicked() {
        setShowsMarkings(showSwitch.state == .on)
    }
}

/// The paint a row wears, drawn small: a row-coloured swatch with the tint
/// over it, or with the rail at its edge.
private final class LegendSample: NSView {
    enum Kind {
        case swatch(NSColor)
        case rail(NSColor)
    }

    private let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        switch kind {
        case .swatch(let tint):
            tint.setFill()
            shape.fill()
        case .rail(let tint):
            tint.setFill()
            NSRect(x: box.minX, y: box.minY, width: ToolPanelRowView.railWidth, height: box.height)
                .fill(using: .sourceOver)
        }
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}
