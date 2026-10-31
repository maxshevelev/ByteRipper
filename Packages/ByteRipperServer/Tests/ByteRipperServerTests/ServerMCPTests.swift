import AgentDocuments
import AgentKit
import CodeAnalysis
import DumpHost
import Foundation
import GhidraHost
@testable import ServerMCP
import ServerRelay
import XCTest
@testable import ByteRipperServer

/// The local MCP the server serves (`Design/SERVER_HEADLESS_PLAN.md` §7): the
/// list an agent gets, the answers over a synthetic image, the socket a
/// client reaches it on, and the relay that carries stdio there.
@MainActor
final class ServerMCPTests: XCTestCase {
    private var directory: URL!
    private var registry: DocumentRegistry!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerMCPTests-\(UUID().uuidString)", isDirectory: true)
        let roots = directory.appendingPathComponent("dumps", isDirectory: true)
        try FileManager.default.createDirectory(at: roots, withIntermediateDirectories: true)
        let url = roots.appendingPathComponent("board.bin")
        try SyntheticDump.image().write(to: url)
        registry = DocumentRegistry(roots: [roots], uploads: directory.appendingPathComponent("Uploads"),
                                    file: directory.appendingPathComponent("documents.json"))
        try await registry.restore()
        try await registry.open(path: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func tools(ghidra: GhidraBackend? = nil) -> [AgentTool] {
        ServerTools.all(documents: registry, store: directory.appendingPathComponent("store"), ghidra: ghidra)
    }

    private func tool(_ name: String, _ tools: [AgentTool]) throws -> AgentTool {
        try XCTUnwrap(tools.first { $0.name == name })
    }

    /// What the server serves, and what it must not: a tool that acts on a
    /// screen or edits a dump is not here (decision 7).
    func testTheToolListIsTheServersAndNothingElse() throws {
        let tools = tools()
        let names = tools.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "two tools of one name")
        for forbidden in ["annotate", "annotations", "remove_annotations", "reveal", "focus", "show",
                          "write", "update_in_parent", "open_panel", "open_code", "open_part",
                          "uefi_select", "uefi_selection", "compare", "reveal_diff", "uefi_fix_checksum",
                          "fit_fix_checksum", "fit_add_microcode", "survey",
                          "open_dump", "close_dump", "copy_to_other_pane",
                          // The next stage, with ME and FIT (decision 15).
                          "region_scan", "microcode_catalogue"] {
            XCTAssertFalse(names.contains(forbidden), "\(forbidden) is in the server's list")
        }
        for required in ["documents", "read", "find_bytes", "uefi_tree", "uefi_node", "uefi_find",
                         "uefi_node_data", "code_query", "code_modules"] {
            XCTAssertTrue(names.contains(required), "\(required) is not in the server's list")
        }
        XCTAssertFalse(names.contains("ghidra_publish"), "no Ghidra role, no Ghidra tools")
        XCTAssertFalse(names.contains("ghidra_open"))
    }

    /// With Ghidra, its review tools are there — one `ghidra_open`, the one by
    /// a node, and the list pins the document rule in its words.
    func testWithGhidraTheReviewToolsAreThere() throws {
        let tools = tools(ghidra: NoGhidra())
        let names = tools.map(\.name)
        XCTAssertEqual(names.filter { $0 == "ghidra_open" }.count, 1)
        XCTAssertTrue(names.contains("ghidra_publish"))
        let open = try tool("ghidra_open", tools)
        XCTAssertNil(open.inputSchema["properties"]?["image"])
        XCTAssertNotNil(open.inputSchema["properties"]?["node"])
        XCTAssertEqual(names.count, Set(names).count)
    }

