import CodeAnalysis
import Foundation

/// `state.json` beside a module's kept project: what made it and what was
/// last published (`Design/GHIDRA_SHARED_PLAN.md` §6.2). The same file
/// `ghidra_owner.py` writes, field for field, so either opens a project the
/// other made.
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
        public var rev: Int?
        public var at: String
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(state) + Data("\n".utf8)).write(to: stateURL, options: .atomic)
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
    func writeRevision(module: SHA256Digest, reading: AnalysisReading, by: String?) async throws
    func storedAnalysis(module: SHA256Digest, recipe: String) async throws -> AnalysisManifest?
    func writeAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data, source: SourceIdentity,
                       reading: AnalysisReading?, replace: Bool) async throws -> AnalysisManifest
}

extension ContentStore: AnalysisWriter {
    public func writeObject(_ data: Data) async throws -> SHA256Digest {
        try putObject(data)
    }

    public func writeRevision(module: SHA256Digest, reading: AnalysisReading, by: String?) async throws {
        try recordRevision(module: module, reading: reading, by: by)
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
}

extension RemoteStore: AnalysisWriter {
    public func writeObject(_ data: Data) async throws -> SHA256Digest {
        try await putObject(data)
    }

    public func writeRevision(module: SHA256Digest, reading: AnalysisReading, by: String?) async throws {
        try await recordRevision(module: module, reading: reading, by: by)
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
}
