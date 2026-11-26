import Foundation

/// The language marker's first line (`Scripts/make-patched-ghidra.sh`):
/// `<processor>:<patch>` joined by `+`, as `x86:descriptor-tables-1+NDS32:nds32-standby-1`.
/// A patch belongs to a module only when it is for the module's processor, so
/// one install's patches for another processor change neither the module's
/// recipe nor what its project needs. `Owner.languagePatch` and
/// `ExportCode.languagePatch` read the line the same way.
public enum LanguagePatches {
    /// The patches of `line` for `processor` (Ghidra's processor name, `x86`
    /// or `NDS32`), joined by `+`; nil when there are none. A patch written
    /// without its processor — a marker made before NDS32 had one, or a
    /// project record, which keeps the module's own — is NDS32's when its name
    /// starts `nds32-`, else x86's.
    public static func `for`(_ processor: String, in line: String?) -> String? {
        guard let line else { return nil }
        let mine = line.split(separator: "+").compactMap { each -> Substring? in
            guard let colon = each.firstIndex(of: ":") else {
                return unqualifiedProcessor(each).lowercased() == processor.lowercased() ? each : nil
            }
            return each[..<colon].lowercased() == processor.lowercased() ? each[each.index(after: colon)...] : nil
        }
        return mine.isEmpty ? nil : mine.joined(separator: "+")
    }

    static func unqualifiedProcessor(_ patch: Substring) -> String {
        patch.lowercased().hasPrefix("nds32-") ? "NDS32" : "x86"
    }
}

/// What a module's Ghidra project was made and last written with: what an
/// owner opening it elsewhere must match, so the program reads as it was
/// reviewed.
public struct ProjectEnvironment: Codable, Equatable, Sendable {
    /// The Ghidra version, as the install names it.
    public var ghidra: String
    /// The language patches of the project's processor the install was
    /// compiled with (`LanguagePatches`); nil for none.
    public var languagePatch: String?
    /// The EDK2 type set the program was typed with.
    public var types: String?
    /// The passes that made the program.
    public var passes: [String]
    /// The recipe the revision was published under.
    public var recipe: String
    /// The owner build that wrote the project last; a different one opens it.
    public var ownerBuild: Int?

    public init(ghidra: String, languagePatch: String?, types: String?, passes: [String], recipe: String,
                ownerBuild: Int?) {
        self.ghidra = ghidra
        self.languagePatch = languagePatch
        self.types = types
        self.passes = passes
        self.recipe = recipe
        self.ownerBuild = ownerBuild
    }

    /// What an install must share with the project to open it: the program's
    /// database is Ghidra's version's, and its instructions are the language's.
    /// The install must carry every language patch the project was made with
    /// (`a+b` names two); one it carries besides opens the project too — a
    /// patch for another processor changes none of its instructions, and
    /// nds32-standby-1 is brought into an older EC project by `ec/reapply`.
    /// Empty when it may.
    public func differences(ghidra other: String, languagePatch otherPatch: String?) -> [String] {
        var said: [String] = []
        if ghidra != other { said.append("Ghidra \(ghidra) made it, this install is \(other)") }
        func patches(_ line: String?) -> Set<Substring> { Set((line ?? "").split(separator: "+")) }
        if !patches(languagePatch).isSubset(of: patches(otherPatch)) {
            said.append("its language patch is \(languagePatch ?? "none"), this install's is \(otherPatch ?? "none")")
        }
        return said
    }

    private enum CodingKeys: String, CodingKey {
        case ghidra, types, passes, recipe
        case languagePatch = "language_patch"
        case ownerBuild = "owner_build"
    }
}

/// `private/projects/<module>/record.json`: which revision the kept project
/// beside it belongs to. The revision knows nothing of it.
public struct ProjectRecord: Codable, Equatable, Sendable {
    public var module: SHA256Digest
    public var rev: Int
    public var artifact: SHA256Digest
    public var review: SHA256Digest?
    public var environment: ProjectEnvironment
    /// The SHA-256 and size of `project.zip`.
    public var sha256: SHA256Digest
    public var size: Int
    public var at: String

