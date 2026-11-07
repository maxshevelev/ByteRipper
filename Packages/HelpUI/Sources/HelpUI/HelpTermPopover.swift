import AppKit
import HelpBook
import Localization

/// One term, explained where it is being read: a popover off the `?` beside a
/// panel's detail list.
///
/// This is the affordance the firmware panels needed. A reader looking at a row
/// called `UTFL` has one question and wants one paragraph — not a window, not a
/// contents list, and not a trip away from the dump they were reading. So the
/// popover answers in place, and offers the window only for a reader who wants
/// the rest.
@MainActor public final class HelpTermPopover: HelpPopoverController {
    private let term: HelpTerm

    public init(term: HelpTerm) {
        self.term = term
        super.init()
    }

    /// Shows the entry for `id` off `anchor`, or does nothing when the book has
    /// no such term — a panel may name a row the glossary has not caught up
    /// with, and a popover saying "nothing here" helps nobody.
    @discardableResult
    public static func show(_ id: HelpTermID, from anchor: NSView,
                            edge: NSRectEdge = .maxY) -> HelpTermPopover? {
        guard let term = Help.shared.term(id) else { return nil }
        let controller = HelpTermPopover(term: term)
        controller.present(from: anchor, edge: edge)
        return controller
    }

    public override func makeContent() -> NSView {
        let body = HelpBodyView()
        body.show(HelpPopoverLayout.fitted(HelpText.renderBrief(term)))
        // Following a link inside a popover would be a second window inside a
        // window; the reader is sent to the real one instead, where Back works.
        body.onFollow = { [weak self] link in
            self?.close()
            HelpPresenter.show(link)
        }

        let more = NSButton(title: L("Open in Help"), target: self, action: #selector(openInHelp))
        more.bezelStyle = .rounded
        more.controlSize = .small

        return HelpPopoverLayout.build(title: HelpPopoverLayout.title(term.name),
                                       body: body, footer: more).view
    }

    @objc private func openInHelp() {
        close()
        HelpPresenter.show(.term(term.id))
    }

    /// What the popover is about, for the tests.
    public var shownTerm: HelpTermID { term.id }
}
