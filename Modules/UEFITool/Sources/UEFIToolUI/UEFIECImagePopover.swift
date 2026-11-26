import AppKit
import Localization
import ToolModuleKit
import UEFITool

// help: panel.uefi.ec-image
/// What an EC image's (i) shows: the image's version as the title, its facts
/// (`UEFIECFacts`) as label and value lines, and **Open with Code** when its
/// module has a stored analysis. The shape is every information popover's
/// (`ToolPanelPopover`, `Design/DESIGN_GUIDE.md` §2.1).
@MainActor public final class UEFIECImagePopover: NSViewController, NSPopoverDelegate {
    public let titleText: String
    public let rows: [UEFIECFacts.Row]
    private let openCode: (() -> Void)?
    private let popover = NSPopover()

    init(title: String, rows: [UEFIECFacts.Row], openCode: (() -> Void)?) {
        titleText = title
        self.rows = rows
        self.openCode = openCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public var offersCode: Bool { openCode != nil }
    public var isShown: Bool { popover.isShown }
    public func close() { popover.performClose(nil) }

    func show(beside view: NSView) {
        popover.delegate = self
        ToolPanelPopover.show(popover, with: self, relativeTo: view.bounds, of: view, edge: .maxX)
    }

    public func popoverDidClose(_ notification: Notification) {
        withExtendedLifetime(self) { popover.contentViewController = nil }
    }

    override public func loadView() {
        let stack = ToolPanelPopover.stack()
        stack.addArrangedSubview(ToolPanelPopover.title(titleText))
        let text = NSMutableAttributedString()
        let size = ToolPanelPopover.proseFont.pointSize
        for (index, row) in rows.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: row.label + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: row.value, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: NSColor.textColor]))
        }
        let list = NSTextField(wrappingLabelWithString: "")
        list.attributedStringValue = text
        list.isSelectable = true
        list.preferredMaxLayoutWidth = ToolPanelPopover.inner
        stack.addArrangedSubview(list)
        if openCode != nil {
            stack.addArrangedSubview(ToolPanelPopover.action(L("Open with Code"), target: self,
                                                             action: #selector(openClicked)))
        }
        view = ToolPanelPopover.content(stack)
    }

    @objc private func openClicked() {
        close()
        openCode?()
    }
}
