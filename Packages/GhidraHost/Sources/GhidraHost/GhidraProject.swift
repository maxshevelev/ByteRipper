import CodeAnalysis
import Foundation

/// `state.json` beside a module's kept project: what made it and what was
/// last published (`Design/GHIDRA_SHARED_PLAN.md` §6.2), field for field the
/// same wherever the project was made, so an owner opens one another made.
public struct ProjectState: Codable, Equatable, Sendable {
    public struct Module: Codable, Equatable, Sendable {
        public var sha256: String
        public var size: Int
        public var name: String
        public var kind: String
        public var phase: String?
    }

    public struct MadeWith: Codable, Equatable, Sendable {
        public var ghidra: String
        public var types: String?
        public var passes: [String]
    }

    public struct Source: Codable, Equatable, Sendable {
        public var path: String?
        public var document: String?
        public var node: String?

        public init(path: String? = nil, document: String? = nil, node: String? = nil) {
            self.path = path
            self.document = document
            self.node = node
        }
    }

    public struct Published: Codable, Equatable, Sendable {
        public var artifact: String
        public var recipe: String
        public var review: String?
        /// The SHA-256 of the module description this publish stored.
        public var description: String?
        public var rev: Int?
        public var at: String
        /// The program's modification number when this publish stored it: a
        /// later number is work the store has not got, saved or not.
        public var modification: Int?
        /// The owner's count of the program's changes over all its sessions
        /// when this publish stored it. Unlike `modification`, which starts
        /// again at every open, a later count can be compared with it after a
        /// restart.
        public var writes: Int?
    }

    public var schema: Int
    /// The project's identity: the `reading.project` of its publishes.
    public var project: String
    public var module: Module
    /// The program's name inside the Ghidra project.
    public var program: String
    public var madeWith: MadeWith
    public var source: Source?
    /// The EDK2 type archive the program was typed with, for the owner.
    public var archive: String?
    public var createdAt: String
    public var reviewed: Bool
    public var published: Published?

    private enum CodingKeys: String, CodingKey {
        case schema, project, module, program, source, archive, reviewed, published
        case madeWith = "made_with"
        case createdAt = "created_at"
    }
}

/// One module's kept project: `GhidraProjects/<module-sha>/`.
public struct GhidraProject: Sendable {
    public static let name = "module"

    public let module: SHA256Digest
    public let folder: URL

    public init(root: URL, module: SHA256Digest) {
        self.module = module
        self.folder = root.appendingPathComponent(module.hex, isDirectory: true)
    }

    var stateURL: URL { folder.appendingPathComponent("state.json") }
    var ownerURL: URL { folder.appendingPathComponent("owner.json") }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: stateURL.path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(Self.name).gpr").path)
    }

    public func state() throws -> ProjectState {
        do {
            return try JSONDecoder().decode(ProjectState.self, from: Data(contentsOf: stateURL))
        } catch {
            throw GhidraHostError(.project, "\(stateURL.path): \(error)")
        }
    }

    public func write(_ state: ProjectState) throws {
        try Self.encoded(state).write(to: stateURL, options: .atomic)
    }

    /// `state.json` as every writer writes it.
    static func encoded(_ state: ProjectState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state) + Data("\n".utf8)
    }

    /// The modules that have a project under `root`.
    public static func all(in root: URL) -> [GhidraProject] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { SHA256Digest(hex: $0.lastPathComponent) }
            .map { GhidraProject(root: root, module: $0) }
            .filter(\.exists)
            .sorted { $0.module < $1.module }
    }
}

/// The owner's record beside its project — `owner.json`, as the Python
/// client writes it, so a client finds an owner the other started.
struct OwnerRecord: Codable, Equatable, Sendable {
    var pid: Int32
    var port: Int
    var startedAt: String

    private enum CodingKeys: String, CodingKey {
        case pid, port
        case startedAt = "started_at"
    }
}

