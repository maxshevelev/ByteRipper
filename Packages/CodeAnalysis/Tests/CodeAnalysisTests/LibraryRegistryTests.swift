import Foundation
import XCTest
@testable import CodeAnalysis

/// The library registry in the store (`Design/LIBRARY_REGISTRY_PLAN.md`): one
/// entry per body, improved in place by a review made on its current version
/// from any module, a conflict for any other review, taken only with a
/// reason, and every version's object kept by collection.
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
                          body: LibraryBody? = nil, address: String = "0x9A91116", base: Int? = nil) -> LibraryProposal {
        let entry: [String: Any] = ["schema": 1, "name": name, "kind": kind, "plate": plate]
        let data = try! JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
        return LibraryProposal(body: body ?? self.body, name: name, kind: kind, address: address, entry: data,
                               basedOn: base == nil ? nil : (body ?? self.body).key, base: base)
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

    /// No module holds an entry: a review made on its current version is the
    /// next version whichever module publishes it — and the module that
    /// published the first, now a version behind, is a conflict like any.
    func testAChangeOnTheCurrentVersionIsTheNextOneFromAnyModule() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        let result = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                                 proposals: [proposal("SetMem", plate: "better", base: 1)])
        XCTAssertEqual(result.updated.map(\.version), [2])
        XCTAssertTrue(result.conflicts.isEmpty)
        let history = try XCTUnwrap(try store.libraryHistory(id: body.key))
        XCTAssertEqual(history.versions.map(\.version), [1, 2])
        XCTAssertEqual(history.versions.last?.source.module, second)
        XCTAssertNil(history.versions.last?.reason, "a change on the current version needs no reason")

        let behind = try store.putLibraryEntries(module: first, rev: 34, by: "agent",
                                                 proposals: [proposal("SetMem", plate: "other", base: 1)])
        XCTAssertEqual(behind.conflicts.map(\.base), [1])
        XCTAssertEqual(behind.conflicts.first?.version, 2)
        XCTAssertEqual(behind.conflicts.first?.heldBy.module, second)
    }

    /// A review not made on the entry — here another name for the same body,
    /// from a function that never carried it — is a conflict, not a second
    /// entry; taking it needs a reason.
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

    private func review(_ name: String, body: LibraryBody, constants: [String]?, variantOf: String? = nil,
                        codes: [String]? = nil) -> LibraryProposal {
        var entry: [String: Any] = ["schema": 1, "name": name, "kind": "amd", "plate": "AGESA IdsLib",
                                    "body": ["size": body.size, "full": body.full, "specific": body.specific]]
        entry["constants"] = constants
        let data = try! JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
        return LibraryProposal(body: body, name: name, kind: "amd", address: "0x9A90000", entry: data,
                               variantOf: variantOf, codes: codes)
    }

    /// A body applied as a variant joins its entry at the publish: one
    /// review, two bodies, the second with its assert codes — and the same
    /// review offered again from the variant's body is no change.
    func testAVariantJoinsItsEntry() throws {
        let other = LibraryBody(size: 0x15, full: body.full, specific: "fedcba9876543210")
        try store.putLibraryEntries(module: first, rev: 1, by: "agent",
                                    proposals: [review("ReadSmn", body: body, constants: ["0x10196"])])
        let joined = try store.putLibraryEntries(module: second, rev: 1, by: "agent", proposals: [
            review("ReadSmn", body: other, constants: ["0x10199"], variantOf: body.key, codes: ["0x10199"])])
        XCTAssertEqual(joined.variants?.map(\.id), [body.key])
        let index = try store.libraryIndex()
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entry(for: other)?.id, body.key)
        XCTAssertEqual(index.entries[body.key]?.variants.last?.codes, ["0x10199"])
        XCTAssertEqual(index.entries[body.key]?.version, 1, "a variant is not a new version")

        let again = try store.putLibraryEntries(module: second, rev: 2, by: "agent", proposals: [
            review("ReadSmn", body: other, constants: ["0x10199"], variantOf: body.key, codes: ["0x10199"])])
        XCTAssertEqual(again.unchanged.map(\.id), [body.key])
        XCTAssertTrue(again.conflicts.isEmpty)
    }

    /// A variant whose review is not the entry's is a conflict, not a variant.
    func testAVariantWithAnotherReviewIsAConflict() throws {
        let other = LibraryBody(size: 0x15, full: body.full, specific: "fedcba9876543210")
        try store.putLibraryEntries(module: first, rev: 1, by: "agent",
                                    proposals: [review("ReadSmn", body: body, constants: ["0x10196"])])
        let refused = try store.putLibraryEntries(module: second, rev: 1, by: "agent", proposals: [
            review("ReadSmnOther", body: other, constants: ["0x10199"], variantOf: body.key)])
        XCTAssertEqual(refused.conflicts.map(\.proposedName), ["ReadSmnOther"])
        XCTAssertNil(try store.libraryIndex().entry(for: other))
    }

    /// An entry written before entries held their constants takes them from
    /// whichever module offers the same review of its body — the holder's
    /// change in all but name, with a reason the history keeps.
    func testTheConstantsCompleteAnEntryFromAnyModule() throws {
        try store.putLibraryEntries(module: first, rev: 1, by: "agent",
                                    proposals: [review("ReadSmn", body: body, constants: nil)])
        let completed = try store.putLibraryEntries(module: second, rev: 1, by: "agent",
                                                    proposals: [review("ReadSmn", body: body, constants: ["0x1"])])
        XCTAssertEqual(completed.updated.map(\.version), [2])
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason, "the body's constants recorded")
        let same = try store.putLibraryEntries(module: first, rev: 2, by: "agent",
                                               proposals: [review("ReadSmn", body: body, constants: ["0x1"])])
        XCTAssertEqual(same.unchanged.count, 1)
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
        try store.putLibraryEntries(module: first, rev: 34, by: "agent",
                                    proposals: [proposal("SetMem", plate: "v2", base: 1)])
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
