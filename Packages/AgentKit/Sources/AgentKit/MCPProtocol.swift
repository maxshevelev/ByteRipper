import Foundation

/// The versions of the Model Context Protocol this server speaks, and the
/// error codes it answers with.
///
/// MCP changed shape in `2026-07-28`. Before it, a connection opened with an
/// `initialize` handshake that fixed the version and the client's capabilities
/// for as long as the connection lasted — the *legacy* era. From it, there is
/// no handshake: every request carries its version and the client's
/// capabilities in `_meta`, and the server holds nothing between requests —
/// the *modern* era. Clients of both kinds are in use at once, so this server
/// speaks both, as the specification allows ("dual-era"): a request with the
/// modern `_meta` is served as modern, an `initialize` starts a legacy
/// connection.
public enum MCPProtocol {
    /// The modern versions, newest first.
    public static let modernVersions = ["2026-07-28"]
    /// The handshake versions, newest first. What a tool call looks like did
    /// not change across them in any way the tools here depend on.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }

    /// How long a client may keep the answer to `server/discover` and
    /// `tools/list` before asking again. The list is fixed while the app runs;
    /// five minutes is so that a newer build of the app, started under a client
    /// that stayed open, is listed without the client having to be restarted.
    public static let listTTLMilliseconds: Int64 = 300_000

    /// The `_meta` keys of a modern request.
    enum Meta {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientInfo = "io.modelcontextprotocol/clientInfo"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
        static let progressToken = "progressToken"
    }

    /// JSON-RPC's own codes, and the one MCP code this server sends.
    public enum ErrorCode {
        public static let parseError: Int64 = -32700
        public static let invalidRequest: Int64 = -32600
        public static let methodNotFound: Int64 = -32601
        public static let invalidParams: Int64 = -32602
        public static let internalError: Int64 = -32603
        /// Modern only: the request names a version this server does not
        /// speak. `data` lists the ones it does.
        public static let unsupportedProtocolVersion: Int64 = -32022
    }
}

/// Which era a request is served in.
enum MCPEra: Equatable, Sendable {
    case modern(version: String)
    case legacy(version: String)
}

/// Who the server says it is, in `initialize`, in `server/discover`, and in
/// the `_meta` of every modern answer.
public struct AgentServerInfo: Equatable, Sendable {
    public var name: String
    public var version: String
    public var title: String?

    public init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }

    var json: JSONValue {
        var members: [String: JSONValue] = ["name": .string(name), "version": .string(version)]
        if let title { members["title"] = .string(title) }
        return .object(members)
    }
}

/// A JSON-RPC error answer, before it is written.
struct RPCError: Error, Equatable {
    let code: Int64
    let message: String
    var data: JSONValue?

    var json: JSONValue {
        var members: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { members["data"] = data }
        return .object(members)
    }

    static func invalidParams(_ message: String) -> RPCError {
        RPCError(code: MCPProtocol.ErrorCode.invalidParams, message: message)
    }
}

/// The messages the server writes.
enum RPCMessage {
    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, _ error: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": error.json]
    }

    static func notification(_ method: String, _ params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": .string(method), "params": params]
    }
}
