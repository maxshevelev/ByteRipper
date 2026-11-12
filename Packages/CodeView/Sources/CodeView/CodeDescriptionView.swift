import AppKit
import CodeAnalysis
import HelpUI
import Localization
import ToolModuleKit

/// The module's description, drawn: the Markdown a review wrote, set as a
/// document at the code's zoom. A link to a function — `[Name](0x…)`, or a
/// function's name or address written as code — goes to it in the code; a
/// link to the web opens in the browser; anything else is text.
@MainActor final class CodeDescriptionView: NSView {
    /// A link to the code was followed: the address, and the range of the
    /// link in the text, which Back flashes on the way back.
    var onFollow: ((CodeAddress, NSRange) -> Void)?
    /// What a function's name written as code links to: its entry, or nil.
    var resolveName: ((String) -> CodeAddress?)?
    /// Whether the code holds an address: a function's entry or an instruction.
    var resolvesAddress: ((CodeAddress) -> Bool)?
    /// A section was chosen in the column: a step, which the pane records.
    var onChooseSection: ((Int) -> Void)?
    /// The close button was pressed.
    var onClose: (() -> Void)?
    /// There are sections to list now, or none any more.
    var onSectionsChanged: (() -> Void)?

    /// A heading of the description, and where it stands in the text.
    struct Section: Equatable {
        let title: String
        let level: Int
        let range: NSRange
    }
    private(set) var sections: [Section] = []
    /// The section just gone to, and where the view stood then: a short last
    /// section cannot reach the top of the view, and is still the one chosen.
    private var chosenSection: (index: Int, origin: NSPoint)?
    private static let headingKey = NSAttributedString.Key("CodeDescriptionHeading")

    private let outline = NSOutlineView()
    /// The column of sections. The pane places it, beside the header as well as
    /// the text.
    let sectionColumn = NSScrollView()
    private var outlineRoots: [SectionRow] = []
    fileprivate var sectionRoots: [SectionRow] { outlineRoots }
    fileprivate var isFollowingReading: Bool { followingReading }
    fileprivate var sectionOutlineSelection: SectionRow? { outline.item(atRow: outline.selectedRow) as? SectionRow }
    private var outlineRows: [Int: SectionRow] = [:]
    /// Set while the column follows the reading: that is not a choice.
    private var followingReading = false

    /// Over the text's corner: the way out of the description from where it is
    /// being read.
    let closeButton = CodeDescriptionCloseButton()
    private let scroll = NSScrollView()
    private let text = DescriptionTextView(usingTextLayoutManager: false)
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var markdown: String?
    private var loaded = false
    /// The description of the revision compared with, while there is one:
    /// "" when it had none. The text is then drawn as the code's diff is, what
    /// only that revision had on red and what only this one has on green.
    private var baseline: String?
    /// The diff as drawn, while the text differs from the baseline.
    private(set) var shownDiff: LineDiff?
    /// The paragraphs drawn on the diff's colours.
    var tints: [DescriptionTextView.Tint] { text.tints }

    static let linkScheme = "code-address"

    init() {
        super.init(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        // The code's margin and the text's own at the sides; above and below as
        // far as the column of sections stands from the area's edges.
        text.textContainerInset = NSSize(width: 20, height: 8)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        text.onLink = { [weak self] link, at in self?.clicked(link, at: at) ?? false }
        text.overlay = closeButton
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        placeholder.font = ToolPanelFont.body()
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.style = .inset
        outline.backgroundColor = .windowBackgroundColor
        outline.rowSizeStyle = .custom
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(sectionClicked)
        // help: panel.code.description-sections
        ControlHelp.describe(outline, L("Sections of the description"))
        sectionColumn.documentView = outline
        sectionColumn.hasVerticalScroller = true
        sectionColumn.backgroundColor = .windowBackgroundColor
        sectionColumn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(placeholder)
        GreyCircleSymbol.apply("xmark.circle.fill", pointSize: 20, to: closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // help: panel.code.description
        ControlHelp.describe(closeButton, name: L("Close"), tooltip: L("Close the description"))
        addSubview(closeButton)
        // The placeholder's margins yield to a pane narrower than they are: a
        // split view lays a pane it has not sized yet at no width, and two
        // required margins 20 points in would ask for negative width.
        let insetLeading = placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                              constant: 20)
        let insetTrailing = placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                                 constant: -20)
        insetLeading.priority = NSLayoutConstraint.Priority(999)
        insetTrailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            // Measured to put the circle 10 points from both edges: the symbol's
            // own margins in its frame are not the same on each side.
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8.5),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            insetLeading,
            insetTrailing
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The description to show; nil once loaded means the module has none.
    func show(_ markdown: String?, loaded: Bool = true) {
        self.markdown = markdown
        self.loaded = loaded
        redraw()
    }

