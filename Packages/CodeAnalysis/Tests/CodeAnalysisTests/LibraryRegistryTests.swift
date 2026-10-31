import Foundation
import XCTest
@testable import CodeAnalysis

/// The library registry in the store (`Design/LIBRARY_REGISTRY_PLAN.md`): one
/// entry per body, improved in place, a conflict for another module's review,
/// taken only with a reason, and every version's object kept by collection.
final class LibraryRegistryTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let first = SHA256Digest(data: Data("AmdSocFp6CznPei".utf8))
    private let second = SHA256Digest(data: Data("AmdSocFp6RnPei".utf8))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRegistryTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let body = LibraryBody(size: 0x15, full: "00112233445566aa", specific: "0123456789abcdef")

    private func proposal(_ name: String, plate: String = "EDK2 BaseMemoryLib SetMem", kind: String = "edk2",
                          body: LibraryBody? = nil, address: String = "0x9A91116") -> LibraryProposal {
        let entry: [String: Any] = ["schema": 1, "name": name, "kind": kind, "plate": plate]
        let data = try! JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
        return LibraryProposal(body: body ?? self.body, name: name, kind: kind, address: address, entry: data)
    }

    func testANewBodyIsAnEntryAndTheSameReviewIsNoChange() throws {
        let added = try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        XCTAssertEqual(added.added.map(\.name), ["SetMem"])
        let index = try store.libraryIndex()
        let (id, entry) = try XCTUnwrap(index.entry(for: body))
        XCTAssertEqual(id, body.key)
        XCTAssertEqual(entry.version, 1)
        XCTAssertEqual(entry.source, LibrarySource(module: first, address: "0x9A91116", rev: 33, by: "agent"))
        XCTAssertEqual(entry.variants, [LibraryVariant(body: body, module: first)])
        XCTAssertTrue(store.hasObject(entry.entry))

        let again = try store.putLibraryEntries(module: second, rev: 4, by: "agent", proposals: [proposal("SetMem")])
        XCTAssertEqual(again.unchanged.map(\.name), ["SetMem"], "the same review from another module is the same entry")
        XCTAssertTrue(again.conflicts.isEmpty)
        XCTAssertEqual(try store.libraryIndex(), index)
    }

    func testTheHoldingModuleImprovesItsEntry() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        let result = try store.putLibraryEntries(module: first, rev: 34, by: "agent",
                                                 proposals: [proposal("SetMem", plate: "better")])
        XCTAssertEqual(result.updated.map(\.version), [2])
        let history = try XCTUnwrap(try store.libraryHistory(id: body.key))
        XCTAssertEqual(history.versions.map(\.version), [1, 2])
        XCTAssertEqual(history.versions.last?.source.rev, 34)
        XCTAssertNil(history.versions.last?.reason)
    }

    /// Another module's different review — here another name for the same
    /// body — is a conflict, not a second entry; taking it needs a reason.
    func testAnotherModulesReviewIsAConflictTakenOnlyWithAReason() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        let refused = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                                  proposals: [proposal("FillBytes")])
        XCTAssertEqual(refused.conflicts.count, 1)
        XCTAssertEqual(refused.conflicts.first?.name, "SetMem")
        XCTAssertEqual(refused.conflicts.first?.proposedName, "FillBytes")
        XCTAssertEqual(refused.conflicts.first?.heldBy.module, first)
        XCTAssertEqual(try store.libraryIndex().entries.count, 1, "one body, one entry")

        XCTAssertThrowsError(try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                                         proposals: [proposal("FillBytes")], take: true))
        let taken = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                                proposals: [proposal("FillBytes")], take: true,
                                                reason: "the review of the Renoir module is the better one")
        XCTAssertEqual(taken.updated.map(\.name), ["FillBytes"])
        let entry = try XCTUnwrap(try store.libraryIndex().entry(for: body)?.entry)
        XCTAssertEqual(entry.name, "FillBytes")
        XCTAssertEqual(entry.source.module, second)
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason,
                       "the review of the Renoir module is the better one")
    }

    func testABadBodyOrKindIsRefused() {
        let bad = LibraryBody(size: 0x15, full: "not-a-hash", specific: "0123456789abcdef")
        XCTAssertThrowsError(try store.putLibraryEntries(module: first, rev: 1, by: nil,
                                                         proposals: [proposal("X", body: bad)]))
        XCTAssertThrowsError(try store.putLibraryEntries(module: first, rev: 1, by: nil,
                                                         proposals: [proposal("X", kind: "arm")]))
    }

    func testCollectionKeepsEveryVersion() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        try store.putLibraryEntries(module: first, rev: 34, by: "agent", proposals: [proposal("SetMem", plate: "v2")])
        let versions = try XCTUnwrap(try store.libraryHistory(id: body.key)).versions.map(\.entry)
        _ = try store.collectGarbage(dryRun: false)
        for object in versions { XCTAssertTrue(store.hasObject(object)) }
    }

    func testAMirrorTakesTheServedIndex() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        let served = try store.libraryIndex()
        let mirrorRoot = directory.appendingPathComponent("mirror", isDirectory: true)
        let mirror = try ContentStore(root: mirrorRoot)
        try mirror.mirrorLibrary(served)
        XCTAssertEqual(try mirror.libraryIndex(), served)
    }
}
