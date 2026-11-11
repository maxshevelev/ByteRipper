import AppKit
import FITTool
import HelpUI
import Localization
import ToolModuleKit

/// The processors behind one CPUID of a microcode, where a reader of the FIT
/// panel asks for them: a popover off the `ⓘ` after the CPUID.
///
/// They are not rows of the tree, because they are not part of the update —
/// only what a published table of brand names says about who runs it. The
/// shape is every information popover's (`ToolPanelPopover`,
/// `Design/DESIGN_GUIDE.md` §2.1): the CPUID as the title; under it, what the table says of its group — the code names, the
/// product families, the cores, the stepping, the segments; then the models
/// with the S-SPECs they were sold under. A CPUID of several groups says each
/// over its own models instead: two groups may share a code name, and a head
/// that listed both would not say whose models are whose.
@MainActor final class FITProcessorsPopover: NSViewController, NSPopoverDelegate {
    let group: FITProcessorGroup
    private let popover = NSPopover()
    private var listField: NSTextField?

    init(group: FITProcessorGroup) {
        self.group = group
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `group` off `rect` in `anchor` — the `ⓘ` the reader clicked;
    /// beside it, so the rows under it stay in sight.
    @discardableResult
    static func show(_ group: FITProcessorGroup, from anchor: NSView, rect: NSRect? = nil) -> FITProcessorsPopover {
        let controller = FITProcessorsPopover(group: group)
        controller.popover.delegate = controller
        ToolPanelPopover.show(controller.popover, with: controller,
                              relativeTo: rect ?? anchor.bounds, of: anchor, edge: .maxX)
        return controller
    }

    var isShown: Bool { popover.isShown }
    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        // The popover's hold on this controller is the last one.
        withExtendedLifetime(self) { popover.contentViewController = nil }
    }

    override func loadView() {
        let stack = ToolPanelPopover.stack()
        stack.addArrangedSubview(ToolPanelPopover.title(L("CPUID %1$@", group.cpuid)))
        // What the table says of a single group, under the CPUID.
        let notes = group.notes.count == 1 ? group.notes[0] : ""
        if !notes.isEmpty {
            let note = ToolPanelPopover.prose(notes)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        }
        let list = NSTextField(wrappingLabelWithString: "")
        list.attributedStringValue = Self.list(group.lines)
        list.isSelectable = true
        list.preferredMaxLayoutWidth = ToolPanelPopover.inner
        listField = list
        stack.addArrangedSubview(list.fittingSize.height > ToolPanelPopover.tallestProse
                                 ? ToolPanelPopover.scrolling(list, width: ToolPanelPopover.inner,
                                                              height: ToolPanelPopover.tallestProse)
                                 : list)
        view = ToolPanelPopover.content(stack)
    }

    /// The list: a model in the body's weight with its S-SPECs quieter after
    /// it, a group's names in the weight of a heading with its note quieter
    /// under them, and the line that says nothing is known quiet throughout.
    static func list(_ lines: [FITProcessorLine]) -> NSAttributedString {
        let size = ToolPanelPopover.proseFont.pointSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            let heading = line.kind == .family
            if heading, index > 0 {
                // A group after another starts a little apart from it.
                text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size / 2)]))
            }
            text.append(NSAttributedString(string: line.text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: heading ? .semibold : .regular),
                .foregroundColor: line.kind == .unknown ? NSColor.secondaryLabelColor : NSColor.textColor,
                .paragraphStyle: paragraph,
            ]))
            if heading, !line.detail.isEmpty {
                // A group's note, under its names, as the head says a single
                // group's.
                text.append(NSAttributedString(string: "\n" + line.detail, attributes: [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]))
            } else if !line.detail.isEmpty {
                text.append(NSAttributedString(string: "   " + line.detail, attributes: [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return text
    }

    /// The processors behind a catalogue entry's CPUID, where the table of
    /// brand names knows any: nil for a CPUID it does not, and for a vendor
    /// it is not about.
    static func group(for cpuid: UInt32?, vendor: MicrocodeVendor) -> FITProcessorGroup? {
        guard vendor == .intel, let cpuid,
              let group = FITProcessorGroup.groups(for: [cpuid], language: Localization.appLanguage).first,
              !group.codeNames.isEmpty
        else { return nil }
        return group
    }

    /// What the popover is showing, for the tests.
    var shownText: String {
        loadViewIfNeeded()
        return listField?.stringValue ?? ""
    }
}