    /// The revision to compare with, by its description; nil shows the
    /// description as it is.
    func compare(with baseline: String?) {
        guard baseline != self.baseline else { return }
        self.baseline = baseline
        redraw()
    }

    /// Drawn again at the zoom's new size, or after the code's names changed.
    func redraw() {
        let origin = scroll.contentView.bounds.origin
        text.tints = []
        shownDiff = nil
        if let markdown, !markdown.isEmpty, let baseline, baseline != markdown {
            let merged = Self.merged(baseline, markdown)
            let (drawn, tints) = Self.tinted(render(merged.markdown))
            text.textStorage?.setAttributedString(drawn)
            text.tints = tints
            shownDiff = merged.diff
            placeholder.isHidden = true
        } else if let markdown, !markdown.isEmpty {
            text.textStorage?.setAttributedString(render(markdown))
            placeholder.isHidden = true
        } else {
            text.textStorage?.setAttributedString(NSAttributedString())
            // help: panel.code.description
            placeholder.stringValue = loaded
                ? L("No description of this module yet. A review writes one — what the module is for, how it works and how it is built — and it appears here when the review is published.")
                : ""
            placeholder.isHidden = !loaded
        }
        placeholder.font = ToolPanelFont.body()
        sections = readSections()
        chosenSection = nil
        scroll(to: origin)
        drawOutline()
    }

    @objc private func scrolled() { followReading() }

    @objc private func closeClicked() { onClose?() }

    /// The column holds the headings under one another by their level. A
    /// description with no headings has no column.
    private func drawOutline() {
        outlineRoots = []
        outlineRows = [:]
        var open: [SectionRow] = []
        for (index, section) in sections.enumerated() {
            let row = SectionRow(index: index, title: section.title, level: section.level)
            outlineRows[index] = row
            while let last = open.last, last.level >= section.level { open.removeLast() }
            if let parent = open.last { parent.children.append(row) } else { outlineRoots.append(row) }
            open.append(row)
        }
        let font = ToolPanelFont.body()
        outline.rowHeight = ceil(font.ascender - font.descender - font.leading) + 6
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        onSectionsChanged?()
        followReading()
    }

