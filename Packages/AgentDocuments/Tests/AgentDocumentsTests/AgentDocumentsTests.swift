import AgentKit
import CodeAnalysis
import Foundation
import GhidraHost
import ToolModuleKit
import XCTest
@testable import AgentDocuments

/// The rule that says which document a call means on a host with no focus,
/// and a tool-module's query run on the document it names
/// (`Design/SERVER_HEADLESS_PLAN.md` §4.1).
@MainActor
final class AgentDocumentsTests: XCTestCase {
    func testAnIdNamesItsDocumentAndAnUnknownOneIsRefused() throws {
        let set = Documents([Document("d1", "a.bin"), Document("d3", "b.bin")])
        XCTAssertEqual(try set.resolve("d3").id, "d3")
        XCTAssertThrowsError(try set.resolve("d2")) { error in
            XCTAssertEqual((error as? AgentToolError)?.message,
                           "No open document has the id d2. Call `documents` for the ones that are open.")
        }
    }

    func testOneOpenIsImpliedSeveralMustBeNamedNoneIsTheHostsToSay() throws {
        XCTAssertEqual(try Documents([Document("d1", "a.bin")]).resolve(nil).id, "d1")
        XCTAssertThrowsError(try Documents([Document("d1", "a.bin"), Document("d2", "b.bin")]).resolve(nil)) { error in
            let message = (error as? AgentToolError)?.message ?? ""
            XCTAssertTrue(message.contains("a.bin (d1), b.bin (d2)"), message)
            XCTAssertTrue(message.contains("`document`"), message)
        }
        XCTAssertThrowsError(try Documents([]).resolve(nil)) { error in
            XCTAssertEqual((error as? AgentToolError)?.message, "Nothing is open here.")
        }
    }

    /// The adapter adds `document`, runs the query on the named document's
    /// host, and says in the answer which document it was — with `disk`
    /// beside it when the file is no longer the one read.
    func testAQueryRunsOnTheDocumentItNamesAndSaysWhichAndItsMark() async throws {
        let set = Documents([Document("d1", "a.bin"), Document("d2", "b.bin", disk: "changed")])
        let query = ToolAgentQuery(name: "file_name", title: "The file's name", description: "Says the name.") { host, _ in
            .json(["name": .string(host.fileName)])
        }
        let tool = ToolQueryTools.tool(for: query, documents: set, document: "Which one.")
        XCTAssertEqual(tool.inputSchema["properties"]?["document"]?["description"]?.stringValue, "Which one.")

        let first = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(["document": "d1"])))
        XCTAssertEqual(first, .json(["name": "a.bin", "document": "d1"]))
        let second = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(["document": "d2"])))
        XCTAssertEqual(second, .json(["name": "b.bin", "document": "d2", "disk": "changed"]))
        do {
            _ = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments([:])))
            XCTFail("two open and none named")
        } catch let error as AgentToolError {
            XCTAssertTrue(error.message.contains("Several documents are open"), error.message)
        }
    }

    /// What a host wraps around the run sees the resolved document and the
    /// query's answer; the stamp comes after it.
    func testAHostWrapsTheRun() async throws {
        let set = Documents([Document("d1", "a.bin")])
        let query = ToolAgentQuery(name: "file_name", title: "t", description: "d") { host, _ in
            .json(["name": .string(host.fileName)])
        }
        let tool = ToolQueryTools.tool(for: query, documents: set, document: "Which one.") { document, body in
            guard case .json(.object(var members)) = try await body() else { return .text("?") }
            members["wrapped"] = .string(document.named)
            return .json(.object(members))
        }
        let answer = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments([:])))
        XCTAssertEqual(answer, .json(["name": "a.bin", "wrapped": "a.bin (d1)", "document": "d1"]))
    }

    /// One `ghidra_open` in the list, and it is the one by a node.
    func testGhidraOpenIsReplacedNotAdded() {
        let tools = GhidraNodeOpen.tools(backend: NoGhidra(), documents: Documents([]),
                                         description: "Opens by node.", document: "The dump.")
        let names = tools.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "two tools of one name")
        let open = tools.first { $0.name == "ghidra_open" }
        XCTAssertEqual(open?.description, "Opens by node.")
        XCTAssertNotNil(open?.inputSchema["properties"]?["node"])
        XCTAssertNil(open?.inputSchema["properties"]?["image"])
    }
}

