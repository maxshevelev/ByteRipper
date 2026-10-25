import Cocoa
import Localization
import Workspace

/// Puts the tabs of a workspace back, all of them together
/// (`Design/WORKSPACE_PLAN.md`, "Restoring").
///
/// Two passes, because a part can be taken out of a pane in another tab or
/// another window — a part torn off into a tab of its own is still a part of
/// the file it came from. First every tab opens its files and untitled
/// documents; then the parts — panels and torn-off tabs alike — are taken out
/// of their parents, each once its parent is open, until none is left that
/// can be. A tab is laid out once all of its own panes are in.
@MainActor final class WorkspaceRestorer {
    private let keeper: ContentKeeper?

    /// Every pane opened so far, by the id it was written down with.
    private var panes: [String: RestoredPane] = [:]
    private(set) var issues: [RestoreIssue] = []
    /// Files opened in the first pass whose kept content waits on a check.
    private var keptFiles: [(check: KeptFileCheck, tab: Tab, slot: Int)] = []

    private final class Tab {
        let controller: MainViewController
        let state: TabState
        var opened: [Int: RestoredPane] = [:]
        /// The tab's own slots still waiting for a parent.
        var pendingSlots: [Int] = []
        /// Its untitled documents, opened once their kept content is read
        /// back off the main thread — before any part, which may come out of
        /// one of them.
        var untitledSlots: [Int] = []
        /// Its panels still waiting, by index into `state.fragments`.
        var pendingFragments: [Int] = []
        var fragments: [Int: RestoredPane] = [:]
        var isLaidOut = false

        init(controller: MainViewController, state: TabState) {
            self.controller = controller
            self.state = state
        }
    }

    private var tabs: [Tab] = []

    init(keeper: ContentKeeper?) {
        self.keeper = keeper
    }

    /// The first pass, for one tab: its files and untitled documents.
    func openFiles(of state: TabState, in controller: MainViewController) {
        let tab = Tab(controller: controller, state: state)
        for (slot, saved) in state.panes.prefix(2).enumerated() {
            guard let saved else { continue }
            if case .part = saved.document {
                tab.pendingSlots.append(slot)
                continue
            }
            if case .untitled = saved.document, keeper != nil {
                tab.untitledSlots.append(slot)
                continue
            }
            let pane = controller.workspaceSlot(slot)
            var checks: [KeptFileCheck] = []
            guard let unchanged = controller.openWorkspaceDocument(saved, in: pane, keeper: keeper,
                                                                    issues: &issues, keptFiles: &checks)
            else { continue }
            register(saved, RestoredPane(pane: pane, unchanged: unchanged), in: tab, slot: slot)
            keptFiles += checks.map { (check: $0, tab: tab, slot: slot) }
        }
        tab.pendingFragments = Array(state.fragments.indices)
        tabs.append(tab)
    }

    /// Whether a tab has anything to show yet or may get it in the second
    /// pass — for the caller deciding whether to keep its window.
    func mayShowAnything(_ controller: MainViewController) -> Bool {
        guard let tab = tabs.first(where: { $0.controller === controller }) else { return false }
        return !tab.opened.isEmpty || !tab.pendingSlots.isEmpty || !tab.untitledSlots.isEmpty
    }

