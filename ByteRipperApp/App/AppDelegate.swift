import Cocoa
import HelpBook
import HelpUI
import Localization
import ToolModuleKit
import Workspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Every open comparison window, in the order they were made. The app owns
    /// its windows rather than being one window's owner: ⇧⌘N adds one, closing
    /// one drops it, and a file handed to the app has to be routed to one of
    /// them rather than to "the" window.
    private(set) var windowControllers: [MainWindowController] = []

    /// Drops a window from `windowControllers` when it closes, so a closed
    /// window is neither kept alive nor offered a file to open.
    private var closeObserver: NSObjectProtocol?
    /// URLs handed to us by Launch Services before the window existed. An
    /// "Open with" / double-click launch can deliver `application(_:open:)`
    /// before `applicationDidFinishLaunching` finishes building the window, so
    /// they queue here and drain once it is up.
    private var pendingOpenURLs: [URL] = []
    /// Node links that came before the first window: opened once it is up.
    private var pendingNodeLinks: [(file: URL, node: String?)] = []
    private var isReady = false
    private var switchingProjects = false
    /// Observes theme changes so a Settings change re-themes the running app
    /// without a relaunch (§3.2).
    private var themeObserver: NSObjectProtocol?
    #if DEBUG
    private var themeToggleMonitor: Any?
    #endif

    /// Keeps the workspace on disk while the app runs, and hands back the one
    /// written last (`Design/WORKSPACE_PLAN.md`). Nil under test, where the
    /// Application Support folder is the user's own.
    lazy var workspaceRecorder: WorkspaceRecorder? = WorkspaceRecorder.defaultFolder().map { folder in
        WorkspaceRecorder(folder: folder, controllers: { [weak self] in self?.windowControllers ?? [] })
    }

    /// The Settings window, owned by the app rather than by a window: there is
    /// one of it however many windows are open. Lazy, so it is not built until
    /// ⌘, is pressed.
    private lazy var settingsWindowController = SettingsWindowController()

    /// Which window has which file open (§4.1 rule 6). The application's, not a
    /// window's: the rule is that a file is open once in the app, and only
    /// something above the windows can answer that.
    private lazy var openDocuments = OpenDocumentRegistry()

    /// The File menu's Open Recent submenu refreshes its rows from
    /// `RecentFilesStore` before each display; the bar belongs to the app, so
    /// the app owns what fills it. Lazy, the way the Settings window is: the
    /// delegate is wired on while the menu bar is built, but building it costs
    /// nothing and this keeps it next to the windows it serves.
    private lazy var openRecentMenuController = OpenRecentMenuController()
    private lazy var openRecentProjectMenuController = OpenRecentProjectMenuController()

    /// The agent service (`Design/AGENT_PLAN.md`): the socket an agent's
    /// client reaches the app on. The application's, like the windows it reads:
    /// an agent works across every tab, and goes on working whichever one is
    /// in front.
    private(set) lazy var agentService = AgentService(
        desk: AgentDesk(
            controllers: { [weak self] in self?.tabsFrontmostFirst() ?? [] },
            keyController: { [weak self] in self?.tabsFrontmostFirst().first }),
        defaults: AppDefaults.store)

    /// Every tab's controller, the one in front first — the order an agent is
    /// told about them in. A tab that is not the selected one of its window is
    /// not on screen and so not in `orderedWindows`; it follows the rest.
    private func tabsFrontmostFirst() -> [MainViewController] {
        let onScreen = NSApp.orderedWindows.compactMap { window in
            windowControllers.first { $0.window === window }?.mainViewController
        }
        let rest = windowControllers.map(\.mainViewController).filter { controller in
            !onScreen.contains { $0 === controller }
        }
        return onScreen + rest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The panels read their zoom from a package, which cannot see the app
        // and so cannot know that a test run reads a suite of its own
        // (`AppDefaults`). Before anything draws, tell it.
        ToolPanelFont.defaults = AppDefaults.store
        // Every document's undo history keeps to the bounds the settings name,
        // read at each edit; the package cannot see the app's defaults.
        EditingSettings.applyUndoLimits()
        // Which language the app speaks, before anything says a word in it:
        // the menu bar below is built from translated strings, and so is every
        // window after it (`Design/LOCALIZATION.md`).
        AppDefaults.startLocalization()
        AppDefaults.isolateFindPasteboard()
        // Tabs are windows. Turning this on is what gives the app the system's
        // tab bar, ⌘T through `newWindowForTab(_:)`, ⌃Tab and ⌘1…⌘9, dragging a
        // tab out into its own window and dragging one back in, and the Window
        // menu's Show Tab Bar / Move Tab to New Window / Merge All Windows —
        // none of which then has to be built or maintained here.
        NSWindow.allowsAutomaticWindowTabbing = true
        // Apply the stored theme before any window appears, so the first frame
        // is already in the right appearance (§3.2).
        applyTheme()
        // The recent-files list keeps its own copy of "what is on disk" and
        // would otherwise keep a deleted file's row for ever — prune it once,
        // at launch, before the menu is first built from it.
        RecentFilesStore.pruneMissing()
        // The pattern library reads itself and, when it is published to a
        // shared file, merges what is there and starts watching it (§11). At
        // launch rather than on first use: a Mac that has not opened the Find
        // bar is still a Mac whose library should be current.
        //
        // Never under XCTest. The test host *is* this app, reaching the same
        // folders the user's copy does, so starting the library there merges
        // and republishes the developer's own — into their own synced
        // folder, from a process that is about to swap the store's defaults
        // out from under it. A suite must not touch the library it is not
        // testing.
        if !MainViewController.isRunningTests {
            FavoritePatternStore.start()
            // The agent socket opens only if the person switched it on, and
            // never in the test host: a suite has no business taking the
            // socket a running copy of the app is serving its agent on.
            AgentService.shared = agentService
            // The annotations of the last run, kept on this Mac; the test
            // host keeps none, as it keeps no library.
            agentService.annotationTools.keep(in: AnnotationsFile.url)
            agentService.apply()
            agentStatusItem = AgentStatusItem(
                service: agentService,
                showWindow: { [weak self] in self?.showAgentWindow(nil) },
                showSettings: { [weak self] in self?.showAgentSettings(nil) })
        }
        // The menu bar belongs to the application, not to a window: it is built
        // once, here, and its commands travel the responder chain to whichever
        // window is key.
        let mainMenu = MainMenu.build(appTarget: self)
        NSApp.mainMenu = mainMenu
        // The File menu's Open Recent submenu is built empty (its rows depend
        // on what has been opened, which the build cannot know); hand it the
        // delegate that rebuilds the rows before each display.
        if let fileMenu = mainMenu.items.compactMap(\.submenu).first(where: { $0.title == L("File", context: "menu") }) {
            fileMenu.items.first { $0.title == L("Open Recent") }?.submenu?.delegate = openRecentMenuController
            fileMenu.items.first { $0.title == L("Open Recent Project") }?.submenu?.delegate =
                openRecentProjectMenuController
        }
        // Handing AppKit the Window submenu is what puts the open windows in it,
        // with Bring All to Front above them — worth having the moment there is
        // more than one window, and the place the system also hangs its own tab
        // commands.
        NSApp.windowsMenu = mainMenu.items.compactMap(\.submenu).first { $0.title == L("Window", context: "menu") }
        #if DEBUG
        installThemeToggle()
        #endif
        themeObserver = NotificationCenter.default.addObserver(
            forName: AppTheme.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` is the guarantee: the block is delivered on the
            // main queue, so it is already on the main actor — the same
            // assumption the close observer below makes, and for the same
            // reason. The closure itself is nonisolated, which is why saying so
            // is necessary.
            MainActor.assumeIsolated {
                self?.applyTheme()
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                guard let self, self.windowControllers.contains(where: { $0.window === window }) else { return }
                self.windowControllers.removeAll { $0.window === window }
                // A closed tab leaves the workspace now, not at the next tick:
                // closing the last window quits, and the quit records what is
                // left — nothing.
                self.workspaceRecorder?.record()
            }
        }
        // A project handed to the launch is the session; otherwise the one
        // open when the app last stood, when the workspace is to be restored;
        // otherwise the session the app kept by itself.
        let launchProject = pendingOpenURLs.first(where: \.isByteRipperProject)
            ?? (WorkspaceSettings.restoresWorkspace ? RecentProjectsStore.lastProject : nil)
        pendingOpenURLs.removeAll(where: \.isByteRipperProject)
        let restored: Bool
        if let launchProject, workspaceRecorder != nil {
            openProject(at: launchProject)
            restored = !windowControllers.isEmpty
        } else {
            restored = restoreWorkspace()
        }
        if !restored {
            makeWindow()
        }
        workspaceRecorder?.start()
        NSApp.activate(ignoringOtherApps: true)
        // The window is up; drain any files Launch Services handed us first.
        isReady = true
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            if restored {
                openFilesBesideWorkspace(urls)
            } else {
                openFiles(urls)
            }
        }
        if !pendingNodeLinks.isEmpty {
            let links = pendingNodeLinks
            pendingNodeLinks.removeAll()
            openNodeLinks(links)
        }
    }

    /// Rebuilds the windows and tabs of the workspace written last, if the
    /// switch is on and there is one (`Design/WORKSPACE_PLAN.md`, "Restoring").
    /// Returns false when nothing was opened, and the launch makes its one
    /// empty window as it always has.
    private func restoreWorkspace() -> Bool {
        guard let recorder = workspaceRecorder, let workspace = recorder.savedWorkspace(),
              !workspace.isEmpty else { return false }
        return rebuild(workspace, with: recorder)
    }

    /// Builds the windows of `workspace` — the session's at launch, or a
    /// project's — with `recorder` paused until every part is back. Returns
    /// false when nothing was opened.
    @discardableResult
    func rebuild(_ workspace: Workspace, with recorder: WorkspaceRecorder) -> Bool {
        // Nothing is written while the workspace is being rebuilt: a window
        // closed on the way, or a snapshot between the two passes, would
        // otherwise write a workspace of what had been rebuilt so far.
        recorder.isPaused = true
        let restorer = WorkspaceRestorer(keeper: recorder.keeper)
        var windows: [(saved: WindowState, group: [MainWindowController], selected: MainWindowController?)] = []
        // Back to front, so the window made last — the front one — is key.
        for saved in workspace.windows.reversed() {
            var group: [MainWindowController] = []
            var selected: MainWindowController?
            let frame = NSRect(x: saved.frame.x, y: saved.frame.y,
                               width: saved.frame.width, height: saved.frame.height)
            for (index, tab) in saved.tabs.enumerated() {
                let controller = makeWindow(tabbedWith: group.first?.window)
                // Where it was from the start, so it does not appear at a
                // cascaded place and jump; set again once its tabs are in.
                if group.isEmpty, let window = controller.window {
                    window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
                }
                restorer.openFiles(of: tab, in: controller.mainViewController)
                // A tab with nothing to show, and no part still to come into
                // it, is not kept as an empty window; the warning says what
                // it held.
                guard restorer.mayShowAnything(controller.mainViewController) else {
                    controller.window?.close()
                    continue
                }
                group.append(controller)
                if index == saved.selectedTab { selected = controller }
            }
            windows.append((saved, group, selected))
        }
        restoringParts = Task { @MainActor [weak self] in
            // The parts, parents first, wherever in the workspace each parent
            // is: the windows are on screen meanwhile.
            await restorer.openParts()
            for controller in restorer.emptyTabs {
                controller.view.window?.close()
            }
            for (saved, group, selected) in windows {
                let open = group.filter { controller in
                    self?.windowControllers.contains { $0 === controller } == true
                }
                let notesWindow = saved.notes.flatMap {
                    NotesWindowController.instance.restore($0, among: open.compactMap(\.window))
                }
                guard let first = open.first?.window ?? notesWindow else { continue }
                // The frame last: a tab joining the window and a comparison
                // opening in it both fit the window to their content, and
                // the window is to stand where it was left.
                let frame = NSRect(x: saved.frame.x, y: saved.frame.y,
                                   width: saved.frame.width, height: saved.frame.height)
                first.setFrame(first.constrainFrameRect(frame, to: first.screen), display: true)
                let front = saved.notes?.isSelected == true ? notesWindow
                    : (selected.flatMap { open.contains($0) ? $0 : nil } ?? open.first)?.window
                if let window = front ?? first as NSWindow? {
                    window.tabGroup?.selectedWindow = window
                    window.makeKeyAndOrderFront(nil)
                }
            }
            if self?.windowControllers.isEmpty == true, !NotesWindowController.isOpen { self?.makeWindow() }
            recorder.isPaused = false
            self?.lastRestoreIssues = restorer.issues
            self?.reportRestoreIssues(restorer.issues)
        }
        return !windowControllers.isEmpty || workspace.windows.contains { $0.notes != nil }
    }

    /// The parts still being put back after a restore, and the windows being
    /// settled after them.
    private(set) var restoringParts: Task<Void, Never>?

    /// What the last restore could not bring back as it was.
    private(set) var lastRestoreIssues: [RestoreIssue] = []

    /// Files handed to a launch that restored a workspace: one already open in
    /// it is brought forward, the rest open in a tab of their own — never into
    /// a restored tab, where they would replace a file the person left there.
    private func openFilesBesideWorkspace(_ urls: [URL]) {
        var fresh: [URL] = []
        for url in urls {
            if let (holder, pane) = openDocuments.location(of: url, excluding: nil) {
                holder.revealOpenFile(inPane: pane)
            } else {
                fresh.append(url)
            }
        }
        guard !fresh.isEmpty else { return }
        makeWindow(tabbedWith: frontmostWindowController()?.window).mainViewController.openFiles(fresh)
    }

    /// One warning for everything the restore could not bring back as it was,
    /// on the window in front, once every panel is back
    /// (`Design/WORKSPACE_PLAN.md`, "Restoring"). Nothing to say, no sheet.
    // help: workspace.restore-warning
    private func reportRestoreIssues(_ issues: [RestoreIssue]) {
        guard !issues.isEmpty else { return }
        func list(_ paths: [String]) -> String {
            paths.map { "• " + ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        }
        let missing = issues.compactMap { if case let .missing(path) = $0 { path } else { nil } }
        let changed = issues.compactMap { if case let .changed(path) = $0 { path } else { nil } }
        var sections: [String] = []
        if !missing.isEmpty {
            sections.append(L("No longer found, not opened:") + "\n" + list(missing))
        }
        if !changed.isEmpty {
            sections.append(L("Changed on disk since the last session. Opened without their unsaved changes, segments, parts and tool state:")
                            + "\n" + list(changed))
        }
        let alert = NSAlert()
        alert.messageText = L("The workspace was not restored in full")
        alert.informativeText = sections.joined(separator: "\n\n")
        alert.addButton(withTitle: L("OK"))
        if let window = frontmostWindowController()?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// File ▸ New Window (⇧⌘N).
    @objc func newWindow(_ sender: Any?) {
        makeWindow()
    }

    /// The last resort for the tab bar's + button and ⌘T: with no window open
    /// there is no window controller to answer them, and the responder chain
    /// reaches the app delegate instead. A tab with nothing to join is a window.
    @objc func newWindowForTab(_ sender: Any?) {
        makeWindow(tabbedWith: NSApp.keyWindow)
    }

    /// ⌘T with no window open, for the same reason.
    @objc func newTab(_ sender: Any?) {
        makeWindow(tabbedWith: NSApp.keyWindow)
    }

    /// Builds a window, wires it to the application's open-file registry, and
    /// shows it.
    ///
    /// Only the first window saves its frame: one autosave name can serve one
    /// window, so every later one is cascaded off the window in front of it
    /// instead — which is also where a new window belongs on screen.
    @discardableResult
    func makeWindow(tabbedWith anchor: NSWindow? = nil) -> MainWindowController {
        // Only the launch window saves a frame: one autosave name can serve one
        // window, and a second window writing to the same key would fight the
        // first over one saved size.
        let isFirst = windowControllers.isEmpty
        let controller = MainWindowController(
            frameAutosaveName: isFirst ? "MainWindow" : nil)
        controller.mainViewController.openDocuments = openDocuments
        openDocuments.register(controller.mainViewController)
        // Tearing a pane off needs a tab to put it in, and only the app can make
        // one. The new tab joins the window the pane is leaving, so the two sit
        // side by side in the same tab bar.
        controller.mainViewController.makeSiblingTab = { [weak self, weak controller] in
            self?.makeWindow(tabbedWith: controller?.window).mainViewController
        }
        controller.mainViewController.hasOtherTabs = { [weak self] in
            (self?.windowControllers.count ?? 0) > 1
        }
        controller.mainViewController.openProject = { [weak self] url in
            // After the open that got here has unwound: the project closes
            // the window it was asked from.
            DispatchQueue.main.async { self?.openProject(at: url) }
        }
        controller.mainViewController.projectName = currentProjectName
        controller.mainViewController.quitsInsteadOfClosing = { [weak self] in
            guard let self, self.keepsWindowsAtQuit, !self.isSwitchingProjects,
                  self.windowControllers.count == 1, !NotesWindowController.isOpen else { return false }
            NSApp.terminate(nil)
            return true
        }
        windowControllers.append(controller)
        // A tab takes its place from the window it joins, so it is added before
        // being shown; a window on its own is placed by `NSWindowController`,
        // which cascades a window it shows unless that window autosaves its
        // frame — so the launch window lands where it was left and every later
        // one steps down and right of the one in front.
        if let anchor, let window = controller.window, anchor !== window {
            anchor.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        return controller
    }

    /// A file opened in a dump tab of its own when no dump window is open:
    /// beside the Annotations window when that is on screen.
    func openInNewTab(_ url: URL) {
        let anchor = NotesWindowController.shared?.window.flatMap { $0.isVisible ? $0 : nil }
        makeWindow(tabbedWith: anchor).mainViewController.openFiles([url])
    }

    /// The window a file handed to the app should open into: the one in front,
    /// or a fresh one when every window has been closed (the app stays running
    /// with no window only while something else keeps it alive).
    private func openFiles(_ urls: [URL]) {
        let controller = frontmostWindowController() ?? makeWindow()
        controller.mainViewController.openFiles(urls)
    }

    /// The key window's controller, else the most recently made one.
    private func frontmostWindowController() -> MainWindowController? {
        if let key = NSApp.keyWindow,
           let controller = windowControllers.first(where: { $0.window === key }) {
            return controller
        }
        return windowControllers.last
    }

    /// Finder double-click / "Open with" hands the file here. The files flow
    /// into the same open pipeline as the Open panel (§4.1), in the window in
    /// front — a file launched with the app opens directly into a pane.
    func application(_ application: NSApplication, open urls: [URL]) {
        // A node link an agent wrote: the file, then the node in its tree.
        let links = urls.compactMap(AgentNodeURLs.parse)
        var files = urls.filter { AgentNodeURLs.parse($0) == nil }
        // A project double-clicked in the Finder opens as a project.
        if isReady, let project = files.first(where: \.isByteRipperProject) {
            openProject(at: project)
        }
        if isReady { files.removeAll(where: \.isByteRipperProject) }
        if isReady {
            openNodeLinks(links)
        } else {
            pendingNodeLinks.append(contentsOf: links)
        }
        guard !files.isEmpty else { return }
        if isReady {
            openFiles(files)
        } else {
            pendingOpenURLs.append(contentsOf: files)
        }
    }

    private func openNodeLinks(_ links: [(file: URL, node: String?)]) {
        for link in links {
            Task { @MainActor in await agentService.openNode(file: link.file, id: link.node) }
        }
    }

    /// Coming forward is when to catch up with the shared library: a Mac hears
    /// nothing while it sleeps, and a file watcher cannot report what it did
    /// not see (§11).
    func applicationDidBecomeActive(_ notification: Notification) {
        workspaceRecorder?.start()
        guard !MainViewController.isRunningTests else { return }
        FavoritePatternStore.start()
    }

    /// Going to the background is a moment to write the workspace down: the
    /// timer stops until the app comes back, and nothing changes meanwhile.
    func applicationDidResignActive(_ notification: Notification) {
        workspaceRecorder?.record()
        workspaceRecorder?.stop()
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.showWindow(sender)
    }

    /// Window ▸ Agent (`Design/AGENT_PLAN.md`): the service's state and the log
    /// of what agents have asked. One for the app, built when first shown.
    private lazy var agentWindowController: AgentWindowController = {
        let controller = AgentWindowController(service: AgentService.shared)
        controller.showSettings = { [weak self] in self?.showAgentSettings(nil) }
        return controller
    }()

    /// The mark in the menu bar while the service is switched on.
    private var agentStatusItem: AgentStatusItem?

    @objc func showAgentWindow(_ sender: Any?) {
        agentWindowController.showWindow(sender)
        agentWindowController.window?.makeKeyAndOrderFront(sender)
        agentWindowController.focusList()
    }

    /// Window ▸ Annotations: the one Annotations window, as a tab beside the
    /// dump in front when it is closed — or a window of its own when no dump
    /// window is open.
    @objc func showNotesWindow(_ sender: Any?) {
        let anchor = frontmostWindowController()?.window
        NotesWindowController.instance.show(tabbedWith: anchor)
    }

    @objc func showAgentSettings(_ sender: Any?) {
        settingsWindowController.showAgent(sender)
    }

    /// Every item of the Help menu, and the ⌘? that opens the first of them.
    ///
    /// The page to open travels in the item's `representedObject`; an item
    /// without one — which no item here is, but a menu built elsewhere could be
    /// — opens the book at its first page rather than doing nothing.
    ///
    /// It lives on the app delegate because help belongs to no window: it has
    /// to work with none open, which is exactly when a new user needs it.
    ///
    /// **Not `showHelp(_:)`.** That is `NSApplication`'s own action, and
    /// `NSApplication` sits in the responder chain ahead of its delegate — so
    /// an item wired to that name never reached this method at all. AppKit
    /// answered it by looking for the help book named in the Info.plist,
    /// finding none, and putting up "Help isn't available for ByteRipper"
    /// (measured, on every item of the menu). The name is distinctive for the
    /// same reason `increaseHexFontSize` is: these dispatch to whoever answers
    /// first.
    @objc func showHelpBook(_ sender: Any?) {
        let link = (sender as? NSMenuItem)?.representedObject as? HelpLink
        HelpPresenter.show(link ?? .topic(.overview))
    }

    /// App ▸ About ByteRipper: the standard panel, with credits that say where
    /// the names the app shows come from. The command needs no target — like
    /// the standard command it replaces, it travels the responder chain to the
    /// app delegate.
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: AboutCredits.text(),
        ])
    }

    /// Zoom In / Zoom Out (§3.2): one step of the hex font size, applied live
    /// to every open window the way the Appearance tab applies it.
    ///
    /// The commands belong to the app, not to a window: the font size is one
    /// app-wide setting, and zooming in one window while another kept its own
    /// size would be a second, invisible preference. Distinctive selector
    /// names because these dispatch through the responder chain to whoever
    /// answers first, and `zoomIn:` is a name several AppKit views use.
    @objc func increaseHexFontSize(_ sender: Any?) {
        AppearanceSettings.zoom(by: AppearanceSettings.fontSizeStep)
    }

    @objc func decreaseHexFontSize(_ sender: Any?) {
        AppearanceSettings.zoom(by: -AppearanceSettings.fontSizeStep)
    }

    /// At either end of the size range there is nothing to do, so the item
    /// dims — the pressed shortcut beeps instead of silently doing nothing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(increaseHexFontSize(_:)):
            return AppearanceSettings.canZoom(by: AppearanceSettings.fontSizeStep)
        case #selector(decreaseHexFontSize(_:)):
            return AppearanceSettings.canZoom(by: -AppearanceSettings.fontSizeStep)
        default:
            return true
        }
    }

    /// Opens Settings on the Favorites tab — **Manage Favorites…** in the Find
    /// bar's search menu (§11).
    func showFavoritePatternSettings() {
        settingsWindowController.showFavorites(nil)
    }

    #if DEBUG
    /// ⌘⇧A flips light and dark, in a debug build only: for looking at a
    /// change in both themes without a trip to Settings. Not stored — the
    /// next launch, or a change in Settings, puts the chosen theme back.
    private func installThemeToggle() {
        themeToggleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // By the key, not the character: in a Russian layout the same key
            // types «ф», and the shortcut is the key under the finger.
            // 0 is kVK_ANSI_A.
            guard modifiers == [.command, .shift], event.keyCode == 0 else { return event }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSApp.appearance = NSAppearance(named: isDark ? .aqua : .darkAqua)
            return nil
        }
    }
    #endif

    /// Maps the stored theme onto `NSApp.appearance`: nil for system (follow the
    /// OS), an explicit appearance for light/dark.
    private func applyTheme() {
        NSApp.appearance = AppTheme.current.appearance
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Removes the socket file, so a relay started later finds nothing
        // there rather than a file nobody answers on.
        agentService.stop()
        // A change made a moment ago is written now, not on a turn of the run
        // loop that will not come.
        agentService.annotationTools.saveNow()
        // The last snapshot, after every Save / Discard was answered: a file
        // saved under a new name in the quit's questions is in it by that name.
        workspaceRecorder?.stop()
        workspaceRecorder?.record()
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Not while one project's windows give way to another's.
        !isSwitchingProjects
    }

    /// True while the windows of one project close for another's to open.
    var isSwitchingProjects: Bool {
        get { switchingProjects }
        set { switchingProjects = newValue }
    }

    /// ⌘Q. Every window is asked what closing it would ask — the parts it
    /// holds, then its files — one at a time, and the app goes only when all of
    /// them agree.
    ///
    /// Quit used to take everything unsaved in the app with it. The prompt each
    /// window puts up is a *close* prompt, and terminating closes nothing: no
    /// window was ever asked.
    ///
    /// Answered here where every window can answer on the spot; a window whose
    /// answer needs a sheet — an untitled file has to be given a location, a
    /// part is being put back — makes the quit wait for it instead. That wait
    /// runs its own run loop, so a window must always answer, either way: it
    /// is why the flows it goes through report a backed-out sheet as an answer
    /// rather than saying nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // More than one thing to answer for, and the answers are a queue of
        // dialogs the reader is about to be walked through. Say so first, and
        // say how many — the way every document-based app on the system does.
        // One is not a queue: it is asked directly, with no preamble.
        let kept = keptAtQuit()
        let unsaved = windowControllers.reduce(0) { $0 + $1.mainViewController.unsavedDocumentCount(keeping: kept) }
        // The questions below bring each window to the front in turn; the
        // workspace keeps the order the person left.
        workspaceRecorder?.freezeOrder()
        if unsaved > 1 {
            switch confirmReviewingChanges(unsaved) {
            case .alertSecondButtonReturn:  // Discard Changes
                return .terminateNow
            case .alertThirdButtonReturn:  // Cancel
                workspaceRecorder?.thawOrder()
                return .terminateCancel
            default:  // Review Changes…
                break
            }
        }
        var inThisCall = true
        var answer: NSApplication.TerminateReply?
        askToClose(windowControllers, keeping: kept) { [weak sender, weak self] agreed in
            answer = agreed ? .terminateNow : .terminateCancel
            if !agreed { self?.workspaceRecorder?.thawOrder() }
            if !inThisCall { sender?.reply(toApplicationShouldTerminate: agreed) }
        }
        inThisCall = false
        return answer ?? .terminateLater
    }

    /// What quitting does not ask about: with the workspace on, an untitled
    /// document, a part or a file's unsaved changes the workspace holds as
    /// they are now come back at the next launch, still unsaved
    /// (`Design/WORKSPACE_PLAN.md`, "Untitled documents"). A snapshot is taken
    /// first, so "as they are now" is true; a document whose bytes could not
    /// be written is asked about as before.
    private func keptAtQuit() -> (PaneViewModel) -> Bool {
        // A project keeps everything, the switch or not: it is a file the
        // person made to keep. The session keeps the same while the switch is
        // on.
        guard let recorder = workspaceRecorder,
              recorder.project != nil || WorkspaceSettings.restoresWorkspace else { return { _ in false } }
        recorder.record()
        let keeper = recorder.keeper
        return { pane in keeper.holdsCurrentBytes(of: pane) }
    }

    /// The one question asked before the queue of them: review, throw it all
    /// away, or stay.
    private func confirmReviewingChanges(_ count: Int) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = L("You have %1$@ documents with unsaved changes. Do you want to review these changes before quitting?", count)
        alert.informativeText = L("If you don’t review your documents, all your changes will be lost.")
        alert.addButton(withTitle: L("Review Changes…"))
        alert.addButton(withTitle: L("Discard Changes"))
        alert.addButton(withTitle: L("Cancel"))
        // Cancel in tests: quitting must never be the thing that throws work
        // away while a suite is running.
        return MainViewController.presentModal(alert, defaultInTest: .alertThirdButtonReturn)
    }

    /// Asks the windows in `queue` one at a time, stopping at the first that
    /// says no.
    func askToClose(_ queue: [MainWindowController],
                            keeping kept: @escaping (PaneViewModel) -> Bool,
                            then done: @escaping (Bool) -> Void) {
        var rest = queue
        guard let controller = rest.first else {
            done(true)
            return
        }
        rest.removeFirst()
        // The questions are alerts that name a file, not a window, and a tab
        // that is not in front is a question about something nobody can see —
        // so the window being asked about comes to the front to ask it.
        controller.window?.makeKeyAndOrderFront(nil)
        controller.mainViewController.confirmClose(keeping: kept) { [weak self] agreed in
            guard agreed, let self else {
                done(agreed)
                return
            }
            self.askToClose(rest, keeping: kept, then: done)
        }
    }
}
