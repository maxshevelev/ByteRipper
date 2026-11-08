import AppKit
import FITTool
import HelpUI
import Localization

/// The processors behind one CPUID of a microcode, where a reader of the FIT
/// panel asks for them: a popover off the `ⓘ` after the CPUID.
///
/// They are not rows of the tree, because they are not part of the update —
/// only what a published table of brand names says about who runs it. The
/// shape is every help popover's (`HelpPopoverLayout`): the CPUID as the
/// title; under it, what the table says of its group — the code names, the
/// product families, the cores, the stepping, the segments; then the models
/// with the S-SPECs they were sold under. A CPUID of several groups says each
/// over its own models instead: two groups may share a code name, and a head
/// that listed both would not say whose models are whose.
@MainActor final class FITProcessorsPopover: HelpPopoverController {
    let group: FITProcessorGroup

    init(group: FITProcessorGroup) {
        self.group = group
        super.init()
    }

    /// Shows `group` off `rect` in `anchor` — the `ⓘ` the reader clicked.
    @discardableResult
    static func show(_ group: FITProcessorGroup, from anchor: NSView, rect: NSRect? = nil) -> FITProcessorsPopover {
        let controller = FITProcessorsPopover(group: group)
        controller.present(from: anchor, rect: rect)
        return controller
    }

    override func makeContent() -> NSView {
        let body = HelpBodyView()
        body.show(Self.list(group.lines))
        let notes = group.notes.count == 1 ? group.notes[0] : ""
        let built = HelpPopoverLayout.build(title: HelpPopoverLayout.title(L("CPUID %1$@", group.cpuid)),
                                            body: body,
                                            note: notes.isEmpty ? nil : HelpPopoverLayout.note(notes))
        return built.view
    }

    /// The list: a model in the body's weight with its S-SPECs quieter after
    /// it, a group's names in the weight of a heading with its note quieter
    /// under them, and the line that says nothing is known quiet throughout.
    static func list(_ lines: [FITProcessorLine]) -> NSAttributedString {
        let size = HelpPopoverLayout.bodySize
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

    /// The `ⓘ` that opens the popover, wherever a CPUID has one: the panel's
    /// info glyph in a CPUID's weight and the colour of a link — which it is.
    /// On a selected row's accent the link's blue is lost: a table cell passes
    /// the selection's text colour as `color` there.
    static func infoImage(size: CGFloat, color: NSColor = .linkColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size.rounded(), weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("Processors"))?
            .withSymbolConfiguration(config)
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
        (view.subviews.first?.subviews.compactMap { $0 as? HelpBodyView }.first?.shownText) ?? ""
    }
}
