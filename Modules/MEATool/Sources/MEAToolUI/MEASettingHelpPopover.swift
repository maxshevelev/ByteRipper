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
/// Flat: the title and the words on the popover's own background, both from
/// the same left edge. What is inside is the tool's own words rather than the
/// book's, under the identifier the row does not show: the one name a setting
/// is written down by everywhere else, and the thing a reader with the popover
/// open is most often after.
///
/// The popover is as tall as its words, up to `maxBodyHeight`; a longer text
/// scrolls inside that. A fixed box left most settings — a line or two — with
/// an empty half under them.
@MainActor final class MEASettingHelpPopover: NSViewController {
    private let help: FieldHelp
    private let popover = NSPopover()

    /// The popover's width, and the margin its title and words keep from its
    /// edges.
    static let width: CGFloat = 340
    static let margin: CGFloat = 14
    /// The tallest the words get before they scroll: about twenty lines.
    static let maxBodyHeight: CGFloat = 320

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

        // The identifier, in the weight the help popover gives a term's name:
        // it is what the popover is about.
        let title = NSTextField(labelWithString: help.identifier)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .left
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        // The words on the popover's background, not on a page of their own:
        // a white page under a material title is two surfaces where one is
        // meant.
        let body = HelpBodyView()
        body.drawsBackground = false
        body.textInset = NSSize(width: Self.margin, height: 0)
        body.show(Self.prose(help.text))
        let height = min(body.contentHeight(width: Self.width), Self.maxBodyHeight)

        for subview in [title, body] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.margin),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            root.widthAnchor.constraint(equalToConstant: Self.width),
            body.heightAnchor.constraint(equalToConstant: height)
        ])
        view = root
        bodyHeight = height
    }

    /// The height the words were given, for the tests.
    private(set) var bodyHeight: CGFloat = 0

    /// The tool's words as the book's prose is drawn — the same reading size,
    /// its own line breaks kept, because they are where the tool put its
    /// paragraphs.
    static func prose(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.alignment = .left
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
