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

extension WorkspaceTests {
    func testBookmarksPastEveryFileAreDropped() {
        let marks = [BookmarkState(row: 0x10, name: "a"), BookmarkState(row: 0x900, name: "b")]
        XCTAssertEqual(marks.restorable(withinLargest: 0x800), [marks[0]])
        XCTAssertEqual(marks.restorable(withinLargest: nil), marks, "no file open, nothing to measure against")
    }

    func testSegmentsApplyOnlyToTheBytesTheyWereCutOn() {
        let cut = SegmentationState(contentSize: 0x1000, pieces: [PieceState(start: 0, name: "a"),
                                                                  PieceState(start: 0x800, name: "b")])
        XCTAssertTrue(cut.applies(toSize: 0x1000, unchanged: true))
        XCTAssertFalse(cut.applies(toSize: 0x1000, unchanged: false))
        XCTAssertFalse(cut.applies(toSize: 0x2000, unchanged: true))
        let unsorted = SegmentationState(contentSize: 0x1000, pieces: [PieceState(start: 0, name: "a"),
                                                                       PieceState(start: 0, name: "b")])
        XCTAssertFalse(unsorted.applies(toSize: 0x1000, unchanged: true))
    }
}

extension WorkspaceTests {
    func testKeptFilesStayUntilNoWorkspaceNamesThem() throws {
        let folder = WorkspaceFolder(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceTests-\(UUID().uuidString)"))
        addTeardownBlock { folder.remove() }
        try folder.prepareKeptFolder()
        try Data([1, 2, 3]).write(to: folder.keptURL("a-1.bin"))
        try Data([4]).write(to: folder.keptURL("b-1.log"))

        folder.removeKept(except: ["b-1.log"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.keptURL("a-1.bin").path))
        XCTAssertEqual(try Data(contentsOf: folder.keptURL("b-1.log")), Data([4]))
    }

    /// Kept content names the files it is read from, whatever its base.
    func testKeptContentNamesItsFiles() {
        let log = KeptLog(file: "d-2.log", length: 10, hash: "00")
        XCTAssertEqual(KeptContent(id: "d", base: .file(serial: 3), head: 5, nextSerial: 6, saved: 3, log: log).files,
                       ["d-2.log"])
        XCTAssertEqual(KeptContent(id: "d", base: .bytes(file: "d-2.bin", serial: 3, hash: "00"), head: 3, nextSerial: 4).files,
                       ["d-2.bin"])
        XCTAssertEqual(KeptBase.edits(file: "x", serial: 9, hash: "00").serial, 9)
    }
}

extension WorkspaceTests {
    func testARelativePathClimbsOutOfTheProjectsFolder() {
        let folder = URL(fileURLWithPath: "/Users/me/Jobs/1234")
        XCTAssertEqual(FileStamp.relativePath(of: "/Users/me/Jobs/1234/dumps/a.bin", to: folder), "dumps/a.bin")
        XCTAssertEqual(FileStamp.relativePath(of: "/Users/me/Jobs/shared/b.bin", to: folder), "../shared/b.bin")
        XCTAssertNil(FileStamp.relativePath(of: "/Volumes/USB/c.bin", to: folder))
    }

    func testAFileMovedWithItsProjectIsFoundByItsRelativePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Move-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let moved = root.appendingPathComponent("new/dumps")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data([1]).write(to: moved.appendingPathComponent("a.bin"))
        var stamp = FileStamp(path: root.appendingPathComponent("old/dumps/a.bin").path, size: 1, modified: nil)
        stamp.relativePath = "dumps/a.bin"
        XCTAssertEqual(stamp.locate(relativeTo: root.appendingPathComponent("new"))?.lastPathComponent, "a.bin")
        XCTAssertNil(stamp.locate(relativeTo: root.appendingPathComponent("elsewhere")))
    }

    func testAProjectIsItsOwnFolder() throws {
        let folder = WorkspaceFolder.project(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("Job-\(UUID().uuidString).brp"))
        addTeardownBlock { folder.remove() }
        try folder.write(Workspace(windows: []))
        XCTAssertEqual(folder.fileURL.lastPathComponent, "Project.json")
        XCTAssertEqual(folder.keptFolder.deletingLastPathComponent().standardizedFileURL,
                       folder.url.standardizedFileURL)
    }

    /// Every kept content in a workspace is reached — a file's, an untitled
    /// document's, a part's, in a tab and in a panel.
    func testEveryKeptContentIsReached() {
        func content(_ id: String) -> KeptContent {
            KeptContent(id: id, base: .file(serial: 0), head: 1, nextSerial: 2)
        }
        let file = PaneState(document: .file(FileStamp(path: "/a", size: 1, modified: nil)),
                             selectionStart: 0, selectionEnd: 0, topOffset: 0, kept: content("file"))
        let untitled = PaneState(document: .untitled(UntitledStamp(content: content("untitled"), name: nil,
                                                                   size: 1, dirty: true)),
                                 selectionStart: 0, selectionEnd: 0, topOffset: 0)
        let part = PaneState(document: .part(PartOrigin(parent: "p1", sourceStart: 0, sourceEnd: 1, name: "zone",
                                                        layout: nil, codec: nil, size: 1,
                                                        edits: UntitledStamp(content: content("part"), name: nil,
                                                                             size: 1, dirty: true))),
                             selectionStart: 0, selectionEnd: 0, topOffset: 0)
        let tab = TabState(panes: [file, untitled], activePane: 0,
                           fragments: [FragmentState(pane: part, surface: SurfaceState())])
        let workspace = Workspace(windows: [WindowState(frame: Rect(x: 0, y: 0, width: 1, height: 1),
                                                        tabs: [tab], selectedTab: 0)])
        var seen: [String] = []
        let updated = workspace.updatingKept { kept in
            seen.append(kept.id)
            var kept = kept
            kept.head = 9
            return kept
        }
        XCTAssertEqual(Set(seen), ["file", "untitled", "part"])
        let panes = updated.windows[0].tabs[0]
        XCTAssertEqual(panes.panes[0]?.kept?.head, 9)
        guard case let .untitled(stamp)? = panes.panes[1]?.document,
              case let .part(origin) = panes.fragments[0].pane.document else { return XCTFail() }
        XCTAssertEqual(stamp.content.head, 9)
        XCTAssertEqual(origin.edits?.content.head, 9)
    }

    /// A Code screen written before `place` existed reads with its indices
    /// and no place; one written now keeps both, so an earlier build still
    /// finds the indices it understands.
    func testACodeScreenPlaceIsAnAddedOptionalField() throws {
        let before = #"{"manifest":"{}","selectedFunction":3,"selectedInstruction":40,"showsC":true}"#
        let old = try JSONDecoder().decode(CodeScreenState.self, from: Data(before.utf8))
        XCTAssertEqual(old.selectedFunction, 3)
        XCTAssertEqual(old.selectedInstruction, 40)
        XCTAssertNil(old.place)

        let now = CodeScreenState(manifest: "{}", selectedFunction: 3, selectedInstruction: 40,
                                  place: .init(function: "0x1F00", instruction: "0x1F2C"),
                                  showsC: true)
        let data = try JSONEncoder().encode(now)
        XCTAssertEqual(try JSONDecoder().decode(CodeScreenState.self, from: data), now)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["selectedFunction"] as? Int, 3)
        XCTAssertEqual(fields["selectedInstruction"] as? Int, 40)
    }
}
