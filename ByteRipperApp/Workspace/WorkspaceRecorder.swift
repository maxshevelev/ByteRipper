import ByteRipperCore
import Cocoa
import CodeAnalysis
import Localization
import Workspace

/// Keeps the workspace on disk up to date while the app runs
/// (`Design/WORKSPACE_PLAN.md`, "When it is written").
///
/// A coarse timer rather than observers: scroll, caret and selection change in
/// a hundred places, and a snapshot is a walk over a handful of tabs. The
/// folder compares the encoded bytes with what it last wrote, so a quiet
/// session writes nothing.
///
/// The session without a project is recorded only while **Reopen the
/// workspace at launch** is on; finding it off deletes the folder, so a
/// workspace from months ago never comes back. A project is recorded always:
/// it is a file the person made to keep (`Design/WORKSPACE_PLAN.md`,
/// "Projects").
///
/// A session a newer build wrote is left alone (`isSessionNewer`): this build
/// cannot read it, and writing over it would lose that build's work. Until
/// the app quits, the session without a project is then kept no more than
/// with the switch off.
@MainActor
final class WorkspaceRecorder {
    /// The session the app keeps by itself, under Application Support.
    private let folder: WorkspaceFolder
    /// The open project, when there is one: what is recorded instead.
    private(set) var project: WorkspaceFolder?
    /// Every window controller the app has, in any order.
    private let controllers: () -> [MainWindowController]
    private var timer: Timer?
    /// The windows' order front to back and the tab each showed, taken when
    /// quitting began: the quit's questions bring each window to the front in
    /// turn, and the workspace must keep the order the person left.
    private var frozenOrder: (windows: [NSWindow], selected: [NSWindow])?

    static let interval: TimeInterval = 2

    /// The untitled documents' bytes and the files' unsaved changes, beside
    /// the workspace.
    private(set) var keeper: ContentKeeper

    /// The Annotations window, if it has been made.
    private let notes: @MainActor () -> NotesWindowController?

    init(folder: WorkspaceFolder, controllers: @escaping () -> [MainWindowController],
         notes: @escaping @MainActor () -> NotesWindowController? = { NotesWindowController.shared }) {
        self.folder = folder
        self.controllers = controllers
        self.notes = notes
        let writer = KeptWriter(folder: folder)
        self.sessionWriter = writer
        self.keeper = ContentKeeper(folder: folder, writer: writer)
        if case .failure(.newer) = folder.load() { isSessionNewer = true }
    }

    /// Whether the session on disk was written by a newer build. Read once,
    /// at launch: it stays out of reach until the app quits.
    private(set) var isSessionNewer = false

    /// Whether the session without a project is being kept: the switch is
    /// on, and the session on disk is this build's to write.
    var keepsSession: Bool {
        WorkspaceSettings.restoresWorkspace && !isSessionNewer
    }

    /// The folder under Application Support, beside the annotations. Nil under
    /// test: the test host's Application Support is the user's own.
    static func defaultFolder() -> WorkspaceFolder? {
        guard !AppDefaults.isUnderTest else { return nil }
        return WorkspaceFolder(url: FavoritesFile.directory(in: FavoritesFile.applicationSupport)
            .appendingPathComponent("Workspace", isDirectory: true))
    }

    /// What the open project's bundle last held: its folder and the analyses
    /// in it. A snapshot with the same set writes nothing.
    private var bundledAnalyses: (project: URL, versions: Set<String>)?

    /// Records into `project` from now on, or — nil — into the session the
    /// app keeps by itself. The keeper starts afresh: what it knows was
    /// written is in the folder it leaves.
    func switchTo(project: WorkspaceFolder?) {
        if let old = self.project, old.url != project?.url {
            let store = try? ContentStore(root: CodeAnalysisStore.root, create: false)
            try? store?.removeRef(CodeAnalysisStore.projectRefName(for: old.url))
        }
        if self.project?.url != project?.url { bundledAnalyses = nil }
        // What the keeper being left still writes goes on in its own queue,
        // into its own folder.
        self.project = project
        keeper = project.map { ContentKeeper(folder: $0, isProject: true) }
            ?? ContentKeeper(folder: folder, writer: sessionWriter)
        removedWhileOff = false
        updateJournalDirectory()
    }

    /// Forgets the session the app keeps by itself: it was saved as a
    /// project, or discarded for one.
    func discardSession() {
        guard !isSessionNewer else { return }
        // After whatever was still being written into it.
        sessionWriter.enqueue { $0.remove() }
    }

    /// The writer of the session without a project, one for the recorder's
    /// life: the session's keepers take turns with it, so whatever one still
    /// writes is queued ahead of the next and of removing the folder.
    private let sessionWriter: KeptWriter

    /// The workspace written last, if the switch is on and there is one this
    /// build can read.
    func savedWorkspace() -> Workspace? {
        guard keepsSession else { return nil }
        return folder.read()
    }

    /// Whether this recorder tells new undo journals where to go — the app's
    /// own one does; a test's leaves them temporary.
    var providesJournalDirectory = false

