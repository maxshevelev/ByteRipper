import AgentDocuments
import AgentKit
import Foundation
import UEFIImage
import XCTest
@testable import DumpHost

/// The documents the server holds (`Design/SERVER_HEADLESS_PLAN.md` §6):
/// snapshots, the disk mark, ids that survive a restart and are never given
/// to another file, the roots, the limits and the uploads.
@MainActor
final class DumpHostTests: XCTestCase {
    private var directory: URL!
    private var roots: URL!
    private var uploads: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DumpHostTests-\(UUID().uuidString)", isDirectory: true)
        roots = directory.appendingPathComponent("dumps", isDirectory: true)
        uploads = directory.appendingPathComponent("Server/Uploads", isDirectory: true)
        file = directory.appendingPathComponent("Server/documents.json")
        try FileManager.default.createDirectory(at: roots, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func registry(limits: DumpLimits = DumpLimits(), roots: [URL]? = nil) async throws -> DocumentRegistry {
        let registry = DocumentRegistry(roots: roots ?? [self.roots], uploads: uploads, file: file, limits: limits)
        try await registry.restore()
        return registry
    }

    @discardableResult
    private func dump(_ name: String, marker: UInt8 = 0) throws -> URL {
        let url = roots.appendingPathComponent(name)
        try SyntheticDump.image(marker: marker).write(to: url)
        return url
    }

    private func state(_ registry: DocumentRegistry, _ id: String) -> String {
        switch registry.rows.first(where: { $0.id == id })?.state {
        case .open?: return "open"
        case .missing(let reason)?: return reason.message
        case nil: return "none"
        }
    }

    /// `XCTAssertThrowsError` for a call that awaits: the autoclosure it takes
    /// cannot be async.
    private func assertThrows(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("\(what) did not throw", file: file, line: line)
        } catch {}
    }

    func testADocumentIsReadIntoATree() async throws {
        let registry = try await registry()
        let id = try await registry.open(path: try dump("board.bin"))
        let host = try XCTUnwrap(registry.rows.first?.host)
        XCTAssertEqual(id, "d1")
        XCTAssertEqual(host.contentSize, 0x1000)
        let tree = try XCTUnwrap(host.uefiTree())
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        XCTAssertFalse(tree.rootNodes.isEmpty, "the volume is read")
        XCTAssertTrue(tree === host.uefiTree(), "the tree lives with the document")
    }