    /// The section being read stands selected in the column.
    private func followReading() {
        let row = currentSection.flatMap { outlineRows[$0] }.map { outline.row(forItem: $0) } ?? -1
        guard row != outline.selectedRow else { return }
        followingReading = true
        defer { followingReading = false }
        guard row >= 0 else {
            outline.deselectAll(nil)
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// A click goes to its section even when the row is selected already: the
    /// reader may have scrolled on through it. The arrow keys change the
    /// selection instead, which the delegate hears.
    @objc private func sectionClicked() {
        guard let row = outline.item(atRow: outline.clickedRow) as? SectionRow else { return }
        onChooseSection?(row.index)
    }

    var selectedSectionTitle: String? {
        (outline.item(atRow: outline.selectedRow) as? SectionRow)?.title
    }
    /// A click on a section in the column, for a test.
    func clickSection(_ index: Int) {
        guard let item = outlineRows[index] else { return }
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
    }

    private func readSections() -> [Section] {
        let drawn = text.attributedString()
        var found: [Section] = []
        drawn.enumerateAttribute(Self.headingKey, in: NSRange(location: 0, length: drawn.length)) { value, range, _ in
            guard let level = value as? Int else { return }
            let title = drawn.attributedSubstring(from: range).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A heading the compared revision had and this one has not is
            // not a section of the description.
            let removed = text.tints.contains { $0.removed && NSIntersectionRange($0.range, range).length > 0 }
            if !title.isEmpty, !removed { found.append(Section(title: title, level: level, range: range)) }
        }
        // A heading alone at the top of the document is its title, the module's
        // name: the sections are what stands under it.
        if let first = found.first, !found.dropFirst().contains(where: { $0.level <= first.level }) {
            found.removeFirst()
        }
        return found
    }

    /// The section at the top of the view: the last heading at or above it, nil
    /// above the first, where the document's introduction is read.
    var currentSection: Int? {
        guard !sections.isEmpty, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        if let chosenSection, chosenSection.origin == scrollOrigin, sections.indices.contains(chosenSection.index) {
            return chosenSection.index
        }
        // A little under the edge: the heading gone to stands just below it.
        let y = scrollOrigin.y - text.textContainerOrigin.y + size * 2
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: container)
        let character = layout.characterIndexForGlyph(at: glyph)
        return sections.lastIndex { $0.range.location <= character }
    }

    /// Brings a section's heading to the top of the view, and shows it.
    func goToSection(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        scroll(to: NSPoint(x: 0, y: rect(of: sections[index].range).minY - size))
        chosenSection = (index, scrollOrigin)
        flash(sections[index].range)
        followReading()
    }

    var hasDescription: Bool { !(markdown ?? "").isEmpty }
    var shownText: String { text.string }
    var attributedText: NSAttributedString { text.attributedString() }
    var placeholderText: String { placeholder.isHidden ? "" : placeholder.stringValue }
    var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }
    var textView: NSTextView { text }

