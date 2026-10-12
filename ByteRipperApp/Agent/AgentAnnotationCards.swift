import Cocoa
import AppPalette
import HelpUI
import Localization
import ToolModuleKit

/// The Annotations page of the Agent window: each annotation a card drawn as
/// it is over the dump — the agent's hue, a dashed outline and a light wash —
/// with everything it says, in columns that scroll (issue #37).
///
/// A card: the number and the title, a dot filled while the file is open;
/// the file and the place; the node it is on, as a link that opens it in
/// UEFI Structure; the note whole; the annotations it is about, as links to
/// their cards. A place in decompressed or decoded bytes wears the badges of
/// the codecs before its addresses, and goes to a fragment panel of those
/// bytes. A click selects, ⌘ and ⇧ add; a double-click or Return goes to the
/// place; the ✕ in the corner removes the card, Delete the selected ones; the
/// arrows move between cards.
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
        card.card.onRemove = { [weak self] in self?.onRemove([annotation.id]) }
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
        // A place in decoded bytes is told in their addresses, after the
        // badges of the codecs they came through.
        let shown = annotation.decoded?.range ?? annotation.range
        let address = shown.map { range in
            range.count <= 1 ? String(format: "0x%llX", range.lowerBound)
                : String(format: "0x%llX–0x%llX", range.lowerBound, range.upperBound)
        }
        return AnnotationCardView.Content(
            id: annotation.id, title: annotation.title, isOpen: isOpen(annotation),
            file: fileName, codecs: annotation.decoded?.codecs ?? [], address: address,
            path: annotation.file.url?.path,
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
        var file: String
        /// The badges before the address: the codecs of decoded bytes.
        var codecs: [String] = []
        var address: String?
        var path: String?
        var site: String?
        var note: String
        var related: [(id: String, title: String)]
    }

    var isSelected = false { didSet { needsDisplay = true } }
    var onDoubleClick: () -> Void = {}
    var onSite: () -> Void = {}
    var onRelated: (String) -> Void = { _ in }
    var onRemove: () -> Void = {}

    /// The lines under the header, top to bottom; a wrapping line takes the
    /// card's whole width, a link only its own.
    private var lines: [(view: NSView, wraps: Bool)] = []
    private var header: (number: NSTextField, title: NSTextField, dot: NSTextField, remove: NSButton)?
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 4
    private static let cornerInset: CGFloat = 5
    private static let headerSpacing: CGFloat = 6
    private(set) var texts: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func show(_ content: Content) {
        subviews.forEach { $0.removeFromSuperview() }
        lines = []
        texts = []
        let number = label(content.id, font: ToolPanelFont.monospacedDigits(), color: .secondaryLabelColor)
        let title = label(content.title, font: ToolPanelFont.title(), wraps: true)
        let dot = label(content.isOpen ? "●" : "○", font: ToolPanelFont.body(), color: ZoneColors.agent)
        dot.toolTip = content.isOpen ? L("The file is open") : L("The file is not open")
        // help: window.agent.annotations
        let remove = AnnotationRemoveBadge { [weak self] in self?.onRemove() }
        [number, title, dot, remove].forEach(addSubview)
        header = (number, title, dot, remove)
        texts += [content.id, content.title]

        let place = AnnotationPlaceLine(file: content.file, codecs: content.codecs, address: content.address)
        place.toolTip = content.path
        add(place, wraps: true)
        texts.append(place.text)
        if let site = content.site {
            let link = linkButton(site) { [weak self] in self?.onSite() }
            link.toolTip = L("Show in UEFI Structure")
            add(link, wraps: false)
            texts.append(site)
        }
        if !content.note.isEmpty {
            add(label(content.note, font: ToolPanelFont.body(), wraps: true), wraps: true)
            texts.append(content.note)
        }
        for related in content.related {
            let text = "→ \(related.id) \(related.title)"
            add(linkButton(text) { [weak self] in self?.onRelated(related.id) }, wraps: false)
            texts.append(text)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// The height the card takes at `width`.
    ///
    /// The lines are placed by hand, by the same code that measures them, so
    /// the height the layout gives the card is the height its text takes.
    /// Measured by Auto Layout instead, a wrapping field's height followed the
    /// width it had last been laid out at, and a note could run out of the
    /// card's bottom.
    func height(forWidth width: CGFloat) -> CGFloat {
        place(width: width)
    }

    override func layout() {
        super.layout()
        place(width: bounds.width)
    }

    /// Frames every line for a card `width` wide; answers the card's height.
    @discardableResult
    private func place(width: CGFloat) -> CGFloat {
        let inner = max(0, width - 2 * Self.padding)
        var bottom = Self.padding
        if let (number, title, dot, remove) = header {
            let numberSize = fitted(number, width: inner)
            let dotSize = fitted(dot, width: inner)
            let removeSize = remove.intrinsicContentSize
            // The ✕ sits in the corner, over the padding; the dot before it.
            remove.frame = NSRect(x: bounds.width - removeSize.width - Self.cornerInset, y: Self.cornerInset,
                                  width: removeSize.width, height: removeSize.height)
            let trailing = removeSize.width + Self.cornerInset - Self.padding + Self.headerSpacing
            let titleWidth = max(0, inner - numberSize.width - dotSize.width - trailing - 2 * Self.headerSpacing)
            title.frame = NSRect(x: Self.padding + numberSize.width + Self.headerSpacing, y: bottom,
                                 width: titleWidth, height: fitted(title, width: titleWidth).height)
            // The number and the dot sit on the title's first line.
            let baseline = bottom + title.firstBaselineOffsetFromTop
            number.frame = NSRect(origin: NSPoint(x: Self.padding, y: 0), size: numberSize)
            number.frame.origin.y = baseline - number.firstBaselineOffsetFromTop
            dot.frame = NSRect(origin: NSPoint(x: Self.padding + inner - trailing - dotSize.width, y: 0), size: dotSize)
            dot.frame.origin.y = baseline - dot.firstBaselineOffsetFromTop
            bottom = [title, number, dot].map(\.frame.maxY).max() ?? bottom
        }
        for line in lines {
            bottom += Self.spacing
            let size = fitted(line.view, width: inner)
            line.view.frame = NSRect(x: Self.padding, y: bottom,
                                     width: line.wraps ? inner : min(size.width, inner), height: size.height)
            bottom = line.view.frame.maxY
        }
        return ceil(bottom + Self.padding)
    }

    /// What `view` takes at most `width` wide: a field's text wrapped at
    /// that width, a link on one line.
    private func fitted(_ view: NSView, width: CGFloat) -> NSSize {
        if let line = view as? AnnotationPlaceLine { return line.size(forWidth: width) }
        guard let control = view as? NSControl, let cell = control.cell else { return view.fittingSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func add(_ view: NSView, wraps: Bool) {
        addSubview(view)
        lines.append((view, wraps))
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
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

/// The line of a card that says where the annotation is: the file, then the
/// badges of the codecs a place in decoded bytes came through — as the
/// fragment panel's header wears them — then the addresses. The file's name
/// gives way first when the card is narrow.
final class AnnotationPlaceLine: NSView {
    private let file: NSTextField
    private let badges: [PartBadgeView]
    private let address: NSTextField?
    private static let gap: CGFloat = 4
    /// What the line says, as one string, for tests.
    let text: String

    init(file name: String, codecs: [String], address text: String?) {
        let font = ToolPanelFont.monospacedDigits()
        file = NSTextField(labelWithString: text == nil ? name : name + " ·")
        file.font = font
        file.textColor = .secondaryLabelColor
        file.lineBreakMode = .byTruncatingMiddle
        file.cell?.truncatesLastVisibleLine = true
        badges = codecs.map { codec in
            let badge = PartBadgeView()
            badge.text = codec
            return badge
        }
        address = text.map { text in
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = .secondaryLabelColor
            return field
        }
        self.text = ([text == nil ? name : name + " ·"] + codecs + [text].compactMap { $0 }).joined(separator: " ")
        super.init(frame: .zero)
        ([file] + badges + [address].compactMap { $0 }).forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The line's size at most `width` wide: one line, whatever the width.
    func size(forWidth width: CGFloat) -> NSSize {
        let heights = ([file] + badges + [address].compactMap { $0 }).map { ceil($0.intrinsicContentSize.height) }
        let wanted = ([file] + badges + [address].compactMap { $0 }).map { ceil($0.intrinsicContentSize.width) }
        let total = wanted.reduce(0, +) + Self.gap * CGFloat(max(0, wanted.count - 1))
        return NSSize(width: min(width, total), height: heights.max() ?? 0)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let tail = badges.map { ceil($0.intrinsicContentSize.width) + Self.gap }.reduce(0, +)
            + (address.map { ceil($0.intrinsicContentSize.width) + Self.gap } ?? 0)
        let fileWidth = max(0, min(ceil(file.intrinsicContentSize.width), bounds.width - tail))
        var x: CGFloat = 0
        func put(_ view: NSView, width: CGFloat) {
            let size = view.intrinsicContentSize
            view.frame = NSRect(x: x, y: floor((height - size.height) / 2), width: width, height: ceil(size.height))
            x += width + Self.gap
        }
        put(file, width: fileWidth)
        badges.forEach { put($0, width: ceil($0.intrinsicContentSize.width)) }
        if let address { put(address, width: ceil(address.intrinsicContentSize.width)) }
    }
}

/// The ✕ in a card's corner: removes that one annotation.
final class AnnotationRemoveBadge: NSButton {
    private let run: () -> Void
    private static let side: CGFloat = 16

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        contentTintColor = .secondaryLabelColor
        target = self
        self.action = #selector(clicked)
        ControlHelp.describe(self, name: L("Remove Annotation"), tooltip: L("Remove this annotation"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    @objc private func clicked() { run() }

    /// A click for tests.
    func click() { run() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (isHighlighted ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
        circle.fill()
        super.draw(dirtyRect)
    }
}
