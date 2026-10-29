import CodeAnalysis
import Foundation
import GhidraHost
import ServerAuth

/// What `byteripper-server` was asked to do, read from its arguments.
public enum ServerCommand: Equatable {
    case serve(ServerConfiguration)
    /// Make, list, rotate or revoke a token of `tokens.json`.
    case token(TokenCommand)
    case help

    public static let usage = """
        usage: byteripper-server [serve] [--cas] [--ghidra] [--listen <host>:<port>]
                                 [--store <dir>] [--tokens <file>]
                                 [--ghidra-home <dir>] [--projects <dir>] [--idle <s>]
               byteripper-server token add --name <name> [--rights <right,…> | --preset <reader|app|admin>]
               byteripper-server token list | rotate <id|name> | revoke <id|name>

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
        """

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
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
}
