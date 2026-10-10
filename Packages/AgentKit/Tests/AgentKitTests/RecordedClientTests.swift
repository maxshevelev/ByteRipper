import XCTest
@testable import AgentKit

/// What a real client sends, recorded off the relay and played back
/// (`Design/AGENT_PLAN.md`, stage 2): Claude Code 2.1.292 against the app's
/// first four tools. It speaks the modern era — `server/discover` first, then
/// `_meta` on every request, with a key of its own (`claudecode/toolUseId`)
/// and a progress token on each call.
///
/// The test that earns its place here is the first one: this client
/// validates the answer to `tools/list`, and one without `ttlMs` and
/// `cacheScope` left it with no tools at all while every hand-written
/// transcript passed.
final class RecordedClientTests: XCTestCase {
    private static let claudeCode = [
        #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.292","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}}}}}"#,
        #"{"method":"tools/list","jsonrpc":"2.0","id":0,"params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.292","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}}}}}"#,
        #"{"method":"tools/call","params":{"name":"documents","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.292","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"claudecode/toolUseId":"toolu_01DguNc98zmrUdUQuFHn4ws8","progressToken":1}},"jsonrpc":"2.0","id":1}"#,
        #"{"method":"tools/call","params":{"name":"read","arguments":{"offset":"0x0","length":16,"format":"ascii"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.292","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"claudecode/toolUseId":"toolu_01ANfKDh9HV2RTKhoohMNEpx","progressToken":2}},"jsonrpc":"2.0","id":2}"#,
        #"{"method":"tools/call","params":{"name":"reveal","arguments":{"offset":"0x10","length":"0x10"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.292","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"claudecode/toolUseId":"toolu_01MrUnVX15Q67jQmxNjtWkUr","progressToken":3}},"jsonrpc":"2.0","id":3}"#,
    ]

    private func stub(_ name: String) -> AgentTool {
        AgentTool(name: name, description: "Stands in for the app's own.", inputSchema: AgentSchema.object([
            "offset": AgentSchema.offset("Where."),
            "length": AgentSchema.offset("How much."),
            "format": AgentSchema.string("As what.")
        ])) { call in
            .json(["tool": .string(call.tool), "length": call.arguments["length"] ?? .null])
        }
    }

    private func play() async throws -> [JSONValue] {
        let output = Output()
        let server = AgentServer(
            info: AgentServerInfo(name: "byteripper", version: "0.9.1"),
            tools: ["documents", "focus", "read", "reveal"].map(stub))
        let connection = AgentConnection(server: server, send: { output.append($0) })
        for line in Self.claudeCode {
            await connection.receive(Data((line + "\n").utf8))
        }
        await connection.waitUntilIdle()
        return try output.lines.map { try JSONValue.parse(Data($0.utf8)) }
    }

    func testEveryRequestIsAnsweredAsTheModernEraRequires() async throws {
        let replies = try await play()
        XCTAssertEqual(replies.map { $0["id"] }, ["server-discover-probe-1", 0, 1, 2, 3])
        for reply in replies {
            XCTAssertNil(reply["error"], "\(reply)")
            XCTAssertEqual(reply["result"]?["resultType"], "complete")
            XCTAssertEqual(reply["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], "byteripper")
        }
    }

    func testTheDiscoveryAndTheListCarryTheCacheHintsThisClientRequires() async throws {
        let replies = try await play()
        for reply in replies.prefix(2) {
            XCTAssertNotNil(reply["result"]?["ttlMs"]?.int64Value, "\(reply)")
            XCTAssertNotNil(reply["result"]?["cacheScope"]?.stringValue, "\(reply)")
        }
        XCTAssertEqual(replies[1]["result"]?["tools"]?.arrayValue?.count, 4)
    }

    /// The model wrote a length in hex, as a string — which is why every
    /// address argument takes one.
    func testTheCallsReachTheToolsWithTheirArgumentsAsWritten() async throws {
        let replies = try await play()
        let texts = replies.suffix(3).compactMap { $0["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue }
        XCTAssertEqual(texts, [
            #"{"length":null,"tool":"documents"}"#,
            #"{"length":16,"tool":"read"}"#,
            #"{"length":"0x10","tool":"reveal"}"#
        ])
    }
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) { lock.withLock { buffer.append(data) } }

    var lines: [String] {
        lock.withLock { String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init) }
    }
}
