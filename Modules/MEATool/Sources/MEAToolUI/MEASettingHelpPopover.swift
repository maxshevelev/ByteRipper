import AppKit
import HelpUI
import ToolModuleKit

// help: (none — the Configuration tab is an experiment, and the page that
// explains it is not written yet; this `?` and the anchor for it go in when it
// is, `Packages/MEPresentation/Sources/MEPresentation/MEAConfigurationText.swift`
// carrying the note for the tab's own words)

/// What Flash Image Tool says about one setting, where a reader of the
/// Configuration tab asks for it: a popover off the `?` beside the setting's
/// name.
///
/// The shape is the help popover's beside a panel's detail list — the same
/// fixed box, the same title over the same scrolling body view — because it
/// answers the same kind of question in the same place, and a second shape for
/// it would read as a different kind of thing. What is inside is the tool's own
/// words rather than the book's, under the identifier the row does not show:
/// the one name a setting is written down by everywhere else, and the thing a
/// reader with the popover open is most often after.
@MainActor final class MEASettingHelpPopover: NSViewController {
    private let help: FieldHelp
    private let popover = NSPopover()

    init(help: FieldHelp) {
        self.help = help
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `help` off `anchor` — the button the reader pressed.
    @discardableResult
    static func show(_ help: FieldHelp, from anchor: NSView) -> MEASettingHelpPopover {
        let controller = MEASettingHelpPopover(help: help)
        controller.popover.contentViewController = controller
        controller.popover.behavior = .transient
        controller.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        return controller
    }

    override func loadView() {
        let root = NSView()

        // The identifier, in the place and the weight the help popover gives a
        // term's name: it is what the popover is about.
        let title = NSTextField(labelWithString: help.identifier)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = HelpBodyView()
        body.show(Self.prose(help.text))

        for subview in [title, body] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // The fixed box the term popover uses: a popover that is a
            // different shape for every setting reads as a glitch, and a long
            // one scrolls inside it.
            root.widthAnchor.constraint(equalToConstant: 340),
            body.heightAnchor.constraint(equalToConstant: 220)
        ])
        view = root
    }

    /// The tool's words as the book's prose is drawn — the same reading size,
    /// its own line breaks kept, because they are where the tool put its
    /// paragraphs.
    static func prose(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: HelpText.Size.body),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ])
    }

    /// What the popover is showing, for the tests.
    var shown: FieldHelp { help }
    var isShown: Bool { popover.isShown }
    func close() { popover.performClose(nil) }
}
