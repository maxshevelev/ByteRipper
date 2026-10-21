import ByteRipperCore
import Workspace
import XCTest
@testable import ByteRipper

/// A project keeps what the session keeps, and the unsaved changes of its
/// files besides; it finds its files again when the job folder moved whole
/// (`Design/WORKSPACE_PLAN.md`, "Projects").
@MainActor
final class ProjectTests: XCTestCase {
    private func shownWindow() -> MainWindowController {
        let controller = MainWindowController(frameAutosaveName: nil)
        controller.showWindow(nil)
        controller.window?.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: true)
        addTeardownBlock { controller.close() }
        return controller
    }

    /// A job folder: a dump, and the project beside it.
    private func jobFolder() throws -> (folder: URL, dump: URL, project: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dumps"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let dump = folder.appendingPathComponent("dumps/bios.bin")
        try Data((0..<0x400).map { UInt8($0 & 0xFF) }).write(to: dump)
        return (folder, dump, folder.appendingPathComponent("Job.brp"))
    }

    private func record(_ windows: [MainWindowController], into project: URL) async -> WorkspaceRecorder {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("Session-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: session) }
        let recorder = WorkspaceRecorder(folder: WorkspaceFolder(url: session), controllers: { windows },
                                         notes: { nil })
        recorder.switchTo(project: WorkspaceFolder.project(at: project))
        await recorder.recordSettled()
        return recorder
    }

    private func reopen(_ project: URL) async -> (MainViewController, [RestoreIssue]) {
        let folder = WorkspaceFolder.project(at: project)
        let workspace = folder.read()
        let keeper = ContentKeeper(folder: folder, isProject: true)
        let target = shownWindow().mainViewController
        let restorer = WorkspaceRestorer(keeper: keeper)
        if let tab = workspace?.windows.first?.tabs.first { restorer.openFiles(of: tab, in: target) }
        await restorer.openParts()
        return (target, restorer.issues)
    }

    func testAProjectKeepsTheRedBytesOfAFileOnDisk() async throws {
        let (_, dump, project) = try jobFolder()
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        window.mainViewController.openFiles([dump])
        pane.select(range: 0x10..<0x10)
        try pane.pasteWrite([0xDE, 0xAD])
        try pane.pasteInsert([0x01])
        let recorder = await record([window], into: project)

        let saved = try XCTUnwrap(WorkspaceFolder.project(at: project).read())
        let state = try XCTUnwrap(saved.windows.first?.tabs.first?.panes.first ?? nil)
        XCTAssertNotNil(state.kept, "the changes are part of the project")
        guard case let .file(stamp) = state.document else { return XCTFail("a file") }
        XCTAssertEqual(stamp.relativePath, "dumps/bios.bin")
        XCTAssertTrue(recorder.keeper.holdsCurrentBytes(of: pane), "leaving the project asks nothing")
        let expected = try pane.document?.read(at: 0, length: 0x401)

        let (target, issues) = await reopen(project)
        XCTAssertEqual(issues, [])
        let restored = target.windowModel.pane1
        XCTAssertEqual(try restored.document?.read(at: 0, length: 0x401), expected)
        XCTAssertTrue(restored.status.isDirty, "still unsaved")
        XCTAssertEqual(try Data(contentsOf: dump).count, 0x400, "the file on disk is untouched")
    }

    func testAJobFolderMovedWholeIsFoundAgain() async throws {
        let (folder, dump, project) = try jobFolder()
        let window = shownWindow()
        window.mainViewController.openFiles([dump])
        _ = await record([window], into: project)
        window.mainViewController.windowModel.pane1.close()

        let moved = folder.deletingLastPathComponent().appendingPathComponent("Moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder, to: moved)
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }

        let (target, issues) = await reopen(moved.appendingPathComponent("Job.brp"))
        XCTAssertEqual(issues, [])
        XCTAssertEqual(target.windowModel.pane1.document?.url.standardizedFileURL,
                       moved.appendingPathComponent("dumps/bios.bin").standardizedFileURL)
    }

    func testChangesToAFileChangedOutsideTheProjectAreNotLaidOver() async throws {
        let (_, dump, project) = try jobFolder()
        let window = shownWindow()
        let pane = window.mainViewController.windowModel.pane1
        window.mainViewController.openFiles([dump])
        pane.select(range: 0..<0)
        try pane.pasteWrite([0xFF])
        _ = await record([window], into: project)
        pane.close()
        try Data(repeating: 7, count: 0x200).write(to: dump)

        let (target, issues) = await reopen(project)
        XCTAssertEqual(issues, [.changed(path: dump.standardizedFileURL.path)])
        XCTAssertFalse(target.windowModel.pane1.status.isDirty, "the changes were made on other bytes")
    }

    func testAProjectIsRecognisedByItsExtension() {
        XCTAssertTrue(URL(fileURLWithPath: "/jobs/Job.brp").isByteRipperProject)
        XCTAssertTrue(URL(fileURLWithPath: "/jobs/Job.BRP").isByteRipperProject)
        XCTAssertFalse(URL(fileURLWithPath: "/jobs/bios.bin").isByteRipperProject)
    }

    /// The last window of a project closing is a quit, not a close: the
    /// window stays for the quit to record, and nothing is asked here.
    func testClosingTheLastWindowOfAProjectQuitsInstead() throws {
        let window = shownWindow()
        let controller = window.mainViewController
        var quits = 0
        controller.quitsInsteadOfClosing = { quits += 1; return true }
        let nsWindow = try XCTUnwrap(window.window)
        XCTAssertFalse(controller.windowShouldClose(nsWindow))
        XCTAssertEqual(quits, 1)
        XCTAssertTrue(nsWindow.isVisible)

        controller.quitsInsteadOfClosing = { false }
        XCTAssertTrue(controller.windowShouldClose(nsWindow), "any other window closes as before")
    }
}
