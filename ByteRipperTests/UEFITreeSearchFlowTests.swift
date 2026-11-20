import XCTest
import AppPalette
import ToolModuleKit
import UEFIImage
import UEFITool
@testable import UEFIToolUI
@testable import ByteRipper

/// The tree's search in the panel: the bar the magnifier opens, the walk from
/// match to match, and what it opens and shuts on the way
/// (`Design/UEFI_STRUCTURE_TOOL.md`, "Searching the tree").
///
/// Two volumes, each holding a driver named `MyDriver` with two sections, so
/// there is a second match to move on to, a branch to open on the way to each,
/// and one level under every match.
@MainActor
final class UEFITreeSearchFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    private static let keys = ["UEFIStructure.ShowsEmptyPadding", "UEFIStructure.Search.Text",
                               "UEFIStructure.Search.Type", "UEFIStructure.Search.Subtype",
                               "UEFIStructure.Search.IsOpen"]

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
        Self.keys.forEach { ToolPanelFont.defaults.removeObject(forKey: $0) }
        ToolPanelFont.defaults.set(true, forKey: "UEFIStructure.ShowsEmptyPadding")
    }

    override func tearDown() {
        Self.keys.forEach { ToolPanelFont.defaults.removeObject(forKey: $0) }
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// The search of the window's UEFI Structure panel.
    private var search: UEFISearchState {
        let session = controller?.tools.session as? UEFIToolSession
        return (session?.viewController as! UEFIToolViewController).searchState
    }

    private func open(_ bytes: [UInt8]) throws {
        let url = try tempFile(bytes)
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        let session = try XCTUnwrap(controller.tools.session as? UEFIToolSession)
        let parsed = expectation(description: "the UEFI parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window.layoutIfNeeded()
    }

    private var panel: NSView {
        get throws { try XCTUnwrap(controller?.tools.panel) }
    }

    private func outline() throws -> NSOutlineView {
        try XCTUnwrap(descendants(of: try panel, NSOutlineView.self).first)
    }

    private func button(_ tooltip: String) throws -> NSButton {
        try XCTUnwrap(descendants(of: try panel, NSButton.self).first { $0.toolTip == tooltip }, tooltip)
    }

    private func nodeName(atRow row: Int) throws -> String {
        let outline = try outline()
        let id = try XCTUnwrap((outline.item(atRow: row) as? UEFITreeRow)?.id)
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        return try XCTUnwrap(tree.node(id)).name
    }

    private func kinds(of outline: NSOutlineView) -> [UEFINodeKind] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let id = (outline.item(atRow: row) as? UEFITreeRow)?.id else { return nil }
            return controller?.windowModel.pane1.uefiState.tree?.node(id)?.kind
        }
    }

    private func openTheBar() throws {
        try button("Look for a node by its name, its GUID or its type").performClick(nil)
        window?.layoutIfNeeded()
    }

    private func searchForTheDriver() throws {
        // The name section inside each driver carries the name too: a file is
        // what is looked for.
        search.query = UEFITreeQuery(text: "mydriver", type: UEFITypes.Item.file.rawValue)
        try openTheBar()
    }

    private func next() throws { try step(segment: 1) }
    private func previous() throws { try step(segment: 0) }

    /// Presses one of the joined ‹ › arrows the way a click does: the segment
    /// clicked is what the action reads. The control is momentary and keeps
    /// no selection outside a click, so it holds one for the press.
    private func step(segment: Int) throws {
        let arrows = try XCTUnwrap(descendants(of: try panel, NSSegmentedControl.self).first {
            $0.segmentCount == 2 && $0.toolTip(forSegment: 1) == "Go to the next node that matches"
        }, "the ‹ › arrows")
        let tracking = arrows.trackingMode
        arrows.trackingMode = .selectOne
        defer { arrows.trackingMode = tracking }
        arrows.selectedSegment = segment
        XCTAssertEqual(arrows.selectedSegment, segment)
        arrows.sendAction(arrows.action, to: arrows.target)
    }

    /// Waits for the selection to stand on a driver, and the rows to settle.
    private func settle(_ outline: NSOutlineView, rows: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == rows && outline.selectedRow >= 0 },
                      "rows \(outline.numberOfRows), selected \(outline.selectedRow)", file: file, line: line)
    }

    // MARK: - The bar

    func testTheMagnifierOpensTheBarAndTheQueryOutlivesIt() throws {
        try open(UEFITestImage.withTwoVolumes())
        let panel = try panel
        XCTAssertTrue(descendants(of: panel, NSSearchField.self).allSatisfy(\.isHiddenOrHasHiddenAncestor),
                      "shut at first")

        try openTheBar()
        let field = try XCTUnwrap(descendants(of: panel, NSSearchField.self).first)
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
        field.stringValue = "driver"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(search.query.text, "driver")

        try openTheBar()
        XCTAssertTrue(field.isHiddenOrHasHiddenAncestor, "the same button shuts it")
        XCTAssertEqual(search.query.text, "driver", "the query stays")
        XCTAssertFalse(search.isOpen)
    }

    /// ⌘F with the keyboard in the tree opens the tree's search and puts the
    /// cursor in its field, rather than opening the dump's Find bar.
    func testFindInTheTreeOpensTheSearchAndItsField() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        let window = try XCTUnwrap(self.window)
        window.makeFirstResponder(outline)

        // Down the responder chain from the tree, as the menu's ⌘F goes in a
        // key window: the panel answers before the window's own Find.
        XCTAssertTrue(outline.tryToPerform(#selector(MainViewController.findPattern), with: nil))
        XCTAssertTrue(search.isOpen)
        let field = try XCTUnwrap(descendants(of: try panel, NSSearchField.self).first)
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(pumpUntil(2) { (window.firstResponder as? NSText)?.delegate === field },
                      "the cursor is in the field: \(String(describing: window.firstResponder))")
    }

    // MARK: - The find pasteboard

    /// A find pasteboard of the test's own, set before the panel is built:
    /// what another app — or the dump's Find bar — would have written goes
    /// there. Put back when the test ends.
    private func ownFindPasteboard() -> NSPasteboard {
        let saved = FindPasteboard.pasteboard
        let pasteboard = NSPasteboard.withUniqueName()
        FindPasteboard.pasteboard = pasteboard
        addTeardownBlock { @MainActor in
            FindPasteboard.pasteboard = saved
            pasteboard.releaseGlobally()
        }
        return pasteboard
    }

    /// ⌘G with the keyboard in the tree looks for the Mac's find string — a
    /// pattern searched for in the dump, or taken there with ⌘E — and opens
    /// the bar on it.
    func testFindNextInTheTreeLooksForTheFindString() throws {
        let pasteboard = ownFindPasteboard()
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        try XCTUnwrap(window).makeFirstResponder(outline)
        pasteboard.clearContents()
        pasteboard.setString("mydriver", forType: .string)

        XCTAssertTrue(outline.tryToPerform(#selector(MainViewController.findNextMatch), with: nil),
                      "the panel answers before the window")
        XCTAssertTrue(search.isOpen)
        XCTAssertEqual(search.query.text, "mydriver")
        XCTAssertTrue(pumpUntil(5) {
            outline.selectedRow >= 0
                && ((try? self.nodeName(atRow: outline.selectedRow)) ?? "").lowercased().contains("mydriver")
        }, "a match is selected")
    }

    /// And a name searched for here becomes the find string the dump's bar
    /// and other apps read.
    func testANameSearchedForBecomesTheFindString() throws {
        let pasteboard = ownFindPasteboard()
        try open(UEFITestImage.withTwoVolumes())
        try searchForTheDriver()

        try next()

        XCTAssertEqual(pasteboard.string(forType: .string), "mydriver")
    }

    /// Opening the bar does not fill a query that asks for a type alone: an
    /// empty text there is a choice, and only a find string new to the bar
    /// replaces it.
    func testOpeningTheBarLeavesASearchByTypeAlone() throws {
        let pasteboard = ownFindPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("left over", forType: .string)
        try open(UEFITestImage.withTwoVolumes())
        search.query = UEFITreeQuery(type: UEFITypes.Item.volume.rawValue)

        try openTheBar()

        XCTAssertEqual(search.query.text, "")
        XCTAssertEqual(search.query.type, UEFITypes.Item.volume.rawValue)
    }

    func testTheTypeAndSubtypeAreKeptAsCodes() throws {
        try open(UEFITestImage.withTwoVolumes())
        try openTheBar()
        let popUps = descendants(of: try panel, NSPopUpButton.self)
        let type = try XCTUnwrap(popUps.first { $0.toolTip == "Only nodes of this type" })
        let subtype = try XCTUnwrap(popUps.first { $0.toolTip == "Only files or sections of this kind" })
        XCTAssertFalse(subtype.isEnabled, "no subtypes without a file or a section")

        type.selectItem(withTitle: "File")
        _ = type.target?.perform(type.action, with: type)
        XCTAssertEqual(search.query.type, UEFITypes.Item.file.rawValue)
        XCTAssertTrue(subtype.isEnabled)

        subtype.selectItem(withTitle: "Driver")
        _ = subtype.target?.perform(subtype.action, with: subtype)
        XCTAssertEqual(search.query.subtype, 0x07)

        type.selectItem(withTitle: "Volume")
        _ = type.target?.perform(type.action, with: type)
        XCTAssertNil(search.query.subtype, "a subtype goes with its type")
        XCTAssertFalse(subtype.isEnabled)
    }

    // MARK: - The walk

    /// The first match opens the way to it and one level under it, and is
    /// selected: the volume, then the driver and its two sections.
    func testTheMatchIsSelectedWithOneLevelUnderIt() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        try searchForTheDriver()

        try next()
        // volume, driver, its sections and their padding, free space, second volume.
        settle(outline, rows: 8)
        XCTAssertEqual(try nodeName(atRow: outline.selectedRow), "MyDriver")
        XCTAssertEqual(outline.selectedRow, 1)
        XCTAssertEqual(kinds(of: outline),
                       [.volume, .file, .section, .padding, .section, .padding, .freeSpace, .volume])
    }

    /// Moving on shuts the volume and the driver the search opened for the
    /// last match, and opens the second volume — and coming round to the
    /// first match again shuts the second.
    func testMovingOnShutsWhatTheSearchOpenedAndComesRound() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        try searchForTheDriver()
        try next()
        settle(outline, rows: 8)

        try next()
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 8 && outline.selectedRow == 2 },
                      "the first volume is shut, the second open: \(outline.numberOfRows) rows, selected \(outline.selectedRow)")
        XCTAssertEqual(kinds(of: outline),
                       [.volume, .volume, .file, .section, .padding, .section, .padding, .freeSpace])
        XCTAssertEqual(try nodeName(atRow: 2), "MyDriver")

        try next()
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 8 && outline.selectedRow == 1 },
                      "round to the first again: \(outline.numberOfRows) rows, selected \(outline.selectedRow)")
        XCTAssertEqual(kinds(of: outline),
                       [.volume, .file, .section, .padding, .section, .padding, .freeSpace, .volume])
    }

    func testPreviousGoesTheOtherWay() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        try searchForTheDriver()

        try previous()    // from nothing: the last match, in the second volume
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow >= 0 && outline.numberOfRows == 8 })
        XCTAssertEqual(try nodeName(atRow: outline.selectedRow), "MyDriver")
        XCTAssertEqual(outline.selectedRow, 2, "behind the first volume, shut")
        XCTAssertEqual(Array(kinds(of: outline).prefix(2)), [.volume, .volume])
    }

    /// A branch the reader opened is theirs: the search goes through it and
    /// leaves it open.
    func testARowTheReaderOpenedStaysOpen() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        let opened = expectation(description: "branch")
        tree.expand(NodeID([0, 0])) { _ in opened.fulfill() }
        wait(for: [opened], timeout: 5)
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual(outline.numberOfRows, 5, "the first volume, opened by the reader")

        try searchForTheDriver()
        try next()
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow == 1 && outline.numberOfRows == 8 })
        try next()
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow == 5 && outline.numberOfRows == 11 },
                      "second volume's driver: \(outline.numberOfRows) rows, selected \(outline.selectedRow)")
        XCTAssertTrue(outline.isItemExpanded(outline.item(atRow: 0)), "the volume the reader opened stays open")
    }

    /// Shutting the branch the match is in takes the selection away, not the
    /// place: the next search goes on from the match, not from the top.
    func testShuttingTheMatchsBranchKeepsThePlace() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        try searchForTheDriver()
        try next()
        settle(outline, rows: 8)

        outline.collapseItem(outline.item(atRow: 0))
        XCTAssertEqual(outline.selectedRow, -1, "the selection went with the branch")
        try next()
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow == 2 && outline.numberOfRows == 8 },
                      "on to the second driver: \(outline.numberOfRows) rows, selected \(outline.selectedRow)")
        XCTAssertEqual(Array(kinds(of: outline).prefix(3)), [.volume, .volume, .file])
    }

    /// A click elsewhere ends the search's claim on what it opened.
    func testAClickElsewhereLeavesTheTreeAsItIs() throws {
        try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()
        try searchForTheDriver()
        try next()
        settle(outline, rows: 8)

        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try next()
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow >= 0 && (try? self.nodeName(atRow: outline.selectedRow)) == "MyDriver" })
        XCTAssertTrue(outline.isItemExpanded(outline.item(atRow: 0)),
                      "the volume the search opened is the reader's now")
    }

    /// The stop button stands beside the progress bar while a search runs,
    /// and with it is out of sight before the first search and after one.
    func testTheStopButtonShowsOnlyWithTheProgressBar() throws {
        try open(UEFITestImage.withTwoVolumes())
        try openTheBar()
        let stop = try button("Stop reading branches to look for a match")
        let bar = try XCTUnwrap(descendants(of: try panel, NSProgressIndicator.self).first)
        XCTAssertTrue(stop.isHidden, "no stop button before a search")
        XCTAssertTrue(bar.isHidden)
    }

    func testNothingFoundSaysSo() throws {
        try open(UEFITestImage.withTwoVolumes())
        search.query = UEFITreeQuery(text: "no such node")
        try openTheBar()
        try next()
        XCTAssertTrue(pumpUntil(5) { shownTexts(try! self.panel).contains("Not found") },
                      "the bar says it")
        let said = try XCTUnwrap(descendants(of: try panel, NSTextField.self).first { $0.stringValue == "Not found" })
        XCTAssertEqual(said.textColor, SemanticColors.bad, "in red, as the dump's Find bar says it")
        XCTAssertEqual(try outline().selectedRow, -1, "the selection is not moved")
    }

    /// A part's panel opens with its bar shut, whatever the window's panel
    /// shows, and what is opened, shut, asked for or scoped in either stays
    /// in it: no panel follows another's search.
    func testAPartsSearchStartsShutAndIsItsOwn() throws {
        try open(UEFITestImage.withTwoVolumes())
        let controller = try XCTUnwrap(self.controller)
        let session = try XCTUnwrap(controller.tools.session as? UEFIToolSession)
        search.query = UEFITreeQuery(text: "mydriver")
        search.content = .init(text: "GH51G", wholeTree: true)
        try openTheBar()
        let field = try XCTUnwrap(descendants(of: try panel, NSSearchField.self).first)
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)

        let tree = try XCTUnwrap(controller.windowModel.pane1.uefiState.tree)
        let volume = try XCTUnwrap(tree.image().allNodes.first { $0.kind == .volume })
        session.openNodeInPanel(for: volume.id, body: false)
        XCTAssertTrue(pumpUntil(2) { controller.fragments.expanded != nil }, "the panel is raised")
        let id = try XCTUnwrap(controller.fragments.expanded)
        defer { controller.fragments.close(id, animated: false) }
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertTrue(pumpUntil(5) { surface.tools.session is UEFIToolSession && surface.tools.panel != nil })
        let partPanel = try XCTUnwrap(surface.tools.panel)
        partPanel.layoutSubtreeIfNeeded()
        let partField = try XCTUnwrap(descendants(of: partPanel, NSSearchField.self).first)
        XCTAssertTrue(partField.isHiddenOrHasHiddenAncestor, "a part's bar starts shut")

        let magnifier = try XCTUnwrap(descendants(of: partPanel, NSButton.self).first {
            $0.toolTip == "Look for a node by its name, its GUID or its type"
        })
        magnifier.performClick(nil)
        XCTAssertFalse(partField.isHiddenOrHasHiddenAncestor, "the part's button opens its bar")
        magnifier.performClick(nil)
        XCTAssertTrue(partField.isHiddenOrHasHiddenAncestor, "and shuts it")
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor, "the window's bar stays open")
        XCTAssertTrue(search.isOpen)

        magnifier.performClick(nil)
        try openTheBar()
        XCTAssertTrue(field.isHiddenOrHasHiddenAncestor, "the window's bar shuts")
        XCTAssertFalse(partField.isHiddenOrHasHiddenAncestor, "the part's stays open")
        try openTheBar()

        let partSession = try XCTUnwrap(surface.tools.session as? UEFIToolSession)
        let partSearch = try XCTUnwrap(partSession.viewController as? UEFIToolViewController).searchState
        partSearch.query = UEFITreeQuery(text: "elsewhere", type: UEFITypes.Item.volume.rawValue)
        partSearch.mode = .contents
        partSearch.content = .init(text: "OTHER", wholeTree: false)
        XCTAssertEqual(search.query, UEFITreeQuery(text: "mydriver"), "the window's query stays")
        XCTAssertEqual(search.mode, .names, "and its mode")
        XCTAssertEqual(search.content, .init(text: "GH51G", wholeTree: true), "and its scope")
        XCTAssertEqual(field.stringValue, "mydriver", "and its field")

        search.content = .init(text: "GH51G", wholeTree: false)
        XCTAssertEqual(partSearch.content, .init(text: "OTHER", wholeTree: false))
        search.query = UEFITreeQuery(text: "again")
        XCTAssertEqual(partSearch.query.text, "elsewhere", "nor does the part follow the window")
    }

    func testTheBarShowsItsPanelsQuery() throws {
        try open(UEFITestImage.withTwoVolumes())
        try openTheBar()
        search.query = UEFITreeQuery(text: "elsewhere")
        let field = try XCTUnwrap(descendants(of: try panel, NSSearchField.self).first)
        XCTAssertEqual(field.stringValue, "elsewhere", "a change of the panel's search is shown")
    }
}