    /// A file rewritten in place after open changes nothing an agent reads:
    /// the snapshot is the file as it was, and the mark says it is not the
    /// file on disk any more.
    func testAFileRewrittenInPlaceIsNotWhatIsRead() async throws {
        let registry = try await registry()
        let url = try dump("board.bin", marker: 1)
        let id = try await registry.open(path: url)
        let before = try registry.rows[0].host!.read(0x48..<0x100)

        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: SyntheticDump.image(marker: 2))
        try handle.close()
        XCTAssertEqual(try registry.rows[0].host!.read(0x48..<0x100), before)
        XCTAssertEqual(try registry.resolve(id).disk, "changed")
        XCTAssertEqual(registry.documents().first?.disk, "changed")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try registry.resolve(id).disk, "gone")
        XCTAssertEqual(try registry.rows[0].host!.read(0x48..<0x100), before, "a gone file goes on serving its snapshot")
    }

    /// Ids come from `next_id`: a closed document's id is not given to the
    /// next file, before or after a restart.
    func testAnIdIsNeverGivenToAnotherFile() async throws {
        var registry = try await registry()
        try await registry.open(path: try dump("a.bin", marker: 1))
        let second = try await registry.open(path: try dump("b.bin", marker: 2))
        try registry.close(second)
        let third = try await registry.open(path: try dump("c.bin", marker: 3))
        XCTAssertEqual(third, "d3", "the closed document's id is not given to the third")

        registry = try await self.registry()
        XCTAssertEqual(registry.rows.map(\.id), ["d1", "d3"])
        let fourth = try await registry.open(path: try dump("d.bin", marker: 4))
        XCTAssertEqual(fourth, "d4")
        let reopened = try await registry.open(path: roots.appendingPathComponent("a.bin"))
        XCTAssertEqual(reopened, "d1", "an open file answers its id")
    }

    /// A restore hashes what it reads: other bytes raise the version and
    /// carry no mark, the same bytes keep it.
    func testARestoreRaisesTheVersionOfOtherBytes() async throws {
        var registry = try await registry()
        let url = try dump("a.bin", marker: 1)
        try await registry.open(path: try dump("b.bin", marker: 2))
        try await registry.open(path: url)
        try await registry.reopen("d2")
        XCTAssertEqual(registry.rows[1].version, 2, "a Reopen raises the version")

        try SyntheticDump.image(marker: 9).write(to: url)
        registry = try await self.registry()
        XCTAssertEqual(registry.rows.map(\.version), [1, 3], "written at once, so a restart does not roll back")
        XCTAssertNil(try registry.resolve("d2").disk, "the snapshot is the file on disk now")
    }

    /// Decision 18: a path that does not resolve inside a root is refused,
    /// a symlink out of one included; a restored row whose root went is kept
    /// missing, its id held, and comes back under it.
    func testOnlyFilesUnderTheRootsAreOpened() async throws {
        let outside = directory.appendingPathComponent("elsewhere.bin")
        try SyntheticDump.image().write(to: outside)
        var registry = try await registry()
        await assertThrows("opening a path outside the roots") { try await registry.open(path: outside) }
        let link = roots.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await assertThrows("opening a symlink out of the roots") { try await registry.open(path: link) }

        try await registry.open(path: try dump("a.bin"))
        let narrower = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: narrower, withIntermediateDirectories: true)
        registry = try await self.registry(roots: [narrower])
        XCTAssertEqual(state(registry, "d1"), MissingReason.outsideRoots.message)
        XCTAssertTrue(registry.documents().isEmpty)
        XCTAssertThrowsError(try registry.resolve("d1")) { error in
            let message = (error as? AgentToolError)?.message ?? ""
            XCTAssertTrue(message.contains("outside the dump roots"), message)
        }

        registry = try await self.registry()
        XCTAssertEqual(state(registry, "d1"), "open")
    }

    /// A root that is not there is named, not read as a file that went: a
    /// mistyped `--dump-roots` or an unmounted volume is the operator's to
    /// see, and the document keeps its id until the root is back.
    func testAnAbsentRootIsNamedAndComesBackWithIt() async throws {
        let volume = directory.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let url = volume.appendingPathComponent("a.bin")
        try SyntheticDump.image(marker: 1).write(to: url)

        var registry = try await self.registry(roots: [volume])
        try await registry.open(path: url)
        XCTAssertTrue(registry.absentRoots.isEmpty)

        // The volume goes: the document is untouched, the root is not there.
        try FileManager.default.removeItem(at: volume)
        registry = try await self.registry(roots: [volume])
        XCTAssertEqual(registry.absentRoots.map(\.path), [volume.path])
        XCTAssertEqual(state(registry, "d1"), MissingReason.rootMissing(volume.path).message)
        await assertThrows("opening under an absent root") { try await registry.open(path: url) }

        // Mounted again with the same bytes: the id comes back under it.
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try SyntheticDump.image(marker: 1).write(to: url)
        registry = try await self.registry(roots: [volume])
        XCTAssertEqual(state(registry, "d1"), "open")
    }

    /// Rows are restored in their stored order and each is admitted if the
    /// limits allow; the one that does not fit stays missing with the limit
    /// named, and the order decides which.
    func testTheLimitsAndTheOrderDecideWhatOpens() async throws {
        var limits = DumpLimits()
        limits.documents = 1
        var registry = try await registry()
        try await registry.open(path: try dump("a.bin", marker: 1))
        try await registry.open(path: try dump("b.bin", marker: 2))

        registry = try await self.registry(limits: limits)
        XCTAssertEqual(state(registry, "d1"), "open")
        XCTAssertEqual(state(registry, "d2"), MissingReason.limit("the limit of 1 open documents").message)
        await assertThrows("opening past the document limit") {
            try await registry.open(path: try dump("c.bin", marker: 3))
        }

        try registry.reorder(["d2", "d1"])
        registry = try await self.registry(limits: limits)
        XCTAssertEqual(state(registry, "d2"), "open")
        XCTAssertEqual(state(registry, "d1"), MissingReason.limit("the limit of 1 open documents").message)

        limits.documents = 8
        limits.openBytes = 0x1800
        registry = try await self.registry(limits: limits)
        XCTAssertEqual(state(registry, "d1"), MissingReason.limit("the limit of 6144 bytes of open documents").message)
    }

    /// A Reopen of a file that is gone keeps the id as a missing row; when
    /// the file is back, Reopen serves it under that id; Forget retires it.
    func testAGoneFileKeepsItsIdUntilForgotten() async throws {
        let registry = try await registry()
        let url = try dump("a.bin")
        try await registry.open(path: url)
        try FileManager.default.removeItem(at: url)
        try await registry.reopen("d1")
        XCTAssertEqual(state(registry, "d1"), MissingReason.gone.message)

        try dump("a.bin")
        try await registry.reopen("d1")
        XCTAssertEqual(state(registry, "d1"), "open")
        XCTAssertEqual(registry.rows[0].version, 1, "the same bytes keep the version")

        try FileManager.default.removeItem(at: url)
        try await registry.reopen("d1")
        try registry.forget("d1")
        let again = try await registry.open(path: try dump("a.bin"))
        XCTAssertEqual(again, "d2", "the forgotten id is retired, the next is new")
    }

    /// An upload is kept under its hash, 0600; the same bytes answer the id
    /// they have; only an upload is deleted.
    func testAnUploadIsNamedByItsHash() async throws {
        let registry = try await registry()
        let data = SyntheticDump.image(marker: 7)
        let id = try await registry.upload(data, name: "../../etc/board.bin")
        let row = try XCTUnwrap(registry.rows.first)
        XCTAssertEqual(row.path.lastPathComponent, row.sha256)
        XCTAssertEqual(row.name, "../../etc/board.bin", "the name is shown, never a path")
        XCTAssertTrue(row.uploaded)
        let mode = try FileManager.default.attributesOfItem(atPath: row.path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let repeated = try await registry.upload(data, name: "again")
        XCTAssertEqual(repeated, id, "the same bytes answer the id they have")
        XCTAssertEqual(registry.rows.count, 1)

        let local = try await registry.open(path: try dump("a.bin"))
        XCTAssertThrowsError(try registry.delete(local))
        try registry.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: row.path.path))

        var small = DumpLimits()
        small.uploadBytes = 16
        let narrow = try await self.registry(limits: small)
        await assertThrows("an upload past its own limit") { try await narrow.upload(data, name: "big") }
    }

    /// No focus on a server: one open document is implied, several must be
    /// named.
    func testSeveralOpenMustBeNamed() async throws {
        let registry = try await registry()
        XCTAssertThrowsError(try registry.resolve(nil))
        try await registry.open(path: try dump("a.bin", marker: 1))
        XCTAssertEqual(try registry.resolve(nil).id, "d1")
        try await registry.open(path: try dump("b.bin", marker: 2))
        XCTAssertThrowsError(try registry.resolve(nil))
    }

    /// A `documents.json` that cannot be read stops the start rather than
    /// handing its ids out again.
    func testAnUnreadableFileIsNotStartedFromEmpty() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        await assertThrows("starting from an unreadable file") { _ = try await self.registry() }
    }

    /// The invariant decision 10 states is kept against the file itself: an id
    /// named twice, or a `next_id` already passed, stops the start rather
    /// than handing a live id to the next document.
    func testAFileThatWouldReuseAnIdIsRefused() async throws {
        let url = try dump("a.bin")
        try await registry().open(path: url)
        var saved = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any])
        var documents = try XCTUnwrap(saved["documents"] as? [[String: Any]])
        documents.append(documents[0])
        saved["documents"] = documents
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        await assertThrows("starting from a file that names an id twice") { _ = try await self.registry() }

        documents.removeLast()
        saved["documents"] = documents
        saved["next_id"] = 1
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let registry = try await self.registry()
        let next = try await registry.open(path: try dump("b.bin", marker: 2))
        XCTAssertEqual(next, "d2", "next_id below the rows is raised past them")
    }
}
