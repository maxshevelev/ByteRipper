import AppPalette
import Cocoa
import HelpUI
import Localization
import ToolModuleKit
import Workspace

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

    /// Whether the window is open: on screen, or a tab behind another.
    static var isOpen: Bool {
        guard let window = shared?.window else { return false }
        return window.isVisible || (window.tabGroup?.windows.count ?? 0) > 1
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
    /// Whether the window was in view when last asked: coming into view
    /// marks the notes made meanwhile new, going out of it takes the marks off.
    private var wasInView = false
    /// The removals made here, the last last: ⌘Z puts the cards back where
    /// they stood, ⇧⌘Z removes them again. Kept while the app runs, not
    /// from one launch to the next.
    private var undoable: [AgentAnnotationTools.Removal] = []
    /// A place in a tab the window was come to from, or goes on to.
    struct Stop {
        weak var controller: MainViewController?
        let place: NavigationPlace
    }
    /// Back: the places in the tabs the window was come to from, the last
    /// last — a note made there, the tab's own Forward. Forward: the places
    /// its Back left — the tab's own Back came here from them.
    private(set) var backStops: [Stop] = []
    private(set) var forwardStops: [Stop] = []
    private var agentObserver: NSObjectProtocol?
    /// The red dot on the Agent button while an agent is at work.
    private let agentBadge = AgentActivityBadge()
    /// The zoom, so the cards re-measure and re-draw while the window is open
    /// rather than on the next open.
    private var zoomObserver: NSObjectProtocol?
    private var redoable: [AgentAnnotationTools.Removal] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = L("Annotations")
        // The tab says what it is with the notes' picture before the name;
        // the toolbar has Back and Forward where a title would be.
        window.titleVisibility = .hidden
        window.tabbingIdentifier = MainWindowController.tabbingIdentifier
        if MainViewController.isRunningTests { window.tabbingMode = .disallowed }
        // Closed, it is kept, and opening it again is showing it again.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NotesWindow")
        super.init(window: window)
        window.delegate = self
        // A toolbar as the dumps' tabs have, so the tab bar and the content
        // do not jump between the tabs. It holds what is not about a dump:
        // the help book, and the Agent button while the agent service is on,
        // where the dumps' toolbars have them, at the right.
        let toolbar = NSToolbar(identifier: "NotesToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        agentObserver = NotificationCenter.default.addObserver(
            forName: AgentService.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAgentItem() }
        }

        cards.build()
        // The cards are drawn as the tool panels' are, and follow the same
        // zoom: a change re-measures and re-draws them while the window is
        // open, not on the next open.
        zoomObserver = ToolPanelFont.observeZoom { [weak self] in self?.cards.zoomChanged() }
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

    deinit {
        if let agentObserver { NotificationCenter.default.removeObserver(agentObserver) }
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }

    /// Shows the window: brought forward where it is, or — closed — as a tab
    /// beside `anchor`'s, the window it was asked for from.
    func show(tabbedWith anchor: NSWindow?) {
        guard let window else { return }
        if !window.isVisible, let anchor, anchor !== window, anchor.isVisible {
            anchor.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        dressTab()
        noteLookedAt()
        refresh()
        syncAgentItem()
    }

    /// The Annotations window alone, closing, is the app quitting — answered
    /// as ⌘Q is, so a project or a restored session keeps it open.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate, app.keepsWindowsAtQuit,
              !app.isSwitchingProjects, app.windowControllers.isEmpty else { return true }
        NSApp.terminate(nil)
        return false
    }

    /// Puts the window back where a restored workspace had it — at its place
    /// among `tabs`, or on its own when `tabs` is empty — with the cards that
    /// were selected selected again (`Design/WORKSPACE_PLAN.md`).
    @discardableResult
    func restore(_ state: NotesState, among tabs: [NSWindow]) -> NSWindow? {
        guard let window else { return nil }
        // A tab closed on the way, its files gone, moves the place up.
        let position = min(state.position, tabs.count)
        if position > 0 {
            tabs[position - 1].addTabbedWindow(window, ordered: .above)
        } else if let first = tabs.first {
            first.addTabbedWindow(window, ordered: .below)
        }
        show(tabbedWith: nil)
        window.layoutIfNeeded()
        cards.collection.layoutSubtreeIfNeeded()
        cards.select(state.selected)
        return window
    }

    /// The tab's title with the notes' picture. Given before the window is
    /// in a tab group it is dropped when the window joins one (measured: the
    /// tab came out with the bare name), so it is given each time the window
    /// is shown or made key.
    private func dressTab() {
        guard let window, window.tab.attributedTitle?.containsAttachments != true else { return }
        window.tab.attributedTitle = Self.tabTitle()
    }

    /// The tab's title: the notes' picture, then the name.
    private static func tabTitle() -> NSAttributedString {
        let title = NSMutableAttributedString()
        if let symbol = NSImage(systemSymbolName: NotesSymbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = NSRect(x: 0, y: -2, width: symbol.size.width, height: symbol.size.height)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: L("Annotations")))
        // The tab's own size: without one the name came out larger than the
        // other tabs' (measured).
        title.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                           range: NSRange(location: 0, length: title.length))
        return title
    }

    // MARK: - Back and Forward

    /// The window comes after `place` in `controller`'s tab — a note made
    /// there, or the tab's Forward: its Back returns there.
    func cameForward(from controller: MainViewController, leaving place: NavigationPlace) {
        backStops.append(Stop(controller: controller, place: place))
        forwardStops = []
        show(tabbedWith: controller.view.window)
    }

    /// The tab's Back has come here from `place`: the window's Forward goes
    /// there again.
    func cameBack(from controller: MainViewController, leaving place: NavigationPlace) {
        forwardStops.append(Stop(controller: controller, place: place))
        show(tabbedWith: controller.view.window)
    }

    /// View ▸ Back (⌘[), and the toolbar's: to where the window was come to
    /// from.
    @objc func navigateBack() {
        guard let stop = Self.pop(&backStops) else { return }
        stop.controller?.arriveFromNotes(at: stop.place, back: true)
        window?.toolbar?.validateVisibleItems()
    }

    /// View ▸ Forward (⌘]), and the toolbar's: to where the window's Back
    /// came from.
    @objc func navigateForward() {
        guard let stop = Self.pop(&forwardStops) else { return }
        stop.controller?.arriveFromNotes(at: stop.place, back: false)
        window?.toolbar?.validateVisibleItems()
    }

    /// The last stop whose tab is still there; ones closed since are passed.
    private static func pop(_ stops: inout [Stop]) -> Stop? {
        while let stop = stops.popLast() {
            if stop.controller?.view.window != nil { return stop }
        }
        return nil
    }

    var canNavigateBack: Bool { backStops.contains { $0.controller?.view.window != nil } }
    var canNavigateForward: Bool { forwardStops.contains { $0.controller?.view.window != nil } }

    /// The Agent button there while the agent service is on, and filled
    /// while an agent is connected, with the red dot blinking on it while one
    /// is at work — as on the dumps' toolbars.
    func syncAgentItem(enabled: Bool? = nil, connected: Bool? = nil) {
        guard let toolbar = window?.toolbar else { return }
        let wanted = enabled ?? (AgentService.shared?.isEnabled == true)
        let shown = toolbar.items.firstIndex { $0.itemIdentifier == .agentWindow }
        if wanted, shown == nil, let help = toolbar.items.firstIndex(where: { $0.itemIdentifier == .help }) {
            toolbar.insertItem(withItemIdentifier: .agentWindow, at: help + 1)
            toolbar.insertItem(withItemIdentifier: .space, at: help + 1)
        } else if !wanted, let shown {
            toolbar.removeItem(at: shown)
            if shown > 0, toolbar.items[shown - 1].itemIdentifier == .space { toolbar.removeItem(at: shown - 1) }
        }
        let isConnected = connected ?? ((AgentService.shared?.connectionCount ?? 0) > 0)
        for item in toolbar.items where item.itemIdentifier == .agentWindow {
            item.image = NSImage(systemSymbolName: AgentService.symbolName(connected: isConnected),
                                 accessibilityDescription: L("Agent"))
        }
        DispatchQueue.main.async { [weak self] in
            self?.agentBadge.sync(in: self?.window, active: wanted && AgentService.shared?.isActive == true)
        }
    }

    /// The notes there are now, the newest first, or the empty screen when
    /// there are none. A note made while the window is in view is new at once.
    func refresh() {
        if Self.isInView, let fresh = AgentAnnotationTools.current?.takeFresh(), !fresh.isEmpty {
            cards.newIDs.formUnion(fresh)
        }
        let all = AgentAnnotationTools.current?.ordered() ?? []
        cards.show(all)
        cards.scroll.isHidden = all.isEmpty
        emptyView.isHidden = !all.isEmpty
    }

    /// The window has perhaps come into view, or gone out of it. Coming in,
    /// the notes made since it was last in view are marked new, and the count
    /// on the toolbar's button goes; the marks stay while the window is in
    /// view — another app in front does not take it out of view — and go when
    /// the person turns to another tab, closes the window or puts it in the Dock.
    private func noteLookedAt() {
        let inView = Self.isInView
        defer { wasInView = inView }
        guard inView else {
            if wasInView { leftView() }
            return
        }
        AgentAnnotationTools.current?.markSeen()
        guard !wasInView else { return }
        cards.newIDs = AgentAnnotationTools.current?.takeFresh() ?? []
    }

    /// Out of view: the cards are no longer new.
    private func leftView() {
        guard !cards.newIDs.isEmpty else { return }
        cards.newIDs = []
        refresh()
    }

    // MARK: - The cards

    private func wireCards() {
        cards.onShow = { [weak self] id in self?.show(id) }
        cards.onOpenSite = { [weak self] annotation in self?.show(annotation.id) }
        cards.onRemove = { [weak self] ids in
            let chosen = Set(ids)
            guard let removal = AgentAnnotationTools.current?.removal(where: { chosen.contains($0.id) }) else { return }
            self?.undoable.append(removal)
            self?.redoable = []
        }
        cards.onArrange = { ids in AgentAnnotationTools.current?.arrange(ids) }
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
        // A step out of the window: Back in that tab comes here again.
        store.place(of: note)?.controller?.recordStepFromNotes()
    }

    // MARK: - A tab among the dumps' tabs

    /// The tab bar's + and ⌘T while this tab is chosen: a new dump tab
    /// beside it. AppKit asks along this window's chain, which ends here.
    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newWindowForTab(sender)
    }

    /// Edit ▸ Select All (⌘A): every card. The menu sends the dump's own
    /// action, which selects every byte there; here it selects every note.
    @objc func selectAllBytes() {
        cards.selectAll()
        window?.makeFirstResponder(cards.collection)
    }

    /// Edit ▸ Undo (⌘Z): the last removal made here undone — the cards back
    /// where they stood, selected.
    @objc func undoEdit() {
        guard let removal = undoable.popLast(), let store = AgentAnnotationTools.current else { return }
        store.restore(removal)
        redoable.append(removal)
        cards.select(removal.ids)
    }

    /// Edit ▸ Redo (⇧⌘Z): the removal undone made again.
    @objc func redoEdit() {
        guard let undone = redoable.popLast(), let store = AgentAnnotationTools.current else { return }
        let ids = Set(undone.ids)
        if let removal = store.removal(where: { ids.contains($0.id) }) { undoable.append(removal) }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectAllBytes): return !cards.isEmpty
        case #selector(undoEdit): return !undoable.isEmpty
        case #selector(redoEdit): return !redoable.isEmpty
        case #selector(navigateBack): return canNavigateBack
        case #selector(navigateForward): return canNavigateForward
        default: return true
        }
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
        dressTab()
        noteLookedAt()
        refresh()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        noteLookedAt()
        refresh()
    }

    /// Another tab chosen, the window closed or put in the Dock: it is out of
    /// view once AppKit has done so. Another app in front is not out of view.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.noteLookedAt() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        wasInView = false
        leftView()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        wasInView = false
        leftView()
    }
}

extension NotesWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, .historyNavigation, .help, .agentWindow]
    }

    /// Back and Forward at the left, where the dumps' tabs have them; the
    /// help book and the Agent button at the right.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.historyNavigation, .flexibleSpace, .help]
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(navigateBack): return canNavigateBack
        case #selector(navigateForward): return canNavigateForward
        default: return true
        }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .historyNavigation: return MainWindowController.makeHistoryNavigationGroup(target: self)
        case .help: return MainWindowController.makeHelpItem()
        case .agentWindow: return MainWindowController.makeAgentWindowItem()
        default: return nil
        }
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