    public init(module: SHA256Digest, rev: Int, artifact: SHA256Digest, review: SHA256Digest?,
                environment: ProjectEnvironment, sha256: SHA256Digest, size: Int, at: String) {
        self.module = module
        self.rev = rev
        self.artifact = artifact
        self.review = review
        self.environment = environment
        self.sha256 = sha256
        self.size = size
        self.at = at
    }
}

/// The store's private part: what the server keeps for itself and serves to
/// nobody. It holds no objects, so the object route cannot name it; a mirror
/// copies manifests and histories, never it; `gc` walks `objects/` only.
extension ContentStore {
    public var privateURL: URL { root.appendingPathComponent("private", isDirectory: true) }
    var projectsURL: URL { privateURL.appendingPathComponent("projects", isDirectory: true) }

    func projectFolder(_ module: SHA256Digest) -> URL {
        projectsURL.appendingPathComponent(module.hex, isDirectory: true)
    }

    /// Where the module's kept project is, when the store holds one.
    public func projectFile(_ module: SHA256Digest) -> URL {
        projectFolder(module).appendingPathComponent("project.zip", isDirectory: false)
    }

    func projectRecordURL(_ module: SHA256Digest) -> URL {
        projectFolder(module).appendingPathComponent("record.json", isDirectory: false)
    }

    /// The module's kept project as the store holds it: the record, and the file
    /// it names. Nil when the store holds none.
    public func project(module: SHA256Digest) throws -> ProjectRecord? {
        let url = projectRecordURL(module)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(ProjectRecord.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// The project at `file` becomes the module's kept project, for the revision
    /// `rev` stored with `artifact`: one per module, the current revision's, and
    /// the one before it goes. The file is copied, then the record names it, so
    /// a stop between the two leaves a record whose sum `verify` refuses.
    @discardableResult
    public func putProject(module: SHA256Digest, file: URL, rev: Int, artifact: SHA256Digest,
                           review: SHA256Digest?, environment: ProjectEnvironment) throws -> ProjectRecord {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw CodeAnalysisError.io("\(file.path): \(error)")
        }
        let record = ProjectRecord(module: module, rev: rev, artifact: artifact, review: review,
                                   environment: environment, sha256: SHA256Digest(data: data), size: data.count,
                                   at: Timestamps.now())
        try withLock {
            try atomicWrite(data, to: projectFile(module))
            try atomicWrite(try encoder.encode(record), to: projectRecordURL(module))
        }
        return record
    }

    /// The modules the private part holds a project for.
    public func projects() -> [SHA256Digest] {
        contents(of: projectsURL).compactMap { SHA256Digest(hex: $0.lastPathComponent) }.sorted()
    }

    /// What is wrong in the private part: a record that cannot be read, a file
    /// whose sum is not the record's, a record of a revision the module's
    /// history does not hold.
    func verifyProjects() -> [String] {
        var problems: [String] = []
        for folder in contents(of: projectsURL) {
            let name = "private/projects/\(folder.lastPathComponent)"
            guard let module = SHA256Digest(hex: folder.lastPathComponent) else {
                problems.append("\(name): not a SHA-256 name")
                continue
            }
            guard let record = try? project(module: module) else {
                problems.append("\(name): record.json cannot be read")
                continue
            }
            guard let data = try? Data(contentsOf: projectFile(module)) else {
                problems.append("\(name): project.zip cannot be read")
                continue
            }
            if SHA256Digest(data: data) != record.sha256 || data.count != record.size {
                problems.append("\(name): project.zip is not the one record.json names")
            }
            if record.module != module {
                problems.append("\(name): record.json names \(record.module.hex)")
            }
            let revisions = (try? reviewHistory(module: module))?.revisions ?? []
            if !revisions.contains(where: { $0.rev == record.rev && $0.artifact == record.artifact }) {
                problems.append("\(name): revision \(record.rev) with artifact \(record.artifact.hex) is not in the module's history")
            }
        }
        return problems
    }
}
