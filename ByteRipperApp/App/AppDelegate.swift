import Cocoa
import HelpBook
import HelpUI
import ToolModuleKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Every open comparison window, in the order they were made. The app owns
    /// its windows rather than being one window's owner: ⇧⌘N adds one, closing
    /// one drops it, and a file handed to the app has to be routed to one of
    /// them rather than to "the" window.
    private var windowControllers: [MainWindowController] = []

    /// Drops a window from `windowControllers` when it closes, so a closed
    /// window is neither kept alive nor offered a file to open.
    private var closeObserver: NSObjectProtocol?
    /// URLs handed to us by Launch Services before the window existed. An
    /// "Open with" / double-click launch can deliver `application(_:open:)`
    /// before `applicationDidFinishLaunching` finishes building the window, so
    /// they queue here and drain once it is up.
    private var pendingOpenURLs: [URL] = []
    private var isReady = false
    /// Observes theme changes so a Settings change re-themes the running app
    /// without a relaunch (§3.2).
    private var themeObserver: NSObjectProtocol?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The panels read their zoom from a package, which cannot see the app
        // and so cannot know that a test run reads a suite of its own
        // (`AppDefaults`). Before anything draws, tell it.
        ToolPanelFont.defaults = AppDefaults.store
        // Tabs are windows. Turning this on is what gives the app the system's
        // tab bar, ⌘T through `newWindowForTab(_:)`, ⌃Tab and ⌘1…⌘9, dragging a
        // tab out into its own window and dragging one back in, and the Window
        // menu's Show Tab Bar / Move Tab to New Window / Merge All Windows —
        // none of which then has to be built or maintained here.
        NSWindow.allowsAutomaticWindowTabbing = true
        // Apply the stored theme before any window appears, so the first frame
        // is already in the right appearance (§3.2).
        applyTheme()
        // Drop bookmarks for files that are no longer there (§D9). They can
        // only fail to resolve, and the store used to keep every one of them
        // for ever: one machine had 9 434 of them, 14 MB of preferences, nearly
        // all pointing at temporary files the test suite had deleted.
        SandboxBookmarkStore.shared.pruneNow()
        // The recent-files list keeps its own copy of "what is on disk" and
        // would otherwise keep a deleted file's row for ever — prune it here,
        // the same way, at the same moment.
        RecentFilesStore.pruneMissing()
        // The pattern library reads itself and, when it is published to a
        // shared file, merges what is there and starts watching it (§11). At
        // launch rather than on first use: a Mac that has not opened the Find
        // bar is still a Mac whose library should be current.
        //
        // Never under XCTest. The test host *is* this app, with this app's
        // container and this app's preferences, so starting the library there
        // merges and republishes the developer's own — into their own synced
        // folder, from a process that is about to swap the store's defaults
        // out from under it. A suite must not touch the library it is not
        // testing.
        if !MainViewController.isRunningTests {
            FavoritePatternStore.start()
        }
        // The menu bar belongs to the application, not to a window: it is built
        // once, here, and its commands travel the responder chain to whichever
        // window is key.
        let mainMenu = MainMenu.build(appTarget: self)
        NSApp.mainMenu = mainMenu
        // The File menu's Open Recent submenu is built empty (its rows depend
        // on what has been opened, which the build cannot know); hand it the
        // delegate that rebuilds the rows before each display.
        if let fileMenu = mainMenu.items.compactMap(\.submenu).first(where: { $0.title == "File" }),
           let openRecentMenu = fileMenu.items.first(where: { $0.title == "Open Recent" })?.submenu {
            openRecentMenu.delegate = openRecentMenuController
        }
        // Handing AppKit the Window submenu is what puts the open windows in it,
        // with Bring All to Front above them — worth having the moment there is
        // more than one window, and the place the system also hangs its own tab
        // commands.
        NSApp.windowsMenu = mainMenu.items.compactMap(\.submenu).first { $0.title == "Window" }
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
                self?.windowControllers.removeAll { $0.window === window }
            }
        }
        makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        // The window is up; drain any files Launch Services handed us first.
        isReady = true
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            openFiles(urls)
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
    private func makeWindow(tabbedWith anchor: NSWindow? = nil) -> MainWindowController {
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
        if isReady {
            openFiles(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    /// Coming forward is when to catch up with the shared library: a Mac hears
    /// nothing while it sleeps, and a file watcher cannot report what it did
    /// not see (§11).
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !MainViewController.isRunningTests else { return }
        FavoritePatternStore.start()
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.showWindow(sender)
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

    /// Maps the stored theme onto `NSApp.appearance`: nil for system (follow the
    /// OS), an explicit appearance for light/dark.
    private func applyTheme() {
        NSApp.appearance = AppTheme.current.appearance
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        let unsaved = windowControllers.reduce(0) { $0 + $1.mainViewController.unsavedDocumentCount }
        if unsaved > 1 {
            switch confirmReviewingChanges(unsaved) {
            case .alertSecondButtonReturn:  // Discard Changes
                return .terminateNow
            case .alertThirdButtonReturn:  // Cancel
                return .terminateCancel
            default:  // Review Changes…
                break
            }
        }
        var inThisCall = true
        var answer: NSApplication.TerminateReply?
        askToClose(windowControllers) { [weak sender] agreed in
            answer = agreed ? .terminateNow : .terminateCancel
            if !inThisCall { sender?.reply(toApplicationShouldTerminate: agreed) }
        }
        inThisCall = false
        return answer ?? .terminateLater
    }

    /// The one question asked before the queue of them: review, throw it all
    /// away, or stay.
    private func confirmReviewingChanges(_ count: Int) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "You have \(count) documents with unsaved changes. "
            + "Do you want to review these changes before quitting?"
        alert.informativeText = "If you don’t review your documents, all your changes will be lost."
        alert.addButton(withTitle: "Review Changes…")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        // Cancel in tests: quitting must never be the thing that throws work
        // away while a suite is running.
        return MainViewController.presentModal(alert, defaultInTest: .alertThirdButtonReturn)
    }

    /// Asks the windows in `queue` one at a time, stopping at the first that
    /// says no.
    private func askToClose(_ queue: [MainWindowController],
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
        controller.mainViewController.confirmClose { [weak self] agreed in
            guard agreed, let self else {
                done(agreed)
                return
            }
            self.askToClose(rest, then: done)
        }
    }
}
