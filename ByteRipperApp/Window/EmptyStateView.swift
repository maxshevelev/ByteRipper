import Cocoa

/// Placeholder shown in empty mode (§3.1): a large system icon that opens the
/// file picker on click, a "Drop files here" headline, the up-to-two-files
/// hint, the app's own name and version, and drag-and-drop support (§4.3 empty
/// mode).
///
/// A newer release, when there is one, is announced under the version it is
/// newer than. The view is told about it rather than looking for it: asking
/// github.com is the app's business, not a view's (`GitHubReleases`).
final class EmptyStateView: NSView {
    /// Fired with the dropped file URLs; the view controller applies §4.3 rules.
    var onOpenFiles: (([URL]) -> Void)?

    /// Asks what letting the dragged pane go on an empty window would do; the
    /// controller answers, and the view accepts only when there is an answer.
    var paneDropOutcome: ((_ draggedPaneID: UUID, _ copying: Bool) -> PaneDrop.Outcome)?

    /// Fired when a dragged pane is let go on the empty window: it moves in, and
    /// the window stops being empty.
    var onPaneDropped: ((_ draggedPaneID: UUID, _ copying: Bool) -> Void)?

    /// Fired when Option goes down or up over this window, so the drop zones
    /// raised in the *other* windows can be re-captioned. Nothing here needs
    /// telling in return: an empty window has no caption to keep in step, only a
    /// cursor, and the cursor is the operation this view returns.
    /// See `PaneDropBandsView.onCopyModifierChanged`.
    var onCopyModifierChanged: ((Bool) -> Void)?

    /// Whether the pane drag in flight is asking to copy, as last read. Held so
    /// a change can be told from a repeat.
    private var draggedPaneIsCopying = false

    /// The muted grey shared by the icon and the headline — softer than the
    /// regular secondary text, so the landing screen reads as a hint, not a
    /// primary control.
    private static let iconColor = NSColor.tertiaryLabelColor

    /// The icon is a third of the window's shorter side, capped so a huge
    /// window doesn't blow it up past this point.
    private static let maxIconSize: CGFloat = 400

    /// Fixed vertical distance (points) between the icon's visible bottom edge
    /// and the headline — constant no matter the icon size.
    private static let headlineGap: CGFloat = 48

    private let openButton = NSButton()

    /// The line announcing a newer release, under the version line. Hidden
    /// until there is a release to announce.
    private let releaseButton = LinkButton()

    /// Where that line goes when it is clicked, and what it says — held because
    /// the button's title is an attributed string and its page is not in it.
    private var releasePage: URL?
    private var releaseText = ""

    /// The bookmark list shown under the hint, and the scroll view that bounds
    /// it. Hidden while the window has no marks.
    private let bookmarkGrid = NSGridView(views: [])
    private let bookmarkScroll = NSScrollView()
    /// The list's size, sized to its rows every time the list is rebuilt. Kept
    /// so the constants can be *updated*: activating a fresh pair on each
    /// rebuild left the old ones active too, and two different fixed heights on
    /// one scroll view is a constraint conflict on every layout pass after the
    /// second bookmark.
    private var bookmarkScrollHeight: NSLayoutConstraint?
    private var bookmarkScrollWidth: NSLayoutConstraint?
    private let bookmarkHeading = NSTextField(labelWithString: "Bookmarks")
    private var bookmarkSection: NSStackView?

    /// The tallest the list gets before it scrolls. A window kept open only for
    /// its marks should show them, not become a list with a landing screen
    /// stapled to the top of it.
    private static let maxBookmarkListHeight: CGFloat = 220

    /// The gap between the version line and the hint above it, tighter than the
    /// stack's own spacing: the version belongs to the hint, it is not another
    /// thing the landing screen is saying.
    private static let versionGap: CGFloat = 6

    /// The gap between the version and the newer-release line under it. Tighter
    /// than `versionGap` because these two are one subject — both are about
    /// which build this window is.
    private static let releaseGap: CGFloat = 4

    /// The gap between the hint and the bookmarks section, wider than the
    /// stack's own spacing.
    private static let bookmarkSectionGap: CGFloat = 30

