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

// The listing's table, rows and cells, the dump's bar and the header's
// small views of the Code panel.


/// The ASM listing: the arrow keys move the selected instruction as a
/// table's do, and Page Up, Page Down, Home and End move it too — a page, or
/// to the first or the last — as they move the C's current line.
final class CodeListingTableView: NSTableView {
    private func select(_ row: Int) {
        guard numberOfRows > 0 else { return }
        let row = min(max(row, 0), numberOfRows - 1)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
    }

    private var rowsPerPage: Int {
        max(1, Int((enclosingScrollView?.contentView.bounds.height ?? visibleRect.height) / max(rowHeight, 1)) - 1)
    }

    override func pageUp(_ sender: Any?) { select(max(selectedRow, 0) - rowsPerPage) }
    override func pageDown(_ sender: Any?) { select(max(selectedRow, 0) + rowsPerPage) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func moveToBeginningOfDocument(_ sender: Any?) { select(0) }
    override func moveToEndOfDocument(_ sender: Any?) { select(numberOfRows - 1) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { select(0) }
    override func scrollToEndOfDocument(_ sender: Any?) { select(numberOfRows - 1) }

    override func keyDown(with event: NSEvent) {
        // A table pages and goes home by scrolling alone; the listing moves
        // its selected instruction, as the C moves its current line.
        switch event.specialKey {
        case .pageUp?: pageUp(nil)
        case .pageDown?: pageDown(nil)
        case .home?: select(0)
        case .end?: select(numberOfRows - 1)
        default: super.keyDown(with: event)
        }
    }
}

/// A row of the ASM listing. The selected instruction wears the C's
/// current-line colour, not the accent: it is where the reader is, and its
/// tokens keep their colours on it.
final class CodeListingRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("code-listing-row")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        CodeColors.currentLine.setFill()
        bounds.fill()
    }
}


/// The bar under the code, on the divider above the module's bytes. Its
/// empty part is a handle of that divider, as Xcode's debug bar is: a drag
/// there moves the divider, and pulls the bytes up when they are hidden.
/// Its buttons and menus keep their own clicks, and only the rest shows the
/// resize cursor.
final class CodeDumpBar: NSView {
    weak var split: ALSplitView?
    var dividerIndex = 0

    override func mouseDown(with event: NSEvent) {
        guard let split else { return super.mouseDown(with: event) }
        split.beginDividerDrag(at: dividerIndex, with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let split else { return super.mouseDragged(with: event) }
        split.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let split else { return super.mouseUp(with: event) }
        split.mouseUp(with: event)
    }

    /// The bar less what takes a click of its own: the resize cursor where
    /// a drag starts. Words and the progress bar pass the click on.
    var handleRects: [NSRect] {
        let taken = subviews
            .filter { !$0.isHidden && !($0 is NSTextField) && !($0 is NSProgressIndicator) }
            .map { $0.frame.insetBy(dx: -2, dy: 0) }
            .sorted { $0.minX < $1.minX }
        var rects: [NSRect] = []
        var x = bounds.minX
        for frame in taken {
            if frame.minX > x { rects.append(NSRect(x: x, y: bounds.minY, width: frame.minX - x, height: bounds.height)) }
            x = max(x, frame.maxX)
        }
        if x < bounds.maxX { rects.append(NSRect(x: x, y: bounds.minY, width: bounds.maxX - x, height: bounds.height)) }
        return rects
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard split != nil else { return }
        for rect in handleRects { addCursorRect(rect, cursor: .resizeUpDown) }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}


/// The listing's row: a table cell around one clickable line of code.
final class CodeLineCell: NSTableCellView {
    let line = CodeLineView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}


/// The header's function name: selectable, so it can be copied, with the
/// function's own right-click menu in place of the text field's — also while
/// it is selected, when the field editor is what the click lands on.
/// An image that stands in a line of text by its middle: the line aligns by
/// baseline, and an image's own baseline is its bottom edge, which would put
/// it above the words. Its middle sits at the middle of the capitals of
/// `lineFont`.
final class CodeBaselineImageView: NSImageView {
    var lineFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize) {
        didSet { invalidateIntrinsicContentSize() }
    }

    private var height: CGFloat { image?.size.height ?? 0 }

    override var firstBaselineOffsetFromTop: CGFloat { height / 2 + lineFont.capHeight / 2 }
    override var lastBaselineOffsetFromBottom: CGFloat { height / 2 - lineFont.capHeight / 2 }
    override var baselineOffsetFromBottom: CGFloat { lastBaselineOffsetFromBottom }
}

final class CodeTitleField: NSTextField {
    var onMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?() ?? super.menu(for: event)
    }

    /// The field editor's menu, while the name is selected: the function's,
    /// with Copy first, so the selection can still be copied.
    @objc func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let own = onMenu?() else { return menu }
        if textView.selectedRange().length > 0 {
            own.insertItem(.separator(), at: 0)
            let copy = NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = textView
            own.insertItem(copy, at: 0)
        }
        return own
    }
}
