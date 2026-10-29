import AgentKit
import CASService
import CodeAnalysis
import Foundation
import GhidraHost
import HTTPService
import ServerAuth

/// The running server: its roles' routes on one listener, behind the tokens
/// of `tokens.json`.
public final class Server: @unchecked Sendable {
    public let configuration: ServerConfiguration
    private let log: @Sendable (String) -> Void
    private var servers: [HTTPServer] = []
    private var watcher: CodeStoreWatcher?
    private var tokens: TokenStore?
    /// Who is signed in to the console, for the server's life.
    public let sessions = AdminSessions()
    public private(set) var cas: CASService?
    public private(set) var ghidra: GhidraHost?

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
        // This file is still the app's and the scripts' token on this Mac
        // (`Design/SERVER_HEADLESS_PLAN.md` decision 2) — an earlier build
        // read it as the server's one token as well. It is not to be deleted:
        // what the programs sending its contents need is a token of its own.
        if FileManager.default.fileExists(atPath: ServerPaths.legacyTokenFile.path) {
            log("\(ServerPaths.legacyTokenFile.path) stays the token the app and the scripts use on "
                + "this Mac; the server no longer reads it, so a program still sending that secret is "
                + "refused: give each one a token of its own with "
                + "`byteripper-server token add --name <mac> --preset app`, pasted into "
                + "Settings ▸ Code Analysis")
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
            // The agent's tools over this host, at `/mcp`, behind the same token.
            let agentServer = AgentServer(
                info: AgentServerInfo(name: "byteripper-server", version: "1", title: "ByteRipper analysis server"),
                instructions: GhidraTools.instructions,
                tools: GhidraTools.tools(backend: host),
                limits: .init(maxLineBytes: 16 << 20, maxAnswerBytes: 96 << 10))
            router.merge(MCPEndpoint.routes(server: agentServer, log: log))
            let ghidraNote = (try? await host.ghidra()).map { "Ghidra \($0.version) at \($0.home.path)" }
                ?? "no Ghidra found yet"
            log("projects \(configuration.projects.path); \(ghidraNote)")
        }
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

    public func stop() {
        for server in servers { server.stop() }
        servers = []
        watcher = nil
        // What `last_used` collected: one write at stop, none per request.
        try? tokens?.flush()
    }
}
