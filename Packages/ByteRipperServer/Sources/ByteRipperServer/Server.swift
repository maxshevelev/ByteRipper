import AgentKit
import CASService
import CodeAnalysis
import DumpHost
import Foundation
import GhidraHost
import HTTPService
import ServerAuth
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
    /// Who is signed in to the console, for the server's life.
    public let sessions = AdminSessions()
    public private(set) var cas: CASService?
    public private(set) var ghidra: GhidraHost?
    /// The dumps the local MCP answers over (`Design/SERVER_HEADLESS_PLAN.md` §6).
    public private(set) var documents: DocumentRegistry?
    public private(set) var mcp: MCPSocket?

    public init(configuration: ServerConfiguration,
                log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.configuration = configuration
        self.log = log
    }

    /// Opens the roles and listens on every address; returns the first one's port.
    @discardableResult
    public func start() async throws -> UInt16 {
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
            info: AgentServerInfo(name: "byteripper-server", version: "1", title: "ByteRipper analysis server"),
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

        var first: UInt16 = 0
        for listen in configuration.listens {
            let http = HTTPServer(
                configuration: .init(host: listen.host, port: listen.port,
                                     authorizer: authorizer, log: log),
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
            let address = http.boundAddress.map { $0 == listen.host ? "" : " (\($0))" } ?? ""
            log("listening on \(listen.host)\(address):\(port), token required")
        }
        return first
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
