import CodeAnalysis
import Foundation

/// The kept project at its revision: a publish keeps it in the store's private
/// part, and a host that has no folder for a module the store keeps one of
/// opens that one, so the project the review goes on is the one the revision
/// was published from.
extension GhidraHost {
    /// What this install and the project make: the environment a record keeps.
    func environment(of state: ProjectState, recipe: String) throws -> ProjectEnvironment {
        let install = try ghidra()
        return ProjectEnvironment(ghidra: install.version, languagePatch: install.languagePatch,
                                  types: state.madeWith.types, passes: state.madeWith.passes, recipe: recipe,
                                  ownerBuild: try? OwnerBuild.build(for: install, sources: configuration.sources))
    }

    /// The project packed and kept for the revision just stored. The owner has
    /// saved the program on the way — the publish and the marks do — so the
    /// files are the revision's.
    func keepProject(_ module: SHA256Digest, state: ProjectState, rev: Int, artifact: SHA256Digest,
                     review: SHA256Digest?, recipe: String) async throws -> ProjectRecord {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghidra-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let zip = scratch.appendingPathComponent("project.zip")
        try ProjectPack.pack(project(module), into: zip, scratch: scratch)
        return try await writer.writeProject(module: module, file: zip, rev: rev, artifact: artifact, review: review,
                                             environment: try environment(of: state, recipe: recipe))
    }

    /// The store's kept project of a module with no folder here unpacked into
    /// its place. Nothing when the store keeps none. Refused when this install
    /// cannot open it as it was made, or when it is of an older revision than
    /// the module's newest: the review would go on from a program the store
    /// has moved past.
    func restoreProject(_ module: SHA256Digest) async throws {
        guard let kept = try await writer.readProject(module: module) else { return }
        let install = try ghidra()
        let differences = kept.record.environment.differences(ghidra: install.version,
                                                              languagePatch: install.languagePatch)
        guard differences.isEmpty else {
            throw GhidraHostError(.refused, "the store keeps \(module.hex)'s project, and this install cannot open it "
                                  + "as it was made: " + differences.joined(separator: "; "), status: 409)
        }
        let newest = try await writer.newestAnalyses().filter { $0.module.sha256 == module }
            .compactMap(\.reading?.rev).max()
        if let newest, newest > kept.record.rev {
            throw GhidraHostError(.refused, "the store keeps \(module.hex)'s project of revision \(kept.record.rev), "
                                  + "and the module is at revision \(newest): a review on it would go on from "
                                  + "a program the store has moved past", status: 409)
        }
        let folder = project(module).folder
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent("unpack-\(module.hex)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration.projectsRoot, withIntermediateDirectories: true)
        try ProjectPack.unpack(kept.file, into: staging)
        do {
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw GhidraHostError(.project, "\(folder.path): \(error)")
        }
    }
}