    /// The app's name and version, as the landing screen signs off with them:
    /// "ByteRipper 0.8.2". Read from the bundle rather than written here, so the
    /// number has one home — `MARKETING_VERSION` in `project.yml`.
    static var appNameAndVersion: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "ByteRipper"
        guard let version = info?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return name }
        return "\(name) \(version)"
    }

    /// The vertical stack holding the icon, headline and hint — kept so
    /// `updateIconSize()` can adjust the icon–headline gap per size.
    private var contentStack: NSStackView?

    init() {
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 4

        // The icon doubles as the Open File button — clicking it opens the
        // picker through the same responder-chain action the old button used.
        openButton.target = nil
        openButton.action = #selector(MainViewController.presentOpenPanel)
        openButton.isBordered = false
        openButton.imagePosition = .imageOnly
        // No `setButtonType`: the default momentary push-in dims the icon while
        // it is held. `.momentaryChange` would swap in `alternateImage`, which
        // this button does not have, so a press showed nothing.
        openButton.contentTintColor = Self.iconColor
        openButton.setAccessibilityLabel("Open File")  // §15

        let titleLabel = NSTextField(labelWithString: "Drop files here")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = Self.iconColor

        let hintLabel = NSTextField(labelWithString:
            "Up to two files can be compared side by side."
        )
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 13)

        // Which app this is and which build of it, under the hint: the one line
        // that answers "what am I looking at" on a window with no file open, and
        // what a bug report gets quoted from.
        let versionLabel = NSTextField(labelWithString: Self.appNameAndVersion)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center
        versionLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        // The newer-release line is a button rather than a link inside a text
        // field: a label's link is all but invisible — it is found by hovering,
        // and only after the pointer is already where the link was — while this
        // line exists to be noticed and clicked. What it opens is set by
        // `showAvailableRelease`, which no caller has called yet.
        releaseButton.bezelStyle = .inline
        releaseButton.isBordered = false
        releaseButton.target = self
        releaseButton.action = #selector(openReleasePage)
        releaseButton.isHidden = true

        // The version and the line under it, held together as one subject: the
        // gap between them is not the stack's, and the bookmark section's gap
        // below them must not move when one of the two is hidden.
        let versionBlock = NSStackView(views: [versionLabel, releaseButton])
        versionBlock.orientation = .vertical
        versionBlock.alignment = .centerX
        versionBlock.spacing = Self.releaseGap

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(openButton)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(hintLabel)
        stackView.addArrangedSubview(versionBlock)
        stackView.addArrangedSubview(makeBookmarkSection())
        stackView.setCustomSpacing(Self.versionGap, after: hintLabel)
        // More air than the stack's usual rhythm: the list is a different
        // subject from the landing screen above it, not the next line of it.
        stackView.setCustomSpacing(Self.bookmarkSectionGap, after: versionBlock)
        addSubview(stackView)
        contentStack = stackView

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Sets the icon image and the icon–headline gap (which depends on the
        // symbol's built-in padding).
        updateIconSize()

        // A pane can be dropped here too: an empty window is the most obvious
        // place to put one (`Design/PANE_DRAG_PLAN.md`).
        registerForDraggedTypes([.fileURL, .fileNames, .pane])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window size is only known once the view is in a window; rescale
        // the icon for the real window the view lands in.
        updateIconSize()
    }

    override func layout() {
        super.layout()
        // Resizing the window changes its shorter side, so the icon must scale
        // along with it.
        updateIconSize()
    }

    private var currentIconSize: CGFloat = 0

    /// Sizes the icon to a third of the window's shorter side, capped at
    /// `maxIconSize`. Falls back to a fixed 96pt when there's no window yet
    /// (e.g. in headless tests).
    /// The bookmarks section: a heading and a read-only list.
    ///
    /// It is the answer to what an empty window is *for*. The marks belong to
    /// the window rather than to a file (§20), so closing the last dump leaves a
    /// window that still holds them — and until now said nothing about it, which
    /// made it look like a window with no reason to exist.
    private func makeBookmarkSection() -> NSView {
        // In the bookmark colour, and big enough to be a heading rather than a
        // caption: it names what the list is, and the purple ties it to the
        // addresses under it and to the marks those addresses point at (§20.4).
        bookmarkHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        bookmarkHeading.textColor = HexTheme.bookmarkColor
        bookmarkHeading.alignment = .left

        bookmarkGrid.rowSpacing = 4
        bookmarkGrid.columnSpacing = 10
        bookmarkGrid.translatesAutoresizingMaskIntoConstraints = false

        bookmarkScroll.translatesAutoresizingMaskIntoConstraints = false
        bookmarkScroll.hasVerticalScroller = true
        bookmarkScroll.drawsBackground = false
        bookmarkScroll.borderType = .noBorder
        bookmarkScroll.documentView = bookmarkGrid

        let section = NSStackView()
        section.orientation = .vertical
        // Leading, not centred: the heading lines up with the left edge of the
        // addresses below it rather than floating over the middle of them. The
        // section as a whole is still centred, by the stack that holds it.
        section.alignment = .leading
        section.spacing = 8
        section.addArrangedSubview(bookmarkHeading)
        section.addArrangedSubview(bookmarkScroll)
        section.isHidden = true
        bookmarkSection = section
        return section
    }

    /// Shows the window's marks, or hides the section when there are none.
    ///
    /// Read-only on purpose: with no file open there is nowhere to go, so a row
    /// that could be clicked would promise something it cannot do.
    func setBookmarks(_ bookmarks: [Bookmark]) {
        while bookmarkGrid.numberOfRows > 0 { bookmarkGrid.removeRow(at: 0) }
        bookmarkSection?.isHidden = bookmarks.isEmpty
        guard !bookmarks.isEmpty else { return }

        bookmarkHeading.stringValue = bookmarks.count == 1
            ? "1 Bookmark Here:"
            : "\(bookmarks.count) Bookmarks Here:"
        for bookmark in bookmarks {
            let address = NSTextField(labelWithString: bookmark.row.bareAddress)
            // The dump's address shape, in the bookmark colour: the same purple
            // as the mark in the gutter and the arrow on the minimap, so the
            // three read as one thing (§20.4). Bare digits, no "0x" — a column
            // of addresses does not need each one announcing it is hex.
            address.font = AppearanceSettings.font(size: 12)
            address.textColor = HexTheme.bookmarkColor
            address.alignment = .right

            // A named mark shows its name. An unnamed one shows nothing further:
            // what the list would otherwise describe it by is the row's bytes,
            // and in a window with no file open there are none to read (§20.5).
            let name = NSTextField(labelWithString: bookmark.name)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail

            bookmarkGrid.addRow(with: [address, name])
        }
        bookmarkGrid.column(at: 0).xPlacement = .trailing
        bookmarkGrid.layoutSubtreeIfNeeded()

        let wantedHeight = min(bookmarkGrid.fittingSize.height, Self.maxBookmarkListHeight)
        let wantedWidth = max(220, bookmarkGrid.fittingSize.width)
        if let height = bookmarkScrollHeight, let width = bookmarkScrollWidth {
            height.constant = wantedHeight
            width.constant = wantedWidth
        } else {
            let height = bookmarkScroll.heightAnchor.constraint(equalToConstant: wantedHeight)
            let width = bookmarkScroll.widthAnchor.constraint(equalToConstant: wantedWidth)
            NSLayoutConstraint.activate([height, width])
            bookmarkScrollHeight = height
            bookmarkScrollWidth = width
        }
    }

    /// The heights the list's scroll view is pinned to — one, however many
    /// times the list has been rebuilt (for tests). A scroll view carries a few
    /// zero-constant heights of its own, so only the sizing ones are counted.
    var bookmarkListHeightsForTesting: [CGFloat] {
        bookmarkScroll.constraints
            .filter { $0.firstAttribute == .height && $0.firstItem === bookmarkScroll
                        && $0.constant > 0 }
            .map(\.constant)
    }

    /// What the list is showing, row by row (for tests).
    var bookmarkRowsForTesting: [(address: String, name: String)] {
        (0..<bookmarkGrid.numberOfRows).compactMap { row in
            let cells = bookmarkGrid.row(at: row)
            guard cells.numberOfCells >= 2,
                  let address = cells.cell(at: 0).contentView as? NSTextField,
                  let name = cells.cell(at: 1).contentView as? NSTextField else { return nil }
            return (address.stringValue, name.stringValue)
        }
    }

    /// The list's heading (for tests).
    var bookmarkHeadingForTesting: NSTextField? { bookmarkHeading }

    /// Whether the bookmarks section is on screen at all (for tests).
    var isShowingBookmarksForTesting: Bool { !(bookmarkSection?.isHidden ?? true) }

    /// The colour the addresses are drawn in (for tests).
    var bookmarkAddressColorForTesting: NSColor? {
        guard bookmarkGrid.numberOfRows > 0,
              let address = bookmarkGrid.row(at: 0).cell(at: 0).contentView as? NSTextField
        else { return nil }
        return address.textColor
    }

    /// Announces a newer release under the version line: one line, and one click
    /// on it opens that release's page on github.com.
    ///
    /// Nothing here asks whether there *is* one. The app asks
    /// (`ReleaseSource.newerRelease(than:)`) and calls this only when the answer
    /// is a release this build is older than — a view that went looking for
    /// releases would be a view that does IO, and the landing screen is drawn
    /// again every time the last file is closed.
    func showAvailableRelease(_ release: Release) {
        releasePage = release.page
        releaseText = "Version \(release.version.text) is available on GitHub"
        releaseButton.attributedTitle = Self.releaseLineText(releaseText)
        releaseButton.toolTip = release.page.absoluteString
        releaseButton.setAccessibilityLabel(
            "Version \(release.version.text) is available — open its page on GitHub"
        )
        releaseButton.isHidden = false
    }

    /// The line, drawn as a link: underlined, in the hint's own size, and in the
    /// system's link colour.
    ///
    /// That colour is the one thing the app draws text with that `AppPalette`
    /// does not name, and deliberately: the About panel's credits use it too,
    /// because what it means — "this opens somewhere else" — is the system's
    /// meaning rather than one of ours.
    private static func releaseLineText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    /// Opens the announced release's page, in the browser, the way the About
    /// panel's links do.
    @objc private func openReleasePage() {
        guard let releasePage else { return }
        NSWorkspace.shared.open(releasePage)
    }

    /// What the newer-release line says and where it points, or `nil` while
    /// there is no release to announce (for tests).
    var releaseLineForTesting: (text: String, page: URL?)? {
        releaseButton.isHidden ? nil : (releaseText, releasePage)
    }

    private func updateIconSize() {
        let windowSize = window?.frame.size
        let shortSide = windowSize.map { min($0.width, $0.height) } ?? 0
        let size = shortSide > 0 ? min(shortSide / 3, Self.maxIconSize) : 96
        guard size != currentIconSize else { return }
        currentIconSize = size
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .light)
        guard let image = NSImage(systemSymbolName: "plus.viewfinder", accessibilityDescription: "Open File")?
            .withSymbolConfiguration(config) else { return }
        openButton.image = image
        // SF Symbol glyphs sit inside their image with built-in padding that
        // scales with the size, so a fixed stack spacing would drift the gap
        // between the *visible* icon and the headline. Add the glyph's bottom
        // inset back so the visible gap stays `headlineGap` exactly.
        contentStack?.setCustomSpacing(Self.headlineGap + Self.visibleBottomInset(of: image), after: openButton)
    }

    /// The glyph's bottom inset (in points) inside its image. SF Symbols draw
    /// the viewfinder frame with built-in padding, so the image's bottom edge
    /// isn't the icon's visible bottom. Measured by rendering the image and
    /// scanning upward from the bottom for the first opaque pixel.
    private static func visibleBottomInset(of image: NSImage) -> CGFloat {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4, bitsPerPixel: 32) else { return 0 }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow
        // Row 0 is the top; the distance from the lowest opaque row to the
        // image's bottom edge is the glyph's bottom padding.
        for row in stride(from: height - 1, through: 0, by: -1) {
            let base = row * bytesPerRow
            for col in 0..<width where data[base + col * 4 + 3] > 0 {
                return CGFloat(height - 1 - row)
            }
        }
        return 0
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = highlighted ? 3 : 0
    }
}

