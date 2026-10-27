import ByteRipperCore
import CodeAnalysis
import Localization
import PartCodec
import ToolModuleKit
import UEFIToolUI
import Workspace
import XCTest
@testable import ByteRipper

/// A tab written down and put back into a fresh one (`Design/WORKSPACE_PLAN.md`):
/// the files, which pane has the keyboard, the selection, the typing mode, the
/// split and the rows on screen.
@MainActor
final class WorkspaceRestoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspaceSettings.resetToDefaults()
    }

    override func tearDown() {
        WorkspaceSettings.resetToDefaults()
        super.tearDown()
    }

    /// A window on screen, so the panes have a height to scroll in.
    private func shownWindow() -> MainWindowController {
        let controller = MainWindowController(frameAutosaveName: nil)
        controller.showWindow(nil)
        controller.window?.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: true)
        addTeardownBlock { controller.close() }
        return controller
    }

    /// Restores `tabs` the way a launch does: every tab's files first, then
    /// the parts, wherever each one's parent is.
    private func restore(_ tabs: [(TabState, MainViewController)],
                         keeper: ContentKeeper? = nil) async -> [RestoreIssue] {
        let restorer = WorkspaceRestorer(keeper: keeper)
        for (tab, controller) in tabs { restorer.openFiles(of: tab, in: controller) }
        await restorer.openParts()
        return restorer.issues
    }

    private func dump(_ size: Int, _ fill: UInt8) throws -> URL {
        try tempFile([UInt8](repeating: fill, count: size), "\(fill)")
    }

    private func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let view = view as? T { return view }
        for subview in view.subviews {
            if let found = firstDescendant(type, in: subview) { return found }
        }
        return nil
    }

    func testAComparisonComesBackAsItWas() async throws {
        let a = try dump(0x10000, 0xAA)
        let b = try dump(0x10000, 0xBB)
        let source = shownWindow().mainViewController
        source.openFiles([a, b])
        source.view.layoutSubtreeIfNeeded()
        let paneB = source.windowModel.pane2
        paneB.select(range: 0x4010..<0x4020)
        paneB.setInputRegion(.ascii)
        source.flipInsertMode(of: paneB)
        source.comparisonView?.setFraction(0.3)
        source.filePaneView(for: paneB)?.scrollRowToTop(containing: 0x4000)
        source.activatePane(at: 1)

        let tab = source.workspaceTab()
        XCTAssertEqual(tab.activePane, 1)
        XCTAssertEqual(try XCTUnwrap(tab.dividerFraction), 0.3, accuracy: 0.01)
        let savedB = try XCTUnwrap(tab.panes[1])
        XCTAssertEqual(savedB.topOffset, 0x4000)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)])

        XCTAssertEqual(issues, [])
        XCTAssertEqual(target.mode, .comparison)
        XCTAssertEqual(target.windowModel.pane1.document?.url.standardizedFileURL, a.standardizedFileURL)
        XCTAssertEqual(target.windowModel.pane2.document?.url.standardizedFileURL, b.standardizedFileURL)
        XCTAssertEqual(target.windowModel.activePaneIndex, 1)
        let restoredB = target.windowModel.pane2
        XCTAssertEqual(restoredB.document?.selection.start, 0x4010)
        XCTAssertEqual(restoredB.document?.selection.end, 0x4020)
        XCTAssertEqual(restoredB.inputRegion, .ascii)
        XCTAssertTrue(restoredB.isInsertMode)
        XCTAssertFalse(target.windowModel.pane1.isInsertMode)
        XCTAssertEqual(try XCTUnwrap(target.comparisonView?.currentFraction), 0.3, accuracy: 0.01)
        XCTAssertEqual(target.filePaneView(for: restoredB)?.firstVisibleOffset, 0x4000)
    }

    func testAMissingFileIsReportedAndTheOtherOpensAlone() async throws {
        let a = try dump(0x100, 0xAA)
        let b = try dump(0x100, 0xBB)
        let source = shownWindow().mainViewController
        source.openFiles([a, b])
        let tab = source.workspaceTab()
        source.windowModel.pane1.close()
        try FileManager.default.removeItem(at: a)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)])

        XCTAssertEqual(issues, [.missing(path: a.standardizedFileURL.path)])
        XCTAssertEqual(target.mode, .singleFile)
        XCTAssertEqual(target.windowModel.pane1.document?.url.standardizedFileURL, b.standardizedFileURL,
                       "a file alone is File A")
    }

    func testAShorterFileIsReportedAndTheCaretMovesToItsEnd() async throws {
        let a = try dump(0x1000, 0xAA)
        let source = shownWindow().mainViewController
        source.openFiles([a])
        source.windowModel.pane1.select(range: 0xF00..<0xF00)
        let tab = source.workspaceTab()
        source.windowModel.pane1.close()
        try Data(repeating: 0x11, count: 0x800).write(to: a)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)])

        XCTAssertEqual(issues, [.changed(path: a.standardizedFileURL.path)])
        XCTAssertEqual(target.windowModel.pane1.document?.selection.start, 0x7FF)
    }

    // MARK: - Around the panes

    func testBookmarksSegmentsMinimapAndFindBarComeBack() async throws {
        let a = try dump(0x2000, 0xAA)
        let chip = try dump(0x1000, 0xCC)
        let source = shownWindow().mainViewController
        source.openFiles([a])
        let pane = source.windowModel.pane1
        _ = source.windowModel.bookmarkStore.add(rowContaining: 0x110, name: "boot block")
        _ = source.windowModel.bookmarkStore.add(rowContaining: 0x1F00, name: "")
        XCTAssertTrue(pane.segmentStore.addCut(at: 0x1000))
        pane.segmentStore.rename(1, to: "chip 2")
        pane.restoreSegments(SegmentationState(contentSize: 0x2000, pieces: [
            PieceState(start: 0, name: "chip 1",
                       link: PieceLinkState(path: chip.standardizedFileURL.path, sourceStart: 0, sourceEnd: 0x1000)),
            PieceState(start: 0x1000, name: "chip 2"),
        ]))
        source.surface.minimap.setPanelVisible(true, animated: false)
        source.surface.minimap.setRenderMode(.overview)
        source.reopenFindBar(text: "AA BB", encoding: .hex)

        let tab = source.workspaceTab()
        XCTAssertEqual(tab.bookmarks, [BookmarkState(row: 0x110, name: "boot block"),
                                       BookmarkState(row: 0x1F00, name: "")])
        XCTAssertEqual(tab.panes[0]?.segments?.pieces.count, 2)
        source.windowModel.pane1.close()

        let target = shownWindow().mainViewController
        let restoreIssues = await restore([(tab, target)])
        XCTAssertEqual(restoreIssues, [])

        XCTAssertEqual(target.windowModel.bookmarkStore.bookmarks.map(\.name), ["boot block", ""])
        let restored = target.windowModel.pane1
        XCTAssertEqual(restored.segmentStore.current.pieces.map(\.name), ["chip 1", "chip 2"])
        let link = try XCTUnwrap(restored.segmentStore.current.pieces[0].link)
        XCTAssertEqual(restored.segmentSources.source(link.source)?.url.standardizedFileURL,
                       chip.standardizedFileURL, "the link finds its file by path")
        XCTAssertEqual(link.sourceRange, 0..<0x1000)
        XCTAssertTrue(target.surface.minimap.isPanelVisible)
        XCTAssertEqual(target.surface.minimap.view.renderMode, .overview)
        XCTAssertEqual(target.openFindPattern?.text, "AA BB")
        XCTAssertEqual(target.openFindPattern?.encoding, .hex)
    }

    func testAChangedFileLosesItsSegmentsAndTheBookmarksPastItsEnd() async throws {
        let a = try dump(0x2000, 0xAA)
        let source = shownWindow().mainViewController
        source.openFiles([a])
        _ = source.windowModel.bookmarkStore.add(rowContaining: 0x10, name: "kept")
        _ = source.windowModel.bookmarkStore.add(rowContaining: 0x1800, name: "gone")
        XCTAssertTrue(source.windowModel.pane1.segmentStore.addCut(at: 0x400))
        let tab = source.workspaceTab()
        source.windowModel.pane1.close()
        try Data(repeating: 0, count: 0x1000).write(to: a)

        let target = shownWindow().mainViewController
        let restoreIssues = await restore([(tab, target)])
        XCTAssertEqual(restoreIssues, [.changed(path: a.standardizedFileURL.path)])

        XCTAssertEqual(target.windowModel.bookmarkStore.bookmarks.map(\.name), ["kept"])
        XCTAssertEqual(target.windowModel.pane1.segmentStore.current.pieces.count, 1,
                       "cuts made on other bytes are not put on these")
    }

    // MARK: - Panels

    func testPartsComeBackDecodedFromTheirParentsAndTheFrontOneInFront() async throws {
        let bytes: [UInt8] = (0..<0x1000).map { UInt8(($0 * 7) & 0xFF) }
        let a = try tempFile(bytes, "parts")
        let source = shownWindow().mainViewController
        source.openFiles([a])
        source.openPart(named: "zone", from: source.windowModel.pane1, source: 0x100..<0x300,
                        codec: CopyPartCodec())
        let zoneID = try XCTUnwrap(source.fragments.dock.panels.first)
        let zone = try XCTUnwrap(source.fragments.pane(zoneID))
        zone.select(range: 0x10..<0x18)
        source.openPart(named: "inner", from: zone, source: 0x40..<0x80, codec: CopyPartCodec())
        source.openFragment([9, 9, 9], named: "loose")
        source.fragments.expand(zoneID, animated: false)

        let keeperFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRecorderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: keeperFolder) }
        let keeper = ContentKeeper(folder: WorkspaceFolder(url: keeperFolder))
        let tab = await keeper.settledTabs { [source.workspaceTab(keeper: keeper)] }[0]
        func parent(_ index: Int) -> String? {
            if case let .part(origin) = tab.fragments[index].pane.document { origin.parent } else { nil }
        }
        XCTAssertEqual(parent(0), tab.panes[0]?.id)
        XCTAssertEqual(parent(1), tab.fragments[0].pane.id)
        XCTAssertNil(parent(2))
        XCTAssertEqual(tab.expandedFragment, 0)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: keeper)

        XCTAssertEqual(issues, [])
        let panes = target.fragments.dock.panels.compactMap { target.fragments.pane($0) }
        XCTAssertEqual(panes.map(\.status.fileName), ["zone", "inner", "loose"])
        // A panel missing is a failure, not a crash of the test host.
        guard panes.count == 3 else { return }
        XCTAssertEqual(try panes[0].document?.read(at: 0, length: 0x200), Array(bytes[0x100..<0x300]))
        XCTAssertEqual(try panes[1].document?.read(at: 0, length: 0x40), Array(bytes[0x140..<0x180]))
        XCTAssertIdentical(panes[0].origin?.parent, target.windowModel.pane1, "the part knows its way home")
        XCTAssertIdentical(panes[1].origin?.parent, panes[0])
        XCTAssertNil(panes[2].origin)
        XCTAssertEqual(panes[0].document?.selection.start, 0x10)
        XCTAssertEqual(target.fragments.expanded, target.fragments.panel(holding: panes[0]))
    }

    /// A code panel follows its analysis: published again with a review — a
    /// function renamed, another found before it — the open panel draws the
    /// new artifact, on the same function by address although its index moved.
    func testAnOpenCodePanelFollowsARepublishedReading() async throws {
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        let parentURL = try dump(0x1000, 0x77)
        func artifactData(_ functions: [(String, String)]) -> Data {
            let list = functions.map { entry, name in
                #"{"entry":"\#(entry)","name":"\#(name)","c":"return 0;","instructions":[{"address":"\#(entry)","bytes":"90","mnemonic":"NOP","text":"NOP"}]}"#
            }
            return Data(#"{"script_version":2,"ghidra":"12.1.2","functions":[\#(list.joined(separator: ","))]}"#.utf8)
        }
        let before = artifactData([("0x0", "entry"), ("0x10", "FUN_00000010")])
        let after = artifactData([("0x0", "entry"), ("0x8", "FUN_00000008"), ("0x10", "LoadMicrocode")])

        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeFollowStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try ContentStore(root: storeRoot)
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(codeBytes)),
                                    size: codeBytes.count, name: "CpuPei", kind: "TE",
                                    language: "x86:LE:32:default", imageBase: "0x0")
        let recipe = AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                    ghidra: "12.1.2", script: "ExportCode.java")
        let manifest = try store.putAnalysis(module: module, recipe: recipe, artifact: before)
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = storeRoot
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let source = shownWindow().mainViewController
        source.openFiles([parentURL])
        source.openCode(
            named: "CpuPei body", from: source.windowModel.pane1,
            source: 0x100..<0x200, manifest: manifest,
            artifact: try JSONDecoder().decode(CodeArtifact.self, from: before),
            codec: ReadOnlyPartCodec(codeBytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")),
            at: CodeLocation(function: CodeAddress(0x10)))
        let id = try XCTUnwrap(source.fragments.expanded)
        XCTAssertEqual(source.fragments.codePane(id)?.selectedFunctionIndex, 1)

        try store.putAnalysis(module: module, recipe: recipe, artifact: after,
                              reading: AnalysisReading(project: "p", rev: 1))
        source.codeStoreChanged()
        for _ in 0..<100 where source.fragments.codePane(id)?.selectedFunction?.name != "LoadMicrocode" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pane = try XCTUnwrap(source.fragments.codePane(id))
        XCTAssertEqual(pane.selectedFunction?.name, "LoadMicrocode", "the panel drew the new reading")
        XCTAssertEqual(pane.selectedFunctionIndex, 2, "on the same function, by address")
        XCTAssertEqual(pane.manifest.reading?.rev, 1)
    }

    /// A code panel torn off into a tab of its own still follows its
    /// analysis: published again, the tab draws the new reading.
    func testACodeTabFollowsARepublishedReading() async throws {
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        let parentURL = try dump(0x1000, 0x77)
        func artifactData(_ name: String) -> Data {
            Data(#"{"script_version":2,"ghidra":"12.1.2","functions":[{"entry":"0x0","name":"\#(name)","c":"return 0;","instructions":[{"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}"#.utf8)
        }
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeTabStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try ContentStore(root: storeRoot)
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(codeBytes)),
                                    size: codeBytes.count, name: "SecCore", kind: "PE32",
                                    language: "x86:LE:32:default", imageBase: "0x0")
        let recipe = AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                    ghidra: "12.1.2", script: "ExportCode.java")
        let manifest = try store.putAnalysis(module: module, recipe: recipe, artifact: artifactData("entry"),
                                             reading: AnalysisReading(project: "p", rev: 24))
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = storeRoot
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let source = shownWindow().mainViewController
        let tab = shownWindow().mainViewController
        source.makeSiblingTab = { tab }
        source.openFiles([parentURL])
        source.openCode(
            named: "SecCore ▸ PE32", from: source.windowModel.pane1,
            source: 0x100..<0x200, manifest: manifest,
            artifact: try JSONDecoder().decode(CodeArtifact.self, from: artifactData("entry")),
            codec: ReadOnlyPartCodec(codeBytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")),
            at: CodeLocation(function: CodeAddress(0x0)))
        let id = try XCTUnwrap(source.fragments.expanded)
        source.tearOffFragment(id)
        XCTAssertEqual(tab.currentCodeScreen()?.manifest.reading?.rev, 24)

        try store.putAnalysis(module: module, recipe: recipe, artifact: artifactData("SecStartup"),
                              reading: AnalysisReading(project: "p", rev: 25))
        tab.codeStoreChanged()
        for _ in 0..<100 where tab.currentCodeScreen()?.manifest.reading?.rev != 25 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(tab.currentCodeScreen()?.manifest.reading?.rev, 25, "the tab drew the new reading")
        XCTAssertEqual(tab.focusedCodePane()?.selectedFunction?.name, "SecStartup")
    }

    /// A code panel comes back as a code panel: the analysis from the store,
    /// the function and the ASM/C side the reader left, not a plain part.
    /// A session keeps which analysis a code panel shows, not which
    /// revision: published again while the app was closed, the panel comes
    /// back with the new reading.
    func testACodePanelComesBackAtTheLatestReading() async throws {
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        let parentURL = try dump(0x1000, 0x77)
        func artifactData(_ name: String) -> Data {
            Data(#"{"script_version":2,"ghidra":"12.1.2","functions":[{"entry":"0x0","name":"\#(name)","c":"return 0;","instructions":[{"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}"#.utf8)
        }
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeLatestStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try ContentStore(root: storeRoot)
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(codeBytes)),
                                    size: codeBytes.count, name: "SecCore", kind: "PE32",
                                    language: "x86:LE:32:default", imageBase: "0x0")
        let recipe = AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                    ghidra: "12.1.2", script: "ExportCode.java")
        let manifest = try store.putAnalysis(module: module, recipe: recipe, artifact: artifactData("entry"),
                                             reading: AnalysisReading(project: "p", rev: 24))
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = storeRoot
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let source = shownWindow().mainViewController
        source.openFiles([parentURL])
        source.openCode(
            named: "SecCore ▸ PE32", from: source.windowModel.pane1,
            source: 0x100..<0x200, manifest: manifest,
            artifact: try JSONDecoder().decode(CodeArtifact.self, from: artifactData("entry")),
            codec: ReadOnlyPartCodec(codeBytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        let tab = source.workspaceTab()

        try store.putAnalysis(module: module, recipe: recipe, artifact: artifactData("SecStartup"),
                              reading: AnalysisReading(project: "p", rev: 25))
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)])
        XCTAssertEqual(issues, [])
        let restoredID = try XCTUnwrap(target.fragments.expanded)
        let restored = try XCTUnwrap(target.fragments.codePane(restoredID))
        XCTAssertEqual(restored.manifest.reading?.rev, 25, "the reading published since, not the one saved")
        XCTAssertEqual(restored.selectedFunction?.name, "SecStartup")
    }

    func testCodePanelComesBackAsCode() async throws {
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        let parentURL = try dump(0x1000, 0x77)
        let artifactData = Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x0","name":"entry","c":"return 0;","instructions":[
            {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
        """.utf8)
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: artifactData)

        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePanelStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try ContentStore(root: storeRoot)
        let manifest = try store.putAnalysis(
            module: ModuleIdentity(sha256: SHA256Digest(data: Data(codeBytes)),
                                   size: codeBytes.count, name: "CpuPei", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: artifactData)
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = storeRoot
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let source = shownWindow().mainViewController
        source.openFiles([parentURL])
        source.openCode(
            named: "CpuPei body", from: source.windowModel.pane1,
            source: 0x100..<0x200, manifest: manifest, artifact: artifact,
            codec: ReadOnlyPartCodec(codeBytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        let id = try XCTUnwrap(source.fragments.expanded)
        source.fragments.codePane(id)?.restore(function: 0, instruction: 0, showsC: true)
        let tab = source.workspaceTab()
        let saved = try XCTUnwrap(tab.fragments.first?.code)
        XCTAssertEqual(saved.selectedFunction, 0)
        XCTAssertNotNil(saved.place?.function, "the place is kept by address as well")
        XCTAssertTrue(saved.showsC)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)])
        XCTAssertEqual(issues, [])
        let restoredID = try XCTUnwrap(target.fragments.expanded,
                                       "the code panel came back, not a plain part")
        let restored = try XCTUnwrap(target.fragments.codePane(restoredID))
        XCTAssertTrue(restored.showsDecompiledC)
        XCTAssertEqual(restored.selectedFunction?.name, "entry")
        XCTAssertFalse(target.toolSelectionAllowed)
        XCTAssertFalse(target.minimapAllowed)
        // The panel is a panel like any other: it stops at the dock, rather
        // than standing over it.
        target.view.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(firstDescendant(FragmentPanelHost.self, in: target.view))
        let strip = try XCTUnwrap(firstDescendant(FragmentDockStrip.self, in: target.view))
        XCTAssertEqual(host.frame.minY, strip.frame.height, accuracy: 0.5,
                       "the stage starts above the dock")
        XCTAssertEqual(try XCTUnwrap(target.fragments.panelView(restoredID)).frame,
                       FragmentPanelView.restingFrame(in: host),
                       "the restored panel stands where every panel stands")
    }

    /// A tab torn off from the dock is a code screen too, and comes back as
    /// one rather than as an ordinary tab of the same bytes.
    func testACodeTabComesBackAsCode() async throws {
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        let fileURL = try tempFile(codeBytes, "code-tab")
        let artifactData = Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x0","name":"entry","c":"return 1;","instructions":[
            {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
        """.utf8)
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: artifactData)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeTabStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try ContentStore(root: storeRoot)
        let manifest = try store.putAnalysis(
            module: ModuleIdentity(sha256: SHA256Digest(data: Data(codeBytes)),
                                   size: codeBytes.count, name: "CpuPei", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: artifactData)
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = storeRoot
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let source = shownWindow().mainViewController
        source.openFiles([fileURL])
        source.installCodeScreen(CodeScreen(manifest: manifest, artifact: artifact,
                                            bytes: Data(codeBytes),
                                            selectedFunction: 0, selectedInstruction: 0,
                                            showsC: true),
                                 on: source.windowModel.pane1)
        source.apply(mode: .singleFile)
        let tab = source.workspaceTab()
        XCTAssertNotNil(tab.code)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)])
        XCTAssertEqual(issues, [])
        XCTAssertTrue(target.hasCodeScreen, "the tab is still a code screen")
        XCTAssertTrue(target.codeScreenView?.showsDecompiledC ?? false)
        XCTAssertEqual(target.codeScreenView?.selectedFunction?.name, "entry")
    }

    // MARK: - Parts torn off into tabs

    /// A part torn off into a tab, in a window of its own, whose parent is a
    /// file in another window — written before that window, so the restore
    /// meets the part before its parent.
    private func tornOffPart() throws -> (parent: MainViewController, part: MainViewController,
                                          bytes: [UInt8], tabs: [TabState]) {
        let bytes: [UInt8] = (0..<0x1000).map { UInt8(($0 * 13) & 0xFF) }
        let a = try tempFile(bytes, "torn")
        let parent = shownWindow().mainViewController
        parent.openFiles([a])
        let part = shownWindow().mainViewController
        let content = Array(bytes[0x200..<0x400])
        let origin = try XCTUnwrap(DocumentOrigin(parent: parent.windowModel.pane1, source: 0x200..<0x400,
                                                  partName: "zone", layout: .image, codec: CopyPartCodec(),
                                                  content: content))
        part.windowModel.pane1.openBytes(content, named: "zone", origin: origin)
        part.refreshMode()
        part.windowModel.pane1.select(range: 0x30..<0x30)
        let ids = WorkspacePaneIDs()
        let tabs = [part.workspaceTab(ids: ids), parent.workspaceTab(ids: ids)]
        return (parent, part, bytes, tabs)
    }

    func testATornOffPartComesBackLinkedToItsParentInAnotherWindow() async throws {
        let (_, _, bytes, tabs) = try tornOffPart()
        guard case let .part(origin)? = tabs[0].panes[0]?.document else { return XCTFail("written as a part") }
        XCTAssertEqual(origin.parent, tabs[1].panes[0]?.id)

        let partTab = shownWindow().mainViewController
        let parentTab = shownWindow().mainViewController
        let issues = await restore([(tabs[0], partTab), (tabs[1], parentTab)])

        XCTAssertEqual(issues, [])
        let restored = partTab.windowModel.pane1
        XCTAssertEqual(partTab.mode, .singleFile)
        XCTAssertEqual(try restored.document?.read(at: 0, length: 0x200), Array(bytes[0x200..<0x400]))
        XCTAssertIdentical(restored.origin?.parent, parentTab.windowModel.pane1,
                           "Update in Parent still knows where to go")
        XCTAssertEqual(restored.status.fileName, "zone")
        XCTAssertEqual(restored.document?.selection.start, 0x30)
    }

    func testATornOffPartIsKeptAtQuit() async throws {
        let (parent, part, _, _) = try tornOffPart()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRecorderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folderURL) }
        WorkspaceSettings.set(restoresWorkspace: true)
        let controllers = [part, parent].compactMap { $0.view.window?.windowController as? MainWindowController }
        XCTAssertEqual(controllers.count, 2)
        let recorder = WorkspaceRecorder(folder: WorkspaceFolder(url: folderURL), controllers: { controllers })

        await recorder.recordSettled()
        let saved = try XCTUnwrap(recorder.savedWorkspace())
        XCTAssertEqual(saved.windows.count, 2, "a part is kept, its parent beside it")
    }

    /// A part with changes its parent has not got comes back with them, still
    /// linked — and without its parent, still with them.
    func testAPartComesBackWithItsChanges() async throws {
        let (parentTab, partTab, bytes, _) = try tornOffPart()
        let part = partTab.windowModel.pane1
        part.select(range: 0..<0)
        try part.pasteWrite([0xDE, 0xAD])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PartEdits-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let keeper = ContentKeeper(folder: WorkspaceFolder(url: folder))
        let tabs = await keeper.settledTabs {
            let ids = WorkspacePaneIDs()
            return [partTab.workspaceTab(keeper: keeper, ids: ids), parentTab.workspaceTab(keeper: keeper, ids: ids)]
        }
        guard case let .part(origin)? = tabs[0].panes[0]?.document else { return XCTFail("written as a part") }
        XCTAssertNotNil(origin.edits)

        let restoredPart = shownWindow().mainViewController
        let restoredParent = shownWindow().mainViewController
        let issues = await restore([(tabs[0], restoredPart), (tabs[1], restoredParent)], keeper: keeper)
        XCTAssertEqual(issues, [])
        let pane = restoredPart.windowModel.pane1
        XCTAssertEqual(try pane.document?.read(at: 0, length: 4),
                       [0xDE, 0xAD] + Array(bytes[0x202..<0x204]))
        XCTAssertIdentical(pane.origin?.parent, restoredParent.windowModel.pane1)
        XCTAssertEqual(pane.origin.map { $0.hasChanges(in: pane) }, true, "Update in Parent has them to put back")

        let alone = shownWindow().mainViewController
        let orphanIssues = await restore([(tabs[0], alone)], keeper: keeper)
        XCTAssertEqual(orphanIssues, [])
        XCTAssertEqual(try alone.windowModel.pane1.document?.read(at: 0, length: 2), [0xDE, 0xAD],
                       "without its parent, the changes still come back")
        XCTAssertNil(alone.windowModel.pane1.origin)
    }

    func testAPartWhoseParentIsGoneIsReported() async throws {
        let (_, _, _, tabs) = try tornOffPart()
        let partTab = shownWindow().mainViewController
        let restorer = WorkspaceRestorer(keeper: nil)
        restorer.openFiles(of: tabs[0], in: partTab)
        await restorer.openParts()

        XCTAssertEqual(restorer.issues, [.missing(path: "zone")])
        XCTAssertTrue(restorer.emptyTabs.contains { $0 === partTab }, "its window is closed, not left empty")
    }

    // MARK: - Tools

    func testTheToolPanelComesBackOnItsPaneWithoutMovingTheWindow() async throws {
        let a = try dump(0x1000, 0xFF)
        let b = try dump(0x1000, 0xEE)
        let source = shownWindow().mainViewController
        source.openFiles([a, b])
        source.activatePane(at: 1)
        source.surface.tools.activate(UEFIToolModule.identifier, animated: false)
        source.activatePane(at: 0)

        let tab = source.workspaceTab()
        let tool = try XCTUnwrap(tab.surface.tool)
        XCTAssertEqual(tool.identifier, UEFIToolModule.identifier)
        XCTAssertEqual(tool.pane, 1, "the tool read File B")
        let state = try XCTUnwrap(tool.state, "the UEFI panel's choice is persistable")
        XCTAssertNotNil(UEFIToolModule.restoredState(from: state))

        let window = shownWindow()
        let target = window.mainViewController
        let frame = try XCTUnwrap(window.window?.frame)
        let restoreIssues = await restore([(tab, target)])
        XCTAssertEqual(restoreIssues, [])

        XCTAssertEqual(target.surface.tools.activeIdentifier, UEFIToolModule.identifier)
        XCTAssertIdentical(target.surface.tools.boundPane, target.windowModel.pane2)
        XCTAssertEqual(target.windowModel.activePaneIndex, 0, "the active pane is still the one that was")
        XCTAssertEqual(window.window?.frame, frame, "a restored window already has its frame")
    }

    // MARK: - Untitled documents

    private func recorder(_ controllers: [MainWindowController]) -> (WorkspaceRecorder, URL) {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRecorderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folderURL) }
        return (WorkspaceRecorder(folder: WorkspaceFolder(url: folderURL), controllers: { controllers }), folderURL)
    }

    /// A session a newer build wrote is neither read, nor written over, nor
    /// deleted — the switch on or off — and the session is not kept meanwhile.
    func testASessionOfANewerVersionIsLeftAlone() throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRecorderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folderURL) }
        let folder = WorkspaceFolder(url: folderURL)
        var newer = Workspace(windows: [])
        newer.version = Workspace.currentVersion + 1
        try folder.write(newer)
        try folder.prepareKeptFolder()
        let kept = folder.keptURL("newer.log")
        try Data([1, 2, 3]).write(to: kept)
        let written = try Data(contentsOf: folder.fileURL)

        let window = shownWindow()
        window.mainViewController.windowModel.pane1.openBytes([0xAA, 0xBB], named: "work")
        let recorder = WorkspaceRecorder(folder: WorkspaceFolder(url: folderURL), controllers: { [window] })
        XCTAssertTrue(recorder.isSessionNewer)
        XCTAssertFalse(recorder.keepsSession)
        XCTAssertNil(recorder.savedWorkspace())

        recorder.record(final: true)
        recorder.flush()
        WorkspaceSettings.set(restoresWorkspace: false)
        recorder.record()
        recorder.discardSession()
        recorder.flush()
        XCTAssertEqual(try Data(contentsOf: folder.fileURL), written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testAnUntitledDocumentComesBackWithItsBytesAndStillUnsaved() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        let bytes: [UInt8] = (0..<0x300).map { UInt8($0 & 0xFF) }
        pane.openBytes(bytes, named: "joined.bin")
        pane.document?.undoHistory.clearKeepingDirty()
        pane.select(range: 0x120..<0x130)
        window.mainViewController.refreshMode()
        let (recorder, _) = recorder([window])
        await recorder.recordSettled()

        let saved = try XCTUnwrap(recorder.savedWorkspace())
        let tab = try XCTUnwrap(saved.windows.first?.tabs.first)
        guard case let .untitled(stamp)? = tab.panes[0]?.document else { return XCTFail("an untitled pane") }
        XCTAssertEqual(stamp.name, "joined.bin")
        XCTAssertTrue(stamp.dirty)

        let target = shownWindow().mainViewController
        let restoreIssues = await restore([(tab, target)], keeper: recorder.keeper)
        XCTAssertEqual(restoreIssues, [])
        let restored = target.windowModel.pane1
        XCTAssertTrue(restored.isUntitled)
        XCTAssertEqual(restored.status.fileName, "joined.bin")
        XCTAssertEqual(try restored.document?.read(at: 0, length: 0x300), bytes)
        XCTAssertTrue(restored.status.isDirty, "closing it must still ask")
        XCTAssertEqual(restored.document?.selection.start, 0x120)
    }

    func testUntitledBytesAreKeptUntilTheirDocumentCloses() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let a = try dump(0x100, 0xAA)
        let files = shownWindow()
        files.mainViewController.openFiles([a])
        let untitled = shownWindow()
        untitled.mainViewController.windowModel.pane1.openBytes([1, 2, 3], named: nil)
        untitled.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([files, untitled])

        await recorder.recordSettled()
        XCTAssertEqual(try XCTUnwrap(recorder.savedWorkspace()).windows.count, 2)
        let kept = folderURL.appendingPathComponent("Kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path)
            .filter { $0.hasSuffix(".bin") }.count, 1, "its bytes, written whole once")

        untitled.mainViewController.windowModel.pane1.close()
        await recorder.recordSettled()
        XCTAssertEqual(try XCTUnwrap(recorder.savedWorkspace()).windows.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path), [],
                       "a closed document takes its bytes with it")
    }

    /// Quitting with the workspace on does not ask about an untitled
    /// document the workspace holds.
    func testQuittingDoesNotAskAboutAKeptUntitledDocument() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let controller = window.mainViewController
        let pane = controller.windowModel.pane1
        pane.openBytes([1, 2, 3], named: "scratch")
        pane.document?.undoHistory.clearKeepingDirty()
        controller.refreshMode()
        let (recorder, _) = recorder([window])
        XCTAssertEqual(controller.unsavedDocumentCount, 1, "the premise: unsaved")

        await recorder.recordSettled()
        let kept: (PaneViewModel) -> Bool = { $0.isUntitled && recorder.keeper.holdsCurrentBytes(of: $0) }
        XCTAssertEqual(controller.unsavedDocumentCount(keeping: kept), 0)
        var agreed: Bool?
        // Under test an asked question answers Cancel: agreeing is the proof
        // that nothing was asked.
        controller.confirmClose(keeping: kept) { agreed = $0 }
        XCTAssertEqual(agreed, true)

        pane.select(range: 0..<0)
        try pane.pasteWrite([9])
        XCTAssertFalse(kept(pane), "a change since the snapshot is not held")
    }

    /// The session keeps a file's unsaved changes as a project does: they
    /// come back red and unsaved, and quitting asks nothing about them.
    func testAFileOnDiskComesBackWithItsUnsavedChanges() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let file = try dump(0x400, 0x5A)
        let window = shownWindow()
        let controller = window.mainViewController
        let pane = controller.windowModel.pane1
        controller.openFiles([file])
        pane.select(range: 0x10..<0x10)
        try pane.pasteWrite([0xDE, 0xAD])
        try pane.pasteInsert([0x01])
        let expected = try pane.document?.read(at: 0, length: 0x401)
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        XCTAssertNotNil(tab.panes[0]?.kept, "the changes are kept")
        guard case let .file(stamp)? = tab.panes[0]?.document else { return XCTFail("a file") }
        XCTAssertNil(stamp.relativePath, "the session finds its files by path alone")
        let kept: (PaneViewModel) -> Bool = { recorder.keeper.holdsCurrentBytes(of: $0) }
        XCTAssertEqual(controller.unsavedDocumentCount(keeping: kept), 0, "quitting asks nothing")

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(try restored.document?.read(at: 0, length: 0x401), expected)
        XCTAssertTrue(restored.status.isDirty, "still unsaved")
        XCTAssertEqual(try Data(contentsOf: file).count, 0x400, "the file on disk is untouched")

        let edits = folderURL.appendingPathComponent("Kept").path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: edits).map { ($0 as NSString).pathExtension },
                       ["log"], "the file is the base: only the log of its changes is kept")
        pane.close()
        // The restored copy writes the same journal; in a real launch it is the
        // only one.
        restored.close()
        await recorder.recordSettled()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: edits), [],
                       "a closed file takes its changes with it")
    }

    // MARK: - The history

    /// What a restored pane holds now, whole.
    private func bytes(_ pane: PaneViewModel) throws -> [UInt8]? {
        try pane.document?.read(at: 0, length: Int(pane.fileSize))
    }

    /// An untitled document comes back with its undo and its redo: what could
    /// be undone and redone before the app went down still can.
    func testAnUntitledDocumentsUndoAndRedoComeBack() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        let original = [UInt8](repeating: 0x10, count: 64)
        pane.openBytes(original, named: "scratch")
        window.mainViewController.refreshMode()
        pane.select(range: 4..<4)
        try pane.pasteWrite([1, 2])
        let afterFirst = try bytes(pane)
        try pane.pasteInsert([3])
        let afterSecond = try bytes(pane)
        try pane.undo()
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(try bytes(restored), afterFirst)
        XCTAssertTrue(try restored.redo())
        XCTAssertEqual(try bytes(restored), afterSecond)
        XCTAssertTrue(try restored.undo())
        XCTAssertTrue(try restored.undo())
        XCTAssertEqual(try bytes(restored), original)
        XCTAssertFalse(restored.status.isDirty, "back to what New File opened")
        XCTAssertFalse(try restored.undo())
    }

    /// The cuts follow an undo and a redo after a relaunch as they did before
    /// it: each step comes back with the segments it was made on.
    func testTheCutsFollowARestoredUndoAndRedo() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        EditingSettings.set(warnsBeforeShiftingEdits: false)
        addTeardownBlock { EditingSettings.resetToDefaults() }
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](repeating: 0x10, count: 64), named: "scratch")
        window.mainViewController.refreshMode()
        pane.segmentStore.addCut(at: 32)
        try pane.deleteBytes(in: 0..<4)                       // the cut at 28
        try pane.deleteBytes(in: 0..<8)                       // the cut at 20
        try pane.undo()                                       // back at 28, one to redo
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<28, 28..<60])
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(restored.segmentStore.segments.map(\.range), [0..<28, 28..<60])
        XCTAssertTrue(try restored.undo())
        XCTAssertEqual(restored.segmentStore.segments.map(\.range), [0..<32, 32..<64], "the cut moves back")
        XCTAssertTrue(try restored.redo())
        XCTAssertTrue(try restored.redo())
        XCTAssertEqual(restored.segmentStore.segments.map(\.range), [0..<20, 20..<52], "and on again")
    }

    /// Content whose kept history no longer leads back comes back without it,
    /// and the warning says so.
    func testAHistoryThatNoLongerLeadsBackIsReported() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](repeating: 0, count: 32), named: "scratch")
        window.mainViewController.refreshMode()
        pane.select(range: 0..<0)
        try pane.pasteWrite([7])
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()
        var tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        guard case var .untitled(stamp)? = tab.panes[0]?.document else { return XCTFail("kept") }
        stamp.content.history?.undoBase = 999_999
        tab.panes[0]?.document = .untitled(stamp)

        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [.historyLost(name: "scratch")])
        XCTAssertEqual(try target.windowModel.pane1.document?.read(at: 0, length: 1), [7], "the content is right")
        XCTAssertFalse(try target.windowModel.pane1.undo())
    }

    /// A file's history comes back with the saved state in it: undoing back to
    /// what is on disk makes the file clean.
    func testAFilesHistoryKnowsItsSavedState() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let file = try dump(0x100, 0x22)
        let window = shownWindow()
        window.mainViewController.openFiles([file])
        let pane = window.mainViewController.windowModel.pane1
        pane.select(range: 0..<0)
        try pane.pasteWrite([0xA1])
        try pane.save()
        try pane.pasteWrite([0xB2])
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        pane.close()
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertTrue(restored.status.isDirty)
        XCTAssertTrue(try restored.undo())
        XCTAssertFalse(restored.status.isDirty, "the state on disk")
        XCTAssertTrue(try restored.undo())
        XCTAssertEqual(try restored.document?.read(at: 0, length: 2), [0x22, 0x22], "before the save")
        XCTAssertTrue(restored.status.isDirty)
    }

    /// A join comes back undoable: undoing it attaches the document to the
    /// file it was joined from again.
    func testAJoinComesBackUndoable() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let file = try dump(0x80, 0x31)
        let other = try dump(0x40, 0x32)
        let window = shownWindow()
        window.mainViewController.openFiles([file])
        let pane = window.mainViewController.windowModel.pane1
        try pane.join(contentsOf: other, at: .end)
        XCTAssertTrue(pane.isUntitled)
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        pane.close()
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(restored.fileSize, 0xC0)
        XCTAssertTrue(try restored.undo())
        XCTAssertEqual(restored.fileSize, 0x80)
        XCTAssertFalse(restored.isUntitled, "attached to its file again")
        XCTAssertEqual(restored.document?.url.standardizedFileURL, file.standardizedFileURL)
    }

    /// A part's history comes back with its changes.
    func testAPartsHistoryComesBack() async throws {
        let (parentTab, partTab, bytes, _) = try tornOffPart()
        let part = partTab.windowModel.pane1
        part.select(range: 0..<0)
        try part.pasteWrite([0xDE, 0xAD])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PartHistory-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let keeper = ContentKeeper(folder: WorkspaceFolder(url: folder))
        let tabs = await keeper.settledTabs {
            let ids = WorkspacePaneIDs()
            return [partTab.workspaceTab(keeper: keeper, ids: ids), parentTab.workspaceTab(keeper: keeper, ids: ids)]
        }

        let restoredPart = shownWindow().mainViewController
        let restoredParent = shownWindow().mainViewController
        let issues = await restore([(tabs[0], restoredPart), (tabs[1], restoredParent)], keeper: keeper)
        XCTAssertEqual(issues, [])
        let pane = restoredPart.windowModel.pane1
        XCTAssertTrue(try pane.undo())
        XCTAssertEqual(try pane.document?.read(at: 0, length: 2), Array(bytes[0x200..<0x202]))
    }

    // MARK: - Integrity

    /// A file with changes kept over it, recorded as the last snapshot is:
    /// with its SHA-256.
    private func keptFileWorkspace() async throws -> (file: URL, tab: TabState, folder: URL, expected: [UInt8]?) {
        WorkspaceSettings.set(restoresWorkspace: true)
        let file = try dump(0x200, 0x33)
        let window = shownWindow()
        window.mainViewController.openFiles([file])
        let pane = window.mainViewController.windowModel.pane1
        pane.select(range: 0x20..<0x20)
        try pane.pasteWrite([0xC0, 0xDE])
        let expected = try pane.document?.read(at: 0, length: 0x200)
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()
        recorder.record(final: true)
        recorder.flush()
        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        pane.close()
        return (file, tab, folderURL, expected)
    }

    func testTheLastSnapshotHasTheHashOfAFileChangesAreKeptOver() async throws {
        let (file, tab, _, _) = try await keptFileWorkspace()
        guard case let .file(stamp)? = tab.panes[0]?.document else { return XCTFail("a file") }
        XCTAssertEqual(stamp.sha256, try FileDigest.sha256(of: file).hex)
    }

    /// An ordinary snapshot does not wait for the hash: it is made in the
    /// background and goes into a snapshot after it.
    func testAHashMadeInTheBackgroundGoesIntoALaterSnapshot() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let file = try dump(0x200, 0x21)
        let window = shownWindow()
        window.mainViewController.openFiles([file])
        let pane = window.mainViewController.windowModel.pane1
        pane.select(range: 0..<0)
        try pane.pasteWrite([0x01])
        let (recorder, _) = recorder([window])
        func hash() -> String? {
            guard case let .file(stamp)? = recorder.savedWorkspace()?.windows.first?.tabs.first?.panes[0]?.document
            else { return nil }
            return stamp.sha256
        }
        await recorder.recordSettled()
        XCTAssertNil(hash(), "not waited for")
        for _ in 0..<100 where hash() == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.recordSettled()
        }
        XCTAssertEqual(hash(), try FileDigest.sha256(of: file).hex)
    }

    /// Checking a file the changes are laid over shows its progress on the
    /// window when there is enough to read; the sheet goes once the changes
    /// are on.
    func testTheCheckShowsItsProgressAndGoesWhenDone() async throws {
        let (_, tab, folderURL, expected) = try await keptFileWorkspace()
        let threshold = WorkspaceRestorer.progressThreshold
        WorkspaceRestorer.progressThreshold = 0
        addTeardownBlock { await MainActor.run { WorkspaceRestorer.progressThreshold = threshold } }
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        XCTAssertEqual(try target.windowModel.pane1.document?.read(at: 0, length: 0x200), expected)
        for _ in 0..<100 where !(target.presentedViewControllers ?? []).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(target.presentedViewControllers ?? [], [], "no sheet is left behind")
    }

    /// A snapshot hands its writing to the background and returns: the
    /// workspace file is there once the writer has caught up.
    func testASnapshotIsWrittenInTheBackground() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](repeating: 3, count: 4 << 20), named: "big")
        window.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([window])
        recorder.keeper.writer.enqueue { _ in Thread.sleep(forTimeInterval: 0.3) }
        recorder.record()
        let file = folderURL.appendingPathComponent("Workspace.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "not written on the spot")
        recorder.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        guard case let .untitled(stamp)? = recorder.savedWorkspace()?.windows.first?.tabs.first?.panes[0]?.document
        else { return XCTFail("kept") }
        guard case let .bytes(_, _, hash) = stamp.content.base else { return XCTFail("a base of bytes") }
        XCTAssertEqual(hash.count, 64, "the base's hash, filled in by the writer")
        XCTAssertNotEqual(stamp.content.log?.hash, "", "and the log's")
    }

    /// A save that writes the file whole hashes it as it goes: the snapshot
    /// after it has the hash at once, without reading the file again.
    func testASaveWrittenWholeGivesTheHashAtOnce() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        EditingSettings.set(warnsBeforeShiftingEdits: false)
        addTeardownBlock { EditingSettings.resetToDefaults() }
        let file = try dump(0x300, 0x41)
        let window = shownWindow()
        window.mainViewController.openFiles([file])
        let pane = window.mainViewController.windowModel.pane1
        pane.select(range: 0..<0)
        try pane.pasteInsert([0x01])                    // a length change: written whole
        try pane.save()
        XCTAssertNotNil(pane.document?.savedDigest)
        try pane.pasteWrite([0x02])
        let (recorder, _) = recorder([window])
        await recorder.recordSettled()
        guard case let .file(stamp)? = recorder.savedWorkspace()?.windows.first?.tabs.first?.panes[0]?.document
        else { return XCTFail("a file") }
        XCTAssertEqual(stamp.sha256, try FileDigest.sha256(of: file).hex, "in the first snapshot, not waited for")
    }

    /// A copy or a `touch` moves the date, not the bytes: the changes still
    /// come back, and so does everything measured on the file.
    func testAMovedDateAloneDoesNotMakeAnotherFile() async throws {
        let (file, tab, folderURL, expected) = try await keptFileWorkspace()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)],
                                              ofItemAtPath: file.path)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        XCTAssertEqual(try target.windowModel.pane1.document?.read(at: 0, length: 0x200), expected)
    }

    /// Other bytes under the same size and date are another file: nothing is
    /// laid over it, and the warning says it changed.
    func testOtherBytesUnderTheSameDateAreAnotherFile() async throws {
        let (file, tab, folderURL, _) = try await keptFileWorkspace()
        let date = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data(repeating: 0x44, count: 0x200).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [.changed(path: file.path)])
        XCTAssertEqual(try target.windowModel.pane1.document?.read(at: 0x20, length: 2), [0x44, 0x44])
    }

    /// A kept base whose bytes are not the ones written is not read.
    func testADamagedBaseIsNotRead() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](repeating: 1, count: 128), named: "scratch")
        window.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()
        let base = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: folderURL.appendingPathComponent("Kept"), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "bin" })
        var data = try Data(contentsOf: base)
        data[5] = 0xEE
        try data.write(to: base)

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [.unreadable(name: "scratch")])
        XCTAssertFalse(target.windowModel.pane1.isOpen)
    }

    /// Writing is incremental: a caret move writes nothing, an edit only
    /// appends to the log, and only content that jumped with no transaction
    /// to say how — a cleared history — is written whole again.
    func testOnlyWhatChangedIsWritten() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](repeating: 7, count: 64), named: nil)
        window.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()
        let keptFolder = folderURL.appendingPathComponent("Kept")
        func files(_ suffix: String) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: keptFolder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == suffix }
        }
        func size(_ url: URL) throws -> Int { try Data(contentsOf: url).count }
        let base = try XCTUnwrap(try files("bin").first)
        XCTAssertEqual(try files("log"), [], "no edits, no log")
        try FileManager.default.removeItem(at: base)

        pane.select(range: 4..<8)
        await recorder.recordSettled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "a caret move writes nothing")

        pane.select(range: 4..<4)
        try pane.pasteWrite([1, 2])
        await recorder.recordSettled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "an edit is not new content whole")
        let log = try XCTUnwrap(try files("log").first, "it goes on the log")
        let logSize = try size(log)
        try pane.pasteWrite([3, 4])
        await recorder.recordSettled()
        XCTAssertGreaterThan(try size(log), logSize, "the next one on the same log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))

        try pane.undo()
        let afterEdit = try size(log)
        await recorder.recordSettled()
        XCTAssertLessThan(try size(log) - afterEdit, 128,
                          "an undo writes no bytes again: which state is kept, and the segments it pairs with the redo")

        pane.document?.undoHistory.clearKeepingDirty()
        await recorder.recordSettled()
        XCTAssertEqual(try files("bin").count, 1, "content that jumped is written whole, under a new name")
        XCTAssertNotEqual(try files("bin").first?.lastPathComponent, base.lastPathComponent)
    }

    /// With the workspace recorded, an edit's bytes are written once: into
    /// the journal in `Kept/` as the edit is made, and the snapshot's record of
    /// the step only names them. The log is about the size of the edit, not
    /// twice it, and it brings the edit back undoable.
    func testAnEditsBytesAreWrittenOnce() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        EditingSettings.set(warnsBeforeShiftingEdits: false)
        addTeardownBlock { EditingSettings.resetToDefaults() }
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        let (recorder, folderURL) = recorder([window])
        let keptFolder = folderURL.appendingPathComponent("Kept")
        UndoJournal.directoryProvider = { keptFolder }
        addTeardownBlock { UndoJournal.directoryProvider = nil }
        pane.openBytes([UInt8](repeating: 0, count: 4 << 20), named: "big")
        window.mainViewController.refreshMode()
        pane.select(range: 0..<0)
        let edit = (0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        try pane.pasteInsert(edit)
        let journal = try XCTUnwrap(pane.document?.undoHistory.journal)
        XCTAssertEqual(journal.url?.deletingLastPathComponent().standardizedFileURL, keptFolder.standardizedFileURL,
                       "made where its log will be")
        await recorder.recordSettled()
        let logs = try FileManager.default.contentsOfDirectory(at: keptFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
        XCTAssertEqual(logs.map(\.lastPathComponent), [journal.url?.lastPathComponent].compactMap { $0 })
        let size = try Data(contentsOf: logs[0]).count
        XCTAssertLessThan(size, edit.count + (64 << 10), "the edit's bytes once, and a short record naming them")

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        pane.close()
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(try restored.document?.read(at: 0, length: 16), Array(edit[0..<16]))
        XCTAssertTrue(try restored.undo())
        XCTAssertEqual(restored.fileSize, 4 << 20)
        XCTAssertTrue(try restored.redo())
        XCTAssertEqual(try restored.document?.read(at: UInt64(edit.count - 16), length: 16),
                       Array(edit[(edit.count - 16)...]))
    }

    /// A journal made before the workspace kept it is moved into `Kept/` off
    /// the main thread, under a sheet: the snapshots leave the document alone
    /// until it is there, an edit made meanwhile — by an agent, a part — is
    /// caught up with, and what comes back undoes as before.
    func testAJournalIsMovedOffTheMainThread() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let delay = ContentKeeper.moveSheetDelay
        ContentKeeper.moveSheetDelay = .milliseconds(10)
        ContentKeeper.beforeMoveRound = { Thread.sleep(forTimeInterval: 0.3) }
        addTeardownBlock {
            await MainActor.run {
                ContentKeeper.moveSheetDelay = delay
                ContentKeeper.beforeMoveRound = nil
            }
        }
        let window = shownWindow()
        let controller = window.mainViewController
        let pane = controller.windowModel.pane1
        pane.openBytes([UInt8](repeating: 0, count: 256 << 10), named: "moving")
        controller.refreshMode()
        pane.select(range: 0..<0)
        try pane.pasteWrite([UInt8](repeating: 0x5A, count: 128 << 10))
        XCTAssertNil(pane.document?.undoHistory.journal?.url, "a temporary journal: made before any workspace")
        let (recorder, folderURL) = recorder([window])
        recorder.record()
        try pane.pasteWrite([0x01, 0x02])                  // what the sheet cannot stop
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(controller.presentedViewControllers?.isEmpty ?? true, "a move past the delay shows itself")
        await recorder.keeper.settleMoves()
        let journal = try XCTUnwrap(pane.document?.undoHistory.journal?.url)
        XCTAssertEqual(journal.deletingLastPathComponent().standardizedFileURL,
                       folderURL.appendingPathComponent("Kept").standardizedFileURL)
        await recorder.recordSettled()
        let expected = try pane.document?.read(at: 0, length: Int(pane.fileSize))

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        pane.close()
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(try restored.document?.read(at: 0, length: Int(restored.fileSize)), expected)
        XCTAssertTrue(try restored.undo())
        XCTAssertTrue(try restored.undo())
        XCTAssertEqual(try restored.document?.read(at: 0, length: 4), [0, 0, 0, 0])
        for _ in 0..<100 where !(controller.presentedViewControllers ?? []).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.presentedViewControllers ?? [], [], "the sheet goes once it is there")
    }

    /// The last snapshot never waits on the main thread: it returns at once,
    /// and its continuation runs once the writer has written it. Writing that
    /// takes long shows a sheet on the window in front meanwhile, gone when
    /// it is done.
    func testTheLastSnapshotCallsBackInsteadOfWaiting() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        window.window?.makeKeyAndOrderFront(nil)
        let controller = window.mainViewController
        controller.windowModel.pane1.openBytes([1, 2, 3], named: "last")
        controller.refreshMode()
        let (recorder, folderURL) = recorder([window])
        let delay = WorkspaceRecorder.finalSheetDelay
        WorkspaceRecorder.finalSheetDelay = .milliseconds(10)
        addTeardownBlock { await MainActor.run { WorkspaceRecorder.finalSheetDelay = delay } }
        recorder.keeper.writer.enqueue { _ in Thread.sleep(forTimeInterval: 0.4) }

        var written = false
        recorder.recordFinal { written = true }
        XCTAssertFalse(written, "returned before the writing")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(written)
        XCTAssertFalse((window.window?.contentViewController?.presentedViewControllers ?? []).isEmpty,
                       "the window in front shows the writing")
        for _ in 0..<100 where !written { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("Workspace.json").path))
        for _ in 0..<100 where !(window.window?.contentViewController?.presentedViewControllers ?? []).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(window.window?.contentViewController?.presentedViewControllers ?? [], [])
    }

    /// The content comes back as it was, from the base and the transactions
    /// after it — an undo and a different edit after it included.
    func testAnUntitledDocumentComesBackFromItsBaseAndLog() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](0..<64), named: "scratch")
        window.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()
        pane.select(range: 8..<8)
        try pane.pasteWrite([0xAA, 0xBB])
        try pane.pasteInsert([0xCC])
        await recorder.recordSettled()
        try pane.undo()
        try pane.deleteBytes(in: 0..<4)
        await recorder.recordSettled()
        let expected = try pane.document?.read(at: 0, length: Int(pane.fileSize))

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(try restored.document?.read(at: 0, length: Int(restored.fileSize)), expected)
        XCTAssertTrue(restored.status.isDirty)
    }

    /// A damaged log is not laid over anything: the file opens as it is on
    /// disk, and the warning says its kept changes could not be read.
    func testADamagedLogIsReportedNotApplied() async throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let file = try dump(0x100, 0x11)
        let window = shownWindow()
        let controller = window.mainViewController
        controller.openFiles([file])
        let pane = controller.windowModel.pane1
        pane.select(range: 0..<0)
        try pane.pasteWrite([0x99, 0x98])
        let (recorder, folderURL) = recorder([window])
        await recorder.recordSettled()
        let log = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: folderURL.appendingPathComponent("Kept"), includingPropertiesForKeys: nil).first)
        var data = try Data(contentsOf: log)
        data[data.count - 40] ^= 0xFF
        try data.write(to: log)

        let tab = try XCTUnwrap(recorder.savedWorkspace()?.windows.first?.tabs.first)
        let target = shownWindow().mainViewController
        let issues = await restore([(tab, target)], keeper: ContentKeeper(folder: WorkspaceFolder(url: folderURL)))
        XCTAssertEqual(issues.count, 1)
        guard case .unreadable? = issues.first else { return XCTFail("\(issues)") }
        XCTAssertEqual(try target.windowModel.pane1.document?.read(at: 0, length: 2), [0x11, 0x11])
    }

    // MARK: - The recorder

    func testTheRecorderWritesTabsWithFilesAndOnlyWhileSwitchedOn() async throws {
        let a = try dump(0x100, 0xAA)
        let withFile = shownWindow()
        withFile.mainViewController.openFiles([a])
        let empty = shownWindow()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRecorderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folderURL) }
        let recorder = WorkspaceRecorder(folder: WorkspaceFolder(url: folderURL),
                                         controllers: { [withFile, empty] })

        await recorder.recordSettled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path),
                       "nothing is written while the switch is off")

        WorkspaceSettings.set(restoresWorkspace: true)
        await recorder.recordSettled()
        let saved = try XCTUnwrap(recorder.savedWorkspace())
        XCTAssertEqual(saved.windows.count, 1, "an empty window is not part of the workspace")
        XCTAssertEqual(saved.windows.first?.tabs.first?.panes.first??.document,
                       .file(try XCTUnwrap(FileStamp(url: a))))

        WorkspaceSettings.set(restoresWorkspace: false)
        await recorder.recordSettled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path),
                       "switching off deletes the workspace")
    }
}

extension WorkspaceRecorder {
    /// A snapshot as the tests read it back: on disk, with every journal that
    /// had to be moved into `Kept/` first moved — the app's own documents are
    /// made there; a test's, made before its recorder, are moved in the
    /// background.
    func recordSettled() async {
        record()
        flush()
        await keeper.settleMoves()
        record()
        flush()
    }
}

extension ContentKeeper {
    /// Tabs written down through this keeper outside a recorder, once every
    /// journal they needed moved is in `Kept/`: taken, the moves waited for,
    /// taken again and settled.
    func settledTabs(_ take: () -> [TabState]) async -> [TabState] {
        _ = take()
        await settleMoves()
        return settled(take())
    }
}
