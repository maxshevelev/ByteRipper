import Cocoa

/// The tool-module panel's chrome: a header naming the tool-module and the file
/// it is working on, a close button, and the tool-module's own view below
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// The header exists to answer one question the panel would otherwise leave
/// open — *which* file this is. A session is bound to the pane it was opened
/// for and does not follow the active pane, so in a comparison the panel and
/// the pane the user is typing in can be different files, and what the header
/// names is where the tool-module's writes go.
///
/// The panel hosts a view controller it does not own: the tool-module builds
/// it, this holds it, and swapping tool-modules swaps the view.
final class ToolPanelView: NSView {
    /// Fired by the header's ✕. The same thing as Tools ▸ None.
    var onClose: (() -> Void)?

    /// Files were dropped on the panel: the same thing as dropping them on the
    /// pane's Replace Current File band, for the pane this panel is reading.
    var onDropFiles: (([URL]) -> Void)?
    /// A pane was dropped on the panel: the tool moves to it.
    var onDropPane: ((UUID) -> Void)?
    /// What dropping the pane with this id would do, for the caption — nil for
    /// a pane the panel will not take, which is its own.
    var paneDropTitle: ((UUID) -> String?)?

    /// A pane was chosen in the header's selector: the tool moves to it. Index
    /// 0 or 1, the same numbering `MainViewController` uses for panes.
    ///
    /// The same thing a pane dropped on the panel does, through the same door,
    /// so the two ways of moving a tool-module onto another file cannot grow
    /// apart. `boundIndex` is what the panel is reading *now*, so the callback
    /// can ignore a selection of the pane already chosen.
    var onSelectPane: ((Int) -> Void)?

    private let header = NSView()
    /// The same wrench the toolbar's Tools button carries, so the panel and the
    /// button that opened it read as one thing.
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// The file selector: a dropdown naming the file the tool-module is
    /// reading, which opens the panes it may be moved onto.
    ///
    /// A popup rather than a label because the header's question — *which* file
    /// is this tool reading — has an answer that can be changed from here, and a
    /// name the user can see is the natural place to offer that. It is the pane
    /// the tool is *bound to*, not the active pane, that a choice moves it to,
    /// and the name it shows is that same pane's — the two are one answer.
    ///
    /// Changing the active pane is not a way of changing this one: the tool
    /// goes on reading the file it was opened for, so the header goes on naming
    /// it. Dropping a pane on the panel and choosing one here are the only two
    /// gestures that move it.
    private let fileSelector = NSPopUpButton()
    private let closeButton = NSButton()
    private let bottomSeparator = NSView()
    private let trailingSeparator = NSView()
    /// Where the tool-module's view goes.
    private let body = NSView()
    /// The drop zone, over the body and only for the length of a drag. The
    /// tool-module's own view keeps the mouse the rest of the time.
    private let dropZone = DropTargetView(title: SingleFileDropTarget.replace.title)
    /// The pane in flight, while one is.
    private var draggedPaneID: UUID?
    /// What the selector's menu currently offers, in pane order — kept so a
    /// choice can be read back to the index it stands for.
    private var paneChoices: [PaneChoice] = []

    /// What the selector's menu is built from: one entry per pane, in pane
    /// order. `isBound` puts the tick on the pane the tool is reading;
    /// `isEnabled` is false for a pane that is not open — a closed pane is not
    /// somewhere a tool can be moved to, and the entry says so rather than
    /// disappearing, so the list is always the same length in the same order.
    struct PaneChoice: Equatable {
        var fileName: String
        var isBound: Bool
        var isEnabled: Bool
    }

    /// The chrome's height, matching the pane's title bar so the panel's body
    /// starts level with the dump beside it.
    static let headerHeight: CGFloat = 28

    /// The smallest box a tool-module's view is ever laid out in, whatever the
    /// panel's own size — see the floor in `init`. Well under the narrowest
    /// panel a user can drag (`ToolController.minPanelWidth`), so it never
    /// fights a real width; well over the outer margins a module's own layout
    /// asks for, so those are always satisfiable.
    static let bodyFloor: CGFloat = 120

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        // A hidden panel is a zero-width pane, not a hidden view — the same
        // rule the minimap panel follows (§19.1) — and an `NSView` does not
        // clip its subviews, so without this the header's labels would paint
        // over the dump beside the panel while the panel itself is nothing but
        // a sliver.
        wantsLayer = true
        layer?.masksToBounds = true

        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true

