import XCTest
import ALSplitView
import AppPalette
import FITToolUI
import ToolModuleKit
import UEFIImage
import UEFITool
@testable import UEFIToolUI
import MEFirmware
@testable import ByteRipper

/// The UEFI Structure tool-module end to end in the app: a real FFSv2 volume in
/// a real image, the tree it parses, the one zone a selection publishes, and the
/// trip back from a zone to its row (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// It drives the module's own controls rather than its session, so what is
/// tested is what a user can reach.
@MainActor
final class UEFIToolFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    /// A data source whose database fetch fails the way an offline one does.
    /// Installed for the whole class so no test here can reach the network: the
    /// ME analyses these tests drive are handed a cached analysis instead
    /// (`setCachedMEAnalysis`), and the one that is not expects the reading to
    /// fail — the fixture's ME region is erased, so there is nothing to parse.
    private struct OfflineDatabaseSource: MEADataSource {
        func database() async throws -> MEADatabase {
            throw MEADataError.offline(underlying: "test offline")
        }
    }

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
        UEFIToolSession.dataSource = OfflineDatabaseSource()
        // The test volume's rows include the erased padding that aligns its
        // free space, and these tests count and index rows with it there: the
        // tree lists it here, as a reader who turned it on would see it. The
        // default is tested on its own.
        ToolPanelFont.defaults.set(true, forKey: Self.showsEmptyPaddingKey)
    }

    private static let showsEmptyPaddingKey = "UEFIStructure.ShowsEmptyPadding"

    override func tearDown() {
        ToolPanelFont.defaults.removeObject(forKey: Self.showsEmptyPaddingKey)
        UEFIToolSession.dataSource = MEAGitHubDataRepository()
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

    /// Opens an image and switches the UEFI tool on, waiting for the first parse
    /// — which happens off the main actor — to land.
    private func open(_ bytes: [UInt8]) throws -> MainViewController {
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
        try waitForParse()
        return controller
    }

    /// Waits on the session's own seam rather than on the clock.
    private func waitForParse() throws {
        let session = try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
        let parsed = expectation(description: "the UEFI parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    private func session() throws -> UEFIToolSession {
        try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
    }

    /// What a row stands for. The outline holds `UEFITreeRow` items — a place
    /// in the tree, not a node — so reading a row means asking the tree what
    /// is there, the way the panel does.
    private func node(atRow row: Int) throws -> UEFINode {
        let outline = try outline()
        let id = try XCTUnwrap((outline.item(atRow: row) as? UEFITreeRow)?.id,
                               "row \(row) stands for a node")
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        return try XCTUnwrap(tree.node(id), "the tree still has \(id)")
    }

    private func kinds(of outline: NSOutlineView) -> [UEFINodeKind] {
        (0..<outline.numberOfRows).compactMap { try? node(atRow: $0).kind }
    }

    /// Opens a row's branch. The tree materializes it off the main actor, so
    /// this waits on the tree's own callback rather than on the clock, then
    /// lets the outline show what arrived.
    @discardableResult
    private func expandRow(_ row: Int) throws -> NSOutlineView {
        let outline = try outline()
        let id = try node(atRow: row).id
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        let opened = expectation(description: "the branch is materialized")
        tree.expand(id) { _ in opened.fulfill() }
        wait(for: [opened], timeout: 5)
        outline.expandItem(outline.item(atRow: row))
        window?.layoutIfNeeded()
        return outline
    }

    private func outline() throws -> NSOutlineView {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
    }

    /// The panel's title: the summary line leading with `prefix` — the clickable
    /// handle to the root the tree folded into it.
    private func summary(_ panel: NSView, prefix: String) throws -> NSTextField {
        try XCTUnwrap(descendants(of: panel, NSTextField.self).first {
            $0.stringValue.hasPrefix(prefix)
        })
    }

    /// Opening a row does not widen the tree past its scroll view: the
    /// indentation comes out of the Name column, so the inset style's margins
    /// and rounded selection stay on screen.
    func testOpeningARowKeepsTheTreeInsideItsScrollView() throws {
        _ = try open(UEFITestImage.make())
        let tree = try expandRow(0)
        XCTAssertGreaterThan(tree.numberOfRows, 1, "the premise: a row is open")
        let clip = try XCTUnwrap(tree.enclosingScrollView?.contentView.bounds.width)
        XCTAssertLessThanOrEqual(tree.frame.width, clip + 0.5, "tree \(tree.frame.width), clip \(clip)")
    }

    /// Empty padding is left out of the tree until the reader asks for it,
    /// with the checkbox in the panel's title row — left of the reveal button
    /// — and the choice is remembered.
    func testEmptyPaddingIsListedOnlyWhenAskedFor() throws {
        ToolPanelFont.defaults.removeObject(forKey: Self.showsEmptyPaddingKey)
        _ = try open(UEFITestImage.withTrailingPadding())
        let tree = try outline()
        XCTAssertEqual(kinds(of: tree), [.volume], "the trailing erased padding is not listed")

        let panel = try XCTUnwrap(controller?.tools.panel)
        let toggle = try XCTUnwrap(descendants(of: panel, NSButton.self).first { $0.title == "Show Empty Padding" },
                                   "the checkbox in the title row")
        let reveal = try XCTUnwrap(descendants(of: panel, NSButton.self).first {
            $0.toolTip == "Show the node under the caret in the tree"
        })
        let inPanel = { (view: NSView) in view.convert(view.bounds, to: panel) }
        XCTAssertLessThan(inPanel(toggle).maxX, inPanel(reveal).minX, "left of the reveal button")
        XCTAssertEqual(inPanel(toggle).midY, inPanel(reveal).midY, accuracy: 3, "on the title row")
        XCTAssertEqual(toggle.state, .off)

        toggle.performClick(nil)
        window?.layoutIfNeeded()

        XCTAssertEqual(kinds(of: tree), [.volume, .padding])
        XCTAssertEqual(ToolPanelFont.defaults.bool(forKey: Self.showsEmptyPaddingKey), true, "remembered")
    }

    /// It is in the shipping app, not only in the tests.
    func testTheAppShipsIt() {
        XCTAssertTrue(
            ToolRegistry.builtIn.contains { $0.identifier == UEFIToolModule.identifier },
            "the registry ships the UEFI Structure tool"
        )
    }

    /// A parse that has landed but a node nobody has chosen yet draws nothing:
    /// the map is empty, and that is the honest state.
    func testNothingSelectedDrawsNoZone() throws {
        _ = try open(UEFITestImage.make())
        XCTAssertTrue(controller?.windowModel.pane1.zones.zones.isEmpty ?? false,
                      "no selection means no zone")
    }

    /// The tree the parser built is the tree the outline shows, and picking a
    /// node publishes that node and what is inside it — the node's whole range
    /// and its body — with the body in focus. Nothing else: not its header as
    /// a zone of its own, not its children, not its neighbours.
    func testSelectingANodePublishesItsBody() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()

        // The volume is the one root of the whole file and keeps its row; its
        // files are not read until something opens it.
        XCTAssertEqual(outline.numberOfRows, 1, "only the top level is read")
        XCTAssertEqual(outline.selectedRow, -1, "nothing chosen yet")

        // Opened, it shows the file, the padding that aligns it and the free
        // space — and the file is the first of them.
        try expandRow(0)
        XCTAssertEqual(outline.numberOfRows, 4, "the volume and its three children")
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        // The file is 0x48..<0x8C: a 0x18-byte FFS header, then its sections.
        let zones = controller.windowModel.pane1.zones
        XCTAssertEqual(zones.zones.map(\.id), ["0.0", "0.0#body"])
        XCTAssertEqual(zones.zones.map(\.range), [0x48..<0x8C, 0x60..<0x8C])
        XCTAssertEqual(zones.focus, "0.0#body",
                       "the body is what the node holds — that is the one drawn "
                       + "as the focus")
    }

    /// The trip back: picking a zone in the dump brings its row to the front
    /// of the tree. The bytes are selected by the host; the row is the half
    /// only the tool-module can do.
    ///
    /// A byte now sits in two of the node's zones — the node and the part it
    /// fell in — so the menu offers both, innermost first, and either of them
    /// leads to the same row.
    func testPickingAZoneInTheDumpSelectsItsRow() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let pane = controller.windowModel.pane1

        // Publish the file's zones by selecting it — the file is the volume's
        // first child, so the volume is opened first — then pick one back in
        // the dump the way the right-click menu does.
        try expandRow(0)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        // 0x60 is the first byte of the file's body (the file is 0x48..<0x8C).
        let menu = controller.makeOffsetMenu(for: pane, offset: 0x60)
        let parent = try XCTUnwrap(menu.items.first { $0.title == "Select Zone" })
        let submenu = try XCTUnwrap(parent.submenu, "two zones cover the byte")
        XCTAssertEqual(submenu.items.map(\.title), ["MyDriver body", "MyDriver"],
                       "the innermost zone is offered first")

        controller.selectZone(submenu.items[0])
        XCTAssertEqual(pane.zones.focus, "0.0#body")
        XCTAssertEqual(outline.selectedRow, 1)
        var selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x60..<0x8C,
                       "the body's bytes, not the whole file's")

        // The node's own zone from the same menu: the same row, the whole of it.
        controller.selectZone(submenu.items[1])
        XCTAssertEqual(outline.selectedRow, 1)
        selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x48..<0x8C)
    }

    /// The title-row button's half of the trip the zone menu makes the other
    /// way: a caret deep in the dump brings the node that owns that byte to the
    /// front of the tree. No zone needs to have been published first — the
    /// caret can sit in a node the panel is not showing at all.
    func testRevealingTheNodeUnderTheCaretSelectsItsRow() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let pane = controller.windowModel.pane1

        XCTAssertEqual(outline.selectedRow, -1, "nothing chosen before the reveal")

        // 0x4A is inside the file's own header (0x48..<0x60): no child of the
        // file begins before its body at 0x60, so the innermost node over it is
        // the file itself.
        pane.moveCaret(to: 0x4A)
        try session().revealNodeAtCaret()

        // The branch the caret sits in may not have been read yet, and the row
        // it opens into is animated in behind whatever the table is doing — so
        // this waits for the panel to settle rather than for the call to
        // return.
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow >= 0 },
                      "the reveal selected a row")
        XCTAssertEqual(try node(atRow: outline.selectedRow).id.description, "0.0",
                       "the file under the caret is the row shown")
    }

    /// The same reveal into a branch that has already been read.
    ///
    /// Nothing is left to read there, so nothing else will redraw the table
    /// afterwards — which makes this the case that says whether the reveal
    /// selects the row *itself*. It opens the row and then selects it, and a
    /// selection made before the opening has had its turn selects nothing.
    func testRevealingIntoAnAlreadyReadBranchStillSelectsItsRow() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let pane = controller.windowModel.pane1

        // Read the branch *and* let the checksum pass it starts land, so
        // there is nothing left in flight that would redraw the table after
        // the reveal and select the row on its behalf.
        let panel = try session()
        let checked = expectation(description: "the branch's checksums are read")
        checked.assertForOverFulfill = false
        panel.onChecksums = { checked.fulfill() }
        try expandRow(0)
        wait(for: [checked], timeout: 5)
        panel.onChecksums = nil

        outline.collapseItem(outline.item(atRow: 0))
        window?.layoutIfNeeded()
        XCTAssertEqual(outline.numberOfRows, 1, "the volume alone again")

        pane.moveCaret(to: 0x4A)
        try session().revealNodeAtCaret()

        // As soon as the rows it opened are there, the row is selected: the
        // selection happens inside the same change to the table, not in some
        // later redraw that happens to come along.
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 4 },
                      "the reveal opened the tree to the file")
        XCTAssertEqual(try node(atRow: outline.selectedRow).id.description, "0.0",
                       "and selected it in the same breath")
    }

    /// Revealing answers with the tree and nothing else: the dump is where the
    /// user is standing, so a selection's start picks the node but the
    /// published zones and the selection itself are left exactly as they were —
    /// no republish scrolls the caret away from the byte it asked about.
    func testRevealingUnderASelectionLeavesTheDumpAlone() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let pane = controller.windowModel.pane1

        XCTAssertTrue(pane.zones.zones.isEmpty, "the parse publishes nothing yet")
        pane.select(range: 0x4A..<0x4C)
        try session().revealNodeAtCaret()

        XCTAssertTrue(pumpUntil(5) { outline.selectedRow >= 0 },
                      "the reveal selected a row")
        XCTAssertEqual(try node(atRow: outline.selectedRow).id.description, "0.0",
                       "the node under the selection's start is shown")
        // The dump has not moved: the map is still empty and the bytes the
        // reveal read from are still the ones selected.
        XCTAssertTrue(pane.zones.zones.isEmpty, "no zone was published")
        XCTAssertEqual(pane.zones.focus, nil)
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x4A..<0x4C,
                       "the selection the reveal answered is untouched")
    }

    /// After a reveal the row it chose is selected but its zone is not
    /// published — that is the reveal's point. A normal click on that row is
    /// how the user then asks for the zone, and it has to work exactly like a
    /// click that moved the selection would: publishing the row's zone. AppKit
    /// reports only selection *changes*, and this click changes none, so the
    /// outline itself notices it.
    func testAClickOnTheRowARevealChosePublishesItsZone() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let pane = controller.windowModel.pane1
        let window = try XCTUnwrap(self.window)

        pane.moveCaret(to: 0x4A)
        try session().revealNodeAtCaret()
        XCTAssertTrue(pumpUntil(5) { outline.selectedRow >= 0 },
                      "the reveal selected a row")
        XCTAssertEqual(try node(atRow: outline.selectedRow).id.description, "0.0",
                       "the reveal chose the file's row")
        XCTAssertTrue(pane.zones.zones.isEmpty, "a reveal publishes nothing")

        // A real click on the selected row — inside the name column, past the
        // disclosure triangle, so the mouse down is not the fold/unfold click.
        let rect = outline.rect(ofRow: outline.selectedRow)
        let point = outline.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
        outline.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))

        let zones = pane.zones
        XCTAssertEqual(zones.zones.map(\.id), ["0.0", "0.0#body"],
                       "the click committed the row's zone")
        XCTAssertEqual(zones.focus, "0.0#body")
    }

    /// The file is a lone FFSv2 volume off a chip — the parser invents no image
    /// root around a single top, the volume *is* the root — and a real root
    /// keeps its row. Opening the panel reads the top level and nothing else;
    /// the volume's files arrive when somebody opens it, and the row they came
    /// from stays where it was.
    func testALoneVolumeKeepsItsRowAndOpensOnDemand() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        XCTAssertEqual(outline.numberOfRows, 1, "the top level is the volume alone")
        let root = try node(atRow: 0)
        XCTAssertEqual(root.kind, .volume)
        XCTAssertTrue(root.isExpandable, "its files have not been read yet")
        XCTAssertTrue(outline.isExpandable(try XCTUnwrap(outline.item(atRow: 0))),
                      "and the tree offers to read them")

        // The title says what the image is and stands for no row of its own,
        // so it is not a handle to anything.
        let title = try summary(panel, prefix: "Volume · FFSv2")
        XCTAssertNil(title.toolTip)

        try expandRow(0)

        XCTAssertEqual(kinds(of: outline), [.volume, .file, .padding, .freeSpace],
                       "the volume kept its row and its children came in under it")
    }

    /// A wrapper root — the "UEFI image" the parser groups several tops under —
    /// does no work as a row, so it folds into the title: clicking the title
    /// behaves exactly like a click on that root's row would, its zones and its
    /// detail. It has no row, so nothing in the tree is selected, and the title
    /// itself reads as selected.
    func testClickingTheTitleSelectsTheFoldedRoot() throws {
        let controller = try open(UEFITestImage.withTrailingPadding())
        let pane = controller.windowModel.pane1
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        // The title is the summary label, and it is the one thing in the panel
        // that is clickable.
        let title = try summary(panel, prefix: "UEFI image")
        XCTAssertTrue(
            title.gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer }),
            "the title must be clickable"
        )

        // A click on a label cannot be simulated the way a button's can, so
        // this drives what the click calls.
        try session().showTopNode()

        // The folded root spans the whole file, and its body is the whole of it
        // too — an invented wrapper has no header of its own, so there is one
        // zone rather than two.
        XCTAssertEqual(pane.zones.zones.map(\.id), ["0"])
        XCTAssertEqual(pane.zones.zones.map(\.range), [0..<0x2000])
        XCTAssertEqual(pane.zones.focus, "0")
        XCTAssertEqual(outline.selectedRow, -1, "the folded root has no row to select")
        XCTAssertEqual(kinds(of: outline), [.volume, .padding],
                       "the wrapper's children are the top of the tree")

        // The detail says the node in focus spans the whole file.
        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("0x0 · 0x2000 (8192) bytes"), "\(text)")
        XCTAssertEqual(title.textColor, .controlAccentColor,
                       "the folded-away root reads as selected in the title")
    }

    /// A row opens once, when its branch is there — not first onto a
    /// "Loading…" row and again a few milliseconds later.
    ///
    /// Two structural changes over the same rows is two animations over them,
    /// the second landing inside the first, and what that looks like is the
    /// whole table rippling. So a click on a branch nobody has read starts the
    /// reading and leaves the row shut; the row opens when there is something
    /// in it, and stays open.
    func testARowOpensOnceWhenItsBranchIsThere() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()

        // A click on the disclosure triangle. The branch has not been read, so
        // nothing opens yet — and nothing stands in for it either.
        outline.expandItem(outline.item(atRow: 0))
        window?.layoutIfNeeded()
        XCTAssertEqual(outline.numberOfRows, 1, "the row waits rather than opening onto nothing")

        // The branch lands — the same reading the click started, coalesced.
        // The panel's own callback was registered first, so by the time this
        // one runs the row is open.
        // The panel opens the row itself, animated and behind whatever the
        // table is already moving, so this waits for it to settle rather than
        // for the branch alone.
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 4 },
                      "the row opened with its children in it: "
                      + "\(outline.numberOfRows) rows")
        XCTAssertEqual(kinds(of: outline), [.volume, .file, .padding, .freeSpace])
    }

    /// The click and nothing else: no second caller waiting on the branch, the
    /// way the app has it.
    func testAClickAloneOpensTheRow() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()

        outline.expandItem(outline.item(atRow: 0))
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 4 },
                      "the row opened on its own: \(outline.numberOfRows) rows")
    }

    /// The same click down the *slow* path — the one that puts a "Loading…"
    /// row up first. The row still ends up open.
    ///
    /// The panel opens that row itself, which means asking its own
    /// `shouldExpandItem` again; a guard that refuses a branch not yet read
    /// refuses this too, and then the branch never opens at all — the reader
    /// clicks, nothing happens, and only a second click works.
    func testASlowBranchOpensThroughItsLoadingRow() throws {
        UEFIToolModule.loadingRowDelay = 0
        defer { UEFIToolModule.loadingRowDelay = 0.2 }

        _ = try open(UEFITestImage.make())
        let outline = try outline()

        outline.expandItem(outline.item(atRow: 0))
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 4 },
                      "the row opened: \(outline.numberOfRows) rows")
        XCTAssertEqual(kinds(of: outline), [.volume, .file, .padding, .freeSpace])
    }

    /// Two branches opened at once both come out right.
    ///
    /// An outline recognises its items by object and holds a map from each one
    /// to its parent, so anything shared between two branches — a placeholder,
    /// a row — is one object in two places at once, which is a tree it cannot
    /// lay out. What that looks like on screen is rows shuffling through each
    /// other.
    func testTwoBranchesOpenedAtOnceBothComeOutRight() throws {
        let controller = try open(UEFITestImage.withTwoVolumes())
        let outline = try outline()

        XCTAssertEqual(outline.numberOfRows, 2, "two volumes at the top")
        outline.expandItem(outline.item(atRow: 0))
        outline.expandItem(outline.item(atRow: 1))
        window?.layoutIfNeeded()

        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 8 },
                      "both rows opened: \(outline.numberOfRows) rows")

        XCTAssertEqual(kinds(of: outline),
                       [.volume, .file, .padding, .freeSpace,
                        .volume, .file, .padding, .freeSpace],
                       "each volume kept its own children under itself")
        // And every row is its own object, standing for its own place.
        let ids = (0..<outline.numberOfRows).compactMap {
            (outline.item(atRow: $0) as? UEFITreeRow)?.id
        }
        XCTAssertEqual(ids.count, outline.numberOfRows)
        XCTAssertEqual(Set(ids).count, ids.count, "no path is drawn twice: \(ids)")
        _ = controller
    }

    /// Coming back to the panel finds the tree as it was left.
    ///
    /// The panel is built again on every activation, so its own memory of what
    /// was open goes with the old one — but what was open is about the *file*,
    /// and the branches are still read. A reader who opens a volume, goes to
    /// another panel and comes back should not have to open it again.
    func testTheRowsLeftOpenAreOpenAgainOnComingBack() throws {
        let controller = try open(UEFITestImage.make())
        try expandRow(0)
        XCTAssertEqual(try outline().numberOfRows, 4, "the volume is open")

        // Away to the FIT panel and back — a new session, a new outline.
        controller.tools.activate(FITToolModule.identifier, animated: false)
        window?.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window?.layoutIfNeeded()
        try waitForParse()

        let outline = try outline()
        XCTAssertTrue(pumpUntil(5) { outline.numberOfRows == 4 },
                      "the row is open again: \(outline.numberOfRows) rows")
        XCTAssertEqual(kinds(of: outline), [.volume, .file, .padding, .freeSpace])
    }

    /// And a row the reader *shut* stays shut.
    func testARowShutBeforeLeavingIsShutOnComingBack() throws {
        let controller = try open(UEFITestImage.make())
        let first = try outline()
        try expandRow(0)
        first.collapseItem(first.item(atRow: 0))
        window?.layoutIfNeeded()
        XCTAssertEqual(first.numberOfRows, 1, "the volume is shut")

        controller.tools.activate(FITToolModule.identifier, animated: false)
        window?.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window?.layoutIfNeeded()
        try waitForParse()

        let outline = try outline()
        XCTAssertEqual(outline.numberOfRows, 1,
                       "nothing was put back that the reader had closed")
    }

    /// The point of a tree shared per file: what one tool-module opened, the
    /// next one finds open. Switching panels re-reads nothing.
    func testABranchOpenedStaysOpenAcrossAPanelSwitch() throws {
        let controller = try open(UEFITestImage.make())
        try expandRow(0)
        XCTAssertEqual(try outline().numberOfRows, 4, "the volume is open")

        // Away to the FIT panel — which reads the same tree — and back.
        controller.tools.activate(FITToolModule.identifier, animated: false)
        window?.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window?.layoutIfNeeded()
        try waitForParse()

        let tree = try XCTUnwrap(controller.windowModel.pane1.uefiState.tree)
        let root = try XCTUnwrap(tree.rootNodes.first)
        XCTAssertFalse(root.children.isEmpty,
                       "the branch the first session opened is still open")
        XCTAssertFalse(root.isExpandable,
                       "so the second session has nothing left to read there")
    }

    /// A file with no root to fold — one that is a single leaf, padding the
    /// whole file — shows that leaf as its one row and hides nothing. The title
    /// has nothing to select, so clicking it does nothing rather than clear a
    /// focus the user set.
    func testTheTitleDoesNothingWhenThereIsNothingToFold() throws {
        let controller = try open([UInt8](repeating: 0xFF, count: 0x1000))
        let outline = try outline()
        let pane = controller.windowModel.pane1

        // Select the one padding row, so there is a focus to keep.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(pane.zones.focus, "0")

        try session().showTopNode()

        XCTAssertEqual(pane.zones.focus, "0",
                       "nothing is hidden in the title, so the click leaves the "
                       + "selection alone")
    }

    /// The bottom of the panel says what the node in focus is, by its type: a
    /// volume by its file system and length, a file by its type and state.
    /// A row's text sits down the middle of the row. The tree is view-based
    /// for that reason: `objectValueFor` is the cell-based path, and an
    /// `NSTextFieldCell` draws its text against the top of the row, which
    /// reads as every row in the tree sitting too high.
    ///
    /// This also guards the focus ring, which is why there is no test of its
    /// own for that. A cell-based table draws a ring around the whole of
    /// itself when it takes focus — `NSCell`-era behaviour — while a
    /// view-based one leaves focus to the selection highlight. That ring was
    /// this tree's, and no other table in the project has ever shown one
    /// because no other table was ever cell-based. Asserting
    /// `focusRingType == .none` instead would only have restated a line of
    /// setup; asserting the cell view is the thing that decides.
    /// Name is the column the reader is after — a GUID or a catalogue name —
    /// so it starts wider than Type and Subtype put together, and those two
    /// start no wider than the short words they hold.
    func testNameStartsWiderThanTheTwoTypeColumns() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()

        func width(_ identifier: String) throws -> CGFloat {
            try XCTUnwrap(outline.tableColumn(withIdentifier: .init(identifier))).width
        }
        let name = try width("name")
        let type = try width("type")
        let subtype = try width("subtype")

        XCTAssertGreaterThan(name, type + subtype,
                             "the tree spends its width on the two columns that "
                             + "say one short word each")
        // Wide enough for the longest word each column shows on a normal row
        // ("Free space", "Empty (FFh)"), and not much wider.
        let font = ToolPanelFont.body()
        func rendered(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        XCTAssertGreaterThan(type, rendered("Free space"))
        XCTAssertLessThan(type, rendered("Free space") * 1.5)
        XCTAssertGreaterThan(subtype, rendered("Empty (FFh)"))
        XCTAssertLessThan(subtype, rendered("Empty (FFh)") * 1.5)
    }

    func testATreeRowsTextIsCentredInTheRow() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()

        let cell = try XCTUnwrap(
            outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView,
            "the tree is view-based — cell-based rows have no view here at all"
        )
        let field = try XCTUnwrap(cell.textField, "the cell shows its text in a field")
        // In the cell's own coordinates: the name shares a row with the
        // wrong-checksum warning, so its field is not a direct subview of the
        // cell and its frame is not measured against the cell's bounds.
        let text = field.convert(field.bounds, to: cell)
        let above = text.minY
        let below = cell.bounds.height - text.maxY

        XCTAssertEqual(above, below, accuracy: 1,
                       "\(above) above the text and \(below) below it — the row's "
                       + "text is not centred")
    }

    /// A value too long for the detail's column wraps inside it: a GUID is 36
    /// characters and there is no sideways scroller to reach the rest of one
    /// with.
    func testALongDetailValueWrapsInsideItsColumn() throws {
        _ = try open(UEFITestImage.make())
        let outline = try outline()
        // The top row is the FFS file, whose detail names it by its GUID.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window?.layoutIfNeeded()

        let panel = try XCTUnwrap(controller?.tools.panel)
        // Inside the detail pane, not the tree above it: a tree cell shows the
        // same GUID and truncates it, as a table cell must.
        let splitter = try XCTUnwrap(descendants(of: panel, ALSplitView.self).first)
        let detail = try XCTUnwrap(splitter.panes.last)
        let fields = descendants(of: detail, NSTextField.self)
        let guid = try XCTUnwrap(
            fields.first { $0.stringValue.hasPrefix("8C8CE578-8A3D-4F1C") },
            "the detail names the volume by its file system GUID: "
                + "\(fields.map(\.stringValue))"
        )
        XCTAssertEqual(guid.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(guid.maximumNumberOfLines, 0)
        let inPanel = guid.convert(guid.bounds, to: panel)
        XCTAssertLessThanOrEqual(inPanel.maxX, panel.bounds.maxX,
                                 "the value runs off the side of the panel")
    }

    /// The detail is the lower pane of the splitter, at the panel's full
    /// width and with height of its own. Position, not only height: while the
    /// split was side by side the detail was a zero-width column down the
    /// right-hand edge, which is a panel with no detail at all.
    func testTheDetailPanelIsTheLowerPaneAtFullWidth() throws {
        _ = try open(UEFITestImage.make())
        window?.layoutIfNeeded()

        let panel = try XCTUnwrap(controller?.tools.panel)
        let splitter = try XCTUnwrap(descendants(of: panel, ALSplitView.self).first,
                                     "the panel has a splitter")
        XCTAssertFalse(splitter.isVertical,
                       "the panes are stacked — the tree above, the detail below")
        let outline = try XCTUnwrap(splitter.panes.first, "the upper pane is the tree")
        let detail = try XCTUnwrap(splitter.panes.last as? NSScrollView,
                                   "the lower pane is the detail")

        XCTAssertGreaterThan(detail.frame.height, 60,
                             "the detail has room to show a node's fields")
        XCTAssertEqual(detail.frame.width, splitter.bounds.width, accuracy: 1,
                       "the detail spans the panel rather than a column beside the tree")
        XCTAssertGreaterThanOrEqual(detail.frame.minY, outline.frame.maxY,
                                    "the detail sits below the tree, not beside it")
    }

    /// A first open shows the placeholder where the user is looking. A scroll
    /// view's document is not flipped by default, so it shows the *bottom* of
    /// anything taller than itself: the text used to land below the fold,
    /// clipped, and the panel read as empty until the user scrolled up.
    func testTheDetailPlaceholderIsInsideTheVisibleAreaOnAFirstOpen() throws {
        _ = try open(UEFITestImage.make())
        let panel = try XCTUnwrap(controller?.tools.panel)

        let placeholder = try XCTUnwrap(
            descendants(of: panel, NSTextField.self)
                .first { $0.stringValue.contains("to see what it is") },
            "nothing selected yet, so the detail says what to do"
        )
        let scroll = try XCTUnwrap(
            descendants(of: panel, ToolDetailScroll.self).first,
            "the placeholder lives in the detail scroll"
        )
        let document = try XCTUnwrap(scroll.documentView)
        let text = placeholder.convert(placeholder.bounds, to: document)

        XCTAssertTrue(scroll.documentVisibleRect.contains(text),
                      "the placeholder is on screen, not below the fold: "
                      + "\(text) is not inside \(scroll.documentVisibleRect)")
        XCTAssertFalse(anyAmbiguousLayout(under: panel),
                       "no view in the panel is left without a size the engine can solve: "
                       + "\(ambiguousViews(under: panel))")
    }

    /// A descriptor says more about itself than a header's worth of rows, and
    /// two of the things it says are grids: what the BIOS master may do to each
    /// region, and the flash chips this firmware was built to drive. Both are
    /// drawn as tables under the rows, with a permission read by its colour.
    func testTheDescriptorsDetailDrawsItsTwoTables() throws {
        let controller = try open(UEFITestImage.intelImage())
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        // The descriptor is the first row under the image root.
        _ = try expandRow(0)
        let row = try XCTUnwrap(
            (0..<outline.numberOfRows).first { (try? node(atRow: $0).kind) == .flashDescriptor },
            "the dump opens with a descriptor region")
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window?.layoutIfNeeded()

        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("11 00 00 9C 90 02 00 D6 00 00 00 05 FF FF FF FF"),
                      "the reserved vector, as a dump prints it: \(text)")
        XCTAssertTrue(text.contains("Region access settings"), "\(text)")
        XCTAssertTrue(text.contains("BIOS access table"), "\(text)")
        XCTAssertTrue(text.contains("Flash chips in VSCC table"), "\(text)")
        XCTAssertTrue(text.contains("Winbond W25Q256"), "a chip the catalogue names: \(text)")
        XCTAssertTrue(text.contains("Unknown"), "and one it does not: \(text)")

        // Two grids, and the permissions in the first are coloured: the BIOS
        // master reads its own region and the ME one, and writes neither.
        let grids = descendants(of: panel, NSGridView.self)
        XCTAssertEqual(grids.count, 3, "one grid per table")
        // A table is as wide as what is in it, not as wide as the panel: the
        // chips' two columns belong side by side, not one at either edge.
        let chips = try XCTUnwrap(grids.last)
        XCTAssertLessThan(chips.frame.width, panel.bounds.width - 60,
                          "the chips table is not stretched across the list")
        let cells = descendants(of: try XCTUnwrap(grids.dropFirst().first), NSTextField.self)
        let yes = cells.filter { $0.stringValue == "Yes" }
        let no = cells.filter { $0.stringValue == "No" }
        XCTAssertEqual(yes.count, 3, "Desc: no, BIOS: read+write, ME: read")
        XCTAssertFalse(no.isEmpty)
        XCTAssertTrue(yes.allSatisfy { $0.textColor == SemanticColors.good },
                      "a permission is the app's green, the one \"Configured\" is drawn in")
        XCTAssertTrue(no.allSatisfy { $0.textColor == SemanticColors.bad }, "a refusal is red")

        // And the chips table is led by an icon, as its heading says it is.
        XCTAssertTrue(
            descendants(of: panel, NSImageView.self).contains {
                $0.image?.accessibilityDescription == "Flash chips in VSCC table"
            },
            "the chip symbol before the heading")
    }

    func testTheDetailSaysWhatTheNodeIs() throws {
        let controller = try open(UEFITestImage.make())
        let outline = try outline()
        let panel = try XCTUnwrap(controller.tools.panel)

        // The volume is the one top-level row.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("0x0 · 0x1000 (4096) bytes"), "\(text)")
        XCTAssertTrue(text.contains("Revision"), "\(text)")

        // The file is under it, once the volume is opened: named by its
        // user-interface section, typed by the code in its header.
        try expandRow(0)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("MyDriver"), "\(text)")
        XCTAssertTrue(text.contains("Driver"), "\(text)")
    }

    // MARK: - A node opened as a panel (Design/FRAGMENT_PANELS_PLAN.md)

    /// Any node of the tree can be taken out into a panel over the dump: its
    /// own bytes, linked back to where they are in the file, so Update in
    /// Parent knows the way home.
    func testANodeOpensAsAPanelLinkedToItsOwnBytes() throws {
        let controller = try open(UEFITestImage.make())
        let node = try node(atRow: 0)

        try session().openNodeInPanel(for: node.id, body: false)
        XCTAssertTrue(pumpUntil(2) { controller.fragments.expanded != nil },
                      "the panel is raised")

        let id = try XCTUnwrap(controller.fragments.expanded)
        let part = try XCTUnwrap(controller.fragments.pane(id))
        XCTAssertEqual(part.fileSize, UInt64(node.range.count), "the node's bytes, and only those")
        let origin = try XCTUnwrap(part.origin, "linked back to where it came from")
        XCTAssertEqual(origin.sourceRange, node.range)
        XCTAssertTrue(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.state, .intact)
        controller.fragments.close(id, animated: false)
    }

    /// And its body alone, without the header, linked to the body's own bytes.
    func testANodesBodyOpensAsAPanelOfItsOwn() throws {
        let controller = try open(UEFITestImage.make())
        let node = try node(atRow: 0)
        try XCTSkipIf(node.header.isEmpty, "this node has no header to leave behind")

        try session().openNodeInPanel(for: node.id, body: true)
        XCTAssertTrue(pumpUntil(2) { controller.fragments.expanded != nil })

        let id = try XCTUnwrap(controller.fragments.expanded)
        let part = try XCTUnwrap(controller.fragments.pane(id))
        XCTAssertEqual(part.fileSize, UInt64(node.body.count))
        XCTAssertEqual(try XCTUnwrap(part.origin).sourceRange, node.body,
                       "the body's own bytes, not the node's")
        XCTAssertTrue(part.status.fileName.hasSuffix(" body.bin"), part.status.fileName)
        controller.fragments.close(id, animated: false)
    }

    /// The tree's own menu is where a reader reaches them.
    func testTheTreeMenuOffersBothOnANodeWithAHeader() throws {
        _ = try open(UEFITestImage.make())
        let node = try node(atRow: 0)
        XCTAssertNotNil(UEFIPresenter.nodeOpenTitle(for: node, body: false))
        XCTAssertEqual(UEFIPresenter.nodeOpenTitle(for: node, body: true) != nil,
                       !node.header.isEmpty,
                       "a body is offered exactly where there is a header to leave behind")
    }

    // MARK: - The ME region's sub-tree (Design/ME_REGION_IN_UEFI_TREE_PLAN.md)

    /// What a row says in the Name column — the node's title for a UEFI row,
    /// the curated title for an ME row.
    private func titleText(_ outline: NSOutlineView, row: Int) -> String? {
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
            .textField?.stringValue
    }

    /// The analysis a test parks in the pane's cache: an identity, one FPT
    /// region with a range, and nothing else — enough for a mappable row and an
    /// info leaf. Decoded the way the engine hands it, so no internal
    /// initializers are needed.
    /// `emptyRegionNamed` adds an erased region beside the real one — a row
    /// whose section holds nothing, which the panel draws grey. Off by default:
    /// the other tests count this sub-tree's rows.
    private func meAnalysisFixture(
        emptyRegionNamed empty: String? = nil
    ) throws -> FirmwareAnalysis {
        var regions: [[String: Any]] = [
            ["id": 0, "name": "FTPR", "offset": 0x1000, "size": 0x1000, "flags": 0x8000],
        ]
        if let empty {
            regions.append(["id": 1, "name": empty, "offset": 0x2000, "size": 0, "flags": 0])
        }
        let base: [String: Any] = [
            "family": "csme",
            "variant": "CSME",
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121],
            "release": "production",
            "type": "region",
            "sku": "",
            "platform": "",
            "sizeBytes": 0x2000,
            "regions": regions,
            "issues": [],
        ]
        return try JSONDecoder().decode(
            FirmwareAnalysis.self,
            from: JSONSerialization.data(withJSONObject: base))
    }

    /// Opens the ME-region image, parks a cached analysis, and opens the region
    /// onto its sub-tree, returning the outline once the sub-tree is on screen.
    ///
    /// The image is an Intel image, so the tree folds the "Intel image" root
    /// into the title and the outline's top level is the root's children — the
    /// descriptor and the ME region, two rows. The ME region is already at the
    /// top level; opening it runs the shared analysis (a cache hit reads
    /// nothing) and presents the curated sub-tree as its children, so the open
    /// lands in the same step and the reveal that follows has already selected
    /// the first root.
    private func openMERegion(analysis: FirmwareAnalysis? = nil) throws -> NSOutlineView {
        let controller = try open(UEFITestImage.intelImageWithME())
        let cached = try analysis ?? meAnalysisFixture()
        controller.windowModel.pane1.uefiState.setCachedMEAnalysis(
            cached, meRegion: 0x1000..<0x2000)
        let outline = try outline()
        let meRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { (try? node(atRow: $0))?.kind == .region },
            "the descriptor maps an ME region")
        // A reader opens the region by clicking its disclosure triangle, which
        // asks the delegate `shouldExpandItem` — the seam that starts the ME
        // analysis. The test invokes that delegate method directly, the way the
        // outline would on a click, so the analysis runs and the row opens onto
        // the sub-tree it presents.
        let vc = try XCTUnwrap(session().viewController as? UEFIToolViewController)
        let item = outline.item(atRow: meRow)
        vc.outlineView(outline, shouldExpandItem: item)
        let open = pumpUntil(5) { outline.numberOfRows >= 5 }
        XCTAssertTrue(open,
                      "the ME region opened onto its roots: \(outline.numberOfRows) rows")
        return outline
    }

    /// The ME region node is the graft point: opening it runs the shared ME
    /// analysis and presents the curated sub-tree as its children, in place of
    /// a raw-area scan the tree would otherwise find nothing in.
    func testTheMERegionExpandsToTheMESubTree() throws {
        let outline = try openMERegion()
        // The three roots the curator presents, in its order — the identity,
        // the regions, and the checksums — not a raw-area scan. They sit under
        // the ME region (row 1), after the descriptor (row 0).
        XCTAssertEqual((2..<outline.numberOfRows).map { titleText(outline, row: $0) },
                       ["Firmware", "Regions (FPT)", "Checksums"])
    }

    /// A row of the sub-tree that stands for bytes publishes a zone for its own
    /// range, the way the ME Analyzer does — and the host brings it on screen
    /// the way it already does for a UEFI node.
    func testSelectingAMappableMENodePublishesItsRange() throws {
        let outline = try openMERegion()
        let pane = try XCTUnwrap(controller?.windowModel.pane1)

        // The region is under the "Regions (FPT)" root, which is opened first.
        let regionsRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { titleText(outline, row: $0) == "Regions (FPT)" })
        outline.expandItem(outline.item(atRow: regionsRow))
        window?.layoutIfNeeded()
        let ftpRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { titleText(outline, row: $0) == "FTPR" })
        outline.selectRowIndexes(IndexSet(integer: ftpRow), byExtendingSelection: false)
        window?.layoutIfNeeded()

        XCTAssertEqual(pane.zones.zones.map(\.id), ["1/0"], "one zone, the node's own")
        XCTAssertEqual(pane.zones.zones.map(\.range), [0x1000..<0x2000],
                       "the region's range, as the analysis gave it")
        XCTAssertEqual(pane.zones.focus, "1/0")
    }

    /// A row that stands for no bytes — the identity — publishes no zone and
    /// shows its fields in the detail only.
    func testSelectingAnInfoLeafMENodePublishesNoZone() throws {
        let outline = try openMERegion()
        let pane = try XCTUnwrap(controller?.windowModel.pane1)

        // The open's reveal already settled on the first root, the identity, so
        // a plain re-select would be a change of nothing the outline does not
        // report. Deselect first, so settling back on the identity is a real
        // selection — the one that reads its detail and says what the map holds.
        let firmwareRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { titleText(outline, row: $0) == "Firmware" })
        outline.deselectAll(nil)
        outline.selectRowIndexes(IndexSet(integer: firmwareRow), byExtendingSelection: false)
        window?.layoutIfNeeded()

        XCTAssertTrue(pane.zones.zones.isEmpty, "an info leaf has no range to publish")
        // Its fields are in the detail, the way the ME Analyzer shows them.
        let panel = try XCTUnwrap(controller?.tools.panel)
        let text = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(text.contains("Family"), "the identity's fields: \(text)")
        XCTAssertTrue(text.contains("CSME"), "\(text)")
    }

    /// A caret inside the ME region is the sub-tree's to place, not the region
    /// node's. The sub-tree's rows are presented under the region rather than
    /// parsed into the UEFI tree, so the deepest node the tree can find inside
    /// the region is the region itself — and the reveal asks the ME half first.
    func testRevealingACaretInsideTheMERegionPicksTheSubTreesRow() throws {
        let outline = try openMERegion()
        let pane = try XCTUnwrap(controller?.windowModel.pane1)

        // 0x1000 is the FPT region the fixture's analysis gives a range for.
        pane.moveCaret(to: 0x1000)
        try session().revealNodeAtCaret()

        XCTAssertTrue(pumpUntil(5) {
            outline.selectedRow >= 0 && titleText(outline, row: outline.selectedRow) == "FTPR"
        }, "the reveal settled on the sub-tree's row, not the region: \(outline.selectedRow)")
        XCTAssertEqual(pane.zones.focus, "1/0", "and published the row's own zone")
    }

    /// A caret inside an ME region nobody has opened is still the sub-tree's to
    /// place. The rows that could own the byte do not exist yet, so the reveal
    /// opens the region rather than answering with the node above it, and
    /// settles on the row once the sub-tree is there.
    func testRevealingIntoAnUnopenedMERegionOpensItAndPicksTheRow() throws {
        let controller = try open(UEFITestImage.intelImageWithME())
        controller.windowModel.pane1.uefiState.setCachedMEAnalysis(
            try meAnalysisFixture(), meRegion: 0x1000..<0x2000)
        let outline = try outline()
        let pane = controller.windowModel.pane1

        // The descriptor and the region are the whole tree: the region is shut.
        XCTAssertEqual(outline.numberOfRows, 2, "the region has not been opened")

        pane.moveCaret(to: 0x1000)
        try session().revealNodeAtCaret()

        XCTAssertTrue(pumpUntil(5) {
            outline.selectedRow >= 0 && titleText(outline, row: outline.selectedRow) == "FTPR"
        }, "the reveal opened the region and settled on its row: \(outline.selectedRow)")
        XCTAssertEqual(pane.zones.focus, "1/0", "and published the row's own zone")
    }

    /// When the reading fails there is no sub-tree to place the caret in, and
    /// the nearest node above it is the region — so the reveal lands there
    /// rather than nowhere. The fixture's ME region is erased, which is what
    /// makes the reading fail; the failure itself is said under the tree.
    func testARevealWhoseReadingFailsFallsBackToTheRegionNode() throws {
        // No cached analysis, so the open has to read the region — and the
        // region holds a manifest, which the analysis names out of the firmware
        // database, which this suite's offline source refuses.
        let controller = try open(UEFITestImage.intelImageWithReadableME())
        let outline = try outline()
        let pane = controller.windowModel.pane1
        XCTAssertEqual(outline.numberOfRows, 2, "the descriptor and the region")

        pane.moveCaret(to: 0x1000)
        try session().revealNodeAtCaret()

        XCTAssertTrue(pumpUntil(5) { outline.selectedRow == 1 },
                      "the reveal fell back to the region node: \(outline.selectedRow)")
        XCTAssertEqual(try node(atRow: outline.selectedRow).kind, .region,
                       "the region stands for the bytes the caret is in")
        XCTAssertEqual(outline.numberOfRows, 2,
                       "and nothing was opened onto: the reading failed")
    }

    /// A reveal that moves off an ME row takes that row's zone off the dump —
    /// and puts nothing in its place. Publishing the new node's own zone instead
    /// would be what makes the host bring it on screen, and what it brings is
    /// the *start* of it: for a node the caret sits deep inside, that is a jump
    /// away from the byte the reveal was asked about.
    func testARevealOffAnMERowClearsTheZoneMap() throws {
        let outline = try openMERegion()
        let pane = try XCTUnwrap(controller?.windowModel.pane1)

        // An ME row that stands for bytes, so there is a zone to lose.
        let regionsRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { titleText(outline, row: $0) == "Regions (FPT)" })
        outline.expandItem(outline.item(atRow: regionsRow))
        window?.layoutIfNeeded()
        let ftpRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { titleText(outline, row: $0) == "FTPR" })
        outline.selectRowIndexes(IndexSet(integer: ftpRow), byExtendingSelection: false)
        window?.layoutIfNeeded()
        XCTAssertEqual(pane.zones.zones.map(\.id), ["1/0"], "the ME row's zone is up")

        // The caret moves into the descriptor, off the ME region entirely, so
        // the reveal crosses to a UEFI node.
        pane.moveCaret(to: 0x50)
        try session().revealNodeAtCaret()

        XCTAssertTrue(pumpUntil(5) { pane.zones.zones.isEmpty },
                      "the zone went with the row it stood for: "
                      + "\(pane.zones.zones.map(\.id))")
        XCTAssertEqual(pane.zones.focus, nil, "and nothing took its place")
    }

    /// A row whose section holds nothing reads grey — the whole row, every
    /// column, the way the ME Analyzer draws it. Setting it in the cell is the
    /// only way the model's `isEmptySection` can reach this panel:
    /// `ToolRowMarks` carries a problem, badges and a tooltip, and no colour.
    func testAnEmptyMESectionReadsGrey() throws {
        let outline = try openMERegion(analysis: meAnalysisFixture(emptyRegionNamed: "MFS"))

        let regionsRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { titleText(outline, row: $0) == "Regions (FPT)" })
        outline.expandItem(outline.item(atRow: regionsRow))
        window?.layoutIfNeeded()

        func nameColor(ofRowTitled title: String) throws -> NSColor? {
            let row = try XCTUnwrap(
                (0..<outline.numberOfRows).first { titleText(outline, row: $0) == title },
                "the row titled \(title)")
            let cell = try XCTUnwrap(
                outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            return cell.textField?.textColor
        }

        XCTAssertEqual(try nameColor(ofRowTitled: "MFS"), .secondaryLabelColor,
                       "a section holding nothing is a place in the layout, not one to read")
        XCTAssertEqual(try nameColor(ofRowTitled: "FTPR"), .labelColor,
                       "and one that holds something reads normally")
    }
}

