import CodeAnalysis
import Darwin
import Foundation

/// The owners of the modules' kept projects, hosted: started on demand,
/// called over loopback, written to under one lease per module, published
/// into a store (`Design/SERVER_PLAN.md` §6).
///
/// The host holds the lease, not its client: it takes it on the first write
/// to a module, keeps it while writes come, and gives it back — publishing —
/// when the client is done. A client never sees a token (§7.3).
public actor GhidraHost {
    public struct Configuration: Sendable {
        public var projectsRoot: URL
        /// Nil: `GhidraInstall.find`'s choice.
        public var ghidraHome: URL?
        public var sources: OwnerSources
        /// Seconds without a call before an owner saves and exits; 0 never.
        public var idle: Int
        /// Who holds the leases the host takes, as the owner logs them.
        public var holder: String
        public var startTimeout: TimeInterval

        public init(projectsRoot: URL = GhidraHost.defaultProjectsRoot, ghidraHome: URL? = nil,
                    sources: OwnerSources = .checkout, idle: Int = 1800,
                    holder: String = "\(NSUserName()) via byteripper-server",
                    startTimeout: TimeInterval = 300) {
            self.projectsRoot = projectsRoot
            self.ghidraHome = ghidraHome
            self.sources = sources
            self.idle = idle
            self.holder = holder
            self.startTimeout = startTimeout
        }
    }

    public static var defaultProjectsRoot: URL {
        CodeAnalysisPaths.defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("GhidraProjects", isDirectory: true)
    }

    /// What a publish stored, and the review types another review defines
    /// differently, which stayed in this program (§6.5) — with the module
    /// that wrote the shared copy of each, where the archive's sidecar knows it.
    /// A link in a comment or the description that still shows a default name
    /// after its target was renamed.
    public struct StaleLink: Codable, Equatable, Sendable {
        /// The comment's address, or `description`.
        public var at: String
        public var kind: String
        public var text: String
        public var target: String
        public var name: String
    }

    public struct Publication: Sendable {
        public var manifest: AnalysisManifest
        public var typeConflicts: [String]
        /// The shared types this publish replaced with its own.
        public var typeConflictsTaken: [String]
        public var typeConflictOrigins: [String: String]
        /// What the library registry made of this module's library functions
        /// reviewed to the bar; nil when the publish offered it nothing.
        public var library: LibraryWriteResult?
        /// The tagged library functions short of the registry's bar, with
        /// what keeps each from it.
        public var libraryBelowBar: [LibraryShortfall]
        /// Why the registry could not be offered the functions, when it could
        /// not: the publish itself is stored either way.
        public var libraryError: String?
        /// Links whose text is a default name while the target has a real one.
        public var staleLinks: [StaleLink]

        public init(manifest: AnalysisManifest, typeConflicts: [String], typeConflictsTaken: [String] = [],
                    typeConflictOrigins: [String: String] = [:], library: LibraryWriteResult? = nil,
                    libraryBelowBar: [LibraryShortfall] = [], libraryError: String? = nil,
                    staleLinks: [StaleLink] = []) {
            self.manifest = manifest
            self.typeConflicts = typeConflicts
            self.typeConflictsTaken = typeConflictsTaken
            self.typeConflictOrigins = typeConflictOrigins
            self.library = library
            self.libraryBelowBar = libraryBelowBar
            self.libraryError = libraryError
            self.staleLinks = staleLinks
        }
    }

    /// What a publish may decide beyond storing the review.
    public struct PublishOptions: Equatable, Sendable {
        /// Replace the shared copy of each conflicting type with this module's.
        public var takeTypeConflicts: Bool
        /// Which conflicting library entries this module's review makes the
        /// entry's next version — all of them with one reason, or those it
        /// names, each with its own.
        public var takeLibrary: LibraryTake

        public init(takeTypeConflicts: Bool = false, takeLibrary: LibraryTake = .none) {
            self.takeTypeConflicts = takeTypeConflicts
            self.takeLibrary = takeLibrary
        }
    }

    /// A tagged library function the registry did not take, and why.
    public struct LibraryShortfall: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var kind: String
        /// `name`, `plate`, `comments`, `params`, `locals`, or `too_short` —
        /// a body Function ID does not hash.
        public var gaps: [String]
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var module: String
        public var name: String
        public var running: Bool
        public var reviewed: Bool
        public var published: ProjectState.Published?
        public var leased: Bool
    }

    public let configuration: Configuration
    let writer: AnalysisWriter
    private var install: GhidraInstall?
    private var leases: [SHA256Digest: String] = [:]
    private var starting: [SHA256Digest: Task<OwnerRecord, Error>] = [:]

    public init(configuration: Configuration = Configuration(), writer: AnalysisWriter) {
        self.configuration = configuration
        self.writer = writer
    }

    public func ghidra() throws -> GhidraInstall {
        if let install { return install }
        let found = try GhidraInstall.find(home: configuration.ghidraHome)
        install = found
        return found
    }

    public func project(_ module: SHA256Digest) -> GhidraProject {
        GhidraProject(root: configuration.projectsRoot, module: module)
    }

    // MARK: - The projects

    public func summaries() async -> [Summary] {
        var rows: [Summary] = []
        for project in GhidraProject.all(in: configuration.projectsRoot) {
            guard let state = try? project.state() else { continue }
            rows.append(Summary(module: project.module.hex, name: state.module.name,
                                running: await runningOwner(project) != nil, reviewed: state.reviewed,
                                published: state.published, leased: leases[project.module] != nil))
        }
        return rows
    }

    /// Where each module's last published analysis names a type, by its name
    /// and its tag — `NAME` and `_NAME` are the one type. It reads the store, so
    /// it reaches modules with no project here, and an owner's unpublished
    /// writes are not in it. Outside the actor: it decodes every module's
    /// artifact, and the reviews going on must not wait for that.
    public nonisolated func typeUses(name: String, limit: Int) async throws -> Data {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = trimmed.hasPrefix("_") ? String(trimmed.dropFirst()) : "_" + trimmed
        struct Row: Encodable {
            let module: String
            let name: String
            let revision: Int?
            let uses: CodeTypeUses
        }
        struct Answer: Encodable {
            let names: [String]
            let reads: String
            let modulesRead: Int
            let functions: Int
            let truncated: Bool
            let modules: [Row]
            enum CodingKeys: String, CodingKey {
                case names, reads, functions, truncated, modules
                case modulesRead = "modules_read"
            }
        }
        var rows: [Row] = []
        var functions = 0
        var room = limit
        var truncated = false
        let manifests = try await writer.newestAnalyses().sorted { $0.module.name < $1.module.name }
        for manifest in manifests {
            let data = try await writer.readObject(manifest.artifact.sha256)
            guard let artifact = try? JSONDecoder().decode(CodeArtifact.self, from: data) else { continue }
            let uses = artifact.typeUses(of: [trimmed, tag])
            guard !uses.isEmpty else { continue }
            functions += uses.functions.count
            let shown = Array(uses.functions.prefix(room))
            if shown.count < uses.functions.count { truncated = true }
            room -= shown.count
            rows.append(Row(module: manifest.module.sha256.hex, name: manifest.module.name,
                            revision: manifest.reading?.rev,
                            uses: CodeTypeUses(functions: shown, data: uses.data, types: uses.types,
                                               holdsTheType: uses.holdsTheType)))
        }
        let answer = Answer(names: [trimmed, tag], reads: "each module's last published analysis",
                            modulesRead: manifests.count, functions: functions, truncated: truncated, modules: rows)
        return try JSONEncoder().encode(answer)
    }

    // MARK: - Calls

    /// A read call of the bridge (`/v1/hello`, `/v1/function/0x…`), starting
    /// the module's owner when none runs.
    public func read(_ module: SHA256Digest, _ path: String) async throws -> Data {
        let record = try await owner(of: module)
        return try await Self.call(record.port, "GET", path).data
    }

    /// A call that asks what a write would do: the owner must be up, and no
    /// lease is taken.
    public func preview(_ module: SHA256Digest, _ path: String, body: Data) async throws -> Data {
        let record = try await owner(of: module)
        return try await Self.call(record.port, "POST", path, body: body).data
    }

    /// A write call of the bridge, under the host's lease of the module.
    public func write(_ module: SHA256Digest, _ path: String, body: Data) async throws -> Data {
        let project = self.project(module)
        let record = try await owner(of: module)
        var token = try await lease(module, record)
        let answer: Data
        do {
            answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
        } catch let error as GhidraHostError where error.status == 403 {
            // The lease lapsed between two writes: take it again, once.
            leases[module] = nil
            token = try await lease(module, record)
            answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
        }
        var state = try project.state()
        if !state.reviewed {
            state.reviewed = true
            try project.write(state)
        }
        return answer
    }

    private func lease(_ module: SHA256Digest, _ record: OwnerRecord) async throws -> String {
        if let token = leases[module] { return token }
        let body = try JSONSerialization.data(withJSONObject: ["holder": configuration.holder, "ttl": 3600])
        let data = try await Self.call(record.port, "POST", "/v1/lease", body: body).data
        guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = answer["token"] as? String else {
            throw GhidraHostError(.owner, "the owner gave no lease token")
        }
        leases[module] = token
        return token
    }

    // MARK: - Publish

    /// The program's artifact, its review document and the module's
    /// description, from the owner, into the store.
    ///
    /// A program nobody has reviewed publishes the mechanical reading. A
    /// reviewed one publishes a revision of this project's reading — one more
    /// than the last whenever the artifact, the document or the description
    /// changed — naming the document and the description, which are stored
    /// first, then recorded in the module's history with `by`. The recipe takes the exporter and the Ghidra from the
    /// artifact, the types and passes from what made the project (§5.2).
    public func publish(_ module: SHA256Digest, by: String?,
                        options: PublishOptions = PublishOptions()) async throws -> Publication {
        let project = self.project(module)
        let record = try await owner(of: module)
        var state = try project.state()
        let path = options.takeTypeConflicts ? "/v1/publish?take_type_conflicts=1" : "/v1/publish"
        let (exported, headers) = try await Self.call(record.port, "POST", path, timeout: 3600)
        var raw = exported
        let document = try await Self.call(record.port, "GET", "/v1/review").data
        let description = try await Self.call(record.port, "GET", "/v1/review/description").data
        guard let artifact = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's artifact is not a JSON object")
        }
        let reviewed = headers["x-owner-reviewed"] == "true"
        let conflicts = (headers["x-owner-type-conflicts"] ?? "").split(separator: ",").map(String.init)
        let taken = (headers["x-owner-type-taken"] ?? "").split(separator: ",").map(String.init)
        let origins = Self.typeOrigins(headers["x-owner-type-origins"])
        let last = state.published
        var reading: AnalysisReading?
        var review: SHA256Digest?
        var described: SHA256Digest?
        if reviewed {
            let stored = try await writer.writeObject(document)
            review = stored
            if !description.isEmpty { described = try await writer.writeObject(description) }
            let changed = last?.artifact != SHA256Digest(data: raw).hex || last?.review != stored.hex
                || last?.description != described?.hex
            let rev = max(1, (last?.rev ?? 0) + (changed ? 1 : 0))
            let current = AnalysisReading(project: state.project, rev: rev, review: stored, description: described)
            reading = current
            // The code goes into the store before the revision that names it:
            // a revision without its artifact is one nobody can diff.
            let code = try await writer.writeObject(raw)
            try await writer.writeRevision(module: module, reading: current, artifact: code, by: by)
        }
        // The library registry is offered the module's library functions
        // reviewed to its bar. A failure here is reported, not thrown: the
        // review is already stored.
        var library: LibraryWriteResult?
        var shortfalls: [LibraryShortfall] = []
        var libraryError: String?
        if reviewed {
            do {
                let offer = try Self.libraryOffer(try await Self.call(record.port, "GET", "/v1/library").data,
                                                  artifact: raw)
                shortfalls = offer.shortfalls
                let offered = try await Self.withoutLinked(offer.proposals, writer: writer)
                if !offered.isEmpty {
                    let written = try await writer.writeLibraryEntries(
                        module: module, rev: reading?.rev, by: by, proposals: offered,
                        take: options.takeLibrary)
                    library = written
                    // A store older than take_ids ignores them and answers with
                    // the conflict: say which entries were not taken, rather
                    // than let the publish read as if it had taken them.
                    let missed = options.takeLibrary.ids.intersection(Set(written.conflicts.map(\.id)))
                    if !missed.isEmpty {
                        libraryError = "the store did not take "
                            + missed.sorted().joined(separator: ", ")
                            + ": its server predates take_ids"
                    }
                    // The marks may change what the artifact says of the
                    // registry — a function that became the entry's next
                    // version, one left in conflict: then it is exported
                    // again, and stored in place of the first.
                    if try await markLibrary(module, proposals: offered, result: written) > 0 {
                        let again = try await write(module, "/v1/export", body: Data())
                        if again != raw {
                            raw = again
                            let code = try await writer.writeObject(raw)
                            if var current = reading, current.rev == last?.rev {
                                current.rev += 1
                                reading = current
                                try await writer.writeRevision(module: module, reading: current,
                                                               artifact: code, by: by)
                            }
                        }
                    }
                }
            } catch {
                libraryError = "\(error)"
            }
        }
        let recipe = Self.recipe(for: artifact, types: state.madeWith.types, passes: state.madeWith.passes)
        let program = artifact["program"] as? [String: Any] ?? [:]
        let identity = ModuleIdentity(sha256: module, size: state.module.size, name: state.module.name,
                                      kind: state.module.kind,
                                      language: program["language"] as? String ?? "unknown",
                                      imageBase: program["image_base"] as? String ?? "0x0",
                                      phase: state.module.phase)
        // A mechanical artifact never replaces another — except this project's
        // own last publish, which a new one of the same program supersedes.
        let stored = try await writer.storedAnalysis(module: module, recipe: recipe.id)
        let ours = stored != nil && last != nil && stored?.artifact.sha256.hex == last?.artifact
        let source = SourceIdentity(path: state.source?.path, document: state.source?.document,
                                    node: state.source?.node)
        let manifest = try await writer.writeAnalysis(module: identity, recipe: recipe, artifact: raw,
                                                      source: source, reading: reading, replace: ours)
        // The number the program stood at when this publish stored it: a later
        // one is a write the store has not got. Read after the marks, which
        // save the program themselves.
        let modification = try? await Self.call(record.port, "GET", "/v1/hello", timeout: 10).data
        let hello = modification
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let number = hello.flatMap { $0["modification"] as? Int }
        let writes = hello.flatMap { $0["writes"] as? Int }
        // A publish that stored nothing new keeps its time: `at` says when this
        // revision was published, and a release with no writes publishes none.
        let before = state.published
        let same = before?.artifact == manifest.artifact.sha256.hex && before?.recipe == recipe.id
            && before?.review == review?.hex && before?.description == described?.hex && before?.rev == reading?.rev
        state.published = .init(artifact: manifest.artifact.sha256.hex, recipe: recipe.id, review: review?.hex,
                                description: described?.hex, rev: reading?.rev,
                                at: same ? (before?.at ?? Self.now()) : Self.now(),
                                modification: number, writes: writes)
        state.reviewed = reviewed
        try project.write(state)
        return Publication(manifest: manifest, typeConflicts: conflicts, typeConflictsTaken: taken,
                           typeConflictOrigins: origins, library: library, libraryBelowBar: shortfalls,
                           libraryError: libraryError, staleLinks: await staleLinks(port: record.port))
    }

    /// A report beside a stored publish: failing to read it never fails that.
    private func staleLinks(port: Int) async -> [StaleLink] {
        struct Answer: Decodable {
            var stale_links: [StaleLink]
        }
        guard let data = try? await Self.call(port, "GET", "/v1/stale-links").data else { return [] }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.stale_links ?? []
    }

    /// The functions the registry took or matched carry the version it holds
    /// now, so the next change to one is made on that version; a conflict's
    /// function keeps the mark it had.
    /// Answers how many functions read otherwise in an artifact now.
    func markLibrary(_ module: SHA256Digest, proposals: [LibraryProposal], result: LibraryWriteResult) async throws -> Int {
        let index = try await writer.readLibraryIndex()
        let items = Self.libraryMarks(proposals, result: result, index: index)
        guard !items.isEmpty else { return 0 }
        let data = try await write(module, "/v1/library/mark",
                                   body: try JSONSerialization.data(withJSONObject: ["items": items]))
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["changed"] as? Int ?? 0
    }

    /// The marks a publish leaves: a function the registry took or matched
    /// carries the version it holds; one in conflict, the entry's version and
    /// the one its review was made on.
    static func libraryMarks(_ proposals: [LibraryProposal], result: LibraryWriteResult,
                             index: LibraryIndex) -> [[String: Any]] {
        let accepted = Set((result.added + result.updated + result.unchanged + (result.variants ?? [])).map(\.id))
        let conflicts = Dictionary(result.conflicts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return proposals.compactMap { proposal in
            guard let id = index.bodies[proposal.body.key] ?? proposal.variantOf else { return nil }
            if accepted.contains(id), index.bodies[proposal.body.key] == id, let held = index.entries[id] {
                return ["address": proposal.address, "id": id, "version": held.version]
            }
            if let conflict = conflicts[id] {
                var item: [String: Any] = ["address": proposal.address, "id": id, "version": conflict.version,
                                           "conflict": true]
                item["base"] = conflict.base
                return item
            }
            return nil
        }
    }

    /// The owner's `GET /v1/library`, as the registry takes it: each entry's
    /// object made canonical — sorted keys — so the same review stores the
    /// same object whichever owner wrote it.
    /// A function linked to an entry and not edited since has nothing to say
    /// to the registry, whatever its project still holds: it is offered only
    /// when it is the entry's own review, which completes an older entry.
    static func withoutLinked(_ proposals: [LibraryProposal], writer: any AnalysisWriter) async throws -> [LibraryProposal] {
        guard proposals.contains(where: \.linked) else { return proposals }
        let index = try await writer.readLibraryIndex()
        var kept: [LibraryProposal] = []
        for proposal in proposals {
            guard proposal.linked else { kept.append(proposal); continue }
            guard let (_, held) = index.entry(for: proposal.body) else { continue }
            if LibraryProposal.sameReview(try await writer.readObject(held.entry), proposal.entry) { kept.append(proposal) }
        }
        return kept
    }

    static let notOfTheDescription: Set<String> = ["callers", "callees", "library_entry", "library_kind",
                                                   "review_level", "review_gaps", "body"]

    static func libraryOffer(_ data: Data, artifact: Data? = nil) throws -> (proposals: [LibraryProposal], shortfalls: [LibraryShortfall]) {
        guard let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's library answer is not a JSON object")
        }
        var functions: [UInt64: [String: Any]] = [:]
        if let artifact, let read = try JSONSerialization.jsonObject(with: artifact) as? [String: Any] {
            for function in read["functions"] as? [[String: Any]] ?? [] {
                if let text = function["entry"] as? String, let at = CodeAddress(hex: text) { functions[at.value] = function }
            }
        }
        var proposals: [LibraryProposal] = []
        for item in answer["entries"] as? [[String: Any]] ?? [] {
            guard let body = item["body"] as? [String: Any], let size = body["size"] as? Int,
                  let full = body["full"] as? String, let specific = body["specific"] as? String,
                  let name = item["name"] as? String, let kind = item["kind"] as? String,
                  let address = item["address"] as? String, var entry = item["entry"] as? [String: Any] else {
                throw GhidraHostError(.owner, "the owner's library entry is not complete")
            }
            // The entry holds the function as it reads, so a reader needs no
            // module's copy of it: only what describes it, nothing of its place.
            if let function = functions[CodeAddress(hex: address)?.value ?? 0] {
                entry["function"] = function.filter { !Self.notOfTheDescription.contains($0.key) }
            }
            let canonical = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            proposals.append(LibraryProposal(body: LibraryBody(size: size, full: full, specific: specific),
                                             name: name, kind: kind, address: address, entry: canonical,
                                             variantOf: item["variant_of"] as? String,
                                             codes: item["codes"] as? [String],
                                             role: entry["assert"] as? Bool == true ? "assert" : nil,
                                             basedOn: item["based_on"] as? String,
                                             base: item["base"] as? Int,
                                             signatureReason: item["signature_reason"] as? String,
                                             nameReason: item["name_reason"] as? String,
                                             linked: item["linked"] as? Bool ?? false,
                                             dataReferences: item["data_references"] as? [String],
                                             callees: (item["callees"] as? [[String: Any]])?.map {
                                                 LibraryCallee(name: $0["name"] as? String ?? "", body: $0["body"] as? String)
                                             }))
        }
        let below = try JSONSerialization.data(withJSONObject: answer["below_bar"] ?? [])
        let shortfalls = try JSONDecoder().decode([LibraryShortfall].self, from: below)
        return (proposals, shortfalls)
    }

    /// `NAME=module,…`, the owner's header: which module wrote the shared
    /// version of each type a publish called a conflict.
    static func typeOrigins(_ text: String?) -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        var origins: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, !parts[1].isEmpty { origins[String(parts[0])] = String(parts[1]) }
        }
        return origins
    }

    /// What a publish would store, and nothing stored: the owner exports the
    /// artifact and works out the type conflicts without saving the program or
    /// merging into the shared archive, and the counts, the revision it would
    /// become and those conflicts come back. The export is the cost a publish
    /// already pays; this one pays it to look first.
    func preview(_ module: SHA256Digest, takeTypeConflicts: Bool = false,
                 takeLibrary: LibraryTake = .none) async throws -> Data {
        let project = self.project(module)
        let record = try await owner(of: module)
        let state = try project.state()
        let path = takeTypeConflicts ? "/v1/publish?dry_run=1&take_type_conflicts=1" : "/v1/publish?dry_run=1"
        let (raw, headers) = try await Self.call(record.port, "POST", path, timeout: 3600)
        let document = try await Self.call(record.port, "GET", "/v1/review").data
        let description = try await Self.call(record.port, "GET", "/v1/review/description").data
        guard let artifact = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's artifact is not a JSON object")
        }
        let reviewed = headers["x-owner-reviewed"] == "true"
        let conflicts = (headers["x-owner-type-conflicts"] ?? "").split(separator: ",").map(String.init)
        let artifactDigest = SHA256Digest(data: raw).hex
        let documentDigest = SHA256Digest(data: document).hex
        let descriptionDigest: String? = description.isEmpty ? nil : SHA256Digest(data: description).hex
        let last = state.published
        let changed = last?.artifact != artifactDigest || last?.review != documentDigest
            || last?.description != descriptionDigest
        let functions = artifact["functions"] as? [[String: Any]] ?? []
        let instructions = functions.reduce(0) { $0 + (($1["instructions"] as? [Any])?.count ?? 0) }
        var preview: [String: Any] = [
            "dry_run": true,
            "reviewed": reviewed,
            "changed": changed,
            // A publish writes the registry's states and marks into the artifact,
            // which a preview cannot: the review's hash holds, this one need not.
            "artifact": ["sha256": artifactDigest, "size": raw.count, "before_library_marks": true],
            "document": ["sha256": documentDigest, "size": document.count],
            "functions": functions.count,
            "instructions": instructions,
            "types": (artifact["types"] as? [Any])?.count ?? 0,
            "strings": (artifact["strings"] as? [Any])?.count ?? 0,
            "type_conflicts": conflicts
        ]
        let taken = (headers["x-owner-type-taken"] ?? "").split(separator: ",").map(String.init)
        // Always present, empty included: a reader tells "nothing to take"
        // from "this build has no such field".
        preview["type_conflicts_taken"] = taken
        preview["type_conflict_origins"] = Self.typeOrigins(headers["x-owner-type-origins"])
        preview["stale_links"] = try Self.plain(await staleLinks(port: record.port))
        if let descriptionDigest {
            preview["description"] = ["sha256": descriptionDigest, "size": description.count]
        }
        var revision: Int?
        if reviewed {
            let would = max(1, (last?.rev ?? 0) + (changed ? 1 : 0))
            revision = would
            preview["revision"] = would
        }
        // What the publish would do to the library registry, without doing
        // it: the offer is the owner's, the decision the reader's, and the
        // store answers the would-be result — refusals included — and writes
        // nothing.
        if reviewed {
            do {
                let offer = try Self.libraryOffer(try await Self.call(record.port, "GET", "/v1/library").data,
                                                  artifact: raw)
                preview["library_below_bar"] = try Self.plain(offer.shortfalls)
                let offered = try await Self.withoutLinked(offer.proposals, writer: writer)
                if !offered.isEmpty {
                    let would = try await writer.previewLibraryEntries(
                        module: module, rev: revision, by: nil, proposals: offered,
                        take: takeLibrary)
                    preview["library"] = try Self.plain(would)
                }
            } catch {
                preview["library_error"] = "\(error)"
            }
        }
        return try JSONSerialization.data(withJSONObject: preview, options: [.sortedKeys])
    }

    /// Publish what the lease changed and give the lease back; nil when the
    /// host holds no lease of the module.
    public func release(_ module: SHA256Digest, by: String?) async throws -> Publication? {
        guard let token = leases[module], let record = await runningOwner(project(module)) else {
            leases[module] = nil
            return nil
        }
        let publication = try await publish(module, by: by)
        leases[module] = nil
        _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
        return publication
    }

    /// Save and stop the module's owner.
    @discardableResult
    public func stop(_ module: SHA256Digest) async -> Bool {
        let project = self.project(module)
        guard let record = await runningOwner(project) else { return false }
        leases[module] = nil
        if (try? await Self.call(record.port, "POST", "/v1/stop", timeout: 30)) == nil {
            kill(record.pid, SIGTERM)
        }
        for _ in 0..<100 where Subprocess.isAlive(record.pid) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? FileManager.default.removeItem(at: project.ownerURL)
        return true
    }

    /// The module's kept project let go: its owner stopped, then the folder
    /// `GhidraProjects/<sha>` moved to the Trash — recoverable, and nothing of
    /// the analysis store touched. The revisions, their artifacts and the
    /// shared review types stay; the module opens again from its bytes and is
    /// analysed afresh. Answers where the folder went.
    @discardableResult
    public func forget(_ module: SHA256Digest) async throws -> URL {
        let project = self.project(module)
        guard project.exists else {
            throw GhidraHostError(.project, "no project for \(module.hex): nothing to forget", status: 404)
        }
        _ = await stop(module)
        leases[module] = nil
        var trashed: NSURL?
        try FileManager.default.trashItem(at: project.folder, resultingItemURL: &trashed)
        return (trashed as URL?) ?? project.folder
    }

    // MARK: - Owners

    /// The module's running owner, or a new one.
    func owner(of module: SHA256Digest) async throws -> OwnerRecord {
        let project = self.project(module)
        guard project.exists else {
            throw GhidraHostError(.project, "no project for \(module.hex): open the module first", status: 404)
        }
        if let running = await runningOwner(project, replacingStale: true) { return running }
        if let pending = starting[module] { return try await pending.value }
        // A live owner that does not answer is busy — a publish exporting a
        // large module — not gone: a second one would only fail on Ghidra's
        // project lock.
        if let data = try? Data(contentsOf: project.ownerURL),
           let record = try? JSONDecoder().decode(OwnerRecord.self, from: data), Subprocess.isAlive(record.pid) {
            throw GhidraHostError(.owner, "the module's owner is busy — a publish of a large module can take a "
                                  + "while; try again shortly", status: 503)
        }
        let task = Task { try await self.start(project) }
        starting[module] = task
        defer { starting[module] = nil }
        return try await task.value
    }

    /// A recorded owner whose process lives and answers; nil otherwise.
    ///
    /// With `replacingStale`, an owner running from another build of the jar
    /// than the one the host would start now — one that outlived a server
    /// restarted on new sources — is stopped, so the caller starts a new one:
    /// an old owner would publish with the old exporter. It saves on the way
    /// out, so nothing written is lost.
    func runningOwner(_ project: GhidraProject, replacingStale: Bool = false) async -> OwnerRecord? {
        guard let data = try? Data(contentsOf: project.ownerURL),
              let record = try? JSONDecoder().decode(OwnerRecord.self, from: data) else { return nil }
        guard Subprocess.isAlive(record.pid) else {
            try? FileManager.default.removeItem(at: project.ownerURL)
            leases[project.module] = nil
            return nil
        }
        guard let hello = try? await Self.call(record.port, "GET", "/v1/hello", timeout: 5) else { return nil }
        guard replacingStale, let current = try? OwnerBuild.build(for: ghidra(), sources: configuration.sources) else {
            return record
        }
        let running = (try? JSONSerialization.jsonObject(with: hello.data) as? [String: Any])?["build"] as? Int
        guard running != current else { return record }
        _ = try? await Self.call(record.port, "POST", "/v1/stop", timeout: 60)
        for _ in 0..<120 where Subprocess.isAlive(record.pid) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? FileManager.default.removeItem(at: project.ownerURL)
        leases[project.module] = nil
        return nil
    }

    private func start(_ project: GhidraProject) async throws -> OwnerRecord {
        let install = try ghidra()
        let jar = try OwnerBuild.jar(for: install, sources: configuration.sources)
        let state = try project.state()
        var arguments = ["-Xmx4G", "-Djava.awt.headless=true",
                         "-cp", (install.classpath() + [jar.path]).joined(separator: ":"), "Owner",
                         "--project-dir", project.folder.path, "--project-name", GhidraProject.name,
                         "--program", state.program, "--module", project.module.hex,
                         "--project-id", state.project]
        if let archive = Self.typeArchive(for: state) {
            arguments += ["--types", archive.path]
        }
        arguments += ["--review-types", configuration.projectsRoot.path,
                      "--port", "0", "--idle", String(configuration.idle)]
        let log = project.folder.appendingPathComponent("owner.log")
        let process = try Subprocess.spawn(install.java, arguments, log: log, ownSession: true)
        let deadline = Date().addingTimeInterval(configuration.startTimeout)
        while true {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("OWNER READY ") }),
               let port = Int(line.split(separator: " ").last ?? "") {
                let record = OwnerRecord(pid: process.pid, port: port, startedAt: Self.now())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try (encoder.encode(record) + Data("\n".utf8)).write(to: project.ownerURL, options: .atomic)
                return record
            }
            if !process.isRunning {
                let tail = text.split(separator: "\n").suffix(20).joined(separator: "\n")
                throw GhidraHostError(.owner, "the owner exited before serving:\n\(tail)")
            }
            if Date() > deadline {
                process.terminate()
                throw GhidraHostError(.owner, "the owner did not serve within \(Int(configuration.startTimeout)) s; "
                                      + "log: \(log.path)")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The EDK2 archive the program was typed with: the one `state.json`
    /// names, or — moved or never recorded — the one of the same tag in the
    /// types cache, for the module's pointer size.
    static func typeArchive(for state: ProjectState) -> URL? {
        if let named = state.archive, FileManager.default.fileExists(atPath: named) {
            return URL(fileURLWithPath: named)
        }
        guard let tag = state.madeWith.types else { return nil }
        let bits = state.module.kind == "TE" || state.module.phase == "pei" ? "Ia32" : "X64"
        let cached = UEFITypes.cacheRoot.appendingPathComponent("uefi_\(bits)-\(tag).gdt")
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    // MARK: - The bridge

    /// One call of an owner on loopback; a refusal is a `GhidraHostError`
    /// with the owner's status and words.
    static func call(_ port: Int, _ method: String, _ path: String, body: Data? = nil, lease: String? = nil,
                     timeout: TimeInterval = 600) async throws -> (data: Data, headers: [String: String]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw GhidraHostError(.owner, "\(path) is not a path of the bridge", status: 400)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body ?? (method == "POST" ? Data() : nil)
        if let lease { request.setValue(lease, forHTTPHeaderField: "X-Lease") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GhidraHostError(.owner, "the owner on port \(port) does not answer: \(error.localizedDescription)")
        }
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GhidraHostError(.refused, message, status: http.statusCode)
        }
        return (data, headers)
    }

    // MARK: -

    /// The exporter and the Ghidra that wrote the artifact, and what the
    /// program was typed with when the UEFI pass ran; a types revision past
    /// the first (`…-r2`) is in the id too.
    static func recipe(for artifact: [String: Any], types: String?, passes: [String]) -> AnalysisRecipe {
        let exporter = artifact["script_version"] as? Int ?? 0
        let ghidra = artifact["ghidra"] as? String
        var id = "code-v\(exporter)-ghidra-\(safeRecipe(ghidra ?? "unknown"))"
        if let types {
            if let dash = types.range(of: "-r", options: .backwards),
               let revision = Int(types[dash.upperBound...]) {
                id = id.replacingOccurrences(of: "-ghidra-", with: "-types\(revision)-ghidra-")
            }
        } else {
            id = id.replacingOccurrences(of: "-ghidra-", with: "-plain-ghidra-")
        }
        return AnalysisRecipe(id: id, exporter: exporter, ghidra: ghidra ?? "unknown", script: "ExportCode.java",
                              types: types, passes: types == nil ? nil : (passes.isEmpty ? ["ApplyUefi.java"] : passes))
    }

    /// `cas._safe_recipe`: runs of anything but letters, digits, `.`, `_`
    /// and `-` become one `-`.
    static func safeRecipe(_ text: String) -> String {
        var out = ""
        var inRun = false
        for scalar in text.unicodeScalars {
            let ok = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._-".unicodeScalars.contains(scalar)
            if ok {
                out.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                out += "-"
                inRun = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00")
    }
}
