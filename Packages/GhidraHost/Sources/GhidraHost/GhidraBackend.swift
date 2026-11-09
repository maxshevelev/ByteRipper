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
    /// Asks what a write would do: the owner runs, no lease is taken.
    func previewCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data
    /// `options` decide what this review's version replaces: a conflicting
    /// type's shared copy (a layout published wrong) or a library registry
    /// entry for the same body (with the reason the history keeps).
    func publishModule(_ module: SHA256Digest, by: String, options: GhidraHost.PublishOptions) async throws -> Data
    /// What a publish would store, exported, and nothing written anywhere.
    /// `takeTypeConflicts` answers what a publish would replace in the shared
    /// archive, `takeLibrary` which registry entries it would take and which
    /// conflicts it would leave; nothing is written either way.
    func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool,
                        takeLibrary: LibraryTake) async throws -> Data
    /// The module taken into work: only its holder writes and publishes it,
    /// until it gives it back or an administrator closes the lease.
    func takeModule(_ module: SHA256Digest) async throws -> Data
    /// The module given back: what the lease changed published first, or with
    /// `discard` nothing published and the unpublished changes dropped.
    func releaseModule(_ module: SHA256Digest, by: String, discard: Bool) async throws -> Data
    /// The module against the library registry: its matches, the entries
    /// applied, a candidate taken or declined, one entry read.
    func library(_ module: SHA256Digest, _ request: GhidraHost.LibraryRequest) async throws -> Data
    /// The tagged library functions short of the bar, as the owner offers
    /// them; nil when no owner runs for the module — a body too short for
    /// Function ID to hash is a fact only Ghidra has.
    /// Whether the module's owner runs and holds a program the store has not
    /// got; nil when no owner runs for it.
    func ownerHasUnpublishedWrites(_ module: SHA256Digest) async throws -> Bool?
    /// The module's kept project let go: its owner stopped and the folder
    /// moved to the Trash. Nothing of the analysis store is touched.
    func forgetModule(_ module: SHA256Digest) async throws -> Data
    /// Where each module's last published analysis names a type.
    func typeUses(name: String, limit: Int) async throws -> Data
    /// A report about a tool, kept where the tools' maintainers read it.
    func reportIssue(_ report: IssueBook.Report) async throws -> Data
    /// This reporter's reports, with the answers of the resolved ones.
    func myIssues(limit: Int) async throws -> Data
    /// A call on the review board (`TicketBook`).
    func tickets(_ request: TicketBook.Request) async throws -> Data
    /// A call on the shared types' proposals (`TypeProposalBook`).
    func typeProposals(_ request: TypeProposalBook.Request) async throws -> Data
}

public extension GhidraBackend {
    /// A backend with no owner of its own to ask.
    func libraryShortfalls(_ module: SHA256Digest) async throws -> [GhidraHost.LibraryShortfall]? { nil }
}

/// A backend with no analysis server behind it — a test's stand-in. The calls
/// only a server or a host answers say so here. They are defaults of this
/// protocol and not of `GhidraBackend`, so a backend that passes calls on
/// (the app's, which picks the server or this Mac's host per call) has to
/// pass every one: a forgotten one fails to compile instead of answering
/// "there is no analysis server" while there is one.
public protocol GhidraBackendWithoutServer: GhidraBackend {}

public extension GhidraBackendWithoutServer {
    func ownerHasUnpublishedWrites(_ module: SHA256Digest) async throws -> Bool? { nil }
    /// A backend that keeps no projects of its own.
    func forgetModule(_ module: SHA256Digest) async throws -> Data {
        throw GhidraHostError(.install, "this backend keeps no projects to forget")
    }
    func typeUses(name: String, limit: Int) async throws -> Data {
        throw GhidraHostError(.install, "this backend reads no store")
    }
    func reportIssue(_ report: IssueBook.Report) async throws -> Data {
        throw GhidraHostError(.install, "this backend keeps no reports: there is no analysis server to send it to. "
            + "Tell the person instead, with the call, its arguments and what came back.")
    }
    func myIssues(limit: Int) async throws -> Data {
        throw GhidraHostError(.install, "this backend keeps no reports: there is no analysis server to read them from.")
    }
    func tickets(_ request: TicketBook.Request) async throws -> Data {
        throw GhidraHostError(.install, "this backend keeps no review board: there is no analysis server to keep it.")
    }
    func typeProposals(_ request: TypeProposalBook.Request) async throws -> Data {
        throw GhidraHostError(.install, "this backend keeps no type proposals: there is no analysis server to keep them.")
    }
}

