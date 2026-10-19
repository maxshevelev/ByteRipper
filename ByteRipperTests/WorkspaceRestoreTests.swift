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
        let issues = target.restoreWorkspaceTab(tab)

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
        let issues = target.restoreWorkspaceTab(tab)

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
        let issues = target.restoreWorkspaceTab(tab)

        XCTAssertEqual(issues, [.changed(path: a.standardizedFileURL.path)])
        XCTAssertEqual(target.windowModel.pane1.document?.selection.start, 0x7FF)
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
