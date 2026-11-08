import CodeAnalysis
import Foundation

/// The shared review-types archives in versions the store keeps. A publish
/// decides its types while it holds the store: its owner merges the review's
/// types into a copy of the current version, a type the archive holds
/// differently refuses the publish before anything is written, and a merge
/// that changed the copy is kept as the next version — a step of the journal.
/// The files beside the projects are a copy of the current version, for the
/// owners to read when they start.
extension GhidraHost {
    /// The names the files of a version have beside the projects and in the
    /// folder an owner merges into.
    static func archiveFileNames(bits: String) -> [String: String] {
        let archive = "review-types-\(bits).gdt"
        return ["archive.gdt": archive, "origin.json": archive + ".origin.json",
                "withdrawn.json": archive + ".withdrawn.json"]
    }

    /// The archive's pointer size, from the program's language.
    static func archiveBits(language: String) -> String {
        language.split(separator: ":").dropFirst(2).first == "64" ? "X64" : "Ia32"
    }

    /// The archive of this size as the store keeps it; when the store keeps
    /// none yet and the projects folder holds one an earlier server merged
    /// into, that one becomes version 1. Nil when there is no archive at all.
    func currentTypeArchive(bits: String) async throws -> (version: TypeArchiveVersion, folder: URL)? {
        if let kept = try await writer.readTypeArchive(bits: bits) { return kept }
        let names = Self.archiveFileNames(bits: bits)
        let beside = configuration.projectsRoot
        guard FileManager.default.fileExists(atPath: beside.appendingPathComponent(names["archive.gdt"]!).path) else {
            return nil
        }
        var files: [String: SHA256Digest] = [:]
        for (stored, local) in names {
            let url = beside.appendingPathComponent(local)
            let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
            files[stored] = try await writer.writeObject(data)
        }
        let first = TypeArchiveVersion(version: 1, files: files, at: Self.now(), by: nil, module: nil, rev: nil,
                                       reason: "the archive an earlier server kept beside its projects")
        _ = try await writer.writeTypeArchive(bits: bits, version: first)
        return try await writer.readTypeArchive(bits: bits)
    }

