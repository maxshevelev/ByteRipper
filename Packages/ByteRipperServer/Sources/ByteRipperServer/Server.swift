import CASService
import CodeAnalysis
import Foundation
import HTTPService

/// The running server: its roles' routes on one listener, behind one token.
public final class Server: @unchecked Sendable {
    public let configuration: ServerConfiguration
    private let log: @Sendable (String) -> Void
    private var http: HTTPServer?
    private var watcher: CodeStoreWatcher?
    public private(set) var cas: CASService?

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
