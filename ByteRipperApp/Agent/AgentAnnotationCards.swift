import Cocoa
import AppPalette
import Localization
import ToolModuleKit

/// The Annotations page of the Agent window: each annotation a card drawn as
/// it is over the dump — the agent's hue, a dashed outline and a light wash —
/// with everything it says, in columns that scroll (issue #37).
///
/// A card: the number and the title, a dot filled while the file is open;
/// the file and the place; the node it is on, as a link that opens it in
/// UEFI Structure; the note whole; the annotations it is about, as links to
/// their cards. A click selects, ⌘ and ⇧ add; a double-click or Return goes to
/// the place; Delete removes the selected; the arrows move between cards.
// help: window.agent.annotations
@MainActor
final class AgentAnnotationCards: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection = AnnotationCollectionView()
    let scroll = NSScrollView()
    private let layout = AnnotationMasonryLayout()
    private let empty = NSTextField(labelWithString: "")

    var onShow: (String) -> Void = { _ in }
    var onOpenSite: (AgentAnnotation) -> Void = { _ in }
    var onRemove: ([String]) -> Void = { _ in }
    var onSelectionChanged: () -> Void = {}
    /// Whether an annotation's file is open on screen now.
    var isOpen: (AgentAnnotation) -> Bool = { _ in false }

    private(set) var rows: [AgentAnnotation] = []
    /// One card laid out off screen, to measure the others by.
    private let sizer = AnnotationCardView()

    func build() {
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(AnnotationCardItem.self, forItemWithIdentifier: AnnotationCardItem.identifier)
        collection.onDelete = { [weak self] in
            guard let self, !self.selectedIDs.isEmpty else { return }
            self.onRemove(self.selectedIDs)
        }
        collection.onReturn = { [weak self] in
            guard let self, let id = self.selectedIDs.first else { return }
            self.onShow(id)
        }
        layout.heightFor = { [weak self] index, width in self?.height(of: index, width: width) ?? 80 }

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        empty.stringValue = L("The agent has not annotated anything yet.")
        empty.font = ToolPanelFont.body()
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    /// The annotations as cards; the selection stays with the ones it was on.
    func show(_ annotations: [AgentAnnotation]) {
        let chosen = Set(selectedIDs)
        rows = annotations
        empty.isHidden = !rows.isEmpty
        layout.invalidateLayout()
        collection.reloadData()
        let kept = Set(rows.indices.filter { chosen.contains(rows[$0].id) }.map { IndexPath(item: $0, section: 0) })
        collection.selectionIndexPaths = kept
    }

    /// The text grew or shrank with the panels' zoom.
    func zoomChanged() {
        empty.font = ToolPanelFont.body()
        layout.invalidateLayout()
        collection.reloadData()
    }

    var isEmpty: Bool { rows.isEmpty }
    var selectedIDs: [String] {
        collection.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < rows.count ? rows[$0].id : nil }
    }

    /// Selects the card of annotation `id` alone and scrolls to it.
    func select(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let path = IndexPath(item: index, section: 0)
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        onSelectionChanged()
    }

    // MARK: - Data

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: AnnotationCardItem.identifier, for: indexPath)
        guard let card = item as? AnnotationCardItem else { return item }
        let annotation = rows[indexPath.item]
        card.card.show(content(of: annotation))
        card.card.onDoubleClick = { [weak self] in self?.onShow(annotation.id) }
        card.card.onSite = { [weak self] in self?.onOpenSite(annotation) }
        card.card.onRelated = { [weak self] id in self?.select(id) }
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged()
    }

    // MARK: - What a card says

    func content(of annotation: AgentAnnotation) -> AnnotationCardView.Content {
        let titles = Dictionary(rows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let fileName: String
        switch annotation.file {
        case .disk(let url, _): fileName = url.lastPathComponent
        case .document(let held): fileName = held.document?.url.lastPathComponent ?? ""
        }
        var place: [String] = [fileName]
        if let range = annotation.range {
            place.append(range.count <= 1 ? String(format: "0x%llX", range.lowerBound)
                         : String(format: "0x%llX–0x%llX", range.lowerBound, range.upperBound))
        }
        return AnnotationCardView.Content(
            id: annotation.id, title: annotation.title, isOpen: isOpen(annotation),
            place: place.joined(separator: " · "), path: annotation.file.url?.path,
            site: annotation.site?.label, note: annotation.note,
            related: annotation.relatedTo.map { ($0, titles[$0] ?? "") })
    }

    private func height(of index: Int, width: CGFloat) -> CGFloat {
        guard index < rows.count else { return 0 }
        sizer.show(content(of: rows[index]))
        return sizer.height(forWidth: width)
    }

    /// What card `id` shows, line by line, for tests.
    func shownTexts(of id: String) -> [String] {
        guard let annotation = rows.first(where: { $0.id == id }) else { return [] }
        sizer.show(content(of: annotation))
        return sizer.texts
    }
}

// MARK: - The collection

/// The collection, with the keys a list of cards answers to.
final class AnnotationCollectionView: NSCollectionView {
    var onDelete: () -> Void = {}
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete()             // Delete, Forward Delete
        case 36, 76: onReturn()              // Return, Enter
        default: super.keyDown(with: event)
        }
    }
}

