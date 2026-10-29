import AgentKit
import CASService
import CodeAnalysis
import DumpHost
import Foundation
import GhidraHost
import HTTPService
import ServerAuth
import ServerConsole
import ServerMCP

/// The running server: its roles' routes on one listener, behind the tokens
/// of `tokens.json`, and the documents its local MCP serves on a socket.
@MainActor
public final class Server {
    public let configuration: ServerConfiguration
    private let log: @Sendable (String) -> Void
    private var servers: [HTTPServer] = []
    private var watcher: CodeStoreWatcher?
    private var tokens: TokenStore?
    /// Who is signed in to the console. Kept in `sessions.json` beside the
    /// tokens, so stopping the server — a rebuild, a restart — does not sign
    /// the operator out.
    public let sessions: AdminSessions
    public private(set) var cas: CASService?
    public private(set) var ghidra: GhidraHost?
    /// The dumps the local MCP answers over (`Design/SERVER_HEADLESS_PLAN.md` §6).
    public private(set) var documents: DocumentRegistry?
    public private(set) var mcp: MCPSocket?
    /// The REST clients the console's Activity lists, per token.
    public let rest = RESTActivity()
    /// When `start` began, and the addresses it bound: the console's Status.
    private var started = Date()
    private var bound: [String] = []

    public init(configuration: ServerConfiguration,
                log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.configuration = configuration
        self.log = log
        // The sessions sit beside the tokens: the server's folder, or the
        // temporary one a test hands it.
        self.sessions = AdminSessions(file: configuration.tokensFile
            .deletingLastPathComponent()
            .appendingPathComponent("sessions.json"))
    }

    /// Opens the roles and listens on every address; returns the first one's port.
    @discardableResult
    public func start() async throws -> UInt16 {
        started = Date()
        let tokens = try TokenStore.open(at: configuration.tokensFile)
        tokens.onProblem = log
        if let warning = Self.clientTokenWarning(configuration.clientTokenFile, tokens: tokens) {
            log(warning)
        }
        // Without an admin token the console cannot be opened and the file
        // cannot be corrected through it, so there is nothing to start
        // (`Design/SERVER_HEADLESS_PLAN.md` decision 16).
        guard tokens.hasAdmin else {
            throw ServerCommand.Failure(description: "\(TokenStore.Failure.noAdmin(configuration.tokensFile.path))")
        }
        self.tokens = tokens
        let authorizer = ServerAuthorizer(tokens: tokens, sessions: sessions)
        var router = HTTPRouter()
        if configuration.roles.contains(.cas) {
            let store = try ContentStore(root: configuration.store)
            let cas = try CASService(store: store)
            router.merge(cas.routes())
            self.cas = cas
            // A write by something else on this machine — byteripper-cas, the
            // skill — lands in the directory, not through a route.
            let feed = cas.feed
            watcher = CodeStoreWatcher(root: store.root) {
                Task { await feed.rescan() }
            }
            log("store \(store.root.path) (\(cas.feed.storeID))")
        }
        if configuration.roles.contains(.ghidra) {
            // The store is always this server's own (decision 17).
            guard let cas else {
                throw ServerCommand.Failure(description: "the Ghidra role publishes into this server's store, which did not open")
            }
            let writer: AnalysisWriter = cas.store
            let host = GhidraHost(configuration: .init(projectsRoot: configuration.projects,
                                                       ghidraHome: configuration.ghidraHome,
                                                       idle: configuration.idle),
                                  writer: writer)
            let feed = cas.feed
            GhidraRoutes.projectsRoot = configuration.projects
            router.merge(GhidraRoutes.routes(host: host, published: { await feed.rescan() }))
            ghidra = host
            let ghidraNote = (try? await host.ghidra()).map { "Ghidra \($0.version) at \($0.home.path)" }
                ?? "no Ghidra found yet"
            log("projects \(configuration.projects.path); \(ghidraNote)")
        }
        // The documents and the local MCP: always on (decision 14), and it has
        // the dumps and the store whether or not Ghidra is a role. The socket
        // is served last, once the rows are restored: a client that connects
        // finds the set the file had, not a half-filled one.
        let registry = DocumentRegistry(roots: configuration.dumpRoots,
                                        uploads: configuration.uploads,
                                        file: configuration.documentsFile,
                                        limits: configuration.limits)
        do {
            try await registry.restore()
        } catch {
            stop()
            throw error
        }
        for root in registry.absentRoots {
            log("dump root \(root.path) is not there; its documents stay missing until it is")
        }
        documents = registry
        log("documents: \(registry.rows.filter { $0.host != nil }.count) open of \(registry.rows.count)")

        let backend = ghidra.map { $0 as any GhidraBackend }
        let tools = ServerTools.all(documents: registry, store: configuration.store, ghidra: backend)
        let agentServer = AgentServer(
            info: AgentServerInfo(name: "byteripper-server", version: Self.version, title: "ByteRipper analysis server"),
            instructions: ServerTools.instructions(ghidra: backend != nil),
            tools: tools,
            limits: .init(maxLineBytes: 16 << 20, maxAnswerBytes: 96 << 10))
        let socket = MCPSocket(path: configuration.mcpSocket.path, server: agentServer)
        do {
            try socket.start()
        } catch {
            stop()
            throw error
        }
        mcp = socket
        log("local MCP on \(configuration.mcpSocket.path), \(tools.count) tools")

        // The console, on every address behind the admin token, and only
        // under this server's own names (decision 19).
        let console: Console
        do {
            console = try Console(registry: registry, tokens: tokens, authorizer: authorizer, rest: rest,
                                  mcp: socket.activity,
                                  agent: ConsoleAgent(socket: configuration.mcpSocket.path,
                                                      binary: Self.executablePath()),
                                  status: { [weak self] in await self?.status() ?? Self.noStatus })
        } catch {
            stop()
            throw error
        }
        router.merge(console.routes(uploadLimit: configuration.limits.uploadBytes))
        let names = ConsoleNames(listens: configuration.listens.map(\.host), serverNames: configuration.serverNames)
        let rest = self.rest
        // The console asks every two seconds: its answered reads would bury
        // every other line of the log.
        let log = self.log
        let requestLog: @Sendable (String) -> Void = { line in
            if line.hasPrefix("GET /admin"), line.contains(" 200 ") || line.contains(" 304 ") { return }
            log(line)
        }

        var first: UInt16 = 0
        bound = []
        for listen in configuration.listens {
            let http = HTTPServer(
                configuration: .init(host: listen.host, port: listen.port,
                                     authorizer: authorizer, log: requestLog,
                                     onRequest: { rest.record($0) }, screen: { names.screen($0) }),
                router: router)
            let port: UInt16
            do {
                port = try await http.start()
            } catch {
                stop()
                throw error
            }
            if servers.isEmpty { first = port }
            servers.append(http)
            bound.append("\(listen.host):\(port)")
            let address = http.boundAddress.map { $0 == listen.host ? "" : " (\($0))" } ?? ""
            log("listening on \(listen.host)\(address):\(port), token required")
        }
        log("console at http://\(Self.hostForURL(configuration.listens[0].host)):\(first)/admin")
        return first
    }

