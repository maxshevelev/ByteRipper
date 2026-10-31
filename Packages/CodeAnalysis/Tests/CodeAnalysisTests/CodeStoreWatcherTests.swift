import Foundation
import XCTest
@testable import CodeAnalysis

/// The store's change notification: a manifest written by any process is an
/// event, and so is a store created after the watch began.
final class CodeStoreWatcherTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeStoreWatcherTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAPathIsAboutTheAnalysesOrNot() throws {
        // /tmp is a link to /private/tmp; FSEvents names the real folder.
        let root = URL(fileURLWithPath: "/tmp/CodeStoreWatcherTests-\(UUID().uuidString)/store")
        let watcher = CodeStoreWatcher(root: root) {}
        defer { watcher.stop() }
        let real = "/private" + root.path
        XCTAssertTrue(watcher.concernsAnalyses([real + "/analyses/abc/code-v3/manifest.json"]))
        XCTAssertTrue(watcher.concernsAnalyses([real + "/analyses"]))
        XCTAssertTrue(watcher.concernsAnalyses([real]), "a coalesced event names a folder above")
        XCTAssertFalse(watcher.concernsAnalyses([real + "/objects/abc"]))
        XCTAssertFalse(watcher.concernsAnalyses([real + "/analysesX"]))
    }

    func testAnAnalysisWrittenIntoANewStoreIsSeen() throws {
        let root = try temporaryRoot()
        let seen = expectation(description: "the store changed")
        seen.assertForOverFulfill = false
        let watcher = CodeStoreWatcher(root: root, latency: 0.05) { seen.fulfill() }
        defer { watcher.stop() }

        let store = try ContentStore(root: root)
        let module = Data([0x56, 0x5A, 1, 2])
        try store.putAnalysis(
            module: ModuleIdentity(sha256: SHA256Digest(data: module), size: module.count,
                                   name: "M", kind: "TE"),
            recipe: AnalysisRecipe(id: "code-v3-ghidra-12.1.2", exporter: 3,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: Data(#"{"script_version":3}"#.utf8))
        wait(for: [seen], timeout: 10)
    }
}

/// The one loader the app and the agent share.
final class ContentStoreArtifactTests: XCTestCase {
    func testTheArtifactAManifestNamesIsTyped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentStoreArtifactTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = Data([0x56, 0x5A, 1, 2])
        let identity = ModuleIdentity(sha256: SHA256Digest(data: module), size: module.count, name: "M")
        let good = try store.putAnalysis(
            module: identity,
            recipe: AnalysisRecipe(id: "code-v3-ghidra-12.1.2", exporter: 3,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: Data(#"{"script_version":3,"functions":[]}"#.utf8))
        XCTAssertEqual(try store.artifact(for: good).scriptVersion, 3)

        let unknown = try store.putAnalysis(
            module: identity,
            recipe: AnalysisRecipe(id: "code-v10-ghidra-12.1.2", exporter: 10,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: Data(#"{"script_version":10}"#.utf8))
        XCTAssertThrowsError(try store.artifact(for: unknown)) { error in
            XCTAssertEqual(error as? CodeArtifactError, .unsupportedVersion(10))
        }
    }
}
