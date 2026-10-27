import AgentKit
import CodeAnalysis
import Foundation
import GhidraHost
import HTTPService
import XCTest
@testable import ByteRipperServer

/// `/mcp` over a backend that answers from memory: the protocol and the
/// tools' wiring, without Ghidra.
final class MCPEndpointTests: XCTestCase {
    struct FakeBackend: GhidraBackend {
        let writes = Calls()

        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(String, Data)] = []
            func add(_ call: String, _ body: Data) { lock.lock(); items.append((call, body)); lock.unlock() }
            var all: [(String, Data)] { lock.lock(); defer { lock.unlock() }; return items }
        }

        func listModules() async throws -> Data { Data(#"[{"module":"ab","name":"M"}]"#.utf8) }
        func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data {
            Data(#"{"opened":"\#(name)","bytes":\#(image.count)}"#.utf8)
        }
        func openModule(_ module: SHA256Digest) async throws -> Data { Data(#"{"functions":13}"#.utf8) }
        func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data {
            Data(#"{"call":"\#(call)","limit":"\#(query["limit"] ?? "")"}"#.utf8)
        }
        func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
            writes.add(call, body)
            if call == "rename/function" { throw GhidraHostError(.refused, "Ghidra would name it Foo_1", status: 409) }
            return Data("{}".utf8)
        }
        func publishModule(_ module: SHA256Digest, by: String) async throws -> Data { Data(#"{"type_conflicts":[]}"#.utf8) }
        func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data { Data(#"{"type_conflicts":[]}"#.utf8) }
    }

    private let module = String(repeating: "ab", count: 32)
    private var server: HTTPServer!
    private var base: URL!
    private let backend = FakeBackend()

    override func setUp() async throws {
        let agent = AgentServer(info: AgentServerInfo(name: "test", version: "1"),
                                instructions: GhidraTools.instructions,
                                tools: GhidraTools.tools(backend: backend))
        server = HTTPServer(configuration: .init(port: 0), router: MCPEndpoint.routes(server: agent, log: { _ in }))
        base = URL(string: "http://127.0.0.1:\(try await server.start())/mcp")!
    }

    override func tearDown() async throws { server.stop() }

    private func post(_ message: JSONValue) async throws -> (Int, JSONValue?) {
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.httpBody = message.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONValue.parse(data))
    }

    private var meta: JSONValue {
        ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
         "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
         "io.modelcontextprotocol/clientCapabilities": [:]]
    }

    private func call(_ id: Int64, _ tool: String, _ arguments: JSONValue) async throws -> JSONValue {
        let (_, answer) = try await post(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                          "params": ["name": .string(tool), "arguments": arguments, "_meta": meta]])
        return try XCTUnwrap(answer?["result"])
    }

    func testToolsAreListedAndCalledOverHTTP() async throws {
        let (status, listed) = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list",
                                               "params": ["_meta": meta]])
        XCTAssertEqual(status, 200)
        let names = listed?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("ghidra_rename_variable"), "\(names)")
        XCTAssertEqual(names.count, 21)

        _ = try await call(7, "ghidra_describe", ["module": .string(module), "section": "Flow", "text": "1. Entry."])
        let sent = try XCTUnwrap(backend.writes.all.last { $0.0 == "set/description" }?.1)
        let body = try JSONSerialization.jsonObject(with: sent) as? [String: String]
        XCTAssertEqual(body, ["section": "Flow", "text": "1. Entry."])

        let read = try await call(2, "ghidra_functions", ["module": .string(module), "limit": 5])
        let text = read["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains(#""call":"functions""#) && text.contains(#""limit":"5""#), text)

        let type = try await call(6, "ghidra_type_definition", ["module": .string(module), "name": "AMD_APOB_HEADER"])
        XCTAssertTrue(type["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(#""call":"type""#) == true)

        let opened = try await call(3, "ghidra_open", ["image_base64": .string(Data([1, 2, 3]).base64EncodedString()),
                                                       "name": "M"])
        XCTAssertTrue(opened["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(#""bytes":3"#) == true)
    }

    func testARefusalIsAToolErrorTheModelReads() async throws {
        let refused = try await call(4, "ghidra_rename", ["module": .string(module), "address": "0x10", "name": "Foo"])
        XCTAssertEqual(refused["isError"], true)
        XCTAssertEqual(refused["content"]?.arrayValue?.first?["text"]?.stringValue, "Ghidra would name it Foo_1")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(backend.writes.all.first?.1)) as? [String: Any]
        XCTAssertEqual(body?["by"] as? String, "agent", "a rename says who made it")

        let unknown = try await call(5, "ghidra_type", ["module": .string(module), "c": "typedef int X;", "bogus": 1])
        XCTAssertEqual(unknown["isError"], true)
    }

    /// A signature can say where each parameter and the result are, for a
    /// function no calling convention fits; the places reach the owner as a
    /// list, and anything but strings is refused.
    func testASignatureCarriesItsStorage() async throws {
        _ = try await call(7, "ghidra_signature", [
            "module": .string(module), "address": "0x9A18526",
            "signature": "VOID GetPstateFrequencyMHz(UINT64 *FrequencyMHz, UINT32 Pstate)",
            "storage": ["ECX:4", "Stack[0x4]:4"], "return_storage": "void"])
        let sent = try XCTUnwrap(backend.writes.all.last { $0.0 == "set/signature" }?.1)
        let body = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        XCTAssertEqual(body?["storage"] as? [String], ["ECX:4", "Stack[0x4]:4"])
        XCTAssertEqual(body?["return_storage"] as? String, "void")

        let wrong = try await call(8, "ghidra_signature", [
            "module": .string(module), "address": "0x10", "signature": "VOID F(UINT32 A)", "storage": [4]])
        XCTAssertEqual(wrong["isError"], true)
    }

    /// A range read as 16-bit code reaches the owner with its size as a
    /// number; any other size is refused before it gets there.
    func testACodeModeCarriesItsRangeAndSize() async throws {
        _ = try await call(9, "ghidra_code_mode", [
            "module": .string(module), "start": "0x9DFE6E0", "end": "0x9DFE7D0", "bits": 16,
            "reason": "reset vector, real mode"])
        let sent = try XCTUnwrap(backend.writes.all.last { $0.0 == "set/code-mode" }?.1)
        let body = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        XCTAssertEqual(body?["start"] as? String, "0x9DFE6E0")
        XCTAssertEqual(body?["end"] as? String, "0x9DFE7D0")
        XCTAssertEqual(body?["bits"] as? Int, 16)

        let wrong = try await call(10, "ghidra_code_mode", [
            "module": .string(module), "start": "0x10", "end": "0x20", "bits": 64])
        XCTAssertEqual(wrong["isError"], true)
    }

    func testALegacyClientAndANotification() async throws {
        let (_, hello) = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                    "clientInfo": ["name": "old", "version": "1"]]])
        XCTAssertNotNil(hello?["result"]?["instructions"]?.stringValue)
        let (status, _) = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(status, 202)
    }
}
