import XCTest
import ToolModuleKit
import UEFIImage
import UEFITool
@testable import UEFIToolUI
@testable import ByteRipper

/// The search bar's Contents mode in the panel: Find All through what the
/// compressed sections decompress to, the results panel under the tree with
/// its progress and its list, a click that goes to a match, and the box that
/// keeps the search to the selected node
/// (`Design/UEFI_STRUCTURE_TOOL.md`, "Searching the contents").
@MainActor
final class UEFIContentSearchFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    private static let keys = ["UEFIStructure.Search.IsOpen", "UEFIStructure.Search.Mode",
                               "UEFIStructure.Search.ContentText", "UEFIStructure.Search.ContentIsHex",
                               "UEFIStructure.Search.ContentFromSelection"]

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
        Self.keys.forEach { ToolPanelFont.defaults.removeObject(forKey: $0) }
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
        UEFISearchSettings.isOpen = true
        UEFISearchSettings.mode = .contents
        window.layoutIfNeeded()
    }

    private func bar() throws -> UEFISearchBar {
        try XCTUnwrap(descendants(of: try XCTUnwrap(controller?.tools.panel), UEFISearchBar.self).first)
    }

    private func outline() throws -> NSOutlineView {
        try XCTUnwrap(descendants(of: try XCTUnwrap(controller?.tools.panel), NSOutlineView.self).first)
    }

    private func selectedNode() throws -> UEFINode? {
        let outline = try outline()
        guard outline.selectedRow >= 0, let id = (outline.item(atRow: outline.selectedRow) as? UEFITreeRow)?.id
        else { return nil }
        return controller?.windowModel.pane1.uefiState.tree?.node(id)
    }

    private func results() throws -> UEFIContentResultsView {
        try XCTUnwrap(descendants(of: try XCTUnwrap(controller?.tools.panel), UEFIContentResultsView.self).first)
    }

    /// Clicks Find All for `text` and waits for the search to be over: the
    /// results panel opens under the tree, with its progress while it runs.
    private func findAll(_ text: String, hex: Bool = false, wholeTree: Bool = true) throws -> UEFIContentResultsView {
        UEFISearchSettings.content = .init(text: text, isHex: hex, wholeTree: wholeTree)
        let bar = try bar()
        let button = try XCTUnwrap(descendants(of: bar, NSButton.self).first { $0.title == "Find All" })
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, "Find All is on screen in Contents mode")
        let results = try results()
        button.performClick(nil)
        if case .searching = results.state {} else { XCTFail("the panel says it is searching: \(results.state)") }
        XCTAssertFalse(results.progressBar.isHidden, "with its progress")
        XCTAssertTrue(pumpUntil(5) { if case .done = results.state { return true }; return false }, "\(results.state)")
        window?.layoutIfNeeded()
        XCTAssertGreaterThan(results.frame.height, 50, "the panel is open under the tree")
        XCTAssertTrue(results.progressBar.isHidden)
        return results
    }

    func testTextInACompressedSectionIsListedAndAClickGoesToIt() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let results = try findAll("gh51g")

        XCTAssertEqual(results.state, .done(total: 1, scope: nil))
        let row = try XCTUnwrap(results.rows.first)
        XCTAssertEqual(row.node, "Raw")
        XCTAssertFalse(row.volume.isEmpty || row.volume == "—", "the volume is named")
        XCTAssertEqual(row.codecs, ["LZMA"], "the badge of the codec its bytes came through")
        XCTAssertTrue(row.address.contains(" in "), row.address)
        XCTAssertEqual(Array(row.excerpt[row.excerptMatch]), Array("GH51G".utf8), "the excerpt holds the match")
        XCTAssertEqual(row.excerptMatch.lowerBound, 8, "eight bytes before it")

        results.choose(0)
        XCTAssertTrue(pumpUntil(5) { (try? self.selectedNode())??.subtype == 0x19 }, "the raw section is selected")
    }

    func testAMatchInTheFileIsSelectedInTheDump() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let results = try findAll("5F 46 56 48", hex: true)

        XCTAssertEqual(results.state, .done(total: 1, scope: nil))
        let row = try XCTUnwrap(results.rows.first)
        XCTAssertEqual(row.codecs, [], "the file's own bytes wear no badge")
        XCTAssertEqual(row.address, "0x28", "the volume's signature")

        results.choose(0)
        let pane = try XCTUnwrap(controller?.windowModel.pane1)
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == 0x28 }, "the dump selects the match")
    }

    func testTheBoxKeepsTheSearchToTheSelectedNode() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        try findAll("GH51G").choose(0)
        XCTAssertTrue(pumpUntil(5) { (try? self.selectedNode())??.subtype == 0x19 })

        // The raw section is selected: the signature of the volume is not in it.
        let none = try findAll("_FVH", wholeTree: false)
        XCTAssertEqual(none.state, .done(total: 0, scope: "Raw"), "says where it looked")
        XCTAssertTrue(none.rows.isEmpty)

        let again = try findAll("GH51G", wholeTree: false)
        XCTAssertEqual(again.state, .done(total: 1, scope: "Raw"))
        let whole = try findAll("_FVH")
        XCTAssertEqual(whole.state, .done(total: 1, scope: nil), "unticked, the whole tree")
    }

    /// A double click on a match in decompressed bytes opens them as a
    /// fragment panel with the match selected — once: a second double click
    /// selects in the same panel.
    func testADoubleClickOpensTheDecompressedBytesWithTheMatchSelected() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let results = try findAll("GH51G")
        let controller = try XCTUnwrap(controller)
        let pane = controller.windowModel.pane1
        results.open(0)
        XCTAssertTrue(pumpUntil(5) { controller.fragments.panelsLinked(to: pane).count == 1 }, "a panel opens")
        let id = try XCTUnwrap(controller.fragments.panelsLinked(to: pane).first)
        let part = try XCTUnwrap(controller.fragments.pane(id))
        XCTAssertTrue(pumpUntil(5) { part.hexSelection().start != 0 })
        let start = Int(part.hexSelection().start)
        let bytes = try XCTUnwrap(part.byteStorage).read(at: UInt64(start), length: 5)
        XCTAssertEqual(bytes, Array("GH51G".utf8), "the match is selected")

        results.open(0)
        _ = pumpUntil(0.5) { false }
        XCTAssertEqual(controller.fragments.panelsLinked(to: pane).count, 1, "not opened twice")
    }

    func testADoubleClickOnAMatchInTheFileOpensNothing() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let results = try findAll("_FVH")
        results.open(0)
        _ = pumpUntil(0.5) { false }
        let controller = try XCTUnwrap(controller)
        XCTAssertTrue(controller.fragments.panelsLinked(to: controller.windowModel.pane1).isEmpty)
    }

    /// The first line says what is searched: the switch, then the box —
    /// ticked, the whole tree, until the reader clears it.
    func testTheBoxIsBesideTheSwitchAndTickedForTheWholeTree() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        ToolPanelFont.defaults.removeObject(forKey: "UEFIStructure.Search.ContentFromSelection")
        XCTAssertTrue(UEFISearchSettings.content.wholeTree, "the whole tree unless asked otherwise")
        let bar = try bar()
        let box = try XCTUnwrap(descendants(of: bar, NSButton.self).first { $0.title == "The whole tree" })
        let switcher = try XCTUnwrap(descendants(of: bar, NSSegmentedControl.self).first)
        let field = try XCTUnwrap(descendants(of: bar, NSSearchField.self).first)
        XCTAssertEqual(box.state, .on)
        XCTAssertTrue(box.superview === switcher.superview, "on the switch's line")
        XCTAssertFalse(field.superview === switcher.superview, "the pattern is on the next")
    }

    /// The note on the ME region stands while the whole tree is searched,
    /// and goes when the search is from the selected node.
    func testTheMENoteGoesWhenTheSearchIsFromTheSelectedNode() throws {
        try open(UEFITestImage.intelImageWithME())
        let bar = try bar()
        let note = { self.descendants(of: bar, NSTextField.self).first { $0.stringValue == "ME Region is not searched" } }
        UEFISearchSettings.content = .init(text: "", isHex: false, wholeTree: true)
        XCTAssertEqual(note()?.isHidden, false, "the whole tree: said")
        UEFISearchSettings.content = .init(text: "", isHex: false, wholeTree: false)
        XCTAssertEqual(note()?.isHidden, true, "from the selected node: not said")
        UEFISearchSettings.mode = .names
        XCTAssertEqual(note()?.isHidden, false, "the name search says it whatever the box")
    }

    func testTheCrossShutsTheResults() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let results = try findAll("GH51G")
        let close = try XCTUnwrap(descendants(of: results, NSButton.self).first { $0.toolTip == "Close search results" })
        close.performClick(nil)
        window?.layoutIfNeeded()
        XCTAssertEqual(results.frame.height, 0, "shut to nothing")
        XCTAssertTrue(results.isHidden)
        XCTAssertEqual(results.state, .idle)
    }
}
