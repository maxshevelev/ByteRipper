import XCTest
@testable import CodeAnalysis

/// The ASM of a library function is the registry's: a module holds where it stands
/// and the addresses of what it names, and those two give its real instructions.
final class LibraryCodeTests: XCTestCase {
    private let caller = "10-1111111111111111-2222222222222222"
    private let callee = "11-3333333333333333-4444444444444444"

    private func instruction(_ address: String, _ bytes: String, _ mnemonic: String, _ text: String,
                             _ references: [[String: Any]] = []) -> [String: Any] {
        ["address": address, "bytes": bytes, "mnemonic": mnemonic, "text": text, "flow": "FALL_THROUGH", "references": references]
    }

    /// One function as a module has it: a local jump, a call to `callee` at
    /// `target`, a read of a table at `table`, a stack reference.
    private func function(at base: UInt64, target: UInt64, table: UInt64) -> [String: Any] {
        func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }
        func le(_ value: UInt64) -> String {
            (0..<4).map { String(format: "%02X", UInt8((value >> (8 * UInt64($0))) & 0xFF)) }.joined(separator: " ")
        }
        let call = base + 2
        return ["entry": hex(base), "name": "Caller", "body": caller, "c": "the review's text",
                "instructions": [
                    instruction(hex(base), "75 05", "JNZ", String(format: "JNZ 0x%08llx", base + 7),
                                [["to": hex(base + 7), "type": "CONDITIONAL_JUMP"]]),
                    instruction(hex(call), "E8 " + le(target &- (call + 5)), "CALL", String(format: "CALL 0x%08llx", target),
                                [["to": hex(target), "type": "UNCONDITIONAL_CALL"], ["to": "0x0", "type": "WRITE"]]),
                    instruction(hex(base + 7), "8A 89 " + le(table), "MOV", String(format: "MOV CL,byte ptr [ECX + 0x%llx]", table),
                                [["to": hex(table), "type": "DATA"]]),
                    instruction(hex(base + 13), "8B 45 08", "MOV", "MOV EAX,dword ptr [EBP + 0x8]",
                                [["to": "0x8", "type": "READ"]])
                ]]
    }

    private func artifact(_ functions: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "script_version": 10, "ghidra": "12.2", "functions": functions,
            "blocks": [["name": ".text", "start": "0x1000", "end": "0x9FFFFF", "executable": true, "initialized": true]]]
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func calleeRow(at base: UInt64, body: String? = nil) -> [String: Any] {
        ["entry": String(format: "0x%llX", base), "name": "Callee", "body": body ?? callee, "c": "callee text",
         "instructions": [instruction(String(format: "0x%llX", base), "C3", "RET", "RET")]]
    }

    private func index(kind: String = "edk2") -> LibraryIndex {
        var index = LibraryIndex()
        for (key, name) in [(caller, "Caller"), (callee, "Callee")] {
            let parts = key.split(separator: "-").map(String.init)
            let body = LibraryBody(size: Int(parts[0], radix: 16) ?? 0, full: parts[1], specific: parts[2])
            let module = SHA256Digest(data: Data("m".utf8))
            index.entries[key] = LibraryIndexEntry(
                version: 1, entry: SHA256Digest(data: Data(name.utf8)), name: name, kind: kind,
                source: LibrarySource(module: module, address: "0x1", rev: 1, by: "agent"),
                variants: [LibraryVariant(body: body, module: module)])
            index.bodies[key] = key
        }
        return index
    }

    private func taught(_ raw: Data, _ start: LibraryIndex) -> (LibraryIndex, [SHA256Digest: Data]) {
        var index = start
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

    private func decoded(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Built from one module, it gives another module's instructions byte for byte,
    /// and a link holds no instruction of its own.
    func testTheRegistrysCodeGivesAnotherModulesInstructionsExactly() throws {
        let source = try artifact([function(at: 0x2000, target: 0x5000, table: 0x7000), calleeRow(at: 0x5000)])
        let (known, code) = taught(source, index())
        XCTAssertEqual(code.count, 2)
        let theirs = function(at: 0x93000, target: 0x90000, table: 0x98000)
        let other = try artifact([theirs, calleeRow(at: 0x90000)])

        let stored = ModuleFormat.stored(other, index: known, code: code)
        XCTAssertEqual(stored.functions, ["0x93000", "0x90000"])
        let rows = try XCTUnwrap(decoded(stored.artifact)["functions"] as? [[String: Any]])
        XCTAssertNil(rows[0]["instructions"])
        XCTAssertNil(rows[0]["c"])
        let targets = try XCTUnwrap(rows[0]["targets"] as? [String: String])
        XCTAssertEqual(targets[callee], "0x90000", "the callee by its number")
        XCTAssertEqual(targets["data_7"], "0x98000", "the datum by its label")
        XCTAssertEqual(targets.count, 2, "nothing for a local jump or the stack")

        let digest = try XCTUnwrap(known.entries[caller]?.variants[0].code)
        let made = try XCTUnwrap(LibraryCode.instructions(code: try XCTUnwrap(code[digest]), entry: 0x93000, targets: targets))
        let real = try XCTUnwrap(theirs["instructions"] as? [[String: Any]])
        XCTAssertEqual(made.map { $0["bytes"] as? String }, real.map { $0["bytes"] as? String })
        XCTAssertEqual(made.map { $0["text"] as? String }, real.map { $0["text"] as? String })
        XCTAssertEqual(made.map { $0["address"] as? String }, real.map { $0["address"] as? String })
        // Already in the form: byte for byte.
        XCTAssertEqual(ModuleFormat.stored(stored.artifact, index: known, code: code).artifact, stored.artifact)
    }

    /// The registry shows what a function calls by name, the name it has now.
    func testTheListingNamesTheCalleeAndNoAddressOfAModule() throws {
        let source = try artifact([function(at: 0x2000, target: 0x5000, table: 0x7000), calleeRow(at: 0x5000)])
        let (known, code) = taught(source, index())
        let digest = try XCTUnwrap(known.entries[caller]?.variants[0].code)
        let listing = try XCTUnwrap(LibraryCode.listing(code: try XCTUnwrap(code[digest])) { $0 == self.callee ? "RenamedCallee" : nil })
        XCTAssertEqual(listing[1]["text"] as? String, "CALL RenamedCallee")
        XCTAssertEqual(listing[1]["offset"] as? String, "0x2")
        XCTAssertEqual(listing[2]["text"] as? String, "MOV CL,byte ptr [ECX + data_7]")
    }

    /// A call to anything the registry does not hold: no link, and no code from it.
    func testACallToAFunctionTheRegistryDoesNotHoldIsNoLink() throws {
        let source = try artifact([function(at: 0x2000, target: 0x5000, table: 0x7000), calleeRow(at: 0x5000)])
        let (known, code) = taught(source, index())
        let other = try artifact([function(at: 0x93000, target: 0x90000, table: 0x98000),
                                  calleeRow(at: 0x90000, body: "11-5555555555555555-6666666666666666")])
        let stored = ModuleFormat.stored(other, index: known, code: code)
        XCTAssertEqual(stored.functions, [], "its callee is another function")
        let rows = try XCTUnwrap(decoded(stored.artifact)["functions"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["c"] as? String, "the review's text", "so it is the module's")

        let unknown = try artifact([function(at: 0x93000, target: 0x90000, table: 0x98000)])
        XCTAssertEqual(ModuleFormat.teachings(unknown, index: index()).map(\.id), [], "nothing to learn from it")
    }

    /// Other bytes than the code gives are another function, whatever the key says.
    func testOtherBytesAreNoLink() throws {
        let source = try artifact([function(at: 0x2000, target: 0x5000, table: 0x7000), calleeRow(at: 0x5000)])
        let (known, code) = taught(source, index())
        var other = function(at: 0x93000, target: 0x90000, table: 0x98000)
        var list = try XCTUnwrap(other["instructions"] as? [[String: Any]])
        list[3]["bytes"] = "8B 45 0C"
        other["instructions"] = list
        let stored = ModuleFormat.stored(try artifact([other, calleeRow(at: 0x90000)]), index: known, code: code)
        XCTAssertEqual(stored.functions, ["0x90000"], "the callee still is")
    }

    /// The module's lists say nothing at a link's instructions, and a reader gets it back.
    func testTheModulesListsKeepNoTextOfALink() throws {
        let raw = try artifact([function(at: 0x2000, target: 0x5000, table: 0x7000), calleeRow(at: 0x5000),
                                ["entry": "0x8000", "name": "Own", "body": "12-7777777777777777-8888888888888888", "c": "own",
                                 "instructions": [instruction("0x8000", "90", "NOP", "NOP")]]],
                               extra: [
            "port_writes": [["address": "0x2002", "function": "0x2000", "port": "0x80", "text": "OUT 0x80,AL"],
                            ["address": "0x8000", "function": "0x8000", "port": "0x70", "text": "OUT 0x70,AL"]],
            "status_code_calls": [["address": "0x2002", "function": "0x2000", "text": "CALL x", "context": ["PUSH 1"]]],
            "equates": [["name": "AtLink", "value": "0x8", "references": [["address": "0x200D", "operand": 1]]],
                        ["name": "AtOwn", "value": "0x8", "references": [["address": "0x8000", "operand": 1]]]]])
        let (known, code) = taught(raw, index())
        let object = try decoded(ModuleFormat.stored(raw, index: known, code: code).artifact)
        let writes = try XCTUnwrap(object["port_writes"] as? [[String: Any]])
        XCTAssertNil(writes[0]["text"])
        XCTAssertEqual(writes[0]["port"] as? String, "0x80", "where it is stays the module's")
        XCTAssertEqual(writes[1]["text"] as? String, "OUT 0x70,AL")
        let calls = try XCTUnwrap(object["status_code_calls"] as? [[String: Any]])
        XCTAssertNil(calls[0]["text"])
        XCTAssertNil(calls[0]["context"])
        XCTAssertEqual((object["equates"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["AtOwn"])
    }

    /// A library function calls its own library, or EDK2, the base of all of them.
    func testAFunctionCallsItsOwnLibraryOrTheBaseOne() throws {
        var index = LibraryIndex()
        let module = SHA256Digest(data: Data("m".utf8))
        let amdBody = LibraryBody(size: 0x20, full: "aaaaaaaaaaaaaaaa", specific: "bbbbbbbbbbbbbbbb")
        let edkBody = LibraryBody(size: 0x21, full: "cccccccccccccccc", specific: "dddddddddddddddd")
        for (body, kind) in [(amdBody, "amd"), (edkBody, "edk2")] {
            index.entries[body.key] = LibraryIndexEntry(
                version: 1, entry: SHA256Digest(data: Data(kind.utf8)), name: kind, kind: kind,
                source: LibrarySource(module: module, address: "0x1", rev: 1, by: "a"),
                variants: [LibraryVariant(body: body, module: module)])
            index.bodies[body.key] = body.key
        }
        func proposal(kind: String, calls body: LibraryBody) -> LibraryProposal {
            LibraryProposal(body: LibraryBody(size: 0x30, full: "eeeeeeeeeeeeeeee", specific: "ffffffffffffffff"),
                            name: "F", kind: kind, address: "0x2", entry: Data("{}".utf8),
                            callees: [LibraryCallee(name: "Callee", body: body.key)])
        }
        XCTAssertNil(proposal(kind: "edk2", calls: edkBody).refusal(in: index))
        XCTAssertNil(proposal(kind: "amd", calls: amdBody).refusal(in: index))
        XCTAssertNil(proposal(kind: "amd", calls: edkBody).refusal(in: index), "EDK2 is the base")
        XCTAssertEqual(proposal(kind: "edk2", calls: amdBody).refusal(in: index)?.why, "dependency")
        XCTAssertEqual(proposal(kind: "intel", calls: amdBody).refusal(in: index)?.why, "dependency")
        XCTAssertEqual(proposal(kind: "phoenix", calls: edkBody).refusal(in: index)?.why, "library")
        XCTAssertTrue(index.mayCall("intel", "edk2"))
        XCTAssertFalse(index.mayCall("amd", "intel"))
        XCTAssertFalse(index.mayCall("intel", "amd"))
        XCTAssertFalse(index.mayCall("edk2", "intel"))
    }

    /// The registry's code is the only copy of a linked function's instructions:
    /// nothing that tidies the store or changes an entry may lose it.
    func testTheCodeSurvivesCollectionAndATakeOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryCode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let bytes = Data("a module".utf8)
        let module = ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count, name: "A")
        let recipe = AnalysisRecipe(id: "code-v10-test", exporter: 10, ghidra: "12.2", script: "ExportCode.java")
        func body(_ key: String) -> LibraryBody {
            let parts = key.split(separator: "-").map(String.init)
            return LibraryBody(size: Int(parts[0], radix: 16) ?? 0, full: parts[1], specific: parts[2])
        }
        func entry(_ name: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["name": name, "kind": "edk2"], options: .sortedKeys)
        }
        try store.putLibraryEntries(module: module.sha256, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: body(caller), name: "Caller", kind: "edk2", address: "0x1000", entry: try entry("Caller")),
            LibraryProposal(body: body(callee), name: "Callee", kind: "edk2", address: "0x2000", entry: try entry("Callee"))
        ])
        let raw = try artifact([function(at: 0x1000, target: 0x2000, table: 0x3000), calleeRow(at: 0x2000)])
        try store.putAnalysis(module: module, recipe: recipe, artifact: raw)
        try store.relinkModules()
        func read() throws -> CodeArtifact.Function {
            let manifest = try XCTUnwrap(store.analysis(module: module.sha256, recipe: recipe.id))
            return try XCTUnwrap(store.artifact(for: manifest).functions.first { $0.entry.value == 0x1000 })
        }
        XCTAssertEqual(try read().instructions.count, 4)
        XCTAssertEqual(try read().name, "Caller")

        // Collection drops the module's old object: the code is only in the registry now.
        _ = try store.collectGarbage(dryRun: false)
        XCTAssertEqual(try read().instructions.map(\.text).first, "JNZ 0x00001007")
        XCTAssertEqual(try read().instructions.count, 4)

        // Out of the registry, and its project has not published since: the
        // instructions still read, and a collection still keeps them.
        try store.changeLibrary(.init(action: .takeOut, id: caller, reason: "not a library function"), by: "agent")
        _ = try store.collectGarbage(dryRun: false)
        XCTAssertEqual(try read().instructions.count, 4)
        XCTAssertNil(try read().libraryEntry)
    }

    /// The dependencies are part of what the store holds, and the code obeys them
    /// whichever way it arrives: a call against them makes no link.
    func testTheStoreHoldsTheDependenciesAndACallAgainstThemMakesNoLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryDeps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = SHA256Digest(data: Data("deps".utf8))
        let entry = try JSONSerialization.data(withJSONObject: ["name": "One", "kind": "edk2"], options: .sortedKeys)
        let parts = caller.split(separator: "-").map(String.init)
        try store.putLibraryEntries(module: module, rev: 1, by: "agent", proposals: [
            LibraryProposal(body: LibraryBody(size: 0x10, full: parts[1], specific: parts[2]), name: "One", kind: "edk2",
                            address: "0x1", entry: entry)
        ])
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("library/index.json"))) as? [String: Any])
        let libraries = try XCTUnwrap(written["libraries"] as? [String: [String: [String]]])
        XCTAssertEqual(libraries["edk2"]?["depends_on"], [])
        XCTAssertEqual(libraries["amd"]?["depends_on"], ["edk2"])
        XCTAssertEqual(libraries["intel"]?["depends_on"], ["edk2"])

        // An index from before the table reads as the standard one.
        var older = try store.libraryIndex()
        older.libraries = nil
        XCTAssertTrue(older.mayCall("amd", "edk2"))
        XCTAssertFalse(older.mayCall("amd", "intel"))

        // An EDK2 function calling an AMD one is not a link, however its body matches.
        var index = self.index()
        index.entries[callee]?.kind = "amd"
        let raw = try artifact([function(at: 0x1000, target: 0x2000, table: 0x3000), calleeRow(at: 0x2000)])
        XCTAssertFalse(ModuleFormat.teachings(raw, index: index).contains { $0.id == caller })
        let (taught, code) = taught(raw, self.index())
        var moved = taught
        moved.entries[callee]?.kind = "amd"
        let stored = ModuleFormat.stored(raw, index: moved, code: code)
        let rows = try XCTUnwrap(decoded(stored.artifact)["functions"] as? [[String: Any]])
        XCTAssertNil(rows.first { $0["entry"] as? String == "0x1000" }?["registry"])
        XCTAssertNotNil(rows.first { $0["entry"] as? String == "0x2000" }?["registry"], "the callee itself is fine")
    }
}