/// `CodeReadings` on its own: a module's analysis read from the store with no
/// dump and no panel, and the refusals a host's words make
/// (`Design/SERVER_HEADLESS_PLAN.md` §4.1) — the same code `byteripper-server`
/// serves, so it is tested where both can run it.
@MainActor
final class CodeReadingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeReadingsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let recipe = AnalysisRecipe(id: "code-v4-ghidra-12.1.2", exporter: 4, ghidra: "12.1.2",
                                        script: "ExportCode.java")

    private var module: ModuleIdentity {
        let bytes = Data("module".utf8)
        return ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count, name: "CpuPei", kind: "TE",
                              language: "x86:LE:32:default", imageBase: "0x0")
    }

    private static let artifact = """
        {"script_version": 4, "ghidra": "12.1.2", "functions": [
          {"entry": "0x1000", "name": "entry", "size": 1, "signature": "void entry(void)",
           "c": "void entry(void)\\n{\\n  return;\\n}\\n",
           "instructions": [{"address": "0x1000", "text": "RET"}]}
        ], "strings": [], "post_codes": [], "status_code_calls": []}
        """

    private func readings(_ documents: [Document] = []) -> CodeReadings {
        CodeReadings(
            documents: Documents(documents),
            wording: .init(query: "q", modules: "m",
                           queryDocument: "The dump.", modulesDocument: "The dump.",
                           missingNode: { "\($0) is not a Code panel." }),
            store: { self.directory },
            catalogue: { .empty })
    }

    private func query(_ readings: CodeReadings) throws -> AgentTool {
        try XCTUnwrap(readings.tools().first { $0.name == "code_query" })
    }

    func testAQueryByModuleReadsTheStoreWithNoDump() async throws {
        try ContentStore(root: directory).putAnalysis(module: module, recipe: recipe,
                                                      artifact: Data(Self.artifact.utf8))
        let tool = try query(readings())
        let answer = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("functions")])))
        guard case .json(.object(let members)) = answer else { return XCTFail("not an object: \(answer)") }
        let found = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("c"), "search": .string("RETURN"), "limit": .int(1)])))
        guard case .json(.object(let search)) = found else { return XCTFail("not an object: \(found)") }
        XCTAssertEqual(search["matches"]?.arrayValue?.count, 1, "\(search)")
        XCTAssertEqual(search["functions_matched"], search["total"], "\(search)")
        XCTAssertEqual(members["module"]?.stringValue, "CpuPei")
        XCTAssertEqual(members["sha256"]?.stringValue, module.sha256.hex)
        XCTAssertEqual(members["recipe"]?.stringValue, recipe.id)
        XCTAssertEqual(members["functions"]?.arrayValue?.first?["name"]?.stringValue, "entry")
        XCTAssertNil(members["document"], "no document was named")
        XCTAssertNil(members["disk"])
    }

    /// A function longer than one page is read to its end, page by page.
    func testALongFunctionsInstructionsAreReadToTheEnd() async throws {
        let lines = (0..<1200).map { #"{"address": "0x\#(String(0x1000 + $0, radix: 16))", "text": "NOP"}"# }
        let artifact = """
            {"script_version": 4, "ghidra": "12.1.2", "functions": [
              {"entry": "0x1000", "name": "entry", "size": 1200, "signature": "void entry(void)",
               "instructions": [\(lines.joined(separator: ","))]}
            ], "strings": [], "post_codes": [], "status_code_calls": []}
            """
        try ContentStore(root: directory).putAnalysis(module: module, recipe: recipe, artifact: Data(artifact.utf8))
        let tool = try query(readings())
        var seen: [String] = []
        var after: String?
        repeat {
            var values: [String: JSONValue] = ["module": .string(module.sha256.hex), "what": "instructions",
                                               "function": "entry", "limit": .int(500)]
            if let after { values["after"] = .string(after) }
            let answer = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments(values)))
            guard case .json(let page) = answer else { return XCTFail("not json: \(answer)") }
            XCTAssertEqual(page["total"], .int(1200))
            XCTAssertLessThanOrEqual(page["instructions"]?.arrayValue?.count ?? 0, 500)
            seen += page["instructions"]?.arrayValue?.compactMap { $0["address"]?.stringValue } ?? []
            after = page["next"]?.stringValue
        } while after != nil
        XCTAssertEqual(seen.count, 1200)
        XCTAssertEqual(Set(seen).count, 1200)
    }

    /// `code_query`'s library block: the numbers a Review status is written
    /// from — kinds, entries by state, the entries this module installed, the
    /// ones that moved on after it, and the tagged functions short of the
    /// bar — counted from the stored analysis and the registry, with
    /// `too_short` from an owner that runs.
    func testTheLibrarySummaryCountsTheRegistry() async throws {
        let store = try ContentStore(root: directory)
        let body1 = LibraryBody(size: 0x10, full: "1111111111111111", specific: "aaaaaaaaaaaaaaaa")
        let body2 = LibraryBody(size: 0x20, full: "2222222222222222", specific: "bbbbbbbbbbbbbbbb")
        func proposal(_ name: String, _ body: LibraryBody, _ kind: String, _ plate: String,
                      base: Int? = nil) throws -> LibraryProposal {
            let entry = try JSONSerialization.data(withJSONObject: ["name": name, "kind": kind, "plate": plate],
                                                   options: .sortedKeys)
            return LibraryProposal(body: body, name: name, kind: kind, address: "0x1000", entry: entry,
                                   basedOn: base == nil ? nil : body.key, base: base)
        }
        try store.putLibraryEntries(module: module.sha256, rev: 1, by: "agent", proposals: [
            try proposal("SetMem", body1, "edk2", "v1"),
            try proposal("LibAmdIoWrite", body2, "amd", "v1")
        ])
        // The second entry moves on: the module's mark is a version behind.
        try store.putLibraryEntries(module: module.sha256, rev: 2, by: "agent", proposals: [
            try proposal("LibAmdIoWrite", body2, "amd", "v2", base: 1)
        ])
        let artifact = """
            {"script_version": 9, "ghidra": "12.1.2", "functions": [
              {"entry": "0x1000", "name": "SetMem", "signature": "void SetMem(void)",
               "library_kind": "edk2", "review_level": "full",
               "library_entry": {"id": "\(body1.key)", "version": 1, "state": "entry"},
               "instructions": [{"address": "0x1000", "text": "RET"}]},
              {"entry": "0x1020", "name": "LibAmdIoWrite", "signature": "undefined8 LibAmdIoWrite(void)",
               "library_kind": "amd", "review_level": "partial", "review_gaps": ["plate", "locals"],
               "library_entry": {"id": "\(body2.key)", "version": 1, "state": "conflict", "base": 1},
               "instructions": [{"address": "0x1020", "text": "RET"}]},
              {"entry": "0x1040", "name": "AsmWriteTr", "library_kind": "amd",
               "instructions": [{"address": "0x1040", "text": "RET"}]}
            ]}
            """
        try store.putAnalysis(module: module, recipe: recipe, artifact: Data(artifact.utf8))

        let tool = try query(readings())
        let answer = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("functions")])))
        guard case .json(.object(let body)) = answer,
              let library = body["library"]?.objectValue else { return XCTFail("no library block: \(answer)") }
        let levels = try XCTUnwrap(body["review_levels"]?.objectValue)
        XCTAssertEqual(levels["full"], .int(1))
        XCTAssertEqual(levels["partial"], .int(1))
        XCTAssertEqual(levels["decompiled"], .int(0))
        XCTAssertEqual(levels["library"], .int(0))
        XCTAssertEqual(levels["no_body"], .int(0))
        XCTAssertEqual(levels["unrecorded"], .int(1))
        let partial = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("functions"), "level": .string("partial")])))
        guard case .json(.object(let only)) = partial else { return XCTFail("not an object: \(partial)") }
        XCTAssertEqual(only["total"], .int(1))
        XCTAssertEqual(only["functions"]?.arrayValue?.first?["name"]?.stringValue, "LibAmdIoWrite")
        XCTAssertEqual(only["review_levels"]?.objectValue?["full"], .int(1), "the counts stay whole")
        XCTAssertEqual(library["edk2"], .int(1))
        XCTAssertEqual(library["amd"], .int(2))
        XCTAssertEqual(library["intel"], .int(0))
        XCTAssertEqual(library["with_entry"], .int(2))
        XCTAssertEqual(library["entry"], .int(1))
        XCTAssertEqual(library["conflict"], .int(1))
        XCTAssertEqual(library["edited"], .int(0))
        XCTAssertEqual(library["differs"], .int(0))
        XCTAssertEqual(library["installed"], .int(2), "both entries carry this module's current version")
        XCTAssertEqual(library["updated_since"], .int(1), "the second entry moved on after the mark")
        let below = try XCTUnwrap(library["below_bar"]?.objectValue)
        XCTAssertEqual(below["plate"], .int(1))
        XCTAssertEqual(below["locals"], .int(1))
        XCTAssertEqual(below["return"], .int(1), "the prototype's return type is Ghidra's placeholder")
        XCTAssertEqual(below["too_short"], .string("unknown"), "no owner was asked")
        XCTAssertEqual(below["name"], .int(0))

        // An owner that runs answers what Function ID could not hash.
        let running = readings()
        running.tooShortCount = { _ in 3 }
        let asked = try await query(running).run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("functions")])))
        guard case .json(.object(let second)) = asked,
              let shortfall = second["library"]?["below_bar"]?.objectValue else {
            return XCTFail("no library block: \(asked)")
        }
        XCTAssertEqual(shortfall["too_short"], .int(3))
    }

    /// A library function is graded like any other: its level is the tag's,
    /// but the gaps the bar reads are written into the artifact, so the
    /// counters here and the owner's `below_bar` describe the same reading.

    /// Every list goes by pages; `function` takes an address inside a body, and
    /// `search` narrows instructions as it does the other lists.
    /// A row says which body it is, so a function matched to the registry with no mark can be counted.
    func testACodeQueryRowNamesItsBody() async throws {
        let store = try ContentStore(root: directory)
        let functions = #"{"entry": "0x1000", "name": "Keyed", "body": "5-aa-bb"}, {"entry": "0x1010", "name": "Unkeyed"}"#
        try store.putAnalysis(module: module, recipe: recipe, artifact: Data((#"{"script_version": 10, "ghidra": "12.1.2", "functions": ["# + functions + "]}").utf8))
        let tool = try query(readings())
        guard case .json(.object(let body)) = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": "functions"]))),
              case .array(let rows)? = body["functions"] else { return XCTFail("no rows") }
        let keys = rows.map { row -> JSONValue? in
            guard case .object(let fields) = row else { return nil }
            return fields["body"]
        }
        XCTAssertEqual(keys, [.string("5-aa-bb"), JSONValue.null])
    }

    func testCodeQueryListsGoByPages() async throws {
        let store = try ContentStore(root: directory)
        let functions = (0..<5).map { index in
            """
            {"entry": "0x\(1000 + index * 10)", "name": "Fn\(index)", "signature_reason": "why \(index)",
             "instructions": [{"address": "0x\(1000 + index * 10)", "text": "PUSH EBP"},
                              {"address": "0x\(1001 + index * 10)", "text": "RET"}]}
            """
        }.joined(separator: ",")
        try store.putAnalysis(module: module, recipe: recipe, artifact: Data((#"{"script_version": 9, "ghidra": "12.1.2", "functions": ["# + functions + "]}").utf8))
        let tool = try query(readings())
        func ask(_ arguments: [String: JSONValue]) async throws -> [String: JSONValue] {
            var all = arguments
            all["module"] = .string(module.sha256.hex)
            guard case .json(.object(let body)) = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments(all))) else {
                throw CocoaError(.fileReadUnknown)
            }
            return body
        }
        var names: [String] = []
        var after: String?
        repeat {
            var question: [String: JSONValue] = ["what": "functions", "limit": 2]
            if let after { question["after"] = .string(after) }
            let page = try await ask(question)
            XCTAssertEqual(page["total"], 5)
            names += page["functions"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
            after = page["next"]?.stringValue
        } while after != nil
        XCTAssertEqual(names, ["Fn0", "Fn1", "Fn2", "Fn3", "Fn4"])

        let middle = try await ask(["what": "instructions", "function": "0x1011"])
        XCTAssertEqual(middle["function"]?.stringValue, "Fn1", "an address inside a body")
        XCTAssertEqual(middle["entry"]?.stringValue, "0x1010")
        let found = try await ask(["what": "instructions", "function": "Fn1", "search": "ret"])
        XCTAssertEqual(found["total"], 1)
        XCTAssertEqual(found["instructions"]?.arrayValue?.first?["text"]?.stringValue, "RET")
        XCTAssertEqual(found["instructions_in_function"], 2)
        let row = try await ask(["what": "functions", "search": "Fn3"])
        XCTAssertEqual(row["functions"]?.arrayValue?.first?["signature_reason"]?.stringValue, "why 3")
    }

    func testALibraryFunctionShortOfTheBarCountsInTheArtifactToo() async throws {
        let artifact = """
            {"script_version": 9, "ghidra": "12.1.2", "functions": [
              {"entry": "0x1020", "name": "SetJump", "signature": "undefined8 SetJump(void)",
               "library_kind": "edk2", "review_level": "library", "review_gaps": ["locals"],
               "instructions": [{"address": "0x1020", "text": "RET"}]},
              {"entry": "0x1040", "name": "LongJump", "signature": "void LongJump(void)",
               "library_kind": "edk2", "review_level": "library", "review_gaps": ["c"],
               "instructions": [{"address": "0x1040", "text": "RET"}]}
            ]}
            """
        try ContentStore(root: directory).putAnalysis(module: module, recipe: recipe,
                                                      artifact: Data(artifact.utf8))
        let tool = try query(readings())
        let answer = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("functions")])))
        guard case .json(.object(let body)) = answer,
              let library = body["library"]?.objectValue,
              let below = library["below_bar"]?.objectValue else {
            return XCTFail("no library block: \(answer)")
        }
        XCTAssertEqual(library["edk2"], .int(2), "the tag still says whose library it is")
        XCTAssertEqual(below["locals"], .int(1), "the gap the owner's bar also reads")
        XCTAssertEqual(below["c"], .int(1), "a body with no C is short of the bar")
        XCTAssertEqual(below["plate"], .int(0))
    }

    /// A placeholder the C still prints is reported on the row and counted, and
    /// the bar does not read it: the function stays clean of gaps.
    func testAPlaceholderInTheCIsReportedAndIsNotAGap() async throws {
        let artifact = """
            {"script_version": 9, "ghidra": "12.1.2", "functions": [
              {"entry": "0x1020", "name": "SetJump", "c": "uVar1 = Named;",
               "c_spans": [[0, 5, "local"], [8, 5, "local"]],
               "library_kind": "edk2", "review_level": "library", "review_gaps": [],
               "instructions": [{"address": "0x1020", "text": "RET"}]},
              {"entry": "0x1040", "name": "LongJump", "c": "Named = 1;",
               "c_spans": [[0, 5, "local"]],
               "library_kind": "edk2", "review_level": "library", "review_gaps": [],
               "instructions": [{"address": "0x1040", "text": "RET"}]}
            ]}
            """
        try ContentStore(root: directory).putAnalysis(module: module, recipe: recipe,
                                                      artifact: Data(artifact.utf8))
        let tool = try query(readings())
        let answer = try await tool.run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("functions")])))
        guard case .json(.object(let body)) = answer,
              let library = body["library"]?.objectValue,
              let below = library["below_bar"]?.objectValue,
              let rows = body["functions"]?.arrayValue else {
            return XCTFail("no library block: \(answer)")
        }
        XCTAssertEqual(rows.first?["temporaries"], .array([.string("uVar1")]))
        XCTAssertEqual(rows.last?["temporaries"], .array([]))
        XCTAssertEqual(library["with_temporaries"], .int(1))
        XCTAssertEqual(below["locals"], .int(0), "reported, and bars nothing")
    }

    /// `live` and `unpublished_writes`: the stored analysis is not the live
    /// program, and the answer says when an owner holds writes it has not
    /// got — the trap of reading a publish-old C after an apply.
    func testTheQuerySaysWhenTheStoredAnalysisIsBehindTheLiveProgram() async throws {
        try ContentStore(root: directory).putAnalysis(module: module, recipe: recipe,
                                                      artifact: Data(Self.artifact.utf8))
        let open = readings()
        open.liveState = { _ in true }
        let behind = try await query(open).run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex), "what": .string("c"),
            "function": .string("entry")])))
        guard case .json(.object(let body)) = behind else { return XCTFail("not an object: \(behind)") }
        XCTAssertEqual(body["live"], .bool(true))
        XCTAssertEqual(body["unpublished_writes"], .bool(true))
        XCTAssertNotNil(body["unpublished_note"])

        let current = readings()
        current.liveState = { _ in false }
        let saved = try await query(current).run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex)])))
        guard case .json(.object(let savedBody)) = saved else { return XCTFail("not an object: \(saved)") }
        XCTAssertEqual(savedBody["live"], .bool(true))
        XCTAssertEqual(savedBody["unpublished_writes"], .bool(false))
        XCTAssertNil(savedBody["unpublished_note"])
        XCTAssertNotNil(savedBody["library"], "the registry block is still there")

        let closed = readings()
        closed.liveState = { _ in nil }
        let noOwner = try await query(closed).run(AgentCall(tool: "code_query", arguments: AgentArguments([
            "module": .string(module.sha256.hex)])))
        guard case .json(.object(let closedBody)) = noOwner else { return XCTFail("not an object: \(noOwner)") }
        XCTAssertEqual(closedBody["live"], .bool(false))
        XCTAssertNil(closedBody["unpublished_writes"], "nothing is open, nothing is behind")
    }

    func testAModuleTheStoreHasNothingForIsRefusedByName() async throws {
        _ = try ContentStore(root: directory)
        let other = SHA256Digest(data: Data("other".utf8)).hex
        do {
            _ = try await query(readings()).run(AgentCall(tool: "code_query", arguments: AgentArguments([
                "module": .string(other)])))
            XCTFail("read an analysis the store has not got")
        } catch let error as AgentToolError {
            XCTAssertEqual(error.message, "The store has no readable analysis of module \(other).")
        }
    }

    /// The library registry: its entries narrowed by kind and name, and one
    /// entry with its review and its history.
    func testTheLibraryRegistryListsEntriesAndOpensOne() async throws {
        let store = try ContentStore(root: directory)
        func proposal(_ name: String, _ kind: String, _ specific: String) throws -> LibraryProposal {
            let entry = try JSONSerialization.data(withJSONObject: ["name": name, "plate": "evidence"],
                                                   options: .sortedKeys)
            return LibraryProposal(body: LibraryBody(size: 0x20, full: "00112233445566aa", specific: specific),
                                   name: name, kind: kind, address: "0x1000", entry: entry)
        }
        try store.putLibraryEntries(module: module.sha256, rev: 3, by: "agent", proposals: [
            try proposal("SetMem", "edk2", "0000000000000001"),
            try proposal("LibAmdIoWrite", "amd", "0000000000000002")
        ])
        let tool = try XCTUnwrap(readings().tools().first { $0.name == "library_registry" })

        let amd = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(["kind": "amd"])))
        guard case .json(.object(let list)) = amd else { return XCTFail("not an object: \(amd)") }
        XCTAssertEqual(list["total"], .int(1))
        let first = try XCTUnwrap(list["entries"]?.arrayValue?.first)
        XCTAssertEqual(first["name"]?.stringValue, "LibAmdIoWrite")
        XCTAssertEqual(first["source"]?["module"]?.stringValue, module.sha256.hex)

        let id = try XCTUnwrap(first["id"]?.stringValue)
        let one = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(["id": .string(id)])))
        guard case .json(.object(let entry)) = one else { return XCTFail("not an object: \(one)") }
        XCTAssertEqual(entry["review"]?["plate"]?.stringValue, "evidence")
        XCTAssertEqual(entry["history"]?.arrayValue?.count, 1)

        do {
            _ = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(["id": "nothing"])))
            XCTFail("opened an entry the registry has not got")
        } catch is AgentToolError {}
    }

    /// An entry with a recorded function stays readable: the answer has its C
    /// and sizes for the bulk, which is read apart a page at a time, and the
    /// lists are narrowed and paged beside it.
    func testALargeRecordedFunctionIsReadInParts() async throws {
        let store = try ContentStore(root: directory)
        let instructions = (0..<500).map { ["address": "0x\(String($0, radix: 16))", "text": String(repeating: "x", count: 200)] }
        let entry = try JSONSerialization.data(withJSONObject: [
            "name": "LargeOne", "plate": "evidence",
            "function": ["name": "LargeOne", "c": "void LargeOne(void) {}", "instructions": instructions,
                         "c_spans": [[1, 2, "comment"]]]
        ], options: .sortedKeys)
        try store.putLibraryEntries(module: module.sha256, rev: 3, by: "agent", proposals: [
            LibraryProposal(body: LibraryBody(size: 0x20, full: "00112233445566aa", specific: "0000000000000001"),
                            name: "LargeOne", kind: "edk2", address: "0x1000", entry: entry)
        ])
        let tool = try XCTUnwrap(readings().tools().first { $0.name == "library_registry" })
        func run(_ values: [String: JSONValue]) async throws -> JSONValue {
            let answer = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(values, answerBound: 24 << 10)))
            guard case .json(let json) = answer else { throw AgentToolError("not json") }
            return json
        }
        let id = "20-00112233445566aa-0000000000000001"
        let whole = try await run(["id": .string(id)])
        XCTAssertLessThan(whole.encoded().count, 24 << 10)
        XCTAssertEqual(whole["review"]?["function"]?["c"]?.stringValue, "void LargeOne(void) {}")
        XCTAssertNil(whole["review"]?["function"]?["instructions"])
        XCTAssertEqual(whole["function_parts"]?["instructions"]?["items"], .int(500))

        var read = 0
        var after: String?
        repeat {
            var values: [String: JSONValue] = ["id": .string(id), "part": "instructions", "limit": .int(1000)]
            if let after { values["after"] = .string(after) }
            let page = try await run(values)
            XCTAssertLessThanOrEqual(page.encoded().count, 24 << 10)
            read += page["items"]?.arrayValue?.count ?? 0
            after = page["next"]?.stringValue
        } while after != nil
        XCTAssertEqual(read, 500)
        do {
            _ = try await run(["part": "instructions"])
            XCTFail("read a part of no entry")
        } catch is AgentToolError {}
    }

    /// A body taken out reads with its version and history, and a filtered
    /// list carries only what it matches, the rest as totals.
    func testTheRegistryListsNarrowAndATakenOutEntryKeepsItsHistory() async throws {
        let store = try ContentStore(root: directory)
        func proposal(_ name: String, _ specific: String) throws -> LibraryProposal {
            LibraryProposal(body: LibraryBody(size: 0x20, full: "00112233445566aa", specific: specific), name: name,
                            kind: "edk2", address: "0x1000",
                            entry: try JSONSerialization.data(withJSONObject: ["name": name, "plate": "evidence"], options: .sortedKeys))
        }
        try store.putLibraryEntries(module: module.sha256, rev: 3, by: "agent", proposals: [
            try proposal("GoneOne", "0000000000000001"), try proposal("KeptOne", "0000000000000002")
        ])
        let gone = "20-00112233445566aa-0000000000000001"
        let kept = "20-00112233445566aa-0000000000000002"
        _ = try store.changeLibrary(LibraryChange(action: .takeOut, id: gone, reason: "reads module data"), by: "agent")
        _ = try store.changeLibrary(LibraryChange(action: .cite, id: kept, file: "a.c", line: 7), by: "agent")
        let tool = try XCTUnwrap(readings().tools().first { $0.name == "library_registry" })
        func run(_ values: [String: JSONValue]) async throws -> JSONValue {
            guard case .json(let json) = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(values))) else {
                throw AgentToolError("not json")
            }
            return json
        }
        let plain = try await run([:])
        XCTAssertEqual(plain["entries"]?.arrayValue?.count, 1)
        XCTAssertNil(plain["taken_out"])
        XCTAssertEqual(plain["taken_out_total"], .int(1))
        XCTAssertEqual(plain["sources_total"], .int(1))

        let out = try await run(["show": "taken_out"])
        XCTAssertEqual(out["taken_out"]?.arrayValue?.first?["reason"]?.stringValue, "reads module data")
        let cited = try await run(["show": "sources", "search": "kept"])
        XCTAssertEqual(cited["sources"]?.arrayValue?.first?["citations"]?.arrayValue?.first?["line"], .int(7))
        let narrow = try await run(["search": "kept"])
        XCTAssertEqual(narrow["taken_out_total"], .int(0))
        let noCitation = try await run(["show": "sources", "search": "gone"])
        XCTAssertEqual(noCitation["sources"]?.arrayValue?.count, 0)

        let entry = try await run(["id": .string(gone)])
        XCTAssertEqual(entry["name"]?.stringValue, "GoneOne")
        XCTAssertNotNil(entry["version"])
        XCTAssertGreaterThan(entry["history"]?.arrayValue?.count ?? 0, 0)
    }

    /// A document that is not a module's code and has no `node` given is
    /// refused in the host's words — the app's name its Code panel, the
    /// server's name nothing.
    func testADocumentWithoutANodeIsRefusedInTheHostsWords() async throws {
        let tool = try query(readings([Document("d1", "a.bin")]))
        do {
            _ = try await tool.run(AgentCall(tool: "code_query",
                                             arguments: AgentArguments(["document": "d1"])))
            XCTFail("answered about a document with no node")
        } catch let error as AgentToolError {
            XCTAssertEqual(error.message, "a.bin (d1) is not a Code panel.")
        }
    }
}

