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
                                                         proposals: [proposal("FillBytes")], take: .all("")))
        let taken = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                                proposals: [proposal("FillBytes")],
                                                take: .all("the review of the Renoir module is the better one"))
        XCTAssertEqual(taken.updated.map(\.name), ["FillBytes"])
        let entry = try XCTUnwrap(try store.libraryIndex().entry(for: body)?.entry)
        XCTAssertEqual(entry.name, "FillBytes")
        XCTAssertEqual(entry.source.module, second)
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason,
                       "the review of the Renoir module is the better one")
    }

    /// A publish decides entry by entry: those it names are taken, each with
    /// its own reason in the history, and the rest stay conflicts — one write,
    /// no second apply.
    func testAConflictIsTakenByNameAndTheRestStayConflicts() throws {
        let other = LibraryBody(size: 0x15, full: "aaaabbbbccccdddd", specific: "0123456789abcdef")
        try store.putLibraryEntries(module: first, rev: 1, by: "agent", proposals: [
            proposal("SetMem"), proposal("CopyMem", body: other)
        ])
        let taken = try store.putLibraryEntries(module: second, rev: 5, by: "agent", proposals: [
            proposal("SetMemRenoir", plate: "ours"), proposal("CopyMemRenoir", plate: "ours", body: other)
        ], take: .these([
            body.key: "the Renoir review types the descriptor",
            other.key: "the Renoir review names both locals"
        ]))
        XCTAssertEqual(Set(taken.updated.map(\.id)), [body.key, other.key])
        XCTAssertTrue(taken.conflicts.isEmpty)
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason,
                       "the Renoir review types the descriptor")
        XCTAssertEqual(try store.libraryHistory(id: other.key)?.versions.last?.reason,
                       "the Renoir review names both locals")

        // A third module's review: one entry named, the other left as it was.
        let third = SHA256Digest(data: Data("PcdPeim".utf8))
        let partial = try store.putLibraryEntries(module: third, rev: 2, by: "agent", proposals: [
            proposal("SetMemThird", plate: "third"), proposal("CopyMemThird", plate: "third", body: other)
        ], take: .these([body.key: "the third module's review is the typed one"]))
        XCTAssertEqual(partial.updated.map(\.id), [body.key])
        XCTAssertEqual(partial.conflicts.map(\.id), [other.key], "the entry not named keeps its own version")
        XCTAssertEqual(partial.conflicts.first?.heldBy.module, second)
        XCTAssertEqual(partial.conflicts.first?.version, 2)
    }

    /// A decision that names an entry this publish leaves alone — the same
    /// review, one already settled — is refused, not passed in silence; and a
    /// variant's conflict cannot be made the entry's review.
    func testATakeOfAnEntryThatIsNotInConflictIsRefused() throws {
        let other = LibraryBody(size: 0x15, full: "aaaabbbbccccdddd", specific: "0123456789abcdef")
        try store.putLibraryEntries(module: first, rev: 1, by: "agent", proposals: [proposal("SetMem")])
        // The same review: unchanged, and naming it takes nothing.
        XCTAssertThrowsError(try store.putLibraryEntries(module: second, rev: 1, by: "agent",
                                                         proposals: [proposal("SetMem")],
                                                         take: .these([body.key: "taken anyway"]))) {
            XCTAssertEqual("\($0)", "the entry \(self.body.key) is not in conflict in this publish: "
                + "SetMem is at version 1, and its review is the entry's own, at version 1")
        }

        // A variant's review is the entry's only when it is the same review:
        // a differing one cannot be made the entry's next version.
        try store.putLibraryEntries(module: first, rev: 1, by: "agent",
                                    proposals: [review("ReadSmn", body: body, constants: ["0x10196"])])
        let variantConflict = try store.putLibraryEntries(module: second, rev: 1, by: "agent", proposals: [
            review("ReadSmnOther", body: other, constants: ["0x10199"], variantOf: body.key)])
        XCTAssertEqual(variantConflict.conflicts.map(\.id), [body.key])
        XCTAssertThrowsError(try store.putLibraryEntries(module: second, rev: 2, by: "agent", proposals: [
            review("ReadSmnOther", body: other, constants: ["0x10199"], variantOf: body.key)],
            take: .these([body.key: "the newer review wins"]))) {
            XCTAssertTrue("\($0)".contains("is the entry of another body"), "\($0)")
            XCTAssertTrue("\($0)".contains("ReadSmnOther at 0x9A90000"), "names the function: \($0)")
        }
    }

    /// A dry run answers what the write would do and writes nothing — no
    /// object, no index, no history — so a preview can be read before the
    /// publish decides.
    func testADryRunAnswersWhatTheWriteWouldAndWritesNothing() throws {
        try store.putLibraryEntries(module: first, rev: 1, by: "agent", proposals: [proposal("SetMem")])
        let indexBefore = try store.libraryIndex()
        let historyBefore = try store.libraryHistory(id: body.key)
        let copy = LibraryBody(size: 0x10, full: "aaaabbbbccccdddd", specific: "0123456789abcdef")
        func offer() -> [LibraryProposal] {
            [proposal("SetMemRenoir", plate: "ours"),
             proposal("CopyMem", plate: "ours", body: copy),
             proposal("SetMemTyped", plate: "ours", body: LibraryBody(size: 0x30, full: "9999999999999999",
                                                                     specific: "aaaaaaaaaaaaaaaa"))]
        }
        let decision = LibraryTake.these([body.key: "the Renoir review types the length"])
        let dry = try store.putLibraryEntries(module: second, rev: 2, by: "agent", proposals: offer(),
                                              take: decision, dryRun: true)
        XCTAssertEqual(dry.updated.map(\.id), [body.key])
        XCTAssertEqual(dry.added.count, 2)
        XCTAssertEqual(try store.libraryIndex(), indexBefore, "nothing was written")
        XCTAssertEqual(try store.libraryHistory(id: body.key), historyBefore)
        let untaken = try JSONSerialization.data(withJSONObject: ["name": "SetMemTyped", "kind": "edk2",
                                                                  "plate": "ours"], options: .sortedKeys)
        XCTAssertFalse(store.hasObject(SHA256Digest(data: untaken)), "a dry run stores no entry object")

        let wet = try store.putLibraryEntries(module: second, rev: 2, by: "agent", proposals: offer(),
                                              take: decision)
        XCTAssertEqual(dry, wet, "the same answer, written or not")
        XCTAssertNotEqual(try store.libraryIndex(), indexBefore)
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason,
                       "the Renoir review types the length")
    }

    /// A take names entries this publish offers: a typo, or an entry no body
    /// of this publish reaches, is refused rather than silently not taken —
    /// and so is an id with no reason.
    func testATakeOfAnEntryThePublishDoesNotOfferIsRefused() throws {
        try store.putLibraryEntries(module: first, rev: 1, by: "agent", proposals: [proposal("SetMem")])
        XCTAssertThrowsError(try store.putLibraryEntries(module: second, rev: 1, by: "agent",
                                                         proposals: [proposal("CopyMem")],
                                                         take: .these(["not-an-entry": "because"])))
        XCTAssertThrowsError(try store.putLibraryEntries(module: second, rev: 1, by: "agent",
                                                         proposals: [proposal("CopyMem")],
                                                         take: .these([body.key: "  "])))
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


    /// An entry's review is read for what it lacks by the same words a
    /// function's gaps use — so the two can be compared before either is
    /// changed, without Ghidra.
    func testAnEntryReviewsGapsAreReadFromItsObject() throws {
        func entry(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        }
        let complete = try entry([
            "name": "SetMem", "plate": "EDK2 BaseMemoryLib",
            "return_type": "void", "comments": [["offset": "0x0", "kind": "eol", "text": "why"]],
            "params": [["ordinal": 0, "name": "Buffer", "type": "void *"]],
            "locals": [["storage": "Stack[0x4]:4", "first_use": "-0x1", "name": "Index", "type": "UINTN"]]
        ])
        XCTAssertEqual(LibraryEntryReview.gaps(of: complete), [])

        let thin = try entry([
            "name": "FUN_00001000", "plate": "",
            "return_type": "undefined8", "comments": [],
            "params": [["ordinal": 0, "name": "param_1", "type": "undefined4"],
                       ["ordinal": 1, "name": "Count", "type": "UINTN"]],
            "locals": [["storage": "Stack[0x8]:4", "first_use": "-0x1", "name": "local_8",
                        "type": "undefined4"]]
        ])
        XCTAssertEqual(LibraryEntryReview.gaps(of: thin), ["name", "plate", "comments", "params", "locals", "return"])

        let typed = try entry([
            "name": "ReadSmn", "plate": "AGESA", "return_type": "UINT32", "comments": [["offset": "0x0"]],
            "params": [["name": "Address", "type": "UINT32"]],
            "locals": [["name": "UVar1", "type": "UINT32"]]
        ])
        XCTAssertEqual(LibraryEntryReview.gaps(of: typed), ["locals"],
                       "a decompiler's temporary is a local a review did not name")

        let placeholder = try entry([
            "name": "LibAmdIoWrite", "plate": "AGESA", "return_type": "void", "comments": [["offset": "0x0"]],
            "params": [["name": "Port", "type": "undefined4"], ["name": "Value", "type": "UINT8"]], "locals": []
        ])
        XCTAssertEqual(LibraryEntryReview.gaps(of: placeholder), ["params"],
                       "a parameter the review never typed")
        XCTAssertEqual(LibraryEntryReview.gaps(of: Data("not json".utf8)), [])
    }
    /// A published analysis' gaps by entry: what the review recorded, plus a
    /// placeholder return type, so a registry decision reads the same words
    /// the panel shows — and never the listing's unused stack slots.
    func testAnAnalysissGapsAreReadByEntry() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
            {"script_version": 9, "ghidra": "12.1.2", "functions": [
              {"entry": "0x1000", "name": "SetMem", "signature": "void SetMem(void)",
               "review_gaps": ["plate"], "instructions": [{"address": "0x1000", "text": "RET"}]},
              {"entry": "0x2000", "name": "RShiftU64", "signature": "undefined8 RShiftU64(UINT64 A)",
               "instructions": [{"address": "0x2000", "text": "RET"}]}
            ]}
            """.utf8))
        let gaps = artifact.reviewGapsByEntry()
        XCTAssertEqual(gaps["0x1000"], ["plate"])
        XCTAssertEqual(gaps["0x2000"], ["return"], "an undefined return type is the decompiler's")
        XCTAssertNil(gaps["0x3000"])
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
