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

    /// An update says what it changes, in a dry run too: a recorded function
    /// reads apart from a change of the text.
    func testAnUpdateNamesTheFieldsItChanges() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        let text = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                               proposals: [proposal("SetMem", plate: "better", base: 1)], dryRun: true)
        XCTAssertEqual(text.needsReason?.first?.changed, ["plate"])
        let told = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                               proposals: [proposal("SetMem", plate: "better", base: 1)],
                                               take: LibraryTake.none.with(entryReasons: [body.key: "better"]), dryRun: true)
        XCTAssertEqual(told.updated.first?.changed, ["plate"])

        var offered = proposal("SetMem")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: offered.entry) as? [String: Any])
        object["function"] = ["name": "SetMem", "c": "void SetMem(void) {}"]
        offered.entry = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let recorded = try store.putLibraryEntries(module: second, rev: 4, by: "agent", proposals: [offered], dryRun: true)
        XCTAssertEqual(recorded.updated.first?.changed, ["function"])
        XCTAssertEqual(recorded.updated.first?.version, 1)
    }

    /// No module holds an entry: a review made on its current version is the
    /// next version whichever module publishes it — and the module that
    /// published the first, now a version behind, is a conflict like any.
    func testAChangeOnTheCurrentVersionIsTheNextOneFromAnyModule() throws {
        try store.putLibraryEntries(module: first, rev: 33, by: "agent", proposals: [proposal("SetMem")])
        let result = try store.putLibraryEntries(module: second, rev: 4, by: "agent",
                                                 proposals: [proposal("SetMem", plate: "better", base: 1)],
                                                 take: LibraryTake.none.with(entryReasons: [body.key: "a better plate"]))
        XCTAssertEqual(result.updated.map(\.version), [2])
        XCTAssertTrue(result.conflicts.isEmpty)
        let history = try XCTUnwrap(try store.libraryHistory(id: body.key))
        XCTAssertEqual(history.versions.map(\.version), [1, 2])
        XCTAssertEqual(history.versions.last?.source.module, second)
        XCTAssertEqual(history.versions.last?.reason, "a better plate")

        let behind = try store.putLibraryEntries(module: first, rev: 34, by: "agent",
                                                 proposals: [proposal("SetMem", plate: "other", base: 1)])
        XCTAssertEqual(behind.conflicts.map(\.base), [1])
        XCTAssertEqual(behind.conflicts.first?.version, 2)
        XCTAssertEqual(behind.conflicts.first?.heldBy.module, second)
    }

    /// A review not made on the entry — here another name for the same body,
    /// from a function that never carried it — is a conflict, not a second
    /// entry; taking it needs a reason.
    /// A version made on the current one that changes the signature says why,
    /// in the function's own words.
    private func withReasons(_ made: LibraryProposal, name: String?, signature: String?, signed: String? = nil) -> LibraryProposal {
        var made = made
        var object = try! JSONSerialization.jsonObject(with: made.entry) as! [String: Any]
        var function: [String: Any] = [:]
        function["name_reason"] = name
        function["signature_reason"] = signature
        object["function"] = function
        if let signed { object["signature"] = signed }
        made.entry = try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        made.nameReason = name
        made.signatureReason = signature
        return made
    }

    /// A version a review changed says why in the function's own words, and only
    /// words that changed with it: an older reason would read as this change's.
    /// Words the server generated are no reason; a taken conflict keeps its own.
    func testAnEntryMovedWithNoReasonIsRefusedAndNamed() throws {
        let source = SHA256Digest(data: Data("source".utf8)), other = SHA256Digest(data: Data("other".utf8))
        let first = try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
            proposal("SetMem", plate: "p", base: nil)])
        let id = try XCTUnwrap(first.added.first?.id)
        // A first version needs none, and says whose it is.
        XCTAssertEqual(first.added.first?.module, source)
        XCTAssertNil(first.added.first?.reason)
        XCTAssertEqual(try store.putLibraryEntries(module: source, rev: 2, by: "agent", proposals: [
            proposal("SetMem", plate: "p", base: 1)]).unchanged.map(\.id), [id], "an unchanged entry needs none")

        for (module, plate, rev) in [(source, "from the source", 3), (other, "from another holder", 4)] {
            let moved = proposal("SetMem", plate: plate, base: rev - 2)
            let versions = try store.libraryHistory(id: id)?.versions.count
            let index = try store.libraryIndex()

            // The dry run names what the publish would be refused for.
            let dry = try store.putLibraryEntries(module: module, rev: rev, by: "agent", proposals: [moved], dryRun: true)
            XCTAssertEqual(dry.needsReason?.map(\.id), [id])
            XCTAssertEqual(dry.needsReason?.first?.version, rev - 1)
            XCTAssertEqual(dry.needsReason?.first?.module, module)
            XCTAssertTrue(dry.updated.isEmpty)
            let refusal = try XCTUnwrap(dry.reasonRefusal)
            XCTAssertTrue(refusal.contains(id) && refusal.contains("entry_reasons"), refusal)

            // The publish is refused with the same words and writes nothing.
            XCTAssertThrowsError(try store.putLibraryEntries(module: module, rev: rev, by: "agent", proposals: [moved])) {
                XCTAssertTrue("\($0)".contains(refusal), "\($0)")
            }
            XCTAssertEqual(try store.libraryIndex().entries[id]?.version, index.entries[id]?.version)
            XCTAssertEqual(try store.libraryIndex().entries[id]?.entry, index.entries[id]?.entry)
            XCTAssertEqual(try store.libraryHistory(id: id)?.versions.count, versions)

            // A dry run with the reason answers the row the publish will.
            let reason = "why \(plate)"
            let take = LibraryTake.none.with(entryReasons: [id: reason])
            let wouldBe = try store.putLibraryEntries(module: module, rev: rev, by: "agent", proposals: [moved],
                                                      take: take, dryRun: true)
            XCTAssertNil(wouldBe.needsReason)
            let done = try store.putLibraryEntries(module: module, rev: rev, by: "agent", proposals: [moved], take: take)
            XCTAssertNil(done.needsReason)
            XCTAssertEqual(done.updated.map(\.module), [module])
            XCTAssertEqual(done.updated.map(\.reason), [reason])
            XCTAssertEqual(done.updated, wouldBe.updated)

            // The history reads back the module and the reason.
            let last = try XCTUnwrap(try store.libraryHistory(id: id)?.versions.last)
            XCTAssertEqual(last.version, rev - 1)
            XCTAssertEqual(last.source.module, module)
            XCTAssertEqual(last.reason, reason)
        }
    }

    func testTheEntryReasonsCrossTheServedStore() throws {
        let sent = ServedStoreProtocol.PutLibrary(module: first, rev: 1, by: "agent", proposals: [],
                                                  entryReasons: ["a": "why a"])
        let text = try XCTUnwrap(String(data: try JSONEncoder().encode(sent), encoding: .utf8))
        XCTAssertTrue(text.contains("entry_reasons"), text)
        let read = try JSONDecoder().decode(ServedStoreProtocol.PutLibrary.self, from: try JSONEncoder().encode(sent))
        XCTAssertEqual(read.decision, LibraryTake.none.with(entryReasons: ["a": "why a"]))
    }

    func testAReasonIsForAnEntryThePublishMoves() throws {
        let module = SHA256Digest(data: Data("a".utf8))
        let first = try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [
            proposal("SetMem", plate: "p", base: nil)])
        let id = try XCTUnwrap(first.added.first?.id)
        func put(_ plate: String, base: Int?, _ reasons: [String: String]) throws {
            try store.putLibraryEntries(module: module, rev: 2, by: "agent",
                                        proposals: [proposal("SetMem", plate: plate, base: base)],
                                        take: LibraryTake.none.with(entryReasons: reasons))
        }
        XCTAssertThrowsError(try put("p", base: 1, [id: "nothing moves"])) {
            XCTAssertTrue("\($0)".contains("has nothing to apply to"), "\($0)")
        }
        XCTAssertThrowsError(try put("q", base: 1, [id: "  "])) { XCTAssertTrue("\($0)".contains("is empty"), "\($0)") }
        XCTAssertThrowsError(try put("q", base: 1, ["11-none": "typo"])) {
            XCTAssertTrue("\($0)".contains("no proposal in this publish"), "\($0)")
        }
        // A conflict is not moved by a reason: it stays a conflict, and says so.
        XCTAssertThrowsError(try put("q", base: nil, [id: "not a take"])) {
            XCTAssertTrue("\($0)".contains("take_library_conflicts"), "\($0)")
        }
        XCTAssertEqual(try store.libraryIndex().entries[id]?.version, 1)
    }

    func testATakenConflictAndAFunctionsOwnReasonNeedNoOtherReason() throws {
        let module = SHA256Digest(data: Data("a".utf8))
        let first = try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [
            withReasons(proposal("SetMem", plate: "p", base: nil), name: "first name", signature: nil)])
        let id = try XCTUnwrap(first.added.first?.id)
        let named = try store.putLibraryEntries(module: module, rev: 2, by: "agent", proposals: [
            withReasons(proposal("SetMem", plate: "q", base: 1), name: "named for what it does", signature: nil)])
        XCTAssertEqual(named.updated.map(\.reason), ["named for what it does"])
        let taken = try store.putLibraryEntries(module: module, rev: 3, by: "agent",
                                                proposals: [proposal("SetMem", plate: "r", base: nil)],
                                                take: .all("this one is fuller"))
        XCTAssertEqual(taken.updated.map(\.reason), ["this one is fuller"])
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.last?.reason, "this one is fuller")
    }

    func testAChangedVersionTakesAReasonOnlyWhenTheReasonChanged() throws {
        func proposed(_ plate: String, name: String?, signature: String? = nil, signed: String? = nil, base: Int?) -> LibraryProposal {
            withReasons(proposal("SetMem", plate: plate, base: base), name: name, signature: signature, signed: signed)
        }
        let module = SHA256Digest(data: Data("a".utf8))
        let first = try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [
            proposed("p", name: "first name", base: nil)])
        let id = try XCTUnwrap(first.added.first?.id)
        let steps = [
            proposed("q", name: "named for what it does", base: 1),
            proposed("r", name: "named for what it does", base: 2),
            proposed("s", name: "library registry entry \(id)", signature: "no longer a library function: x", base: 3),
            proposed("t", name: "library registry entry \(id) v3", signature: "the byte reaches AL", base: 4),
            proposed("t", name: "library registry entry \(id) v3", signature: "the byte reaches AL", signed: "void SetMem(UINT8 v)", base: 5),
            proposed("t", name: "library registry entry \(id) v3", signature: "takes the width too", signed: "void SetMem(UINT8 v, UINT8 w)", base: 6)
        ]
        // Steps 1, 2 and 4 say nothing new of their own, so each has to be told.
        let told: Set<Int> = [1, 2, 4]
        for (index, step) in steps.enumerated() {
            let asked = try store.putLibraryEntries(module: module, rev: index + 2, by: "agent", proposals: [step], dryRun: true)
            XCTAssertEqual(asked.needsReason?.map(\.id), told.contains(index) ? [id] : nil, "step \(index)")
            let take = told.contains(index) ? LibraryTake.none.with(entryReasons: [id: "told"]) : .none
            try store.putLibraryEntries(module: module, rev: index + 2, by: "agent", proposals: [step], take: take)
        }
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.map(\.reason),
                       [nil, "named for what it does", "told", "told", "the byte reaches AL", "told", "takes the width too"])
        // A conflict taken says why it was taken, whatever the function says.
        let other = SHA256Digest(data: Data("b".utf8))
        try store.putLibraryEntries(module: other, rev: 1, by: "agent", proposals: [
            proposed("other", name: "its own", base: 1)], take: .all("this review is the right one"))
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.last?.reason, "this review is the right one")
    }

    private func printed(_ c: String, base: Int?, address: String = "0x9A91116") -> LibraryProposal {
        var made = proposal("SetMem", plate: "p", address: address, base: base)
        var object = try! JSONSerialization.jsonObject(with: made.entry) as! [String: Any]
        object["function"] = ["name": "SetMem", "c": c, "name_reason": "offered"]
        made.entry = try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return made
    }

    /// The module an entry's C came from prints it anew, and nothing moves but
    /// the text: not the version, not the function's other fields, and the
    /// version before it stays in the history.
    func testTheEntrysModulePrintsItsCAgainWithNoNewVersion() throws {
        let module = SHA256Digest(data: Data("a".utf8))
        let added = try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [
            printed("/* WARNING: Unknown calling convention -- yet parameter storage is locked */\nif (Buffer == (void *)0x0 && H == (EFI_HANDLE)0x0) {\n}", base: nil)])
        let id = try XCTUnwrap(added.added.first?.id)
        let before = try XCTUnwrap(try store.libraryIndex().entries[id]?.entry)
        let new = printed("if (Buffer == NULL && H == NULL) {\n}", base: 1)

        let dry = try store.putLibraryEntries(module: module, rev: 2, by: "agent", proposals: [new], dryRun: true)
        XCTAssertEqual(dry.updated.first?.changed, ["function"])
        XCTAssertEqual(try store.libraryIndex().entries[id]?.entry, before, "a dry run writes nothing")

        let again = try store.putLibraryEntries(module: module, rev: 2, by: "agent", proposals: [new])
        XCTAssertEqual(again.updated.map(\.version), [1])
        XCTAssertEqual(again.updated.first?.changed, ["function"])
        let entry = try XCTUnwrap(try store.libraryIndex().entries[id])
        XCTAssertEqual(entry.version, 1)
        XCTAssertNotEqual(entry.entry, before)
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.map(\.entry).first, before)
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.map(\.version), [1, 1])

        let settled = try store.putLibraryEntries(module: module, rev: 3, by: "agent", proposals: [new])
        XCTAssertEqual(settled.unchanged.map(\.version), [1], "printed once, it is the same")
        XCTAssertTrue(settled.updated.isEmpty)
    }

    /// Another module, another place, or text that differs by more than the
    /// printing leaves the entry's C as it is.
    func testOnlyItsModuleAndOnlyThePrintingChangeAnEntrysC() throws {
        let module = SHA256Digest(data: Data("a".utf8))
        let c = "if (Buffer == (void *)0x0) {\n}"
        let added = try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [printed(c, base: nil)])
        let id = try XCTUnwrap(added.added.first?.id)
        let held = try XCTUnwrap(try store.libraryIndex().entries[id]?.entry)
        let cases: [(SHA256Digest, LibraryProposal)] = [
            (SHA256Digest(data: Data("b".utf8)), printed("if (Buffer == NULL) {\n}", base: 1)),
            (module, printed("if (Buffer == NULL) {\n}", base: 1, address: "0x9A91200")),
            (module, printed("if (Buffer != NULL) {\n}", base: 1)),
            (module, printed("if (Buffer == (void *)0x1) {\n}", base: 1))
        ]
        for (from, offered) in cases {
            let answer = try store.putLibraryEntries(module: from, rev: 2, by: "agent", proposals: [offered])
            XCTAssertTrue(answer.updated.isEmpty, "\(offered.address)")
            XCTAssertEqual(try store.libraryIndex().entries[id]?.entry, held)
        }
    }

    /// An entry that holds no function gives nothing to compare with: no reason.
    func testAnEntryWithNoFunctionTakesNoReasonFromTheFunction() throws {
        let module = SHA256Digest(data: Data("a".utf8))
        let first = try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [proposal("SetMem", plate: "p")])
        let id = try XCTUnwrap(first.added.first?.id)
        var next = proposal("SetMem", plate: "q", base: 1)
        next.nameReason = "named for what it does"
        XCTAssertThrowsError(try store.putLibraryEntries(module: module, rev: 2, by: "agent", proposals: [next]))
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.map(\.reason), [nil])
    }

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
                                    proposals: [review("ReadSmn", body: body, constants: ["0x10196"])],
                                    take: LibraryTake.none.with(entryReasons: [body.key: "reviewed as ReadSmn"]))
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

    /// The same review from a body of another shape — a function cut again
    /// after it took the entry — is other code: a conflict, not a variant.
    func testABodyOfAnotherShapeIsNotAVariant() throws {
        let cut = LibraryBody(size: 8, full: "5b1411038663e4ad", specific: "5b1411038663e4ad")
        try store.putLibraryEntries(module: first, rev: 1, by: "agent",
                                    proposals: [review("ReadSmn", body: body, constants: ["0x10196"])])
        let refused = try store.putLibraryEntries(module: first, rev: 2, by: "agent", proposals: [
            review("ReadSmn", body: cut, constants: ["0x10196"], variantOf: body.key)])
        XCTAssertEqual(refused.conflicts.map(\.id), [body.key])
        XCTAssertNil(refused.variants)
        XCTAssertNil(try store.libraryIndex().entry(for: cut))
    }

    /// An entry can be left with the one body it should have had: new id, the
    /// review's body with it, the other body gone, the history carried over.
    func testAnEntryIsRebodied() throws {
        let cut = LibraryBody(size: 8, full: "5b1411038663e4ad", specific: "5b1411038663e4ad")
        let other = LibraryBody(size: body.size, full: body.full, specific: "fedcba9876543210")
        try store.putLibraryEntries(module: first, rev: 1, by: "agent",
                                    proposals: [review("ReadSmn", body: body, constants: ["0x10196"])])
        try store.putLibraryEntries(module: first, rev: 2, by: "agent", proposals: [
            review("ReadSmn", body: other, constants: ["0x10199"], variantOf: body.key)])

        XCTAssertThrowsError(try store.rebodyLibraryEntry(id: body.key, bodyKey: cut.key, reason: "absent"))
        XCTAssertThrowsError(try store.rebodyLibraryEntry(id: body.key, bodyKey: other.key, reason: " "))
        let before = try store.libraryIndex()
        let preview = try store.rebodyLibraryEntry(id: body.key, bodyKey: other.key, reason: "why", dryRun: true)
        XCTAssertEqual(preview.id, other.key)
        XCTAssertEqual(try store.libraryIndex(), before, "a preview writes nothing")

        try store.rebodyLibraryEntry(id: body.key, bodyKey: other.key, reason: "why")
        let index = try store.libraryIndex()
        XCTAssertNil(index.entries[body.key])
        XCTAssertNil(index.entry(for: body))
        let entry = try XCTUnwrap(index.entries[other.key])
        XCTAssertEqual(entry.version, 2)
        XCTAssertEqual(entry.variants.map(\.body), [other])
        XCTAssertEqual(index.entry(for: other)?.id, other.key)
        let review = try JSONSerialization.jsonObject(with: store.object(entry.entry)) as? [String: Any]
        XCTAssertEqual((review?["body"] as? [String: Any])?["specific"] as? String, other.specific)
        XCTAssertEqual(review?["name"] as? String, "ReadSmn")
        XCTAssertNil(try store.libraryHistory(id: body.key))
        let history = try XCTUnwrap(store.libraryHistory(id: other.key))
        XCTAssertEqual(history.versions.map(\.version), [1, 2])
        XCTAssertEqual(history.versions.last?.reason, "why")
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
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason,
                       "the body's constants recorded from \(second.hex) at 0x9A90000")
        XCTAssertEqual(completed.updated.first?.module, second)
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

        // A register or a value split over registers is the decompiler's
        // piece, as `assess` reads it: not a gap a review left.
        let fragments = try entry([
            "name": "ReadSmn", "plate": "AGESA", "return_type": "UINT32", "comments": [["offset": "0x0"]],
            "params": [["name": "Address", "type": "UINT32"]],
            "locals": [["storage": "ECX:4", "first_use": "0x4", "name": "extraout_EDX", "type": "UINT32"],
                       ["storage": "EDX:4,EAX:4", "first_use": "0x8", "name": "uVar1", "type": "undefined8"],
                       ["storage": "HASH:5f75a4dce4:1", "first_use": "0x6", "name": "in_EAX", "type": "UINT32"]]
        ])
        XCTAssertEqual(LibraryEntryReview.gaps(of: fragments), [])

        let stack = try entry([
            "name": "ReadSmn", "plate": "AGESA", "return_type": "UINT32", "comments": [["offset": "0x0"]],
            "params": [["name": "Address", "type": "UINT32"]],
            "locals": [["storage": "Stack[-0x4]:4", "first_use": "-0x1", "name": "uVar1", "type": "UINT32"]]
        ])
        XCTAssertEqual(LibraryEntryReview.gaps(of: stack), ["locals"],
                       "a stack local the review never named is a gap")

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
                                    proposals: [proposal("SetMem", plate: "v2", base: 1)],
                                    take: LibraryTake.none.with(entryReasons: [body.key: "v2"]))
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

    /// What the C still prints under a placeholder: locals and parameters, each
    /// once, with no word of a comment or a type taken for one; and no gap.
    func testTemporariesAreReadFromTheCAndAreNotAGap() throws {
        let c = "/* uVar9 */ undefined4 f(int param_1) { int uVar1; in_ECX = uVar1 + Named + param_1 + uVar1; }"
        func span(_ text: String, _ kind: String, from: Int = 0) -> [Any] {
            let units = Array(c.utf16), wanted = Array(text.utf16)
            let at = (from...(units.count - wanted.count)).first { Array(units[$0..<($0 + wanted.count)]) == wanted }!
            return [at, wanted.count, kind]
        }
        let spans: [[Any]] = [
            span("uVar9", "comment"), span("undefined4", "type"), span("param_1", "parameter"),
            span("uVar1", "local"), span("in_ECX", "local"), span("Named", "local"),
            span("uVar1", "local", from: c.utf16.count - 8)
        ]
        let function = try JSONSerialization.data(withJSONObject: [
            "script_version": 9, "program": ["image_base": "0x0"],
            "functions": [["entry": "0x10", "name": "F", "c": c, "c_spans": spans,
                           "review_level": "library", "review_gaps": [String](), "instructions": [[String: String]]()],
                          ["entry": "0x20", "name": "NoSpans", "c": "uVar1;", "instructions": [[String: String]]()]]
        ])
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: function)
        XCTAssertEqual(LibraryEntryReview.temporaries(in: artifact.functions[0]), ["param_1", "uVar1", "in_ECX"])
        XCTAssertEqual(LibraryEntryReview.temporaries(in: artifact.functions[1]), [], "no spans, nothing claimed")
        XCTAssertEqual(artifact.functions[0].reviewGaps, [])
    }
}
