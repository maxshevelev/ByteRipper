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
        return try! JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
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

    func testRebindingTheSameAnalysisUpdatesOnlyWhatIsNamed() throws {
        let identity = module()
        let data = artifact()
        let first = try store.putAnalysis(
            module: identity, recipe: recipe(), artifact: data,
            source: SourceIdentity(document: "d1", node: "0.1"))
        XCTAssertEqual(first.source.node, "0.1")

        let rebound = try store.putAnalysis(
            module: identity, recipe: recipe(), artifact: data,
            source: SourceIdentity(document: "d1", node: "0.2"))
        XCTAssertEqual(rebound.source.node, "0.2")
        XCTAssertEqual(
            try store.analysis(module: identity.sha256, recipe: "code-v2-ghidra-12.1.2")?.source.node,
            "0.2")

        // A re-put that names no node keeps the one already written.
        let kept = try store.putAnalysis(module: identity, recipe: recipe(), artifact: data)
        XCTAssertEqual(kept.source.node, "0.2")
        XCTAssertEqual(kept.source.document, "d1")
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
        XCTAssertEqual(imported.imported.count, 1)
        XCTAssertEqual(try other.analysis(module: manifest.module.sha256)?.artifact,
                       manifest.artifact)
        XCTAssertEqual(other.verify(), [])
    }

    /// A bundle written by the Python store: the Swift reader has to read the
    /// same entries and the same snake_case manifest.
    func testAPythonBundleImports() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bundle", withExtension: "zip",
                                                  subdirectory: "Fixtures"))
        let imported = try store.importBundle(from: url).imported
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

    // MARK: - Readings

    private func reading(_ rev: Int, project: String = "p") -> AnalysisReading {
        AnalysisReading(project: project, rev: rev)
    }

    func testTheOrderOfTwoReadings() {
        XCTAssertEqual(ReadingOrder(incoming: nil, stored: nil), .unreviewed)
        XCTAssertEqual(ReadingOrder(incoming: reading(1), stored: nil), .newer)
        XCTAssertEqual(ReadingOrder(incoming: nil, stored: reading(1)), .unreviewedOverReviewed)
        XCTAssertEqual(ReadingOrder(incoming: reading(2), stored: reading(1)), .newer)
        XCTAssertEqual(ReadingOrder(incoming: reading(1), stored: reading(1)), .notNewer)
        XCTAssertEqual(ReadingOrder(incoming: reading(1), stored: reading(2)), .notNewer)
        XCTAssertEqual(ReadingOrder(incoming: reading(9, project: "q"), stored: reading(1)), .otherProject)
    }

    func testALaterPublishReplacesTheReadingAndAnEarlierOneIsRefused() throws {
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(functions: 1),
                              reading: reading(1))
        let second = try store.putAnalysis(module: module(), recipe: recipe(),
                                           artifact: artifact(functions: 2), reading: reading(2))
        XCTAssertEqual(try store.analysis(module: module().sha256)?.artifact, second.artifact)
        XCTAssertThrowsError(try store.putAnalysis(module: module(), recipe: recipe(),
                                                   artifact: artifact(functions: 3), reading: reading(2)))
    }

    func testAMechanicalRunDoesNotReplaceAReadingUnlessTold() throws {
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(functions: 1),
                              reading: reading(1))
        XCTAssertThrowsError(try store.putAnalysis(module: module(), recipe: recipe(),
                                                   artifact: artifact(functions: 2), replace: true))
        let replaced = try store.putAnalysis(module: module(), recipe: recipe(),
                                             artifact: artifact(functions: 2), discardReading: true)
        XCTAssertNil(replaced.reading)
    }

    func testAReadingReplacesAMechanicalArtifact() throws {
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(functions: 1))
        let read = try store.putAnalysis(module: module(), recipe: recipe(),
                                         artifact: artifact(functions: 2), reading: reading(1))
        XCTAssertEqual(try store.analysis(module: module().sha256)?.reading, read.reading)
    }

    func testTheSameArtifactAdoptsAReadingButKeepsAnExistingOne() throws {
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact())
        let adopted = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                            reading: reading(1))
        XCTAssertEqual(adopted.reading, reading(1))
        let kept = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                         reading: reading(5))
        XCTAssertEqual(kept.reading, reading(1))
    }

    /// The table of `Design/GHIDRA_SHARED_PLAN.md` §5.6, at bundle import.
    func testABundleImportTakesEachAnalysisByItsReading() throws {
        let other = try ContentStore(root: directory.appendingPathComponent("other", isDirectory: true))
        func bundle(_ reading: AnalysisReading?, functions: Int, module label: String) throws -> URL {
            let source = try ContentStore(root: directory.appendingPathComponent(UUID().uuidString))
            let manifest = try source.putAnalysis(module: module(label), recipe: recipe(),
                                                  artifact: artifact(functions: functions),
                                                  reading: reading)
            let url = directory.appendingPathComponent("\(UUID().uuidString).zip")
            try source.exportBundle([manifest.key!], to: url)
            return url
        }
        // An older revision is skipped, a newer one replaces.
        try other.putAnalysis(module: module("a"), recipe: recipe(), artifact: artifact(functions: 2),
                              reading: reading(2))
        XCTAssertEqual(try other.importBundle(from: bundle(reading(1), functions: 1, module: "a")).skipped.count, 1)
        XCTAssertEqual(try other.importBundle(from: bundle(reading(3), functions: 3, module: "a")).imported.count, 1)
        XCTAssertEqual(try other.analysis(module: module("a").sha256)?.reading?.rev, 3)
        // A mechanical artifact never replaces a reading.
        XCTAssertEqual(try other.importBundle(from: bundle(nil, functions: 4, module: "a")).skipped.count, 1)
        // Another project's reading is kept aside, and its object survives gc.
        let conflict = try other.importBundle(from: bundle(reading(1, project: "q"), functions: 5, module: "a"))
        XCTAssertEqual(conflict.conflicts.count, 1)
        XCTAssertEqual(other.conflicts().count, 1)
        XCTAssertEqual(try other.analysis(module: module("a").sha256)?.reading?.project, "p")
        try other.collectGarbage(dryRun: false)
        XCTAssertTrue(other.hasObject(other.conflicts()[0].artifact.sha256))
        XCTAssertEqual(other.verify(), [])
    }

    func testOneBadEntryDoesNotStopTheRestOfABundle() throws {
        let first = try store.putAnalysis(module: module("a"), recipe: recipe(), artifact: artifact(functions: 1))
        let second = try store.putAnalysis(module: module("b"), recipe: recipe(), artifact: artifact(functions: 2))
        let url = directory.appendingPathComponent("two.zip")
        try store.exportBundle([first.key!, second.key!], to: url)
        let other = try ContentStore(root: directory.appendingPathComponent("other", isDirectory: true))
        try other.putAnalysis(module: module("a"), recipe: recipe(), artifact: artifact(functions: 9))
        let result = try other.importBundle(from: url)
        XCTAssertEqual(result.skipped.map(\.key), [first.key!.description])
        XCTAssertEqual(result.imported.map(\.key), [second.key])
        // The skipped artifact's object is stored all the same.
        XCTAssertTrue(other.hasObject(first.artifact.sha256))
    }

    func testTheUEFIRecipeAndPhaseSurviveARebind() throws {
        var uefi = recipe()
        uefi.types = "edk2-stable202608"
        uefi.passes = ["ApplyUefi.java"]
        var identity = module()
        identity.phase = "pei"
        try store.putAnalysis(module: identity, recipe: uefi, artifact: artifact())
        let rebound = try store.putAnalysis(module: identity, recipe: uefi, artifact: artifact(),
                                            source: SourceIdentity(node: "0.1"))
        XCTAssertEqual(rebound.recipe.types, "edk2-stable202608")
        XCTAssertEqual(rebound.recipe.passes, ["ApplyUefi.java"])
        XCTAssertEqual(try store.analysis(module: identity.sha256)?.module.phase, "pei")
    }

    func testTheTimestampMatchesThePythonStoresShape() {
        XCTAssertTrue(Timestamps.now().hasSuffix("+00:00"))
    }
}