    /// The keys `documents` answers with, as the plan pins them: no caller
    /// here sees a pane's `slot`, `tab` or `focused`.
    func testDocumentsCarriesTheServersKeys() async throws {
        let answer = try await tool("documents", tools())
            .run(AgentCall(tool: "documents", arguments: AgentArguments([:])))
        guard case .json(.object(let members)) = answer else { return XCTFail("not an object: \(answer)") }
        let entry = try XCTUnwrap(members["documents"]?.arrayValue?.first)
        XCTAssertEqual(entry["id"]?.stringValue, "d1")
        XCTAssertEqual(entry["name"]?.stringValue, "board.bin")
        XCTAssertEqual(entry["size"]?.stringValue, "0x1000")
        XCTAssertEqual(entry["version"], .count(1))
        XCTAssertNotNil(entry["link"]?.stringValue, "a file on disk is linked")
        XCTAssertNil(entry["disk"], "the file is the one read")
        for absent in ["slot", "focused", "tab", "part_of"] {
            XCTAssertNil(entry[absent], absent)
        }
    }

    /// The tree of the synthetic image, and its bytes, read through the same
    /// answer a query gives.
    func testTheTreeAndTheBytesAnswer() async throws {
        let tools = self.tools()
        let tree = try await tool("uefi_tree", tools)
            .run(AgentCall(tool: "uefi_tree", arguments: AgentArguments(["document": "d1"])))
        guard case .json(.object(let members)) = tree else { return XCTFail("not an object: \(tree)") }
        XCTAssertEqual(members["document"]?.stringValue, "d1")
        XCTAssertEqual(members["image"]?.stringValue, "Volume · FFSv2")
        XCTAssertFalse(members["children"]?.arrayValue?.isEmpty ?? true, "the volume is read: \(tree)")

        let read = try await tool("read", tools).run(AgentCall(
            tool: "read", arguments: AgentArguments(["document": "d1", "offset": "0x0", "length": "16"])))
        guard case .json(.object(let bytes)) = read else { return XCTFail("not an object: \(read)") }
        XCTAssertEqual(bytes["document"]?.stringValue, "d1")
        XCTAssertFalse(bytes["rows"]?.arrayValue?.isEmpty ?? true, "\(read)")
    }

    /// The disk mark reaches an answer that names a document (decision 9):
    /// the snapshot answers on, and says the file is no longer the one read.
    func testTheDiskMarkReachesAnAnswer() async throws {
        let url = try XCTUnwrap(registry.rows.first?.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: SyntheticDump.image(marker: 9))
        try handle.close()

        let read = try await tool("read", tools()).run(AgentCall(
            tool: "read", arguments: AgentArguments(["offset": "0x0", "length": "16"])))
        guard case .json(.object(let bytes)) = read else { return XCTFail("not an object: \(read)") }
        XCTAssertEqual(bytes["disk"]?.stringValue, "changed")
        XCTAssertEqual(bytes["document"]?.stringValue, "d1", "the only open document is implied")
    }

    /// A search of the stored bytes: ascii, utf16le and hex with `??`, paged
    /// by `after`.
    func testFindBytesSearchesTheSnapshot() async throws {
        let tools = self.tools()
        let ascii = try await tool("find_bytes", tools).run(AgentCall(
            tool: "find_bytes", arguments: AgentArguments(["text": "MZ", "encoding": "ascii", "limit": 1])))
        guard case .json(.object(let asciiMembers)) = ascii else { return XCTFail("\(ascii)") }
        XCTAssertEqual(asciiMembers["total"], .count(1))
        XCTAssertEqual(asciiMembers["matches"]?.arrayValue?.first?["encoding"]?.stringValue, "ascii")

        let wide = try await tool("find_bytes", tools).run(AgentCall(
            tool: "find_bytes", arguments: AgentArguments(["text": "MZ", "encoding": "utf16le"])))
        guard case .json(.object(let wideMembers)) = wide else { return XCTFail("\(wide)") }
        XCTAssertEqual(wideMembers["total"], .count(0), "MZ is not stored wide in the stub image")

        let any = try await tool("find_bytes", tools).run(AgentCall(
            tool: "find_bytes", arguments: AgentArguments(["hex": "4D ?? 00 00"])))
        guard case .json(.object(let anyMembers)) = any else { return XCTFail("\(any)") }
        XCTAssertGreaterThanOrEqual(anyMembers["total"]?.int64Value ?? 0, 1, "\(any)")
    }

