import Foundation
import XCTest
@testable import CodeAnalysis

/// A library function has one description: a reader gets it from the registry
/// entry, whatever the module's own project still holds, and what is the
/// module's stays the module's.
final class LibraryViewTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let source = SHA256Digest(data: Data("source".utf8))
    private let body = LibraryBody(size: 0x15, full: "00112233445566aa", specific: "0123456789abcdef")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryViewTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
        var index = try store.libraryIndex()
        index.readThrough = true
        try store.mirrorLibrary(index)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The entry's function: at 0x1000, it calls 0x2000, printed `Theirs`.
    private func entryObject(plate: String = "EDK2 CopyMem") throws -> Data {
        let c = "void CopyMem(void) {\n  Theirs(Count);\n}\n"
        let at = (c as NSString).range(of: "Theirs").location
        let local = (c as NSString).range(of: "Count").location
        let function: [String: Any] = [
            "entry": "0x1000", "name": "CopyMem", "signature": "void CopyMem(void)", "c": c,
            "c_spans": [[at, 6, "function", "0x2000"], [local, 5, "local"]],
            "c_sites": [[at, 6, "0x1004"]],
            "instructions": [
                ["address": "0x1000", "bytes": "90", "text": "NOP"],
                ["address": "0x1004", "bytes": "e8", "text": "CALL 0x2000",
                 "references": [["to": "0x2000", "type": "UNCONDITIONAL_CALL"]]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: [
            "schema": 1, "name": "CopyMem", "kind": "edk2", "plate": plate,
            "signature": "void CopyMem(void)", "function": function
        ], options: .sortedKeys)
    }

    private func register(_ object: Data) throws {
        _ = try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1000", entry: object)
        ])
    }

    /// The module's own copy: another name, other C, other addresses.
    private func moduleArtifact(pending: Bool = false, bodyKey: String? = nil) throws -> CodeArtifact {
        var function: [String: Any] = [
            "entry": "0x9000", "name": "OwnName", "signature": "int OwnName(int param_1)",
            "review_level": "full", "review_gaps": ["plate"],
            "callers": ["0x9500"]
        ]
        if let key = bodyKey ?? Optional(body.key) { function["body"] = key }
        if pending {
            function["fingerprint"] = "pending"
        } else {
            function["c"] = "int OwnName(int param_1) { MyCallee(); uVar1 = 1; }"
            function["instructions"] = [
                ["address": "0x9000", "bytes": "90", "text": "NOP"],
                ["address": "0x9004", "bytes": "e8", "text": "CALL 0xA000",
                 "references": [["to": "0xA000", "type": "UNCONDITIONAL_CALL"]]]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "script_version": 10, "ghidra": "12.2", "functions": [
                function, ["entry": "0xA000", "name": "MyCallee"]
            ]
        ])
        return try JSONDecoder().decode(CodeArtifact.self, from: data)
    }

    func testAFunctionReadsAsItsEntryAndWhatIsTheModulesStays() throws {
        try register(try entryObject())
        let read = store.throughRegistry(try moduleArtifact()).functions[0]
        XCTAssertEqual(read.name, "CopyMem")
        XCTAssertEqual(read.signature, "void CopyMem(void)")
        XCTAssertEqual(read.reviewLevel, .library)
        XCTAssertEqual(read.reviewGaps, [])
        XCTAssertEqual(read.libraryKind, .edk2)
        XCTAssertEqual(read.libraryEntry?.id, body.key)
        XCTAssertEqual(read.libraryEntry?.isEntry, true)
        XCTAssertFalse(read.c?.contains("uVar1") ?? true, "nothing of the module's copy shows")
        // Its place stays this module's.
        XCTAssertEqual(read.entry, CodeAddress(0x9000))
        XCTAssertEqual(read.callers, [CodeAddress(0x9500)])
        XCTAssertEqual(read.instructions.first?.address, CodeAddress(0x9000))
    }

    /// What the C names is this module's: the callee's name and address, by
    /// the reference of the same instruction, and every position follows.
    func testTheEntrysCOfACalleeIsTheModules() throws {
        try register(try entryObject())
        let read = store.throughRegistry(try moduleArtifact()).functions[0]
        let c = try XCTUnwrap(read.c)
        XCTAssertTrue(c.contains("MyCallee(Count)"), c)
        XCTAssertFalse(c.contains("Theirs"), c)
        let span = try XCTUnwrap(read.cSpans.first { $0.kind == .function })
        XCTAssertEqual(span.target, CodeAddress(0xA000))
        let units = Array(c.utf16)
        func text(_ start: Int, _ length: Int) -> String {
            String(decoding: units[start..<(start + length)], as: UTF16.self)
        }
        XCTAssertEqual(text(span.start, span.length), "MyCallee")
        let local = try XCTUnwrap(read.cSpans.first { $0.kind == .local })
        XCTAssertEqual(text(local.start, local.length), "Count", "a span after the rename follows it")
        XCTAssertEqual(read.cSites.first?.address, CodeAddress(0x9004))
    }

    /// A callee that is in the registry prints the registry's name.
    func testACallerPrintsTheEntrysNameOfItsCallee() throws {
        try register(try entryObject())
        let data = try JSONSerialization.data(withJSONObject: [
            "script_version": 10, "ghidra": "12.2", "functions": [
                ["entry": "0x9000", "name": "OwnName", "body": body.key]
            ]
        ])
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: data)
        XCTAssertEqual(store.throughRegistry(artifact).functions[0].name, "CopyMem")
    }

    /// A function shown from the index has no code yet: it still reads as the
    /// entry, and its code stays to be read.
    func testAFunctionWithItsCodePendingTakesTheNameOnly() throws {
        try register(try entryObject())
        let read = store.throughRegistry(try moduleArtifact(pending: true)).functions[0]
        XCTAssertEqual(read.name, "CopyMem")
        XCTAssertNil(read.c)
        XCTAssertTrue(read.codeIsPending)
    }

    func testAFunctionTheRegistryDoesNotHoldStaysAsPublished() throws {
        try register(try entryObject())
        let read = store.throughRegistry(try moduleArtifact(bodyKey: "15-ffffffffffffffff-0000000000000000")).functions[0]
        XCTAssertEqual(read.name, "OwnName")
        XCTAssertEqual(read.reviewLevel, .full)
    }

    /// An entry from before entries held the function: its name and signature
    /// are the registry's, and the C stays until the entry is completed.
    func testAnEntryWithoutItsFunctionGivesWhatItHas() throws {
        let object = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "name": "CopyMem", "kind": "edk2", "signature": "void CopyMem(void)"
        ], options: .sortedKeys)
        try register(object)
        let read = store.throughRegistry(try moduleArtifact()).functions[0]
        XCTAssertEqual(read.name, "CopyMem")
        XCTAssertEqual(read.signature, "void CopyMem(void)")
        XCTAssertEqual(read.c, "int OwnName(int param_1) { MyCallee(); uVar1 = 1; }")
    }

    /// Another module's C of the same review is no new version; the same
    /// review completes an entry that lacks its function, and a different one
    /// stays a conflict.
    func testTheFunctionIsNotPartOfTheReview() throws {
        let bare = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": "CopyMem", "kind": "edk2",
                                                               "plate": "EDK2 CopyMem",
                                                               "signature": "void CopyMem(void)"], options: .sortedKeys)
        try register(bare)
        XCTAssertTrue(LibraryProposal.sameReview(bare, try entryObject()))
        let other = SHA256Digest(data: Data("other".utf8))
        let differing = try store.putLibraryEntries(module: other, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1", entry: try entryObject(plate: "Mine"))
        ])
        XCTAssertEqual(differing.conflicts.map(\.id), [body.key])
        let completed = try store.putLibraryEntries(module: other, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1", entry: try entryObject())
        ])
        XCTAssertEqual(completed.updated.first?.version, 1, "the C recorded is no new version of the review")
        let (_, held) = try XCTUnwrap(try store.libraryIndex().entry(for: body))
        XCTAssertTrue(LibraryProposal.hasFunction(try store.object(held.entry)))
        // Who wrote the review stays who wrote it; the C says where it came from.
        XCTAssertEqual(held.source.module, source, "recording the C does not change the review's author")
        let recorded = try JSONSerialization.jsonObject(with: try store.object(held.entry)) as? [String: Any]
        let origin = (recorded?["function"] as? [String: Any])?["source"] as? [String: Any]
        XCTAssertEqual(origin?["module"] as? String, other.hex)
        XCTAssertEqual(origin?["address"] as? String, "0x1")
        let last = try XCTUnwrap(try store.libraryHistory(id: body.key)?.versions.last)
        XCTAssertEqual(last.source.module, source)
        XCTAssertTrue(last.reason?.contains(other.hex) == true, "\(last.reason ?? "")")
        let again = try store.putLibraryEntries(module: source, rev: 2, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x2", entry: try entryObject())
        ])
        XCTAssertEqual(again.updated.count, 0)
    }

    /// A name is one library function's: a different body under it is refused
    /// and told who holds it; the entry itself may keep its name, and the
    /// module's own function is none of the registry's business.
    func testADifferentBodyCannotTakeALibraryFunctionsName() throws {
        try register(try entryObject())
        let other = LibraryBody(size: 0x13, full: "ffeeddccbbaa9988", specific: "7766554433221100")
        func offer(_ name: String) throws -> LibraryWriteResult {
            let object = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": name, "kind": "edk2"], options: .sortedKeys)
            return try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
                LibraryProposal(body: other, name: name, kind: "edk2", address: "0x3000", entry: object)
            ])
        }
        let refused = try offer("CopyMem")
        XCTAssertEqual(refused.added.count, 0)
        XCTAssertEqual(refused.nameConflicts?.map(\.heldBy), [body.key])
        XCTAssertEqual(try store.libraryIndex().entries.count, 1)
        XCTAssertEqual(try offer("CopyMemForward").added.map(\.name), ["CopyMemForward"])
        // Renaming an entry onto another's name is refused too.
        let renamed = try store.putLibraryEntries(module: source, rev: 2, by: "agent", proposals: [
            LibraryProposal(body: other, name: "CopyMem", kind: "edk2", address: "0x3000",
                            entry: try JSONSerialization.data(withJSONObject: ["schema": 1, "name": "CopyMem", "kind": "edk2"], options: .sortedKeys),
                            basedOn: other.key, base: 1)
        ])
        XCTAssertEqual(renamed.nameConflicts?.count, 1)
        XCTAssertEqual(try store.libraryIndex().entries[other.key]?.name, "CopyMemForward")
    }

    /// A name goes by what the functions mean: the entry holding one too wide
    /// gives it up, and a later function may take it or a narrower one.
    func testAnEntryWithAWideNameCanGiveItUp() throws {
        try register(try entryObject())
        XCTAssertThrowsError(try store.renameLibraryEntry(id: body.key, name: "CopyMemForward", reason: " ", by: "agent"))
        let preview = try store.renameLibraryEntry(id: body.key, name: "CopyMemForward", reason: "copies forward only",
                                                   by: "agent", dryRun: true)
        XCTAssertEqual(preview.version, 2)
        XCTAssertEqual(try store.libraryIndex().entries[body.key]?.name, "CopyMem")
        try store.renameLibraryEntry(id: body.key, name: "CopyMemForward", reason: "copies forward only", by: "agent")
        let index = try store.libraryIndex()
        XCTAssertEqual(index.entries[body.key]?.name, "CopyMemForward")
        XCTAssertEqual(index.entries[body.key]?.version, 2)
        let history = try XCTUnwrap(try store.libraryHistory(id: body.key))
        XCTAssertEqual(history.versions.last?.reason, "copies forward only (was CopyMem)")
        let read = store.throughRegistry(try moduleArtifact()).functions[0]
        XCTAssertEqual(read.name, "CopyMemForward")
        XCTAssertEqual(read.signature, "void CopyMemForward(void)")

        // The name is free again, for a function the review finds it fits.
        let other = LibraryBody(size: 0x13, full: "ffeeddccbbaa9988", specific: "7766554433221100")
        let object = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": "CopyMem", "kind": "edk2"], options: .sortedKeys)
        let taken = try store.putLibraryEntries(module: source, rev: 2, by: "agent", proposals: [
            LibraryProposal(body: other, name: "CopyMem", kind: "edk2", address: "0x3000", entry: object)
        ])
        XCTAssertEqual(taken.added.map(\.name), ["CopyMem"])
        // And a rename onto a name another entry holds says which.
        XCTAssertThrowsError(try store.renameLibraryEntry(id: body.key, name: "CopyMem", reason: "x", by: "agent"))
    }

    private func offerBody(_ key: LibraryBody, _ name: String, data: [String]? = nil,
                           callees: [LibraryCallee]? = nil) throws -> LibraryWriteResult {
        let object = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": name, "kind": "edk2"], options: .sortedKeys)
        return try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: key, name: name, kind: "edk2", address: "0x3000", entry: object,
                            dataReferences: data, callees: callees)
        ])
    }

    /// The approved rule at the door: a new body with a data reference needs a
    /// citation, and a new body's callees must all be in the registry already.
    func testABodyThatDependsOnAModuleIsNotTaken() throws {
        let leaf = LibraryBody(size: 0x13, full: "ffeeddccbbaa9988", specific: "7766554433221100")
        let refusedData = try offerBody(leaf, "ReadsData", data: ["0x4"])
        XCTAssertEqual(refusedData.notLibrary?.map(\.why), ["data"])
        XCTAssertEqual(refusedData.notLibrary?.first?.data, ["0x4"])
        XCTAssertEqual(try store.libraryIndex().entries.count, 0)

        try store.changeLibrary(.init(action: .cite, body: leaf.key, file: "MdePkg/Foo.c", line: 12), by: "agent")
        XCTAssertEqual(try offerBody(leaf, "ReadsData", data: ["0x4"]).added.count, 1)

        let caller = LibraryBody(size: 0x20, full: "aaeeddccbbaa9988", specific: "1166554433221100")
        let unknown = LibraryBody(size: 0x21, full: "bbeeddccbbaa9988", specific: "2266554433221100")
        let refusedCall = try offerBody(caller, "Caller", callees: [LibraryCallee(name: "Local", body: unknown.key)])
        XCTAssertEqual(refusedCall.notLibrary?.map(\.why), ["callee"])
        XCTAssertEqual(refusedCall.notLibrary?.first?.callees, ["Local"])
        let unhashed = try offerBody(caller, "Caller", callees: [LibraryCallee(name: "Tiny", body: nil)])
        XCTAssertEqual(unhashed.notLibrary?.map(\.why), ["callee"])
        let taken = try offerBody(caller, "Caller", callees: [LibraryCallee(name: "ReadsData", body: leaf.key),
                                                              LibraryCallee(name: "Caller", body: caller.key)])
        XCTAssertEqual(taken.added.map(\.name), ["Caller"])
    }

    /// Taken out: gone from the index, its name free, refused at the next
    /// offer, its text kept for its modules, and the decision can be undone.
    func testATakenOutEntryStaysOutAndCanComeBack() throws {
        try register(try entryObject())
        XCTAssertEqual(try store.changeLibrary(.init(action: .takeOut, id: body.key, reason: "x"), by: "agent",
                                               dryRun: true).takenOut?.count, 1)
        XCTAssertNotNil(try store.libraryIndex().entries[body.key])
        XCTAssertThrowsError(try store.changeLibrary(.init(action: .takeOut, id: body.key), by: "agent"))

        try store.changeLibrary(.init(action: .takeOut, id: body.key, reason: "the GUID is the module's"), by: "agent")
        let index = try store.libraryIndex()
        XCTAssertNil(index.entries[body.key])
        XCTAssertNil(index.bodies[body.key])
        let out = try XCTUnwrap(index.takenOut?[body.key])
        XCTAssertEqual(out.name, "CopyMem")
        XCTAssertNoThrow(try store.object(out.entry))
        XCTAssertTrue(store.libraryObjects().contains(out.entry), "a collection must not lose its text")
        XCTAssertEqual(try store.libraryHistory(id: body.key)?.versions.last?.reason,
                       "taken out: the GUID is the module's")

        let offered = try offerBody(body, "CopyMem")
        XCTAssertEqual(offered.notLibrary?.map(\.why), ["taken_out"])
        XCTAssertEqual(offered.added.count, 0)
        let read = store.throughRegistry(try moduleArtifact()).functions[0]
        XCTAssertNotEqual(read.reviewLevel, .library)

        try store.changeLibrary(.init(action: .restore, body: body.key, reason: "wrong"), by: "agent")
        let back = try store.libraryIndex()
        XCTAssertEqual(back.bodies[body.key], body.key)
        XCTAssertEqual(back.takenOut?[body.key], nil)
        XCTAssertEqual(back.entries[body.key]?.version, out.version + 1)
    }

    /// One body of a two-body entry leaves; the entry and its other body stay.
    func testOneBodyOfAnEntryCanBeTakenOutOrSplitOff() throws {
        let second = LibraryBody(size: 0x15, full: "00112233445566aa", specific: "aaaaaaaaaaaaaaaa")
        let third = LibraryBody(size: 0x15, full: "00112233445566aa", specific: "bbbbbbbbbbbbbbbb")
        try register(try entryObject())
        var index = try store.libraryIndex()
        for extra in [second, third] {
            index.entries[body.key]?.variants.append(LibraryVariant(body: extra, module: source))
            index.bodies[extra.key] = body.key
        }
        try store.mirrorLibrary(index)

        try store.changeLibrary(.init(action: .takeOut, id: body.key, body: second.key, reason: "x"), by: "agent")
        index = try store.libraryIndex()
        XCTAssertEqual(index.entries[body.key]?.variants.map(\.body), [body, third])
        XCTAssertEqual(index.takenOut?.keys.sorted(), [second.key])

        // The body the entry is keyed by, the name already held: refused.
        XCTAssertThrowsError(try store.changeLibrary(.init(action: .split, id: body.key, body: body.key, name: "A", reason: "x"), by: "agent"))
        XCTAssertThrowsError(try store.changeLibrary(.init(action: .split, id: body.key, body: third.key, name: "CopyMem", reason: "x"), by: "agent"))

        let split = try store.changeLibrary(.init(action: .split, id: body.key, body: third.key, name: "CopyMemNarrow", reason: "y"), by: "agent")
        XCTAssertEqual(split.added.map(\.id), [third.key])
        index = try store.libraryIndex()
        XCTAssertEqual(index.entries[body.key]?.variants.map(\.body), [body])
        XCTAssertEqual(index.bodies[third.key], third.key)
        XCTAssertEqual(index.entries[third.key]?.name, "CopyMemNarrow")
        let review = try JSONSerialization.jsonObject(with: try store.object(try XCTUnwrap(index.entries[third.key]).entry)) as? [String: Any]
        XCTAssertEqual(review?["name"] as? String, "CopyMemNarrow")
        XCTAssertEqual(try store.libraryHistory(id: third.key)?.versions.first?.reason,
                       "split from \(body.key) (CopyMem): y")
    }

    /// Off, the default: readers see what the module published.
    func testReadThroughIsOffUntilTurnedOn() throws {
        try register(try entryObject())
        try store.changeLibrary(.init(action: .readThrough, on: false), by: "agent")
        XCTAssertNotEqual(store.throughRegistry(try moduleArtifact()).functions[0].reviewLevel, .library)
        try store.changeLibrary(.init(action: .readThrough, on: true), by: "agent")
        XCTAssertEqual(store.throughRegistry(try moduleArtifact()).functions[0].reviewLevel, .library)
        XCTAssertNil(LibraryIndex().readThrough)
    }

    /// Recording the C brings nothing else of the module that offers it: the
    /// constants the entry holds stay, whatever that module reads.
    func testRecordingTheFunctionChangesNothingElse() throws {
        let held = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "name": "CopyMem", "kind": "edk2", "plate": "EDK2 CopyMem",
            "signature": "void CopyMem(void)", "constants": [["offset": "0x1", "operand": 1, "value": "0x10"]]
        ], options: .sortedKeys)
        try register(held)
        var offered = try XCTUnwrap(try JSONSerialization.jsonObject(with: try entryObject()) as? [String: Any])
        offered["constants"] = [[String: Any]]()
        let data = try JSONSerialization.data(withJSONObject: offered, options: .sortedKeys)
        XCTAssertEqual(try store.putLibraryEntries(module: source, rev: 2, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x2", entry: data)
        ]).updated.count, 1)
        let (_, entry) = try XCTUnwrap(try store.libraryIndex().entry(for: body))
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: try store.object(entry.entry)) as? [String: Any])
        XCTAssertEqual((now["constants"] as? [Any])?.count, 1)
        XCTAssertNotNil(now["function"])
    }
}
