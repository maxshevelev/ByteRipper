import Foundation
import XCTest
@testable import CodeAnalysis

/// The index a panel asks "is there an analysis for this module?" of: usable
/// manifests only, and the module sizes that make a body worth hashing.
final class CodeAnalysisIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeAnalysisIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func module(_ label: String) -> ModuleIdentity {
        let bytes = Data(label.utf8)
        return ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count,
                              name: label, kind: "TE",
                              language: "x86:LE:32:default", imageBase: "0x0")
    }

    private func recipe(_ id: String = "code-v2-ghidra-12.1.2") -> AnalysisRecipe {
        AnalysisRecipe(id: id, exporter: 2, ghidra: "12.1.2", script: "ExportCode.java")
    }

    private func put(_ label: String, in store: ContentStore) throws -> AnalysisManifest {
        try store.putAnalysis(module: module(label), recipe: recipe(),
                              artifact: Data("{\"script_version\":2}".utf8))
    }

    // MARK: - Loading

    func testAnEmptyStoreHasNoAnalyses() {
        let index = CodeAnalysisIndex.load(from: directory.appendingPathComponent("missing"))
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(index.analyzedSizes.isEmpty)
        XCTAssertEqual(index.manifests, [])
    }

    func testTheIndexKeepsTheUsableModulesAndSizes() throws {
        let store = try ContentStore(root: directory)
        let first = try put("one", in: store)
        let second = try put("two", in: store)

        let index = CodeAnalysisIndex.load(from: directory)
        XCTAssertEqual(index.manifests.count, 2)
        XCTAssertEqual(index.analyzedSizes, [first.module.size, second.module.size])
        XCTAssertTrue(index.hasUsableAnalysis(for: first.module.sha256))
        XCTAssertTrue(index.hasUsableAnalysis(for: second.module.sha256))
        XCTAssertEqual(index.manifests(for: first.module.sha256).count, 1)
        XCTAssertEqual(index.newest(for: first.module.sha256)?.module.sha256,
                       first.module.sha256)
    }

    func testAMissingObjectDoesNotCount() throws {
        let store = try ContentStore(root: directory)
        let manifest = try put("one", in: store)
        try FileManager.default.removeItem(at: store.objectURL(manifest.artifact.sha256))

        let index = CodeAnalysisIndex.load(from: directory)
        XCTAssertTrue(index.isEmpty)
        XCTAssertFalse(index.hasUsableAnalysis(for: manifest.module.sha256))
    }

    func testADirectoryNamedLikeAnObjectDoesNotCount() throws {
        let store = try ContentStore(root: directory)
        let manifest = try put("one", in: store)
        let object = store.objectURL(manifest.artifact.sha256)
        try FileManager.default.removeItem(at: object)
        try FileManager.default.createDirectory(at: object, withIntermediateDirectories: false)

        XCTAssertTrue(CodeAnalysisIndex.load(from: directory).isEmpty)
    }

    func testAnUnreadableManifestIsSkipped() throws {
        let store = try ContentStore(root: directory)
        let manifest = try put("one", in: store)
        let key = try XCTUnwrap(manifest.key)
        try Data("not a manifest".utf8).write(to: store.manifestURL(key))

        XCTAssertTrue(CodeAnalysisIndex.load(from: directory).isEmpty)
    }

    func testTheDefaultRootIsTheSkillsStore() {
        XCTAssertTrue(CodeAnalysisPaths.defaultRoot.path.hasSuffix("/ByteRipper/Analysis"))
    }

    // MARK: - Recipes

    func testTheNewestRecipeIsChosenByTime() {
        let module = module("one")
        let artifact = AnalysisArtifact(sha256: SHA256Digest(data: Data("a".utf8)),
                                        size: 1, mediaType: "application/json")
        func manifest(_ id: String, _ time: String) -> AnalysisManifest {
            AnalysisManifest(
                module: module, recipe: recipe(id), artifact: artifact,
                analyzedAt: time, stats: AnalysisStats())
        }
        let older = manifest("code-v2-ghidra-12.1.2", "2026-10-24T10:00:00+00:00")
        let newer = manifest("code-v3-ghidra-12.2", "2026-10-25T10:00:00+00:00")
        let index = CodeAnalysisIndex(manifests: [older, newer])

        XCTAssertEqual(index.newest(for: module.sha256)?.recipe.id,
                       "code-v3-ghidra-12.2")
    }
}
