import Cocoa
import IntelCPUID
import ToolModuleKit
import XCTest
@testable import ByteRipper

/// Window ▸ Intel CPUID Lookup, over the fixture tables: what a query shows,
/// what is offered and remembered, and that the window reads the store the
/// FIT panel reads.
@MainActor
final class CPUIDLookupWindowTests: XCTestCase {
    private var controller: CPUIDLookupWindowController!
    private var defaultsName: String?

    private var lookup: CPUIDLookupViewController { controller.lookupController }

    override func setUp() async throws {
        try await super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        CPUIDLookupViewController.defaults = isolated.store
        CPUIDLookupViewController.rememberDelay = 3600
        FixtureProcessorTables.use()
        controller = CPUIDLookupWindowController()
        _ = lookup.view
    }

    override func tearDown() async throws {
        controller.window?.orderOut(nil)
        controller.lookupController.closeSuggestions()
        controller = nil
        if let defaultsName { discardIsolatedDefaults(defaultsName, CPUIDLookupViewController.defaults) }
        CPUIDLookupViewController.defaults = .standard
        CPUIDLookupViewController.rememberDelay = 2
        FixtureProcessorTables.restore()
        try await super.tearDown()
    }

    /// Before anything is typed every model is listed, and the line counts them.
    func testAnEmptyQueryListsTheWholeTable() {
        XCTAssertEqual(lookup.shown.count, CPUIDLookup(tables: FixtureProcessorTables.tables).rows.count)
        XCTAssertTrue(lookup.statusLabel.stringValue.contains("CPUID"))
        XCTAssertTrue(lookup.headingScroll.isHidden)
    }

    /// An S-SPEC finds its model, and the table shows it.
    func testAnSSpecFindsItsModel() {
        lookup.setQuery("SR3Z0")
        XCTAssertEqual(lookup.shown.count, 1)
        XCTAssertEqual(lookup.shown.first?.cpuids, ["906EA"])
        XCTAssertEqual(lookup.tableView.numberOfRows, 1)
        XCTAssertEqual(lookup.statusLabel.stringValue, "Found: 1")
    }

    /// A CPUID typed whole is headed by its entry and the microcode it
    /// shares; one with no models gives the window to the heading.
    func testACPUIDIsHeadedByItsEntry() throws {
        lookup.setQuery("B06F5")
        XCTAssertFalse(lookup.headingScroll.isHidden)
        let heading = lookup.headingView.string
        XCTAssertTrue(heading.contains("Raptor Lake"))
        XCTAssertTrue(heading.contains("90672"), "the CPUIDs its microcode also serves")
        XCTAssertFalse(lookup.tableScroll.isHidden)

        let modelless = try XCTUnwrap(FixtureProcessorTables.tables.families.first {
            $0.processors.isEmpty && $0.cpuids.count == 1 && !$0.cpuids[0].contains("X")
        })
        lookup.setQuery(modelless.cpuids[0])
        XCTAssertTrue(lookup.shown.isEmpty)
        XCTAssertTrue(lookup.tableScroll.isHidden, "no models: the heading is all there is")
        XCTAssertEqual(lookup.statusLabel.stringValue,
                       "No models are listed for this CPUID. What is known about it is above.")
    }

    /// A search that found something is remembered, and replaces what was
    /// typed on the way to it; one that found nothing is not.
    func testSearchesAreRememberedWhenTheyFindSomething() throws {
        lookup.searchField.stringValue = "SR3Z"
        lookup.render()
        lookup.rememberQuery()
        lookup.setQuery("SR3Z0")
        lookup.setQuery("nosuchprocessor")
        XCTAssertEqual(lookup.history, ["SR3Z0"])
        let menu = try XCTUnwrap(lookup.searchField.searchMenuTemplate, "the magnifier offers them")
        XCTAssertEqual(menu.items.map(\.title), ["Recent Queries", "SR3Z0", "", "Clear Recents"],
                       "drawn as the Find bar's menu is")
        lookup.clearHistory()
        XCTAssertTrue(lookup.history.isEmpty)
        XCTAssertNil(lookup.searchField.searchMenuTemplate, "nothing to list, no menu")
    }

    /// Copy puts the selected rows on the pasteboard, a line each.
    func testCopyPutsTheRowsOnThePasteboard() {
        lookup.setQuery("SR3Z0")
        lookup.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        lookup.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.hasPrefix("906EA\t"))
        XCTAssertTrue(copied.contains("SR3Z0"))
    }

    /// The window shows what is installed in the one store: a table that
    /// lands while it is open is searched at once.
    func testANewTableIsSearchedAtOnce() {
        lookup.setQuery("SR3Z0")
        XCTAssertEqual(lookup.shown.count, 1)
        ProcessorTables.install(.empty)
        let emptied = expectation(description: "the window follows the store")
        DispatchQueue.main.async { emptied.fulfill() }
        wait(for: [emptied], timeout: 2)
        XCTAssertTrue(lookup.shown.isEmpty)
        XCTAssertTrue(lookup.statusLabel.stringValue.hasPrefix("The table has not been read yet"))
    }

    /// View ▸ Zoom reaches the table: its rows and columns grow with the size.
    func testTheTableFollowsTheZoom() {
        let key = ToolPanelFont.zoomSizeKey
        let saved = ToolPanelFont.defaults.object(forKey: key)
        defer {
            ToolPanelFont.defaults.set(saved, forKey: key)
            NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        }
        let rowHeight = lookup.tableView.rowHeight
        let width = lookup.tableView.tableColumns[1].width
        ToolPanelFont.defaults.set(ToolPanelFont.size + 4, forKey: key)
        NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(lookup.tableView.rowHeight, rowHeight)
        XCTAssertGreaterThan(lookup.tableView.tableColumns[1].width, width)
    }

    /// Its `?` opens its page.
    func testHelpOpensTheLookupPage() {
        XCTAssertEqual(lookup.help.opens, .topic(.cpuidLookup))
    }
}
