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
        let link = bodyKey == nil
        var function: [String: Any] = [
            "entry": "0x9000", "name": "OwnName", "signature": "int OwnName(int param_1)",
            "review_level": "full", "review_gaps": ["plate"],
            "callers": ["0x9500"]
        ]
        if let key = bodyKey ?? Optional(body.key) { function["body"] = key }
        if link { function["registry"] = body.key }
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
                ["entry": "0x9000", "registry": body.key, "body": body.key]
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
        XCTAssertNil(read.c, "a link has no text of its own to fall back on")
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

    /// A rename reaches the stored C: its own name there, a recursive call, and
    /// every place after them. A comment naming it is the review's and stays.
    func testARenameReachesTheStoredC() throws {
        let c = "/* CopyMem copies */\nvoid CopyMem(void) {\n  CopyMem(Count);\n  Theirs(Count);\n}\n"
        let text = c as NSString
        let own = text.range(of: "void CopyMem").location + 5
        let again = text.range(of: "  CopyMem(").location + 2
        let theirs = text.range(of: "Theirs").location
        let count = text.range(of: "Theirs(Count").location + 7
        let function: [String: Any] = [
            "entry": "0x1000", "name": "CopyMem", "signature": "void CopyMem(void)", "c": c,
            "c_spans": [[0, 20, "comment"], [own, 7, "function", "0x1000"], [again, 7, "function", "0x1000"],
                        [theirs, 6, "function", "0x2000"], [count, 5, "local"]],
            "c_sites": [[again, 7, "0x1000"], [theirs, 6, "0x1004"]],
            "c_fields": [[count, 5, "T", 4]],
            "c_unreachable": [[own, 12, ["0x1008"]]],
            "instructions": [["address": "0x1000", "bytes": "90", "text": "NOP"]]
        ]
        try register(try JSONSerialization.data(withJSONObject: [
            "schema": 1, "name": "CopyMem", "kind": "edk2", "plate": "EDK2 CopyMem",
            "signature": "void CopyMem(void)", "function": function
        ], options: .sortedKeys))
        try store.renameLibraryEntry(id: body.key, name: "CopyMemForwardOnly", reason: "copies forward only", by: "agent")
        let entry = try XCTUnwrap(try store.libraryIndex().entries[body.key])
        let review = try XCTUnwrap(try JSONSerialization.jsonObject(with: try store.object(entry.entry)) as? [String: Any])
        let stored = try XCTUnwrap(review["function"] as? [String: Any])
        let now = try XCTUnwrap(stored["c"] as? String) as NSString
        XCTAssertEqual(now, "/* CopyMem copies */\nvoid CopyMemForwardOnly(void) {\n  CopyMemForwardOnly(Count);\n  Theirs(Count);\n}\n")
        func token(_ row: [Any]) -> String { now.substring(with: NSRange(location: row[0] as! Int, length: row[1] as! Int)) }
        let spans = try XCTUnwrap(stored["c_spans"] as? [[Any]])
        XCTAssertEqual(spans.map(token), ["/* CopyMem copies */", "CopyMemForwardOnly", "CopyMemForwardOnly", "Theirs", "Count"])
        XCTAssertEqual(try XCTUnwrap(stored["c_sites"] as? [[Any]]).map(token), ["CopyMemForwardOnly", "Theirs"])
        XCTAssertEqual(try XCTUnwrap(stored["c_fields"] as? [[Any]]).map(token), ["Count"])
        XCTAssertEqual(try XCTUnwrap(stored["c_unreachable"] as? [[Any]]).map(token), ["CopyMemForwardOnly(void"])
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

    /// A body with two constants holds two citations; the same file and line
    /// replaces, removing takes one away, and what went is kept with who did it.
    func testABodyHoldsSeveralCitationsAndKeepsWhatWasReplaced() throws {
        let body = LibraryBody(size: 0xd, full: "ffeeddccbbaa9988", specific: "7766554433221100")
        func cite(_ line: Int, note: String? = nil, remove: Bool? = nil, dryRun: Bool = false) throws -> LibraryCitationResult? {
            try store.changeLibrary(.init(action: .cite, body: body.key, reason: note, file: "Fpu.nasm", line: line, remove: remove),
                                    by: "agent", dryRun: dryRun).citations?.first
        }
        XCTAssertEqual(try cite(15, note: "first")?.action, "added")
        XCTAssertEqual(try cite(20, dryRun: true)?.action, "added")
        XCTAssertEqual(try store.libraryIndex().sources?[body.key]?.all.map(\.line), [15], "a dry run wrote nothing")
        XCTAssertEqual(try cite(20)?.action, "added")
        XCTAssertEqual(try store.libraryIndex().sources?[body.key]?.all.map(\.line), [15, 20])

        let replaced = try cite(15, note: "second")
        XCTAssertEqual(replaced?.action, "replaced")
        XCTAssertEqual(replaced?.old?.note, "first")
        XCTAssertEqual(try store.libraryIndex().sources?[body.key]?.all.map(\.note), ["second", nil])

        XCTAssertEqual(try cite(15, remove: true)?.action, "removed")
        XCTAssertEqual(try store.libraryIndex().sources?[body.key]?.all.map(\.line), [20])
        XCTAssertThrowsError(try cite(15, remove: true), "no such citation")
        XCTAssertEqual(try cite(20, remove: true)?.action, "removed")
        XCTAssertNil(try store.libraryIndex().sources?[body.key], "none left")
        XCTAssertEqual(try store.libraryIndex().sourceChanges?[body.key]?.map(\.action), ["replaced", "removed", "removed"])
        XCTAssertEqual(try store.libraryIndex().sourceChanges?[body.key]?.first?.old.note, "first")
    }

    /// An index written with one citation per body reads as it was, and one
    /// with several still reads where a citation is one object.
    func testACitationKeepsItsOldForm() throws {
        let old = #"{"file":"a.c","line":3,"at":"t"}"#
        let read = try JSONDecoder().decode(LibraryCitation.self, from: Data(old.utf8))
        XCTAssertEqual(read.all.map(\.line), [3])
        struct Earlier: Decodable { var file: String; var line: Int }
        let two = LibraryCitation(file: "a.c", line: 3, note: nil, by: nil, at: "t",
                                  also: [LibraryCitation(file: "a.c", line: 4, note: nil, by: nil, at: "t", also: nil)])
        XCTAssertEqual(try JSONDecoder().decode(Earlier.self, from: JSONEncoder().encode(two)).line, 3)
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

    /// A take-out's reason found wrong is corrected: the body stays out, at its
    /// version, and history keeps what it said.
    func testATakeOutReasonIsCorrectedAndHistoryKeepsTheOldOne() throws {
        try register(try entryObject())
        let (id, _) = try XCTUnwrap(try store.libraryIndex().entry(for: body))
        try store.changeLibrary(.init(action: .takeOut, id: id, reason: "three over fourteen"), by: "agent")
        let version = try XCTUnwrap(store.libraryIndex().takenOut?[body.key]?.version)
        let rows = try XCTUnwrap(store.libraryHistory(id: id)).versions.count

        try store.changeLibrary(.init(action: .takeOut, id: id, reason: "two groups over four"), by: "agent", dryRun: true)
        XCTAssertEqual(try store.libraryIndex().takenOut?[body.key]?.reason, "three over fourteen", "a dry run writes nothing")

        let result = try store.changeLibrary(.init(action: .takeOut, id: id, reason: "two groups over four"), by: "agent")
        XCTAssertEqual(result.takenOut?.map(\.id), [id])
        let out = try XCTUnwrap(store.libraryIndex().takenOut?[body.key])
        XCTAssertEqual(out.reason, "two groups over four")
        XCTAssertEqual(out.version, version)
        XCTAssertNil(try store.libraryIndex().entries[id], "it stays out")
        let history = try XCTUnwrap(store.libraryHistory(id: id)).versions
        XCTAssertEqual(history.count, rows + 1)
        XCTAssertEqual(history.last?.reason, "reason corrected: two groups over four (it said: three over fourteen)")
        XCTAssertThrowsError(try store.changeLibrary(.init(action: .takeOut, id: "no-such", reason: "x"), by: "agent"))
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

    /// Callees entering in the same publish count: a pair that call each other
    /// enter together, and a foreign callee or a data reference keeps out the
    /// body and whatever calls it.
    func testBodiesOfOnePublishEnterTogetherOrNotAtAll() throws {
        let a = LibraryBody(size: 0x20, full: "aaeeddccbbaa9988", specific: "1166554433221100")
        let b = LibraryBody(size: 0x21, full: "bbeeddccbbaa9988", specific: "2266554433221100")
        let c = LibraryBody(size: 0x22, full: "cceeddccbbaa9988", specific: "3366554433221100")
        func proposal(_ key: LibraryBody, _ name: String, calls: [LibraryCallee], data: [String] = []) throws -> LibraryProposal {
            let object = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": name, "kind": "edk2"], options: .sortedKeys)
            return LibraryProposal(body: key, name: name, kind: "edk2", address: "0x1", entry: object,
                                   dataReferences: data, callees: calls)
        }
        // Each calls the other, and the third reads data: it is out, and so is whoever calls it.
        let pair = try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
            try proposal(a, "PrintA", calls: [LibraryCallee(name: "PrintB", body: b.key)]),
            try proposal(b, "PrintB", calls: [LibraryCallee(name: "PrintA", body: a.key)])
        ])
        XCTAssertEqual(pair.added.map(\.name).sorted(), ["PrintA", "PrintB"])
        XCTAssertNil(pair.notLibrary)
        let d = LibraryBody(size: 0x23, full: "ddeeddccbbaa9988", specific: "4466554433221100")
        let out = try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
            try proposal(c, "ReadsData", calls: [], data: ["0x4"]),
            try proposal(d, "CallsIt", calls: [LibraryCallee(name: "ReadsData", body: c.key)])
        ])
        XCTAssertEqual(out.added.count, 0)
        XCTAssertEqual(out.notLibrary?.map(\.why).sorted(), ["callee", "data"])
        // A pair where one half has a foreign callee: neither enters.
        let e = LibraryBody(size: 0x24, full: "eeeeddccbbaa9988", specific: "5566554433221100")
        let f = LibraryBody(size: 0x25, full: "ffeeddccbbaa9988", specific: "6666554433221100")
        let half = try store.putLibraryEntries(module: source, rev: 1, by: "agent", proposals: [
            try proposal(e, "HalfE", calls: [LibraryCallee(name: "HalfF", body: f.key)]),
            try proposal(f, "HalfF", calls: [LibraryCallee(name: "HalfE", body: e.key), LibraryCallee(name: "Local", body: nil)])
        ])
        XCTAssertEqual(half.added.count, 0)
        XCTAssertEqual(half.notLibrary?.count, 2)
    }

    // MARK: What is the publisher's, in a holder's reading

    private func function(entry: String, c: String? = nil, spans: [[Any]] = [],
                          instructions: [[String: Any]], extra: [String: Any] = [:]) throws -> CodeArtifact.Function {
        var fields: [String: Any] = ["entry": entry, "name": "F", "instructions": instructions, "c_spans": spans]
        if let c { fields["c"] = c }
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(CodeArtifact.Function.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func instruction(_ address: String, _ references: [(String, String)] = []) -> [String: Any] {
        ["address": address, "bytes": "90", "text": "NOP",
         "references": references.map { ["to": $0.0, "type": $0.1] }]
    }

    private func span(_ token: String, in c: String, _ kind: String, _ target: String) -> [Any] {
        [(c as NSString).range(of: token).location, (token as NSString).length, kind, target]
    }

    /// A stray reference on the publisher's side does not cost the call its target.
    func testAStrayReferenceDoesNotLoseTheCallsTarget() throws {
        let theirs = try function(entry: "0x1000", instructions: [
            instruction("0x1000", [("0x2000", "UNCONDITIONAL_CALL"), ("0x0", "WRITE")])
        ])
        let ours = try function(entry: "0x9000", instructions: [
            instruction("0x9000", [("0xA000", "UNCONDITIONAL_CALL")])
        ])
        let carried = LibraryView.carriedOver(from: theirs, to: ours)
        XCTAssertEqual(carried[CodeAddress(hex: "0x2000")!], CodeAddress(hex: "0xA000")!)
        XCTAssertNil(carried[CodeAddress(hex: "0x0")!], "no partner: not carried")
    }

    /// Counts that differ within a type cannot be paired honestly: nothing of
    /// that type goes anywhere, rather than to the wrong place.
    func testReferencesThatCannotBePairedAreNotCarried() throws {
        let theirs = try function(entry: "0x1000", instructions: [
            instruction("0x1000", [("0x5000", "READ"), ("0x5004", "READ"), ("0x2000", "UNCONDITIONAL_CALL")]),
            instruction("0x1004", [("0x6000", "READ")])
        ])
        let ours = try function(entry: "0x9000", instructions: [
            instruction("0x9000", [("0xD004", "READ"), ("0xA000", "UNCONDITIONAL_CALL")]),
            instruction("0x9004", [("0xE000", "DATA")])
        ])
        let carried = LibraryView.carriedOver(from: theirs, to: ours)
        XCTAssertNil(carried[CodeAddress(hex: "0x5000")!])
        XCTAssertNil(carried[CodeAddress(hex: "0x5004")!])
        XCTAssertNil(carried[CodeAddress(hex: "0x6000")!], "another type is no partner")
        XCTAssertEqual(carried[CodeAddress(hex: "0x2000")!], CodeAddress(hex: "0xA000")!)
    }

    /// One address that would land in two places lands in neither.
    func testAnAddressThatWouldLandInTwoPlacesLandsInNeither() throws {
        let theirs = try function(entry: "0x1000", instructions: [
            instruction("0x1000", [("0x5000", "READ")]), instruction("0x1004", [("0x5000", "READ")])
        ])
        let ours = try function(entry: "0x9000", instructions: [
            instruction("0x9000", [("0xD000", "READ")]), instruction("0x9004", [("0xD008", "READ")])
        ])
        XCTAssertNil(LibraryView.carriedOver(from: theirs, to: ours)[CodeAddress(hex: "0x5000")!])
    }

    private let tableC = "x = s_Success_09dffb80; y = s_Warning_Stale_Data_09dffbfd; z = DAT_09dffb74;"

    private func tableSource() throws -> CodeArtifact.Function {
        try function(entry: "0x1000", c: tableC, spans: [
            span("s_Success_09dffb80", in: tableC, "global", "0x9DFFB80"),
            span("s_Warning_Stale_Data_09dffbfd", in: tableC, "global", "0x9DFFBFD"),
            span("DAT_09dffb74", in: tableC, "global", "0x9DFFB74")
        ], instructions: [instruction("0x1000", [("0x9DFFB80", "DATA"), ("0x9DFFB74", "READ")])])
    }

    private func tableHolder() throws -> CodeArtifact.Function {
        try function(entry: "0x9A1210F", instructions: [
            instruction("0x9A1210F", [("0x9A12D18", "DATA"), ("0x9A12D10", "READ")])
        ])
    }

    /// `s_Warning_Stale_Data`: reached through a table, so no reference names
    /// it. The nearest data before it, the same distance on, and a string there.
    func testADatumOnlyATableReachesReadsTheHoldersAddress() throws {
        let source = try tableSource()
        let carried = LibraryView.carriedOver(from: source, to: try tableHolder())
        let rendered = LibraryView.render(source, carried: carried, name: { _ in nil }, string: {
            $0 == CodeAddress(hex: "0x9A12D95")! ? "Warning Stale Data" : nil
        })
        XCTAssertEqual(rendered.c, "x = s_Success_09a12d18; y = s_Warning_Stale_Data_09a12d95; z = DAT_09a12d10;")
        XCTAssertEqual(rendered.publisherAddresses, [])
        XCTAssertTrue(rendered.spans.contains { $0.target == CodeAddress(hex: "0x9A12D95")! })
    }

    /// A string there that does not read as the name, or none: the text stays,
    /// the link goes, and the reading says so.
    func testANameTheHolderDoesNotBearOutKeepsItsTextAndLosesItsLink() throws {
        let source = try tableSource()
        let carried = LibraryView.carriedOver(from: source, to: try tableHolder())
        for held in ["Warning Bad Buffer Size", nil] as [String?] {
            let rendered = LibraryView.render(source, carried: carried, name: { _ in nil }, string: { _ in held })
            XCTAssertTrue(rendered.c.contains("s_Warning_Stale_Data_09dffbfd"))
            XCTAssertEqual(rendered.publisherAddresses, ["s_Warning_Stale_Data_09dffbfd"])
            let at = (rendered.c as NSString).range(of: "s_Warning").location
            XCTAssertNil(rendered.spans.first { $0.start == at }?.target)
        }
    }

    /// The holder's own symbol wins, as it always did.
    func testAHoldersOwnNameIsPrintedForAddressName() throws {
        let source = try tableSource()
        let carried = LibraryView.carriedOver(from: source, to: try tableHolder())
        let rendered = LibraryView.render(source, carried: carried, name: {
            $0 == CodeAddress(hex: "0x9A12D18")! ? "gSuccessText" : nil
        })
        XCTAssertTrue(rendered.c.contains("x = gSuccessText;"))
    }

    private func offering(c: String, equates: [[String: Any]]? = nil) throws -> Data {
        let function: [String: Any] = [
            "entry": "0x1000", "name": "CopyMem", "signature": "void CopyMem(void)", "c": c,
            "instructions": [
                ["address": "0x1000", "bytes": "90", "text": "NOP"],
                ["address": "0x1004", "bytes": "e8", "text": "CALL 0x2000",
                 "references": [["to": "0x2000", "type": "UNCONDITIONAL_CALL"]]]
            ]
        ]
        var object: [String: Any] = ["schema": 1, "name": "CopyMem", "kind": "edk2", "plate": "EDK2 CopyMem",
                                     "signature": "void CopyMem(void)", "function": function]
        object["equates"] = equates
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    private func offer(_ object: Data, from module: SHA256Digest, base: Int, why: String? = nil) throws -> LibraryWriteResult {
        var id = ""
        if let found = try store.libraryIndex().entry(for: body) { id = found.0 }
        return try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1000", entry: object,
                            basedOn: id, base: base)
        ], take: why.map { LibraryTake.none.with(entryReasons: [id: $0]) } ?? .none,
           dryRun: why == nil)
    }

    /// A name the C prints is the entry's: the reason answers for it by name, a
    /// holder reads what it means from the entry, and the holder's own equate on
    /// the value is neither printed nor what a click finds. Nothing of a
    /// holder's tag, mark or symbol enters the text.
    func testAnEquateInTheCIsAnsweredForAndMeansWhatTheEntrySays() throws {
        try register(try offering(c: "void CopyMem(void) {\n  cpuid(0xbaccd00b);\n}\n"))
        let named: [[String: Any]] = [["name": "ONE_NAME", "value": "0xBACCD00B", "enum": "LEAF",
                                       "comment": "What the entry says.", "uses": [["0x4", 1]]]]
        let printing = try offering(c: "void CopyMem(void) {\n  cpuid(ONE_NAME);\n}\n", equates: named)

        // A name where the entry printed a number only adds to it.
        let would = try offer(printing, from: source, base: 1)
        XCTAssertEqual(would.updated.first?.names, ["equate +ONE_NAME"])
        XCTAssertEqual(would.updated.first?.changed?.contains("equates"), true)
        XCTAssertEqual(try store.libraryIndex().entry(for: body)?.1.version, 1, "a dry run stored nothing")

        let taken = try offer(printing, from: source, base: 1, why: "the leaf is AGESA's")
        XCTAssertEqual(taken.updated.first?.names, ["equate +ONE_NAME"])
        XCTAssertEqual(taken.updated.first?.version, 2)

        // The same names again: no change.
        XCTAssertEqual(try offer(printing, from: source, base: 2).unchanged.count, 1)
        // Another module's text prints another name: both are said.
        let other = SHA256Digest(data: Data("other".utf8))
        let otherName = try offering(c: "void CopyMem(void) {\n  cpuid(OTHER_NAME);\n}\n", equates: [
            ["name": "OTHER_NAME", "value": "0xBACCD00B", "uses": [["0x4", 1]]]
        ])
        XCTAssertEqual(try offer(otherName, from: other, base: 2).conflicts.first?.names,
                       ["equate +OTHER_NAME", "equate -ONE_NAME"])
        // Its text printing the number drops the name, and says so.
        let number = try offering(c: "void CopyMem(void) {\n  cpuid(0xbaccd00b);\n}\n")
        XCTAssertEqual(try offer(number, from: other, base: 2).conflicts.first?.names, ["equate -ONE_NAME"])
        // The comment moved: the name stays, and its meaning is another.
        var moved = named[0]
        moved["comment"] = "Another meaning."
        XCTAssertEqual(try offer(try offering(c: "void CopyMem(void) {\n  cpuid(ONE_NAME);\n}\n", equates: [moved]),
                                 from: other, base: 2).conflicts.first?.names, ["equate ~ONE_NAME"])

        // A holder with its own equate on the value, its own tag and symbol.
        let (id, row) = try XCTUnwrap(try store.libraryIndex().entry(for: body))
        let entry = try XCTUnwrap(LibraryView.Entry(object: try store.object(row.entry), id: id, version: row.version))
        let holder = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: [
            "script_version": 10, "ghidra": "12.2", "program": ["image_base": "0x0"],
            "functions": [[
                "entry": "0x9000", "name": "OwnSymbol", "signature": "int OwnSymbol(void)", "body": body.key,
                "registry": id,
                "c": "int OwnSymbol(void) { cpuid(HOLDERS_NAME); }",
                "instructions": [
                    ["address": "0x9000", "bytes": "90", "text": "NOP"],
                    ["address": "0x9004", "bytes": "e8", "text": "CALL 0xA000",
                     "references": [["to": "0xA000", "type": "UNCONDITIONAL_CALL"]]]
                ]
            ]],
            "equates": [["name": "HOLDERS_NAME", "value": "0xBACCD00B", "enum": "HOLDERS", "comment": "The holder's.",
                         "references": [["0x9004", 1]]],
                        ["name": "ONE_NAME", "value": "0x1", "enum": "HOLDERS", "comment": "The holder's other.",
                         "references": [["0x9000", 0]]]]
        ]))
        let local = try XCTUnwrap(holder.functions.first)
        let read = LibraryView.function(local, entry: entry, name: { _ in nil })
        let c = try XCTUnwrap(read.c)
        XCTAssertTrue(c.contains("cpuid(ONE_NAME)"))
        for own in ["HOLDERS_NAME", "OwnSymbol", "amd", "library"] { XCTAssertFalse(c.contains(own), own) }
        XCTAssertEqual(read.entryEquates.first?.references.first?.address.value, 0x9004)
        XCTAssertEqual(read.entryEquates.first?.comment, "What the entry says.")

        var artifact = holder
        artifact.functions[0] = read
        let model = CodeModel(artifact: artifact, moduleBytes: nil)
        let at = (c as NSString).range(of: "ONE_NAME").location
        let token = CodeToken(start: at, length: 8, kind: .constant)
        XCTAssertEqual(model.explanation(ofC: token, inFunction: 0)?.text, "What the entry says.",
                       "the entry's meaning, not the holder's equate of that name")
    }

    /// An entry from before entries recorded their equates, already printing
    /// the name, has not changed by now saying so.
    func testAnOlderEntryPrintingTheNameHasNotChanged() throws {
        let c = "void CopyMem(void) {\n  cpuid(ONE_NAME);\n}\n"
        try register(try offering(c: c))
        let said = try offering(c: c, equates: [["name": "ONE_NAME", "value": "0x1", "uses": [["0x4", 1]]]])
        // Another module says so: nothing moves, and it records nothing.
        let other = SHA256Digest(data: Data("other".utf8))
        let id = try XCTUnwrap(try store.libraryIndex().entry(for: body)?.0)
        XCTAssertEqual(try store.putLibraryEntries(module: other, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1000", entry: said, basedOn: id, base: 1)
        ]).unchanged.count, 1)
        XCTAssertNil(LibraryView.Entry(object: try store.object(try XCTUnwrap(store.libraryIndex().entries[id]).entry),
                                       id: id, version: 1)?.equates.first)
        // The module its C came from fills them in: no version moves, history says so.
        let filled = try store.putLibraryEntries(module: source, rev: 2, by: "agent", proposals: [
            LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1000", entry: said, basedOn: id, base: 1)
        ])
        XCTAssertEqual(filled.updated.first?.version, 1)
        XCTAssertEqual(filled.updated.first?.changed, ["equates"])
        let row = try XCTUnwrap(store.libraryIndex().entries[id])
        XCTAssertEqual(row.version, 1)
        XCTAssertEqual(LibraryView.Entry(object: try store.object(row.entry), id: id, version: 1)?.equates.first?.equate.name, "ONE_NAME")
        XCTAssertEqual(try store.libraryHistory(id: id)?.versions.last?.reason, "the equates its C prints recorded by its module")
    }

    /// A conflict says which names taking it would change, as a change does.
    func testAConflictNamesWhatItPrints() throws {
        try register(try offering(c: "void CopyMem(void) {\n  cpuid(ONE_NAME);\n}\n", equates: [
            ["name": "ONE_NAME", "value": "0x1", "uses": [["0x4", 1]]]
        ]))
        let number = try offering(c: "void CopyMem(void) {\n  cpuid(0x1);\n}\n")
        XCTAssertEqual(try offer(number, from: source, base: 0).conflicts.first?.names, ["equate -ONE_NAME"])
    }

    /// A named label in the offered C is the review's, answered for like an
    /// equate; the decompiler's own `LAB_` is no name.
    func testANamedLabelInTheCIsAnsweredFor() throws {
        try register(try offering(c: "void CopyMem(void) {\n  goto LAB_00001004;\nLAB_00001004:\n}\n"))
        let named = try offering(c: "void CopyMem(void) {\n  goto ErrorExit;\nErrorExit:\n}\n")
        XCTAssertEqual(try offer(named, from: source, base: 1).updated.first?.names, ["label +ErrorExit"])
        let taken = try offer(named, from: source, base: 1, why: "the exit path")
        XCTAssertEqual(taken.updated.first?.names, ["label +ErrorExit"])
        let other = SHA256Digest(data: Data("other".utf8))
        XCTAssertEqual(try offer(try offering(c: "void CopyMem(void) {\n  goto LAB_09001004;\nLAB_09001004:\n}\n"),
                                 from: other, base: 2).conflicts.first?.names, ["label -ErrorExit"])
        XCTAssertTrue(LibraryProposal.sameReview(try offering(c: "goto LAB_00001000;"), try offering(c: "goto LAB_00009000;")),
                      "two modules' decompiler labels are no change")
    }

    /// Labels and removed blocks: the holder's address, same length, so no span
    /// after them moves. One with no place here is reported.
    func testLabelsAndRemovedBlocksReadTheHoldersAddress() throws {
        let c = "/* Removing unreachable block (ram,0x00001004) */\ngoto LAB_00001000;\nLAB_00001000:\ngoto LAB_00001008;\nCallee();"
        let source = try function(entry: "0x1000", c: c, spans: [span("Callee", in: c, "function", "0x2000")], instructions: [
            instruction("0x1000", [("0x2000", "UNCONDITIONAL_CALL")]), instruction("0x1004")
        ])
        let ours = try function(entry: "0x9000", instructions: [
            instruction("0x9000", [("0xA000", "UNCONDITIONAL_CALL")]), instruction("0x9004")
        ])
        let rendered = LibraryView.render(source, carried: LibraryView.carriedOver(from: source, to: ours),
                                          name: { _ in nil })
        XCTAssertEqual(rendered.c.utf16.count, c.utf16.count)
        XCTAssertTrue(rendered.c.contains("(ram,0x00009004)"))
        XCTAssertTrue(rendered.c.contains("goto LAB_00009000;\nLAB_00009000:"))
        XCTAssertEqual(rendered.publisherAddresses, ["LAB_00001008"])
        let callee = (rendered.c as NSString).range(of: "Callee").location
        XCTAssertEqual(rendered.spans.first?.start, callee)
    }

    /// A mark whose id the registry no longer holds: the module's function, its
    /// own text, no `entry` on its row. With the switch off nothing changes.
    func testAGoneMarkReadsItsOwnTextWithNoEntry() throws {
        try register(try entryObject())
        let c = "int OwnName(void) { return 0; }"
        let data = try JSONSerialization.data(withJSONObject: [
            "script_version": 10, "ghidra": "12.2", "functions": [[
                "entry": "0x9000", "name": "OwnName", "c": c, "body": "99-gone-body",
                "library_entry": ["id": "99-gone-entry", "version": 3, "state": "entry"],
                "instructions": [["address": "0x9000", "bytes": "90", "text": "NOP"]]
            ] as [String: Any]]
        ])
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: data)
        let read = try XCTUnwrap(store.throughRegistry(artifact).functions.first)
        XCTAssertEqual(read.c, c)
        XCTAssertNil(read.libraryEntry)
        XCTAssertFalse(read.textFromRegistry)

    }

    /// An entry that cannot be read leaves the published text; the row stays
    /// marked and has no `text`, which is how the failure shows.
    func testAnEntryThatCannotBeReadShowsOnTheRow() throws {
        try register(try entryObject())
        let artifact = try moduleArtifact()
        XCTAssertEqual(store.throughRegistry(artifact).functions.first?.textFromRegistry, true)
        let (_, held) = try XCTUnwrap(try store.libraryIndex().entry(for: body))
        try FileManager.default.removeItem(at: store.objectURL(held.entry))
        let read = try XCTUnwrap(store.throughRegistry(artifact).functions.first)
        XCTAssertFalse(read.textFromRegistry)
        XCTAssertTrue(read.textUnavailable)
        XCTAssertEqual(read.name, "CopyMem", "the index still names it")
    }

    /// A function's own state is not made `entry` by being read as the entry.
    // MARK: - Stage 2: no copies, and other bytes are another function

    private func exported(_ rows: [[String: Any]], symbols: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["script_version": 10, "ghidra": "12.2", "functions": rows,
                                                    "symbols": symbols, "strings": [], "blocks": [], "types": []],
                                   options: .sortedKeys)
    }

    private func row(_ entry: String, name: String, body: String?, mark: [String: Any]? = nil,
                     bytes: String? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "entry": entry, "name": name, "signature": "void \(name)(void)", "c": "void \(name)(void) {}",
            "c_spans": [], "c_sites": [], "c_fields": [], "name_source": "USER_DEFINED", "name_reason": "the review's",
            "signature_reason": "the review's", "library_kind": "edk2", "review_level": "library", "review_gaps": ["plate"],
            "callers": ["0x100"], "callees": [], "instructions": [["address": entry, "bytes": "90", "text": "NOP"]]]
        row["body"] = body
        row["library_entry"] = mark
        row["reference_bytes"] = bytes
        return row
    }

    /// The index with the code the export gives it, as a publish teaches it.
    private func taught(_ raw: Data, _ index: LibraryIndex) -> (LibraryIndex, [SHA256Digest: Data]) {
        var index = index
        var code: [SHA256Digest: Data] = [:]
        for teaching in ModuleFormat.teachings(raw, index: index) {
            let digest = SHA256Digest(data: teaching.code)
            code[digest] = teaching.code
            if let at = index.entries[teaching.id]?.variants.firstIndex(where: { $0.body.key == teaching.variant.body.key }) {
                index.entries[teaching.id]?.variants[at].code = digest
            }
        }
        return (index, code)
    }

    private func indexHolding(_ key: String, bytes: String? = nil) -> LibraryIndex {
        var index = LibraryIndex()
        let parts = key.split(separator: "-").map(String.init)
        let body = LibraryBody(size: Int(parts[0], radix: 16) ?? 0, full: parts[1], specific: parts[2])
        index.entries[key] = LibraryIndexEntry(
            version: 3, entry: SHA256Digest(data: Data("entry".utf8)), name: "PeiServicesLocatePpi", kind: "edk2",
            source: LibrarySource(module: SHA256Digest(data: Data("m".utf8)), address: "0x1", rev: 1, by: "agent"),
            variants: [LibraryVariant(body: body, module: SHA256Digest(data: Data("m".utf8)), referenceBytes: bytes)])
        index.bodies[key] = key
        return index
    }

    func testAModuleStoresOnlyItsOwnFactsOfARegistryFunction() throws {
        let key = "13-f8dd4aec64a3065c-ead22510a48e4aa9"
        let index = indexHolding(key)
        let raw = try exported([
            row("0x1000", name: "ByMark", body: key, mark: ["id": key, "version": 3, "state": "entry"]),
            row("0x2000", name: "BodyOnly", body: key),
            row("0x3000", name: "Edited", body: key, mark: ["id": key, "version": 3, "state": "edited"]),
            row("0x5000", name: "ModulesOwn", body: "13-1111111111111111-2222222222222222")
        ], symbols: [["address": "0x1000", "name": "ByMark"], ["address": "0x5000", "name": "ModulesOwn"],
                     ["address": "0x9000", "name": "gGuid"]])
        let (taught, code) = taught(raw, index)
        let stored = ModuleFormat.stored(raw, index: taught, code: code)
        XCTAssertEqual(stored.functions, ["0x1000", "0x2000", "0x3000"], "a draft stays in its project")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored.artifact) as? [String: Any])
        let rows = try XCTUnwrap(object["functions"] as? [[String: Any]])
        for link in rows.prefix(3) {
            XCTAssertEqual(link.keys.sorted(), ["body", "callees", "callers", "entry", "registry"])
            XCTAssertEqual(link["registry"] as? String, key)
            XCTAssertEqual(link["callers"] as? [String], ["0x100"])
        }
        XCTAssertNotNil(rows[3]["c"])
        XCTAssertNil(rows[3]["library_kind"])
        XCTAssertEqual(rows[3]["review_level"] as? String, "partial")
        XCTAssertEqual((object["symbols"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["ModulesOwn", "gGuid"])
        // Already in the form: byte for byte.
        XCTAssertEqual(ModuleFormat.stored(stored.artifact, index: taught, code: code).artifact, stored.artifact)
    }

    func testAReviewDocumentKeepsNothingOfAStrippedFunction() throws {
        let stripped = ModuleFormat.Stored(artifact: Data(), functions: ["0x1000"], addresses: ["0x1000", "0x1002"])
        let document = try JSONSerialization.data(withJSONObject: [
            "functions": ["0x1000": ["name": "ByMark"], "0x5000": ["name": "Own"]],
            "comments": [["address": "0x1002", "text": "a step"], ["address": "0x5000", "text": "own"]],
            "data": [:]], options: .sortedKeys)
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: ModuleFormat.review(document, of: stripped)) as? [String: Any])
        XCTAssertEqual((out["functions"] as? [String: Any])?.keys.sorted(), ["0x5000"])
        XCTAssertEqual((out["comments"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, ["own"])
    }

    /// `PeiServicesLocatePpi` of another GUID has the same key: it is another function.
    func testOtherBytesAreAnotherFunctionWithOrWithoutAMark() throws {
        let key = "13-f8dd4aec64a3065c-ead22510a48e4aa9"
        let index = indexHolding(key, bytes: "aaaa")
        func id(_ bytes: String?, mark: String? = nil, in index: LibraryIndex) -> String? {
            LibraryView.entryID(body: key, mark: mark, external: false, thunk: false, referenceBytes: bytes, in: index)
        }
        XCTAssertEqual(id("aaaa", in: index), key)
        XCTAssertNil(id("bbbb", in: index), "a body-only row of another GUID")
        XCTAssertNil(id("bbbb", mark: key, in: index), "nor by a mark")
        XCTAssertNil(id(nil, in: index), "a row that says no bytes is in doubt: the module's")
        XCTAssertEqual(id("bbbb", in: indexHolding(key)), key, "nor an entry that has not learned them")
        // So it keeps its text.
        let raw = try exported([row("0x2000", name: "OtherGuid", body: key, bytes: "bbbb"),
                                row("0x3000", name: "SameGuid", body: key, bytes: "aaaa")])
        let (known, code) = taught(raw, index)
        XCTAssertEqual(ModuleFormat.stored(raw, index: known, code: code).functions, ["0x3000"])
    }

}
