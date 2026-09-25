import Cocoa
import HelpBook
import Localization

/// The application's menu bar (§4, §5, §7, §10.3, §11, §12), built in code
/// rather than from a nib.
///
/// There is one menu bar per application no matter how many windows or tabs are
/// open, so it is built once at launch and belongs to no window. That is also
/// why nothing here carries a target — apart from ⌘, — and every command
/// instead travels the responder chain to the key window's
/// `MainViewController`. A menu addressed to one particular controller would go
/// on addressing it after the user switched to another tab.
enum MainMenu {
    /// Builds the whole bar. `appTarget` receives the two commands that belong
    /// to the application rather than to a document — Settings… (⌘,) and every
    /// item of the Help menu — as an explicit target rather than through the
    /// responder chain, so they work while the hex view, which swallows
    /// unmodified keystrokes, is first responder, and while AppKit would
    /// otherwise answer for them (see `makeHelpMenu`).
    static func build(appTarget: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L("About ByteRipper"),
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        // Standard macOS placement: Settings… between About and the Hide/Quit
        // group. Explicit target keeps ⌘, working even when the hex view (which
        // swallows unmodified keystrokes) is first responder.
        let settingsItem = appMenu.addItem(
            withTitle: L("Settings…"),
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = appTarget
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide ByteRipper"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit ByteRipper"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu (§4, §5).
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        fileItem.submenu = makeFileMenu()

        // Edit menu (§7, §11, §12)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        editItem.submenu = makeEditMenu()

        // View menu (§10.3 navigation, §3.3 layout)
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        viewItem.submenu = makeViewMenu()

        // Tools menu (Design/TOOL_MODULES_PLAN.md): between View and Window,
        // where an instrument that acts on the open document belongs — after
        // the menus about looking at it, before the ones about the windows it
        // is looked at in.
        let toolsItem = NSMenuItem()
        mainMenu.addItem(toolsItem)
        toolsItem.submenu = makeToolsMenu()

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L("Window", context: "menu"))
        windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        // Help menu
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        helpItem.submenu = makeHelpMenu(target: appTarget)

        return mainMenu
    }

    /// Builds the app menu bar's Help submenu.
    ///
    /// The first item is what every Mac app puts there, on the key every Mac
    /// app puts it on. Under it are the three doors a bench actually walks
    /// through — what the app is for, the rules for not ruining a dump, and the
    /// glossaries the firmware panels' words are explained in — because the one
    /// thing a help menu can do better than a window is start the reader
    /// somewhere useful.
    ///
    /// Every item carries its destination in `representedObject` as the
    /// `HelpLink` itself, so one action serves the whole menu and nothing here
    /// matches on a title.
    ///
    /// **Explicit target, and a name of our own**, which is two guards against
    /// the same thing — an item of a menu titled "Help" being answered by
    /// AppKit instead of by us:
    ///
    /// - The action is `showHelpBook(_:)`, not `showHelp(_:)`. The latter is
    ///   `NSApplication`'s own action, and `NSApplication` is in the responder
    ///   chain ahead of its delegate, so every item wired to that name was
    ///   answered by AppKit looking for a help book the app does not have:
    ///   "Help isn't available for ByteRipper" (measured).
    /// - The target is the app delegate rather than the responder chain, for
    ///   the reason Settings… carries one: help belongs to no window and must
    ///   work with none open, and with a hex view — which swallows plain
    ///   keystrokes — as first responder.
    ///
    /// A glossary item opens its first entry, which is how the window's
    /// contents comes to be showing that glossary open — the sidebar expands
    /// whichever group holds the page it is told to show.
    static func makeHelpMenu(target: AnyObject? = nil) -> NSMenu {
        let helpMenu = NSMenu(title: L("Help", context: "menu"))

        func add(_ title: String, _ link: HelpLink, key: String = "") {
            let item = helpMenu.addItem(withTitle: title,
                                        action: #selector(AppDelegate.showHelpBook(_:)),
                                        keyEquivalent: key)
            item.representedObject = link
            item.target = target
        }

        // ⌘? is the platform's own help key: ⇧⌘/ , which AppKit spells as "?"
        // with Command alone.
        // help: menu.help.book
        add(L("ByteRipper Help"), .topic(.overview), key: "?")
        helpMenu.addItem(.separator())
        add(L("Getting Started"), .topic(.firstComparison))
        add(L("Bench Rules"), .topic(.benchSafety))
        helpMenu.addItem(.separator())
        add(L("Glossary: UEFI Images"), .term(HelpTermID("flash-descriptor")))
        add(L("Glossary: Intel ME"), .term(HelpTermID("fpt")))
        add(L("Where This Knowledge Comes From"), .topic(.provenance))
        return helpMenu
    }

