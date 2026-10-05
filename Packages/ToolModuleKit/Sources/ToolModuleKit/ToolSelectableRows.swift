import AppKit
import Localization

/// A place between two characters of a row: a part of it — a cell, a name or
/// a value — and a UTF-16 offset into that part's text.
public struct ToolTextMark: Comparable, Sendable {
    public var part: Int
    public var index: Int

    public init(part: Int, index: Int) {
        self.part = part
        self.index = index
    }

    public static func < (a: ToolTextMark, b: ToolTextMark) -> Bool {
        (a.part, a.index) < (b.part, b.index)
    }
}

/// A row that draws its own text and can say where in it a point falls, so
/// that `ToolSelectableRows` can select across it.
@MainActor public protocol ToolSelectableRow: NSView {
    var startMark: ToolTextMark { get }
    var endMark: ToolTextMark { get }
    /// The place nearest `point`, in the row's own coordinates.
    func mark(at point: NSPoint) -> ToolTextMark
    /// The word around `mark`, within its part.
    func word(at mark: ToolTextMark) -> Range<ToolTextMark>
    /// The text between two places, a tab between parts.
    func text(in range: Range<ToolTextMark>) -> String
    /// The part of the selection in this row, which the row draws behind its
    /// text. Nil when none of it is.
    var selectedRange: Range<ToolTextMark>? { get set }
}

/// A column of rows, **one view per row**, whose text is selected the way a
/// text view's is: a drag across parts and rows, a double click for a word, a
/// triple click for a row, ⌘A for the lot — and ⌘C copies it with a tab
/// between parts and a line per row, which a spreadsheet takes as the table it
/// was.
///
/// Selectable text fields gave that for free, a field at a time, at the price
/// of a field, a field editor's worth of machinery and its constraints per
/// cell. A row that draws its few strings is a fraction of that, and the
/// selection is the column's rather than a row's, so that it can run from one
/// row into the next. A subclass hands over its rows (`selectableRows`) and
/// places them by frame, each row taking the spacing under it, so a selection
/// through several rows is one band rather than stripes.
@MainActor open class ToolSelectableRows: NSView {
    /// A place between two characters of the column: a row, and a place in it.
    public struct Spot: Comparable {
        public var row: Int
        public var mark: ToolTextMark

        public init(row: Int, mark: ToolTextMark) {
            self.row = row
            self.mark = mark
        }

        public static func < (a: Spot, b: Spot) -> Bool { (a.row, a.mark) < (b.row, b.mark) }
    }

    /// The rows, top to bottom. A subclass returns its own.
    open var selectableRows: [any ToolSelectableRow] { [] }

    /// The selected text's ends. Nil when nothing is selected.
    public private(set) var selection: Range<Spot>?

    open override var isFlipped: Bool { true }
    open override var acceptsFirstResponder: Bool { true }

    open override func resignFirstResponder() -> Bool {
        select(nil)
        return true
    }

    /// A click on a row lands here, passed up from it: it selects from where
    /// it fell to where the drag lets go.
    open override func mouseDown(with event: NSEvent) {
        guard let window, !selectableRows.isEmpty else { return }
        window.makeFirstResponder(self)
        let start = spot(at: convert(event.locationInWindow, from: nil))
        let unit: Range<Spot>
        switch event.clickCount {
        case 1: unit = start..<start
        case 2: unit = word(at: start)
        default: unit = wholeRow(start.row)
        }
        select(unit)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              next.type == .leftMouseDragged {
            autoscroll(with: next)
            extend(unit, to: convert(next.locationInWindow, from: nil))
        }
    }

    /// The selection from `unit` — the place, word or row the click took — to
    /// the place under `point`.
    public func extend(_ unit: Range<Spot>, to point: NSPoint) {
        let end = spot(at: point)
        select(min(unit.lowerBound, end)..<max(unit.upperBound, end))
    }

    public func select(_ range: Range<Spot>?) {
        selection = range?.isEmpty == false ? range : nil
        for (index, row) in selectableRows.enumerated() { row.selectedRange = span(of: index) }
    }

    /// The place under `point`: above the rows their start, below them their
    /// end.
    public func spot(at point: NSPoint) -> Spot {
        let rows = selectableRows
        guard let first = rows.first, let last = rows.indices.last
        else { return Spot(row: 0, mark: ToolTextMark(part: 0, index: 0)) }
        guard point.y >= first.frame.minY else { return Spot(row: 0, mark: first.startMark) }
        guard let index = rows.firstIndex(where: { point.y < $0.frame.maxY })
        else { return Spot(row: last, mark: rows[last].endMark) }
        let row = rows[index]
        return Spot(row: index, mark: row.mark(at: convert(point, to: row)))
    }

    private func word(at spot: Spot) -> Range<Spot> {
        let marks = selectableRows[spot.row].word(at: spot.mark)
        return Spot(row: spot.row, mark: marks.lowerBound)..<Spot(row: spot.row, mark: marks.upperBound)
    }

    private func wholeRow(_ index: Int) -> Range<Spot> {
        let row = selectableRows[index]
        return Spot(row: index, mark: row.startMark)..<Spot(row: index, mark: row.endMark)
    }

    /// The part of the selection in one row.
    private func span(of index: Int) -> Range<ToolTextMark>? {
        guard let selection, (selection.lowerBound.row...selection.upperBound.row).contains(index)
        else { return nil }
        let row = selectableRows[index]
        let start = selection.lowerBound.row == index ? selection.lowerBound.mark : row.startMark
        let end = selection.upperBound.row == index ? selection.upperBound.mark : row.endMark
        return start < end ? start..<end : nil
    }

    /// What is selected, a tab between parts and a line per row.
    public var selectedText: String? {
        guard let selection else { return nil }
        let rows = selectableRows
        let lines = (selection.lowerBound.row...selection.upperBound.row).compactMap { index in
            span(of: index).map { rows[index].text(in: $0) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    @objc open func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    open override func selectAll(_ sender: Any?) {
        let rows = selectableRows
        guard let first = rows.first, let last = rows.last else { return }
        select(Spot(row: 0, mark: first.startMark)..<Spot(row: rows.count - 1, mark: last.endMark))
    }

    /// ⌘C and ⌘A while the rows have the focus. The Edit menu's own Copy and
    /// Select All are the dump's — they copy and select bytes — so the rows
    /// answer these keys before the menu is asked.
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c" where selection != nil: copy(nil); return true
        case "a": selectAll(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

public extension NSMenu {
    /// A context menu of one **Copy**: what the rows have selected or, with
    /// nothing selected, `fallback` — the part under the pointer. Nil when
    /// there is nothing to copy.
    @MainActor static func copyMenu(selection: String?, fallback: String?) -> NSMenu? {
        guard let text = selection ?? fallback else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("Copy"), action: #selector(ToolCopyAction.copyText(_:)), keyEquivalent: "")
        item.target = ToolCopyAction.shared
        item.representedObject = text
        menu.addItem(item)
        return menu
    }
}

/// The target of a context menu's Copy: the text it was made with, to the
/// clipboard.
@MainActor final class ToolCopyAction: NSObject {
    static let shared = ToolCopyAction()

    @objc func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
