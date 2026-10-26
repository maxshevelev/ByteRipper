import Foundation

/// A local copy of a served store, which the app reads as it reads its own
/// (`Design/SERVER_PLAN.md` §5).
///
/// The mirror is a `ContentStore` in a directory of its own, named by the
/// served store's identity. Manifests and histories are copied as the server
/// decided them; objects are fetched the first time something reads them and
/// kept, since they never change. Every copy is an ordinary atomic write in
/// `analyses/` or `reviews/`, so the FSEvents stream the app already follows
/// announces a change on the server like a local one.
public actor StoreMirror {
    public nonisolated let remote: RemoteStore
    public nonisolated let mirrorsRoot: URL

    private var mirror: ContentStore?
    private var storeID: String?
    private var epoch: String?
    private var seq = 0

    /// - Parameter mirrorsRoot: the folder holding one mirror per served
    ///   store; `CodeAnalysisPaths.mirrorsRoot` for the app.
    public init(remote: RemoteStore, mirrorsRoot: URL) {
        self.remote = remote
        self.mirrorsRoot = mirrorsRoot
    }

    public static func root(of storeID: String, in mirrorsRoot: URL) -> URL {
        mirrorsRoot.appendingPathComponent(storeID, isDirectory: true)
    }

    /// The mirror, made current: read the server's hello, open the mirror
    /// directory for its store and copy every module.
    @discardableResult
    public func connect() async throws -> ContentStore {
        let hello = try await remote.hello()
        let store = try open(hello.store)
        try await syncAll(into: store)
        epoch = hello.epoch
        seq = hello.seq
        return store
    }

    /// The mirror of the store this one last connected to, without the
    /// network: what the app reads while the server is out of reach.
    public func offline(storeID: String) throws -> ContentStore {
        try open(storeID)
    }

    /// Wait up to `wait` seconds for the server to change, and copy what
    /// changed. Returns the modules copied.
    @discardableResult
    public func follow(wait: Int = 25) async throws -> [SHA256Digest] {
        guard let store = mirror, let epoch else {
            try await connect()
            return []
        }
        let changes = try await remote.changes(since: seq, epoch: epoch, wait: wait)
        guard changes.store == storeID else {
            // The server now serves another store: start over in its mirror.
            try await connect()
            return []
        }
        if changes.resync || changes.epoch != epoch {
            try await syncAll(into: store)
            self.epoch = changes.epoch
            seq = changes.seq
            return []
        }
        for module in changes.modules {
            try store.mirror(try await remote.module(module))
        }
        seq = changes.seq
        return changes.modules
    }

    /// Copy these modules as the server holds them now — after a write whose
    /// result the feed may not report, such as a bundle the server left as
    /// it was.
    public func refresh(_ modules: [SHA256Digest]) async throws {
        guard let store = mirror else { return }
        for module in Set(modules) {
            try store.mirror(try await remote.module(module))
        }
    }

    /// The served store this mirror copies, once it has connected or opened.
    public var servedStoreID: String? { storeID }

    /// Drop the objects no mirrored manifest or history names.
    public func collectGarbage() throws {
        guard var store = mirror else { return }
        store.objectSource = nil
        _ = try store.collectGarbage(dryRun: false)
    }

    // MARK: -

    private func open(_ id: String) throws -> ContentStore {
        guard SafeName.isSafe(id) else { throw CodeAnalysisError.invalidName(id) }
        if let mirror, storeID == id { return mirror }
        let root = Self.root(of: id, in: mirrorsRoot)
        let remote = self.remote
        // Registered, not only set: the app opens the store by its root in
        // many places, and each of them must fetch what the mirror lacks.
        ContentStore.register(objectSource: { try remote.objectBlocking($0) }, forRoot: root)
        let store = try ContentStore(root: root)
        mirror = store
        storeID = id
        epoch = nil
        seq = 0
        return store
    }

    private func syncAll(into store: ContentStore) async throws {
        let served = try await remote.modules()
        let names = Set(served.map(\.module))
        for module in served {
            try store.mirror(module)
        }
        for module in store.modules() where !names.contains(module) {
            try store.mirror(ServedModule(module: module, manifests: [], history: nil))
        }
    }
}
