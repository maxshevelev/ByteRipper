import AgentKit
import Foundation
import HTTPService

/// MCP over HTTP at `/mcp` — the Streamable HTTP transport, one JSON-RPC
/// message per `POST`, answered with one JSON message.
///
/// The protocol itself is `AgentKit`'s, the one the app serves over its
/// socket. Each request gets a connection of its own for as long as it runs:
/// a modern client (`2026-07-28`) holds nothing between requests, and a
/// legacy one is served without its handshake, which `AgentConnection`
/// allows — so the server keeps no sessions. Progress notifications are not
/// streamed; a call answers when it is done. `GET` is refused: the server
/// sends nothing unasked.
enum MCPEndpoint {
    static let path = "/mcp"

    static func routes(server: AgentServer, log: @escaping @Sendable (String) -> Void) -> HTTPRouter {
        var router = HTTPRouter()
        // Its tools reach Ghidra and publish into the store: the rights of
        // both, until the endpoint goes (`Design/SERVER_HEADLESS_PLAN.md` §9).
        router.add("POST", path, access: .rights([.ghidraUse, .casWrite])) { request in
            guard let message = try? JSONValue.parse(request.body) else {
                return rpcError(-32700, "Parse error")
            }
            let id = message["id"]
            let lines = Lines()
            let connection = AgentConnection(server: server, send: { lines.add($0) }, observer: { record in
                log("mcp \(record.tool) \(record.outcome)")
            })
            var line = request.body
            line.append(0x0A)
            await connection.receive(line)
            await connection.waitUntilIdle()
            await connection.close()
            guard let id, id != .null else {
                // A notification: nothing to answer.
                return HTTPResponse(HTTPStatus(202, "Accepted"))
            }
            let answer = lines.all.compactMap { try? JSONValue.parse($0) }.first { $0["id"] == id }
                ?? lines.all.compactMap { try? JSONValue.parse($0) }.first { $0["id"] == .null && $0["error"] != nil }
            guard let answer else { return rpcError(-32603, "No answer", id: id) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: answer.encoded())
        }
        router.add("GET", path) { _ in
            throw HTTPError(.methodNotAllowed, "this server sends nothing unasked: POST a JSON-RPC message")
        }
        return router
    }

    static func rpcError(_ code: Int64, _ message: String, id: JSONValue = .null) -> HTTPResponse {
        let value: JSONValue = ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
        return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: value.encoded())
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func add(_ line: Data) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return lines }
    }
}