/// A 4 KiB FFSv2 volume with one sectioned file in it, built byte by byte — the
/// app suite's own fixture, since the parser package's builders do not ship.
///
/// The layout the parse is checked against:
///
/// ```
/// 0x00  volume header, 0x48 long: base header + a two-entry block map
/// 0x48  file "MyDriver" (0x44)
/// 0x60    name section "MyDriver"
/// 0x78    raw section
/// 0x8C  padding to the next eight-byte boundary
/// 0x90  free space to the end of the volume
/// ```
///
/// `HeaderLength` covers the block map, so the body starts at `ALIGN8(0x48)` —
/// past the map, on the first file (§3.2).
enum UEFITestImage {
    static func make() -> [UInt8] {
        let volumeLength: UInt64 = 0x1000
        var image = [UInt8](repeating: 0xFF, count: Int(volumeLength))

        // The volume header: the file system GUID, the length, the signature,
        // the erase polarity, and a block map that agrees with the length.
        // `HeaderLength` spans the base header and the block map, so the body
        // starts past it (§3.2).
        var header: [UInt8] = []
        header += [UInt8](repeating: 0, count: 0x10)
        header += KnownGUIDs.ffsV2.bytes
        header += u64(volumeLength)
        header += u32(0x4856_465F)          // _FVH
        header += u32(0x0000_0800)          // erase polarity
        header += u16(0x48)                 // header length, over the block map
        header += u16(0)                    // checksum, filled in below
        header += u16(0)                    // no extended header
        header += [0, 2]                    // reserved, revision 2
        header += u32(1)                    // block map: one block…
        header += u32(UInt32(volumeLength)) // …of this size
        header += u32(0)                    // …terminated by the {0, 0} pair
        header += u32(0)
        // The sum covers the whole `HeaderLength` (§3.3).
        let checksum = Checksums.checksum16(header) ?? 0
        header[0x32] = UInt8(truncatingIfNeeded: checksum)
        header[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)
        image.replaceSubrange(0x00..<0x48, with: header)

        // The file: a driver, named by its user-interface section.
        image.replaceSubrange(0x48..<0x8C, with: file())
        return image
    }

