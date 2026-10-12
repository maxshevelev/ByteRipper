import XCTest
@testable import ToolModuleKit
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
        FindHistoryStore.defaults = isolated.store
        FindBarView.defaults = isolated.store
        Self.keys.forEach { ToolPanelFont.defaults.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { ToolPanelFont.defaults.removeObject(forKey: $0) }
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
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

    /// Opens `bytes` with UEFI Structure switched on and returns at once,
    /// while the tree may still be read.
    private func openWithoutWaiting(_ bytes: [UInt8]) throws {
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
        UEFISearchSettings.isOpen = true
        UEFISearchSettings.mode = .contents
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
    }

    /// A chip dump with no descriptor, whose top level takes a scan to read:
    /// the volume well into a few megabytes of erased flash.
    private static func slowImage() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: 0x800000)
        let image = try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G")
        bytes.replaceSubrange(0x400000..<(0x400000 + image.count), with: image)
        return bytes
    }

    /// Find All clicked while the tree is still being read waits for it and
    /// then searches — it is not dropped.
    func testFindAllWaitsForTheTree() throws {
        try openWithoutWaiting(try Self.slowImage())
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        XCTAssertFalse(tree.isReady, "the test asks while the tree is read")
        UEFISearchSettings.content = .init(text: "GH51G", wholeTree: true)
        let results = try results()
        let button = try XCTUnwrap(descendants(of: try bar(), NSButton.self).first { $0.title == "Find All" })
        button.performClick(nil)
        if case .searching = results.state {} else { XCTFail("the panel says it is searching: \(results.state)") }
        XCTAssertTrue(pumpUntil(10) { if case .done = results.state { return true }; return false }, "\(results.state)")
        XCTAssertEqual(results.state, .done(total: 1, scope: nil))
    }

    /// The same for a search by name.
    func testANameSearchWaitsForTheTree() throws {
        try openWithoutWaiting(try Self.slowImage())
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        XCTAssertFalse(tree.isReady)
        UEFISearchSettings.mode = .names
        UEFISearchSettings.query = UEFITreeQuery(type: UEFITypes.Item.volume.rawValue)
        let bar = try bar()
        bar.onSearch?(.forward)
        XCTAssertEqual(bar.status, .searching, "the bar says it is searching")
        XCTAssertTrue(pumpUntil(10) { (try? self.selectedNode())??.kind == .volume },
                      "the volume is found once the tree is there")
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
        UEFISearchSettings.content = .init(text: text, wholeTree: wholeTree)
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
        XCTAssertEqual(row.node, "LZMA compressed section: Raw", "the node after the one above it")
        XCTAssertEqual(row.codecs, ["LZMA"], "the badge of the codec its bytes came through")
        XCTAssertTrue(row.address.contains(" in "), row.address)
        XCTAssertEqual(Array(row.excerpt[row.excerptMatch]), Array("GH51G".utf8), "the excerpt holds the match")
        XCTAssertEqual(row.excerptMatch.lowerBound, 8, "eight bytes before it")

        results.choose(0)
        XCTAssertTrue(pumpUntil(5) { (try? self.selectedNode())??.subtype == 0x19 }, "the raw section is selected")
        // The dump selects the compressed section the match came out of.
        let tree = try XCTUnwrap(controller?.windowModel.pane1.uefiState.tree)
        let section = try XCTUnwrap(tree.image().allNodes.first { $0.compression != nil && $0.space == .file })
        let pane = try XCTUnwrap(controller?.windowModel.pane1)
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == section.range.lowerBound },
                      "the dump stands on the section: \(pane.hexSelection().start)")
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

        // The part's own tree opens to the node the match is in.
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertTrue(pumpUntil(5) {
            guard let outline = self.descendants(of: surface.tools.panel, NSOutlineView.self).first,
                  outline.selectedRow >= 0,
                  let row = outline.item(atRow: outline.selectedRow) as? UEFITreeRow,
                  let node = part.uefiState.tree?.node(row.id) else { return false }
            return node.kind == .section && node.subtype == 0x19
        }, "the raw section holding the match is selected in the part's tree")

        // The right-click menu says the same and does the same.
        let item = try XCTUnwrap(results.menu(forRow: 0).items.first)
        XCTAssertEqual(item.title, "Open Decompressed Body")
        _ = item.target?.perform(item.action, with: item)
        _ = pumpUntil(0.5) { false }
        XCTAssertEqual(controller.fragments.panelsLinked(to: pane).count, 1, "not opened twice")
    }

    func testADoubleClickOnAMatchInTheFileOpensNothing() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let results = try findAll("_FVH")
        XCTAssertTrue(results.menu(forRow: 0).items.isEmpty, "nothing to open: the dump shows it")
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
        UEFISearchSettings.content = .init(text: "", wholeTree: true)
        XCTAssertEqual(note()?.isHidden, false, "the whole tree: said")
        UEFISearchSettings.content = .init(text: "", wholeTree: false)
        XCTAssertEqual(note()?.isHidden, true, "from the selected node: not said")
        UEFISearchSettings.mode = .names
        XCTAssertEqual(note()?.isHidden, false, "the name search says it whatever the box")
    }

    /// A variable is named after its store, though the store is called by its
    /// kind: that says which list of variables it is in.
    func testAVariableIsNamedAfterItsStore() throws {
        try open(NvramTestImage.vss([NvramTestImage.Variable("SetupMode", Array("FINDME-MARK".utf8))]))
        let results = try findAll("FINDME-MARK")
        let row = try XCTUnwrap(results.rows.first, "\(results.state)")
        XCTAssertTrue(row.node.hasPrefix("VSS store: "), row.node)
        XCTAssertTrue(row.node.contains("SetupMode"), row.node)
    }

    /// Space on the results opens the details large, as on the tree, and the
    /// arrows then go from match to match, the details following.
    func testSpaceOnTheResultsOpensTheDetailsLarge() throws {
        try open(NvramTestImage.vss([NvramTestImage.Variable("FirstVar", Array("FINDME-MARK".utf8)),
                                     NvramTestImage.Variable("SecondVar", Array("FINDME-MARK".utf8))]))
        let results = try findAll("FINDME-MARK")
        XCTAssertGreaterThanOrEqual(results.rows.count, 2)
        let window = try XCTUnwrap(window)
        results.choose(0)
        XCTAssertTrue(pumpUntil(5) { (try? self.selectedNode()) != nil }, "the first match's node is selected")
        window.makeFirstResponder(results.table)
        let pane = try XCTUnwrap(descendants(of: try XCTUnwrap(controller?.tools.panel), ToolDetailPane.self).first)
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(pane.handleKeyWhileShut(try key(" ", 49)), "Space on the results is taken")
        XCTAssertTrue(pane.isQuickLookShown)
        XCTAssertTrue(window.firstResponder === results.table, "the focus stays on the results")

        let first = try XCTUnwrap(selectedNode()).id
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        XCTAssertTrue(pane.handleKeyWhileShown(try key(down, 125)))
        XCTAssertEqual(results.table.selectedRow, 1, "the arrow moves the results")
        XCTAssertTrue(pumpUntil(5) { (try? self.selectedNode())??.id != first }, "the tree follows the match")
        pane.closeQuickLook()
    }

    /// The arrows on the results go to each match as a click does: the tree
    /// selects its node and the dump its bytes, so the three agree.
    func testTheArrowsOnTheResultsGoToEachMatch() throws {
        try open(NvramTestImage.vss([NvramTestImage.Variable("FirstVar", Array("FINDME-MARK".utf8)),
                                     NvramTestImage.Variable("SecondVar", Array("FINDME-MARK".utf8))]))
        let results = try findAll("FINDME-MARK")
        XCTAssertEqual(results.rows.count, 2)
        let window = try XCTUnwrap(window)
        let pane = try XCTUnwrap(controller?.windowModel.pane1)
        let addresses = results.rows.compactMap { UInt64($0.address.dropFirst(2), radix: 16) }
        XCTAssertEqual(addresses.count, 2, "\(results.rows.map(\.address))")

        results.choose(0)
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == addresses[0] }, "the first match in the dump")
        let first = try XCTUnwrap(selectedNode()).id
        window.makeFirstResponder(results.table)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        results.table.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: down,
            charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125)))
        XCTAssertEqual(results.table.selectedRow, 1)
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == addresses[1] }, "the dump follows the arrow")
        XCTAssertTrue(pumpUntil(5) { (try? self.selectedNode())??.id != first }, "so does the tree")
        XCTAssertTrue(window.firstResponder === results.table, "and the keyboard stays on the results")
    }

    /// Typing in a part opened from the results leaves the dump where the
    /// reader is typing: the caret moves on, nothing else is selected and the
    /// view does not jump to the node's start.
    func testTypingInAPartOpenedFromTheResultsStaysWhereItIs() throws {
        try open(try CompressedTestImage.make(payload: [UInt8](repeating: 0x20, count: 0x300) + Array("GH51G".utf8)
                                               + [UInt8](repeating: 0x20, count: 0x300)))
        let results = try findAll("GH51G")
        let controller = try XCTUnwrap(controller)
        results.open(0)
        XCTAssertTrue(pumpUntil(5) { controller.fragments.panelsLinked(to: controller.windowModel.pane1).count == 1 })
        let id = try XCTUnwrap(controller.fragments.panelsLinked(to: controller.windowModel.pane1).first)
        let part = try XCTUnwrap(controller.fragments.pane(id))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertTrue(pumpUntil(5) {
            guard let outline = self.descendants(of: surface.tools.panel, NSOutlineView.self).first else { return false }
            return outline.selectedRow >= 0
        }, "the part's tree has opened to the match's node")
        _ = pumpUntil(0.5) { false }
        let view = try XCTUnwrap(controller.filePaneView(for: part))
        let clip = try XCTUnwrap(descendants(of: view, NSClipView.self).first)
        let at = part.hexSelection().start
        let scrolled = clip.bounds.origin.y
        print("PROBE before: selection \(part.hexSelection()) scrolled \(scrolled)")

        part.moveCaret(to: at, center: false)
        part.typeHexNibble(0x4)
        part.typeHexNibble(0x1)
        _ = pumpUntil(1.5) { false }
        print("PROBE after: selection \(part.hexSelection()) scrolled \(clip.bounds.origin.y)")
        XCTAssertEqual(part.hexSelection().start, at + 1, "the caret moved on past the byte typed")
        XCTAssertEqual(part.hexSelection().end, part.hexSelection().start, "nothing selected")
        XCTAssertEqual(clip.bounds.origin.y, scrolled, accuracy: 1, "the view stayed")
    }

    // MARK: - The Find bar's controls

    private func controls() throws -> PatternQueryControls {
        try XCTUnwrap((try bar().query as? ToolPatternQueryControls)?.controls, "the host's controls are installed")
    }

    /// The pattern is asked for with the dump's own controls — field, encoding,
    /// Smart Search, case — in the bar's field's place.
    func testTheContentsSearchAsksWithTheFindBarsControls() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let bar = try bar()
        let controls = try controls()
        XCTAssertTrue(controls.patternField.isDescendant(of: bar))
        XCTAssertFalse(controls.patternField.isHiddenOrHasHiddenAncestor, "on screen in Contents mode")
        XCTAssertFalse(controls.smartButton.isHiddenOrHasHiddenAncestor)
        XCTAssertNotNil(controls.patternField.searchMenuTemplate, "with the menu of recents and the library")
        UEFISearchSettings.mode = .names
        XCTAssertFalse(controls.patternField.isDescendant(of: bar), "the name search has its own field")
        UEFISearchSettings.mode = .contents
        XCTAssertTrue(controls.patternField.isDescendant(of: bar), "and back in Contents mode")
    }

    /// A search that found something goes into the Find bar's recent queries,
    /// with the encoding it was found in; one that found nothing does not.
    func testAFoundSearchJoinsTheFindBarsRecents() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        _ = try findAll("NOT-IN-THERE")
        XCTAssertNil(FindHistoryStore.mostRecent, "nothing found, nothing kept")
        _ = try findAll("GH51G")
        XCTAssertEqual(FindHistoryStore.mostRecent?.pattern, "GH51G")
        XCTAssertEqual(FindHistoryStore.mostRecent?.encoding, .ascii)
    }

    /// A pattern picked out of the field's menu is searched at once — and, a
    /// pick, is not written into the recents a second time.
    func testAPatternPickedFromTheMenuIsSearched() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        FindHistoryStore.record(pattern: "GH51G", encoding: .ascii, caseSensitive: false)
        let controls = try controls()
        controls.rebuildPatternMenu()
        let item = try XCTUnwrap(controls.patternField.searchMenuTemplate?.items.first {
            $0.representedObject != nil && ($0.attributedTitle?.string ?? $0.title).contains("GH51G")
        })
        let results = try results()
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertTrue(pumpUntil(5) { if case .done = results.state { return true }; return false })
        XCTAssertEqual(results.state, .done(total: 1, scope: nil))
        XCTAssertEqual(controls.text, "GH51G")
    }

    /// Smart Search tries one encoding after another and shows the one that
    /// found the match: a variable's name is UTF-16.
    func testSmartSearchShowsTheEncodingThatFound() throws {
        try open(NvramTestImage.vss([NvramTestImage.Variable("SetupMode", [0x01])]))
        let controls = try controls()
        XCTAssertTrue(controls.isSmartSearchEnabled, "on unless turned off")
        let results = try findAll("SetupMode")
        XCTAssertGreaterThan(results.rows.count, 0)
        XCTAssertEqual(controls.currentEncoding(), .utf16LE)
    }

    /// The case toggle is the Find bar's: on, letters match exactly.
    func testTheCaseToggleMatchesExactly() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        let controls = try controls()
        controls.caseButton.state = .on
        controls.caseToggled()
        XCTAssertEqual(try findAll("gh51g").state, .done(total: 0, scope: nil))
        XCTAssertEqual(try findAll("GH51G").state, .done(total: 1, scope: nil))
        controls.caseButton.state = .off
        controls.caseToggled()
    }

    /// What is typed stays when the box is ticked or cleared — in the tab's
    /// panel and in a fragment panel's.
    func testTheBoxLeavesTheTypedPatternAlone() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        UEFISearchSettings.content = .init(text: "OLD", wholeTree: true)
        let results = try findAll("GH51G")
        results.open(0)
        let controller = try XCTUnwrap(controller)
        XCTAssertTrue(pumpUntil(5) { controller.fragments.panelsLinked(to: controller.windowModel.pane1).count == 1 })
        let id = try XCTUnwrap(controller.fragments.panelsLinked(to: controller.windowModel.pane1).first)
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertTrue(pumpUntil(5) { !self.descendants(of: surface.tools.panel, UEFISearchBar.self).isEmpty })

        for bar in [try bar(), try XCTUnwrap(descendants(of: surface.tools.panel, UEFISearchBar.self).first)] {
            let controls = try XCTUnwrap((bar.query as? ToolPatternQueryControls)?.controls)
            let window = try XCTUnwrap(bar.window)
            window.makeFirstResponder(controls.patternField)
            let editor = try XCTUnwrap(controls.patternField.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("TYPED-\(ObjectIdentifier(bar).hashValue)", replacementRange: editor.selectedRange())
            let typed = controls.text
            let box = try XCTUnwrap(descendants(of: bar, NSButton.self).first { $0.title == "The whole tree" })
            box.performClick(nil)
            XCTAssertEqual(controls.text, typed, "cleared: the pattern stays")
            box.performClick(nil)
            XCTAssertEqual(controls.text, typed, "ticked: the pattern stays")
        }
    }

    /// A pattern that came into the field without typing — picked from the
    /// menu — stays too when the box is used.
    func testTheBoxLeavesAPickedPatternAlone() throws {
        try open(try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"))
        UEFISearchSettings.content = .init(text: "OLD", wholeTree: true)
        FindHistoryStore.record(pattern: "GH51G", encoding: .ascii, caseSensitive: false)
        let controls = try controls()
        controls.rebuildPatternMenu()
        let item = try XCTUnwrap(controls.patternField.searchMenuTemplate?.items.first {
            $0.representedObject != nil && ($0.attributedTitle?.string ?? $0.title).contains("GH51G")
        })
        let results = try results()
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertTrue(pumpUntil(5) { if case .done = results.state { return true }; return false })
        let box = try XCTUnwrap(descendants(of: try bar(), NSButton.self).first { $0.title == "The whole tree" })
        box.performClick(nil)
        XCTAssertEqual(controls.text, "GH51G", "the picked pattern stays")
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
