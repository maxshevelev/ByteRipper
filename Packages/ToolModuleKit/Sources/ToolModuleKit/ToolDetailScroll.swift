import AppKit
import HelpBook
import HelpUI
import Localization

/// A panel's scrolling detail: a column of label/value rows that starts at the
/// top, is as wide as the visible area, and scrolls only once it outgrows it.
///
/// Both firmware tool-modules show one under their table, and the AppKit recipe
/// behind it is wrong by default in three ways that all look like "the panel is
/// broken" rather than like a layout mistake:
///
/// - A document view with no constraints tying it to the clip view has no size
///   the engine can solve for, so it logs a conflict and lands on whatever
///   number falls out.
/// - A document view is **not flipped**, so a scroll view shows the *bottom* of
///   content taller than itself: rows pinned to the visual top end up above the
///   visible area, and the panel looks empty until the user scrolls up.
/// - Content shorter than the visible area leaves the document either too tall
///   (a placeholder centred in it sits below the fold) or too short to fill the
///   box behind it.
///
/// So the whole of it lives here once: the document is flipped, pinned to the
/// clip view on three sides, at least as tall as the visible area and taller
/// only when the rows need it.
@MainActor public final class ToolDetailScroll: NSScrollView {
    /// The rows. A panel empties it and refills it on every selection.
    public let content = NSStackView()

    /// What stands in for the rows when there are none — centred in the
    /// *visible* area, because the document is exactly the visible area's
    /// height whenever the rows do not overflow it.
    public let placeholder = NSTextField(labelWithString: "")

    /// The `?` in the list's top corner: what the *row in focus* is, in a
    /// paragraph, without leaving the dump.
    ///
    /// This is the answer to the one question a firmware panel raises on every
    /// row and answers nowhere — a reader looking at `UTFL` or "Integrity 1"
    /// meets a word the panel never defines. It sits beside the node's name,
    /// which both panels put at the top of the list, because that name is what
    /// it explains.
    ///
    /// A subview of the **scroll view**, placed by frame in `tile()` — so it
    /// stays in the corner while the rows scroll under it. Three other homes
    /// were tried, and the first two fail quietly rather than loudly:
    ///
    /// - A subview of the scroll view laid out by **constraints** is never
    ///   laid out — a scroll view positions its own subviews and solves no
    ///   constraints for one of them. It sat at zero size in a corner nobody
    ///   asked for. A frame set in `tile()`, which is where the scroll view
    ///   places its own clip view and scrollers, is one it keeps.
    /// - `addFloatingSubview(_:for:)`, the documented way to keep a control
    ///   over scrolling content, draws it correctly and then leaves it out of
    ///   the accessibility tree and out of the view's own `subviews`
    ///   (measured: a walk of the running window found no such button while it
    ///   was on screen). A control VoiceOver cannot reach is not a control
    ///   (§15).
    /// - A subview of the **document** works, and scrolls away with the rows:
    ///   a reader part-way down a descriptor's straps had to scroll back up to
    ///   ask what they were reading or to open it larger.
    ///
    /// Hidden until a panel names a term, so a row the glossary has nothing to
    /// say about carries no button at all.
    private let termButton = NSButton()
    /// The entry the `?` opens. Nil while it is hidden.
    private var term: HelpTermID?

    /// The button at the very corner, beside the `?`: open the list in the
    /// large view (`ToolDetailPane`), or close it again from there. A list
    /// nobody hands an `onExpand` carries none — the ME Summary is not the
    /// detail of a row, and has no large view to open.
    private let expandButton = NSButton()
    /// The corner buttons' size, and their inset from the list's top and
    /// trailing edges — inside the scroller's column.
    private static let cornerButtonSize: CGFloat = 22
    private static let cornerInset = (top: CGFloat(4), trailing: CGFloat(16))

    /// The expand button was clicked. Nil leaves the list without one.
    public var onExpand: (() -> Void)? {
        didSet { updateExpandButton() }
    }

    /// Whether the list is the large view's rather than its panel's: the
    /// corner button then closes it rather than opening it.
    public var isExpanded = false {
        didSet { updateExpandButton() }
    }

    /// What the rows on screen describe, so a refill can tell a different
    /// subject from the same one re-read. Nil while the placeholder is up.
    private var shownSubject: String?

    /// The panel's rows are rebuilt by their own module when the zoom moves;
    /// the placeholder is this view's own text, so it re-reads the size here.
    private var zoomObserver: NSObjectProtocol?

