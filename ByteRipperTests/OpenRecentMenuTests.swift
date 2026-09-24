import XCTest
@testable import ByteRipper

/// File ▸ Open Recent: the submenu's rows, what a row click does, and Clear
/// Menu. Against the menu's own delegate and a bare controller rather than an
/// installed menu bar — the same reading `ToolsMenuTests` and `PatternMenuTests`
/// take of their menus: what the menu *is* is tested here, and the open it
/// triggers through the controller's own pipeline.
@MainActor
final class OpenRecentMenuTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var controller: MainViewController!
    private var window: NSWindow!
    private var menu: NSMenu!
    /// The menu's delegate is held weakly, so the test keeps its own reference
    /// — the same thing the app delegate does for the real menu bar.
    private var populator: OpenRecentMenuController!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        RecentFilesStore.defaults = store

        controller = MainViewController()
        window = makeTestWindow()
        window.contentViewController = controller
        populator = OpenRecentMenuController()
        menu = NSMenu(title: "Open Recent")
        menu.delegate = populator
    }

    override func tearDown() {
        populator = nil
        menu = nil
        window = nil
        controller = nil
        RecentFilesStore.defaults = AppDefaults.store
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    private func row(_ title: String) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "a “\(title)” row")
    }

    /// The File menu offers the submenu after Open… — the standard macOS place
    /// for it — with no action of its own: its rows are the commands.
    func testTheFileMenuCarriesAnOpenRecentSubmenuAfterOpen() throws {
        let fileMenu = MainMenu.makeFileMenu()
        let items = fileMenu.items
        let open = try XCTUnwrap(items.first { $0.title == "Open…" })
        let openRecent = try XCTUnwrap(items.first { $0.title == "Open Recent" })
        XCTAssertEqual(items.firstIndex(of: openRecent), items.firstIndex(of: open)! + 1,
                       "Open Recent sits right after Open…")
        // A submenu parent is not a command, its rows are: AppKit synthesizes
        // the action that opens it, gives it no key equivalent, and — as the
        // run proved — points its target at the submenu itself.
        XCTAssertEqual(openRecent.action, #selector(NSMenu.submenuAction(_:)))
        XCTAssertEqual(openRecent.keyEquivalent, "")
        XCTAssertTrue(openRecent.target === openRecent.submenu)
        XCTAssertNotNil(openRecent.submenu)
    }

    /// An empty list is an empty menu — no rows and no Clear Menu to clear
    /// with.
    func testAnEmptyListIsAnEmptyMenu() {
        populator.populate(menu)

        XCTAssertTrue(menu.items.isEmpty)
    }

    /// One row per recent file, most recent first, each carrying its path,
    /// addressed to no target so the click travels the responder chain.
    func testTheRowsAreTheRecentFilesMostRecentFirst() throws {
        let a = try tempFile([0x41])
        let b = try tempFile([0x42])
        RecentFilesStore.record(a)
        RecentFilesStore.record(b)
        populator.populate(menu)

        XCTAssertEqual(menu.items.map(\.title), [b.lastPathComponent, a.lastPathComponent, "Clear Menu"])

        let rowA = try row(a.lastPathComponent)
        let rowB = try row(b.lastPathComponent)
        XCTAssertEqual(rowB.representedObject as? String, b.standardizedFileURL.path)
        XCTAssertEqual(rowA.representedObject as? String, a.standardizedFileURL.path)
        // Two names can collide; the tooltip is where the path shows.
        XCTAssertEqual(rowB.toolTip, b.standardizedFileURL.path)

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNil(item.target, "\(item.title) must travel the responder chain")
        }
        XCTAssertEqual(rowA.action, #selector(MainViewController.openRecentFile(_:)))
        XCTAssertEqual(rowB.action, #selector(MainViewController.openRecentFile(_:)))
        XCTAssertEqual(try row("Clear Menu").action, #selector(MainViewController.clearRecentFiles(_:)))
    }

    /// **Clear Menu** is the menu's own row, so it exists only while there is
    /// something to clear.
    func testClearMenuAppearsOnlyWithAListToClear() {
        RecentFilesStore.record(URL(fileURLWithPath: "/var/tmp/ByteRipper/a.bin"))
        populator.populate(menu)
        XCTAssertEqual(menu.items.last?.title, "Clear Menu")

        RecentFilesStore.clear()
        populator.populate(menu)
        XCTAssertFalse(menu.items.contains { $0.title == "Clear Menu" })
    }

    /// A row stands for a file on disk, so it is available only while that file
    /// is still there.
    func testARowIsDisabledWhenItsFileIsGone() throws {
        let url = try tempFile([0x41])
        RecentFilesStore.record(url)
        populator.populate(menu)
        let live = try row(url.lastPathComponent)
        XCTAssertTrue(controller.validateMenuItem(live), "a row whose file is there is enabled")

        try FileManager.default.removeItem(at: url)
        controller.windowModel.pane1.close()
        populator.populate(menu)
        let gone = try row(url.lastPathComponent)
        XCTAssertFalse(controller.validateMenuItem(gone), "a row whose file is gone is greyed")
    }

    /// Clicking a row opens the file through the normal pipeline — placement,
    /// the already-open refusal, all of it unchanged.
    func testClickingARowOpensTheFile() throws {
        let url = try tempFile([0x41, 0x42, 0x43])
        RecentFilesStore.record(url)
        populator.populate(menu)
        let row = try row(url.lastPathComponent)

        controller.openRecentFile(row)

        XCTAssertTrue(controller.windowModel.pane1.isOpen)
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, url.lastPathComponent)
        // The open re-recorded the file, and it was already at the front.
        XCTAssertEqual(RecentFilesStore.recent.first, url.standardizedFileURL.path)
    }

    /// Clear Menu wipes the list and the rows that are on screen while it is
    /// clicked.
    func testClearMenuEmptiesTheListAndTheOpenMenu() throws {
        let a = try tempFile([0x41])
        let b = try tempFile([0x42])
        RecentFilesStore.record(a)
        RecentFilesStore.record(b)
        populator.populate(menu)
        let clear = try row("Clear Menu")

        controller.clearRecentFiles(clear)

        XCTAssertTrue(RecentFilesStore.recent.isEmpty)
        XCTAssertTrue(menu.items.isEmpty, "the open menu's rows go immediately")
        XCTAssertEqual(clear.action, #selector(MainViewController.clearRecentFiles(_:)))
    }

    /// Clear Menu is available exactly while the list is non-empty — the
    /// delegate's own rule for showing the row, agreed by validation.
    func testClearMenuValidationFollowsTheList() throws {
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(MainViewController.clearRecentFiles(_:)),
                               keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(clear), "greyed with an empty list")

        RecentFilesStore.record(URL(fileURLWithPath: "/var/tmp/ByteRipper/a.bin"))
        XCTAssertTrue(controller.validateMenuItem(clear), "available with a list to clear")
    }
}