    func scroll(to origin: NSPoint) {
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
        }
        let visible = scroll.contentView.bounds.size
        let y = max(0, min(origin.y, text.frame.height - visible.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Shows where the reader came back to: the link they followed, where
    /// the description is scrolled as they left it.
    func flash(_ range: NSRange) {
        guard NSMaxRange(range) <= (text.string as NSString).length else { return }
        if text.window != nil, text.visibleRect.intersects(rect(of: range)) { text.showFindIndicator(for: range) }
    }

    private func rect(of range: NSRange) -> NSRect {
        guard let layout = text.layoutManager, let container = text.textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    /// The link at `index` of the text, followed as a click would: for tests.
    @discardableResult
    func followLink(at index: Int) -> Bool {
        guard let link = text.textStorage?.attribute(.link, at: index, effectiveRange: nil) else { return false }
        return clicked(link, at: index)
    }

    private func clicked(_ link: Any, at index: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
              url.scheme == Self.linkScheme else { return false }
        guard let address = CodeAddress(hex: url.absoluteString.dropFirst(Self.linkScheme.count + 1).description)
        else { return true }
        var range = NSRange()
        _ = text.textStorage?.attribute(.link, at: index, effectiveRange: &range)
        onFollow?(address, range)
        return true
    }

    // MARK: - Drawing the Markdown

    private var size: CGFloat { ToolPanelFont.size }

    /// The Markdown as Foundation parses it — CommonMark with GitHub's
    /// tables — set in the view's own type: each block a paragraph whose
    /// style comes from where the block stands (a heading, an item of a list
    /// inside a list, a cell of a table), each run's emphasis, code and link
    /// on top.
    // MARK: - Against a revision

    /// What marks a source line as one only the new text has, or only the old:
    /// characters no description holds, taken out once drawn.
    static let addedMark: Character = "\u{E000}"
    static let removedMark: Character = "\u{E001}"

    /// The two descriptions as one Markdown text, line by line in the order
    /// of their diff, each line one of them lacks marked. A marked line of
    /// running text stands as a paragraph of its own, so its colour does not
    /// spread over the lines both share; a line of a table or of a code block
    /// stays where it is, as the table or the block would end otherwise.
    static func merged(_ old: String, _ new: String) -> (markdown: String, diff: LineDiff) {
        let diff = LineDiff.between(old, new)
        var lines: [String] = []
        var inFence = false
        for row in diff.rows {
            let text: String
            let mark: Character?
            switch row {
            case .same(_, _, let line): text = line; mark = nil
            case .removed(_, let line): text = line; mark = removedMark
            case .added(_, let line): text = line; mark = addedMark
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            defer { if fence { inFence.toggle() } }
            guard let mark, !trimmed.isEmpty, !fence else {
                lines.append(text)
                continue
            }
            if inFence {
                lines.append(String(mark) + text)
            } else if trimmed.hasPrefix("|") {
                lines.append(markCells(text, mark))
            } else {
                lines.append(contentsOf: ["", marked(text, mark), ""])
            }
        }
        return (lines.joined(separator: "\n"), diff)
    }

    /// The mark after what makes the line a heading, an item or a quote.
    private static func marked(_ line: String, _ mark: Character) -> String {
        let pattern = #"^\s*(?:>\s*)*(?:(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?(?:#{1,6}\s+)?"#
        let lead = line.range(of: pattern, options: .regularExpression).map { line[$0] } ?? ""
        return String(lead) + String(mark) + String(line.dropFirst(lead.count))
    }

    /// The mark in every cell of a table row, so the whole row reads coloured.
    private static func markCells(_ line: String, _ mark: Character) -> String {
        var cells = line.components(separatedBy: "|")
        guard cells.count > 2 else { return line }
        // The row under the header says where the columns lie: a mark would
        // make it a row of text, and the table would be no table.
        let inner = cells[1..<(cells.count - 1)]
        if inner.allSatisfy({ $0.range(of: #"^\s*:?-+:?\s*$"#, options: .regularExpression) != nil }) { return line }
        for index in 1..<(cells.count - 1) {
            let cell = cells[index]
            let lead = cell.prefix { $0 == " " }
            cells[index] = String(lead) + String(mark) + String(cell.dropFirst(lead.count))
        }
        return cells.joined(separator: "|")
    }

    /// Takes the marks out of the drawn text, and names the paragraphs they
    /// stood in: the rows the view colours.
    static func tinted(_ drawn: NSAttributedString) -> (NSAttributedString, [DescriptionTextView.Tint]) {
        let out = NSMutableAttributedString(attributedString: drawn)
        let string = out.string as NSString
        var marks: [(location: Int, removed: Bool)] = []
        let added = String(addedMark), removed = String(removedMark)
        var index = 0
        while index < string.length {
            let character = string.substring(with: NSRange(location: index, length: 1))
            if character == added || character == removed { marks.append((index, character == removed)) }
            index += 1
        }
        for mark in marks.reversed() { out.deleteCharacters(in: NSRange(location: mark.location, length: 1)) }
        let plain = out.string as NSString
        var tints: [DescriptionTextView.Tint] = []
        for (shift, mark) in marks.enumerated() {
            let location = min(mark.location - shift, max(0, plain.length - 1))
            guard plain.length > 0 else { break }
            let range = plain.paragraphRange(for: NSRange(location: location, length: 0))
            if tints.last?.range == range { continue }
            tints.append(.init(range: range, removed: mark.removed))
        }
        return (out, tints)
    }

    func render(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: body(), .foregroundColor: NSColor.labelColor])
        }
        let out = NSMutableAttributedString()
        var block: Int?
        var style = NSMutableParagraphStyle()
        var font = body()
        var color = NSColor.labelColor
        var code = false
        var headingLevel: Int?
        var lastWasList = false
        var lastWasTable = false
        var markedItems: Set<Int> = []
        var tables: [Int: NSTextTable] = [:]
        var codeBlocks: [Int: NSTextBlock] = [:]
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            var text = String(parsed[run.range].characters)
            if identity != block {
                if block != nil {
                    out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
                }
                block = identity
                let kinds = components.map(\.kind)
                let lists = kinds.filter { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }
                let inTable = kinds.contains { if case .tableCell = $0 { return true }; return false }
                let quoted = kinds.contains { if case .blockQuote = $0 { return true }; return false }
                let indent = CGFloat(lists.count) * size * 1.6 + (quoted ? size : 0)
                style = paragraph(indent: indent, before: 0, after: size * 0.6)
                font = body()
                color = quoted ? .secondaryLabelColor : .labelColor
                code = false
                headingLevel = nil
                if (lastWasList && lists.isEmpty) || (lastWasTable && !inTable) {
                    style.paragraphSpacingBefore = size * 0.6
                }
                lastWasList = !lists.isEmpty
                lastWasTable = inTable
                switch components.first?.kind {
                case .header(let level)?:
                    headingLevel = level
                    let scale: CGFloat = [8, 4, 2, 1, 0, 0][min(max(level, 1), 6) - 1]
                    font = .systemFont(ofSize: size + scale, weight: level <= 1 ? .bold : .semibold)
                    style.paragraphSpacingBefore = out.length == 0 ? 0 : (level <= 2 ? size * 1.1 : size * 0.7)
                    style.paragraphSpacing = level <= 1 ? size * 0.5 : size * 0.3
                case .codeBlock?:
                    code = true
                    font = CodePaneView.codeFont()
                    let box = codeBlocks[identity ?? 0] ?? {
                        let box = NSTextBlock()
                        box.backgroundColor = CodeColors.descriptionCodeBackground
                        box.setWidth(size * 0.6, type: .absoluteValueType, for: .padding)
                        box.setValue(100, type: .percentageValueType, for: .width)
                        return box
                    }()
                    codeBlocks[identity ?? 0] = box
                    style.textBlocks = [box]
                    style.lineBreakMode = .byCharWrapping
                    if text.hasSuffix("\n") { text.removeLast() }
                case .tableCell(let column)?:
                    var row = 0
                    var columns = 1
                    var tableID = 0
                    for component in components {
                        switch component.kind {
                        case .tableRow(let index): row = index
                        case .tableHeaderRow: row = 0
                        case .table(let described):
                            columns = max(1, described.count)
                            tableID = component.identity
                        default: break
                        }
                    }
                    let table = tables[tableID] ?? {
                        let table = NSTextTable()
                        table.numberOfColumns = columns
                        table.layoutAlgorithm = .automaticLayoutAlgorithm
                        table.collapsesBorders = true
                        table.hidesEmptyCells = false
                        return table
                    }()
                    tables[tableID] = table
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                                startingColumn: column, columnSpan: 1)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(.separatorColor)
                    cell.setWidth(size * 0.35, type: .absoluteValueType, for: .padding)
                    if row == 0 {
                        cell.backgroundColor = CodeColors.descriptionTableHeader
                        font = .systemFont(ofSize: size, weight: .semibold)
                    }
                    style = NSMutableParagraphStyle()
                    style.textBlocks = [cell]
                default:
                    break
                }
                // An item's first paragraph carries its marker, hung in the
                // margin; what else the item holds is indented under its text.
                if components.count > 1, case .listItem(let ordinal) = components[1].kind,
                   !markedItems.contains(components[1].identity) {
                    markedItems.insert(components[1].identity)
                    var ordered = false
                    if components.count > 2, case .orderedList = components[2].kind { ordered = true }
                    let marker = ordered ? "\(ordinal).\t" : (lists.count % 2 == 1 ? "•\t" : "◦\t")
                    style.firstLineHeadIndent = indent - size * 1.6
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    style.paragraphSpacing = size * 0.15
                    out.append(NSAttributedString(string: marker, attributes: [
                        .font: ordered ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : body(),
                        .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
                } else if !lists.isEmpty {
                    style.paragraphSpacing = size * 0.15
                }
            }
            let start = out.length
            out.append(inline(text, run: run, font: font, style: style, color: color, inCodeBlock: code))
            if let headingLevel {
                out.addAttribute(Self.headingKey, value: headingLevel,
                                 range: NSRange(location: start, length: out.length - start))
            }
        }
        return out
    }

    private func inline(_ text: String, run: AttributedString.Runs.Run, font: NSFont, style: NSParagraphStyle,
                        color: NSColor, inCodeBlock: Bool) -> NSAttributedString {
        var font = font
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: style]
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if intent.contains(.code), !inCodeBlock {
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            font = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: bold ? .semibold : .regular)
            attributes[.backgroundColor] = CodeColors.descriptionCodeBackground
            if let address = codeTarget(text) { attributes[.link] = codeURL(address) }
        }
        if let link = run.link, let url = linkURL(link.absoluteString) { attributes[.link] = url }
        attributes[.font] = font
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func body() -> NSFont { .systemFont(ofSize: size) }

    private func paragraph(indent: CGFloat, before: CGFloat, after: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.08
        return style
    }

    /// What a link's target is: an address in the code, a function by name,
    /// a page on the web, or nothing to follow — a file path, a relative name.
    private func linkURL(_ target: String) -> URL? {
        let target = target.removingPercentEncoding ?? target
        if target.lowercased().hasPrefix("0x"), let address = CodeAddress(hex: target) {
            return codeURL(address)
        }
        if let address = resolveName?(target) { return codeURL(address) }
        guard let url = URL(string: target), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }

    /// A function's name, or an address the code holds, written as code.
    private func codeTarget(_ code: String) -> CodeAddress? {
        var name = code.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("()") { name.removeLast(2) }
        if name.lowercased().hasPrefix("0x"), let address = CodeAddress(hex: name),
           resolvesAddress?(address) == true {
            return address
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return resolveName?(name)
    }

    private func codeURL(_ address: CodeAddress) -> URL {
        URL(string: "\(Self.linkScheme):\(address.description)")!
    }
}

/// The text view under the description: a link is the view's to follow, and
/// the right-click menu is what read-only text needs.
/// The description's close button. It stands over the text, whose I-beam would
/// otherwise stay on the pointer.
final class CodeDescriptionCloseButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
}

/// A row of the column of sections: a heading, with those under it.
final class SectionRow {
    let index: Int
    let title: String
    let level: Int
    var children: [SectionRow] = []

    init(index: Int, title: String, level: Int) {
        self.index = index
        self.title = title
        self.level = level
    }
}

extension CodeDescriptionView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SectionRow)?.children.count ?? sectionRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SectionRow)?.children[index] ?? sectionRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SectionRow).map { !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? SectionRow else { return nil }
        let label = NSTextField(labelWithString: row.title)
        label.font = ToolPanelFont.body()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// A click's own action goes to the section; hearing it here as well would
    /// make two steps of it.
    private var isClick: Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown?, .leftMouseUp?, .leftMouseDragged?: true
        default: false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isFollowingReading, !isClick, let row = sectionOutlineSelection else { return }
        onChooseSection?(row.index)
    }
}