    /// A flipped document, so the scroll view starts at the first row rather
    /// than the last.
    private final class TopDownView: NSView {
        override var isFlipped: Bool { true }
    }

    public init() {
        super.init(frame: .zero)

        hasVerticalScroller = true
        // No horizontal scroller: the rows are pinned to the visible width, so
        // there is never anything to the side to reach.
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .bezelBorder
        translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 3
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setHuggingPriority(.defaultHigh, for: .vertical)

        placeholder.font = ToolPanelFont.body()
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let document = TopDownView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        document.addSubview(placeholder)
        documentView = document

        termButton.image = NSImage(systemSymbolName: "questionmark.circle",
                                   accessibilityDescription: nil)
        termButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16,
                                                                     weight: .regular)
        termButton.isBordered = false
        termButton.imagePosition = .imageOnly
        termButton.contentTintColor = .secondaryLabelColor
        termButton.target = self
        termButton.action = #selector(termClicked)
        termButton.isHidden = true

        // help: panel.detail-quick-look
        expandButton.symbolConfiguration = termButton.symbolConfiguration
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.target = self
        expandButton.action = #selector(expandClicked)

        // Over the clip view, not in it: added after it, placed by frame in
        // `tile()`.
        for button in [termButton, expandButton] {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.autoresizingMask = []
            addSubview(button)
        }
        updateExpandButton()

        // The document is only ever as tall as it has to be: at least the
        // visible height, so the placeholder is centred in what the user can
        // see and the box behind the rows is filled, and taller than that only
        // when the rows themselves ask for it.
        let fitsTheClip = document.heightAnchor.constraint(
            equalTo: contentView.heightAnchor
        )
        fitsTheClip.priority = .defaultLow

        // The side insets break rather than fight a panel squeezed to zero
        // width, which is what a closed tool panel is. Required, the two of
        // them ask a 0-point-wide list for 20 points, and AppKit recovers by
        // striking one of them out — for good. The list then had no width to
        // follow, so a panel later dragged narrower laid its rows out for the
        // width it used to have.
        let sideInsets = [
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
        ]
        // One above `.defaultHigh`, not at it: a plain label's compression
        // resistance, and a list's label-column width, are `.defaultHigh`
        // too, and a tie between them and the margins is one the engine was
        // free to settle against the margins — which is how the ME Summary's
        // rows came to run edge to edge (measured: 0 points either side).
        sideInsets.forEach { $0.priority = .defaultHigh + 1 }

