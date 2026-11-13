import CodeAnalysis
import Foundation
import HTTPService

/// The store's operations as routes under `/cas/v1` (`Design/SERVER_PLAN.md`
/// §4). Every write is `ContentStore`'s own call, so what the server refuses
/// is what `byteripper-cas` refuses; after a write the change feed looks for
/// what it changed.
///
/// Not served, on purpose: garbage collection and anything that names a
/// file. Collection runs on the server's own directory, by the person.
public struct CASService: Sendable {
    public let store: ContentStore
    public let feed: ChangeFeed
    /// The longest a long poll is held, whatever the client asks.
    public var maxWait: TimeInterval = 60
    /// How often `heartbeat` writes; a test's own.
    public var heartbeatInterval = HeartbeatWatch.interval

    public init(store: ContentStore) throws {
        self.store = store
        self.feed = try ChangeFeed(store: store)
    }

    /// Whether an `Accept-Encoding` header takes gzip: named, and not `q=0`.
    static func acceptsGzip(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.split(separator: ",").contains { item in
            let fields = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard fields.first == "gzip" else { return false }
            return !fields.dropFirst().contains { field in
                field.hasPrefix("q=") && Double(field.dropFirst(2)) == 0
            }
        }
    }

    /// Every route names its right (`Design/SERVER_HEADLESS_PLAN.md` §5):
    /// `cas.read` for what only reads — `export` among them, a POST only
    /// because it carries a list — `cas.write` for the references, and
    /// `admin` for what writes the store past a publish.
    public func routes() -> HTTPRouter {
        var router = HTTPRouter()
        let prefix = ServedStoreProtocol.prefix
        let store = self.store
        let feed = self.feed
        let maxWait = self.maxWait
        let heartbeatInterval = self.heartbeatInterval

        router.add("GET", "\(prefix)/hello", access: .rights([.casRead])) { _ in
            .json(ServedStoreProtocol.Hello(store: feed.storeID, epoch: feed.epoch, seq: await feed.current))
        }

        router.add("GET", "\(prefix)/objects/:sha", access: .rights([.casRead])) { request in
            .bytes(try Self.answer { try store.object(try Self.digest(request.parameters["sha"])) })
        }
        router.add("GET", "\(prefix)/objects/:sha/root", access: .rights([.casRead])) { request in
            let digest = try Self.digest(request.parameters["sha"])
            // The root's own file for a client that takes gzip, as URLSession
            // does and inflates by itself: a large module's root is a third of
            // the size that way, and is compressed only once.
            let gzipped = Self.acceptsGzip(request.headers["accept-encoding"])
            guard let root = try Self.answer({
                gzipped ? try store.gzippedObjectRoot(digest) : try store.objectRoot(digest)
            }) else {
                throw HTTPError(.notFound, "object \(digest.hex) is not cut")
            }
            var response = HTTPResponse.bytes(root)
            response.headers["vary"] = "accept-encoding"
            if gzipped { response.headers["content-encoding"] = "gzip" }
            return response
        }
        router.add("POST", "\(prefix)/objects/parts", access: .rights([.casRead])) { request in
            let names = try request.json(ServedStoreProtocol.Parts.self)
            guard names.sha256.count <= ServedStoreProtocol.Parts.limit else {
                throw HTTPError(.unprocessable, "at most \(ServedStoreProtocol.Parts.limit) objects a request")
            }
            var answer = Data()
            for name in names.sha256 {
                var file = Data()
                do {
                    file = try store.gzippedObject(name)
                } catch CodeAnalysisError.objectMissing {
                    // Stays empty: the client knows what it lacks.
                }
                answer.append(Data(name.hex.utf8))
                withUnsafeBytes(of: UInt64(file.count).bigEndian) { answer.append(contentsOf: $0) }
                answer.append(file)
            }
            return .bytes(answer)
        }
        // The writes past a publish — an object, an analysis, a revision, the
        // registry, a bundle — are an administrator's (`Design/SERVER_PLAN.md`
        // stage 2.5): a client makes a revision by publishing through the
        // Ghidra role, which writes the store in this process and takes none
        // of these routes. `cas.write` is left the references and that publish.
        router.add("PUT", "\(prefix)/objects/:sha", access: .rights([.admin])) { request in
            let digest = try Self.digest(request.parameters["sha"])
            guard SHA256Digest(data: request.body) == digest else {
                throw HTTPError(.unprocessable, "the body does not hash to \(digest.hex)")
            }
            try Self.answer { try store.putObject(request.body) }
            return HTTPResponse(.noContent)
        }

        router.add("GET", "\(prefix)/analyses", access: .rights([.casRead])) { _ in
            .json(ServedStoreProtocol.Modules(modules: store.modules().sorted().map(store.served)))
        }
        router.add("GET", "\(prefix)/analyses/:module", access: .rights([.casRead])) { request in
            .json(store.served(try Self.digest(request.parameters["module"])))
        }
        router.add("POST", "\(prefix)/analyses", access: .rights([.admin])) { request in
            let put = try request.json(ServedStoreProtocol.PutAnalysis.self)
            let manifest = try Self.answer { () -> AnalysisManifest in
                let artifact = try store.object(put.artifact)
                return try store.putAnalysis(
                    module: put.module, recipe: put.recipe, artifact: artifact,
                    source: put.source ?? SourceIdentity(), reading: put.reading,
                    replace: put.replace ?? false, discardReading: put.discardReading ?? false)
            }
            await feed.rescan()
            return .json(manifest)
        }

        router.add("GET", "\(prefix)/reviews/:module", access: .rights([.casRead])) { request in
            let module = try Self.digest(request.parameters["module"])
            guard let history = try Self.answer({ try store.reviewHistory(module: module) }) else {
                throw HTTPError(.notFound, "no review history for \(module.hex)")
            }
            return .json(history)
        }
        router.add("POST", "\(prefix)/reviews/:module", access: .rights([.admin])) { request in
            let module = try Self.digest(request.parameters["module"])
            let record = try request.json(ServedStoreProtocol.RecordRevision.self)
            let history = try Self.answer {
                try store.recordRevision(module: module, reading: record.reading,
                                         artifact: record.artifact, by: record.by)
            }
            await feed.rescan()
            return .json(history)
        }

        // The library registry (`Design/LIBRARY_REGISTRY_PLAN.md`): its index,
        // one entry's history, and a publish's offer.
        router.add("GET", "\(prefix)/library", access: .rights([.casRead])) { _ in
            .json(try Self.answer { try store.libraryIndex() })
        }
        router.add("GET", "\(prefix)/library/history/:id", access: .rights([.casRead])) { request in
            let id = request.parameters["id"] ?? ""
            guard let history = try Self.answer({ try store.libraryHistory(id: id) }) else {
                throw HTTPError(.notFound, "no library entry \(id)")
            }
            return .json(history)
        }
        router.add("POST", "\(prefix)/library", access: .rights([.admin])) { request in
            let put = try request.json(ServedStoreProtocol.PutLibrary.self)
            let dryRun = put.dryRun == true
            // A citation only adds. A change of the registry itself is a
            // proposal's, which the server applies once agreed.
            if var citation = put.citation {
                citation.action = .cite
                let result = try Self.answer { try store.changeLibrary(citation, by: put.by, changedFrom: put.module, dryRun: dryRun) }
                if !dryRun { await feed.rescan() }
                return .json(result)
            }
            // An offer adds, or completes, or conflicts: what an entry says is
            // replaced by an agreed proposal, which the module's next publish
            // applies inside the server, never by an offer.
            let result = try Self.answer {
                try store.putLibraryEntries(module: put.module, rev: put.rev, by: put.by,
                                            proposals: put.proposals,
                                            take: LibraryTake.none.with(entryReasons: put.entryReasons ?? [:]),
                                            dryRun: dryRun)
            }
            if !dryRun { await feed.rescan() }
            return .json(result)
        }

        router.add("GET", "\(prefix)/conflicts", access: .rights([.casRead])) { _ in .json(store.conflicts()) }

        router.add("GET", "\(prefix)/refs", access: .rights([.casRead])) { _ in .json(store.refs()) }
        router.add("PUT", "\(prefix)/refs/:name", access: .rights([.casWrite])) { request in
            let set = try request.json(ServedStoreProtocol.SetRef.self)
            return .json(try Self.answer { try store.setRef(request.parameters["name"]!, analyses: set.analyses) })
        }
        router.add("DELETE", "\(prefix)/refs/:name", access: .rights([.casWrite])) { request in
            guard try Self.answer({ try store.removeRef(request.parameters["name"]!) }) else {
                throw HTTPError(.notFound, "no reference \(request.parameters["name"]!)")
            }
            return HTTPResponse(.noContent)
        }

        router.add("POST", "\(prefix)/import", access: .rights([.admin])) { request in
            let report = try Self.withTemporaryFile(in: store, request.body) { url in
                try Self.answer { try store.importBundle(from: url) }
            }
            await feed.rescan()
            return .json(report)
        }
        router.add("POST", "\(prefix)/export", access: .rights([.casRead])) { request in
            let export = try request.json(ServedStoreProtocol.Export.self)
            return .bytes(try Self.withTemporaryFile(in: store, nil) { url in
                try Self.answer { _ = try store.exportBundle(export.keys, to: url) }
                return try Data(contentsOf: url)
            }, type: "application/zip")
        }

        router.add("GET", "\(prefix)/verify", access: .rights([.casRead])) { _ in
            .json(ServedStoreProtocol.Problems(problems: store.verify()))
        }

        router.add("GET", "\(prefix)/changes", access: .rights([.casRead])) { request in
            let since = Int(request.query["since"] ?? "") ?? 0
            let wait = min(TimeInterval(request.query["wait"] ?? "") ?? 0, maxWait)
            return .json(await feed.changes(since: since, epoch: request.query["epoch"], wait: wait))
        }

        // Pushed, not asked for: a client that stops hearing it knows the
        // connection is gone, which a long poll says only when it times out.
        router.add("GET", "\(prefix)/heartbeat", access: .rights([.casRead])) { _ in
            .stream(type: "text/event-stream") { client in
                var beat = 0
                while true {
                    beat += 1
                    guard await client.write(Data("data: {\"beat\":\(beat)}\n\n".utf8)) else { return }
                    try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                }
            }
        }
        return router
    }

