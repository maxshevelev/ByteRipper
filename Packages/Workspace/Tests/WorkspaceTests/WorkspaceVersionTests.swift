import XCTest
@testable import Workspace

/// A workspace written by an earlier build still opens: each version from
/// `WorkspaceMigration.oldestReadable` on is kept as a file in `Fixtures/`,
/// written by the build of that version and never rewritten since.
final class WorkspaceVersionTests: XCTestCase {
    /// What `Fixtures/v4/Project.json` holds: a field of every kind the
    /// version had. When a later version migrates it, this is what the
    /// migration must arrive at.
    static func version4Sample() -> Workspace {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        var stamp = FileStamp(path: "/Jobs/T480/bios.bin", size: 0x100_0000, modified: date)
        stamp.relativePath = "bios.bin"
        stamp.sha256 = String(repeating: "ab", count: 32)
        let history = KeptHistory(undoBase: 1, redoTip: 9, redoSteps: [2, 1], savedState: 1,
                                  dirtyRegardless: false,
                                  joins: [KeptJoin(serial: 5, path: "/Jobs/T480/ec.bin", readOnly: true)],
                                  undoneJoins: [])
        let fileContent = KeptContent(
            id: "A1", base: .file(serial: 1), head: 6, nextSerial: 10, saved: 1,
            log: KeptLog(file: "A1-1.log", length: 812, hash: String(repeating: "cd", count: 32)),
            history: history)
        let editsContent = KeptContent(
            id: "A2", base: .edits(file: "A2-3.edits", serial: 3, hash: String(repeating: "01", count: 32)),
            head: 3, nextSerial: 4, saved: nil)
        let untitledContent = KeptContent(
            id: "U1", base: .bytes(file: "U1-0.bin", serial: 0, hash: String(repeating: "ef", count: 32)),
            head: 0, nextSerial: 1)
        let filePane = PaneState(
            id: "p1", document: .file(stamp), selectionStart: 0x10, selectionEnd: 0x20,
            inputRegion: .text, insertMode: true, topOffset: 0x1000,
            segments: SegmentationState(contentSize: 0x100_0000, pieces: [
                PieceState(start: 0, name: "Descriptor"),
                PieceState(start: 0x1000, name: "ME",
                           link: PieceLinkState(path: "/Jobs/T480/me.bin", sourceStart: 0, sourceEnd: 0x5000)),
            ]),
            uefiOpenRows: [[0], [0, 2, 1]], kept: fileContent)
        let otherFile = PaneState(document: .file(FileStamp(path: "/Jobs/T480/donor.bin", size: 0x100_0000,
                                                            modified: date)),
                                  selectionStart: 0, selectionEnd: 0, topOffset: 0, kept: editsContent)
        let untitled = PaneState(document: .untitled(UntitledStamp(content: untitledContent, name: "Join",
                                                                   size: 0x2000, dirty: true)),
                                 selectionStart: 4, selectionEnd: 4, topOffset: 0)
        let partEdits = UntitledStamp(
            content: KeptContent(id: "P1", base: .bytes(file: "P1-2.bin", serial: 2,
                                                        hash: String(repeating: "23", count: 32)),
                                 head: 2, nextSerial: 3),
            name: nil, size: 0x800, dirty: true)
        let part = PaneState(id: "p2",
                             document: .part(PartOrigin(parent: "p1", sourceStart: 0x40_0000, sourceEnd: 0x40_0400,
                                                        name: "Setup", layout: #"{"kind":"lzma"}"#,
                                                        codec: #"{"lzma":{}}"#, size: 0x800, edits: partEdits)),
                             selectionStart: 0, selectionEnd: 8, topOffset: 0)
        let surface = SurfaceState(minimapVisible: true, minimapMode: "overview",
                                   findPattern: FindPatternState(text: "$FPT", encoding: "ascii"),
                                   tool: ToolState(identifier: "uefi", state: Data([1, 2, 3]), pane: 0))
        let tab = TabState(panes: [filePane, otherFile], activePane: 1, dividerFraction: 0.4,
                           bookmarks: [BookmarkState(row: 0x1000, name: "ME start")],
                           surface: surface,
                           fragments: [FragmentState(pane: part, surface: SurfaceState(
                               tool: ToolState(identifier: "uefi", state: nil, pane: nil)))],
                           expandedFragment: 0)
        return Workspace(windows: [
            WindowState(frame: Rect(x: 10, y: 20, width: 1200, height: 800),
                        tabs: [tab, TabState(panes: [untitled, nil], activePane: 0)],
                        selectedTab: 0,
                        notes: NotesState(position: 2, isSelected: false, selected: ["n3"])),
        ])
    }

    private func fixture(_ version: Int) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "v\(version)", withExtension: nil,
                                        subdirectory: "Fixtures"))
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceVersionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Every version kept

