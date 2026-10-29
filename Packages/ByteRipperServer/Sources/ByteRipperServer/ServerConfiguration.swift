import CodeAnalysis
import DumpHost
import Foundation
import GhidraHost
import ServerAuth

/// What `byteripper-server` was asked to do, read from its arguments.
public enum ServerCommand: Equatable {
    case serve(ServerConfiguration)
    /// Make, list, rotate or revoke a token of `tokens.json`.
    case token(TokenCommand)
    /// The stdio↔socket bridge an agent's client launches. No role is
    /// started: the process only copies bytes (`ServerRelay`).
    case relay(path: String)
    case help

    public static let usage = """
        usage: byteripper-server [serve] [--cas] [--ghidra] [--listen <host>:<port>]
                                 [--store <dir>] [--tokens <file>]
                                 [--dump-roots <dir>] [--max-documents <n>]
                                 [--max-open-bytes <n>] [--max-upload-bytes <n>] [--mcp-socket <path>]
                                 [--ghidra-home <dir>] [--projects <dir>] [--idle <s>]
               byteripper-server token add --name <name> [--rights <right,…> | --preset <reader|app|admin>]
               byteripper-server token list | rotate <id|name> | revoke <id|name>
               byteripper-server relay [--mcp-socket <path>]

        \(TokenCommand.usage)

          --cas           serve the store alone; the store is served either way,
                          and with neither --cas nor --ghidra both roles are on
          --ghidra        host the Ghidra owners
          --listen        an address to listen on, 127.0.0.1:8765 by default;
                          repeat it for several (loopback for this Mac's own
                          app, the tailnet address for the others)
          --store         the store's directory, the app's own by default
          --tokens        the tokens' file, tokens.json in the server's folder
                          by default; every address needs a token
          --ghidra-home   the Ghidra install; GHIDRA_HOME or the newest found
          --projects      the modules' kept projects, the app's folder by default
          --idle          seconds an owner waits for a call before it saves and
                          exits, 1800 by default
          --dump-roots    a folder the console may open dumps from; repeat it
                          for several. A path outside every root and the
                          server's Uploads is refused
          --max-documents open documents at once, 8 by default
          --max-open-bytes
                          bytes of open documents together, 512 MiB by default
          --max-upload-bytes
                          the most one upload may be, 256 MiB by default
          --mcp-socket    the local MCP's socket, mcp.sock in the server's
                          folder by default

          relay           copy MCP between stdin/stdout and the local socket,
                          for an agent's client; it starts none of the roles
        """

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// A byte count: plain, or with KiB, MiB or GiB after it.
    static func bytes(_ flag: String, _ text: String) throws -> UInt64 {
        let units: [(String, UInt64)] = [("KiB", 1 << 10), ("MiB", 1 << 20), ("GiB", 1 << 30)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            guard let value = UInt64(text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else {
                throw Failure(description: "\(flag) takes a size, not \(text)")
            }
            return value * scale
        }
        guard let value = UInt64(text) else { throw Failure(description: "\(flag) takes a size, not \(text)") }
        return value
    }

    public static func parse(_ arguments: [String]) throws -> ServerCommand {
        var rest = arguments[...]
        var verb = "serve"
        if let first = rest.first, !first.hasPrefix("-") {
            verb = first
            rest = rest.dropFirst()
        }
        func value(_ flag: String) throws -> String {
            guard let next = rest.first, !next.hasPrefix("--") else {
                throw Failure(description: "\(flag) needs a value")
            }
            rest = rest.dropFirst()
            return next
        }
        switch verb {
        case "help":
            return .help
        case "relay":
            var path = ProcessInfo.processInfo.environment["BYTERIPPER_SERVER_SOCKET"]
                .map { URL(fileURLWithPath: $0) } ?? ServerPaths.defaultSocket
            while let flag = rest.popFirst() {
                switch flag {
                case "--mcp-socket": path = URL(fileURLWithPath: try value(flag))
                case "--help", "-h": return .help
                default: throw Failure(description: "relay does not take \(flag)")
                }
            }
            return .relay(path: path.path)
        case "token":
            do {
                return .token(try TokenCommand.parse(Array(rest), defaultFile: ServerPaths.defaultTokensFile))
            } catch let failure as TokenCommand.Failure {
                throw Failure(description: failure.description)
            }
        case "serve":
            var configuration = ServerConfiguration()
            var roles: Set<ServerConfiguration.Role> = []
            var listens: [ServerConfiguration.Listen] = []
            while let flag = rest.popFirst() {
                switch flag {
                case "--cas":
                    roles.insert(.cas)
                case "--ghidra":
                    roles.insert(.ghidra)
                case "--ghidra-home":
                    configuration.ghidraHome = URL(fileURLWithPath: try value(flag))
                case "--projects":
                    configuration.projects = URL(fileURLWithPath: try value(flag))
                case "--idle":
                    let text = try value(flag)
                    guard let idle = Int(text), idle >= 0 else { throw Failure(description: "--idle takes seconds") }
                    configuration.idle = idle
                case "--listen":
                    let address = try value(flag)
                    guard let colon = address.lastIndex(of: ":"),
                          let port = UInt16(address[address.index(after: colon)...]) else {
                        throw Failure(description: "--listen takes <host>:<port>, not \(address)")
                    }
                    listens.append(.init(host: String(address[..<colon])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port))
                case "--store":
                    configuration.store = URL(fileURLWithPath: try value(flag))
                case "--tokens":
                    configuration.tokensFile = URL(fileURLWithPath: try value(flag))
                case "--dump-roots":
                    configuration.dumpRoots.append(URL(fileURLWithPath: try value(flag)))
                case "--max-documents":
                    let text = try value(flag)
                    guard let count = Int(text), count > 0 else {
                        throw Failure(description: "--max-documents takes a number of documents")
                    }
                    configuration.limits.documents = count
                case "--max-open-bytes":
                    configuration.limits.openBytes = try Self.bytes(flag, try value(flag))
                case "--max-upload-bytes":
                    configuration.limits.uploadBytes = try Self.bytes(flag, try value(flag))
                case "--mcp-socket":
                    configuration.mcpSocket = URL(fileURLWithPath: try value(flag))
                case "--help", "-h":
                    return .help
                default:
                    throw Failure(description: "serve does not take \(flag)")
                }
            }
            if !listens.isEmpty { configuration.listens = listens }
            // The store is this server's own and always served
            // (`Design/SERVER_HEADLESS_PLAN.md` decision 17); Ghidra alone is
            // optional.
            configuration.roles = roles.isEmpty ? [.cas, .ghidra] : roles.union([.cas])
            return .serve(configuration)
        default:
            throw Failure(description: "\(verb) is not a command of byteripper-server")
        }
    }
}

public struct ServerConfiguration: Equatable, Sendable {
    public enum Role: String, Sendable {
        case cas
        case ghidra
    }