    /// The same volume with 4 KiB of erased bytes behind it. Two things at the
    /// top level rather than one, so the parser groups them under the "UEFI
    /// image" root it invents for exactly that case — which is the shape the
    /// panel folds into its title.
    static func withTrailingPadding() -> [UInt8] {
        make() + [UInt8](repeating: 0xFF, count: 0x1000)
    }

    /// Two volumes back to back: two branches a reader can open at once.
    static func withTwoVolumes() -> [UInt8] {
        make() + make()
    }

    /// A whole SPI dump: a flash descriptor with a master section and a VSCC
    /// table, a BIOS region holding the volume above, and nothing else. What
    /// the descriptor's own detail is read from.
    static func intelImage() -> [UInt8] {
        let biosAt = 0x1000
        var image = [UInt8](repeating: 0xFF, count: 0x2000)
        func put(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { image[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func put16(_ value: UInt16, at offset: Int) {
            image[offset] = UInt8(truncatingIfNeeded: value)
            image[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }

        // The vector, the signature, and a map naming the three sections.
        image.replaceSubrange(0..<16, with: [0x11, 0x00, 0x00, 0x9C, 0x90, 0x02, 0x00, 0xD6,
                                             0x00, 0x00, 0x00, 0x05, 0xFF, 0xFF, 0xFF, 0xFF])
        put(0x0FF0_A55A, at: 0x10)
        put(0x0004_0000, at: 0x14)          // RegionBase 0x04
        put(0x0000_000A, at: 0x18)          // MasterBase 0x0A
        put(0xFFFF_FFFF, at: 0x20)          // a version 1 descriptor

        for index in 0..<16 {               // every region absent…
            put16(0, at: 0x40 + index * 4)
            put16(0, at: 0x40 + index * 4 + 2)
        }
        put16(UInt16(biosAt >> 12), at: 0x44)                 // …but BIOS,
        put16(UInt16((image.count - 1) >> 12), at: 0x46)      // which is the rest

        // The BIOS master: reads its own region and the ME one, writes neither.
        image[0xA2] = 0x06
        image[0xA3] = 0x00

        // Two chips in the VSCC table: one the catalogue knows, one it does not.
        put16(0x0410, at: 0x0EFC)           // base 0x10, two entries (four dwords)
        for (index, id) in [0xEF4019, 0x0A0B0C].enumerated() {
            let entry = 0x100 + index * 8
            image[entry] = UInt8(truncatingIfNeeded: id >> 16)
            image[entry + 1] = UInt8(truncatingIfNeeded: id >> 8)
            image[entry + 2] = UInt8(truncatingIfNeeded: id)
            put(0x2005, at: entry + 4)
        }

        image.replaceSubrange(biosAt..<(biosAt + 0x1000), with: make())
        return image
    }

    /// A whole SPI dump with an ME region: a flash descriptor that maps an ME
    /// region after itself, and nothing else. The ME region's bytes are padding
    /// — the tests that use this park a cached analysis first, so the content
    /// is never read.
    static func intelImageWithME() -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: 0x2000)
        func put(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { image[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func put16(_ value: UInt16, at offset: Int) {
            image[offset] = UInt8(truncatingIfNeeded: value)
            image[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }

        // The vector, the signature, and a map naming the sections.
        image.replaceSubrange(0..<16, with: [0x11, 0x00, 0x00, 0x9C, 0x90, 0x02, 0x00, 0xD6,
                                             0x00, 0x00, 0x00, 0x05, 0xFF, 0xFF, 0xFF, 0xFF])
        put(0x0FF0_A55A, at: 0x10)
        put(0x0004_0000, at: 0x14)          // RegionBase 0x04
        put(0xFFFF_FFFF, at: 0x20)          // a version 1 descriptor

        for index in 0..<16 {               // every region absent…
            put16(0, at: 0x40 + index * 4)
            put16(0, at: 0x40 + index * 4 + 2)
        }
        put16(0x01, at: 0x48)               // …but ME, 0x1000–0x1FFF.
        put16(0x01, at: 0x4A)
        return image
    }

    /// The same image with a real ME manifest in its region instead of the
    /// erased bytes. Enough for the analysis to get as far as the firmware
    /// database — which is where a machine that cannot reach it fails, and the
    /// only failure this session can actually be driven into.
    static func intelImageWithReadableME() -> [UInt8] {
        var image = intelImageWithME()
        let manifest = METestImage.manifestFile()
        image.replaceSubrange(0x1000..<(0x1000 + manifest.count), with: manifest)
        return image
    }

    /// The one file in the volume: a 0x44-byte driver whose body is a name
    /// section and a raw section.
    private static func file() -> [UInt8] {
        let name = EFIGUID(low: 0x0000_0000_0000_0001, high: 0x0000_0000_0000_0002)
        var bytes: [UInt8] = []
        bytes += name.bytes
        bytes += [0, 0xAA, 0x07, 0x00]      // header/body checksum, type, attributes
        bytes += u24(0x44)                  // size
        bytes += [0xF8]                     // state, erase polarity

        // Name section: the UCS-2 string a person gave the file.
        bytes += u24(0x16)
        bytes += [0x15]
        bytes += ucs2("MyDriver")

        // Two erased bytes to the next four-byte boundary.
        bytes += [0xFF, 0xFF]

        // Raw section: sixteen bytes of payload.
        bytes += u24(0x14)
        bytes += [0x19]
        bytes += [UInt8](repeating: 0x5A, count: 16)
        return bytes
    }

    // MARK: - Little-endian writers

    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u24(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    /// UCS-2 little-endian, with the terminating zero the section carries.
    private static func ucs2(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in string.unicodeScalars {
            bytes += [UInt8(truncatingIfNeeded: scalar.value), 0]
        }
        bytes += [0, 0]
        return bytes
    }
}