final class DescriptionTextView: NSTextView, FindBoxHost {
    /// A search's matches, drawn as Xcode draws them (`FindBoxes`).
    var findBoxes: [NSRange] = [] {
        didSet { if findBoxes != oldValue { needsDisplay = true } }
    }

    /// What stands over the text. Under it the text leaves the arrow alone: it
    /// hears the pointer's moves too, and setting its I-beam at each one fights
    /// the button's arrow.
    weak var overlay: NSView?

    private func isOverOverlay(_ event: NSEvent) -> Bool {
        guard let overlay, !overlay.isHiddenOrHasHiddenAncestor else { return false }
        return overlay.bounds.contains(overlay.convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverOverlay(event) { NSCursor.arrow.set() } else { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverOverlay(event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let overlay, !overlay.isHiddenOrHasHiddenAncestor {
            addCursorRect(convert(overlay.bounds, from: overlay), cursor: .arrow)
        }
    }

    /// A text view given a new size scrolls itself (measured: 3.5 points when
    /// the column of sections takes its width). The document stays where it
    /// was read.
    override func setFrameSize(_ newSize: NSSize) {
        let clip = enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        super.setFrameSize(newSize)
        if let clip, let origin, clip.bounds.origin != origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    var onLink: ((Any, Int) -> Bool)?

    override func clicked(onLink link: Any, at charIndex: Int) {
        if onLink?(link, charIndex) == true { return }
        super.clicked(onLink: link, at: charIndex)
    }

    /// A table row is as tall as its tallest cell, and AppKit draws the view
    /// in tiles — while scrolling, a tile at a time. The text view picks what
    /// to draw from the line fragments inside the tile, so a tile that cuts a
    /// row leaves out a cell whose lines lie outside it: its last line half
    /// drawn, its background and borders missing. Asking for whole rows
    /// draws every cell the tile crosses; the tile's clip keeps the rest off.
    /// A paragraph of the description drawn against a revision: what only
    /// that revision had, or what only this one has.
    struct Tint: Equatable {
        let range: NSRange
        let removed: Bool
    }

    /// Coloured the width of the text, as the code's diff colours its rows.
    var tints: [Tint] = [] {
        didSet { if tints != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = tableRows(crossing: dirtyRect)
        drawTints(in: rect)
        super.draw(rect)
    }

    private func drawTints(in rect: NSRect) {
        guard !tints.isEmpty, let layout = layoutManager, let container = textContainer,
              let storage = textStorage else { return }
        for tint in tints where NSMaxRange(tint.range) <= storage.length {
            (tint.removed ? CodeColors.diffRemoved : CodeColors.diffAdded).setFill()
            let glyphs = layout.glyphRange(forCharacterRange: tint.range, actualCharacterRange: nil)
            var first: NSRect?
            layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, _, _ in
                var row = fragment.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                // A paragraph of running text is coloured the width of the
                // view; a cell or a code block keeps to its own box.
                if fragment.width >= container.size.width - 1 { row.origin.x = 0; row.size.width = self.bounds.width }
                if row.intersects(rect) { row.fill() }
                if first == nil {
                    first = used.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                }
            }
            // The mark the code's diff puts before a line, in the margin
            // before the paragraph's first line: - what only the revision
            // compared with had, + what only this one has, as the code's.
            guard let line = first, line.intersects(rect.insetBy(dx: 0, dy: -line.height)) else { continue }
            let mark = tint.removed ? "-" : "+"
            let font = CodePaneView.codeFont()
            let words = NSAttributedString(string: mark, attributes: [
                .font: font,
                .foregroundColor: tint.removed ? CodeColors.diffRemovedMark : CodeColors.diffAddedMark
            ])
            let size = words.size()
            words.draw(at: NSPoint(x: Self.markInset, y: line.midY - size.height / 2))
        }
    }

    /// Where the diff's + and − stand: in the text's left margin.
    static let markInset: CGFloat = 6

    func tableRows(crossing rect: NSRect) -> NSRect {
        guard let storage = textStorage, let layout = layoutManager, storage.length > 0 else { return rect }
        var rows: [NSRect] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = layout.boundsRect(for: cell, glyphRange: glyphs)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            rows.append(bounds)
        }
        // A row's cells share its top: a cell crossing the rect brings in
        // every cell of its row.
        var out = rect
        for crossed in rows where crossed.intersects(rect) {
            for cell in rows where abs(cell.minY - crossed.minY) < 0.5 { out = out.union(cell) }
        }
        return out
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }
}
