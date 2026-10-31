import CodeAnalysis
import Foundation

/// What the agent's tools need of a Ghidra host: the host in this process, or
/// a `byteripper-server` reached over the network. The answers are the owner's
/// JSON as it sent it.
public protocol GhidraBackend: Sendable {
    func listModules() async throws -> Data
    /// Make the module's project if it has none, and start its owner.
    func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data
    /// Start the owner of a module that already has a project.
    func openModule(_ module: SHA256Digest) async throws -> Data
    func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data
    func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data
    /// `options` decide what this review's version replaces: a conflicting
    /// type's shared copy (a layout published wrong) or a library registry
    /// entry for the same body (with the reason the history keeps).
    func publishModule(_ module: SHA256Digest, by: String, options: GhidraHost.PublishOptions) async throws -> Data
    /// What a publish would store, exported, and nothing written anywhere.
    /// `takeTypeConflicts` answers what a publish would replace in the shared
    /// archive; nothing is written either way.
    func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data
    func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data
}

public extension GhidraBackend {
    /// The conflicts left in this module.
    func publishModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try await publishModule(module, by: by, options: GhidraHost.PublishOptions())
    }

    /// A backend with no shared archive of its own to ask.
    func publishPreview(_ module: SHA256Digest) async throws -> Data {
        try await publishPreview(module, takeTypeConflicts: false)
    }
}

/// The answer a backend gives about a publish — the host in this process and
/// a server alike.
public struct PublishAnswer: Codable, Sendable {
    public var manifest: AnalysisManifest?
    public var typeConflicts: [String]
    public var typeConflictsTaken: [String]
    public var typeConflictOrigins: [String: String]
    /// What the library registry made of the module's library functions.
    public var library: LibraryWriteResult?
    public var libraryBelowBar: [GhidraHost.LibraryShortfall]?
    public var libraryError: String?

    public init(_ publication: GhidraHost.Publication?) {
        manifest = publication?.manifest
        typeConflicts = publication?.typeConflicts ?? []
        typeConflictsTaken = publication?.typeConflictsTaken ?? []
        typeConflictOrigins = publication?.typeConflictOrigins ?? [:]
        library = publication?.library
        libraryBelowBar = publication.map(\.libraryBelowBar).flatMap { $0.isEmpty ? nil : $0 }
        libraryError = publication?.libraryError
    }

    private enum CodingKeys: String, CodingKey {
        case manifest
        case typeConflicts = "type_conflicts"
        case typeConflictsTaken = "type_conflicts_taken"
        case typeConflictOrigins = "type_conflict_origins"
        case library
        case libraryBelowBar = "library_below_bar"
        case libraryError = "library_error"
    }
}

extension GhidraHost: GhidraBackend {
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public func listModules() async throws -> Data {
        try Self.encode(await summaries())
    }

    public func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data {
        try await create(module: image, name: name, source: .init(document: document, node: node))
        return try await read(SHA256Digest(data: image), "/v1/hello")
    }

    public func openModule(_ module: SHA256Digest) async throws -> Data {
        try await read(module, "/v1/hello")
    }

    public func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data {
        var components = URLComponents()
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        let suffix = query.isEmpty ? "" : "?" + (components.percentEncodedQuery ?? "")
        return try await read(module, "/v1/\(call)\(suffix)")
    }

    public func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
        try await write(module, "/v1/\(call)", body: body)
    }

    public func publishModule(_ module: SHA256Digest, by: String,
                              options: GhidraHost.PublishOptions) async throws -> Data {
        try Self.encode(PublishAnswer(try await publish(module, by: by, options: options)))
    }

    public func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data {
        try await preview(module, takeTypeConflicts: takeTypeConflicts)
    }

    public func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try Self.encode(PublishAnswer(try await release(module, by: by)))
    }
}

/// A `byteripper-server`'s Ghidra role, over `/ghidra/v1`: what the app's
/// tools relay to when the analyses are kept on a server.
public struct GhidraRemote: GhidraBackend {
    public let base: URL
    private let token: String?

    public init(base: URL, token: String?) {
        self.base = base
        self.token = token?.isEmpty == true ? nil : token
    }

    public func listModules() async throws -> Data { try await call("GET", "modules") }

    public func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data {
        var query = ["name": name]
        query["document"] = document
        query["node"] = node
        return try await call("POST", "modules", query: query, body: image, timeout: 1800)
    }

    public func openModule(_ module: SHA256Digest) async throws -> Data {
        try await call("GET", "modules/\(module.hex)/hello")
    }

    public func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data {
        try await self.call("GET", "modules/\(module.hex)/\(call)", query: query)
    }

    public func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
        try await self.call("POST", "modules/\(module.hex)/write/\(call)", body: body)
    }

    public func publishModule(_ module: SHA256Digest, by: String,
                              options: GhidraHost.PublishOptions) async throws -> Data {
        var query = ["by": by]
        if options.takeTypeConflicts { query["take_type_conflicts"] = "1" }
        if options.takeLibraryConflicts { query["take_library_conflicts"] = "1" }
        query["library_reason"] = options.libraryReason
        return try await call("POST", "modules/\(module.hex)/publish", query: query, timeout: 3600)
    }

    public func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data {
        var query = ["dry_run": "1"]
        if takeTypeConflicts { query["take_type_conflicts"] = "1" }
        return try await call("POST", "modules/\(module.hex)/publish", query: query, timeout: 3600)
    }

    public func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try await call("POST", "modules/\(module.hex)/release", query: ["by": by], timeout: 3600)
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                      timeout: TimeInterval = 600) async throws -> Data {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/ghidra/v1/" + path
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body ?? (method == "POST" ? Data() : nil)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GhidraHostError(.owner, "the analysis server cannot be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = failure?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw GhidraHostError(.refused, message, status: status, rights: failure?["rights"] as? [String] ?? [])
        }
        return data
    }
}
