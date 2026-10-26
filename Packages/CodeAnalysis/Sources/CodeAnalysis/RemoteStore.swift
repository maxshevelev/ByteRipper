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
        /// The server answered with a refusal.
        case refused(status: Int, message: String)
        /// The answer is not what this protocol version expects.
        case unexpected(String)

        public var description: String {
            switch self {
            case .unreachable(let reason):
                return "no byteripper-server answers at \(reason) — is it running, and listening on that address?"
            case .refused(_, let message): return message
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

    /// The same as `object`, for `ContentStore.objectSource`, which is called
    /// from synchronous code off the main actor.
    public func objectBlocking(_ digest: SHA256Digest) throws -> Data {
        try Self.blocking { try await object(digest) }
    }

    /// Waits on this thread for an async call. Only off the main actor, and
    /// never from inside a task the call would need: it blocks the thread.
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
        } catch Failure.refused(status: 404, _) {
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
                               by: String? = nil) async throws -> ReviewHistory {
        let body = try encoder.encode(ServedStoreProtocol.RecordRevision(reading: reading, by: by))
        return try await json("POST", "reviews/\(module.hex)", body: body)
    }

    public func reviewHistory(module: SHA256Digest) async throws -> ReviewHistory? {
        do {
            let history: ReviewHistory = try await json("GET", "reviews/\(module.hex)")
            return history
        } catch Failure.refused(status: 404, _) {
            return nil
        }
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
        let answer: ServedStoreProtocol.Problems = try await json("GET", "verify")
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable("\(base.absoluteString): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.unexpected("not an HTTP answer")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServedStoreProtocol.Failure.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw Failure.refused(status: http.statusCode, message: message)
        }
        return data
    }
}

final class BlockingResult<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}
