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

    private func dump(_ size: Int, _ fill: UInt8) throws -> URL {
        try tempFile([UInt8](repeating: fill, count: size), "\(fill)")
    }

    func testAComparisonComesBackAsItWas() throws {
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
        let issues = target.restoreWorkspaceTab(tab).issues

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

    func testAMissingFileIsReportedAndTheOtherOpensAlone() throws {
        let a = try dump(0x100, 0xAA)
        let b = try dump(0x100, 0xBB)
        let source = shownWindow().mainViewController
        source.openFiles([a, b])
        let tab = source.workspaceTab()
        source.windowModel.pane1.close()
        try FileManager.default.removeItem(at: a)

        let target = shownWindow().mainViewController
        let issues = target.restoreWorkspaceTab(tab).issues

        XCTAssertEqual(issues, [.missing(path: a.standardizedFileURL.path)])
        XCTAssertEqual(target.mode, .singleFile)
        XCTAssertEqual(target.windowModel.pane1.document?.url.standardizedFileURL, b.standardizedFileURL,
                       "a file alone is File A")
    }

    func testAShorterFileIsReportedAndTheCaretMovesToItsEnd() throws {
        let a = try dump(0x1000, 0xAA)
        let source = shownWindow().mainViewController
        source.openFiles([a])
        source.windowModel.pane1.select(range: 0xF00..<0xF00)
        let tab = source.workspaceTab()
        source.windowModel.pane1.close()
        try Data(repeating: 0x11, count: 0x800).write(to: a)

        let target = shownWindow().mainViewController
        let issues = target.restoreWorkspaceTab(tab).issues

        XCTAssertEqual(issues, [.changed(path: a.standardizedFileURL.path)])
        XCTAssertEqual(target.windowModel.pane1.document?.selection.start, 0x7FF)
    }

    // MARK: - Around the panes

    func testBookmarksSegmentsMinimapAndFindBarComeBack() throws {
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
        XCTAssertEqual(target.restoreWorkspaceTab(tab).issues, [])

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

    func testAChangedFileLosesItsSegmentsAndTheBookmarksPastItsEnd() throws {
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
        XCTAssertEqual(target.restoreWorkspaceTab(tab).issues, [.changed(path: a.standardizedFileURL.path)])

        XCTAssertEqual(target.windowModel.bookmarkStore.bookmarks.map(\.name), ["kept"])
        XCTAssertEqual(target.windowModel.pane1.segmentStore.current.pieces.count, 1,
                       "cuts made on other bytes are not put on these")
    }

    // MARK: - Panels

    func testPartsComeBackDecodedFromTheirParentsAndTheFrontOneInFront() throws {
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
        let keeper = UntitledKeeper(folder: WorkspaceFolder(url: keeperFolder))
        let tab = source.workspaceTab(keeper: keeper)
        XCTAssertEqual(tab.fragments.map(\.parent), [.pane(0), .fragment(0), nil])
        XCTAssertEqual(tab.expandedFragment, 0)

        let target = shownWindow().mainViewController
        let restored = target.restoreWorkspaceTab(tab, keeper: keeper)
        let expectation = expectation(description: "panels")
        var issues: [RestoreIssue] = []
        Task { @MainActor in
            issues = await target.restoreWorkspaceFragments(tab, over: restored, keeper: keeper)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(issues, [])
        let panes = target.fragments.dock.panels.compactMap { target.fragments.pane($0) }
        XCTAssertEqual(panes.map(\.status.fileName), ["zone", "inner", "loose"])
        XCTAssertEqual(try panes[0].document?.read(at: 0, length: 0x200), Array(bytes[0x100..<0x300]))
        XCTAssertEqual(try panes[1].document?.read(at: 0, length: 0x40), Array(bytes[0x140..<0x180]))
        XCTAssertIdentical(panes[0].origin?.parent, target.windowModel.pane1, "the part knows its way home")
        XCTAssertIdentical(panes[1].origin?.parent, panes[0])
        XCTAssertNil(panes[2].origin)
        XCTAssertEqual(panes[0].document?.selection.start, 0x10)
        XCTAssertEqual(target.fragments.expanded, target.fragments.panel(holding: panes[0]))
    }

    // MARK: - Tools

    func testTheToolPanelComesBackOnItsPaneWithoutMovingTheWindow() throws {
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
        XCTAssertEqual(target.restoreWorkspaceTab(tab).issues, [])

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

    func testAnUntitledDocumentComesBackWithItsBytesAndStillUnsaved() throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        let bytes: [UInt8] = (0..<0x300).map { UInt8($0 & 0xFF) }
        pane.openBytes(bytes, named: "joined.bin")
        pane.document?.undoHistory.clearKeepingDirty()
        pane.select(range: 0x120..<0x130)
        window.mainViewController.refreshMode()
        let (recorder, _) = recorder([window])
        recorder.record()

        let saved = try XCTUnwrap(recorder.savedWorkspace())
        let tab = try XCTUnwrap(saved.windows.first?.tabs.first)
        guard case let .untitled(stamp)? = tab.panes[0]?.document else { return XCTFail("an untitled pane") }
        XCTAssertEqual(stamp.name, "joined.bin")
        XCTAssertTrue(stamp.dirty)

        let target = shownWindow().mainViewController
        XCTAssertEqual(target.restoreWorkspaceTab(tab, keeper: recorder.keeper).issues, [])
        let restored = target.windowModel.pane1
        XCTAssertTrue(restored.isUntitled)
        XCTAssertEqual(restored.status.fileName, "joined.bin")
        XCTAssertEqual(try restored.document?.read(at: 0, length: 0x300), bytes)
        XCTAssertTrue(restored.status.isDirty, "closing it must still ask")
        XCTAssertEqual(restored.document?.selection.start, 0x120)
    }

    func testTheSnapshotAtQuitLeavesOutUntitledDocumentsAndTheirBytes() throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let a = try dump(0x100, 0xAA)
        let files = shownWindow()
        files.mainViewController.openFiles([a])
        let untitled = shownWindow()
        untitled.mainViewController.windowModel.pane1.openBytes([1, 2, 3], named: nil)
        untitled.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([files, untitled])

        recorder.record()
        XCTAssertEqual(try XCTUnwrap(recorder.savedWorkspace()).windows.count, 2)
        let kept = folderURL.appendingPathComponent("Untitled")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path).count, 1)

        recorder.record(final: true)
        XCTAssertEqual(try XCTUnwrap(recorder.savedWorkspace()).windows.count, 1,
                       "an untitled document still open at quit was discarded")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path), [])
    }

    func testUnchangedUntitledBytesAreNotWrittenAgain() throws {
        WorkspaceSettings.set(restoresWorkspace: true)
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        pane.openBytes([UInt8](repeating: 7, count: 64), named: nil)
        window.mainViewController.refreshMode()
        let (recorder, folderURL) = recorder([window])
        recorder.record()
        let kept = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: folderURL.appendingPathComponent("Untitled"), includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: kept)

        pane.select(range: 4..<8)
        recorder.record()
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "a caret move is not new bytes")

        pane.document?.undoHistory.clearKeepingDirty()
        recorder.record()
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "new content is written")
    }

    // MARK: - The recorder

    func testTheRecorderWritesTabsWithFilesAndOnlyWhileSwitchedOn() throws {
        let a = try dump(0x100, 0xAA)
        let withFile = shownWindow()
        withFile.mainViewController.openFiles([a])
        let empty = shownWindow()
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRecorderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folderURL) }
        let recorder = WorkspaceRecorder(folder: WorkspaceFolder(url: folderURL),
                                         controllers: { [withFile, empty] })

        recorder.record()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path),
                       "nothing is written while the switch is off")

        WorkspaceSettings.set(restoresWorkspace: true)
        recorder.record()
        let saved = try XCTUnwrap(recorder.savedWorkspace())
        XCTAssertEqual(saved.windows.count, 1, "an empty window is not part of the workspace")
        XCTAssertEqual(saved.windows.first?.tabs.first?.panes.first??.document,
                       .file(try XCTUnwrap(FileStamp(url: a))))

        WorkspaceSettings.set(restoresWorkspace: false)
        recorder.record()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path),
                       "switching off deletes the workspace")
    }
}