private struct Document: AgentDocument {
    let id: String
    let label: String
    var disk: String?

    init(_ id: String, _ label: String, disk: String? = nil) {
        self.id = id
        self.label = label
        self.disk = disk
    }

    @MainActor func readHost() -> any ToolReadHost { Host(fileName: label) }
}

@MainActor
private final class Documents: AgentDocumentSet {
    let list: [Document]
    init(_ list: [Document]) { self.list = list }
    func documents() -> [any AgentDocument] { list }
    func resolve(_ document: String?) throws -> any AgentDocument {
        try AgentDocumentRule.resolve(document, in: list, noneOpen: "Nothing is open here.")
    }
}

@MainActor
private final class Host: ToolReadHost {
    let fileName: String
    init(fileName: String) { self.fileName = fileName }
    var contentSize: UInt64 { 0 }
    func read(_ range: Range<UInt64>) throws -> [UInt8] { [] }
    func snapshot() throws -> any ToolContentReader { throw AgentToolError("no bytes") }
}

private struct NoGhidra: GhidraBackend {
    func listModules() async throws -> Data { Data() }
    func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data { Data() }
    func openModule(_ module: SHA256Digest) async throws -> Data { Data() }
    func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data { Data() }
    func previewCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data { Data() }
    func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data { Data() }
    func publishModule(_ module: SHA256Digest, by: String, options: GhidraHost.PublishOptions) async throws -> Data { Data() }
    func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data { Data() }
    func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data { Data() }
    func library(_ module: SHA256Digest, _ request: GhidraHost.LibraryRequest) async throws -> Data { Data() }
}
