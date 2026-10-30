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
                                 [--server-name <name>] [--store <dir>] [--tokens <file>]
                                 [--support <dir>] [--dump-roots <dir>] [--max-documents <n>]
                                 [--max-open-bytes <n>] [--max-upload-bytes <n>] [--mcp-socket <path>]
                                 [--ghidra-home <dir>] [--ghidra-scripts <dir>] [--projects <dir>] [--idle <s>]
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
          --support       the server's own folder — tokens.json, sessions,
                          mcp.sock, documents.json and Uploads in one place,
                          as an installed copy keeps them; --tokens and
                          --mcp-socket still win
          --ghidra-home   the Ghidra install; GHIDRA_HOME or the newest found
          --ghidra-scripts
                          the folder of the Ghidra scripts, `owner/` and
                          `scripts/`; the `ghidra` folder beside the binary by
                          default, else the checkout this build came from
          --projects      the modules' kept projects, the app's folder by default
          --idle          seconds an owner waits for a call before it saves and
                          exits, 1800 by default
          --server-name   a name the console answers under besides the listen
                          addresses — a LAN or tailnet name; repeat it for
                          several. A browser that reached the server under any
                          other name is refused
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
          --config        a configuration file — ~/.byteripper-server.json by
                          default — read before the flags, which still win
          --no-config     read no configuration file

          ~/.byteripper-server.json takes the flags above as its keys — support,
          store, projects, ghidraHome, ghidraScripts, tokens, mcpSocket,
          dumpRoots, serverNames, listen, idle, maxDocuments, maxOpenBytes,
          maxUploadBytes — paths as strings, lists as arrays, sizes as numbers
          or "512 MiB".

          relay           copy MCP between stdin/stdout and the local socket,
                          for an agent's client; it starts none of the roles.
                          The socket is --mcp-socket, else
                          $BYTERIPPER_SERVER_SOCKET, else the default
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

    /// `host:port`, with an IPv6 host in brackets.
    static func listen(_ address: String) throws -> ServerConfiguration.Listen {
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]) else {
            throw Failure(description: "--listen takes <host>:<port>, not \(address)")
        }
        return ServerConfiguration.Listen(
            host: String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            port: port)
    }

    public static func parse(_ arguments: [String],
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ServerCommand {
        var rest = arguments[...]
        var verb = "serve"
        if let first = rest.first, !first.hasPrefix("-") {
            verb = first
            rest = rest.dropFirst()
        }
        // `--config` and `--no-config` may stand anywhere on the line, so
        // they are read first, and the loop below only steps over them.
        var configFile: URL? = ServerConfiguration.defaultFile(in: home)
        var scan = rest[...]
        while let flag = scan.popFirst() {
            switch flag {
            case "--config":
                guard let next = scan.popFirst() else { throw Failure(description: "--config needs a file") }
                configFile = URL(fileURLWithPath: next)
            case "--no-config":
                configFile = nil
            case "--help", "-h":
                return .help
            default:
                break
            }
        }
        var fromFile = ServerConfiguration()
        if let configFile {
            if FileManager.default.fileExists(atPath: configFile.path) {
                try ServerConfiguration.load(configFile, into: &fromFile)
            } else if configFile != ServerConfiguration.defaultFile(in: home) {
                throw Failure(description: "\(configFile.path) is not there")
            }
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
                .map { URL(fileURLWithPath: $0) } ?? fromFile.mcpSocket
            while let flag = rest.popFirst() {
                switch flag {
                case "--mcp-socket": path = URL(fileURLWithPath: try value(flag))
                case "--config": _ = try value(flag)   // read before the loop
                case "--no-config": break
                case "--help", "-h": return .help
                default: throw Failure(description: "relay does not take \(flag)")
                }
            }
            return .relay(path: path.path)
        case "token":
            do {
                return .token(try TokenCommand.parse(Array(rest), defaultFile: fromFile.tokensFile))
            } catch let failure as TokenCommand.Failure {
                throw Failure(description: failure.description)
            }
        case "serve":
            var configuration = fromFile
            var roles: Set<ServerConfiguration.Role> = []
            var listens: [ServerConfiguration.Listen] = []
            var support: URL?
            var tokensGiven = false
            var socketGiven = false
            while let flag = rest.popFirst() {
                switch flag {
                case "--cas":
                    roles.insert(.cas)
                case "--ghidra":
                    roles.insert(.ghidra)
                case "--ghidra-home":
                    configuration.ghidraHome = URL(fileURLWithPath: try value(flag))
                case "--ghidra-scripts":
                    configuration.ghidraScripts = URL(fileURLWithPath: try value(flag))
                case "--support":
                    support = URL(fileURLWithPath: try value(flag))
                case "--projects":
                    configuration.projects = URL(fileURLWithPath: try value(flag))
                case "--idle":
                    let text = try value(flag)
                    guard let idle = Int(text), idle >= 0 else { throw Failure(description: "--idle takes seconds") }
                    configuration.idle = idle
                case "--listen":
                    listens.append(try Self.listen(try value(flag)))
                case "--store":
                    configuration.store = URL(fileURLWithPath: try value(flag))
                case "--tokens":
                    configuration.tokensFile = URL(fileURLWithPath: try value(flag))
                    tokensGiven = true
                case "--server-name":
                    configuration.serverNames.append(try value(flag))
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
                    socketGiven = true
                case "--config":
                    _ = try value(flag)   // read before the loop
                case "--no-config":
                    break
                case "--help", "-h":
                    return .help
                default:
                    throw Failure(description: "serve does not take \(flag)")
                }
            }
            if !listens.isEmpty { configuration.listens = listens }
            // One folder for the server's own files: a flag on any of them
            // still wins over it, whichever came first on the line.
            if let support {
                configuration.useFolder(support, tokens: tokensGiven, socket: socketGiven)
            }
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
    /// The folder of the Ghidra scripts — `owner/` and `scripts/`, the
    /// skill's layout and the distribution's. Nil: `OwnerSources.resolved`.
    public var ghidraScripts: URL?
    public var projects = GhidraHost.defaultProjectsRoot
    public var idle = 1800
    public var store = CodeAnalysisPaths.defaultRoot
    /// The folder the server keeps its own files in (`--support`): the
    /// tokens, the console's sessions, the local MCP's socket, the documents
    /// and their uploads. Nil: `ServerPaths`, the app's shared folder.
    public var support: URL?
    /// The file of tokens, by hash and right: the only credential the server
    /// has (`Design/SERVER_HEADLESS_PLAN.md` §5).
    public var tokensFile = ServerPaths.defaultTokensFile
    /// The `--dump-roots` a document's path must resolve inside. A root that
    /// is not there is kept and reported (`DocumentRegistry.absentRoots`).
    public var dumpRoots: [URL] = []
    /// `--server-name`: the names the console answers under besides the
    /// listen addresses (decision 19).
    public var serverNames: [String] = []
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

    /// `~/.byteripper-server.json`: what the server does when a flag on the
    /// line does not say. Read before the flags, which still win.
    public static func defaultFile(in home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".byteripper-server.json", isDirectory: false)
    }

    /// Points the server's own files at one folder (`--support`, or the
    /// file's `support`): the tokens, the local MCP's socket, the documents
    /// and their uploads, and this Mac's client token.
    public mutating func useFolder(_ folder: URL, tokens tokensNamed: Bool = false,
                                   socket socketNamed: Bool = false) {
        support = folder
        if !tokensNamed { tokensFile = folder.appendingPathComponent("tokens.json") }
        if !socketNamed { mcpSocket = folder.appendingPathComponent("mcp.sock") }
        documentsFile = folder.appendingPathComponent("documents.json")
        uploads = folder.appendingPathComponent("Uploads", isDirectory: true)
        clientTokenFile = folder.appendingPathComponent("token")
    }

    /// The file that was expected, and the one thing it reads.
    static func jsonProblem(_ data: Data) -> String? {
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            switch parsed {
            case is [Any]: return "the top level is a list, not an object of settings"
            case is String: return "the top level is a string, not an object of settings"
            case is NSNumber: return "the top level is a number, not an object of settings"
            case is NSNull: return "the file is null, not an object of settings"
            default: return "the top level is not an object of settings"
            }
        } catch {
            let debug = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return debug ?? error.localizedDescription
        }
    }

    /// Reads a configuration file into `configuration`. Each key is a flag
    /// without its `--`; a key the server does not know is refused rather
    /// than dropped, and a value of the wrong type is refused with its key.
    public static func load(_ file: URL, into configuration: inout ServerConfiguration) throws {
        var data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ServerCommand.Failure(description: "\(file.path): \(error.localizedDescription)")
        }
        // An editor may save a UTF-8 byte-order mark; the parser counts it as
        // a character and stops on it.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data(data.dropFirst(3)) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // The parser's own words say where: "Invalid value around line 3,
            // column 1." — a message without them is a search through the file.
            throw ServerCommand.Failure(description: "\(file.path): \(Self.jsonProblem(data) ?? "not a JSON object")")
        }
        let known: Set<String> = ["support", "store", "projects", "ghidraHome", "ghidraScripts",
                                  "tokens", "mcpSocket", "dumpRoots", "serverNames", "listen",
                                  "idle", "maxDocuments", "maxOpenBytes", "maxUploadBytes"]
        let unknown = object.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ServerCommand.Failure(description: "\(file.path): "
                + unknown.map { "\"\($0)\"" }.joined(separator: ", ")
                + " \(unknown.count == 1 ? "is not a setting" : "are not settings") of the server")
        }
        func text(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value as? String else {
                throw ServerCommand.Failure(description: "\(file.path): \(key) is a string, not \(value)")
            }
            return text
        }
        func path(_ key: String) throws -> URL? {
            try text(key).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        func list(_ key: String) throws -> [String]? {
            guard let value = object[key] else { return nil }
            guard let list = value as? [String] else {
                throw ServerCommand.Failure(description: "\(file.path): \(key) is a list of strings")
            }
            return list
        }
        func number(_ key: String) throws -> Int? {
            guard let value = object[key] else { return nil }
            guard let number = value as? NSNumber else {
                throw ServerCommand.Failure(description: "\(file.path): \(key) is a number, not \(value)")
            }
            return number.intValue
        }
        func size(_ key: String) throws -> UInt64? {
            guard let value = object[key] else { return nil }
            if let number = value as? NSNumber { return number.uint64Value }
            if let text = value as? String { return try ServerCommand.bytes(key, text) }
            throw ServerCommand.Failure(description: "\(file.path): \(key) is a byte count, "
                + "a number or \"512 MiB\"")
        }

        let folder = try path("support")
        let tokens = try path("tokens")
        let socket = try path("mcpSocket")
        if let folder { configuration.useFolder(folder, tokens: tokens != nil, socket: socket != nil) }
        if let tokens { configuration.tokensFile = tokens }
        if let socket { configuration.mcpSocket = socket }
        if let store = try path("store") { configuration.store = store }
        if let projects = try path("projects") { configuration.projects = projects }
        if let home = try path("ghidraHome") { configuration.ghidraHome = home }
        if let scripts = try path("ghidraScripts") { configuration.ghidraScripts = scripts }
        if let roots = try list("dumpRoots") {
            configuration.dumpRoots = roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        if let names = try list("serverNames") { configuration.serverNames = names }
        if let listens = try list("listen") {
            configuration.listens = try listens.map { try ServerCommand.listen($0) }
        }
        if let idle = try number("idle") { configuration.idle = idle }
        if let documents = try number("maxDocuments") { configuration.limits.documents = documents }
        if let bytes = try size("maxOpenBytes") { configuration.limits.openBytes = bytes }
        if let bytes = try size("maxUploadBytes") { configuration.limits.uploadBytes = bytes }
    }
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