/// Where a publish goes: a store on this machine, or a served one. The host
/// stores in the order the store's rules expect (§5.4): the document, the
/// revision, then the analysis naming both.
public protocol AnalysisWriter: Sendable {
    func writeObject(_ data: Data) async throws -> SHA256Digest
    func writeRevision(module: SHA256Digest, reading: AnalysisReading, artifact: SHA256Digest,
                       by: String?) async throws
    func storedAnalysis(module: SHA256Digest, recipe: String) async throws -> AnalysisManifest?
    func writeAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data, source: SourceIdentity,
                       reading: AnalysisReading?, replace: Bool) async throws -> AnalysisManifest
    func writeLibraryEntries(module: SHA256Digest, rev: Int?, by: String?, proposals: [LibraryProposal],
                             take: LibraryTake) async throws -> LibraryWriteResult
    /// What `writeLibraryEntries` would do, writing nothing.
    func previewLibraryEntries(module: SHA256Digest, rev: Int?, by: String?, proposals: [LibraryProposal],
                               take: LibraryTake) async throws -> LibraryWriteResult
    /// An entry given a narrower name, as `ContentStore.renameLibraryEntry` does.
    func renameLibraryEntry(id: String, name: String, reason: String, by: String?, module: SHA256Digest,
                            dryRun: Bool) async throws -> LibraryWriteResult
    /// A write on the registry itself, as `ContentStore.changeLibrary` does.
    func changeLibrary(_ change: LibraryChange, by: String?, module: SHA256Digest,
                       dryRun: Bool) async throws -> LibraryWriteResult
    /// The last published analysis' review gaps by function entry; nil when
    /// the module has no stored analysis.
    func reviewGaps(module: SHA256Digest) async throws -> [String: [String]]?
    /// The registry as the store holds it, for matching a module against it.
    func readLibraryIndex() async throws -> LibraryIndex
    func readLibraryHistory(id: String) async throws -> LibraryHistory?
    func readObject(_ digest: SHA256Digest) async throws -> Data
    /// Each module's newest analysis, for a question about all of them.
    func newestAnalyses() async throws -> [AnalysisManifest]
    /// One function of the module's newest analysis as a reader of the store
    /// sees it, nil when this store cannot say.
    func functionAsRead(module: SHA256Digest, entry: CodeAddress) async throws -> CodeArtifact.Function?
    /// The project at `file` kept for the revision `rev`, in the store's private part.
    func writeProject(module: SHA256Digest, file: URL, rev: Int, artifact: SHA256Digest, review: SHA256Digest?,
                      environment: ProjectEnvironment) async throws -> ProjectRecord
    /// The module's kept project and the file holding it; nil when the store keeps none.
    func readProject(module: SHA256Digest) async throws -> (record: ProjectRecord, file: URL)?
}

extension ContentStore: AnalysisWriter {
    public func writeObject(_ data: Data) async throws -> SHA256Digest {
        try putObject(data)
    }

    public func writeProject(module: SHA256Digest, file: URL, rev: Int, artifact: SHA256Digest,
                             review: SHA256Digest?, environment: ProjectEnvironment) async throws -> ProjectRecord {
        try putProject(module: module, file: file, rev: rev, artifact: artifact, review: review,
                       environment: environment)
    }

    public func readProject(module: SHA256Digest) async throws -> (record: ProjectRecord, file: URL)? {
        try project(module: module).map { ($0, projectFile(module)) }
    }

    public func writeRevision(module: SHA256Digest, reading: AnalysisReading, artifact: SHA256Digest,
                              by: String?) async throws {
        try recordRevision(module: module, reading: reading, artifact: artifact, by: by)
    }

    public func storedAnalysis(module: SHA256Digest, recipe: String) async throws -> AnalysisManifest? {
        try analysis(module: module, recipe: recipe)
    }

