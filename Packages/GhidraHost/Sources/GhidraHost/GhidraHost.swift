import CodeAnalysis
import Darwin
import Foundation

/// The owners of the modules' kept projects, hosted: started on demand,
/// called over loopback, written to under one lease per module, published
/// into a store (`Design/SERVER_PLAN.md` §6).
///
/// A client writes a module it has taken into work (`GhidraHost+Leases.swift`):
/// one holder at a time, from the take to the give-back. The owner's own
/// lease token stays inside the host; a client never sees one (§7.3).
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
        /// Where the modules in work are kept across restarts; nil keeps them
        /// in memory only.
        public var leasesFile: URL?
        /// Where agents' reports about the tools are kept (`IssueBook`); nil
        /// takes none.
        public var issuesFile: URL?
        /// Where the review board's tickets are kept (`TicketBook`); nil
        /// keeps none.
        public var ticketsFile: URL?
        /// The pinned tag's library sources an EDK2 plate's `Evidence:` line is
        /// checked against at publish; fetched there once when missing. Nil
        /// checks nothing.
        public var edk2Sources: URL?

        public init(projectsRoot: URL = GhidraHost.defaultProjectsRoot, ghidraHome: URL? = nil,
                    sources: OwnerSources = .checkout, idle: Int = 1800,
                    holder: String = "\(NSUserName()) via byteripper-server",
                    startTimeout: TimeInterval = 300, leasesFile: URL? = nil, issuesFile: URL? = nil,
                    ticketsFile: URL? = nil,
                    edk2Sources: URL? = UEFITypes.Paths(root: UEFITypes.cacheRoot).edk2Library) {
            self.projectsRoot = projectsRoot
            self.ghidraHome = ghidraHome
            self.sources = sources
            self.idle = idle
            self.holder = holder
            self.startTimeout = startTimeout
            self.leasesFile = leasesFile
            self.issuesFile = issuesFile
            self.ticketsFile = ticketsFile
            self.edk2Sources = edk2Sources
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
        /// Why the registry could not be offered the functions, when it could
        /// not: the publish itself is stored either way.
        public var libraryError: String?
        /// Links whose text is a default name while the target has a real one.
        public var staleLinks: [StaleLink]
        /// Why the review's types could not be merged into the shared archive:
        /// the revision is stored either way, and the next publish merges them.
        public var typesError: String?
        /// The shared types' version this publish made, when its types changed the archive.
        public var typesVersion: Int?
        /// The kept project the store holds for this revision now.
        public var project: ProjectRecord?
        /// Why the project could not be kept: the revision is stored either way,
        /// and the next publish keeps it.
        public var projectError: String?
        /// EDK2 functions offered whose plate's citation of the pinned tag
        /// does not hold: a warning, the publish is stored either way.
        public var evidence: [EvidenceWarning] = []
        /// Why the citations could not be checked, when they could not.
        public var evidenceUnchecked: String?
        /// How many offered EDK2 functions had their citation checked: with no
        /// `evidence`, every one of them held.
        public var evidenceChecked = 0

        public init(manifest: AnalysisManifest, typeConflicts: [String], typeConflictsTaken: [String] = [],
                    typeConflictOrigins: [String: String] = [:], library: LibraryWriteResult? = nil,
                    libraryError: String? = nil,
                    staleLinks: [StaleLink] = []) {
            self.manifest = manifest
            self.typeConflicts = typeConflicts
            self.typeConflictsTaken = typeConflictsTaken
            self.typeConflictOrigins = typeConflictOrigins
            self.library = library
            self.libraryError = libraryError
            self.staleLinks = staleLinks
        }
    }

    /// What a publish carries beyond the review. A publish never replaces a
    /// shared type or a registry entry: only an agreed proposal does, applied
    /// by the module's next publish.
    public struct PublishOptions: Equatable, Sendable {
        /// Why this review adds to each entry it moves, by id: kept in the
        /// entry's history.
        public var entryReasons: [String: String]

        public init(entryReasons: [String: String] = [:]) {
            self.entryReasons = entryReasons
        }
    }

    /// A tagged library function the registry did not take, and why.
    public struct LibraryShortfall: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var kind: String
        /// `name`, `plate`, `comments`, `params`, `locals`, or `no_body` —
        /// a thunk or an external function, which has no body to offer.
        public var gaps: [String]
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var module: String
        public var name: String
        public var running: Bool
        public var reviewed: Bool
        public var published: ProjectState.Published?
        /// Whether the module is in work, by whom and since when.
        public var leased: Bool
        public var holder: String?
        public var since: String?
        /// A lease an administrator closed, until its holder takes the module again.
        public var closed: LeaseEnd?
        /// What an earlier owner of this project ended without saving, as the
        /// next open wrote it down. Absent when nothing was.
        public var writesLost: String?
        /// Where the module's review stands on the review board: "open" (a
        /// remark is still to be dealt with), "settled" (none is, not yet
        /// closed), "closed" (a verifier closed it), or absent: no ticket.
        public var review: String?
        public var openRemarks: Int?

        enum CodingKeys: String, CodingKey {
            case module, name, running, reviewed, published, leased, holder, since, closed, review
            case writesLost = "writes_lost"
            case openRemarks = "open_remarks"
        }
    }

    public let configuration: Configuration
    let writer: AnalysisWriter
    private var install: GhidraInstall?
    /// The owners' own lease tokens: the host writes to an owner under one.
    /// Who may write at all is the work lease (`leaseBook`).
    private var leases: [SHA256Digest: String] = [:]
    /// The modules in work and the leases closed (`GhidraHost+Leases.swift`).
    var leaseBook: LeaseBook
    var leaseWaiters: [SHA256Digest: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// What a publish would store when a module's lease was taken, for a done to
    /// compare: a write can count and change nothing, as a signature written
    /// again does, and a new exporter's artifact is no reason for a revision.
    /// It holds while the owner's count of changes stands where it was, so a run
    /// of refused writes, each giving its lease back, pays for one export.
    var leaseBaselines: [SHA256Digest: (writes: Int?, content: LeaseBaseline)] = [:]
    /// How many exports a baseline has cost, for the tests.
    private(set) var leaseBaselinesTaken = 0

    struct LeaseBaseline: Equatable {
        var artifact: SHA256Digest
        var review: SHA256Digest
        var description: SHA256Digest
    }
    /// Writes begun and writes still running, per module: a done's answers come
    /// over several awaits, and a write can land between them.
    private var writesBegun: [SHA256Digest: Int] = [:]
    private var writesRunning: [SHA256Digest: Int] = [:]
    /// Called at a done's two windows, for the tests that land a write in them.
    private var releaseStep: (@Sendable (ReleaseStep) async -> Void)?
    enum ReleaseStep { case compared, givenBack }
    func setReleaseStep(_ step: (@Sendable (ReleaseStep) async -> Void)?) { releaseStep = step }
    private var starting: [SHA256Digest: Task<OwnerRecord, Error>] = [:]
    /// Modules a stopped publish left a journal for: its owner's steps are
    /// finished at the module's next open.
    var unfinished: Set<SHA256Digest> = []
    var finishing: Set<SHA256Digest> = []
    /// Publishes holding the store now: an owner opened inside one finishes
    /// nothing, since finishing waits for the same hold.
    var publishing = 0
    /// The fetch of the pinned tag's library sources, while it runs.
    var edk2Fetch: Task<Void, Never>?
    /// Why the last fetch failed; the next publish tries again.
    var edk2FetchError: String?
    /// Whether this process has given the shared 32-bit review types EFIAPI's
    /// convention, or found they need none (`migrateSharedEFIAPI`).
    var sharedEFIAPIDone = false
    /// The step a test stops a publish after.
    var publishStop: PublishStop?
    func setPublishStop(_ stop: PublishStop?) { publishStop = stop }

    public init(configuration: Configuration = Configuration(), writer: AnalysisWriter) {
        self.configuration = configuration
        self.writer = writer
        self.leaseBook = Self.loadLeaseBook(configuration.leasesFile)
        self.issues = configuration.issuesFile.map { IssueBook(file: $0) }
        self.tickets = configuration.ticketsFile.map { TicketBook(file: $0) }
        self.typeProposals = configuration.ticketsFile.map {
            TypeProposalBook(file: $0.deletingLastPathComponent().appendingPathComponent("type-proposals.json"))
        }
    }

    /// Agents' proposals to replace shared types, kept beside the review board.
    public nonisolated let typeProposals: TypeProposalBook?

    /// The review board, when the host keeps one.
    public nonisolated let tickets: TicketBook?

    /// Agents' reports about the tools, when the host keeps them.
    public nonisolated let issues: IssueBook?

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
            let lease = leaseBook.leases[project.module.hex]
            let ticket = await tickets?.ticket(project.module.hex)
            rows.append(Summary(module: project.module.hex, name: state.module.name,
                                running: await runningOwner(project) != nil, reviewed: state.reviewed,
                                published: state.published, leased: lease != nil,
                                holder: lease?.holder, since: lease?.since,
                                closed: leaseBook.closed[project.module.hex],
                                writesLost: try? String(contentsOf: project.folder.appendingPathComponent("writes-lost"),
                                                        encoding: .utf8),
                                review: ticket.flatMap { $0.state == "none" ? nil : $0.state },
                                openRemarks: ticket.flatMap { $0.state == "none" ? nil : $0.openRemarks }))
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
    public func read(_ module: SHA256Digest, _ path: String, holder: String? = nil) async throws -> Data {
        try tellClosed(module, holder: holder)
        let record = try await owner(of: module)
        let data = try await Self.call(record.port, "GET", path).data
        noteActivity(module, holder: holder, call: Self.callName(path), kind: .read)
        return data
    }

    /// A bridge path as the Activity page names the call: `function`, `set/comment`.
    static func callName(_ path: String) -> String {
        var name = path.hasPrefix("/v1/") ? String(path.dropFirst(4)) : path
        if let query = name.firstIndex(of: "?") { name = String(name[..<query]) }
        if let address = name.range(of: "/0x") { name = String(name[..<address.lowerBound]) }
        return name
    }

    /// A call that asks what a write would do: the owner must be up, and no
    /// lease is taken.
    public func preview(_ module: SHA256Digest, _ path: String, body: Data, holder: String? = nil) async throws -> Data {
        try tellClosed(module, holder: holder)
        let record = try await owner(of: module)
        return try await Self.call(record.port, "POST", path, body: body).data
    }

    /// A call of the owner on the shared types: under the module's lease, which
    /// it takes and gives back when it held none, and counted as no write of
    /// the review — it changes an archive, not the program.
    func typesCall(_ module: SHA256Digest, _ path: String, body: Data) async throws -> Data {
        let record = try await owner(of: module)
        let held = leases[module] != nil
        var token = try await lease(module, record)
        do {
            let answer: Data
            do {
                answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
            } catch let error as GhidraHostError where error.status == 403 {
                // The owner's lease lapsed after an hour with no write while the
                // host kept its token (issue ce3740de): take it again, once.
                leases[module] = nil
                token = try await lease(module, record)
                answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
            }
            if !held {
                leases[module] = nil
                _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
            }
            return answer
        } catch {
            if !held {
                leases[module] = nil
                _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
            }
            throw error
        }
    }

    /// A write call of the bridge: refused unless `holder` has the module in
    /// work. `byHost` is the host's own write — a publish's step, a
    /// registry's mark — made inside a call that has been allowed already.
    public func write(_ module: SHA256Digest, _ path: String, body: Data, holder: String? = nil,
                      byHost: Bool = false) async throws -> Data {
        if !byHost { try requireLease(module, holder: holder) }
        if path == "/v1/type", writer.keepsTypeArchives, Self.withdrawsShared(body) {
            return try await withdrawSharedType(module, body: body)
        }
        writesBegun[module, default: 0] += 1
        writesRunning[module, default: 0] += 1
        defer { writesRunning[module, default: 1] -= 1 }
        let project = self.project(module)
        let record = try await owner(of: module)
        let held = leases[module] != nil
        if !held { await keepLeaseBaseline(module, record) }
        var token = try await lease(module, record)
        let answer: Data
        do {
            do {
                answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
            } catch let error as GhidraHostError where error.status == 403 {
                // The lease lapsed between two writes: take it again, once.
                leases[module] = nil
                token = try await lease(module, record)
                answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
            } catch let error as GhidraHostError where !byHost && !Self.untakenText(error).isEmpty {
                // A link reads as its entry's text, which the program does not
                // hold: the entry's text goes into the program first, so the
                // write stands on it rather than on Ghidra's defaults (issue
                // 41e8efe7). Once: a second refusal is answered as it is.
                for address in Self.untakenText(error) {
                    _ = try await library(module, .init(action: .apply, address: address,
                                                        reason: "the entry's text, taken before a write on its link",
                                                        takeText: true), holder: holder)
                }
                token = leases[module] ?? token
                answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
            }
        } catch {
            // A refused write wrote nothing, so the lease it took goes back: a
            // module left leased stops a deploy, and a `ghidra_done` would
            // publish it. One an earlier write holds stays, as does one a batch
            // that stopped part way has written under.
            if !held, await holdsNoWrites(project, record) {
                leases[module] = nil
                _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
            }
            throw error
        }
        var state = try project.state()
        if !state.reviewed {
            state.reviewed = true
            try project.write(state)
        }
        if !byHost { noteActivity(module, holder: holder, call: Self.callName(path), kind: .write) }
        return answer
    }

    /// The links an owner's refusal names as reading their entry's text
    /// without the program holding it (`Owner.UNTAKEN_TEXT`); empty for any
    /// other refusal.
    static func untakenText(_ error: GhidraHostError) -> [String] {
        guard error.status == 409, let start = error.message.range(of: "untaken entry text at ") else { return [] }
        let rest = error.message[start.upperBound...]
        let list = rest.prefix { $0 != ":" }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("0x") }
    }

    /// Whether the owner's count of changes stands where the last publish left
    /// it. An owner that does not answer has not said so.
    private func holdsNoWrites(_ project: GhidraProject, _ record: OwnerRecord) async -> Bool {
        guard let data = try? await Self.call(record.port, "GET", "/v1/hello", timeout: 10).data,
              let hello = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Self.holdsUnpublishedWrites(hello: hello, published: try? project.state().published) == false
    }

    private func ownerWrites(_ record: OwnerRecord) async -> Int? {
        guard let data = try? await Self.call(record.port, "GET", "/v1/hello", timeout: 10).data,
              let hello = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return hello["writes"] as? Int
    }

    /// Writes a done found to have changed nothing are not the store's to get:
    /// the next session must not take them for work still unpublished.
    private func recordNoChange(_ project: GhidraProject, record writes: Int?) {
        guard let writes, var state = try? project.state(), state.published != nil else { return }
        state.published?.writes = writes
        try? project.write(state)
    }

    /// The one kept stands while nothing has been counted since it was taken. A
    /// project already holding writes the store has not got takes none: they are
    /// what a done is there to publish, and comparing against them would hide them.
    private func keepLeaseBaseline(_ module: SHA256Digest, _ record: OwnerRecord) async {
        let data = try? await Self.call(record.port, "GET", "/v1/hello", timeout: 10).data
        let hello = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let hello, Self.holdsUnpublishedWrites(hello: hello, published: try? project(module).state().published) != false {
            leaseBaselines[module] = nil
            return
        }
        let writes = hello?["writes"] as? Int
        if let writes, leaseBaselines[module]?.writes == writes { return }
        leaseBaselinesTaken += 1
        leaseBaselines[module] = await leaseBaseline(record).map { (writes, $0) }
    }

    /// Whether the project holds writes the store has not got, asked of its owner
    /// or, with none up, of the count it left behind; no owner is started to ask.
    func holdsUnpublishedWrites(_ module: SHA256Digest) async -> Bool {
        let project = self.project(module)
        guard let state = try? project.state() else { return false }
        if let record = await runningOwner(project) {
            return await !holdsNoWrites(project, record)
        }
        guard let text = try? String(contentsOf: project.folder.appendingPathComponent("writes"), encoding: .utf8),
              let writes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return Self.holdsUnpublishedWrites(hello: ["writes": writes], published: state.published) == true
    }

    /// nil when the owner does not answer: a done then publishes as it would.
    private func leaseBaseline(_ record: OwnerRecord) async -> LeaseBaseline? {
        guard let artifact = try? await Self.call(record.port, "POST", "/v1/publish?dry_run=1", timeout: 3600).data,
              let review = try? await Self.call(record.port, "GET", "/v1/review").data,
              let description = try? await Self.call(record.port, "GET", "/v1/review/description").data else {
            return nil
        }
        return LeaseBaseline(artifact: SHA256Digest(data: artifact), review: SHA256Digest(data: review),
                             description: SHA256Digest(data: description))
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

    /// The owner's lease lapsed as an hour without a write lapses it, while
    /// this host keeps its token: for the tests of a stale token.
    func lapseOwnerLease(_ module: SHA256Digest) async {
        guard let token = leases[module], let record = await runningOwner(project(module)) else { return }
        _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
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
                        options: PublishOptions = PublishOptions(), holder: String? = nil,
                        byHost: Bool = false) async throws -> Publication {
        if !byHost { try requireLease(module, holder: holder) }
        let project = self.project(module)
        let record = try await owner(of: module)
        let state = try project.state()
        // The export only: the review's types are merged once the registry has
        // said yes, so a refused publish leaves the shared archive as it was.
        let (exported, headers) = try await Self.call(record.port, "POST", "/v1/publish?merge_types=0", timeout: 3600)
        let document = try await Self.call(record.port, "GET", "/v1/review").data
        let description = try await Self.call(record.port, "GET", "/v1/review/description").data
        guard let artifact = try JSONSerialization.jsonObject(with: exported) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's artifact is not a JSON object")
        }
        let reviewed = headers["x-owner-reviewed"] == "true"
        let conflicts = (headers["x-owner-type-conflicts"] ?? "").split(separator: ",").map(String.init)
        let taken = (headers["x-owner-type-taken"] ?? "").split(separator: ",").map(String.init)
        let origins = Self.typeOrigins(headers["x-owner-type-origins"])
        let last = state.published
        let recipe = Self.recipe(for: artifact, types: state.madeWith.types, passes: state.madeWith.passes)
        if let refusal = Self.languagePatchRefusal(publishing: recipe.id, over: last?.recipe) {
            throw GhidraHostError(.refused, refusal, status: 409)
        }
        let offer = try Self.libraryOffer(try await Self.call(record.port, "GET", "/v1/library").data, artifact: exported)

        // From the registry's decision to the last write, this publish is the
        // only one on the store.
        let hold = try await writer.lockPublishes()
        publishing += 1
        defer {
            publishing -= 1
            hold.release()
        }
        // The revision this publish would be, as the store numbers them.
        let next = ((try await writer.latestRevision(module: module))?.rev ?? 0) + 1
        // A replacement of registry entries is an agreed proposal's, and only
        // for what the voters read.
        var take = LibraryTake.none.with(entryReasons: options.entryReasons)
        var libraryProposals: [String] = []
        if let agreed = try await agreedLibraryTake(module, raw: exported, offer: offer.proposals, reviewed: reviewed) {
            take = LibraryTake.these(agreed.reasons).with(entryReasons: options.entryReasons)
            libraryProposals = agreed.proposals
        }
        // The registry decides first, on everything this publish offers: the
        // review's candidates, and the changes to entries its functions link to.
        // A refusal leaves all of it as it was, and stores nothing.
        var offered = try await ownWidth(try await Self.withoutLinked(offer.proposals, writer: writer), module: module)
        // A link reads its entry's text: an entry with none learns it from here.
        let completion = try await Self.completions(exported, offer: offer.proposals, offered: offered,
                                                    reviewed: reviewed, take: take, writer: writer)
        if let refusal = LibraryRefusal.refusal(completion.refused) {
            throw GhidraHostError(.refused, refusal, status: 409)
        }
        offered += completion.proposals
        let would = offered.isEmpty ? nil : try await writer.previewLibraryEntries(
            module: module, rev: next - 1, by: by, proposals: offered, take: take)
        if let refusal = would?.publishRefusal ?? Self.offerRefusal(offer.shortfalls, would: would) {
            throw GhidraHostError(.refused, refusal, status: 409)
        }
        let evidence = evidenceCheck(offered)
        let program = artifact["program"] as? [String: Any] ?? [:]
        // Then the shared types: merged into a copy of the archive's current
        // version; one the archive holds differently refuses the publish, here,
        // before anything is written.
        let types = writer.keepsTypeArchives && reviewed
            ? try await decideTypes(module, language: program["language"] as? String ?? "unknown",
                                    by: by)
            : nil
        // Both said yes: the journal goes down before the first write.
        let identity = ModuleIdentity(sha256: module, size: state.module.size, name: state.module.name,
                                      kind: state.module.kind,
                                      language: program["language"] as? String ?? "unknown",
                                      imageBase: program["image_base"] as? String ?? "0x0",
                                      phase: state.module.phase)
        // A mechanical artifact never replaces another — except this project's
        // own last publish, which a new one of the same program supersedes.
        let stored = try await writer.storedAnalysis(module: module, recipe: recipe.id)
        let ours = stored != nil && last != nil
            && (stored?.artifact.sha256.hex == last?.artifact || stored?.relinkedFrom?.hex == last?.artifact)
        var journal = PublishJournal(
            id: "\(Self.journalStamp())-\(module.hex.prefix(16))", module: module, by: by, startedAt: Self.now(),
            planned: next, reviewed: reviewed, takeTypeConflicts: false,
            take: take, offered: offered,
            exported: try await writer.writeObject(exported), document: try await writer.writeObject(document),
            description: try await writer.writeObject(description), identity: identity, recipe: recipe,
            source: SourceIdentity(path: state.source?.path, document: state.source?.document, node: state.source?.node),
            replace: ours, typeConflicts: types?.merged.conflicts ?? conflicts,
            typeConflictsTaken: types?.merged.taken ?? taken, typeConflictOrigins: types?.merged.origins ?? origins)
        journal.objects = [journal.exported, journal.document, journal.description]
        journal.typesInOwner = !writer.keepsTypeArchives
        if let types {
            journal.typesBits = types.bits
            journal.typesVersion = types.version
            if !types.proposals.isEmpty { journal.typeProposals = types.proposals }
            for object in types.version?.files.values.sorted() ?? [] { journal.keep(object) }
        }
        let applying = Set(journal.typeProposals ?? []).union(libraryProposals)
        if !applying.isEmpty { journal.typeProposals = applying.sorted() }
        try await writeDown(journal)
        try await applyStoreSteps(&journal)
        try await applyOwnerSteps(&journal, record: record)
        try await writer.removeJournal(id: journal.id)
        await noteProposalsApplied(journal.typeProposals ?? [], module: module, revision: journal.rev,
                                   version: journal.typesVersion?.version, relinked: journal.library?.relinked ?? [])
        guard let manifest = journal.manifest else { throw GhidraHostError(.owner, "the publish stored no analysis") }
        var publication = Publication(manifest: manifest, typeConflicts: journal.typeConflicts,
                                      typeConflictsTaken: journal.typeConflictsTaken,
                                      typeConflictOrigins: journal.typeConflictOrigins, library: journal.library,
                                      libraryError: journal.libraryError, staleLinks: await staleLinks(port: record.port))
        publication.typesError = journal.typesError
        publication.typesVersion = journal.typesVersion?.version
        publication.project = journal.project
        publication.projectError = journal.projectError
        publication.evidence = evidence.warnings
        publication.evidenceUnchecked = evidence.unchecked
        publication.evidenceChecked = evidence.checked
        if !byHost { noteActivity(module, holder: holder, call: "publish", kind: .publish, revision: journal.rev) }
        return publication
    }

    /// Whether a `/v1/type` body takes a type out of the shared archive.
    static func withdrawsShared(_ body: Data) -> Bool {
        let request = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        return request["delete"] as? Bool == true && request["shared"] as? Bool == true
    }

    /// A journal's name sorts by when it began.
    static func journalStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS"
        return formatter.string(from: Date())
    }

    /// A report beside a stored publish: failing to read it never fails that.
    func staleLinks(port: Int) async -> [StaleLink] {
        struct Answer: Decodable {
            var stale_links: [StaleLink]
        }
        guard let data = try? await Self.call(port, "GET", "/v1/stale-links").data else { return [] }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.stale_links ?? []
    }

    /// An address as a number, whatever its spelling: `0x9DFCAAC`, `0x09dfcaac`.
    static func addressValue(_ text: String) -> UInt64? {
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt64(digits, radix: 16)
    }

    /// The addresses of the offered functions a registry's would-be answer
    /// takes, as `libraryMarks` will mark them once it is written: a short body
    /// by the entry its review was made on or the one made of it by name, any
    /// other by the entry its body or its variant names.
    static func wouldLink(_ proposals: [LibraryProposal], would: LibraryWriteResult) -> [String] {
        let rows = would.added + would.updated + would.unchanged + (would.variants ?? [])
        let accepted = Set(rows.map(\.id))
        let names = Set(rows.map(\.name))
        return proposals.compactMap { proposal in
            if let based = proposal.basedOn ?? proposal.variantOf, accepted.contains(based) { return proposal.address }
            if accepted.contains(proposal.body.key) || names.contains(proposal.name) { return proposal.address }
            return nil
        }
    }

    /// The marks a publish leaves: a function the registry took or matched
    /// carries the version it holds. One it did not take keeps what it had.
    static func libraryMarks(_ proposals: [LibraryProposal], result: LibraryWriteResult,
                             index: LibraryIndex) -> [[String: Any]] {
        let accepted = Set((result.added + result.updated + result.unchanged + (result.variants ?? [])).map(\.id))
        return proposals.compactMap { proposal in
            // A short body's entry is the one its review was made on, or the one
            // this publish made of it: its bytes do not say.
            if proposal.body.isShort {
                let id = proposal.basedOn ?? result.added.first { $0.name == proposal.name }?.id
                guard let id, accepted.contains(id), let held = index.entries[id] else { return nil }
                return ["address": proposal.address, "id": id, "version": held.version, "kind": proposal.kind]
            }
            guard let id = index.bodies[proposal.body.key] ?? proposal.variantOf,
                  accepted.contains(id), index.bodies[proposal.body.key] == id, let held = index.entries[id] else { return nil }
            return ["address": proposal.address, "id": id, "version": held.version, "kind": proposal.kind]
        }
    }

    /// The owner's `GET /v1/library`, as the registry takes it: each entry's
    /// object made canonical — sorted keys — so the same review stores the
    /// same object whichever owner wrote it.
    /// The export as a store keeps it. No registry to read says nothing is a link.
    static func stored(_ raw: Data, writer: any AnalysisWriter) async -> ModuleFormat.Stored {
        let index = (try? await writer.readLibraryIndex()) ?? LibraryIndex()
        var code: [SHA256Digest: Data] = [:]
        for digest in ModuleFormat.codeNeeded(raw, index: index) {
            code[digest] = try? await writer.readObject(digest)
        }
        return ModuleFormat.stored(raw, index: index, code: code)
    }

    /// A function bound to an entry and not dirty has nothing to say to the
    /// registry, whatever its project still holds: it is offered only when it is
    /// the entry's own review, which completes an older entry. One whose entry
    /// was taken out is the module's own again, whatever was written on it.
    ///
    /// A review that changes only an entry's head — its convention, signature,
    /// return type, parameters — offers the entry's own C under the new head
    /// (`LibraryProposal.keepingEntryText`): the body as the entry's module
    /// printed it, not as this module's decompiler does, which may not tell
    /// the same temporaries apart.
    static func withoutLinked(_ proposals: [LibraryProposal], writer: any AnalysisWriter) async throws -> [LibraryProposal] {
        guard !proposals.isEmpty else { return proposals }
        let index = try await writer.readLibraryIndex()
        guard !index.entries.isEmpty else { return proposals }
        var kept: [LibraryProposal] = []
        for var proposal in proposals {
            if let based = proposal.basedOn, index.entries[based] == nil,
               index.takenOut?.contains(where: { $0.value.id == based }) == true { continue }
            if !proposal.linked, let (_, held) = index.entry(for: proposal.body),
               let kept = LibraryProposal.keepingEntryText(proposal.entry, in: try await writer.readObject(held.entry),
                                                           heldSource: held.source) {
                proposal.entry = kept
            }
            guard proposal.linked else { kept.append(proposal); continue }
            guard let (_, held) = index.entry(for: proposal.body) else { continue }
            if LibraryProposal.sameReview(try await writer.readObject(held.entry), proposal.entry) { kept.append(proposal) }
        }
        return kept
    }

    /// The equates a function's C prints, by name, with their places as offsets
    /// from its start: what a holder needs to read the name, nothing of the
    /// module. Nil where it prints none, so an entry without any is unchanged.
    static func printedEquates(of function: [String: Any], in equates: [[String: Any]]) -> [[String: Any]]? {
        guard let c = function["c"] as? String, let text = function["entry"] as? String,
              let start = CodeAddress(hex: text) else { return nil }
        let held = Set((function["instructions"] as? [[String: Any]] ?? []).compactMap {
            ($0["address"] as? String).flatMap { CodeAddress(hex: $0)?.value }
        })
        var rows: [[String: Any]] = []
        for equate in equates {
            guard let name = equate["name"] as? String,
                  c.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
            else { continue }
            let uses = (equate["references"] as? [[Any]] ?? []).compactMap { use -> [Any]? in
                guard use.count == 2, let at = (use[0] as? String).flatMap({ CodeAddress(hex: $0) }),
                      held.contains(at.value), let operand = use[1] as? Int else { return nil }
                return [CodeAddress(at.value &- start.value).description, operand]
            }
            guard !uses.isEmpty else { continue }
            var row: [String: Any] = ["name": name, "value": equate["value"] ?? "", "uses": uses]
            row["enum"] = equate["enum"] is NSNull ? nil : equate["enum"]
            row["comment"] = equate["comment"] is NSNull ? nil : equate["comment"]
            rows.append(row)
        }
        guard !rows.isEmpty else { return nil }
        return rows.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    static let notOfTheDescription: Set<String> = ["callers", "callees", "library_entry", "review_level",
                                                   "review_gaps", "body"]

    /// Whether a review document says anything of the module's own, once the
    /// functions it only links are out. Types and equates do not count: applying
    /// an entry brings its own.
    static func holdsOwnReview(document: Data, description: Data) -> Bool {
        guard description.isEmpty else { return true }
        guard let object = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return false }
        return !(object["functions"] as? [String: Any] ?? [:]).isEmpty
            || !(object["comments"] as? [Any] ?? []).isEmpty
            || !(object["data"] as? [String: Any] ?? [:]).isEmpty
    }

    /// What the registry would not take, and why.
    static func offerRefusal(_ shortfalls: [LibraryShortfall], would: LibraryWriteResult?) -> String? {
        let below = shortfalls.map {
            LibraryRefusal.Row(address: $0.address, name: $0.name,
                               why: $0.gaps.contains("no_body") ? "it has no body: a thunk or an external function"
                                   : "short of the bar: " + $0.gaps.joined(separator: ", ")
                                       + "; if it is a registry function, take the entry's text with `ghidra_library_apply` "
                                       + "and `take_text`, then repeat the edit")
        }
        return LibraryRefusal.refusal(below + (would.map(LibraryRefusal.rows(of:)) ?? []))
    }

    static func libraryOffer(_ data: Data, artifact: Data? = nil) throws -> (proposals: [LibraryProposal], shortfalls: [LibraryShortfall]) {
        guard let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's library answer is not a JSON object")
        }
        var functions: [UInt64: [String: Any]] = [:]
        var equates: [[String: Any]] = []
        if let artifact, let read = try JSONSerialization.jsonObject(with: artifact) as? [String: Any] {
            equates = read["equates"] as? [[String: Any]] ?? []
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
                if let printed = Self.printedEquates(of: function, in: equates) { entry["equates"] = printed }
            }
            let canonical = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            proposals.append(LibraryProposal(body: LibraryBody(size: size, full: full, specific: specific),
                                             name: name, kind: kind, address: address, entry: canonical,
                                             variantOf: item["variant_of"] as? String,
                                             codes: item["codes"] as? [String],
                                             role: entry["assert"] as? Bool == true ? "assert" : nil,
                                             basedOn: item["based_on"] as? String,
                                             base: item["base"] as? Int,
                                             linked: item["linked"] as? Bool ?? false,
                                             dataReferences: item["data_references"] as? [String],
                                             callees: (item["callees"] as? [[String: Any]])?.map {
                                                 LibraryCallee(name: $0["name"] as? String ?? "", body: $0["body"] as? String)
                                             },
                                             referenceBytes: item["reference_bytes"] as? String))
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
    public func preview(_ module: SHA256Digest, entryReasons: [String: String] = [:],
                        holder: String? = nil) async throws -> Data {
        try tellClosed(module, holder: holder)
        let project = self.project(module)
        let record = try await owner(of: module)
        let state = try project.state()
        let (raw, headers) = try await Self.call(record.port, "POST", "/v1/publish?dry_run=1", timeout: 3600)
        let document = try await Self.call(record.port, "GET", "/v1/review").data
        let description = try await Self.call(record.port, "GET", "/v1/review/description").data
        guard let artifact = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's artifact is not a JSON object")
        }
        let reviewed = headers["x-owner-reviewed"] == "true"
        let conflicts = (headers["x-owner-type-conflicts"] ?? "").split(separator: ",").map(String.init)
        let stored = await Self.stored(raw, writer: writer)
        let storedDocument = ModuleFormat.review(document, of: stored)
        let artifactDigest = SHA256Digest(data: stored.artifact).hex
        let documentDigest = SHA256Digest(data: storedDocument).hex
        let descriptionDigest: String? = description.isEmpty ? nil : SHA256Digest(data: description).hex
        // What the store holds last decides, as it numbers the revisions.
        let last = try await writer.latestRevision(module: module)
        let changed = last?.artifact?.hex != artifactDigest || last?.review.hex != documentDigest
            || last?.description?.hex != descriptionDigest
        let functions = artifact["functions"] as? [[String: Any]] ?? []
        let instructions = functions.reduce(0) { $0 + (($1["instructions"] as? [Any])?.count ?? 0) }
        var preview: [String: Any] = [
            "dry_run": true,
            "reviewed": reviewed && Self.holdsOwnReview(document: storedDocument, description: description),
            "changed": changed,
            // A publish writes the registry's states and marks into the artifact,
            // which a preview cannot: the review's hash holds, this one need not.
            "artifact": ["sha256": artifactDigest, "size": stored.artifact.count, "before_library_marks": true],
            "document": ["sha256": documentDigest, "size": storedDocument.count],
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
        let typeOrigins = Self.typeOrigins(headers["x-owner-type-origins"])
        preview["type_conflict_origins"] = typeOrigins
        // A type the shared archive holds differently refuses the publish; a
        // withdrawn name only stays in this module.
        let replacing = conflicts.filter { !(typeOrigins[$0] ?? "").hasPrefix("withdrawn ") }
        // An agreed proposal that covers every replacement is what the
        // publish would apply: the preview says so, as the publish decides it.
        var agreedProposals: [String]?
        if writer.keepsTypeArchives, !replacing.isEmpty {
            agreedProposals = try? await agreedReplacement(module, replacements: replacing)
            if let agreedProposals { preview["types_agreed"] = agreedProposals }
        }
        if writer.keepsTypeArchives, !replacing.isEmpty, agreedProposals == nil {
            let names = Dictionary((try? await writer.newestAnalyses())?.map { ($0.module.sha256.hex, $0.module.name) } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            preview["types_refused"] = Self.typeRefusal(replacing, origins: typeOrigins, names: names, version: nil,
                                                        bits: Self.archiveBits(language: (artifact["program"] as? [String: Any])?["language"] as? String ?? ""))
        }
        // The version of the shared types the publish would make, as its answer
        // says it: merged into a throwaway copy of the current version, and
        // nothing stored. Absent when the types add nothing, as in a publish.
        if writer.keepsTypeArchives, reviewed, replacing.isEmpty || agreedProposals != nil {
            let language = (artifact["program"] as? [String: Any])?["language"] as? String ?? ""
            if let next = try? await wouldBeTypeVersion(module, language: language, take: agreedProposals != nil) {
                preview["types_version"] = next
            }
        }
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
        // nothing. Candidates are asked about before anything else makes the
        // program a review, as the publish refuses them.
        // The links the revision would hold: those the export already carries,
        // and the functions this publish offers that the registry would take —
        // a short body among them becomes a link only by that decision.
        var links = Set(stored.functions.compactMap(Self.addressValue))
        do {
            let offer = try Self.libraryOffer(try await Self.call(record.port, "GET", "/v1/library").data,
                                              artifact: raw)
            // An agreed proposal is the publish's decision: the preview answers
            // what that publish would do.
            var takeLibrary = LibraryTake.none.with(entryReasons: entryReasons)
            if let agreed = try await agreedLibraryTake(module, raw: raw, offer: offer.proposals, reviewed: reviewed) {
                takeLibrary = LibraryTake.these(agreed.reasons).with(entryReasons: entryReasons)
                preview["library_agreed"] = agreed.proposals
            }
            var offered = try await ownWidth(try await Self.withoutLinked(offer.proposals, writer: writer), module: module)
            let completion = try await Self.completions(raw, offer: offer.proposals, offered: offered, reviewed: reviewed,
                                                        take: takeLibrary, writer: writer)
            offered += completion.proposals
            let evidence = evidenceCheck(offered)
            if !evidence.warnings.isEmpty { preview["evidence"] = try Self.plain(evidence.warnings) }
            if let unchecked = evidence.unchecked { preview["evidence_unchecked"] = unchecked }
            if evidence.checked > 0 { preview["evidence_checked"] = evidence.checked }
            if let refusal = LibraryRefusal.refusal(completion.refused) {
                preview["library_refused"] = refusal
            } else if !offered.isEmpty {
                let would = try await writer.previewLibraryEntries(
                    module: module, rev: revision, by: nil, proposals: offered,
                    take: takeLibrary)
                preview["library"] = try Self.plain(would)
                if let refusal = would.publishRefusal ?? Self.offerRefusal(offer.shortfalls, would: would) {
                    preview["library_refused"] = refusal
                } else if reviewed {
                    links.formUnion(Self.wouldLink(offered, would: would).compactMap(Self.addressValue))
                }
            } else if let refusal = Self.offerRefusal(offer.shortfalls, would: nil) {
                preview["library_refused"] = refusal
            }
        } catch {
            preview["library_error"] = "\(error)"
        }
        preview["links"] = links.count
        return try JSONSerialization.data(withJSONObject: preview, options: [.sortedKeys])
    }

    /// The module given back by its holder: what the lease changed published
    /// first (`release(_:by:)`), and with `discard` nothing published — the
    /// working project goes to the Trash with its unpublished changes, and the
    /// next open is the last published revision. A publish that is refused
    /// keeps the lease.
    public func release(_ module: SHA256Digest, by: String?, holder: String? = nil,
                        discard: Bool = false) async throws -> Publication? {
        try requireLease(module, holder: holder)
        if discard {
            try await discardWorkingProject(module)
            try dropLease(module)
            return nil
        }
        let publication = try await publishChanges(module, by: by)
        try dropLease(module)
        return publication
    }

    /// Publish what the lease changed; nil when the host holds no owner lease
    /// of the module, or the lease changed nothing: nothing counted since the
    /// last publish, or what would be stored is what would have been when the
    /// lease was taken. A new exporter's different artifact is no reason for a
    /// revision nobody wrote.
    private func publishChanges(_ module: SHA256Digest, by: String?) async throws -> Publication? {
        guard let token = leases[module], let record = await runningOwner(project(module)) else {
            leases[module] = nil
            // No lease here, as after a restart of this server: a done still means
            // the store gets what the project holds and it has not got.
            guard await holdsUnpublishedWrites(module) else { return nil }
            let publication = try await publish(module, by: by, byHost: true)
            leaseBaselines[module] = nil
            return publication
        }
        let begun = writesBegun[module, default: 0]
        // A write that overlaps the comparison may not be in what it compared:
        // an extra revision costs little, a lost publish does not.
        func quiet() -> Bool { writesRunning[module, default: 0] == 0 && writesBegun[module, default: 0] == begun }
        var unchanged = quiet()
        if unchanged { unchanged = await holdsNoWrites(project(module), record) }
        if !unchanged, quiet(), let baseline = leaseBaselines[module]?.content, let now = await leaseBaseline(record) {
            unchanged = now == baseline
        }
        await releaseStep?(.compared)
        if unchanged, quiet() {
            leases[module] = nil
            leaseBaselines[module] = nil
            _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
            await releaseStep?(.givenBack)
            // After the lease: giving it back saves, and the count moves with that.
            let writes = await ownerWrites(record)
            if quiet() { recordNoChange(project(module), record: writes) }
            return nil
        }
        let publication = try await publish(module, by: by, byHost: true)
        leases[module] = nil
        leaseBaselines[module] = nil
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
    /// What `forget` moved to the Trash: the working folder, and the store's
    /// copy of the project when the store kept one.
    public struct Forgotten: Sendable {
        public var folder: URL
        public var storeCopy: URL?

        /// The answer the tool and the route give.
        public var answer: [String: String] {
            var answer = ["trashed": folder.path]
            if let storeCopy { answer["store_copy_trashed"] = storeCopy.path }
            return answer
        }
    }

    @discardableResult
    public func forget(_ module: SHA256Digest, holder: String? = nil) async throws -> Forgotten {
        // Another holder's module is not let go under it; the holder's own
        // lease goes with the project.
        if let held = leaseBook.leases[module.hex], held.holder != holderName(holder) {
            throw Self.heldByAnother(held)
        }
        let project = self.project(module)
        guard project.exists else {
            throw GhidraHostError(.project, "no project for \(module.hex): nothing to forget", status: 404)
        }
        _ = await stop(module)
        leases[module] = nil
        try dropLease(module)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: project.folder, resultingItemURL: &trashed)
        // The store's copy goes with it, or the next open would bring the same
        // program back: to the Trash too, as recoverable as the folder.
        var storeCopy: URL?
        if let kept = try await writer.readProject(module: module) {
            var moved: NSURL?
            let folder = kept.file.deletingLastPathComponent()
            try FileManager.default.trashItem(at: folder, resultingItemURL: &moved)
            storeCopy = (moved as URL?) ?? folder
        }
        return Forgotten(folder: (trashed as URL?) ?? project.folder, storeCopy: storeCopy)
    }

    // MARK: - Owners

    /// The module's running owner, or a new one.
    func owner(of module: SHA256Digest) async throws -> OwnerRecord {
        let project = self.project(module)
        if !project.exists { try await restoreProject(module) }
        guard project.exists else {
            throw GhidraHostError(.project, "no project for \(module.hex): open the module first", status: 404)
        }
        if let running = await runningOwner(project, replacingStale: true) {
            await finishPublishes(module, record: running)
            return running
        }
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
        let record = try await task.value
        await finishPublishes(module, record: record)
        await migrateSharedEFIAPI(module)
        return record
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
        do {
            return try await startOnce(project)
        } catch let error as GhidraHostError where error.message.contains("LockException") {
            // An owner left by a host stopped while it started holds the
            // project: stop it and start once more. Anything else holding the
            // lock is named.
            if !(await stopOrphanOwners(module: project.module.hex)).isEmpty {
                return try await startOnce(project)
            }
            throw GhidraHostError(.owner, "the project of \(project.module.hex) is locked by another process, so "
                                  + "no owner can open it: " + lockHolders(project), status: 409)
        }
    }

    private func startOnce(_ project: GhidraProject) async throws -> OwnerRecord {
        let install = try ghidra()
        let jar = try OwnerBuild.jar(for: install, sources: configuration.sources)
        let state = try await retypedForEFIAPI(project, try project.state())
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
        // The name a moved archive still has, else the machine (an X64 PEIM is not Ia32).
        let bits = typedIa32(state) ? "Ia32" : "X64"
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
        // A patched language prints other C from the same Ghidra.
        if let patch = artifact["language_patch"] as? String { id += "-lang-\(safeRecipe(patch))" }
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

    /// Why a publish from a stock Ghidra may not follow one from a patched
    /// language: the module's C would go back to what the patch corrected. nil
    /// when it may.
    static func languagePatchRefusal(publishing recipe: String, over last: String?) -> String? {
        guard let last, last.contains("-lang-"), !recipe.contains("-lang-") else { return nil }
        return "this module was published as \(last), from a Ghidra with a patched language, and this Ghidra has none: "
            + "name the patched copy in `ghidraHome` (Scripts/make-patched-ghidra.sh)"
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