// NSView already conforms to NSDraggingDestination (empty defaults); we override
// the members. Only registered destination views receive drag callbacks.
extension EmptyStateView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            return paneOperation(paneID, copying: sender.isCopyRequested)
        }
        guard !sender.draggingPasteboard.droppedFileURLs.isEmpty else { return [] }
        setDropHighlighted(true)
        return .copy
    }

    /// Re-read on every update, because Option pressed or released mid-drag
    /// arrives as one of these.
    ///
    /// Without an override of its own, AppKit answers every update with whatever
    /// `draggingEntered` returned: the cursor kept promising a move while the
    /// drop — which reads the modifier itself, when it happens — performed a
    /// copy. A window with nothing in it is exactly where that is hardest to
    /// notice, since it has no zones with captions to disagree with.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let paneID = sender.draggingPasteboard.draggedPaneID else {
            return sender.draggingPasteboard.droppedFileURLs.isEmpty ? [] : .copy
        }
        return paneOperation(paneID, copying: sender.isCopyRequested)
    }

    /// What dropping the pane here would do, as the cursor: the copy's + with
    /// Option, the move's arrow without it, and nothing at all when this window
    /// has nothing to offer (its own pane has nowhere else to be).
    private func paneOperation(_ paneID: UUID, copying: Bool) -> NSDragOperation {
        if draggedPaneIsCopying != copying {
            draggedPaneIsCopying = copying
            onCopyModifierChanged?(copying)
        }
        let outcome = paneDropOutcome?(paneID, copying) ?? .none
        guard outcome != .none else {
            setDropHighlighted(false)
            return []
        }
        setDropHighlighted(true)
        return copying ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        if let paneID = sender.draggingPasteboard.draggedPaneID {
            onPaneDropped?(paneID, sender.isCopyRequested)
            return true
        }
        let urls = sender.draggingPasteboard.droppedFileURLs
        if !urls.isEmpty {
            onOpenFiles?(urls)
        }
        return true
    }
}

/// A button that reads as a link, with the one thing a link has that text does
/// not: the pointing hand over it.
///
/// The cursor is the button's own business — a rect added by its owner would
/// have to be invalidated by its owner every time the stack above it re-laid
/// out, and a stale one shows the hand over the wrong line.
private final class LinkButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