    /// A folder holding a copy of the current version under the names an
    /// owner reads, or an empty one when there is no archive yet.
    func archiveWorkingCopy(bits: String) async throws -> (folder: URL, current: TypeArchiveVersion?) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-types-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = try await currentTypeArchive(bits: bits)
        if let current {
            for (stored, local) in Self.archiveFileNames(bits: bits) {
                try FileManager.default.copyItem(at: current.folder.appendingPathComponent(stored),
                                                 to: folder.appendingPathComponent(local))
            }
        }
        return (folder, current?.version)
    }

    /// The next version from what an owner left in `folder`, its files stored
    /// as objects; nil when the merge changed nothing.
    func nextTypeVersion(bits: String, folder: URL, after current: TypeArchiveVersion?, answer: TypesMerged,
                         by: String?, module: SHA256Digest, reason: String? = nil) async throws -> TypeArchiveVersion? {
        guard answer.changed else { return nil }
        var files: [String: SHA256Digest] = [:]
        for (stored, local) in Self.archiveFileNames(bits: bits) {
            let url = folder.appendingPathComponent(local)
            let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
            files[stored] = try await writer.writeObject(data)
        }
        if let current, current.files == files { return nil }
        return TypeArchiveVersion(version: (current?.version ?? 0) + 1, files: files, at: Self.now(), by: by,
                                  module: module, rev: nil, added: answer.added, amended: answer.amended,
                                  taken: answer.taken, withdrawn: answer.withdrawn, reason: reason)
    }

    /// The copy beside the projects made the current version again.
    func refreshArchiveCopy(bits: String) async throws {
        guard let current = try await writer.readTypeArchive(bits: bits) else { return }
        try FileManager.default.createDirectory(at: configuration.projectsRoot, withIntermediateDirectories: true)
        for (stored, local) in Self.archiveFileNames(bits: bits) {
            let source = current.folder.appendingPathComponent(stored)
            let target = configuration.projectsRoot.appendingPathComponent(local)
            let data = try Data(contentsOf: source)
            if (try? Data(contentsOf: target)) == data { continue }
            try data.write(to: target, options: .atomic)
        }
    }

    /// Every copy beside the projects brought to its current version: after a
    /// server stopped between keeping a version and copying it.
    func refreshArchiveCopies() async {
        for bits in ContentStore.typeArchiveBits { try? await refreshArchiveCopy(bits: bits) }
    }

    /// What an owner's `/v1/types/merge` answered.
    struct TypesMerged: Sendable {
        var changed: Bool
        var added: [String]
        var amended: [String]
        var taken: [String]
        var withdrawn: [String] = []
        var conflicts: [String]
        var origins: [String: String]

        init(_ data: Data) {
            let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            changed = answer["changed"] as? Bool ?? false
            added = answer["added"] as? [String] ?? []
            amended = answer["amended"] as? [String] ?? []
            taken = answer["taken"] as? [String] ?? []
            conflicts = answer["conflicts"] as? [String] ?? []
            origins = answer["origins"] as? [String: String] ?? [:]
        }

        /// The conflicts that are a type the archive holds differently: a
        /// withdrawn name stays in its program, as it did before versions.
        var replacements: [String] {
            conflicts.filter { !(origins[$0] ?? "").hasPrefix("withdrawn ") }
        }
    }

    /// The publish's types decided while it holds the store: merged into a
    /// copy of the current version, refused when one would replace a type the
    /// archive holds, and the next version when the copy changed.
    func decideTypes(_ module: SHA256Digest, language: String, take: Bool,
                     by: String?) async throws -> (merged: TypesMerged, bits: String, version: TypeArchiveVersion?) {
        let bits = Self.archiveBits(language: language)
        let (folder, current) = try await archiveWorkingCopy(bits: bits)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = take ? "/v1/types/merge?take_type_conflicts=1" : "/v1/types/merge"
        let body = try JSONSerialization.data(withJSONObject: ["archive": folder.path])
        let merged = TypesMerged(try await typesCall(module, path, body: body))
        let replacements = merged.replacements
        if !replacements.isEmpty {
            let names = Dictionary((try? await writer.newestAnalyses())?.map { ($0.module.sha256.hex, $0.module.name) } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            throw GhidraHostError(.refused, Self.typeRefusal(replacements, origins: merged.origins, names: names,
                                                             version: current?.version, bits: bits), status: 409)
        }
        let version = try await nextTypeVersion(bits: bits, folder: folder, after: current, answer: merged,
                                                by: by, module: module)
        return (merged, bits, version)
    }

    static func typeRefusal(_ names: [String], origins: [String: String], names modules: [String: String],
                            version: Int?, bits: String) -> String {
        let listed = names.map { name -> String in
            let origin = origins[name] ?? ""
            guard let digest = SHA256Digest(hex: origin) else { return name }
            return "\(name) (written by \(modules[digest.hex] ?? origin))"
        }
        return "the shared \(bits) types" + (version.map { " (version \($0))" } ?? "")
            + " hold these differently, and this publish would replace them: " + listed.joined(separator: ", ")
            + ". Nothing was written. Make the module's type the shared one (`ghidra_type_definition` shows both), "
            + "or, when the shared one is wrong, tell the person with the evidence: only they replace a shared type, "
            + "in the server's console (Activity, the module in work, its shared-types button). An agent cannot."
    }

    /// A type taken out of the shared archive, as a version of its own.
    func withdrawSharedType(_ module: SHA256Digest, body: Data) async throws -> Data {
        let hold = try await writer.lockPublishes()
        publishing += 1
        defer {
            publishing -= 1
            hold.release()
        }
        let state = try project(module).state()
        let language = try await ownerLanguage(module) ?? (state.module.kind == "TE" || state.module.phase == "pei"
                                                            ? "x86:LE:32:default" : "x86:LE:64:default")
        let bits = Self.archiveBits(language: language)
        let (folder, current) = try await archiveWorkingCopy(bits: bits)
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        request["archive"] = folder.path
        let answer = try await typesCall(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: request))
        let said = (try? JSONSerialization.jsonObject(with: answer) as? [String: Any]) ?? [:]
        var merged = TypesMerged(Data("{}".utf8))
        merged.changed = true
        merged.withdrawn = said["withdrawn"] as? [String] ?? []
        if let version = try await nextTypeVersion(bits: bits, folder: folder, after: current, answer: merged,
                                                   by: configuration.holder, module: module,
                                                   reason: said["reason"] as? String) {
            _ = try await writer.writeTypeArchive(bits: bits, version: version)
            try await refreshArchiveCopy(bits: bits)
        }
        return answer
    }

    /// The program's language as its owner says.
    func ownerLanguage(_ module: SHA256Digest) async throws -> String? {
        let record = try await owner(of: module)
        let hello = try? JSONSerialization.jsonObject(with: try await Self.call(record.port, "GET", "/v1/hello",
                                                                              timeout: 10).data) as? [String: Any]
        return hello?["language"] as? String
    }
}
