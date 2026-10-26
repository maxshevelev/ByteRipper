import CASService
import CodeAnalysis
import Foundation
import GhidraHost
import HTTPService

/// The running server: its roles' routes on one listener, behind one token.
public final class Server: @unchecked Sendable {
    public let configuration: ServerConfiguration
    private let log: @Sendable (String) -> Void
    private var http: HTTPServer?
    private var watcher: CodeStoreWatcher?
    public private(set) var cas: CASService?
    public private(set) var ghidra: GhidraHost?

    public init(configuration: ServerConfiguration,
                log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.configuration = configuration
        self.log = log
    }

    /// Opens the roles and listens; returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let token = try TokenFile.read(at: configuration.tokenFile)
        if token == nil, configuration.tokenRequired {
            throw ServerCommand.Failure(description: "\(configuration.tokenFile.path) does not exist; "
                                        + "make it with byteripper-server token")
        }
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
            let writer: AnalysisWriter
            if let url = configuration.casURL {
                writer = RemoteStore(base: url, token: token)
            } else if let cas {
                writer = cas.store
            } else {
                throw ServerCommand.Failure(description: "the Ghidra role publishes into a store: add --cas, or name --cas-url")
            }
            let host = GhidraHost(configuration: .init(projectsRoot: configuration.projects,
                                                       ghidraHome: configuration.ghidraHome,
                                                       idle: configuration.idle),
                                  writer: writer)
            let feed = cas?.feed
            GhidraRoutes.projectsRoot = configuration.projects
            router.merge(GhidraRoutes.routes(host: host, published: { await feed?.rescan() }))
            ghidra = host
            let ghidraNote = (try? await host.ghidra()).map { "Ghidra \($0.version) at \($0.home.path)" }
                ?? "no Ghidra found yet"
            log("projects \(configuration.projects.path); \(ghidraNote)")
        }
        let http = HTTPServer(
            configuration: .init(host: configuration.host, port: configuration.port, token: token,
                                 log: log),
            router: router)
        let port = try await http.start()
        self.http = http
        log("listening on \(configuration.host):\(port)" + (token == nil ? ", no token (loopback only)" : ", token required"))
        return port
    }

    public func stop() {
        http?.stop()
        http = nil
        watcher = nil
    }
}
