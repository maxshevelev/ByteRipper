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

    private func registry(limits: DumpLimits = DumpLimits(), roots: [URL]? = nil) throws -> DocumentRegistry {
        let registry = DocumentRegistry(roots: roots ?? [self.roots], uploads: uploads, file: file, limits: limits)
        try registry.restore()
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

    func testADocumentIsReadIntoATree() async throws {
        let registry = try registry()
        let id = try registry.open(path: try dump("board.bin"))
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
    func testAFileRewrittenInPlaceIsNotWhatIsRead() throws {
        let registry = try registry()
        let url = try dump("board.bin", marker: 1)
        let id = try registry.open(path: url)
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
    func testAnIdIsNeverGivenToAnotherFile() throws {
        var registry = try registry()
        try registry.open(path: try dump("a.bin", marker: 1))
        let second = try registry.open(path: try dump("b.bin", marker: 2))
        try registry.close(second)
        XCTAssertEqual(try registry.open(path: try dump("c.bin", marker: 3)), "d3")

        registry = try self.registry()
        XCTAssertEqual(registry.rows.map(\.id), ["d1", "d3"])
        XCTAssertEqual(try registry.open(path: try dump("d.bin", marker: 4)), "d4")
        XCTAssertEqual(try registry.open(path: roots.appendingPathComponent("a.bin")), "d1", "an open file answers its id")
    }

    /// A restore hashes what it reads: other bytes raise the version and
    /// carry no mark, the same bytes keep it.
    func testARestoreRaisesTheVersionOfOtherBytes() throws {
        var registry = try registry()
        let url = try dump("a.bin", marker: 1)
        try registry.open(path: try dump("b.bin", marker: 2))
        try registry.open(path: url)
        try registry.reopen("d2")
        XCTAssertEqual(registry.rows[1].version, 2, "a Reopen raises the version")

        try SyntheticDump.image(marker: 9).write(to: url)
        registry = try self.registry()
        XCTAssertEqual(registry.rows.map(\.version), [1, 3], "written at once, so a restart does not roll back")
        XCTAssertNil(try registry.resolve("d2").disk, "the snapshot is the file on disk now")
    }

    /// Decision 18: a path that does not resolve inside a root is refused,
    /// a symlink out of one included; a restored row whose root went is kept
    /// missing, its id held, and comes back under it.
    func testOnlyFilesUnderTheRootsAreOpened() throws {
        let outside = directory.appendingPathComponent("elsewhere.bin")
        try SyntheticDump.image().write(to: outside)
        var registry = try registry()
        XCTAssertThrowsError(try registry.open(path: outside))
        let link = roots.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try registry.open(path: link))

        try registry.open(path: try dump("a.bin"))
        let narrower = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: narrower, withIntermediateDirectories: true)
        registry = try self.registry(roots: [narrower])
        XCTAssertEqual(state(registry, "d1"), MissingReason.outsideRoots.message)
        XCTAssertTrue(registry.documents().isEmpty)
        XCTAssertThrowsError(try registry.resolve("d1")) { error in
            let message = (error as? AgentToolError)?.message ?? ""
            XCTAssertTrue(message.contains("outside the dump roots"), message)
        }

        registry = try self.registry()
        XCTAssertEqual(state(registry, "d1"), "open")
    }

    /// Rows are restored in their stored order and each is admitted if the
    /// limits allow; the one that does not fit stays missing with the limit
    /// named, and the order decides which.
    func testTheLimitsAndTheOrderDecideWhatOpens() throws {
        var limits = DumpLimits()
        limits.documents = 1
        var registry = try registry()
        try registry.open(path: try dump("a.bin", marker: 1))
        try registry.open(path: try dump("b.bin", marker: 2))

        registry = try self.registry(limits: limits)
        XCTAssertEqual(state(registry, "d1"), "open")
        XCTAssertEqual(state(registry, "d2"), MissingReason.limit("the limit of 1 open documents").message)
        XCTAssertThrowsError(try registry.open(path: try dump("c.bin", marker: 3)))

        try registry.reorder(["d2", "d1"])
        registry = try self.registry(limits: limits)
        XCTAssertEqual(state(registry, "d2"), "open")
        XCTAssertEqual(state(registry, "d1"), MissingReason.limit("the limit of 1 open documents").message)

        limits.documents = 8
        limits.openBytes = 0x1800
        registry = try self.registry(limits: limits)
        XCTAssertEqual(state(registry, "d1"), MissingReason.limit("the limit of 6144 bytes of open documents").message)
    }

    /// A Reopen of a file that is gone keeps the id as a missing row; when
    /// the file is back, Reopen serves it under that id; Forget retires it.
    func testAGoneFileKeepsItsIdUntilForgotten() throws {
        let registry = try registry()
        let url = try dump("a.bin")
        try registry.open(path: url)
        try FileManager.default.removeItem(at: url)
        try registry.reopen("d1")
        XCTAssertEqual(state(registry, "d1"), MissingReason.gone.message)

        try dump("a.bin")
        try registry.reopen("d1")
        XCTAssertEqual(state(registry, "d1"), "open")
        XCTAssertEqual(registry.rows[0].version, 1, "the same bytes keep the version")

        try FileManager.default.removeItem(at: url)
        try registry.reopen("d1")
        try registry.forget("d1")
        XCTAssertEqual(try registry.open(path: try dump("a.bin")), "d2")
    }

    /// An upload is kept under its hash, 0600; the same bytes answer the id
    /// they have; only an upload is deleted.
    func testAnUploadIsNamedByItsHash() throws {
        let registry = try registry()
        let data = SyntheticDump.image(marker: 7)
        let id = try registry.upload(data, name: "../../etc/board.bin")
        let row = try XCTUnwrap(registry.rows.first)
        XCTAssertEqual(row.path.lastPathComponent, row.sha256)
        XCTAssertEqual(row.name, "../../etc/board.bin", "the name is shown, never a path")
        XCTAssertTrue(row.uploaded)
        let mode = try FileManager.default.attributesOfItem(atPath: row.path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try registry.upload(data, name: "again"), id)
        XCTAssertEqual(registry.rows.count, 1)

        let local = try registry.open(path: try dump("a.bin"))
        XCTAssertThrowsError(try registry.delete(local))
        try registry.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: row.path.path))

        var small = DumpLimits()
        small.uploadBytes = 16
        XCTAssertThrowsError(try self.registry(limits: small).upload(data, name: "big"))
    }

    /// No focus on a server: one open document is implied, several must be
    /// named.
    func testSeveralOpenMustBeNamed() throws {
        let registry = try registry()
        XCTAssertThrowsError(try registry.resolve(nil))
        try registry.open(path: try dump("a.bin", marker: 1))
        XCTAssertEqual(try registry.resolve(nil).id, "d1")
        try registry.open(path: try dump("b.bin", marker: 2))
        XCTAssertThrowsError(try registry.resolve(nil))
    }

    /// A `documents.json` that cannot be read stops the start rather than
    /// handing its ids out again.
    func testAnUnreadableFileIsNotStartedFromEmpty() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try registry())
    }
}