    /// Paging loses nothing: a match a page stopped before is the next
    /// page's first, and the ASCII and UTF-16LE matches at one address are
    /// two matches, both listed.
    func testFindBytesPagesThroughEveryMatch() async throws {
        var bytes = [UInt8](repeating: 0, count: 64)
        for index in stride(from: 0, to: 64, by: 8) { bytes[index] = 0x41 }
        let url = directory.appendingPathComponent("dumps/pattern.bin")
        try Data(bytes).write(to: url)
        let id = try await registry.open(path: url)
        let find = try tool("find_bytes", tools())

        var seen: [String] = []
        var after: JSONValue?
        var pages = 0
        repeat {
            var arguments: [String: JSONValue] = ["document": .string(id), "text": "A", "limit": 3]
            if let after { arguments["after"] = after }
            let answer = try await find.run(AgentCall(tool: "find_bytes", arguments: AgentArguments(arguments)))
            guard case .json(let value) = answer else { return XCTFail("\(answer)") }
            XCTAssertEqual(value["total"], .count(16), "every A is an ASCII match and a UTF-16LE one")
            seen += (value["matches"]?.arrayValue ?? []).compactMap { match in
                guard let start = match["start"]?.stringValue, let encoding = match["encoding"]?.stringValue else {
                    return nil
                }
                return "\(start) \(encoding)"
            }
            // `JSONValue` takes `nil` as `.null`: the end is said in so many words.
            if let next = value["next"], !next.isNull { after = next } else { after = nil }
            pages += 1
        } while after != nil && pages < 20
        let expected = stride(from: 0, to: 64, by: 8).flatMap { offset in
            ["0x\(String(offset, radix: 16, uppercase: true)) ascii", "0x\(String(offset, radix: 16, uppercase: true)) utf16le"]
        }
        XCTAssertEqual(seen, expected)
    }

    /// No description the server serves sends an agent to what only the app
    /// has: a panel, a part, the focus, a survey, an edit.
    func testNoDescriptionNamesWhatTheServerHasNot() {
        let forbidden = ["survey", "reveal", "open_part", "annotate", "open_panel", "_fix_checksum", "panel",
                         "focus", "unsaved", "`write`", "open_code", "counterpart", "open_dump",
                         // Not served before the next stage (decision 15).
                         "region_scan", "microcode_catalogue"]
        for tool in tools(ghidra: NoGhidra()) {
            for word in forbidden where tool.description.localizedCaseInsensitiveContains(word) {
                XCTFail("\(tool.name) names \(word)")
            }
        }
        // The instructions say there is no focus, which is the point of saying it.
        let instructions = ServerTools.instructions(ghidra: true)
        for word in forbidden where word != "focus" && instructions.localizedCaseInsensitiveContains(word) {
            XCTFail("the instructions name \(word)")
        }
    }

    /// Every rewording is of a query the server serves, and is what it serves:
    /// a query renamed in the module would otherwise bring the panel's text
    /// back without a word.
    func testEveryRewordingIsServed() throws {
        let served = Dictionary(uniqueKeysWithValues: tools().map { ($0.name, $0.description) })
        let queries = Set(ServerTools.queries.map(\.name))
        for (name, text) in ServerToolText.overrides {
            XCTAssertTrue(queries.contains(name), "\(name) is reworded but is no query of the module")
            XCTAssertEqual(served[name], text, "\(name) is not served in the server's words")
        }
    }