    public func writeAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data,
                              source: SourceIdentity, reading: AnalysisReading?,
                              replace: Bool) async throws -> AnalysisManifest {
        try putAnalysis(module: module, recipe: recipe, artifact: artifact, source: source,
                        reading: reading, replace: replace)
    }

    public func writeLibraryEntries(module: SHA256Digest, rev: Int?, by: String?, proposals: [LibraryProposal],
                                    take: LibraryTake) async throws -> LibraryWriteResult {
        try putLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: take)
    }

    public func previewLibraryEntries(module: SHA256Digest, rev: Int?, by: String?,
                                      proposals: [LibraryProposal],
                                      take: LibraryTake) async throws -> LibraryWriteResult {
        try putLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: take, dryRun: true)
    }

    public func renameLibraryEntry(id: String, name: String, reason: String, by: String?, module: SHA256Digest,
                                   dryRun: Bool) async throws -> LibraryWriteResult {
        var result = LibraryWriteResult()
        result.updated = [try renameLibraryEntry(id: id, name: name, reason: reason, by: by, changedFrom: module, dryRun: dryRun)]
        return result
    }

    public func changeLibrary(_ change: LibraryChange, by: String?, module: SHA256Digest,
                              dryRun: Bool) async throws -> LibraryWriteResult {
        try changeLibrary(change, by: by, changedFrom: module, dryRun: dryRun)
    }

    public func reviewGaps(module: SHA256Digest) async throws -> [String: [String]]? {
        guard let manifest = try analysis(module: module), let artifact = try? artifact(for: manifest) else {
            return nil
        }
        return artifact.reviewGapsByEntry()
    }

    public func readLibraryIndex() async throws -> LibraryIndex { try libraryIndex() }
    public func readLibraryHistory(id: String) async throws -> LibraryHistory? { try libraryHistory(id: id) }
    public func readObject(_ digest: SHA256Digest) async throws -> Data { try object(digest) }
    public func newestAnalyses() async throws -> [AnalysisManifest] {
        try Set(analyses().map(\.module.sha256)).compactMap { try analysis(module: $0) }
    }

    public func functionAsRead(module: SHA256Digest, entry: CodeAddress) async throws -> CodeArtifact.Function? {
        guard let manifest = try analysis(module: module) else { return nil }
        if try skeleton(of: manifest.artifact.sha256) != nil {
            return try functions([entry], of: manifest.artifact.sha256).first
        }
        return try artifact(for: manifest).functions.first { $0.entry == entry }
    }
}

extension RemoteStore: AnalysisWriter {
    public func writeObject(_ data: Data) async throws -> SHA256Digest {
        try await putObject(data)
    }

    /// A served store keeps its projects to itself: the server keeps what its
    /// own host publishes, and nothing reaches it from outside.
    public func writeProject(module: SHA256Digest, file: URL, rev: Int, artifact: SHA256Digest,
                             review: SHA256Digest?, environment: ProjectEnvironment) async throws -> ProjectRecord {
        throw GhidraHostError(.refused, "a served store keeps no project sent to it")
    }

    public func readProject(module: SHA256Digest) async throws -> (record: ProjectRecord, file: URL)? { nil }

    public func writeRevision(module: SHA256Digest, reading: AnalysisReading, artifact: SHA256Digest,
                              by: String?) async throws {
        try await recordRevision(module: module, reading: reading, artifact: artifact, by: by)
    }

    public func storedAnalysis(module: SHA256Digest, recipe: String) async throws -> AnalysisManifest? {
        try await self.module(module).manifests.first { $0.recipe.id == recipe }
    }

    public func writeAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data,
                              source: SourceIdentity, reading: AnalysisReading?,
                              replace: Bool) async throws -> AnalysisManifest {
        try await putAnalysis(module: module, recipe: recipe, artifact: artifact, source: source,
                              reading: reading, replace: replace)
    }

    public func writeLibraryEntries(module: SHA256Digest, rev: Int?, by: String?, proposals: [LibraryProposal],
                                    take: LibraryTake) async throws -> LibraryWriteResult {
        try await putLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: take)
    }

    public func previewLibraryEntries(module: SHA256Digest, rev: Int?, by: String?,
                                      proposals: [LibraryProposal],
                                      take: LibraryTake) async throws -> LibraryWriteResult {
        try await putLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: take,
                                    dryRun: true)
    }

    public func reviewGaps(module: SHA256Digest) async throws -> [String: [String]]? {
        guard let manifest = try await self.module(module).manifests.first else { return nil }
        let data = try await object(manifest.artifact.sha256)
        return (try? JSONDecoder().decode(CodeArtifact.self, from: data))?.reviewGapsByEntry()
    }

    public func readLibraryIndex() async throws -> LibraryIndex { try await libraryIndex() }
    public func readLibraryHistory(id: String) async throws -> LibraryHistory? { try await libraryHistory(id: id) }
    public func readObject(_ digest: SHA256Digest) async throws -> Data { try await object(digest) }
    /// A served store renders on the server: this side cannot, and a marked
    /// function then answers without `text`.
    public func functionAsRead(module: SHA256Digest, entry: CodeAddress) async throws -> CodeArtifact.Function? { nil }
    public func newestAnalyses() async throws -> [AnalysisManifest] {
        try await modules().compactMap(\.manifests.first)
    }
}