    /// Builds the app menu bar's Tools submenu: None, then every tool-module
    /// the registry holds, in its order (`Design/TOOL_MODULES_PLAN.md`).
    ///
    /// One tool-module runs per tab, so these are radio items rather than
    /// toggles — the menu answers "which one", and None is how the panel is
    /// closed. The tool-module an item stands for travels in
    /// `representedObject` as its identifier, and None carries nothing, so the
    /// same action serves every row and the controller never matches on titles.
    ///
    /// Built from the registry when the bar is built, which is once per launch:
    /// what is installed cannot change while the app runs.
    static func makeToolsMenu() -> NSMenu {
        let toolsMenu = NSMenu(title: L("Tools", context: "menu"))
        // help: menu.tools.none
        toolsMenu.addItem(withTitle: L("None"),
                          action: #selector(MainViewController.activateTool(_:)),
                          keyEquivalent: "")
        guard !ToolRegistry.modules.isEmpty else { return toolsMenu }
        toolsMenu.addItem(.separator())
        for module in ToolRegistry.modules {
            let item = toolsMenu.addItem(withTitle: module.title,
                                         action: #selector(MainViewController.activateTool(_:)),
                                         keyEquivalent: "")
            item.representedObject = module.identifier
        }
        return toolsMenu
    }