    /// The socket the local MCP is served on: a client connects, asks for the
    /// tools, calls one, and is answered.
    func testAClientReachesTheToolsOverTheSocket() async throws {
        // `sun_path` holds 104 bytes: a socket in /tmp, not under the test folder.
        let socket = MCPSocket(path: "/tmp/br-\(UUID().uuidString.prefix(8)).sock",
                               server: AgentServer(info: AgentServerInfo(name: "byteripper-server", version: "1"),
                                                   instructions: ServerTools.instructions(ghidra: false),
                                                   tools: tools(),
                                                   limits: .init(maxLineBytes: 1 << 20, maxAnswerBytes: 96 << 10)))
        try socket.start()
        defer { socket.stop() }

        let fd = try UnixSocket.connect(to: socket.path)
        defer { Darwin.close(fd) }
        let listed = try await Self.ask(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8), at: fd)
        XCTAssertTrue(listed.contains("\"tools\""), listed)
        XCTAssertTrue(listed.contains("uefi_tree"), listed)

        let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"documents","arguments":{}}}"#.utf8)
        let answered = try await Self.ask(call, at: fd)
        XCTAssertTrue(answered.contains("board.bin"), answered)
        // The row is touched on the main actor, after the answer was written.
        for _ in 0..<50 where socket.activity.rows.first?.calls != 1 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(socket.activity.rows.first?.calls, 1, "the connection is a row the console shows")
    }

    /// Sends one message and reads one answer, giving up after a few seconds
    /// so a broken socket fails the test rather than hanging it.
    private static func ask(_ message: Data, at fd: Int32, timeout: TimeInterval = 5) async throws -> String {
        var line = message
        line.append(0x0A)
        XCTAssertTrue(UnixSocket.writeAll(fd, line))
        // A socket hands over what has arrived, not what was sent: the answer
        // is read until one whole line parses.
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = await withTaskGroup(of: Data?.self) { group in
                group.addTask { UnixSocket.readSome(fd) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let chunk else { break }
            data.append(chunk)
            if data.last == 0x0A, (try? JSONValue.parse(data.dropLast())) != nil {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The relay mode starts none of the roles: it copies bytes, and with no
    /// server to copy to it answers every request with the reason.
    func testTheRelayModeStartsNoRole() throws {
        guard case .relay(let path) = try ServerCommand.parse(["relay", "--mcp-socket", "/tmp/x.sock"]) else {
            return XCTFail("not a relay")
        }
        XCTAssertEqual(path, "/tmp/x.sock")
        guard case .relay(let fallback) = try ServerCommand.parse(["relay"]) else { return XCTFail() }
        XCTAssertEqual(fallback, ServerPaths.defaultSocket.path)
    }

    func testTheRelayAnswersWhenNothingListens() throws {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&input), 0)
        XCTAssertEqual(pipe(&output), 0)
        defer {
            Darwin.close(input[0])
            Darwin.close(output[0])
        }
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8) + Data("\n".utf8)
        _ = request.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        Darwin.close(input[1])
        let code = ServerRelay.run(path: "/tmp/no-server-\(UUID().uuidString).sock",
                                   input: input[0], output: output[1])
        Darwin.close(output[1])
        XCTAssertEqual(code, 1)
        let answer = String(decoding: UnixSocket.readSome(output[0]) ?? Data(), as: UTF8.self)
        XCTAssertTrue(answer.contains("\"id\":7"), answer)
        XCTAssertTrue(answer.contains(ServerRelay.unavailable), answer)
    }
}

/// A Ghidra that answers nothing: the list is what is under test.
private struct NoGhidra: GhidraBackend {
    func listModules() async throws -> Data { Data() }
    func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data { Data() }
    func openModule(_ module: SHA256Digest) async throws -> Data { Data() }
    func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data { Data() }
    func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data { Data() }
    func publishModule(_ module: SHA256Digest, by: String, takeTypeConflicts: Bool) async throws -> Data { Data() }
    func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data { Data() }
    func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data { Data() }
}
