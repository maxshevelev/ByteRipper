import AppPalette
import Cocoa
import HelpUI
import Localization

/// The Annotations window: every note made on the files — by an agent or by
/// the person — as cards (`AgentAnnotationTools`).
///
/// The notes belong to the app, not to a window, so they are shown once, in a
/// window of their own that joins the tab bar as a tab beside the dumps. There
/// is one, made the first time it is asked for; it may stand empty, and it is
/// closed and opened again like any tab — Window ▸ Annotations and the
/// toolbar's button bring it back.
///
/// The web edition has no tabs: there the notes stay a panel of the dock,
/// made with the first note and gone with the last, folded rather than
/// closed (`Design/AGENT_PLAN.md`, "Annotations").
// help: window.notes
@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    /// The one window, once it has been asked for.
    private(set) static var shared: NotesWindowController?

    /// The one window, made now if it has not been.
    static var instance: NotesWindowController {
        if let shared { return shared }
        let made = NotesWindowController()
        shared = made
        return made
    }

    /// Closes the window and forgets it, for a test: the next one is made
    /// again, in the language and with the notes store of that test.
    static func discardForTesting() {
        shared?.window?.orderOut(nil)
        shared = nil
    }

    /// Whether the notes are in front of someone: the window on screen and
    /// the tab chosen in its tab bar. An agent's note made while they are not
    /// is counted on the toolbar's button until they are.
    static var isInView: Bool {
        guard let window = shared?.window, window.isVisible, !window.isMiniaturized else { return false }
        return window.tabGroup?.selectedWindow.map { $0 === window } ?? true
    }

    let cards = AgentAnnotationCards()
    let emptyView = NotesEmptyView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = L("Annotations")
        window.tabbingIdentifier = MainWindowController.tabbingIdentifier
        if MainViewController.isRunningTests { window.tabbingMode = .disallowed }
        // Closed, it is kept, and opening it again is showing it again.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NotesWindow")
        super.init(window: window)
        window.delegate = self
        // A toolbar as the dumps' tabs have, so the tab bar and the content
        // do not jump between the tabs; it holds nothing but the title.
        let toolbar = NSToolbar(identifier: "NotesToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        cards.build()
        cards.scroll.borderType = .noBorder
        let content = NSView()
        for view in [cards.scroll, emptyView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        window.contentView = content
        wireCards()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window: brought forward where it is, or — closed — as a tab
    /// beside `anchor`'s, the window it was asked for from.
    func show(tabbedWith anchor: NSWindow?) {
        guard let window else { return }
        if !window.isVisible, let anchor, anchor !== window, anchor.isVisible {
            anchor.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        refresh()
        noteLookedAt()
    }

    /// The notes there are now, or the empty screen when there are none.
    func refresh() {
        let all = AgentAnnotationTools.current?.all() ?? []
        cards.show(all)
        cards.scroll.isHidden = all.isEmpty
        emptyView.isHidden = !all.isEmpty
    }

    private func noteLookedAt() {
        if Self.isInView { AgentAnnotationTools.current?.markSeen() }
    }

    // MARK: - The cards

    private func wireCards() {
        cards.onShow = { [weak self] id in self?.show(id) }
        cards.onOpenSite = { [weak self] annotation in self?.show(annotation.id) }
        cards.onRemove = { ids in
            let chosen = Set(ids)
            AgentAnnotationTools.current?.remove { chosen.contains($0.id) }
        }
        // help: window.notes.edit
        cards.onEdit = { [weak self] annotation in
            NoteForm.ask(L("Edit Annotation"), L("The title and the note change; the place stays."),
                         button: L("Save"), title: annotation.title, note: annotation.note,
                         in: self?.window) { title, note in
                AgentAnnotationTools.current?.update(annotation.id, title: title, note: note)
            }
        }
        cards.isOpen = { annotation in AgentAnnotationTools.current?.place(of: annotation) != nil }
    }

    /// Goes to note `id`'s place — its file's tab brought forward, or the
    /// file opened in a new one; a file moved or deleted since is said so.
    private func show(_ id: String) {
        guard let store = AgentAnnotationTools.current,
              let note = store.all().first(where: { $0.id == id }) else { return }
        if store.place(of: note) == nil, let url = note.file.url,
           !FileManager.default.fileExists(atPath: url.path) {
            let alert = NSAlert()
            alert.messageText = L("The file is not there")
            alert.informativeText = L("“%1$@” has been moved or deleted since the annotation was made.", url.path)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        store.show(id)
    }

    // MARK: - A tab among the dumps' tabs

    /// The tab bar's + and ⌘T while this tab is chosen: a new dump tab
    /// beside it. AppKit asks along this window's chain, which ends here.
    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newWindowForTab(sender)
    }

    /// File ▸ Close (⌘W): the tab goes; the notes stay.
    @objc func closeDocument() {
        window?.performClose(nil)
    }

    /// File ▸ Close Window (⇧⌘W): every tab of the window this one is in.
    @objc func closeWindow(_ sender: Any?) {
        guard let window else { return }
        for tab in window.tabGroup?.windows ?? [window] { tab.performClose(nil) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
        noteLookedAt()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        noteLookedAt()
    }
}

/// What the Annotations window shows with no annotation in it: what goes
/// here, and how to make one.
final class NotesEmptyView: NSView {
    let title = NSTextField(labelWithString: L("No Annotations"))
    let message = NSTextField(wrappingLabelWithString: L(
        "Annotations made by hand or by a connected agent are listed here. Select bytes in a dump, or a node in UEFI Structure, right-click and choose Add Annotation…"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: NotesSymbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .light))
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.preferredMaxLayoutWidth = 360
        let help = HelpButton.standard(for: .topic(.notes))
        let stack = NSStackView(views: [icon, title, message, help])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
    }
}

/// The picture of the notes: on the toolbar's button and the empty screen.
enum NotesSymbol {
    static let name = "heart.text.square"
}

/// The round count on the Annotations button's corner.
final class NotesCountBadge: NSView {
    static let side: CGFloat = 14

    var count = 0 {
        didSet {
            setAccessibilityLabel(L("%1$@ new annotations", "\(count)"))
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var text: NSAttributedString {
        NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(Self.side, ceil(text.size().width) + 7), height: Self.side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        ZoneColors.agent.setFill()
        shape.fill()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
