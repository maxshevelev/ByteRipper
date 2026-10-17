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
/// The shape is every help popover's (`HelpPopoverLayout`), because it answers
/// the same kind of question in the same place. What is inside is the tool's
/// own words rather than the book's, under the identifier the row does not
/// show: the one name a setting is written down by everywhere else, and the
/// thing a reader with the popover open is most often after.
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
        view = makeView()
        // The zoom moving while the popover is open re-sets its words at the
        // new size, as it does the rows beside it.
        zoomObserver = HelpPopoverLayout.observeTextSize { [weak self] in
            guard let self else { return }
            self.view = self.makeView()
            self.popover.contentSize = self.view.fittingSize
        }
    }

    private var zoomObserver: NSObjectProtocol?

    deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }

    private func makeView() -> NSView {
        // The tool's words with its own line breaks kept: they are where the
        // tool put its paragraphs.
        let body = HelpBodyView()
        body.show(HelpPopoverLayout.prose(help.text))
        let built = HelpPopoverLayout.build(title: HelpPopoverLayout.title(help.identifier),
                                            body: body,
                                            note: help.note.map(HelpPopoverLayout.note))
        bodyHeight = built.bodyHeight
        return built.view
    }

    /// The height the words were given, for the tests.
    private(set) var bodyHeight: CGFloat = 0

    /// What the popover is showing, for the tests.
    var shown: FieldHelp { help }
    var isShown: Bool { popover.isShown }
    func close() { popover.performClose(nil) }
}