public extension GhidraBackend {
    func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try await releaseModule(module, by: by, discard: false)
    }

    /// The conflicts left in this module.
    func publishModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try await publishModule(module, by: by, options: GhidraHost.PublishOptions())
    }

    /// A backend with no shared archive of its own to ask.
    func publishPreview(_ module: SHA256Digest) async throws -> Data {
        try await publishPreview(module, takeTypeConflicts: false, takeLibrary: .none)
    }

    func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data {
        try await publishPreview(module, takeTypeConflicts: takeTypeConflicts, takeLibrary: .none)
    }

    /// A backend that knows no library decisions answers the preview it can.
    func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool,
                        takeLibrary: LibraryTake) async throws -> Data {
        try await publishPreview(module, takeTypeConflicts: takeTypeConflicts)
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
    public var libraryError: String?
    public var staleLinks: [GhidraHost.StaleLink]?
    /// The kept project the store holds for this revision now.
    public var project: ProjectRecord?
    /// Why the project could not be kept: the revision is stored either way.
    public var projectError: String?
    /// Why the review's types could not be merged into the shared archive.
    public var typesError: String?
    /// The shared types' version the publish made, when it changed the archive.
    public var typesVersion: Int?

    public init(_ publication: GhidraHost.Publication?) {
        manifest = publication?.manifest
        typeConflicts = publication?.typeConflicts ?? []
        typeConflictsTaken = publication?.typeConflictsTaken ?? []
        typeConflictOrigins = publication?.typeConflictOrigins ?? [:]
        library = publication?.library
        libraryError = publication?.libraryError
        staleLinks = publication.map(\.staleLinks).flatMap { $0.isEmpty ? nil : $0 }
        project = publication?.project
        projectError = publication?.projectError
        typesError = publication?.typesError
        typesVersion = publication?.typesVersion
    }

    private enum CodingKeys: String, CodingKey {
        case manifest
        case typeConflicts = "type_conflicts"
        case typeConflictsTaken = "type_conflicts_taken"
        case typeConflictOrigins = "type_conflict_origins"
        case library
        case libraryError = "library_error"
        case staleLinks = "stale_links"
        case project
        case projectError = "project_error"
        case typesError = "types_error"
        case typesVersion = "types_version"
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
        let suffix = query.isEmpty ? "" : "?" + FormQuery.encode(query)
        return await throughRegistry(try await read(module, "/v1/\(call)\(suffix)"), module: module, call: call)
    }

    public func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
        try await write(module, "/v1/\(call)", body: body)
    }

    public func previewCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
        try await preview(module, "/v1/\(call)", body: body)
    }

    public func publishModule(_ module: SHA256Digest, by: String,
                              options: GhidraHost.PublishOptions) async throws -> Data {
        try Self.encode(PublishAnswer(try await publish(module, by: by, options: options)))
    }

    public func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool,
                               takeLibrary: LibraryTake) async throws -> Data {
        try await preview(module, takeTypeConflicts: takeTypeConflicts, takeLibrary: takeLibrary)
    }

    public func takeModule(_ module: SHA256Digest) async throws -> Data {
        try Self.encode(try await take(module))
    }

    public func library(_ module: SHA256Digest, _ request: GhidraHost.LibraryRequest) async throws -> Data {
        try await library(module, request, holder: nil)
    }

    public func releaseModule(_ module: SHA256Digest, by: String, discard: Bool) async throws -> Data {
        try Self.encode(PublishAnswer(try await release(module, by: by, discard: discard)))
    }

    public func forgetModule(_ module: SHA256Digest) async throws -> Data {
        try Self.encode(["trashed": try await forget(module).path])
    }

    /// Reported by this host's own holder — the server's local MCP.
    public func reportIssue(_ report: IssueBook.Report) async throws -> Data {
        try await reportIssue(report, by: configuration.holder)
    }

    public nonisolated func reportIssue(_ report: IssueBook.Report, by reporter: String) async throws -> Data {
        guard let issues else {
            throw GhidraHostError(.install, "this host keeps no reports: there is no analysis server to send it to. "
                + "Tell the person instead, with the call, its arguments and what came back.")
        }
        return try IssueBook.encoder.encode(try await issues.report(report, by: reporter))
    }

    public func myIssues(limit: Int) async throws -> Data {
        try await myIssues(by: configuration.holder, limit: limit)
    }

    /// Called by this host's own holder — the server's local MCP.
    public func tickets(_ request: TicketBook.Request) async throws -> Data {
        try await ticketCall(request, holder: configuration.holder)
    }

    public func typeProposals(_ request: TypeProposalBook.Request) async throws -> Data {
        try await typeProposalCall(request, holder: configuration.holder)
    }

    public nonisolated func myIssues(by reporter: String, limit: Int) async throws -> Data {
        guard let issues else {
            throw GhidraHostError(.install, "this host keeps no reports: there is no analysis server to read them from.")
        }
        return try IssueBook.encoder.encode(await issues.mine(reporter, limit: limit))
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

    public func previewCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
        try await self.call("POST", "modules/\(module.hex)/preview/\(call)", body: body)
    }

    public func forgetModule(_ module: SHA256Digest) async throws -> Data {
        try await call("DELETE", "modules/\(module.hex)")
    }

    public func typeUses(name: String, limit: Int) async throws -> Data {
        try await call("GET", "type-uses", query: ["name": name, "limit": String(limit)])
    }

    public func publishModule(_ module: SHA256Digest, by: String,
                              options: GhidraHost.PublishOptions) async throws -> Data {
        var query = ["by": by]
        if options.takeTypeConflicts { query["take_type_conflicts"] = "1" }
        let body = try Self.libraryDecision(options.takeLibrary, query: &query)
        return try await call("POST", "modules/\(module.hex)/publish", query: query, body: body,
                              timeout: 3600)
    }

    /// A publish's library decision on the wire. A take of every conflict is
    /// the query the route has always read; entries named, and the reasons for
    /// those it moves, go in the body.
    private static func libraryDecision(_ take: LibraryTake, query: inout [String: String]) throws -> Data {
        var body: [String: Any] = [:]
        if take.all {
            query["take_library_conflicts"] = "1"
            query["library_reason"] = take.reason
        } else if !take.ids.isEmpty {
            body["take_library_conflicts"] = take.ids.sorted()
            body["library_reasons"] = take.reasons
        }
        if !take.entryReasons.isEmpty { body["entry_reasons"] = take.entryReasons }
        return body.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool,
                               takeLibrary: LibraryTake) async throws -> Data {
        var query = ["dry_run": "1"]
        if takeTypeConflicts { query["take_type_conflicts"] = "1" }
        let body = try Self.libraryDecision(takeLibrary, query: &query)
        return try await call("POST", "modules/\(module.hex)/publish", query: query, body: body,
                              timeout: 3600)
    }

    public func takeModule(_ module: SHA256Digest) async throws -> Data {
        try await call("POST", "modules/\(module.hex)/lease")
    }

    public func releaseModule(_ module: SHA256Digest, by: String, discard: Bool) async throws -> Data {
        var query = ["by": by]
        if discard { query["discard"] = "1" }
        return try await call("POST", "modules/\(module.hex)/release", query: query, timeout: 3600)
    }

    public func library(_ module: SHA256Digest, _ request: GhidraHost.LibraryRequest) async throws -> Data {
        try await call("POST", "modules/\(module.hex)/library", body: try JSONEncoder().encode(request),
                       timeout: 1800)
    }

    public func reportIssue(_ report: IssueBook.Report) async throws -> Data {
        try await call("POST", "issues", body: try JSONEncoder().encode(report), timeout: 30)
    }

    public func myIssues(limit: Int) async throws -> Data {
        try await call("GET", "issues/mine", query: ["limit": String(limit)], timeout: 20)
    }

    public func tickets(_ request: TicketBook.Request) async throws -> Data {
        try await call("POST", "tickets", body: try JSONEncoder().encode(request), timeout: 30)
    }

    /// A proposal reads the module's publish first: as long as a dry run.
    public func typeProposals(_ request: TypeProposalBook.Request) async throws -> Data {
        try await call("POST", "type-proposals", body: try JSONEncoder().encode(request), timeout: 3600)
    }

    /// The server's answer: nil when no owner has the module open. A server
    /// older than the route answers 404, which is thrown: unknown, not "not
    /// open".
    public func ownerHasUnpublishedWrites(_ module: SHA256Digest) async throws -> Bool? {
        let live = try JSONDecoder().decode(GhidraLive.self, from: try await call("GET", "live/\(module.hex)", timeout: 20))
        return live.live ? (live.unpublishedWrites ?? false) : nil
    }

    /// The review kit's manifest (`ReviewKit.Manifest`), and one of its files.
    public func kitManifest() async throws -> Data { try await call("GET", "kit", timeout: 20) }
    public func kitFile(_ path: String) async throws -> Data { try await call("GET", "kit/\(path)", timeout: 20) }

    /// The kit's source for the app's `ReviewKitCache`.
    public var kitSource: ReviewKitCache.Source {
        ReviewKitCache.Source(manifest: { try await kitManifest() }, file: { try await kitFile($0) })
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                      timeout: TimeInterval = 600) async throws -> Data {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/ghidra/v1/" + path
        if !query.isEmpty {
            components.percentEncodedQuery = FormQuery.encode(query)
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

/// `GET /ghidra/v1/live/:module`: whether an owner has the module open, and
/// whether its program holds writes the store has not got.
public struct GhidraLive: Codable, Equatable, Sendable {
    public let live: Bool
    public let unpublishedWrites: Bool?

    public init(live: Bool, unpublishedWrites: Bool?) {
        self.live = live
        self.unpublishedWrites = unpublishedWrites
    }

    enum CodingKeys: String, CodingKey {
        case live
        case unpublishedWrites = "unpublished_writes"
    }
}
