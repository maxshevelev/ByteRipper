import AgentKit
import Foundation

/// How an agent's MCP client reaches this server (`Design/SERVER_HEADLESS_PLAN.md`
/// §7): the relay's command and the client configuration it belongs in. The
/// console shows both because the two things a client on this Mac cannot guess
/// are the socket's path and this binary's path — the server knows both.
public struct ConsoleAgent: Sendable, Equatable {
    /// The local MCP socket the relay connects to.
    public let socket: String
    /// This server's own binary, absolute: the client starts it in `relay`.
    public let binary: String

    public init(socket: String, binary: String) {
        self.socket = socket
        self.binary = binary
    }

    /// `<binary> relay --mcp-socket <socket>`, quoted for a shell.
    public var command: String {
        "\(Self.quoted(binary)) relay --mcp-socket \(Self.quoted(socket))"
    }

    /// The line that adds the server to Claude Code.
    public var claudeCommand: String { "claude mcp add byteripper -- \(command)" }

    /// The `mcpServers` object for `.mcp.json` or Claude Desktop's own file.
    public var config: String {
        """
        {
          "mcpServers": {
            "byteripper": {
              "command": \(Self.jsonQuoted(binary)),
              "args": ["relay", "--mcp-socket", \(Self.jsonQuoted(socket))]
            }
          }
        }
        """
    }

    func json() -> JSONValue {
        [
            "socket": .string(socket),
            "binary": .string(binary),
            "command": .string(command),
            "claude": .string(claudeCommand),
            "config": .string(config)
        ]
    }

    /// A shell word: plain when it can be, single-quoted when it cannot.
    static func quoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        guard text.rangeOfCharacter(from: plain.inverted) != nil else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A JSON string literal, quotes included. The slashes are left as they
    /// are — a path is not a place a reader wants `\/`.
    static func jsonQuoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
