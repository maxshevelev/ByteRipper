import CodeAnalysis
import CryptoKit
import Foundation
@testable import GhidraHost

/// Ghidra's analysis of a module, made once and copied into each test.
///
/// `GhidraHost.create` imports the image with `analyzeHeadless`, runs Ghidra's
/// whole analysis and the UEFI pass: seconds to a minute per module, the same
/// work for the same bytes in every test that opens them. A test that is not
/// about making a project takes it from here instead. The first test to open a
/// module makes the project as `create` always does and keeps a copy; every
/// later one gets an APFS clone of that copy in its own projects folder, which
/// `create` then opens as a project it already has.
///
/// The copy is kept between runs, under a key of everything the analysis
/// depends on: the module's bytes, the name and phase it is opened with, the
/// Ghidra install, the EDK2 type set, and the bytes of every Ghidra script the
/// pass runs. A change to any of them makes a new key, so a stale project is
/// never handed out; old keys are simply left behind in the temporary folder.
enum TestProjectCache {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ByteRipperGhidraTestProjects", isDirectory: true)

    static func key(host: GhidraHost, blob: Data, name: String, phase: GhidraHost.Phase?, uefi: Bool) async throws -> String {
        var hash = SHA256()
        let install = try await host.ghidra()
        let scripts = await host.configuration.sources.scripts
        func add(_ text: String) { hash.update(data: Data((text + "\n").utf8)) }
        add(SHA256Digest(data: blob).hex)
        add(name)
        add(phase?.rawValue ?? "-")
        add(uefi ? "uefi" : "plain")
        add(install.home.path)
        add(install.version)
        add(UEFITypes.types)
        let files = (FileManager.default.enumerator(at: scripts, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.path < $1.path }
        for file in files {
            add(file.lastPathComponent)
            hash.update(data: (try? Data(contentsOf: file)) ?? Data())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension GhidraHost {
    /// `create`, from the test cache when the module was made before with the
    /// same inputs. What it answers is what `create` answers for a project it
    /// already has.
    func createCached(module blob: Data, name: String, source: ProjectState.Source? = nil,
                      phase: Phase? = nil, uefi: Bool = true) async throws -> ProjectState {
        let project = self.project(SHA256Digest(data: blob))
        guard !project.exists else { return try project.state() }
        let key = try await TestProjectCache.key(host: self, blob: blob, name: name, phase: phase, uefi: uefi)
        let kept = TestProjectCache.root.appendingPathComponent(key, isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: kept.appendingPathComponent("state.json").path) {
            try manager.createDirectory(at: project.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A copy on the same APFS volume is a clone: no bytes move.
            try manager.copyItem(at: kept, to: project.folder)
            var state = try project.state()
            // A fresh project is no other test's: its own identity, its source.
            state.project = UUID().uuidString.lowercased()
            state.source = source
            try project.write(state)
            return state
        }
        let state = try await create(module: blob, name: name, source: source, phase: phase, uefi: uefi)
        // Kept under a temporary name first, so a run stopped halfway never
        // leaves a half-copied project under the key.
        try manager.createDirectory(at: TestProjectCache.root, withIntermediateDirectories: true)
        let staging = TestProjectCache.root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try manager.copyItem(at: project.folder, to: staging)
        if (try? manager.moveItem(at: staging, to: kept)) == nil { try? manager.removeItem(at: staging) }
        return state
    }
}