    func testEveryReadableVersionHasAFixture() throws {
        for version in WorkspaceMigration.oldestReadable...Workspace.currentVersion {
            XCTAssertNoThrow(try fixture(version), "no fixture of version \(version)")
        }
    }

    func testEveryReadableVersionHasAStepToTheNext() {
        for version in WorkspaceMigration.oldestReadable..<Workspace.currentVersion {
            XCTAssertNotNil(WorkspaceMigration.steps[version], "no step from version \(version)")
        }
    }

    func testAProjectOfVersion4Opens() throws {
        let folder = WorkspaceFolder.project(at: try fixture(4))
        XCTAssertEqual(try folder.load().get(), Self.version4Sample())
    }

    // MARK: - The chain

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnEarlierVersionGoesThroughEveryStepInTurn() throws {
        let steps: [Int: WorkspaceMigration.Step] = [
            4: { $0["trail"] = "4" },
            5: { $0["trail"] = ($0["trail"] as? String ?? "") + "5" },
        ]
        let migrated = try object(WorkspaceMigration.migrate(try json(["version": 4, "windows": []]),
                                                             to: 6, oldest: 4, steps: steps))
        XCTAssertEqual(migrated["version"] as? Int, 6)
        XCTAssertEqual(migrated["trail"] as? String, "45")
    }

    func testTheCurrentVersionIsReadAsItIs() throws {
        let data = try json(["version": 6, "windows": []])
        XCTAssertEqual(try WorkspaceMigration.migrate(data, to: 6, oldest: 4, steps: [:]), data)
    }

    func testAVersionWithNoStepIsNotGuessedAt() {
        XCTAssertThrowsError(try WorkspaceMigration.migrate(try json(["version": 4]), to: 6, oldest: 4,
                                                            steps: [4: { _ in }])) {
            XCTAssertEqual($0 as? WorkspaceMigration.Failure, .unreadable)
        }
    }

    func testANewerVersionIsRefused() throws {
        let folder = WorkspaceFolder(url: temporaryFolder())
        var workspace = Workspace(windows: [])
        workspace.version = Workspace.currentVersion + 1
        try folder.write(workspace)
        XCTAssertEqual(WorkspaceFolder(url: folder.url).load(),
                       .failure(.newer(version: Workspace.currentVersion + 1)))
    }

    func testAVersionBeforeMigrationsIsRefused() throws {
        let folder = WorkspaceFolder(url: temporaryFolder())
        var workspace = Workspace(windows: [])
        workspace.version = WorkspaceMigration.oldestReadable - 1
        try folder.write(workspace)
        XCTAssertEqual(WorkspaceFolder(url: folder.url).load(),
                       .failure(.tooOld(version: WorkspaceMigration.oldestReadable - 1)))
    }

    func testAMigratedWorkspaceIsWrittenInThisVersion() throws {
        let url = temporaryFolder()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let original = try Data(contentsOf: try fixture(4).appendingPathComponent("Project.json"))
        try original.write(to: url.appendingPathComponent("Project.json"))
        let folder = WorkspaceFolder.project(at: url)
        try folder.write(try folder.load().get())
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.fileURL)) as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, Workspace.currentVersion)
    }
}
