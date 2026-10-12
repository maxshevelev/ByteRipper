import Cocoa
import AppPalette
import HelpUI
import Localization
import ToolModuleKit

/// The cards of the Annotations window (`NotesWindowController`): each note a card drawn as it
/// is over the dump — its author's hue, a dashed outline and a light wash —
/// with everything it says, in columns that scroll (issue #37).
///
/// A card: the agent's picture, on a note the agent made, and the title; the file, after a dot filled while it is open; the
/// place — the node it is on after its parent, as the Contents search results
/// name it, a link that opens it in UEFI Structure, or the addresses in a
/// file with no firmware tree; the note whole; the annotations it is about,
/// as links to their cards. A place in decompressed or decoded bytes wears
/// the badges of the codecs before it, and goes to a fragment panel of those
/// bytes. A click selects, ⌘ and ⇧ add; a double-click or Return goes to the
/// place; the ✕ in the corner removes the card, Delete the selected ones; the
/// arrows move between cards.
// help: window.notes
@MainActor
final class AgentAnnotationCards: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection = AnnotationCollectionView()
    let scroll = NSScrollView()
    private let layout = AnnotationMasonryLayout()

    var onShow: (String) -> Void = { _ in }
    var onOpenSite: (AgentAnnotation) -> Void = { _ in }
    var onRemove: ([String]) -> Void = { _ in }
    var onEdit: (AgentAnnotation) -> Void = { _ in }
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
        // The theme's own background, as a document's: the cards' washes
        // read on it as they do over the dump.
        collection.backgroundColors = [.textBackgroundColor]
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

    }

    /// The annotations as cards; the selection stays with the ones it was on.
    func show(_ annotations: [AgentAnnotation]) {
        let chosen = Set(selectedIDs)
        rows = annotations
        layout.invalidateLayout()
        collection.reloadData()
        let kept = Set(rows.indices.filter { chosen.contains(rows[$0].id) }.map { IndexPath(item: $0, section: 0) })
        collection.selectionIndexPaths = kept
    }

    /// The text grew or shrank with the panels' zoom.
    func zoomChanged() {
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
        card.card.onEdit = { [weak self] in self?.onEdit(annotation) }
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
            file: fileName, codecs: annotation.decoded?.codecs.map(\.text) ?? [], address: address,
            path: annotation.file.url?.path,
            site: annotation.site?.label, note: annotation.note,
            related: annotation.relatedTo.map { ($0, titles[$0] ?? "") },
            byAgent: annotation.author == .agent)
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
        /// Made by the agent — its hue and its picture before the title — or
        /// by the person, in the person's hue.
        var byAgent = true
    }

    var isSelected = false { didSet { needsDisplay = true } }
    var onDoubleClick: () -> Void = {}
    var onSite: () -> Void = {}
    var onRelated: (String) -> Void = { _ in }
    var onRemove: () -> Void = {}
    /// The pencil on a note the person made: opens it for editing.
    var onEdit: () -> Void = {}

    /// The lines under the header, top to bottom; a wrapping line takes the
    /// card's whole width, a link only its own.
    private var lines: [(view: NSView, wraps: Bool)] = []
    private var header: (title: NSTextField, remove: NSButton)?
    /// The picture before the title: the agent's on a note it made, the
    /// pencil that edits a note the person made.
    private var headerIcon: NSView?
    /// The card's hue: the agent's or the person's.
    private(set) var hue = ZoneColors.agent
    /// Whether the card wears the agent's picture, for tests.
    var showsAgentIcon: Bool { headerIcon is NSImageView }
    /// The pencil, for tests.
    var editButton: NSButton? { headerIcon as? NSButton }
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 4
    /// How far the ✕ stands out of the card's corner, as the badge on an
    /// iPhone app being deleted does.
    static let removeOverhang: CGFloat = 8
    private static let headerSpacing: CGFloat = 6
    private(set) var texts: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The ✕ standing out of the corner answers a click outside the card too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let remove = header?.remove, !remove.isHidden,
           remove.frame.contains(convert(point, from: superview)) {
            return remove
        }
        return super.hitTest(point)
    }

    func show(_ content: Content) {
        subviews.forEach { $0.removeFromSuperview() }
        lines = []
        texts = []
        let title = label(content.title, font: ToolPanelFont.title(), wraps: true)
        // help: window.notes
        let remove = AnnotationRemoveBadge { [weak self] in self?.onRemove() }
        [title, remove].forEach(addSubview)
        header = (title, remove)
        hue = content.byAgent ? ZoneColors.agent : ZoneColors.person
        remove.hue = hue
        headerIcon = nil
        let symbolSize = NSImage.SymbolConfiguration(pointSize: ToolPanelFont.title().pointSize, weight: .regular)
        if !content.byAgent {
            // help: window.notes.edit
            let pencil = CardEditButton { [weak self] in self?.onEdit() }
            pencil.image = (NSImage(systemSymbolName: "long.text.page.and.pencil", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil))?
                .withSymbolConfiguration(symbolSize)
            pencil.contentTintColor = hue
            ControlHelp.describe(pencil, name: L("Edit Annotation"), tooltip: L("Edit this annotation"))
            addSubview(pencil)
            headerIcon = pencil
        }
        if content.byAgent {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: AgentService.symbolName(connected: true),
                                 accessibilityDescription: L("Agent"))
            icon.symbolConfiguration = symbolSize
            icon.contentTintColor = hue
            icon.toolTip = L("Made by the agent")
            addSubview(icon)
            headerIcon = icon
        }
        texts.append(content.title)

        // The file, after the dot that says whether it is open: one text, so
        // a name that wraps leaves the dot on its first line.
        let dot = content.isOpen ? "●" : "○"
        let file = label("", font: ToolPanelFont.monospacedDigits(), color: .secondaryLabelColor, wraps: true)
        let line = NSMutableAttributedString(string: dot + " ", attributes: [
            .font: ToolPanelFont.body(), .foregroundColor: hue
        ])
        line.append(NSAttributedString(string: content.file, attributes: [
            .font: ToolPanelFont.monospacedDigits(), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        file.attributedStringValue = line
        file.toolTip = [content.isOpen ? L("The file is open") : L("The file is not open"), content.path]
            .compactMap { $0 }.joined(separator: "\n")
        add(file, wraps: true)
        texts.append(dot + " " + content.file)
        // The place: the node, which the bytes selected in the dump do not
        // say — or, with no tree to name it, the addresses.
        let place: AnnotationPlaceLine?
        if let site = content.site {
            let link = CardLinkField(text: site) { [weak self] in self?.onSite() }
            link.toolTip = L("Show in UEFI Structure")
            place = AnnotationPlaceLine(codecs: content.codecs, place: link, text: site)
        } else if let address = content.address {
            let field = label(address, font: ToolPanelFont.monospacedDigits(), color: .secondaryLabelColor)
            field.lineBreakMode = .byTruncatingTail
            place = AnnotationPlaceLine(codecs: content.codecs, place: field, text: address)
        } else {
            place = nil
        }
        if let place {
            add(place, wraps: true)
            texts.append(place.text)
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
        if let (title, remove) = header {
            let removeSize = remove.intrinsicContentSize
            // The ✕ sits on the corner, standing out of the card; the title
            // keeps clear of the part of it inside.
            remove.frame = NSRect(x: width - removeSize.width + Self.removeOverhang, y: -Self.removeOverhang,
                                  width: removeSize.width, height: removeSize.height)
            let inside = max(0, removeSize.width - Self.removeOverhang - Self.padding)
            var left = Self.padding
            if let icon = headerIcon,
               let image = (icon as? NSImageView)?.image ?? (icon as? NSButton)?.image {
                // Sized from the image, not the view: an image view reports
                // a configured symbol's size wrongly.
                let lineHeight = fitted(title, width: .greatestFiniteMagnitude).height
                icon.frame = NSRect(x: left, y: bottom + floor((lineHeight - image.size.height) / 2),
                                    width: image.size.width, height: image.size.height)
                left = icon.frame.maxX + Self.headerSpacing
            }
            let titleWidth = max(0, inner - (left - Self.padding) - inside - Self.headerSpacing)
            title.frame = NSRect(x: left, y: bottom,
                                 width: titleWidth, height: fitted(title, width: titleWidth).height)
            bottom = title.frame.maxY
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
        // A button's cell answers nothing for a bounded size: a link is
        // measured on its one line and gives way at the card's edge.
        if control is NSButton {
            return NSSize(width: min(ceil(cell.cellSize.width), width), height: ceil(cell.cellSize.height))
        }
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
        hue.withAlphaComponent(isSelected ? 0.18 : 0.10).setFill()
        path.fill()
        hue.withAlphaComponent(0.9).setStroke()
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

/// The pencil before the title of a note the person made.
private final class CardEditButton: NSButton {
    private let run: () -> Void

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        title = ""
        target = self
        self.action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { run() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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

/// A link that wraps: a node's name in the place line, which may take more
/// than one line of a narrow card. A click runs `action`.
private final class CardLinkField: NSTextField {
    private let run: () -> Void

    init(text: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        font = ToolPanelFont.body()
        textColor = .linkColor
        stringValue = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { run() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The line of a card under the file's name that says where in it the
/// annotation is: the badges of the codecs a place in decoded bytes came
/// through — as the fragment panel's header wears them — then the place.
/// A node's name too long for the line wraps under its own start, not under
/// the badges; an address stays on one line and gives way at its end.
final class AnnotationPlaceLine: NSView {
    private let badges: [PartBadgeView]
    private let address: NSControl
    private static let gap: CGFloat = 4
    /// What the line says, as one string, for tests.
    let text: String

    init(codecs: [String], place: NSControl, text: String) {
        badges = codecs.map { codec in
            let badge = PartBadgeView()
            badge.text = codec
            return badge
        }
        address = place
        self.text = (codecs + [text]).joined(separator: " ")
        super.init(frame: .zero)
        (badges + [address]).forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// What `view` takes at most `width` wide. A field is measured by its
    /// cell, as the card's other lines are: its intrinsic size came out a few
    /// points short of the text, and the last digit of the addresses was cut.
    private static func measure(_ view: NSView, width: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        guard let cell = (view as? NSControl)?.cell else {
            let size = view.intrinsicContentSize
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return NSSize(width: ceil(min(size.width, width)), height: ceil(size.height))
    }

    /// The frames of the badges and of the place for a line `width` wide.
    /// The badges stand on the place's first line.
    private func frames(width: CGFloat) -> [NSRect] {
        var x: CGFloat = 0
        let badgeSizes = badges.map { Self.measure($0) }
        for size in badgeSizes { x += size.width + Self.gap }
        let room = max(0, width - x)
        let place = Self.measure(address, width: room)
        let firstLine = Self.measure(address).height
        let rowHeight = max(firstLine, badgeSizes.map(\.height).max() ?? 0)
        var frames: [NSRect] = []
        var left: CGFloat = 0
        for size in badgeSizes {
            frames.append(NSRect(x: left, y: floor((rowHeight - size.height) / 2),
                                 width: size.width, height: size.height))
            left += size.width + Self.gap
        }
        frames.append(NSRect(x: x, y: floor((rowHeight - firstLine) / 2), width: place.width, height: place.height))
        return frames
    }

    /// The line's size at most `width` wide.
    func size(forWidth width: CGFloat) -> NSSize {
        let all = frames(width: width)
        return NSSize(width: min(width, all.map(\.maxX).max() ?? 0), height: all.map(\.maxY).max() ?? 0)
    }

    override func layout() {
        super.layout()
        for (view, frame) in zip(badges + [address], frames(width: bounds.width)) {
            view.frame = frame
        }
    }
}

/// The ✕ in a card's corner: removes that one annotation.
/// Opaque — white, outlined and crossed in the card's own hue — so the card
/// does not show through it.
final class AnnotationRemoveBadge: NSButton {
    private let run: () -> Void
    private static let side: CGFloat = 20
    /// The card's hue, which it is outlined and crossed in.
    var hue = ZoneColors.agent { didSet { needsDisplay = true } }

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
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
        let hue = self.hue.withAlphaComponent(0.9)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.white.setFill()
        circle.fill()
        // Pressed, it takes the card's wash, as the card does when selected.
        if isHighlighted {
            self.hue.withAlphaComponent(0.18).setFill()
            circle.fill()
        }
        hue.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        let arm = bounds.width * 0.17
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY - arm))
        cross.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY + arm))
        cross.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY + arm))
        cross.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY - arm))
        cross.lineWidth = 1.8
        cross.lineCapStyle = .round
        cross.stroke()
    }
}