    /// Builds the app menu bar's View submenu (§3.3 layout, §10.3 navigation,
    /// §19 the minimap). Standalone for the same reason File and Edit are: a
    /// test can read what the menu offers without installing a menu bar on the
    /// running process.
    static func makeViewMenu() -> NSMenu {
        let viewMenu = NSMenu(title: L("View", context: "menu"))
        // help: menu.view.pane-layout
        viewMenu.addItem(withTitle: L("Toggle Pane Layout"), action: #selector(MainViewController.togglePaneLayout), keyEquivalent: "l")
        if let layoutItem = viewMenu.items.last {
            layoutItem.keyEquivalentModifierMask = [.command, .option]
        }
        // help: menu.view.swap-panes
        viewMenu.addItem(withTitle: L("Swap Panels"), action: #selector(MainViewController.swapPanes), keyEquivalent: "")
        // The minimap toggle also lives in the toolbar; the menu gives it a key
        // equivalent and a discoverable home. The title flips with the panel's
        // state, the way Show/Hide items do elsewhere on the platform.
        // help: menu.view.minimap
        viewMenu.addItem(withTitle: L("Show Minimap"),
                         action: #selector(MainViewController.toggleMinimap),
                         keyEquivalent: "M")
        // Whole-file overview vs the detail window around the caret (§19.4). A
        // checked item, not a flipping title: both modes show a minimap, so the
        // check reads as "which one" rather than "on or off".
        // help: menu.view.minimap-overview
        let overviewItem = viewMenu.addItem(withTitle: L("Minimap Overview"),
                                           action: #selector(MainViewController.toggleMinimapOverview),
                                           keyEquivalent: "m")
        overviewItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())

        func addNavigationItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        // help: menu.view.next-difference
        addNavigationItem(L("Next Difference"), #selector(MainViewController.nextDifference), "\u{F703}", [.command, .option])
        // help: menu.view.previous-difference
        addNavigationItem(L("Previous Difference"), #selector(MainViewController.previousDifference), "\u{F702}", [.command, .option])
        // help: menu.view.next-same
        addNavigationItem(L("Next Same Block"), #selector(MainViewController.nextSameBlock), "\u{F703}", [.command, .option, .shift])
        // help: menu.view.previous-same
        addNavigationItem(L("Previous Same Block"), #selector(MainViewController.previousSameBlock), "\u{F702}", [.command, .option, .shift])

        // Word Size (§6): group the hex bytes into words of 1/2/4/8 bytes.
        viewMenu.addItem(.separator())
        // help: menu.view.word-size
        let wordSizeItem = NSMenuItem(title: L("Word Size"), action: nil, keyEquivalent: "")
        let wordSizeMenu = NSMenu(title: L("Word Size"))
        for size in WordSize.allCases {
            let item = wordSizeMenu.addItem(
                withTitle: size.title,
                action: #selector(MainViewController.setWordSize(_:)),
                keyEquivalent: ""
            )
            item.tag = size.rawValue
        }
        wordSizeItem.submenu = wordSizeMenu
        viewMenu.addItem(wordSizeItem)

        // Zoom (§3.2): the hex font size, one point at a time, on the shortcuts
        // every document app uses for it. It is the same app-wide setting the
        // Appearance tab holds — the menu is the fast way to it, not a second
        // preference — so the items go to the app delegate rather than to a
        // controller: a window cannot have a size of its own.
        viewMenu.addItem(.separator())
        // help: menu.view.zoom
        viewMenu.addItem(withTitle: L("Zoom In"),
                         action: #selector(AppDelegate.increaseHexFontSize(_:)),
                         keyEquivalent: "=")
        viewMenu.addItem(withTitle: L("Zoom Out"),
                         action: #selector(AppDelegate.decreaseHexFontSize(_:)),
                         keyEquivalent: "-")

        viewMenu.addItem(.separator())
        // help: menu.view.full-screen
        viewMenu.addItem(withTitle: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        if let fullScreenItem = viewMenu.items.last {
            fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        }
        return viewMenu
    }

    /// Builds the app menu bar's File submenu (§4, §5). No item carries a
    /// target: each command travels the responder chain to the key window's
    /// `MainViewController`, which resolves the active pane.
    static func makeFileMenu() -> NSMenu {
        let fileMenu = NSMenu(title: L("File", context: "menu"))
        func add(_ title: String, _ action: Selector, _ key: String) {
            fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        // New File: no dialog — a brand-new untitled in-memory document opens
        // into a pane; it is written to disk on the first Save / Save As.
        // help: menu.file.new
        add(L("New File"), #selector(MainViewController.newDocument), "n")
        // New Window (⇧⌘N) is the app's, not a pane's: it is the one File
        // command that does not act on a document, so it is the one item here
        // the responder chain carries past every view controller to the app
        // delegate, which owns the windows.
        // help: menu.file.new-window
        add(L("New Window"), #selector(AppDelegate.newWindow(_:)), "N")
        // New Tab (⌘T) is the app's own item. Automatic tabbing supplies the tab
        // bar, Merge All Windows and Move Tab to New Window, and it calls
        // `newWindowForTab(_:)` for the bar's + button — but the command in the
        // menu, and the key that opens a tab without the bar showing, are ours
        // to put here.
        // help: menu.file.new-tab
        add(L("New Tab"), #selector(MainViewController.newTab(_:)), "t")
        // help: menu.file.open
        add(L("Open…"), #selector(MainViewController.presentOpenPanel), "o")
        // Open Recent: a submenu parent like "Word Size" — no action, no key
        // equivalent, its own submenu empty at build time. The list of opened
        // files keeps changing as files open, so the rows are rebuilt on every
        // display by the submenu's delegate (`OpenRecentMenuController`),
        // which `applicationDidFinishLaunching` wires on.
        let openRecent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        openRecent.submenu = NSMenu(title: L("Open Recent"))
        fileMenu.addItem(openRecent)
        fileMenu.addItem(.separator())
        // help: menu.file.save
        add(L("Save"), #selector(MainViewController.saveDocument), "s")
        // help: menu.file.save-as
        add(L("Save As…"), #selector(MainViewController.saveDocumentAs), "S")
        // help: menu.file.revert
        add(L("Revert to Saved"), #selector(MainViewController.revertDocument), "")
        // Update in Parent (`Design/UEFI/UPDATE_IN_PARENT.md` §3): a tab opened
        // from a part of another document puts its bytes back there. With the
        // Saves, because it is the third place a document's changes can go.
        // help: menu.file.update-in-parent
        add(L("Update in Parent"), #selector(MainViewController.updateInParent), "")
        fileMenu.addItem(.separator())
        // The join commands (§22.1): bring a second file's bytes into the active
        // pane, at one end or the other. They act on the active pane, like the
        // rest of the File submenu. Insert (at the start) is grouped with the
        // edit commands above; Append (at the end) sits in its own block.
        // help: menu.file.insert-at-start
        add(L("Insert File at Start…"), #selector(MainViewController.insertFileAtStart), "")
        // help: menu.file.append
        add(L("Append File…"), #selector(MainViewController.appendFile), "")
        fileMenu.addItem(.separator())
        // Duplicate (§23): the active pane's content, copied into the free pane
        // as an untitled document — how the dump as opened is kept beside a copy
        // being patched. Single-file mode only, and no key equivalent: ⌘D is
        // Toggle Bookmark (§20).
        // help: menu.file.duplicate
        add(L("Duplicate"), #selector(MainViewController.duplicateDocument), "")
        fileMenu.addItem(.separator())
        // Close (⌘W) closes the active pane ("close document"); with no panes
        // open it falls back to closing the window (§3.5).
        // help: menu.file.close
        add(L("Close"), #selector(MainViewController.closeDocument), "w")
        // ⌘W works down one step at a time — the active pane, then the tab once
        // no pane is left, then the window once no tab is. ⇧⌘W is the whole
        // window at once, every tab in it (`Design/TABS_PLAN.md`).
        // help: menu.file.close-window
        add(L("Close Window"), #selector(MainViewController.closeWindow(_:)), "W")
        return fileMenu
    }

    /// Builds the app menu bar's Edit submenu (§7, §11, §12). Standalone so a
    /// test can pin the key-equivalent routing: ⌘V must reach the standard
    /// `paste:` action (responder chain), never paste-write.
    static func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: L("Edit", context: "menu"))
        // help: menu.edit.undo
        editMenu.addItem(withTitle: L("Undo"), action: #selector(MainViewController.undoEdit), keyEquivalent: "z")
        // help: menu.edit.redo
        editMenu.addItem(withTitle: L("Redo"), action: #selector(MainViewController.redoEdit), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: nil, keyEquivalent: "")
        // help: menu.edit.copy
        editMenu.addItem(withTitle: L("Copy"), action: #selector(MainViewController.copySelection), keyEquivalent: "c")
        // ⌘V is the standard Paste (§11): the menu item dispatches `paste:`
        // down the responder chain, so a focused text field's editor pastes
        // text, while a focused hex view routes to MainViewController.paste(_:)
        // and overwrites bytes (paste-write). Plain Paste already IS the
        // paste-write in the dump, so no separate "Paste Write" entry exists.
        // help: menu.edit.paste
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // help: menu.edit.paste-insert
        editMenu.addItem(withTitle: L("Paste Insert…"), action: #selector(MainViewController.pasteInsert), keyEquivalent: "")
        // help: menu.edit.delete-bytes
        editMenu.addItem(withTitle: L("Delete Bytes…"), action: #selector(MainViewController.deleteBytes), keyEquivalent: "")
        // A checked toggle, not a one-shot command: it flips the typing mode for
        // both panes (see `toggleInsertMode`). Bound to ⌥⌘I — a mode switch the
        // user reaches often, so it earns a shortcut (Option keeps it clear of
        // the plain-⌘ single-letter command space).
        // help: menu.edit.insert-mode
        let insertModeItem = editMenu.addItem(withTitle: L("Insert Mode"),
                                              action: #selector(MainViewController.toggleInsertMode),
                                              keyEquivalent: "i")
        insertModeItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(.separator())
        // Select Block leads the selection block: it selects a named block from
        // the caret, alongside Fill and Select All.
        // help: menu.edit.select-block
        editMenu.addItem(withTitle: L("Select Block…"), action: #selector(MainViewController.selectBlock), keyEquivalent: "")
        // help: menu.edit.fill
        editMenu.addItem(withTitle: L("Fill Selection with…"), action: #selector(MainViewController.fillSelectionWithBytes), keyEquivalent: "")
        // help: menu.edit.select-all
        editMenu.addItem(withTitle: L("Select All"), action: #selector(MainViewController.selectAllBytes), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // help: menu.edit.find
        editMenu.addItem(withTitle: L("Find"), action: #selector(MainViewController.findPattern), keyEquivalent: "f")
        // ⌘E beside Find, where every Mac app puts it: it loads the pattern the
        // next Find will use and does nothing else — no bar, no search (§11).
        // help: menu.edit.use-selection
        editMenu.addItem(withTitle: L("Use Selection for Find"),
                         action: #selector(MainViewController.useSelectionForFind),
                         keyEquivalent: "e")
        // ⌘D marks (or unmarks) the caret's row — the gesture that has to cost
        // nothing on a bench (§20). It sits beside Go To: mark where you are,
        // then go to a position. The title says Toggle rather than Add because
        // the one command does both, whatever the caret's row currently is.
        // help: menu.edit.bookmark-toggle
        editMenu.addItem(withTitle: L("Toggle Bookmark"), action: #selector(MainViewController.toggleBookmark), keyEquivalent: "d")
        // ⇧⌘D edits the caret's row's mark — its address and its name. Making one
        // is ⌘D's job, which opens the same popover, so this command only ever
        // edits, and is greyed out on a row that carries no mark (§20.3).
        // help: menu.edit.bookmark-edit
        editMenu.addItem(withTitle: L("Edit Bookmark…"), action: #selector(MainViewController.editBookmark), keyEquivalent: "D")
        // help: menu.edit.go-to
        editMenu.addItem(withTitle: L("Go To Position…"), action: #selector(MainViewController.goToPosition), keyEquivalent: "l")
        // The segment pair (§21.3). No key equivalents: both are deliberate acts
        // reached from a menu, and the fast path is Split Here at «address» in the dump's own
        // context menu. Add Cut… opens the offset-and-description popover;
        // Merge merges the piece the caret sits in into a neighbour — it acts on
        // the caret's position, not on a cut point. Its title is renamed by
        // validation to name the piece and its neighbour ("Merge S1 into S0").
        editMenu.addItem(.separator())
        // help: menu.edit.add-cut
        editMenu.addItem(withTitle: L("Add Cut…"), action: #selector(MainViewController.addCut), keyEquivalent: "")
        // help: menu.edit.merge
        editMenu.addItem(withTitle: L("Merge"), action: #selector(MainViewController.removeSegment(_:)), keyEquivalent: "")
        // Segments…: the partition's own form (§21.4) — the list the two
        // commands above edit, with a row editor and the Save All button.
        // ⌥⌘S opens it: ⌘S is Save and ⇧⌘S is Save As, so the form takes the
        // Option variant.
        // help: menu.edit.segments
        let segmentsItem = editMenu.addItem(withTitle: L("Segments…"),
                                            action: #selector(MainViewController.showSegments),
                                            keyEquivalent: "s")
        segmentsItem.keyEquivalentModifierMask = [.command, .option]
        return editMenu
    }
}