    public struct Listen: Equatable, Sendable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public var roles: Set<Role> = [.cas, .ghidra]
    /// Every address the server listens on, the same routes behind each.
    public var listens = [Listen(host: "127.0.0.1", port: 8765)]

    /// The first address — the one a single `--listen` names.
    public var host: String {
        get { listens[0].host }
        set { listens[0].host = newValue }
    }

    public var port: UInt16 {
        get { listens[0].port }
        set { listens[0].port = newValue }
    }
    public var ghidraHome: URL?
    public var projects = GhidraHost.defaultProjectsRoot
    public var idle = 1800
    public var store = CodeAnalysisPaths.defaultRoot
    /// The file of tokens, by hash and right: the only credential the server
    /// has (`Design/SERVER_HEADLESS_PLAN.md` §5).
    public var tokensFile = ServerPaths.defaultTokensFile
    /// The `--dump-roots` a document's path must resolve inside. A root that
    /// is not there is kept and reported (`DocumentRegistry.absentRoots`).
    public var dumpRoots: [URL] = []
    /// The local MCP's socket, `mcp.sock` in the server's folder.
    public var mcpSocket = ServerPaths.defaultSocket
    /// `Uploads` beside the tokens, and the documents' file — the server's
    /// own unless a test hands it another.
    public var uploads = ServerPaths.uploads
    public var documentsFile = ServerPaths.documentsFile
    /// How much may be open at once (decisions 11 and 12).
    public var limits = DumpLimits()
    /// This Mac's client token, which the server checks at start against
    /// `tokensFile` and never serves on (decision 2).
    public var clientTokenFile = ServerPaths.clientTokenFile

    public init() {}
}

public enum ServerPaths {
    public static var support: URL {
        CodeAnalysisPaths.defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("Server", isDirectory: true)
    }

    public static var defaultTokensFile: URL {
        support.appendingPathComponent("tokens.json", isDirectory: false)
    }

    /// The app's and the scripts' client token on this Mac, written from
    /// Settings ▸ Code Analysis (`Design/SERVER_HEADLESS_PLAN.md` decision 2);
    /// an earlier build also read it as the server's one token, and no longer
    /// does.
    public static var clientTokenFile: URL {
        support.appendingPathComponent("token", isDirectory: false)
    }

    /// The dumps uploaded through the console: the other place a document's
    /// path may be (`Design/SERVER_HEADLESS_PLAN.md` §6).
    public static var uploads: URL {
        support.appendingPathComponent("Uploads", isDirectory: true)
    }

    /// The ids, hashes, stamps and versions of the documents, and `next_id`.
    public static var documentsFile: URL {
        support.appendingPathComponent("documents.json", isDirectory: false)
    }

    /// The local MCP's socket, the file the `relay` mode connects to.
    public static var defaultSocket: URL {
        support.appendingPathComponent("mcp.sock", isDirectory: false)
    }
}