    /// Points new undo journals at the `Kept/` of what is recorded now, so a
    /// document's history is written where its log will be, once
    /// (`Design/PERSISTENT_UNDO_PLAN.md`, "One journal"); at nothing — a
    /// temporary file — while nothing is.
    private func updateJournalDirectory() {
        guard providesJournalDirectory else { return }
        let directory = project?.keptFolder
            ?? (keepsSession ? folder.keptFolder : nil)
        UndoJournal.directoryProvider = { directory }
    }

    func start() {
        updateJournalDirectory()
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
    /// documents, the parts' changes and the files' unsaved changes included,
    /// at quit as at every other time: quitting does not ask about them, they
    /// come back.
    /// `final` for the snapshot that may be the last before the app or the
    /// project goes: a file kept content is laid over whose hash the
    /// background has not made yet is hashed by the writer before it writes.
    func record(final: Bool = false) {
        updateJournalDirectory()
        if let project {
            guard !isPaused else { return }
            keeper.beginSnapshot()
            let state = snapshot()
            keeper.commit(state, final: final)
            bundleAnalyses(of: state, in: project)
            return
        }
        // Neither written nor deleted: it is a newer build's.
        guard !isSessionNewer else { return }
        guard WorkspaceSettings.restoresWorkspace else {
            if !removedWhileOff { keeper.writer.enqueue { $0.remove() } }
            removedWhileOff = true
            return
        }
        removedWhileOff = false
        guard !isPaused else { return }
        keeper.beginSnapshot()
        keeper.commit(snapshot(), final: final)
    }

    /// The snapshot that may be the last — quitting, leaving a project — and
    /// `then`, once it is on disk. The main thread does not wait for it: the
    /// writer calls back. Should the writing take longer than a moment, the
    /// window in front shows a sheet meanwhile, so nothing is changed that
    /// the snapshot would not have.
    // help: workspace.final-write
    func recordFinal(then done: @escaping @MainActor () -> Void) {
        record(final: true)
        let operation = BackgroundOperation(name: L("Writing the changes kept beside it"), indeterminate: true) {}
        let presenter = (NSApp.keyWindow ?? controllers().first?.window)?.contentViewController
        let title = project != nil ? L("Writing the project") : L("Writing the workspace")
        let sheet = Task { @MainActor in
            try? await Task.sleep(for: Self.finalSheetDelay)
            guard !Task.isCancelled, operation.isActive, let presenter, presenter.view.window != nil else { return }
            BlockingOperationSheet.present(operation, title: title, from: presenter, cancellable: false)
        }
        keeper.writer.whenWritten {
            sheet.cancel()
            operation.finish()
            done()
        }
    }

    /// How long a last snapshot may take before its sheet shows.
    static var finalSheetDelay: Duration = .milliseconds(200)

    // MARK: - The project's analyses

    /// A project keeps the analyses its Code screens show: a bundle beside
    /// `Project.json`, and a reference in the store so the objects the bundle
    /// was made from are not collected. Viewing a module in the session
    /// without a project creates neither.
    private func bundleAnalyses(of workspace: Workspace, in project: WorkspaceFolder) {
        let manifests = Self.codeManifests(in: workspace)
        let keys = Set(manifests.compactMap(\.key))
        // A republished reading keeps its key and changes its artifact or
        // revision: the bundle is written again for that too, or a project
        // carried to another Mac would carry the reading it first saw.
        let versions = Set(manifests.map {
            "\($0.key?.description ?? "")/\($0.artifact.sha256.hex)/\($0.reading?.rev ?? 0)"
        })
        guard bundledAnalyses?.project != project.url || bundledAnalyses?.versions != versions else { return }
        bundledAnalyses = (project.url, versions)
        let root = CodeAnalysisStore.root
        let ref = CodeAnalysisStore.projectRefName(for: project.url)
        let bundleURL = CodeAnalysisStore.bundleURL(in: project.url)
        keeper.writer.enqueue { _ in
            guard let store = try? ContentStore(root: root, create: !keys.isEmpty) else { return }
            if keys.isEmpty {
                try? FileManager.default.removeItem(at: bundleURL)
                try? store.removeRef(ref)
            } else {
                let ordered = keys.sorted()
                try? store.setRef(ref, analyses: ordered)
                try? store.exportBundle(ordered, to: bundleURL)
            }
        }
    }

    /// Every analysis a Code screen in `workspace` names, once.
    private static func codeManifests(in workspace: Workspace) -> [AnalysisManifest] {
        let decoder = JSONDecoder()
        var seen = Set<AnalysisKey>()
        var manifests: [AnalysisManifest] = []
        for window in workspace.windows {
            for tab in window.tabs {
                for state in [tab.code] + tab.fragments.map(\.code) {
                    guard let state,
                          let data = state.manifest.data(using: .utf8),
                          let manifest = try? decoder.decode(AnalysisManifest.self, from: data),
                          let key = manifest.key,
                          seen.insert(key).inserted
                    else { continue }
                    manifests.append(manifest)
                }
            }
        }
        return manifests
    }

    /// Waits until every snapshot taken so far is on disk — for a test.
    func flush() {
        keeper.writer.flush()
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
