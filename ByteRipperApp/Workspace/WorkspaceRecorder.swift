import Cocoa
import Workspace

/// Keeps the workspace on disk up to date while the app runs
/// (`Design/WORKSPACE_PLAN.md`, "When it is written").
///
/// A coarse timer rather than observers: scroll, caret and selection change in
/// a hundred places, and a snapshot is a walk over a handful of tabs. The
/// folder compares the encoded bytes with what it last wrote, so a quiet
/// session writes nothing.
///
/// Records only while **Reopen the workspace at launch** is on; finding it off
/// deletes the folder, so a workspace from months ago never comes back.
@MainActor
final class WorkspaceRecorder {
    private let folder: WorkspaceFolder
    /// Every window controller the app has, in any order.
    private let controllers: () -> [MainWindowController]
    private var timer: Timer?
    /// The windows' order front to back and the tab each showed, taken when
    /// quitting began: the quit's questions bring each window to the front in
    /// turn, and the workspace must keep the order the person left.
    private var frozenOrder: (windows: [NSWindow], selected: [NSWindow])?

    static let interval: TimeInterval = 2

    /// The untitled documents' bytes, beside the workspace.
    let keeper: UntitledKeeper

    /// The Annotations window, if it has been made.
    private let notes: @MainActor () -> NotesWindowController?

    init(folder: WorkspaceFolder, controllers: @escaping () -> [MainWindowController],
         notes: @escaping @MainActor () -> NotesWindowController? = { NotesWindowController.shared }) {
        self.folder = folder
        self.controllers = controllers
        self.notes = notes
        self.keeper = UntitledKeeper(folder: folder)
    }

    /// The folder under Application Support, beside the annotations. Nil under
    /// test: the test host's Application Support is the user's own.
    static func defaultFolder() -> WorkspaceFolder? {
        guard !AppDefaults.isUnderTest else { return nil }
        return WorkspaceFolder(url: FavoritesFile.directory(in: FavoritesFile.applicationSupport)
            .appendingPathComponent("Workspace", isDirectory: true))
    }

    /// The workspace written last, if the switch is on and there is one.
    func savedWorkspace() -> Workspace? {
        guard WorkspaceSettings.restoresWorkspace else { return nil }
        return folder.read()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
        timer?.tolerance = Self.interval / 2
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether the folder was deleted since the switch was last seen off, so
    /// a switch left off is not a deletion every tick.
    private var removedWhileOff = false

    /// True while a restore is still putting panels back: a snapshot then
    /// would write the workspace with them missing.
    var isPaused = false

    /// Writes the workspace as it stands, if the switch is on — untitled
    /// documents and the parts' changes included, at quit as at every other
    /// time: quitting does not ask about them, they come back.
    func record() {
        guard WorkspaceSettings.restoresWorkspace else {
            if !removedWhileOff { folder.remove() }
            removedWhileOff = true
            return
        }
        removedWhileOff = false
        guard !isPaused else { return }
        keeper.beginSnapshot()
        let workspace = snapshot()
        guard (try? folder.write(workspace)) != nil else { return }
        keeper.endSnapshot()
    }

    /// Quitting has begun: keep the window order as it is now.
    func freezeOrder() {
        let windows = controllers().compactMap(\.window) + [openNotesWindow].compactMap { $0 }
        frozenOrder = (NSApp.orderedWindows.filter { windows.contains($0) },
                       windows.compactMap { $0.tabGroup?.selectedWindow ?? $0 })
    }

    /// Quitting was cancelled: the order is live again.
    func thawOrder() {
        frozenOrder = nil
    }

    /// The Annotations window while it is open — on screen, or a tab behind
    /// another in its window.
    private var openNotesWindow: NSWindow? {
        guard let window = notes()?.window else { return nil }
        if window.isVisible { return window }
        return (window.tabGroup?.windows.count ?? 0) > 1 && window.tabGroup?.windows.contains(window) == true
            ? window : nil
    }

    /// Every window, front to back, each with its tabs left to right.
    func snapshot() -> Workspace {
        let controllers = controllers()
        func controller(of window: NSWindow) -> MainWindowController? {
            controllers.first { $0.window === window }
        }
        let notesWindow = openNotesWindow
        let all = controllers.compactMap(\.window) + [notesWindow].compactMap { $0 }
        let front = frozenOrder?.windows ?? NSApp.orderedWindows.filter { all.contains($0) }
        let selected = frozenOrder?.selected
        var seen = Set<ObjectIdentifier>()
        var windows: [WindowState] = []
        // One naming for the whole snapshot: a part torn off into one tab
        // names its parent in another by it.
        let ids = WorkspacePaneIDs()
        // On-screen windows first, front to back; a tab not in front is not
        // on screen, and its group is found through the tab that is.
        for window in front + all where !seen.contains(ObjectIdentifier(window)) {
            let group = window.tabGroup?.windows ?? [window]
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            let shown = group.first { selected?.contains($0) ?? false }
                ?? window.tabGroup?.selectedWindow ?? window
            var tabs: [TabState] = []
            var selectedTab = 0
            var notesState: NotesState?
            for tabWindow in group {
                if tabWindow === notesWindow, let cards = notes()?.cards {
                    notesState = NotesState(position: tabs.count, isSelected: tabWindow === shown,
                                            selected: cards.selectedIDs)
                    continue
                }
                guard let tab = controller(of: tabWindow)?.mainViewController
                        .workspaceTab(keeper: keeper, ids: ids),
                      !tab.isEmpty else { continue }
                if tabWindow === shown { selectedTab = tabs.count }
                tabs.append(tab)
            }
            guard !tabs.isEmpty || notesState != nil else { continue }
            let frame = shown.frame
            windows.append(WindowState(
                frame: Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                tabs: tabs, selectedTab: selectedTab, notes: notesState))
        }
        return Workspace(windows: windows)
    }
}