    /// The second pass: the parts, parents first, and each tab laid out as
    /// soon as its own panes are in. What is still waiting when nothing more
    /// can be opened had a parent that did not come back.
    func openParts() async {
        await settleKeptContent()
        var progress = true
        while progress {
            progress = false
            for tab in tabs where !tab.isLaidOut && tab.pendingSlots.isEmpty {
                await layOut(tab)
                progress = true
            }
            for tab in tabs {
                for slot in tab.pendingSlots {
                    guard let saved = tab.state.panes[slot], case let .part(origin) = saved.document,
                          let parent = panes[origin.parent] else { continue }
                    tab.pendingSlots.removeAll { $0 == slot }
                    progress = true
                    let pane = tab.controller.workspaceSlot(slot)
                    guard let opened = await tab.controller.openWorkspacePart(origin, from: parent, into: pane,
                                                                              keeper: keeper)
                            ?? tab.controller.openWorkspaceOrphan(origin, into: pane, keeper: keeper) else {
                        issues.append(notOpened(origin))
                        continue
                    }
                    if opened.keptChangesLost { issues.append(.unreadable(name: origin.name)) }
                    register(saved, opened, in: tab, slot: slot)
                }
                // A panel opens over a tab that is laid out.
                guard tab.isLaidOut else { continue }
                for index in tab.pendingFragments {
                    let saved = tab.state.fragments[index]
                    switch saved.pane.document {
                    case let .part(origin):
                        guard let parent = panes[origin.parent] else { continue }
                        tab.pendingFragments.removeAll { $0 == index }
                        progress = true
                        guard let opened = await tab.controller.openWorkspacePart(origin, from: parent, into: nil,
                                                                                  keeper: keeper)
                                ?? tab.controller.openWorkspaceOrphan(origin, into: nil, keeper: keeper)
                        else {
                            issues.append(notOpened(origin))
                            continue
                        }
                        if opened.keptChangesLost { issues.append(.unreadable(name: origin.name)) }
                        await openedFragment(saved, opened, index: index, in: tab)
                    case let .untitled(stamp):
                        tab.pendingFragments.removeAll { $0 == index }
                        progress = true
                        guard let opened = tab.controller.openWorkspaceLooseFragment(stamp, keeper: keeper) else {
                            issues.append(.unreadable(name: stamp.name ?? L("Untitled")))
                            continue
                        }
                        await openedFragment(saved, opened, index: index, in: tab)
                    case .file:
                        tab.pendingFragments.removeAll { $0 == index }
                    }
                }
            }
        }
        // Whatever still waits has no parent to come out of: its parent's
        // file is gone or changed, or its parent was itself left out.
        // A part that held changes of its own still comes back with them, as
        // untitled bytes.
        for tab in tabs {
            for slot in tab.pendingSlots {
                guard let saved = tab.state.panes[slot], case let .part(origin) = saved.document else { continue }
                if let opened = tab.controller.openWorkspaceOrphan(
                    origin, into: tab.controller.workspaceSlot(slot), keeper: keeper) {
                    register(saved, opened, in: tab, slot: slot)
                } else {
                    issues.append(notOpened(origin))
                }
            }
            tab.pendingSlots = []
            if !tab.isLaidOut { await layOut(tab) }
            for index in tab.pendingFragments {
                let saved = tab.state.fragments[index]
                guard case let .part(origin) = saved.pane.document else { continue }
                if let opened = tab.controller.openWorkspaceOrphan(origin, into: nil, keeper: keeper) {
                    await openedFragment(saved, opened, index: index, in: tab)
                } else {
                    issues.append(notOpened(origin))
                }
            }
            tab.pendingFragments = []
            let front = tab.state.expandedFragment.flatMap { tab.fragments[$0]?.pane }
            tab.controller.settleWorkspaceFragments(expanded: front)
        }
        issues += (keeper?.takeHistoriesLost() ?? []).map { .historyLost(name: $0) }
        keeper?.forgetReadBacks()
    }

    /// Why a part did not open: its kept changes could not be read, or there
    /// was nothing to open it from.
    private func notOpened(_ origin: PartOrigin) -> RestoreIssue {
        origin.edits != nil ? .unreadable(name: origin.name) : .missing(path: origin.name)
    }

