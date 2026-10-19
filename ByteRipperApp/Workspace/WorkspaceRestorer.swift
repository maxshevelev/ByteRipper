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
    private let keeper: UntitledKeeper?

    /// Every pane opened so far, by the id it was written down with.
    private var panes: [String: RestoredPane] = [:]
    private(set) var issues: [RestoreIssue] = []

    private final class Tab {
        let controller: MainViewController
        let state: TabState
        var opened: [Int: RestoredPane] = [:]
        /// The tab's own slots still waiting for a parent.
        var pendingSlots: [Int] = []
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

    init(keeper: UntitledKeeper?) {
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
            let pane = controller.workspaceSlot(slot)
            guard let unchanged = controller.openWorkspaceDocument(saved, in: pane, keeper: keeper,
                                                                    issues: &issues) else { continue }
            register(saved, RestoredPane(pane: pane, unchanged: unchanged), in: tab, slot: slot)
        }
        tab.pendingFragments = Array(state.fragments.indices)
        tabs.append(tab)
    }

    /// Whether a tab has anything to show yet or may get it in the second
    /// pass — for the caller deciding whether to keep its window.
    func mayShowAnything(_ controller: MainViewController) -> Bool {
        guard let tab = tabs.first(where: { $0.controller === controller }) else { return false }
        return !tab.opened.isEmpty || !tab.pendingSlots.isEmpty
    }

    /// The second pass: the parts, parents first, and each tab laid out as
    /// soon as its own panes are in. What is still waiting when nothing more
    /// can be opened had a parent that did not come back.
    func openParts() async {
        var progress = true
        while progress {
            progress = false
            for tab in tabs where !tab.isLaidOut && tab.pendingSlots.isEmpty {
                layOut(tab)
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
                        issues.append(.missing(path: origin.name))
                        continue
                    }
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
                            issues.append(.missing(path: origin.name))
                            continue
                        }
                        openedFragment(saved, opened, index: index, in: tab)
                    case let .untitled(stamp):
                        tab.pendingFragments.removeAll { $0 == index }
                        progress = true
                        guard let opened = tab.controller.openWorkspaceLooseFragment(stamp, keeper: keeper) else {
                            issues.append(.missing(path: stamp.name ?? L("Untitled")))
                            continue
                        }
                        openedFragment(saved, opened, index: index, in: tab)
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
                    issues.append(.missing(path: origin.name))
                }
            }
            tab.pendingSlots = []
            if !tab.isLaidOut { layOut(tab) }
            for index in tab.pendingFragments {
                let saved = tab.state.fragments[index]
                guard case let .part(origin) = saved.pane.document else { continue }
                if let opened = tab.controller.openWorkspaceOrphan(origin, into: nil, keeper: keeper) {
                    openedFragment(saved, opened, index: index, in: tab)
                } else {
                    issues.append(.missing(path: origin.name))
                }
            }
            tab.pendingFragments = []
            let front = tab.state.expandedFragment.flatMap { tab.fragments[$0]?.pane }
            tab.controller.settleWorkspaceFragments(expanded: front)
        }
    }

    /// The tabs in which nothing at all could be opened.
    var emptyTabs: [MainViewController] {
        tabs.filter { $0.opened.isEmpty && $0.fragments.isEmpty }.map(\.controller)
    }

    private func register(_ saved: PaneState, _ opened: RestoredPane, in tab: Tab, slot: Int) {
        tab.opened[slot] = opened
        if let id = saved.id { panes[id] = opened }
    }

    private func openedFragment(_ saved: FragmentState, _ opened: RestoredPane, index: Int, in tab: Tab) {
        tab.fragments[index] = opened
        if let id = saved.pane.id { panes[id] = opened }
        tab.controller.finishWorkspaceFragment(saved, opened: opened)
    }

    /// Lays a tab out around its own panes. A pane alone is File A, whichever
    /// slot it was written from.
    private func layOut(_ tab: Tab) {
        tab.isLaidOut = true
        let model = tab.controller.windowModel
        if !model.pane1.isOpen, model.pane2.isOpen {
            model.swapPanes()
        }
        tab.controller.finishWorkspaceTab(tab.state, opened: tab.opened)
    }
}
