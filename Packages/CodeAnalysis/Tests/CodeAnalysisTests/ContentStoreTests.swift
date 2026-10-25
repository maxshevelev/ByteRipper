import Foundation
import XCTest
@testable import CodeAnalysis

/// The local CAS: objects by hash, analyses by module and recipe, references
/// and collection, and a bundle from the Python side.
final class ContentStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Helpers

    private func artifact(functions: Int = 1) -> Data {
        let functions = (0..<functions).map { index in
            ["entry": String(format: "0x%X", index),
             "name": "FUN_\(index)",
             "instructions": [["address": String(format: "0x%X", index), "text": "RET"]]] as [String: Any]
        }
        let document: [String: Any] = [
            "script_version": 2,
            "ghidra": "12.1.2",
            "functions": functions,
            "strings": [],
            "post_codes": [],
            "status_code_calls": []
        ]
        return try! JSONSerialization.data(withJSONObject: document)
    }

    private func module(_ label: String = "module") -> ModuleIdentity {
        let data = Data(label.utf8)
        return ModuleIdentity(sha256: SHA256Digest(data: data), size: data.count,
                              name: label, kind: "TE",
                              language: "x86:LE:32:default", imageBase: "0x0")
    }

    private func recipe(_ id: String = "code-v2-ghidra-12.1.2") -> AnalysisRecipe {
        AnalysisRecipe(id: id, exporter: 2, ghidra: "12.1.2", script: "ExportCode.java")
    }

    // MARK: - Objects

    func testAnObjectIsItsHashAndADuplicatePutReturnsTheSame() throws {
        let first = try store.putObject(Data("hello".utf8))
        let second = try store.putObject(Data("hello".utf8))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, SHA256Digest(data: Data("hello".utf8)))
        XCTAssertEqual(try store.object(first), Data("hello".utf8))
    }

    func testACorruptObjectIsRefusedOnReadAndReported() throws {
        let digest = try store.putObject(Data("hello".utf8))
        try Data("HELLO".utf8).write(to: store.objectURL(digest))
        XCTAssertThrowsError(try store.object(digest))
        XCTAssertFalse(store.verify().isEmpty)
    }

    func testAPathThatIsNotADigestIsRefused() {
        XCTAssertNil(SHA256Digest(hex: "../../etc/passwd"))
        XCTAssertThrowsError(try store.refURL("../outside"))
    }

    // MARK: - Analyses

    func testAnAnalysisNamesItsModuleItsRecipeAndItsObject() throws {
        let data = artifact(functions: 3)
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: data)
        XCTAssertEqual(manifest.artifact.sha256, SHA256Digest(data: data))
        XCTAssertEqual(manifest.stats.functions, 3)
        XCTAssertEqual(manifest.stats.instructions, 3)
        XCTAssertEqual(try store.analysis(module: manifest.module.sha256,
                                          recipe: "code-v2-ghidra-12.1.2")?.artifact,
                       manifest.artifact)
        XCTAssertEqual(store.recipes(ofModule: manifest.module.sha256), ["code-v2-ghidra-12.1.2"])
    }

    func testTheSameRecipeWithAnotherArtifactIsRefusedUnlessReplaced() throws {
        let identity = module()
        let first = try store.putAnalysis(module: identity, recipe: recipe(), artifact: artifact(functions: 1))
        XCTAssertThrowsError(try store.putAnalysis(module: identity, recipe: recipe(),
                                                   artifact: artifact(functions: 2)))
        let replaced = try store.putAnalysis(module: identity, recipe: recipe(),
                                             artifact: artifact(functions: 2), replace: true)
        XCTAssertNotEqual(replaced.artifact.sha256, first.artifact.sha256)
        XCTAssertEqual(replaced.stats.functions, 2)
    }

    func testARecipeNameCannotEscapeItsDirectory() {
        XCTAssertThrowsError(try store.putAnalysis(
            module: module(), recipe: recipe("../../outside"), artifact: artifact()))
    }

    func testTwoRecipesAreTwoAnalysesOfTheSameModule() throws {
        let identity = module()
        try store.putAnalysis(module: identity, recipe: recipe(), artifact: artifact(functions: 1))
        try store.putAnalysis(module: identity, recipe: recipe("code-v2-ghidra-12.2"),
                              artifact: artifact(functions: 2))
        XCTAssertEqual(store.recipes(ofModule: identity.sha256),
                       ["code-v2-ghidra-12.1.2", "code-v2-ghidra-12.2"])
    }

    // MARK: - References and collection

    func testAReferenceKeepsItsAnalysisAndGCLeavesTheRest() throws {
        let first = try store.putAnalysis(module: module("one"), recipe: recipe(),
                                          artifact: artifact(functions: 1))
        let second = try store.putAnalysis(module: module("two"), recipe: recipe(),
                                           artifact: artifact(functions: 2))
        try store.setRef("project", analyses: [first.key!])

        let report = try store.collectGarbage(dryRun: false, deleteUnreferencedAnalyses: true)
        XCTAssertEqual(report.analyses, 1)
        XCTAssertNotNil(try store.analysis(module: first.module.sha256))
        XCTAssertNil(try store.analysis(module: second.module.sha256))
        XCTAssertEqual(store.referencedKeys(), [first.key!])
    }

    func testGCAgainstAnEmptyReferenceSetKeepsAnalyses() throws {
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact())
        let report = try store.collectGarbage(dryRun: false, deleteUnreferencedAnalyses: false)
        XCTAssertEqual(report.analyses, 0)
        XCTAssertNotNil(try store.analysis(module: manifest.module.sha256))
    }

    func testAnObjectNoManifestNamesIsCollected() throws {
        let digest = try store.putObject(Data("orphan".utf8))
        let report = try store.collectGarbage(dryRun: false)
        XCTAssertEqual(report.objects, 1)
        XCTAssertFalse(store.hasObject(digest))
    }

    func testAVerifyIsQuietOnASoundStore() throws {
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact())
        try store.setRef("project", analyses: [manifest.key!])
        XCTAssertEqual(store.verify(), [])
    }

    // MARK: - Bundles

    func testABundleCarriesTheManifestAndTheArtifact() throws {
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(functions: 4))
        let bundle = directory.appendingPathComponent("bundle.zip")
        try store.exportBundle([manifest.key!], to: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))

        let other = try ContentStore(root: directory.appendingPathComponent("other", isDirectory: true))
        let imported = try other.importBundle(from: bundle)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(try other.analysis(module: manifest.module.sha256)?.artifact,
                       manifest.artifact)
        XCTAssertEqual(other.verify(), [])
    }

    /// A bundle written by the Python store: the Swift reader has to read the
    /// same entries and the same snake_case manifest.
    func testAPythonBundleImports() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bundle", withExtension: "zip",
                                                  subdirectory: "Fixtures"))
        let imported = try store.importBundle(from: url)
        XCTAssertEqual(imported.count, 1)
        let manifest = try XCTUnwrap(imported.first)
        XCTAssertEqual(manifest.module.name, "Fixture")
        XCTAssertEqual(manifest.recipe.id, "code-v2-ghidra-12.1.2")
        XCTAssertEqual(manifest.stats.functions, 2)
        XCTAssertEqual(manifest.stats.instructions, 3)
        XCTAssertEqual(manifest.stats.strings, 1)
        XCTAssertEqual(manifest.stats.postCodeWrites, 1)
        XCTAssertEqual(manifest.stats.statusCodeCandidates, 1)
        XCTAssertEqual(store.verify(), [])
    }

    func testTheTimestampMatchesThePythonStoresShape() {
        XCTAssertTrue(Timestamps.now().hasSuffix("+00:00"))
    }
}
