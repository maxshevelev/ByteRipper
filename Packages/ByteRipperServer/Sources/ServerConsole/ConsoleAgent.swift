import AgentKit
import Foundation

/// How an agent's MCP client reaches this server (`Design/SERVER_HEADLESS_PLAN.md`
/// §7): the relay's command and the client configuration it belongs in. The
/// console shows both because the two things a client on this Mac cannot guess
/// are the socket's path and this binary's path — the server knows both.
///
/// The clients are the app's own (`AgentClientConfiguration` in Settings ▸
/// Agents): Claude Code, Claude Desktop, Cursor, and any other client's
/// parameters one by one. The server is registered as `byteripper-server`, so
/// it sits beside the app's `byteripper` in one client rather than over it.
public struct ConsoleAgent: Sendable, Equatable {
    /// The name the server is registered under in every client.
    public static let serverName = "byteripper-server"

    /// The local MCP socket the relay connects to.
    public let socket: String
    /// This server's own binary, absolute: the client starts it in `relay`.
    public let binary: String

    public init(socket: String, binary: String) {
        self.socket = socket
        self.binary = binary
    }

    public enum Client: String, CaseIterable, Sendable {
        case claudeCode = "claude-code"
        case claudeDesktop = "claude-desktop"
        case cursor
        /// Any other MCP client: the parameters as a list, for a settings
        /// screen that asks for them one by one.
        case other

        public var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .claudeDesktop: return "Claude Desktop"
            case .cursor: return "Cursor"
            case .other: return "Other client"
            }
        }

        /// Where the text goes, said above it — the app's sentences.
        public var destination: String {
            switch self {
            case .claudeCode:
                return "Run this command once in Terminal. It adds the server to Claude Code for every folder."
            case .claudeDesktop:
                return "Add this to Claude Desktop's configuration file, "
                    + "~/Library/Application Support/Claude/claude_desktop_config.json, and restart Claude Desktop."
            case .cursor:
                return "Add this to Cursor's configuration file, ~/.cursor/mcp.json, for every project — "
                    + "or to .cursor/mcp.json in one project."
            case .other:
                return "Enter these parameters in the client's MCP server settings."
            }
        }

        /// Whether the text is a command, a JSON block or a list of fields:
        /// what the page draws it as.
        var form: String {
            switch self {
            case .claudeCode: return "shell"
            case .claudeDesktop, .cursor: return "json"
            case .other: return "fields"
            }
        }
    }

    /// `<binary> relay --mcp-socket <socket>`, quoted for a shell.
    public var command: String {
        "\(Self.quoted(binary)) relay --mcp-socket \(Self.quoted(socket))"
    }

    /// The text for `client`.
    public func text(for client: Client) -> String {
        switch client {
        case .claudeCode:
            // User scope, as the app's: an operator talks to the server from
            // whatever folder they are in.
            return "claude mcp add --scope user \(Self.serverName) -- \(command)"
        case .claudeDesktop, .cursor:
            // The two read the same block. A file that already lists servers
            // takes the inner entry beside them.
            return """
                {
                  "mcpServers": {
                    "\(Self.serverName)": {
                      "command": \(Self.jsonQuoted(binary)),
                      "args": ["relay", "--mcp-socket", \(Self.jsonQuoted(socket))]
                    }
                  }
                }
                """
        case .other:
            let rows = fields
            let width = rows.map(\.0.count).max() ?? 0
            return rows.map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
                .joined(separator: "\n")
        }
    }

    /// Another client's parameters, one by one.
    var fields: [(String, String)] {
        [
            ("Name", Self.serverName),
            ("Transport", "stdio"),
            ("Command", binary),
            ("Arguments", "relay --mcp-socket \(Self.quoted(socket))"),
            ("Environment", "none")
        ]
    }

    func json() -> JSONValue {
        [
            "socket": .string(socket),
            "binary": .string(binary),
            "command": .string(command),
            "server_name": .string(Self.serverName),
            "clients": .array(Client.allCases.map { client in
                var members: [String: JSONValue] = [
                    "id": .string(client.rawValue),
                    "title": .string(client.title),
                    "destination": .string(client.destination),
                    "form": .string(client.form),
                    "text": .string(text(for: client))
                ]
                if client == .other {
                    members["fields"] = .array(fields.map { ["name": .string($0.0), "value": .string($0.1)] })
                }
                return .object(members)
            })
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
