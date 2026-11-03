import Foundation

/// The client of a served store (`byteripper-server --cas`, `/cas/v1`).
///
/// It sends the store's operations, never files: the server runs
/// `ContentStore` on its own directory and is its only writer, so a refusal —
/// an older revision, another project's reading — is the server's
/// `ContentStore` refusing, in the words `byteripper-cas` would use.
public struct RemoteStore: Sendable {
    public let base: URL
    private let token: String?
    private let session: URLSession

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The server could not be reached, or did not answer in time: its
        /// address and the system's words for why.
        case unreachable(String)
        /// The server answered with a refusal. `rights` are the rights a 403
        /// names as lacking; empty when it names none.
        case refused(status: Int, message: String, rights: [String])
        /// The answer is not what this protocol version expects.
        case unexpected(String)

        public var description: String {
            switch self {
            case .unreachable(let reason):
                return "no byteripper-server answers at \(reason) — is it running, and listening on that address?"
            case .refused(_, let message, _): return message
            case .unexpected(let reason): return "the analysis server answered unexpectedly: \(reason)"
            }
        }
    }

    /// - Parameter base: the server, `http://host:port`; the store's prefix is
    ///   added here.
    public init(base: URL, token: String?, session: URLSession = .shared) {
        self.base = base
        self.token = token?.isEmpty == true ? nil : token
        self.session = session
    }

    // MARK: - Calls

    public func hello() async throws -> ServedStoreProtocol.Hello {
        let hello: ServedStoreProtocol.Hello = try await json("GET", "hello")
        guard hello.protocolVersion == ServedStoreProtocol.version else {
            throw Failure.unexpected("protocol \(hello.protocolVersion), not \(ServedStoreProtocol.version)")
        }
        return hello
    }

    public func object(_ digest: SHA256Digest) async throws -> Data {
        let data = try await call("GET", "objects/\(digest.hex)")
        guard SHA256Digest(data: data) == digest else {
            throw CodeAnalysisError.objectCorrupt(digest.hex)
        }
        return data
    }

    /// A cut object's root (`ContentStore.objectRoot`); nil when the object is
    /// not cut, is not there, or the server is older than the call: all three
    /// are read whole, or found missing, by `object`.
    public func objectRoot(_ digest: SHA256Digest) async throws -> Data? {
        do {
            return try await call("GET", "objects/\(digest.hex)/root")
        } catch Failure.refused(let status, _, _) where status == 404 {
            return nil
        }
    }

    /// Objects as gzip files, each checked against its name: as many requests
    /// as it takes, and no entry for an object the server does not have. A
    /// server older than the call refuses it with 404.
    public func gzippedObjects(_ digests: [SHA256Digest]) async throws -> [SHA256Digest: Data] {
        var files: [SHA256Digest: Data] = [:]
        var start = 0
        while start < digests.count {
            let names = Array(digests[start..<min(start + ServedStoreProtocol.Parts.limit, digests.count)])
            start += names.count
            let answer = try await call("POST", "objects/parts",
                                        body: try encoder.encode(ServedStoreProtocol.Parts(sha256: names)),
                                        timeout: 300)
            try Self.read(frames: answer, naming: names, into: &files)
        }
        return files
    }

    /// The same as `object`, for `ContentStore.objectSource`, which is called
    /// from synchronous code off the main actor — usually from inside a task,
    /// blocking a thread of the cooperative pool. So the wait needs no task:
    /// `blocking` here would starve once the pool is full of such waits, and
    /// the answer comes back at the waiting thread's own QoS.
    public func objectBlocking(_ digest: SHA256Digest) throws -> Data {
        let data = try waited(try request("GET", "objects/\(digest.hex)", query: [:], body: nil, timeout: 20))
        guard SHA256Digest(data: data) == digest else {
            throw CodeAnalysisError.objectCorrupt(digest.hex)
        }
        return data
    }

    /// The same as `objectRoot`, for `ContentStore.partSource`.
    public func objectRootBlocking(_ digest: SHA256Digest) throws -> Data? {
        do {
            return try waited(try request("GET", "objects/\(digest.hex)/root", query: [:], body: nil, timeout: 20))
        } catch Failure.refused(let status, _, _) where status == 404 {
            return nil
        }
    }

    /// The same as `gzippedObjects`, for `ContentStore.partSource`.
    public func gzippedObjectsBlocking(_ digests: [SHA256Digest]) throws -> [SHA256Digest: Data] {
        try batches(of: digests) { names in
            try waited(try request("POST", "objects/parts", query: [:],
                                   body: try encoder.encode(ServedStoreProtocol.Parts(sha256: names)), timeout: 300))
        }
    }

    private func waited(_ request: URLRequest) throws -> Data {
        let box = BlockingResult<Data>()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            box.value = Result {
                if let error { throw unreachable(error) }
                guard let data, let response else { throw Failure.unexpected("not an HTTP answer") }
                return try checked(data, response)
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try box.value!.get()
    }

    private func batches(of digests: [SHA256Digest],
                         _ ask: ([SHA256Digest]) throws -> Data) throws -> [SHA256Digest: Data] {
        var files: [SHA256Digest: Data] = [:]
        var start = 0
        while start < digests.count {
            let names = Array(digests[start..<min(start + ServedStoreProtocol.Parts.limit, digests.count)])
            start += names.count
            try Self.read(frames: try ask(names), naming: names, into: &files)
        }
        return files
    }

    private static func read(frames answer: Data, naming names: [SHA256Digest],
                             into files: inout [SHA256Digest: Data]) throws {
        var at = answer.startIndex
        for name in names {
            guard answer.distance(from: at, to: answer.endIndex) >= 72,
                  String(decoding: answer[at..<(at + 64)], as: UTF8.self) == name.hex else {
                throw Failure.unexpected("the answer does not name \(name.hex) where it should")
            }
            let length = answer[(at + 64)..<(at + 72)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            at += 72
            guard length <= UInt64(answer.distance(from: at, to: answer.endIndex)) else {
                throw Failure.unexpected("the answer ends inside \(name.hex)")
            }
            let end = at + Int(length)
            if length > 0 {
                let file = Data(answer[at..<end])
                guard let bytes = Gzip.decompress(file), SHA256Digest(data: bytes) == name else {
                    throw CodeAnalysisError.objectCorrupt(name.hex)
                }
                files[name] = file
            }
            at = end
        }
        guard at == answer.endIndex else { throw Failure.unexpected("the answer holds more than was asked") }
    }

    /// Waits on this thread for an async call. Only off the main actor, and
    /// never from inside a task: the call needs a thread of the cooperative
    /// pool, and this one blocks.
    public static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = BlockingResult<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.value!.get()
    }

    public func hasObject(_ digest: SHA256Digest) async throws -> Bool {
        do {
            _ = try await call("HEAD", "objects/\(digest.hex)")
            return true
        } catch Failure.refused(status: 404, _, _) {
            return false
        }
    }

    @discardableResult
    public func putObject(_ data: Data) async throws -> SHA256Digest {
        let digest = SHA256Digest(data: data)
        if try await hasObject(digest) { return digest }
        _ = try await call("PUT", "objects/\(digest.hex)", body: data)
        return digest
    }

    public func modules() async throws -> [ServedModule] {
        let answer: ServedStoreProtocol.Modules = try await json("GET", "analyses")
        return answer.modules
    }

    public func module(_ module: SHA256Digest) async throws -> ServedModule {
        try await json("GET", "analyses/\(module.hex)")
    }

    /// `ContentStore.putAnalysis` on the server: the artifact is put first,
    /// then the manifest naming it.
    @discardableResult
    public func putAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data,
                            source: SourceIdentity = SourceIdentity(),
                            reading: AnalysisReading? = nil, replace: Bool = false,
                            discardReading: Bool = false) async throws -> AnalysisManifest {
        let digest = try await putObject(artifact)
        let request = ServedStoreProtocol.PutAnalysis(
            module: module, recipe: recipe, artifact: digest, source: source, reading: reading,
            replace: replace ? true : nil, discardReading: discardReading ? true : nil)
        return try await json("POST", "analyses", body: try encoder.encode(request))
    }

    @discardableResult
    public func recordRevision(module: SHA256Digest, reading: AnalysisReading,
                               artifact: SHA256Digest? = nil,
                               by: String? = nil) async throws -> ReviewHistory {
        let body = try encoder.encode(ServedStoreProtocol.RecordRevision(reading: reading, artifact: artifact,
                                                                         by: by))
        return try await json("POST", "reviews/\(module.hex)", body: body)
    }

    public func reviewHistory(module: SHA256Digest) async throws -> ReviewHistory? {
        do {
            let history: ReviewHistory = try await json("GET", "reviews/\(module.hex)")
            return history
        } catch Failure.refused(status: 404, _, _) {
            return nil
        }
    }

    /// The library registry's index on the server.
    public func libraryIndex() async throws -> LibraryIndex {
        try await json("GET", "library")
    }

    public func libraryHistory(id: String) async throws -> LibraryHistory? {
        do {
            let history: LibraryHistory = try await json("GET", "library/history/\(id)")
            return history
        } catch Failure.refused(status: 404, _, _) {
            return nil
        }
    }

    /// `ContentStore.putLibraryEntries` on the server.
    @discardableResult
    public func putLibraryEntries(module: SHA256Digest, rev: Int?, by: String?, proposals: [LibraryProposal],
                                  take: LibraryTake = .none, dryRun: Bool = false)
        async throws -> LibraryWriteResult {
        let body = try encoder.encode(ServedStoreProtocol.PutLibrary(
            module: module, rev: rev, by: by, proposals: proposals,
            take: take.all ? true : nil, reason: take.all ? take.reason : nil,
            takeIDs: take.all ? nil : (take.ids.isEmpty ? nil : take.ids.sorted()),
            reasons: take.all || take.ids.isEmpty ? nil : take.reasons,
            dryRun: dryRun ? true : nil))
        return try await json("POST", "library", body: body)
    }

    public func conflicts() async throws -> [AnalysisManifest] {
        try await json("GET", "conflicts")
    }

    public func refs() async throws -> [AnalysisRef] {
        try await json("GET", "refs")
    }

    @discardableResult
    public func setRef(_ name: String, analyses: [AnalysisKey]) async throws -> AnalysisRef {
        let body = try encoder.encode(ServedStoreProtocol.SetRef(analyses: analyses))
        return try await json("PUT", "refs/\(name)", body: body)
    }

    public func removeRef(_ name: String) async throws {
        _ = try await call("DELETE", "refs/\(name)")
    }

    /// A bundle sent to the server's `importBundle`; the answer is its report.
    public func importBundle(_ bundle: Data) async throws -> BundleImport {
        try await json("POST", "import", body: bundle)
    }

    public func exportBundle(_ keys: [AnalysisKey]) async throws -> Data {
        try await call("POST", "export", body: try encoder.encode(ServedStoreProtocol.Export(keys: keys)))
    }

    public func verify() async throws -> [String] {
        // The server unpacks and hashes every object before it answers.
        let answer: ServedStoreProtocol.Problems = try await json("GET", "verify", timeout: 3600)
        return answer.problems
    }

    /// Waits up to `wait` seconds for a change after `since` in `epoch`.
    public func changes(since: Int, epoch: String, wait: Int) async throws -> ServedStoreProtocol.Changes {
        try await json("GET", "changes", query: ["since": String(since), "epoch": epoch,
                                                 "wait": String(wait)],
                       timeout: TimeInterval(wait + 30))
    }

    // MARK: - Transport

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func json<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    body: Data? = nil, timeout: TimeInterval = 20) async throws -> T {
        let data = try await call(method, path, query: query, body: body, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.unexpected("\(method) \(path): \(error)")
        }
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:],
                      body: Data? = nil, timeout: TimeInterval = 20) async throws -> Data {
        let request = try request(method, path, query: query, body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw unreachable(error)
        }
        return try checked(data, response)
    }

    private func request(_ method: String, _ path: String, query: [String: String],
                         body: Data?, timeout: TimeInterval) throws -> URLRequest {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + ServedStoreProtocol.prefix + "/" + path
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        guard let url = components.url else { throw Failure.unexpected("cannot address \(path)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func unreachable(_ error: Error) -> Failure {
        .unreachable("\(base.absoluteString): \(error.localizedDescription)")
    }

    private func checked(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw Failure.unexpected("not an HTTP answer")
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(ServedStoreProtocol.Failure.self, from: data)
            let message = failure?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw Failure.refused(status: http.statusCode, message: message, rights: failure?.rights ?? [])
        }
        return data
    }
}

final class BlockingResult<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}
