import XCTest
import AgentKit
import CodeAnalysis
import Localization
import PartCodec
import UEFIContentSource
import ToolModuleKit
import UEFIImage
import UEFIToolUI
@testable import ByteRipper

/// A panel opened from a part of another document remembers where it came
/// from, says so in its header, and tells a UEFI panel what its bytes are
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §2, `Design/FRAGMENT_PANELS_PLAN.md`).
@MainActor
final class LinkedPartTests: XCTestCase {
    private var files: [URL] = []
    private var controllers: [MainViewController] = []
    private var windows: [NSWindow] = []
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        installToolStubs()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        for controller in controllers {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
        }
        windows.forEach { $0.close() }
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controllers = []
        windows = []
        files = []
        super.tearDown()
    }

    private func makeController(opening bytes: [UInt8]? = nil) throws -> MainViewController {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // A controller shrinks its window to what its view asks for, which for
        // an empty one is nothing: the panel a part opens into needs a window
        // with room in it.
        window.setContentSize(NSSize(width: 900, height: 600))
        if let bytes {
            let url = try tempFile(bytes)
            files.append(url)
            try controller.windowModel.pane1.open(url: url)
            controller.apply(mode: .singleFile)
        }
        window.layoutIfNeeded()
        controllers.append(controller)
        windows.append(window)
        return controller
    }

    private func host(_ controller: MainViewController) throws -> PaneToolHost {
        controller.tools.activate(StubToolA.identifier, animated: false)
        return try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
    }

    /// A code part is a read-only part with the code pane beside its bytes:
    /// the same source link, no bookmark space, and the placeholder the app
    /// puts up until the listing is drawn.
    func testACodePartOpensReadOnlyWithItsPane() throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x400))
        let parent = controller.windowModel.pane1
        let bytes = teModule()
        let manifest = AnalysisManifest(
            module: ModuleIdentity(
                sha256: SHA256Digest(data: Data(bytes)), size: bytes.count, name: "CpuPei",
                kind: "TE", language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(
                sha256: SHA256Digest(data: Data("artifact".utf8)), size: 8,
                mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00",
            stats: AnalysisStats())
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x0","name":"entry","instructions":[
            {"address":"0x0","bytes":"90","text":"NOP"}]}]}
        """.utf8))
        controller.openCode(
            named: "CpuPei body", from: parent, source: 0x100..<0x160,
            manifest: manifest, artifact: artifact,
            codec: ReadOnlyPartCodec(
                bytes,
                title: L("This cannot be put back"),
                reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")
            ))
        let id = try XCTUnwrap(controller.fragments.expanded)
        controller.view.window?.layoutIfNeeded()

        let part = try XCTUnwrap(controller.fragments.pane(id))
        XCTAssertEqual(part.origin?.sourceRange, 0x100..<0x160)
        XCTAssertTrue(part.origin?.codec is ReadOnlyPartCodec)
        XCTAssertNil(part.bookmarks, "a read-only code part has no bookmark space")
        XCTAssertEqual(part.zones.focus, "code-screen.function",
                       "the function is the dump's main zone")
        XCTAssertEqual(part.zones.zones.map(\.range), [0x50..<0x51])
        XCTAssertEqual(part.panelBadge?.text.text, "Code")
        XCTAssertEqual(part.panelBadge?.symbolName, "ellipsis.curlybraces")
        let panelView = try XCTUnwrap(descendants(of: controller.view, FilePaneView.self)
                                        .first { $0.viewModel === part })
        XCTAssertEqual(panelView.codecBadge.text, "Code",
                       "the header says Code, not Read-only")
        let strip = try XCTUnwrap(descendants(of: controller.view, FragmentDockStrip.self).first)
        let pill = try XCTUnwrap(strip.pillsForTesting.first)
        XCTAssertEqual(pill.transform?.text, "Code", "the pill wears the panel's kind")
        XCTAssertEqual(pill.transform?.symbolName, "ellipsis.curlybraces")
        XCTAssertFalse(pill.transform?.isTransform ?? true)
        part.select(range: 0..<1)
        let selection = part.hexSelection()
        controller.fragments.codePane(id)?.selectFunction(at: 0)
        XCTAssertEqual(part.hexSelection(), selection,
                       "choosing a function leaves the reader's selection alone")
        XCTAssertEqual(part.zones.zones.map(\.range), [0x50..<0x51])
        XCTAssertNotNil(controller.fragments.codePane(id))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertFalse(surface.minimapPanelVisible, "the code screen has no minimap")
        XCTAssertFalse(controller.minimapAllowed, "and the map commands are off")
        XCTAssertFalse(surface.tools.isPanelVisible, "the code screen has no tool strip")
        XCTAssertFalse(surface.tools.allowsSelection,
                       "and no tool-module may be chosen on it")
        XCTAssertFalse(controller.toolSelectionAllowed,
                       "a code screen has no room for a tool-module")
        // The screen's own place travels too: here the C side of the switch.
        controller.fragments.codePane(id)?.restore(function: 0, instruction: 0, showsC: true)

        // A copy is a new document, but the screen is part of what is copied.
        let content = try XCTUnwrap(controller.fragments.content(id))
        let copy = MainViewController()
        try copy.adoptCopy(of: content)
        XCTAssertTrue(copy.hasCodeScreen)
        XCTAssertTrue(copy.codeScreenView?.showsDecompiledC ?? false,
                      "the copy opens on the same side of the switch")
        XCTAssertFalse(copy.windowModel.pane1 === part, "the copy has its own document")
        copy.windowModel.pane1.close()

        // Moving the panel to a tab of its own must keep the screen, not turn
        // it into the plain dump its pane would otherwise be.
        let tab = MainViewController()
        defer {
            tab.windowModel.pane1.close()
            tab.windowModel.pane2.close()
        }
        controller.makeSiblingTab = { tab }
        tab.loadViewIfNeeded()
        controller.tearOffFragment(id)
        tab.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.fragments.isEmpty, "the panel left the dock")
        XCTAssertTrue(tab.hasCodeScreen, "it is still a code screen")
        XCTAssertTrue(tab.windowModel.pane1 === part, "the pane itself moved")
        XCTAssertEqual(part.panelBadge?.text.text, "Code", "and it is still a code panel")
        let moved = try XCTUnwrap(tab.codeScreenView)
        XCTAssertEqual(moved.functionCount, 1)
        XCTAssertEqual(moved.selectedFunction?.name, "entry")
        XCTAssertTrue(moved.showsDecompiledC, "the moved screen keeps the C side")
        let paneView = try XCTUnwrap(descendants(of: tab.view, FilePaneView.self).first)
        XCTAssertTrue(paneView.isHeaderHoisted, "the title bar is above the whole screen")
        let header = try XCTUnwrap(descendants(of: tab.view, PaneHeaderView.self).first)
        XCTAssertFalse(header.isDescendant(of: paneView),
                       "the name is not attached to the hex view")
        let close = try XCTUnwrap(descendants(of: header, NSButton.self).first {
            $0.accessibilityLabel() == "Close pane"
        })
        XCTAssertTrue(close.isHidden, "the window's own close is the only one")
        XCTAssertFalse(tab.surface.minimapPanelVisible, "and still has no minimap")
        XCTAssertFalse(tab.minimapAllowed, "and still refuses a map")
        XCTAssertFalse(tab.surface.tools.isPanelVisible, "and still has no tool strip")
        XCTAssertFalse(tab.surface.tools.allowsSelection, "and still refuses a tool-module")
        XCTAssertFalse(tab.toolSelectionAllowed, "and the menu agrees")
        let savedTab = tab.workspaceTab()
        XCTAssertTrue(savedTab.code?.showsC ?? false, "the workspace remembers the screen")

        // A code tab that becomes an ordinary tab puts the title bar back on
        // its dump, with the pane's own close control again.
        let url = try tempFile([UInt8](repeating: 0x55, count: 0x80))
        try tab.windowModel.pane1.open(url: url)
        tab.apply(mode: .singleFile)
        tab.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(paneView.isHeaderHoisted)
        XCTAssertFalse(paneView.hidesCloseButton)
        XCTAssertTrue(header.isDescendant(of: paneView))
        XCTAssertFalse(close.isHidden)
        try? FileManager.default.removeItem(at: url)
    }


    /// A module with two stored analyses: the header offers the other one, and
    /// choosing it redraws the same panel with that artifact.
    func testAnotherRecipeRedrawsTheSamePanel() async throws {
        let bytes = [UInt8](repeating: 0x90, count: 0x100)
        let one = Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x0","name":"first","instructions":[
            {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
        """.utf8)
        let two = Data("""
        {"script_version":2,"ghidra":"12.2","functions":[
          {"entry":"0x0","name":"second","instructions":[
            {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
        """.utf8)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(bytes)),
                                    size: bytes.count, name: "CpuPei", kind: "TE",
                                    language: "x86:LE:32:default", imageBase: "0x0")
        let first = try store.putAnalysis(
            module: module,
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: one)
        let second = try store.putAnalysis(
            module: module,
            recipe: AnalysisRecipe(id: "code-v3-ghidra-12.2", exporter: 3,
                                   ghidra: "12.2", script: "ExportCode.java"),
            artifact: two)
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = root
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x300))
        controller.openCode(
            named: "CpuPei body", from: controller.windowModel.pane1,
            source: 0x100..<0x200, manifest: first,
            artifact: try JSONDecoder().decode(CodeArtifact.self, from: one),
            recipes: [first, second],
            codec: ReadOnlyPartCodec(bytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        let id = try XCTUnwrap(controller.fragments.expanded)
        let before = try XCTUnwrap(controller.fragments.codePane(id))
        XCTAssertEqual(before.offeredRecipes.map(\.recipe.id),
                       [first.recipe.id, second.recipe.id])

        before.chooseRecipe(at: 1)
        try await until {
            controller.fragments.codePane(id)?.manifest.recipe.id == second.recipe.id
        }
        let after = try XCTUnwrap(controller.fragments.codePane(id))
        XCTAssertEqual(after.selectedFunction?.name, "second")
        XCTAssertEqual(controller.fragments.expanded, id, "the panel did not move")
    }


    /// The agent reads the same typed artifact the panel shows: no second
    /// parse, and the module offset beside Ghidra's address.
    func testTheAgentReadsTheCodeArtifact() async throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x300))
        let bytes = [UInt8](repeating: 0x90, count: 0x100)
        let manifest = AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: Data(bytes)), size: bytes.count,
                                   name: "CpuPei", kind: "TE", language: "x86:LE:32:default",
                                   imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(sha256: SHA256Digest(data: Data("artifact".utf8)),
                                       size: 8, mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00", stats: AnalysisStats())
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","strings":[
          {"address":"0x10","type":"string","value":"hello"}],
         "functions":[{"entry":"0x0","name":"entry","c":"void entry(void) { }","instructions":[
          {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"},
          {"address":"0x1","bytes":"E8 00 00 00 00","mnemonic":"CALL","text":"CALL 0x00000020",
           "references":[{"to":"0x20","type":"UNCONDITIONAL_CALL"}]}]},
          {"entry":"0x20","name":"FUN_00000020","instructions":[
          {"address":"0x20","bytes":"C3","mnemonic":"RET","text":"RET"}]}]}
        """.utf8))
        controller.openCode(
            named: "CpuPei body", from: controller.windowModel.pane1,
            source: 0x100..<0x200, manifest: manifest, artifact: artifact,
            codec: ReadOnlyPartCodec(bytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        let desk = AgentDesk(controllers: { [controller] }, keyController: { controller })
        let tool = try XCTUnwrap(AgentCodeTools(desk: desk).tools().first)
        let answer = try await tool.run(AgentCall(
            tool: tool.name,
            arguments: AgentArguments(["what": .string("functions")])))
        guard case .json(let value) = answer,
              case .string(let module)? = value["module"],
              case .array(let functions)? = value["functions"],
              case .object(let first)? = functions.first
        else { return XCTFail("a functions answer") }
        XCTAssertEqual(module, "CpuPei")
        XCTAssertEqual(first["name"]?.stringValue, "entry")

        let strings = try await tool.run(AgentCall(
            tool: tool.name,
            arguments: AgentArguments(["what": .string("strings")])))
        guard case .json(let stringValue) = strings,
              case .array(let rows)? = stringValue["strings"],
              case .object(let row)? = rows.first
        else { return XCTFail("a strings answer") }
        XCTAssertEqual(row["value"]?.stringValue, "hello")

        let c = try await tool.run(AgentCall(
            tool: tool.name,
            arguments: AgentArguments(["what": .string("c"), "function": .string("entry")])))
        guard case .json(let cValue) = c else { return XCTFail("a C answer") }
        XCTAssertEqual(cValue["c"]?.stringValue, "void entry(void) { }")

        let uses = try await tool.run(AgentCall(
            tool: tool.name,
            arguments: AgentArguments(["what": .string("uses"), "address": .string("0x20")])))
        guard case .json(let usesValue) = uses,
              case .array(let found)? = usesValue["uses"],
              case .object(let use)? = found.first
        else { return XCTFail("a uses answer") }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(use["from"]?.stringValue, "0x1")
        XCTAssertEqual(use["function"]?.stringValue, "entry")
    }

    /// A zone "FFSv2" at 0x100..<0x180 of a 0x400-byte dump, opened as a panel
    /// over the dump it came out of — which is where a part opens
    /// (`Design/FRAGMENT_PANELS_PLAN.md`). The parent is that controller's own
    /// pane 1; the part is the panel's pane.
    private func openZonePanel() throws -> (controller: MainViewController, part: PaneViewModel) {
        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x400))
        try host(controller).publish(
            ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x180)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x120)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “FFSv2”" })
        _ = item.target?.perform(item.action, with: item)
        let id = try XCTUnwrap(controller.fragments.expanded, "the part opens in a panel, raised")
        // The panel is placed by frame arithmetic, so its subtree has to be
        // laid out before the pane's own chrome — the link button among it —
        // knows whether it fits.
        controller.view.window?.layoutIfNeeded()
        controller.fragments.panelView(id)?.layoutSubtreeIfNeeded()
        return (controller, try XCTUnwrap(controller.fragments.pane(id)))
    }

    private func link(of part: PaneViewModel, in controller: MainViewController) throws -> NSButton {
        controller.paneView(for: part).linkButton
    }

    /// The part in the panel `controller` has raised — what every route that
    /// opens one leaves on screen.
    private func openedPart(in controller: MainViewController) throws -> PaneViewModel {
        let id = try XCTUnwrap(controller.fragments.expanded, "a part opens in a raised panel")
        return try XCTUnwrap(controller.fragments.pane(id))
    }

    /// A tool-module on the raised panel's own surface, bound to the part.
    private func partHost(_ controller: MainViewController) throws -> PaneToolHost {
        let id = try XCTUnwrap(controller.fragments.expanded)
        try XCTUnwrap(controller.fragments.surface(id)).tools.activate(StubToolA.identifier,
                                                                      animated: false)
        return try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
    }

    // MARK: - The link

    func testAZoneTabIsLinkedToTheZoneAndNamesItsParent() throws {
        let (controller, part) = try openZonePanel()

        let origin = try XCTUnwrap(part.origin)
        XCTAssertTrue(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.sourceRange, 0x100..<0x180)
        XCTAssertEqual(origin.partName, "FFSv2")
        XCTAssertEqual(origin.state, .intact)

        let button = try link(of: part, in: controller)
        XCTAssertFalse(button.isHidden, "the header shows the link")
        XCTAssertEqual(button.title, controller.windowModel.pane1.status.fileName)
        XCTAssertEqual(button.toolTip?.contains("FFSv2"), true)
    }

    /// An edit to the source breaks the link and undoing it mends it; an edit
    /// elsewhere in the parent leaves it alone.
    func testTheLinkFollowsTheSourceBytes() throws {
        let (controller, part) = try openZonePanel()
        let parentHost = try host(controller)
        let origin = try XCTUnwrap(part.origin)

        try parentHost.apply(ToolTransaction(name: "Elsewhere", offset: 0x10, bytes: [0x01]))
        XCTAssertEqual(origin.state, .intact, "an edit outside the source")

        try parentHost.apply(ToolTransaction(name: "Inside", offset: 0x140, bytes: [0x02]))
        XCTAssertEqual(origin.state, .sourceChanged)
        XCTAssertEqual(try link(of: part, in: controller).toolTip?.contains("changed"), true,
                       "the header redraws when the parent changes")

        _ = try controller.windowModel.pane1.undo()
        XCTAssertEqual(origin.state, .intact, "the bytes are the ones taken out again")
    }

    func testClosingTheParentBreaksTheLink() throws {
        let (controller, part) = try openZonePanel()
        let origin = try XCTUnwrap(part.origin)
        let name = controller.windowModel.pane1.status.fileName

        controller.windowModel.pane1.close()

        XCTAssertEqual(origin.state, .parentClosed)
        XCTAssertEqual(origin.parentName, name, "still says which file it was")
        XCTAssertEqual(try link(of: part, in: controller).toolTip?.contains("no longer open"), true)
    }

    /// Another file dropped into the tab replaces the part: no link any more.
    func testReplacingTheTabsContentDropsTheLink() throws {
        let (_, part) = try openZonePanel()
        let url = try tempFile([0x01, 0x02])
        files.append(url)

        try part.open(url: url)

        XCTAssertNil(part.origin)
    }

    func testClickingTheLinkSelectsTheSourceInTheParent() throws {
        let (controller, part) = try openZonePanel()

        controller.revealOrigin(of: part)

        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x180)
    }

    /// A link whose parent is itself a panel: the parent panel comes to the
    /// front with the source selected in it — not a silent no-op, the case
    /// `controller(holding:)` cannot see because the parent is not a window
    /// pane (`Design/FRAGMENT_PANELS_PLAN.md`).
    func testClickingTheLinkInANestedPanelSelectsTheSourceInTheParentPanel() throws {
        let controller = try makeController()
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(outer))
        let host = try partHost(controller)

        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x13)

        let inner = try XCTUnwrap(controller.fragments.expanded, "the inner part opens raised")
        let deeper = try XCTUnwrap(controller.fragments.pane(inner))
        XCTAssertTrue(deeper.origin?.parent === part, "the inner part's parent is the outer panel")

        controller.view.window?.layoutIfNeeded()

        controller.revealOrigin(of: deeper)

        XCTAssertEqual(controller.fragments.expanded, outer,
                       "the parent panel comes to the front")
        let selection = part.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x10..<0x13,
                       "and the source is selected in it, in its own offsets")
    }

    /// A part torn off into a tab whose parent stayed behind as a panel: the
    /// link still leads somewhere, and clicking it raises that panel in the
    /// window it belongs to. The parent is a document of that window held in a
    /// panel rather than in a pane, which is what the search for its window
    /// used to miss.
    func testALinkFromATabToAPanelOfAnotherWindowLeadsThere() throws {
        let (controller, part) = try openZonePanel()
        let host = try partHost(controller)
        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x13)
        let deeper = try openedPart(in: controller)
        XCTAssertTrue(deeper.origin?.parent === part, "opened out of the panel, not the dump")

        let tab = try makeController()
        let registry = OpenDocumentRegistry()
        registry.register(controller)
        registry.register(tab)
        controller.openDocuments = registry
        tab.openDocuments = registry
        controller.makeSiblingTab = { tab }
        controller.tearOffPaneToNewTab(draggedPaneID: deeper.dragID)
        XCTAssertTrue(tab.windowModel.pane1 === deeper, "the part is a tab of its own now")
        XCTAssertEqual(controller.fragments.count, 1, "and its parent is still a panel back there")
        controller.fragments.collapse(animated: false)

        tab.revealOrigin(of: deeper)

        XCTAssertEqual(controller.fragments.expanded,
                       controller.fragments.panel(holding: part),
                       "the panel holding the parent is raised in its own window")
        let selection = part.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x10..<0x13,
                       "and the source is selected in it")
    }

    /// Where the bytes land must not be left under something else. A folded
    /// panel put back into the dump while *another* panel is up used to leave
    /// that other panel standing over the very thing this is here to show.
    func testUpdatingAFoldedPanelClearsWhateverIsCoveringTheDump() throws {
        let (controller, part) = try openZonePanel()
        let other = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x40),
                                                          named: "other", animated: false))
        XCTAssertEqual(controller.fragments.expanded, other, "the other panel is the one up")
        try patch(part, at: 0x10, with: 0x55)

        XCTAssertNil(controller.performUpdateInParent(of: part), "written on the spot")

        XCTAssertNil(controller.fragments.expanded,
                     "the stage is cleared, whichever panel was standing on it")
        XCTAssertEqual(controller.fragments.count, 2, "both panels are still open, in their pills")
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x180,
                       "and what landed is selected where it landed")
    }

    /// The header says **Modified** and offers the update while the part holds
    /// bytes its parent does not have, and takes both away once they are back.
    /// The update says last where it can be undone: in the parent.
    func testTheHeaderOffersTheUpdateWhileThePartIsModified() throws {
        let (controller, part) = try openZonePanel()
        let view = controller.paneView(for: part)
        XCTAssertTrue(view.updateButton.isHiddenOrHasHiddenAncestor, "nothing to put back yet")

        try patch(part, at: 0x10, with: 0x55)
        controller.fragments.panelView(try XCTUnwrap(controller.fragments.expanded))?
            .layoutSubtreeIfNeeded()

        XCTAssertFalse(view.updateButton.isHiddenOrHasHiddenAncestor, "modified: the button is there")
        XCTAssertEqual(view.updateButton.accessibilityLabel(), "Update in Parent")
        XCTAssertEqual(view.updateButton.title, "Modified")
        XCTAssertTrue(view.updateButton.isBordered, "a button with a border, not a bare glyph")
        // Measured on what the layout places — the alignment rects — not on
        // the frames: a bordered button's frame takes in the room its bezel
        // draws in, a few points either side of what is seen.
        let update = view.updateButton.alignmentRect(forFrame: view.updateButton.frame)
        let link = view.linkButton.alignmentRect(forFrame: view.linkButton.frame)
        XCTAssertEqual(update.minX - link.maxX, 6, accuracy: 0.5, "right after the parent's name")

        view.updateButton.performClick(nil)

        XCTAssertEqual(try controller.windowModel.pane1.byteStorage?.read(at: 0x110, length: 1), [0x55])
        XCTAssertEqual(controller.lastAlertTitle,
                       "Updated “\(controller.windowModel.pane1.status.fileName)”")
        XCTAssertTrue(try XCTUnwrap(controller.lastAlertMessage).contains("takes it back"))
        XCTAssertEqual(controller.lastAlertOutcome, .success)
        XCTAssertTrue(view.updateButton.isHiddenOrHasHiddenAncestor, "and gone once it is back")
    }

    /// A fragment is named by what was opened, without the dump around it:
    /// the panel, its pill and its link all say the zone's name.
    func testAFragmentIsNamedByWhatWasOpenedAlone() throws {
        let (controller, part) = try openZonePanel()
        XCTAssertEqual(part.status.fileName, "FFSv2")
        XCTAssertEqual(part.origin?.partName, "FFSv2")
        XCTAssertEqual(MainViewController.saveAsName(for: part), "FFSv2.bin", "saved, it is a file of bytes")
        XCTAssertEqual(try XCTUnwrap(descendants(of: controller.view, FragmentDockStrip.self).first).pillsForTesting.map(\.title), ["FFSv2"])
    }

    /// A part torn off into a tab of its own keeps the link: the origin is the
    /// pane's own property, so Update in Parent still knows where the bytes go
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    func testAPartTornOffIntoATabKeepsItsLink() throws {
        let (controller, part) = try openZonePanel()
        let tab = try makeController()
        controller.makeSiblingTab = { tab }

        controller.tearOffPaneToNewTab(draggedPaneID: part.dragID)

        XCTAssertTrue(controller.fragments.isEmpty)
        XCTAssertTrue(tab.windowModel.pane1 === part)
        let origin = try XCTUnwrap(part.origin, "still linked to the zone it came out of")
        XCTAssertTrue(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.state, .intact)

        try patch(part, at: 0x10, with: 0x55)
        tab.performUpdateInParent(of: part)
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0x55,
                       "and the bytes still go back where they came from")
    }

    // MARK: - Against the bytes it was opened with

    private func modified(_ range: Range<UInt64>, in part: PaneViewModel) -> [Bool] {
        part.hexByteStates(in: range).map(\.isModified)
    }

    /// An edit in a part's tab reads as modified against the bytes the part
    /// was opened with — in the hex view and on the minimap's source — and
    /// still does after the edit has been put back into the controller.
    func testAnEditInAPartsTabReadsAsModified() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        XCTAssertTrue(pane.marksModifiedBytes)
        XCTAssertEqual(modified(0x0F..<0x12, in: part), [false, false, false], "nothing edited yet")

        try patch(part, at: 0x10, with: 0x55)
        XCTAssertEqual(modified(0x0F..<0x12, in: part), [false, true, false])

        try patch(part, at: 0x10, with: 0xAA)
        XCTAssertEqual(modified(0x0F..<0x12, in: part), [false, false, false],
                       "the original byte back is not a modification")

        try patch(part, at: 0x10, with: 0x55)
        controller.performUpdateInParent(of: pane)
        XCTAssertEqual(modified(0x10..<0x11, in: part), [true], "still not what the tab was opened with")
    }

    /// An untitled document with no parent has nothing to be modified against.
    func testAPlainUntitledDocumentMarksNothing() throws {
        let controller = try makeController()
        let pane = controller.windowModel.pane1
        pane.openBytes([1, 2, 3], named: "bytes.bin")
        try pane.applyToolWrites([(offset: 1, bytes: [9])], named: "Patch")

        XCTAssertFalse(pane.marksModifiedBytes)
        XCTAssertEqual(pane.hexByteStates(in: 0..<3).map(\.isModified), [false, false, false])
    }

    /// In a part's tab, Revert to Saved is Revert to Original: asked first,
    /// it drops every edit and leaves the tab linked, holding what it opened with.
    func testRevertToOriginalGoesBackToTheBytesTheTabOpenedWith() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        let menu = controller.makePaneMenu(for: pane)
        let item = try XCTUnwrap(menu.items.first {
            $0.action == #selector(MainViewController.revertPaneDocument(_:))
        })
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Revert to Original")
        XCTAssertEqual(controller.makePaneMenu(for: controller.windowModel.pane1).items.first {
            $0.action == #selector(MainViewController.revertPaneDocument(_:))
        }.map { controller.validateMenuItem($0) ? $0.title : "disabled" }, "Revert to Saved")

        try patch(part, at: 0x10, with: 0x55)
        var asked: String?
        MainViewController.modalResponder = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }
        defer { MainViewController.modalResponder = nil }
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(asked, "Revert to the original bytes?")
        XCTAssertEqual(try byte(at: 0x10, of: part), 0x55, "cancelled")

        MainViewController.modalResponder = { _ in .alertFirstButtonReturn }
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(try byte(at: 0x10, of: part), 0xAA)
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertFalse(pane.status.canUndo, "the edits are gone, not undoable")
        XCTAssertEqual(modified(0x10..<0x11, in: part), [false])
        XCTAssertNotNil(pane.origin, "still linked")
        XCTAssertFalse(try XCTUnwrap(pane.origin).hasChanges(in: pane))
    }

    // MARK: - What the bytes are

    /// The report: a Tiano section's body opened in a tab showed only padding
    /// in UEFI Structure. Linked as a decompressed body, it reads as sections.
    func testADecompressedBodyTabIsReadAsSections() async throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xFF, count: 0x100))
        let parentHost = try host(controller)
        // Two user-interface sections, "Drv" and "Set", twelve bytes each.
        let section: (String) -> [UInt8] = { text in
            [0x0C, 0x00, 0x00, 0x15] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        }

        parentHost.openPart(section("Drv") + section("Set"), named: "bios_Body.bin",
                                linkedTo: 0x20..<0x80, layout: .decompressedBody,
                                part: .init(space: .decompressed(chain: [0x20])))

        let part = try openedPart(in: controller)
        XCTAssertEqual(part.origin?.layout, .decompressedBody)
        let tree = try XCTUnwrap(try partHost(controller).uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        XCTAssertEqual(tree.layout, .decompressedBody)
        XCTAssertEqual(tree.rootNodes.map(\.kind), [.section, .section])
    }

    /// A zone of a UEFI file is told what it is by the parent's tree.
    func testAZoneOfAUEFINodeIsToldWhatItIs() throws {
        let (_, part) = try openZonePanel()
        // The dump is all 0xAA: no node covers the zone, so it is an image.
        XCTAssertEqual(part.origin?.layout, .image)
    }

    // MARK: - Update in Parent (§3)

    private func byte(at offset: UInt64, of pane: PaneViewModel) throws -> UInt8 {
        try XCTUnwrap(pane.document?.read(at: offset, length: 1).first)
    }

    private func patch(_ part: PaneViewModel, at offset: UInt64, with value: UInt8) throws {
        try part.applyToolWrites([(offset: offset, bytes: [value])], named: "Patch")
    }

    /// The tab's bytes go back over the zone as one undo step in the parent,
    /// named after the tab, and the link then has nothing left to put back.
    func testUpdatingAZoneWritesTheTabBackAsOneUndoStep() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        let origin = try XCTUnwrap(pane.origin)
        try patch(part, at: 0x10, with: 0x55)
        XCTAssertTrue(origin.hasChanges(in: pane))

        controller.performUpdateInParent(of: pane)

        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0x55)
        XCTAssertEqual(controller.windowModel.pane1.undoLabel, "Update from \(pane.status.fileName)")
        XCTAssertTrue(controller.windowModel.pane1.status.isDirty, "written to the parent, not to its file")
        XCTAssertEqual(origin.state, .intact)
        XCTAssertFalse(origin.hasChanges(in: pane))
        XCTAssertEqual(try link(of: part, in: controller).toolTip?.contains("Click to show"), true,
                       "the header shows the link intact after the parent's own change")

        _ = try controller.windowModel.pane1.undo()
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0xAA)
        XCTAssertEqual(origin.state, .sourceChanged, "the parent no longer holds what the tab put back")
    }

    /// The bytes go back, and the panel gets out of the way so the change can
    /// be seen landing: it folds into its pill, and the dump behind it has the
    /// part selected where it went.
    func testUpdatingFoldsThePanelAndShowsWhereItLanded() throws {
        let (controller, part) = try openZonePanel()
        try patch(part, at: 0x10, with: 0x55)
        XCTAssertNotNil(controller.fragments.expanded, "the premise: the panel is up")

        controller.performUpdateInParent(of: part)

        XCTAssertNil(controller.fragments.expanded,
                     "the panel folds — watching it land is why a part opens over its parent")
        XCTAssertEqual(controller.fragments.count, 1, "folded, not closed")
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x180,
                       "and the dump shows the bytes that just arrived")
    }

    /// Offered in the header's menu, named after the parent, and enabled only
    /// when there is something to put back.
    func testTheCommandIsOfferedWhenThereIsSomethingToPutBack() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        let menu = controller.makePaneMenu(for: pane)
        let item = try XCTUnwrap(menu.items.first {
            $0.action == #selector(MainViewController.updatePaneInParent(_:))
        })

        XCTAssertFalse(controller.validateMenuItem(item), "nothing changed yet")
        XCTAssertEqual(item.title, "Update in “\(controller.windowModel.pane1.status.fileName)”")

        try patch(part, at: 0, with: 0x01)
        XCTAssertTrue(controller.validateMenuItem(item))

        controller.windowModel.pane1.close()
        XCTAssertFalse(controller.validateMenuItem(item), "no parent to put it back into")
    }

    func testALengthChangeIsRefused() throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xAA, count: 0x100))
        try host(controller).openPart([0x01, 0x02, 0x03], named: "part.bin", linkedTo: 0x10..<0x20)
        let part = try openedPart(in: controller)
        try patch(part, at: 0, with: 0x09)

        controller.performUpdateInParent(of: part)

        XCTAssertEqual(controller.lastAlertTitle, "The length changed")
        XCTAssertEqual(try byte(at: 0x10, of: controller.windowModel.pane1), 0xAA, "nothing was written")
    }

    /// A source edited in the parent since is overwritten only when the reader
    /// says so.
    func testAChangedSourceIsOverwrittenOnlyWhenConfirmed() throws {
        let (controller, part) = try openZonePanel()
        let pane = part
        try host(controller).apply(ToolTransaction(name: "Meanwhile", offset: 0x150, bytes: [0x77]))
        try patch(part, at: 0x10, with: 0x55)
        var asked: String?

        controller.updateConfirm = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }
        controller.performUpdateInParent(of: pane)
        XCTAssertEqual(asked, "“FFSv2” has changed in \(controller.windowModel.pane1.status.fileName)")
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0xAA, "cancelled")
        XCTAssertEqual(try byte(at: 0x150, of: controller.windowModel.pane1), 0x77)

        controller.updateConfirm = { _ in .alertFirstButtonReturn }
        controller.performUpdateInParent(of: pane)
        XCTAssertEqual(try byte(at: 0x110, of: controller.windowModel.pane1), 0x55)
        XCTAssertEqual(try byte(at: 0x150, of: controller.windowModel.pane1), 0xAA, "the tab's bytes, the parent's change overwritten")
        XCTAssertEqual(pane.origin?.state, .intact)
    }

    /// A decompressed body goes back through the rebuild planner; one whose
    /// section is not in the parent any more is refused with the reason, and
    /// nothing is written.
    func testADecompressedBodyWhoseSectionIsGoneIsRefused() async throws {
        let controller = try makeController(opening: [UInt8](repeating: 0xFF, count: 0x100))
        try host(controller).openPart([UInt8](repeating: 0, count: 0x60), named: "body",
                                      linkedTo: 0x20..<0x80, layout: .decompressedBody,
                                      part: .init(space: .decompressed(chain: [0x20])))
        let part = try openedPart(in: controller)
        try patch(part, at: 0, with: 0x01)

        await controller.performUpdateInParent(of: part)?.value

        XCTAssertEqual(controller.lastAlertTitle, "“body” cannot be put back")
        XCTAssertEqual(try byte(at: 0x20, of: controller.windowModel.pane1), 0xFF)
    }

    /// Waits, a little at a time and for two seconds at most, until `done` —
    /// for what lands on the main actor after an animation, like a sheet going.
    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Cancel on the update's sheet abandons it: the sheet goes, and nothing is
    /// written into the controller.
    func testCancellingTheUpdateSheetWritesNothing() async throws {
        let controller = try makeController(opening: UEFITestImage.make())
        let parentHost = try host(controller)
        let tree = try XCTUnwrap(parentHost.uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.expand(NodeID.root.child(0)) { _ in done.resume() }
        }
        parentHost.publish(ZoneMap(zones: [Zone(id: "0.0", name: "MyDriver", range: 0x48..<0x8C)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x50)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “MyDriver”" })
        _ = item.target?.perform(item.action, with: item)
        let part = try openedPart(in: controller)
        let pane = part
        try patch(part, at: 0x34, with: 0x00)
        let before = try XCTUnwrap(controller.windowModel.pane1.document?.read(at: 0, length: 0x1000))

        let update = controller.performUpdateInParent(of: pane)
        let sheet = try XCTUnwrap(controller.presentedViewControllers?.first as? BlockingOperationSheet)
        sheet.cancelButton.performClick(nil)
        await update?.value
        try await until { (controller.presentedViewControllers ?? []).isEmpty }

        XCTAssertTrue((controller.presentedViewControllers ?? []).isEmpty, "the sheet goes")
        XCTAssertFalse(sheet.operation.isActive)
        XCTAssertEqual(controller.windowModel.pane1.document.flatMap { try? $0.read(at: 0, length: 0x1000) }, before,
                       "nothing was written")
        XCTAssertNotEqual(controller.lastAlertTitle, "Updated “\(controller.windowModel.pane1.status.fileName)”")
    }

    /// A zone that is a file of the image goes back through the planner, which
    /// puts the file's checksums right around the edit.
    func testAZoneThatIsAFileGoesBackWithItsChecksumsRight() async throws {
        let controller = try makeController(opening: UEFITestImage.make())
        let parentHost = try host(controller)
        let tree = try XCTUnwrap(parentHost.uefiTree())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.expand(NodeID.root.child(0)) { _ in done.resume() }
        }
        parentHost.publish(ZoneMap(zones: [Zone(id: "0.0", name: "MyDriver", range: 0x48..<0x8C)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x50)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open Zone “MyDriver”" })
        _ = item.target?.perform(item.action, with: item)
        let part = try openedPart(in: controller)
        let pane = part
        XCTAssertEqual((pane.origin?.codec as? UEFIPartCodec)?.target,
                       UEFIRebuild.Target(space: .file, range: 0x48..<0x8C))

        // The raw section's first payload byte.
        try patch(part, at: 0x34, with: 0x00)
        let update = controller.performUpdateInParent(of: pane)
        // The work lands in the parent: a sheet on its window says so while it
        // runs, and keeps the parent from being edited under it. One window
        // now, since the part opens over its parent rather than in a tab.
        let sheet = try XCTUnwrap(controller.presentedViewControllers?.first as? BlockingOperationSheet,
                                  "a sheet on the parent's window")
        XCTAssertTrue(sheet.titleLabel.stringValue.contains("MyDriver"), sheet.titleLabel.stringValue)
        XCTAssertEqual(sheet.cancelButton.title, "Cancel")
        let operation = sheet.operation
        await update?.value
        try await until { !operation.isActive && (controller.presentedViewControllers ?? []).isEmpty }
        XCTAssertFalse(operation.isActive, "done")
        XCTAssertTrue((controller.presentedViewControllers ?? []).isEmpty, "the sheet goes when the update is done")

        XCTAssertEqual(try byte(at: 0x48 + 0x34, of: controller.windowModel.pane1), 0x00)
        let bytes = try XCTUnwrap(controller.windowModel.pane1.document?.read(at: 0, length: 0x1000))
        let checksums = UEFIParser.parse(bytes).diagnostics.filter { "\($0.kind)".hasPrefix("checksumMismatch") }
        XCTAssertEqual(checksums, [], "the file's checksums were put right")
        XCTAssertEqual(controller.lastAlertTitle, "Updated “\(controller.windowModel.pane1.status.fileName)”")
        XCTAssertEqual(pane.origin?.state, .intact)
        XCTAssertEqual(pane.origin?.hasChanges(in: pane), false)
    }

    /// A minimal TE image with a `.text` section at address 0 whose one byte
    /// lands at module offset 0x40 — the fixture the code screen's address map
    /// can answer for.
    private func teModule() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x56
        bytes[1] = 0x5A
        put16(&bytes, 2, 0x14C)
        bytes[4] = 1
        put16(&bytes, 6, 0x28)
        put32(&bytes, 8, 0)
        put32(&bytes, 12, 0)
        put64(&bytes, 16, 0)
        let section = 40
        for (index, byte) in Array(".text".utf8).enumerated() {
            bytes[section + index] = byte
        }
        put32(&bytes, section + 8, 0x10)
        put32(&bytes, section + 12, 0)
        put32(&bytes, section + 16, 0x10)
        put32(&bytes, section + 20, 0x50)
        put32(&bytes, section + 36, 0x6000_0020)
        bytes[0x50] = 0x90
        return bytes
    }

    private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        for index in 0..<2 {
            bytes[offset + index] = UInt8((value >> (8 * UInt16(index))) & 0xFF)
        }
    }

    private func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF)
        }
    }

    private func put64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF)
        }
    }
}