final class AnnotationCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AnnotationCard")
    let card = AnnotationCardView()

    override func loadView() {
        view = card
    }

    override var isSelected: Bool {
        didSet { card.isSelected = isSelected }
    }
}

/// Cards in as many columns as the width holds — one below 640 points, two
/// below 980, three above — each card as tall as its text, put in the
/// shortest column, so a long note leaves no hole beside it.
final class AnnotationMasonryLayout: NSCollectionViewLayout {
    var heightFor: (Int, CGFloat) -> CGFloat = { _, _ in 80 }
    static let inset: CGFloat = 12
    static let gap: CGFloat = 12
    private var frames: [NSRect] = []
    private var contentHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = -1

    static func columns(forWidth width: CGFloat) -> Int {
        width < 640 ? 1 : width < 980 ? 2 : 3
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
        laidOutWidth = width
        let count = collectionView.numberOfItems(inSection: 0)
        let columns = Self.columns(forWidth: width)
        let columnWidth = max(120, (width - 2 * Self.inset - CGFloat(columns - 1) * Self.gap) / CGFloat(columns))
        var tops = [CGFloat](repeating: Self.inset, count: columns)
        frames = (0..<count).map { index in
            let column = tops.indices.min { tops[$0] < tops[$1] } ?? 0
            let height = ceil(heightFor(index, columnWidth))
            let frame = NSRect(x: Self.inset + CGFloat(column) * (columnWidth + Self.gap), y: tops[column],
                               width: columnWidth, height: height)
            tops[column] += height + Self.gap
            return frame
        }
        contentHeight = (tops.max() ?? Self.inset) - Self.gap + Self.inset
    }

    override var collectionViewContentSize: NSSize {
        let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? 0
        let visible = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: width, height: max(contentHeight, visible))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        frames.indices.filter { frames[$0].intersects(rect) }.compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - laidOutWidth) > 0.5
    }

    /// The frames, for tests.
    var itemFrames: [NSRect] { frames }
}

// MARK: - The card

/// One annotation, drawn as over the dump: the agent's hue as a wash and a
/// dashed outline — a solid one while selected.
final class AnnotationCardView: NSView {
    struct Content {
        var id: String
        var title: String
        var isOpen: Bool
        var place: String
        var path: String?
        var site: String?
        var note: String
        var related: [(id: String, title: String)]
    }

    var isSelected = false { didSet { needsDisplay = true } }
    var onDoubleClick: () -> Void = {}
    var onSite: () -> Void = {}
    var onRelated: (String) -> Void = { _ in }

    private let stack = NSStackView()
    private var widthConstraint: NSLayoutConstraint?
    static let padding: CGFloat = 10
    private(set) var texts: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func show(_ content: Content) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        texts = []
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        let number = label(content.id, font: ToolPanelFont.monospacedDigits(), color: .secondaryLabelColor)
        let title = label(content.title, font: ToolPanelFont.title(), wraps: true)
        let dot = label(content.isOpen ? "●" : "○", font: ToolPanelFont.body(), color: ZoneColors.agent)
        dot.toolTip = content.isOpen ? L("The file is open") : L("The file is not open")
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The title takes the room between the number and the dot, so the dot
        // keeps to the card's right edge.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        number.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        header.distribution = .fill
        header.alignment = .firstBaseline
        header.addArrangedSubview(number)
        header.addArrangedSubview(title)
        header.addArrangedSubview(dot)
        add(header, fill: true)
        texts += [content.id, content.title]

        let place = label(content.place, font: ToolPanelFont.monospacedDigits(), color: .secondaryLabelColor, wraps: true)
        place.toolTip = content.path
        add(place, fill: true)
        texts.append(content.place)
        if let site = content.site {
            let link = linkButton(site) { [weak self] in self?.onSite() }
            link.toolTip = L("Show in UEFI Structure")
            add(link)
            texts.append(site)
        }
        if !content.note.isEmpty {
            add(label(content.note, font: ToolPanelFont.body(), wraps: true), fill: true)
            texts.append(content.note)
        }
        for related in content.related {
            let text = "→ \(related.id) \(related.title)"
            add(linkButton(text) { [weak self] in self?.onRelated(related.id) })
            texts.append(text)
        }
        needsDisplay = true
    }

    /// The height the card takes at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        frame.size.width = width
        widthConstraint?.isActive = false
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
        layoutSubtreeIfNeeded()
        return stack.fittingSize.height + 2 * Self.padding
    }

    private func add(_ view: NSView, fill: Bool = false) {
        stack.addArrangedSubview(view)
        if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        if wraps { field.preferredMaxLayoutWidth = 0 }
        return field
    }

    private func linkButton(_ text: String, action: @escaping () -> Void) -> NSButton {
        let button = CardLinkButton(title: text, action: action)
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: ToolPanelFont.body(), .foregroundColor: NSColor.linkColor
        ])
        return button
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        ZoneColors.agent.withAlphaComponent(isSelected ? 0.18 : 0.10).setFill()
        path.fill()
        ZoneColors.agent.withAlphaComponent(0.9).setStroke()
        path.lineWidth = isSelected ? 2 : 1.5
        if !isSelected {
            let dash: [CGFloat] = [4, 3]
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick() }
    }
}

/// A line of a card that is a link: drawn as one, a click runs `action`.
private final class CardLinkButton: NSButton {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(clicked)
        alignment = .left
        lineBreakMode = .byTruncatingTail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { run() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
