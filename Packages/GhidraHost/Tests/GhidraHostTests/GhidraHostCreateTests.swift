import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A project made from a module's bytes here, published through an owner,
/// against the artifact `code_artifact.py` stored for the same bytes. Run with
/// `GHIDRA_PARITY_MODULE` naming the module and `GHIDRA_PARITY_ARTIFACT` the
/// artifact the script wrote; skipped otherwise.
final class GhidraHostCreateTests: XCTestCase {
    func testAProjectMadeHerePublishesTheScriptsArtifact() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modulePath = environment["GHIDRA_PARITY_MODULE"],
              let artifactPath = environment["GHIDRA_PARITY_ARTIFACT"] else {
            throw XCTSkip("GHIDRA_PARITY_MODULE and GHIDRA_PARITY_ARTIFACT are not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCreateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 120, holder: "GhidraHostCreateTests"),
                              writer: store)
        let module = URL(fileURLWithPath: modulePath)
        let blob = try Data(contentsOf: module)
        let state = try await host.create(module: blob, name: module.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(state.module.sha256, SHA256Digest(data: blob).hex)
        let publication = try await host.publish(SHA256Digest(data: blob), by: nil)
        await host.stop(SHA256Digest(data: blob))
        XCTAssertNil(publication.manifest.reading, "a project nobody reviewed publishes the mechanical reading")
        let ours = try store.object(publication.manifest.artifact.sha256)
        XCTAssertEqual(ours, try Data(contentsOf: URL(fileURLWithPath: artifactPath)))
    }
}
