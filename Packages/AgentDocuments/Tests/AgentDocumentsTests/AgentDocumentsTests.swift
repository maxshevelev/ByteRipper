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
        XCTAssertEqual(members["module"]?.stringValue, "CpuPei")
        XCTAssertEqual(members["sha256"]?.stringValue, module.sha256.hex)
        XCTAssertEqual(members["recipe"]?.stringValue, recipe.id)
        XCTAssertEqual(members["functions"]?.arrayValue?.first?["name"]?.stringValue, "entry")
        XCTAssertNil(members["document"], "no document was named")
        XCTAssertNil(members["disk"])
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
    func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data { Data() }
    func publishModule(_ module: SHA256Digest, by: String, takeTypeConflicts: Bool) async throws -> Data { Data() }
    func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data { Data() }
}
