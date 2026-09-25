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
@MainActor public final class HelpTermPopover: NSViewController {
    private let term: HelpTerm
    private let popover = NSPopover()

    public init(term: HelpTerm) {
        self.term = term
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    public override func loadView() {
        let root = NSView()

        let name = NSTextField(labelWithString: term.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let body = HelpBodyView()
        body.show(HelpText.renderBrief(term))
        // Following a link inside a popover would be a second window inside a
        // window; the reader is sent to the real one instead, where Back works.
        body.onFollow = { [weak self] link in
            self?.popover.performClose(nil)
            HelpPresenter.show(link)
        }

        let more = NSButton(title: L("Open in Help"), target: self, action: #selector(openInHelp))
        more.bezelStyle = .rounded
        more.controlSize = .small
        more.translatesAutoresizingMaskIntoConstraints = false

        for subview in [name, body, more] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            name.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            body.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            more.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 4),
            more.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            more.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            // A fixed box rather than one sized to the entry: a popover that is
            // a different shape for every term reads as a glitch, and a long
            // entry scrolls inside it.
            root.widthAnchor.constraint(equalToConstant: 340),
            body.heightAnchor.constraint(equalToConstant: 220)
        ])
        view = root
    }

    private func present(from anchor: NSView, edge: NSRectEdge) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    @objc private func openInHelp() {
        popover.performClose(nil)
        HelpPresenter.show(.term(term.id))
    }

    /// What the popover is about, for the tests.
    public var shownTerm: HelpTermID { term.id }
    public var isShown: Bool { popover.isShown }
    public func close() { popover.performClose(nil) }
}
