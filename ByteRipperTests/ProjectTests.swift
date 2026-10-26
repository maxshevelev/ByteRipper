import ByteRipperCore
import CodeAnalysis
import Localization
import PartCodec
import UEFIToolUI
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


    /// A project carries the analyses its Code screens show: the bundle sits
    /// beside `Project.json`, a reference keeps the store from collecting the
    /// objects, and the screen comes back on a machine whose store is empty.
    func testAProjectCarriesItsCodeAnalyses() async throws {
        let (_, dump, project) = try jobFolder()
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        let artifactData = Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x0","name":"entry","instructions":[
            {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
        """.utf8)
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: artifactData)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectAnalyses-\(UUID().uuidString)")
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

        let window = shownWindow()
        let controller = window.mainViewController
        controller.openFiles([dump])
        controller.openCode(
            named: "CpuPei body", from: controller.windowModel.pane1,
            source: 0x100..<0x200, manifest: manifest, artifact: artifact,
            codec: ReadOnlyPartCodec(codeBytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        XCTAssertTrue(store.refs().isEmpty, "viewing alone creates no reference")

        _ = await record([window], into: project)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CodeAnalysisStore.bundleURL(in: project).path),
            "the project carries its analysis")
        XCTAssertEqual(store.refs().map(\.name),
                       [CodeAnalysisStore.projectRefName(for: project)])

        // Another Mac: no store, only the project folder.
        try FileManager.default.removeItem(at: storeRoot)
        let imported = try XCTUnwrap(CodeAnalysisStore.importProjectBundle(at: project))
        XCTAssertEqual(imported.imported.count, 1)
        XCTAssertNil(CodeAnalysisStore.noticeLines(for: imported), "nothing to tell")
        let (target, issues) = await reopen(project)
        XCTAssertEqual(issues, [])
        let restored = try XCTUnwrap(target.fragments.expanded.flatMap { target.fragments.codePane($0) })
        XCTAssertEqual(restored.selectedFunction?.name, "entry")

        // A Mac whose store holds another analysis under the same key: the
        // project opens with that one, and the notice says so.
        try FileManager.default.removeItem(at: storeRoot)
        try ContentStore(root: storeRoot).putAnalysis(
            module: manifest.module, recipe: manifest.recipe,
            artifact: Data(#"{"script_version":2,"ghidra":"12.1.2","functions":[]}"#.utf8))
        let other = try XCTUnwrap(CodeAnalysisStore.importProjectBundle(at: project))
        XCTAssertEqual(other.notTaken.map(\.kind), [.otherAnalysis])
        XCTAssertEqual(CodeAnalysisStore.noticeLines(for: other), [
            L("Not every code analysis of the project is shown as it was saved"),
            L("A different stored analysis is shown instead: %1$@", "1")])
    }

    /// A reading published again under the same key is written into the
    /// project's bundle too, not only a change of which analyses it shows.
    func testARepublishedReadingIsBundledAgain() async throws {
        let (_, dump, project) = try jobFolder()
        let codeBytes = [UInt8](repeating: 0x90, count: 0x100)
        func artifactData(_ name: String) -> Data {
            Data("""
            {"script_version":2,"ghidra":"12.1.2","functions":[
              {"entry":"0x0","name":"\(name)","instructions":[
                {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
            """.utf8)
        }
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectAnalyses-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try ContentStore(root: storeRoot)
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(codeBytes)),
                                    size: codeBytes.count, name: "CpuPei", kind: "TE",
                                    language: "x86:LE:32:default", imageBase: "0x0")
        let recipe = AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                    ghidra: "12.1.2", script: "ExportCode.java")
        let first = try store.putAnalysis(module: module, recipe: recipe, artifact: artifactData("entry"),
                                          reading: AnalysisReading(project: "p", rev: 1))
        let previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = storeRoot
        addTeardownBlock { UEFIToolModule.codeAnalysisRoot = previousRoot }

        let window = shownWindow()
        let controller = window.mainViewController
        controller.openFiles([dump])
        controller.openCode(
            named: "CpuPei body", from: controller.windowModel.pane1,
            source: 0x100..<0x200, manifest: first,
            artifact: try JSONDecoder().decode(CodeArtifact.self, from: artifactData("entry")),
            codec: ReadOnlyPartCodec(codeBytes, title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        let recorder = await record([window], into: project)

        try store.putAnalysis(module: module, recipe: recipe, artifact: artifactData("CpuInit"),
                              reading: AnalysisReading(project: "p", rev: 2))
        let id = try XCTUnwrap(controller.fragments.expanded)
        controller.codeStoreChanged()
        for _ in 0..<100 where controller.fragments.codePane(id)?.selectedFunction?.name != "CpuInit" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.fragments.codePane(id)?.selectedFunction?.name, "CpuInit")
        await recorder.recordSettled()

        let elsewhere = try ContentStore(root: storeRoot.appendingPathComponent("elsewhere"))
        _ = try elsewhere.importBundle(from: CodeAnalysisStore.bundleURL(in: project))
        XCTAssertEqual(try elsewhere.analysis(module: module.sha256)?.reading?.rev, 2)
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
