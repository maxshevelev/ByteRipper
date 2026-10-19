import XCTest
@testable import Workspace

final class WorkspaceTests: XCTestCase {
    private func pane(_ path: String = "/dumps/a.bin", size: UInt64 = 0x1000,
                      selection: Range<UInt64> = 0x10..<0x20, top: UInt64 = 0) -> PaneState {
        PaneState(document: .file(FileStamp(path: path, size: size, modified: Date(timeIntervalSince1970: 1000))),
                  selectionStart: selection.lowerBound, selectionEnd: selection.upperBound,
                  inputRegion: .text, insertMode: true, topOffset: top)
    }

    // MARK: - The file

    func testAWorkspaceReadsBackAsItWasWritten() throws {
        let folder = WorkspaceFolder(url: temporaryFolder())
        let workspace = Workspace(windows: [
            WindowState(frame: Rect(x: 10, y: 20, width: 800, height: 600),
                        tabs: [TabState(panes: [pane(), nil], activePane: 0),
                               TabState(panes: [pane("/dumps/b.bin"), pane("/dumps/c.bin")],
                                        activePane: 1, dividerFraction: 0.3)],
                        selectedTab: 1),
        ])
        XCTAssertTrue(try folder.write(workspace))
        XCTAssertEqual(WorkspaceFolder(url: folder.url).read(), workspace)
    }

    func testTheSameWorkspaceIsNotWrittenTwice() throws {
        let folder = WorkspaceFolder(url: temporaryFolder())
        let workspace = Workspace(windows: [])
        XCTAssertTrue(try folder.write(workspace))
        XCTAssertFalse(try folder.write(workspace), "nothing changed, nothing to write")
    }

    func testAnotherVersionIsIgnored() throws {
        let folder = WorkspaceFolder(url: temporaryFolder())
        var workspace = Workspace(windows: [])
        workspace.version = Workspace.currentVersion + 1
        try folder.write(workspace)
        XCTAssertNil(WorkspaceFolder(url: folder.url).read())
    }

    func testRemovingTheFolderLeavesNothingToRead() throws {
        let folder = WorkspaceFolder(url: temporaryFolder())
        try folder.write(Workspace(windows: []))
        folder.remove()
        XCTAssertNil(folder.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
    }

    func testAWorkspaceWithOnlyEmptyTabsIsEmpty() {
        let empty = Workspace(windows: [WindowState(frame: Rect(x: 0, y: 0, width: 1, height: 1),
                                                    tabs: [TabState(panes: [nil, nil], activePane: 0)],
                                                    selectedTab: 0)])
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - A file on disk

    func testAStampSaysWhetherTheFileChanged() {
        let date = Date(timeIntervalSince1970: 1000)
        let stamp = FileStamp(path: "/a", size: 16, modified: date)
        XCTAssertTrue(stamp.isUnchanged(comparedWith: FileStamp(path: "/a", size: 16, modified: date)))
        XCTAssertFalse(stamp.isUnchanged(comparedWith: FileStamp(path: "/a", size: 17, modified: date)))
        XCTAssertFalse(stamp.isUnchanged(comparedWith: FileStamp(path: "/a", size: 16, modified: date + 60)))
    }

    func testAStampIsReadFromDisk() throws {
        let url = temporaryFolder().appendingPathComponent("dump.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 32).write(to: url)
        let stamp = try XCTUnwrap(FileStamp(url: url))
        XCTAssertEqual(stamp.size, 32)
        XCTAssertNotNil(stamp.modified)
        XCTAssertNil(FileStamp(url: url.appendingPathExtension("gone")))
    }

    // MARK: - What a restore applies

    func testAnUnchangedFileGetsEverythingBack() {
        let restore = PaneRestore(pane(selection: 0x10..<0x20, top: 0x100), size: 0x1000, unchanged: true)
        XCTAssertEqual(restore.selection, 0x10..<0x20)
        XCTAssertEqual(restore.topOffset, 0x100)
        XCTAssertEqual(restore.inputRegion, .text)
        XCTAssertTrue(restore.insertMode)
        XCTAssertTrue(restore.keepsMeasuredState)
    }

    func testAShorterFileMovesThePositionToItsLastAddress() {
        let restore = PaneRestore(pane(selection: 0xF00..<0xF10, top: 0xE00), size: 0x800, unchanged: false)
        XCTAssertEqual(restore.selection, 0x7FF..<0x800)
        XCTAssertEqual(restore.topOffset, 0x7FF)
        XCTAssertFalse(restore.keepsMeasuredState, "segments and tools were measured on other bytes")
    }

    func testAChangedFileKeepsAPositionThatStillFits() {
        let restore = PaneRestore(pane(selection: 0x10..<0x20, top: 0), size: 0x2000, unchanged: false)
        XCTAssertEqual(restore.selection, 0x10..<0x20)
        XCTAssertFalse(restore.keepsMeasuredState)
    }

    func testAnEmptyFileTakesTheCaretToZero() {
        let restore = PaneRestore(pane(selection: 0x10..<0x20, top: 0x10), size: 0, unchanged: false)
        XCTAssertEqual(restore.selection, 0..<0)
        XCTAssertEqual(restore.topOffset, 0)
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

extension WorkspaceTests {
    func testAStampReadFromDiskReadsBackEqual() throws {
        let url = temporaryFile()
        try Data(repeating: 0, count: 8).write(to: url)
        let stamp = try XCTUnwrap(FileStamp(url: url))
        let data = try JSONEncoder.iso8601.encode(stamp)
        XCTAssertEqual(try JSONDecoder.iso8601.decode(FileStamp.self, from: data), stamp)
    }

    private func temporaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