    /// What the console's Status shows, read at each ask.
    func status() async -> ConsoleStatus {
        var ghidraNote: String?
        if let ghidra {
            ghidraNote = (try? await ghidra.ghidra()).map { "Ghidra \($0.version) at \($0.home.path)" }
                ?? "no Ghidra found: give --ghidra-home"
        }
        return ConsoleStatus(version: Self.version, started: started, addresses: bound,
                             serverNames: configuration.serverNames,
                             roles: configuration.roles.map(\.rawValue).sorted(),
                             store: configuration.store.path, storeID: cas?.feed.storeID, ghidra: ghidraNote,
                             socket: configuration.mcpSocket.path, tokensFile: configuration.tokensFile.path)
    }

    /// What the server calls itself to an agent and on the console.
    public nonisolated static let version = "1"

    /// This server's own binary, absolute — the thing an MCP client's relay
    /// starts. `CommandLine.arguments` holds what the operator typed, which is
    /// often a path relative to the folder it was typed in; a bare name is
    /// looked up in `PATH` and left as it is when it is not found there.
    nonisolated static func executablePath() -> String {
        let argument = CommandLine.arguments.first ?? "byteripper-server"
        if argument.contains("/") {
            return URL(fileURLWithPath: argument).standardized.path
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(argument)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return argument
    }

    nonisolated static let noStatus = ConsoleStatus(
        version: version, started: Date(), addresses: [], serverNames: [], roles: [], store: "", storeID: nil,
        ghidra: nil, socket: "", tokensFile: "")

    static func hostForURL(_ host: String) -> String {
        if ConsoleNames.isWildcard(host) { return "127.0.0.1" }
        return host.contains(":") ? "[\(host)]" : host
    }

    /// What to say about this Mac's client token: nothing when it is one of
    /// this server's live tokens — the usual Mac where the app and the server
    /// sit together — and how to mend it when it is not, which is what an
    /// earlier build's single token is after an upgrade. The file is the
    /// app's and the scripts' (decision 2): it is never to be deleted.
    static func clientTokenWarning(_ file: URL, tokens: TokenStore) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, !tokens.holds(secret: secret) else { return nil }
        return "\(file.path), the token the app and the scripts send from this Mac, is not one of "
            + "this server's: they will be refused. Make one with "
            + "`byteripper-server token add --name <mac> --preset app` and paste it into "
            + "Settings ▸ Code Analysis — the app rewrites the file; do not delete it"
    }

    public func stop() {
        mcp?.stop()
        mcp = nil
        documents = nil
        for server in servers { server.stop() }
        servers = []
        watcher = nil
        // What `last_used` collected: one write at stop, none per request.
        try? tokens?.flush()
    }
}