    // MARK: -

    static func digest(_ text: String?) throws -> SHA256Digest {
        guard let text, let digest = SHA256Digest(hex: text) else {
            throw HTTPError(.badRequest, "\(text ?? "nothing") is not a SHA-256")
        }
        return digest
    }

    /// The store's refusal as the HTTP status a client acts on.
    @discardableResult
    static func answer<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CodeAnalysisError {
            switch error {
            case .objectMissing, .analysisMissing:
                throw HTTPError(.notFound, error.description)
            case .analysisMismatch:
                throw HTTPError(.conflict, error.description)
            case .invalidDigest, .invalidName, .invalidRecipe, .bundleInvalid:
                throw HTTPError(.badRequest, error.description)
            case .objectCorrupt, .io:
                throw HTTPError(.internalError, error.description)
            }
        }
    }

    /// A bundle is a zip the store reads from and writes to a file; the file
    /// lives in the store's own `tmp/` for the length of one call.
    static func withTemporaryFile<T>(in store: ContentStore, _ contents: Data?,
                                     _ body: (URL) throws -> T) throws -> T {
        let url = store.tmpURL.appendingPathComponent("served-\(UUID().uuidString).zip")
        try FileManager.default.createDirectory(at: store.tmpURL, withIntermediateDirectories: true)
        if let contents { try contents.write(to: url) }
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}