    /// Lays the kept content over the files the first pass opened, each once
    /// it is known to be the file the content was made on — all of them
    /// checked at once, off the main thread. One that is not opens as it is on
    /// disk, as a file changed since does; one whose kept content cannot be
    /// read opens as it is on disk too, and the warning says which.
    private func settleKeptContent() async {
        let checks = keptFiles
        keptFiles = []
        guard let keeper else { return }
        // Every content kept in the workspace, with the name a person knows it by.
        var contents: [(content: KeptContent, name: String, controller: MainViewController)] = []
        for (check, tab, _) in checks { contents.append((check.kept, check.url.lastPathComponent, tab.controller)) }
        for tab in tabs {
            func add(_ state: PaneState) {
                switch state.document {
                case let .untitled(stamp): contents.append((stamp.content, stamp.name ?? L("Untitled"), tab.controller))
                case let .part(origin):
                    if let edits = origin.edits { contents.append((edits.content, origin.name, tab.controller)) }
                case .file: break
                }
            }
            tab.state.panes.compactMap { $0 }.forEach(add)
            tab.state.fragments.map(\.pane).forEach(add)
        }
        let reading = contents.reduce(0) { $0 + keeper.bytesToRead($1.content) }
        let hashing = checks.filter { $0.check.readsTheFile }.reduce(0) { $0 + $1.check.stamp.size }
        let progress = CheckProgress(controllers: contents.map(\.controller) + checks.map(\.tab.controller),
                                     total: reading + hashing, threshold: Self.progressThreshold)
        defer { progress.finish() }
        let report = progress.reporter()

        // Read back, off the main thread: logs by their chained hash, bases by
        // theirs, a document's whole content rebuilt.
        let names = Dictionary(contents.map { ($0.content.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        await keeper.readBack(contents.map(\.content), progress: report.map { report in
            { id, count in report(L("Reading the changes kept for “%1$@”", names[id] ?? ""), count) }
        })

        // The untitled documents, before any part: a part may come out of one.
        for tab in tabs {
            for slot in tab.untitledSlots {
                guard let saved = tab.state.panes[slot] else { continue }
                var none: [KeptFileCheck] = []
                guard let unchanged = tab.controller.openWorkspaceDocument(
                    saved, in: tab.controller.workspaceSlot(slot), keeper: keeper, issues: &issues, keptFiles: &none)
                else { continue }
                register(saved, RestoredPane(pane: tab.controller.workspaceSlot(slot), unchanged: unchanged),
                         in: tab, slot: slot)
            }
            tab.untitledSlots = []
        }

        // The files kept changes are laid over, each checked to be the file
        // they were made on.
        let same = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, entry) in checks.enumerated() {
                let check = entry.check
                let name = L("Checking “%1$@”", check.url.lastPathComponent)
                let fileReport: (@Sendable (Int) -> Void)? = report.map { report in { report(name, $0) } }
                group.addTask { (index, await check.isTheSameFile(progress: fileReport)) }
            }
            var same = [Bool](repeating: false, count: checks.count)
            for await (index, result) in group { same[index] = result }
            return same
        }
        for (index, (check, tab, slot)) in checks.enumerated() {
            if same[index] {
                do {
                    try keeper.apply(check.kept, to: check.pane, name: check.url.path)
                } catch {
                    issues.append(.unreadable(name: check.url.path))
                }
            } else {
                issues.append(.changed(path: check.url.path))
            }
            tab.opened[slot]?.unchanged = same[index]
            if let id = check.id { panes[id]?.unchanged = same[index] }
        }
    }

    /// How many bytes — kept content to read back, files to check — before
    /// the windows show how far it has got; below it the work is over before a
    /// sheet would be.
    static var progressThreshold: UInt64 = 256 << 20

    /// The tabs in which nothing at all could be opened.
    var emptyTabs: [MainViewController] {
        tabs.filter { $0.opened.isEmpty && $0.fragments.isEmpty }.map(\.controller)
    }

    private func register(_ saved: PaneState, _ opened: RestoredPane, in tab: Tab, slot: Int) {
        tab.opened[slot] = opened
        if let id = saved.id { panes[id] = opened }
    }

    private func openedFragment(_ saved: FragmentState, _ opened: RestoredPane,
                                index: Int, in tab: Tab) async {
        tab.fragments[index] = opened
        if let id = saved.pane.id { panes[id] = opened }
        await tab.controller.finishWorkspaceFragment(saved, opened: opened)
    }

    /// Lays a tab out around its own panes. A pane alone is File A, whichever
    /// slot it was written from.
    private func layOut(_ tab: Tab) async {
        tab.isLaidOut = true
        let model = tab.controller.windowModel
        if !model.pane1.isOpen, model.pane2.isOpen {
            model.swapPanes()
        }
        await tab.controller.finishWorkspaceTab(tab.state, opened: tab.opened)
    }
}

/// How far reading back the kept content and checking the files it is laid
/// over has got, shown on each window concerned — a sheet, so nothing is
/// edited there before the content is in (`Design/PERSISTENT_UNDO_PLAN.md`,
/// "Integrity"). Only when there is enough to read for it to matter.
@MainActor private final class CheckProgress {
    private var operations: [BackgroundOperation] = []
    private let total: UInt64
    private let counter = Counter()

    /// Bytes read so far, from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var read: UInt64 = 0
        func add(_ count: Int) -> UInt64 { lock.withLock { read += UInt64(count); return read } }
    }

    // help: workspace.restore-check
    init(controllers: [MainViewController], total: UInt64, threshold: UInt64) {
        self.total = total
        guard total >= threshold, total > 0 else { return }
        var seen = Set<ObjectIdentifier>()
        for controller in controllers where seen.insert(ObjectIdentifier(controller)).inserted {
            guard controller.view.window != nil else { continue }
            let operation = BackgroundOperation(name: L("Getting ready")) {}
            BlockingOperationSheet.present(operation, title: L("Checking the files changes are kept for"),
                                           from: controller, cancellable: false)
            operations.append(operation)
        }
    }

    /// What the work reports through: what it is doing now, and the bytes it
    /// read. Nil when nothing is shown.
    func reporter() -> (@Sendable (String, Int) -> Void)? {
        guard !operations.isEmpty else { return nil }
        let operations = operations, counter = counter, total = Double(total)
        return { name, count in
            let read = counter.add(count)
            for operation in operations {
                operation.rename(name)
                operation.report(Double(read) / total)
            }
        }
    }

    func finish() {
        for operation in operations { operation.finish() }
    }
}