        iconView.image = NSImage(
            systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileSelector.bezelStyle = .inline
        // Borderless-ish, like the ✕ beside it: the header is 28 points tall
        // and a full-size popup would set the height of the bar rather than sit
        // in it.
        fileSelector.isBordered = false
        fileSelector.font = .systemFont(ofSize: 11)
        fileSelector.lineBreakMode = .byTruncatingMiddle
        fileSelector.target = self
        fileSelector.action = #selector(paneSelected)
        // The file name is what gives way first when the panel is narrow: the
        // tool-module's name is the shorter of the two and the one that says
        // what the panel is.
        fileSelector.translatesAutoresizingMaskIntoConstraints = false
        // Both halves of the sizing contract, and the second is the one that
        // matters. A popup measures itself by the title of the *selected* item,
        // which `setPanes` fills with the bound pane's file name — a long name
        // there made the control ask for 188 points, where its
        // own two-line menu needs 63. Resistance alone only says "do not squeeze
        // me below this"; it is hugging that says "do not *grow* me to this",
        // and without it the popup insists on the width of the longest name the
        // header can ever show, against a chain of five equally breakable links
        // — which is what AppKit logged as a pile of conflicts on every open.
        fileSelector.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        fileSelector.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close the tool panel"
        closeButton.setAccessibilityLabel("Close the tool panel")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        for separator in [bottomSeparator, trailingSeparator] {
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.wantsLayer = true
        }
        applyChromeColors()

        body.translatesAutoresizingMaskIntoConstraints = false

        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.isHidden = true

        addSubview(header)
        addSubview(body)
        addSubview(dropZone)
        addSubview(trailingSeparator)

        // A file dropped here replaces the file the panel is reading; a pane
        // dropped here moves the tool onto it. Both are things the panel is
        // *about*, which is why they are offered on the panel rather than only
        // over the dump.
        registerForDraggedTypes([.fileURL, .fileNames, .pane])
        header.addSubview(iconView)
        header.addSubview(titleLabel)
        header.addSubview(fileSelector)
        header.addSubview(closeButton)
        header.addSubview(bottomSeparator)

        // The side insets break rather than fight a panel squeezed to zero
        // width, for the reason the minimap panel's do (§19.2): a collapsed
        // panel is a legal state and must not log a constraint conflict every
        // time it is reached.
        //
        // They are breakable *by different amounts*, and that is the point of
        // the four priorities below. Five links at one priority are five links
        // AppKit has no reason to prefer when a narrow panel cannot hold them
        // all: it logs the conflict and then breaks whichever it reached last,
        // so the header gave up its pieces in an order nobody chose. Ranked, the
        // squeeze has an answer written down — the rule the panel follows is
        // "the ✕ stays put, the name shortens first, then the module's title,
        // and the icon's own inset goes last".
        let leading = iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8)
        leading.priority = .defaultHigh - 3
        let afterIcon = titleLabel.leadingAnchor.constraint(
            equalTo: iconView.trailingAnchor, constant: 5
        )
        afterIcon.priority = .defaultHigh - 2
        let gap = fileSelector.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6)
        gap.priority = .defaultHigh - 1
        let trailing = closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6)
        trailing.priority = .defaultHigh
        let toClose = fileSelector.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                                             constant: -6)
        toClose.priority = .defaultHigh - 1

        // The drop zone's insets break for the same reason, and it is not a
        // nicety: a collapsed panel is 8 + 8 + the trailing rule narrower than
        // nothing, so required insets make the zero-width state unsatisfiable
        // — and what AppKit picks to break to recover is one of the panel's
        // *own* pins. It broke the rule's, and the body it is measured from
        // then kept whatever width it last had, so a panel dragged narrower
        // laid its tool-module out for the old width.
        let zoneLeading = dropZone.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        zoneLeading.priority = .defaultHigh
        let zoneTrailing = dropZone.trailingAnchor.constraint(
            equalTo: trailingSeparator.leadingAnchor, constant: -8
        )
        zoneTrailing.priority = .defaultHigh
        // The same on the other axis: a collapsed panel is no taller than the
        // header it does not draw either.
        let zoneTop = dropZone.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8)
        zoneTop.priority = .defaultHigh
        let zoneBottom = dropZone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        zoneBottom.priority = .defaultHigh

        // And the body's own edge against the rule, for the same reason: a
        // zero-width panel cannot hold a 1-point rule *and* a body beside it.
        let bodyTrailing = body.trailingAnchor.constraint(
            equalTo: trailingSeparator.leadingAnchor
        )
        bodyTrailing.priority = .required - 1

        // The body follows the panel exactly, and clips: what it holds is a
        // tool-module's whole layout, and that layout is never asked to solve
        // itself in a box of nothing (see `setContent`).
        body.clipsToBounds = true
        clipsToBounds = true

        // The header's height gives way to a panel with no height at all,
        // which is what one is before its first layout: 28 points of header
        // plus a body below it do not fit in none, and what AppKit strikes out
        // to recover is whichever of the panel's pins it likes.
        let headerHeight = header.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        headerHeight.priority = .required - 1
        let bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor)
        bodyBottom.priority = .required - 1

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            header.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            leading, afterIcon, gap, trailing, toClose,
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            fileSelector.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            bottomSeparator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),

            // The panel's own edge against the dump. The split view draws a
            // divider there too, but it is a drag target rather than a rule.
            trailingSeparator.topAnchor.constraint(equalTo: topAnchor),
            trailingSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingSeparator.widthAnchor.constraint(equalToConstant: 1),

            zoneTop, zoneBottom, zoneLeading, zoneTrailing,
            dropZone.trailingAnchor.constraint(lessThanOrEqualTo: trailingSeparator.leadingAnchor),

            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyTrailing,
            body.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bodyBottom,
            body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    /// The header is chrome and not document, and it says so with the same fill
    /// the panes' headers use — a translucent system fill made to sit over
    /// content, at the tertiary weight (`PaneHeaderView`). It used to be
    /// `underPageBackgroundColor`, which is a page's *surround* and reads as a
    /// dark bar beside a light dump.
    ///
    /// The bottom rule is the panes' rule, because the two headers are the same
    /// height on either side of the window and a line that stops and restarts
    /// in a different colour is a line that has been noticed.
    private func applyChromeColors() {
        header.layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        bottomSeparator.layer?.backgroundColor = PaneHeaderView.headerRuleColor().cgColor
        trailingSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    /// A layer colour is resolved once, when it is assigned, and these are
    /// assigned before the panel is in a window — so a later switch to dark
    /// mode would leave the header light. Re-resolved here, where the effective
    /// appearance is authoritative (§3.2), exactly as the panes' header does.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applyChromeColors()
        }
    }

    // MARK: - Dropping on the panel

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            draggedPaneID = paneID
            guard let title = paneDropTitle?(paneID) else {
                // Its own pane. The zone still appears, wearing the refusal —
                // an area that stays blank says nothing about why nothing will
                // happen (§4.3).
                show(dropZone: true, refused: true)
                return []
            }
            dropZone.setTitle(title)
            show(dropZone: true, refused: false)
            return .move
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        dropZone.setTitle(SingleFileDropTarget.replace.title)
        show(dropZone: true, refused: false)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let paneID = draggedPaneID {
            return paneDropTitle?(paneID) == nil ? [] : .move
        }
        return sender.draggingPasteboard.droppedFileURLs.isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrag()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrag()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            let accepted = paneDropTitle?(paneID) != nil
            endDrag()
            guard accepted else { return false }
            onDropPane?(paneID)
            return true
        }
        let urls = sender.draggingPasteboard.droppedFileURLs
        endDrag()
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func show(dropZone shown: Bool, refused: Bool) {
        dropZone.isHidden = !shown
        dropZone.setHighlighted(shown && !refused)
        if refused { dropZone.setRefused() }
    }

    private func endDrag() {
        draggedPaneID = nil
        show(dropZone: false, refused: false)
    }

    /// What the drop zone is saying, for tests. Nil while it is not shown.
    var dropZoneCaption: String? {
        dropZone.isHidden ? nil : dropZone.titleForTesting
    }

    /// Whether the zone is refusing what is being carried, for tests.
    var dropZoneIsRefusing: Bool {
        !dropZone.isHidden && dropZone.isShowingRefusal
    }

    @objc private func closeClicked() {
        onClose?()
    }

    /// The tool-module's half of the header. The file half is the selector, and
    /// it is filled by `setPanes`, which is told about the panes — nothing here
    /// is, so nothing here can name a file.
    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    /// Fills the selector: one entry per pane, in pane order, naming its own
    /// file, with a tick — and so the header — on the one the tool-module is
    /// reading.
    ///
    /// There is one answer to show, not two. The header's question is *which
    /// file this panel is working on*, and that is the file the session is
    /// bound to: the pane the user has clicked into since is somewhere else
    /// entirely, and naming it would say the tool had gone there — which it has
    /// not, and which nothing but a drop or a choice here can make it do.
    ///
    /// `NSPopUpButton` writes the tick itself, from whichever item is selected,
    /// and undoes a `state` set on any item — so the tick is the selection, and
    /// the entry it lands on carries both the tick and the name the header
    /// draws while the menu is shut.
    ///
    /// A pane that is closed keeps its entry and is disabled rather than
    /// vanishing, so the list is the same length in the same order whatever is
    /// open, and the entry at a given position is always the same pane.
    func setPanes(_ choices: [PaneChoice]) {
        paneChoices = choices
        // Which entry the tick and the visible name both land on. With nothing
        // bound there is no tick — the first entry is simply where the popup's
        // selection has to sit, since it insists on drawing some title.
        let bound = choices.firstIndex(where: { $0.isBound }) ?? 0
        // The menu is rebuilt wholesale: `NSMenu` has no cheap "change the
        // ticks" and the list is two entries long.
        let menu = NSMenu()
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.fileName, action: #selector(paneSelected),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = choice.isEnabled
            menu.addItem(item)
        }
        fileSelector.menu = menu
        // The selected item's title is what the closed popup draws, and it is
        // its own pane's name either way — the header and the menu offer the
        // same list, with the tick saying which of them the tool is on.
        fileSelector.selectItem(at: bound)
        fileSelector.isEnabled = !choices.isEmpty
    }

    @objc private func paneSelected(_ sender: NSMenuItem) {
        // The tag is the pane's own index: every entry in the menu is a pane,
        // in pane order.
        let index = sender.tag
        guard paneChoices.indices.contains(index) else { return }
        // The pane the tool already reads is not somewhere to move it to, and
        // choosing it would restart a parse for a file that has not changed.
        guard !paneChoices[index].isBound else { return }
        onSelectPane?(index)
    }

    /// Whether the selector offers a choice at all. False with one file open,
    /// where there is nowhere to move the tool and an enabled dropdown would be
    /// a control that does nothing — the ✕ beside it stays live either way.
    func setSelectorEnabled(_ isEnabled: Bool) {
        fileSelector.isEnabled = isEnabled
    }

    /// The tool-module's view, or nil to empty the panel. The panel constrains
    /// it to fill the body; the tool-module decides everything inside it.
    func setContent(_ view: NSView?) {
        for existing in body.subviews { existing.removeFromSuperview() }
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)

        // The module fills the body — but never below the floor, whatever the
        // panel's own size is. A closed panel is zero points wide with a
        // tool-module still inside it, and a module's layout is full of
        // required insets: 8 points either side of a box, 10 either side of a
        // list. Required margins inside a box of nothing are constraints
        // AppKit *strikes out* to recover, permanently — and the module's
        // insides then stopped following the panel's width at all, so a panel
        // dragged narrower laid its rows out for the width it used to have.
        //
        // Under the floor the body simply clips: there is nothing to read in a
        // panel that narrow anyway, and every module's own layout stays
        // solvable at every size the panel can take.
        let fills = [
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ]
        // Just under required: these must outrank the ordinary content
        // priorities inside the module (a label's own 750, say), or the solver
        // treats a tie as licence to land the module somewhere between the
        // panel's width and its content's — which is neither.
        fills.forEach { $0.priority = .required - 1 }
        NSLayoutConstraint.activate(fills + [
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.bodyFloor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.bodyFloor),
        ])
    }

    /// What the panel is showing, for the tests that ask.
    var contentView: NSView? { body.subviews.first }
    /// The header's fill and its icon, for the test that keeps the header from
    /// going back to being a dark bar with nothing on it.
    var headerFill: CGColor? { header.layer?.backgroundColor }
    var headerIcon: NSImage? { iconView.image }
    var title: String { titleLabel.stringValue }
    /// What the header is *showing* about the file: the name in the selector's
    /// closed state, which is the file the tool-module is reading.
    var fileName: String { fileSelector.titleOfSelectedItem ?? "" }
    /// The selector's pane entries, for the tests that check what it offers.
    /// Each names its own pane, so the pane an entry stands for is both its
    /// position and its title.
    var paneTitles: [String] { fileSelector.itemArray.map(\.title) }
    /// The index of the pane the tool-module is bound to, read the way the popup
    /// itself keeps it — the selection. nil when there is no session.
    var tickedPaneIndex: Int? {
        guard paneChoices.contains(where: { $0.isBound }) else { return nil }
        return fileSelector.indexOfSelectedItem
    }
    /// The selector itself, for the tests that drive a choice the way a user
    /// does — by picking an item.
    var paneSelector: NSPopUpButton { fileSelector }

}
