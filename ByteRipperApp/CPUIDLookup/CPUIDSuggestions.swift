import Cocoa
import IntelCPUID
import Localization
import ToolModuleKit

/// The completions under the lookup's search field: a borderless list
/// attached to the window, eight at most, each with what kind of thing it is
/// and what it belongs to.
///
/// The field keeps the keyboard: its delegate moves through the list with ↑
/// and ↓, takes the one chosen with Return and closes the list with Escape
/// (`CPUIDLookupViewController.control(_:textView:doCommandBy:)`). A click
/// takes the row clicked.
@MainActor
final class CPUIDSuggestions: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onPick: ((String) -> Void)?

    private var hints: [CPUIDLookup.Hint] = []
    private var query = ""
    private var window: NSWindow?
    private let table = NSTableView()

    var isOpen: Bool { window?.isVisible == true }

    /// The completion chosen with the arrows, if any.
    var chosen: String? {
        guard isOpen, hints.indices.contains(table.selectedRow) else { return nil }
        return hints[table.selectedRow].text
    }

    /// What is shown, for a test.
    var shownTexts: [String] { isOpen ? hints.map(\.text) : [] }

    func show(_ hints: [CPUIDLookup.Hint], under field: NSView, query: String) {
        guard !hints.isEmpty, let parent = field.window else { return close() }
        self.hints = hints
        self.query = query
        let window = self.window ?? make()
        table.reloadData()
        table.deselectAll(nil)
        let rowHeight = table.rowHeight + table.intercellSpacing.height
        let height = CGFloat(hints.count) * rowHeight + 10
        let below = field.convert(field.bounds, to: nil)
        let onScreen = parent.convertToScreen(below)
        window.setFrame(NSRect(x: onScreen.minX, y: onScreen.minY - height - 3,
                               width: onScreen.width, height: height), display: true)
        if window.parent == nil { parent.addChildWindow(window, ordered: .above) }
        window.orderFront(nil)
    }

    func close() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    func move(by step: Int) {
        guard isOpen, !hints.isEmpty else { return }
        let next = table.selectedRow < 0 ? (step > 0 ? 0 : hints.count - 1)
            : (table.selectedRow + step + hints.count + 1) % (hints.count + 1)
        // One step past either end is back to the text as typed.
        if next == hints.count {
            table.deselectAll(nil)
        } else {
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }
    }

    /// A completion's row: the tool panels' row, with room around it.
    static var rowHeight: CGFloat { ToolPanelFont.rowHeight + 4 }

    /// View ▸ Zoom moved: the rows are drawn again at the new size.
    func zoomChanged() {
        table.rowHeight = Self.rowHeight
        close()
    }

    private func make() -> NSWindow {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hint"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            table.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -4),
            table.topAnchor.constraint(equalTo: effect.topAnchor, constant: 5),
            table.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -5)
        ])
        window.contentView = effect
        self.window = window
        return window
    }

    @objc private func clicked() {
        guard hints.indices.contains(table.clickedRow) else { return }
        onPick?(hints[table.clickedRow].text)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hints.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("hintCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? CPUIDSuggestionCell
            ?? CPUIDSuggestionCell(identifier: id)
        cell.show(hints[row], query: query)
        return cell
    }

    static func kind(_ kind: CPUIDLookup.Hint.Kind) -> String {
        switch kind {
        case .cpuid: return "CPUID"
        case .sSpec: return "S-SPEC"
        case .model: return L("model")
        case .codeName: return L("code name")
        }
    }
}

/// One completion: the text, what the query found in it marked, and on the
/// right what kind of thing it is and what it belongs to.
@MainActor
final class CPUIDSuggestionCell: NSTableCellView {
    private let main = CPUIDLookupCell(identifier: NSUserInterfaceItemIdentifier("hintText"))
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        main.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for view in [main, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            main.topAnchor.constraint(equalTo: topAnchor),
            main.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: main.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            main.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor, multiplier: 0.4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ hint: CPUIDLookup.Hint, query: String) {
        main.show(hint.text, query: query, monospaced: hint.kind == .cpuid || hint.kind == .sSpec)
        detail.font = .systemFont(ofSize: ToolPanelFont.size - 1)
        detail.stringValue = CPUIDSuggestions.kind(hint.kind) + (hint.detail.isEmpty ? "" : " · " + hint.detail)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            main.backgroundStyle = backgroundStyle
            detail.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}