        // The placeholder's own margins, breakable for the same reason: it
        // cannot be kept 10 points clear of both edges of a list that is not
        // 20 points wide, and a required pair there is a constraint AppKit
        // strikes out to recover.
        let placeholderInsets = [
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor, constant: 10
            ),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: document.trailingAnchor, constant: -10
            ),
        ]
        placeholderInsets.forEach { $0.priority = .defaultHigh }

        // The list follows the clip view's width, down to a floor: a pane of a
        // split is laid out by frame, and its first one — before the split has
        // a size of its own — is nothing at all. A row is a name, six points
        // and a value, which does not fit in nothing however low the
        // priorities inside it are, so the engine strikes one of the row's own
        // constraints out to recover. Under the floor a scroll view does what
        // it is for and clips.
        let followsTheClip = document.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor
        )
        followsTheClip.priority = .required - 1

        NSLayoutConstraint.activate(sideInsets + [
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            followsTheClip,
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            document.heightAnchor.constraint(
                greaterThanOrEqualTo: contentView.heightAnchor
            ),
            fitsTheClip,

            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            // What never gives: the rows stay inside the list.
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: content.bottomAnchor, constant: 8
            ),

            placeholder.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: document.centerYAnchor),
        ] + placeholderInsets)

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.placeholder.font = ToolPanelFont.body()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    public override func tile() {
        super.tile()
        placeCornerButtons()
    }

    /// The buttons in the visible area's top trailing corner, level with the
    /// first row — the node's name — while the list is at its top: the
    /// expand button at the very corner, the `?` beside it, or in its place
    /// when it is hidden. Nothing pushes them, so a long name truncates
    /// under them rather than moving them.
    private func placeCornerButtons() {
        let clip = contentView.frame
        let size = Self.cornerButtonSize
        let y = isFlipped ? clip.minY + Self.cornerInset.top
                          : clip.maxY - Self.cornerInset.top - size
        var trailing = clip.maxX - Self.cornerInset.trailing
        for button in [expandButton, termButton] where !button.isHidden {
            button.frame = NSRect(x: trailing - size, y: y, width: size, height: size)
            trailing -= size + 6
        }
    }

    /// Names what the rows are about, so the `?` in the corner can explain it:
    /// the glossary entry for the selected node, or nil to take the button
    /// away.
    ///
    /// A panel calls this beside every `prepareForRows`, from the same place
    /// that decided which node is in focus — which is why the term is a value
    /// the panel hands over rather than something guessed here from the rows'
    /// labels.
    // help: panel.node-term
    public func setTerm(_ id: HelpTermID?) {
        // A term the book has no entry for is the same as none: the button
        // would open a popover with nothing in it.
        let known = id.flatMap { HelpPresenter.hasTerm($0) ? $0 : nil }
        term = known
        termButton.isHidden = known == nil
        placeCornerButtons()
        if let known, let name = HelpPresenter.book.term(known)?.name {
            ControlHelp.describe(termButton, L("What is %1$@?", name))
        }
    }

    /// What the corner `?` explains, for the tests. Nil when it carries none.
    public var shownTerm: HelpTermID? { termButton.isHidden ? nil : term }

    /// Where the `?` has landed **on screen**, in window coordinates — for the
    /// test that keeps it in the list's top trailing corner.
    ///
    /// In the window's space, not this view's, and that is the point: the
    /// document it sits in is flipped, so a frame read in either its own
    /// coordinates or this view's can say "top" about a button drawn at the
    /// bottom — which one of them did. The window's space is the one the
    /// reader is in. Nil while the view is not in a window.
    var termButtonFrameInWindow: NSRect? {
        guard window != nil, let host = termButton.superview else { return nil }
        return host.convert(termButton.frame, to: nil)
    }

    /// The `?` itself, for the test that proves it can be reached — by a click
    /// and by VoiceOver. Both were lost once, to a home that drew it correctly
    /// and exposed it to neither.
    var termButtonForTesting: NSButton { termButton }

    /// The list's own frame in the same space, so a test can compare the two.
    var frameInWindow: NSRect? {
        window == nil ? nil : convert(bounds, to: nil)
    }

    @objc private func termClicked() {
        guard let term else { return }
        HelpTermPopover.show(term, from: termButton)
    }

    @objc private func expandClicked() {
        onExpand?()
    }

    /// The corner button as the state asks: an expand glyph in the panel, a
    /// close glyph in the large view. In the panel it is there only while
    /// there are rows — a placeholder has nothing to show larger; in the
    /// large view it always is, being the way out.
    private func updateExpandButton() {
        expandButton.isHidden = onExpand == nil || (!isExpanded && !placeholder.isHidden)
        let symbol = isExpanded ? "xmark.circle" : "arrow.up.left.and.arrow.down.right.circle"
        let name = isExpanded ? L("Close") : L("Expand")
        expandButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        placeCornerButtons()
        ControlHelp.describe(expandButton, name: name, tooltip: isExpanded
            ? L("Close the large view (Space or Esc)")
            : L("Show the details in a large view (Space)"))
    }

    /// The corner's expand-or-close button, for the tests. Nil while hidden.
    public var expandButtonForTesting: NSButton? { expandButton.isHidden ? nil : expandButton }

    /// Empties the rows and shows `text` in their place.
    public func showPlaceholder(_ text: String) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.stringValue = text
        placeholder.isHidden = false
        shownSubject = nil
        updateExpandButton()
    }

    /// Whether rows are on screen rather than the placeholder.
    public var hasRows: Bool { placeholder.isHidden }

    /// Empties the rows and hides the placeholder, ready to be refilled with
    /// the rows describing `subject` — a row's index, a node's path, whatever
    /// the panel calls the thing in focus.
    ///
    /// The scroll goes back to the first row only when `subject` is not what
    /// is already on screen. A panel re-reads and re-renders for reasons that
    /// have nothing to do with the user: an edit anywhere in the dump costs a
    /// re-parse, and resetting on every refill would throw a reader back to
    /// the top of the detail they were part-way through. A *different* subject
    /// is the opposite — its first field is where the reader wants to be, not
    /// wherever the last subject had been scrolled to.
    public func prepareForRows(subject: String) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.isHidden = true
        updateExpandButton()
        guard subject != shownSubject else { return }
        shownSubject = subject
        documentView?.scroll(.zero)
    }
}
