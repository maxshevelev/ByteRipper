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

    /// A mirror holds what was asked of it: a manifest naming an object it has
    /// not fetched yet is not a damaged store, and the same store with no source
    /// to fetch it from is.
    func testAVerifyOnAMirrorDoesNotCountWhatItHasNotFetched() throws {
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact())
        try FileManager.default.removeItem(at: directory.appendingPathComponent("objects/\(manifest.artifact.sha256.hex)"))
        XCTAssertFalse(store.verify().isEmpty, "with no source, an object gone is a problem")
        defer { ContentStore.register(partSource: nil, forRoot: directory) }
        ContentStore.register(partSource: .init(root: { _ in nil }, files: { _ in [:] }), forRoot: directory)
        XCTAssertEqual(try ContentStore(root: directory).verify(), [])
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

    /// A comment changes the review document and not the artifact: the same
    /// artifact takes a newer reading of the same project, and nothing else.
    func testTheSameArtifactTakesANewerReadingOnly() throws {
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact())
        let adopted = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                            reading: reading(1))
        XCTAssertEqual(adopted.reading, reading(1))
        let newer = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                          reading: reading(5))
        XCTAssertEqual(newer.reading, reading(5))
        let older = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                          reading: reading(2))
        XCTAssertEqual(older.reading, reading(5))
        let other = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                          reading: reading(9, project: "q"))
        XCTAssertEqual(other.reading, reading(5))
    }

    /// A later revision that printed the artifact a recipe already holds is the
    /// module's newest, though another recipe was written since that artifact was.
    func testARevisionOfTheSameArtifactIsTheNewestOverAnotherRecipe() throws {
        let first = recipe("code-v2-ghidra-12.1.2"), second = recipe("code-v2-ghidra-12.2")
        try store.putAnalysis(module: module(), recipe: first, artifact: artifact(), reading: reading(1))
        Thread.sleep(forTimeInterval: 1.1)
        try store.putAnalysis(module: module(), recipe: second, artifact: artifact(), reading: reading(2))
        XCTAssertEqual(try store.analysis(module: module().sha256)?.recipe.id, second.id)
        Thread.sleep(forTimeInterval: 1.1)
        try store.putAnalysis(module: module(), recipe: first, artifact: artifact(), reading: reading(3))
        let newest = try store.analysis(module: module().sha256)
        XCTAssertEqual(newest?.recipe.id, first.id)
        XCTAssertEqual(newest?.reading, reading(3))
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

    func testGCKeepsTheReviewDocumentAReadingNames() throws {
        let document = try store.putObject(Data(#"{"schema":1}"#.utf8))
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                              reading: AnalysisReading(project: "p", rev: 1, review: document))
        XCTAssertEqual(try store.collectGarbage(dryRun: false).objects, 0)
        XCTAssertTrue(store.hasObject(document))
        XCTAssertEqual(store.verify(), [])
        try FileManager.default.removeItem(at: store.objectURL(document))
        XCTAssertEqual(store.verify().count, 1)
    }

    // MARK: - Review history

    /// The commit order of `Design/GHIDRA_SHARED_PLAN.md` §5.4: document,
    /// history entry, analysis.
    private func publish(_ rev: Int, document text: String, project: String = "p",
                         functions: Int = 1) throws -> AnalysisReading {
        let document = try store.putObject(Data(text.utf8))
        let reading = AnalysisReading(project: project, rev: rev, review: document)
        try store.recordRevision(module: module().sha256, reading: reading, by: "agent")
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(functions: functions),
                              reading: reading)
        return reading
    }

    func testTheHistoryKeepsEveryRevisionAndGCKeepsTheirDocuments() throws {
        let first = try publish(1, document: #"{"rev":1}"#)
        let second = try publish(2, document: #"{"rev":2}"#, functions: 2)
        let history = try XCTUnwrap(try store.reviewHistory(module: module().sha256))
        XCTAssertEqual(history.revisions.map(\.rev), [1, 2])
        XCTAssertEqual(history.revisions.map(\.by), ["agent", "agent"])
        XCTAssertEqual(try store.collectGarbage(dryRun: false).objects, 1, "only the first artifact goes")
        XCTAssertTrue(store.hasObject(first.review!), "an earlier revision's document is the base for a diff")
        XCTAssertTrue(store.hasObject(second.review!))
        XCTAssertEqual(store.verify(), [])
    }

    /// The module's kept project lives in the store's private part, beside the
    /// revision it belongs to: one per module, the newest replacing the one
    /// before. `verify` checks its sum and its revision; `gc` leaves it; it is
    /// no object, so nothing serves or mirrors it by a digest.
    func testAProjectIsKeptPrivatelyAtItsRevision() throws {
        let document = try store.putObject(Data(#"{"rev":1}"#.utf8))
        let code = try store.putObject(artifact())
        let reading = AnalysisReading(project: "p", rev: 1, review: document)
        try store.recordRevision(module: module().sha256, reading: reading, artifact: code, by: "agent")
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(), reading: reading)
        let environment = ProjectEnvironment(ghidra: "12.2", languagePatch: "descriptor-tables-1", types: "t",
                                             passes: ["ApplyUefi.java"], recipe: recipe().id, ownerBuild: 7)
        let file = directory.appendingPathComponent("made.zip")
        try Data("first project".utf8).write(to: file)
        XCTAssertNil(try store.project(module: module().sha256))
        let record = try store.putProject(module: module().sha256, file: file, rev: 1, artifact: code,
                                          review: document, environment: environment)
        XCTAssertEqual(try store.project(module: module().sha256), record)
        XCTAssertEqual(try Data(contentsOf: store.projectFile(module().sha256)), Data("first project".utf8))
        XCTAssertEqual(store.projects(), [module().sha256])
        XCTAssertFalse(store.hasObject(record.sha256), "the project is no object")
        XCTAssertEqual(store.verify(), [])
        XCTAssertEqual(try store.collectGarbage(dryRun: false).objects, 0)
        XCTAssertNotNil(try store.project(module: module().sha256), "gc leaves the private part")

        // The newest replaces the one before.
        try Data("second project".utf8).write(to: file)
        try store.putProject(module: module().sha256, file: file, rev: 1, artifact: code, review: document,
                             environment: environment)
        XCTAssertEqual(try Data(contentsOf: store.projectFile(module().sha256)), Data("second project".utf8))
        XCTAssertEqual(store.verify(), [])

        // A file that is not the record's, or a revision the history lacks, is a problem.
        try Data("changed behind the record".utf8).write(to: store.projectFile(module().sha256))
        XCTAssertEqual(store.verify().filter { $0.contains("project.zip is not") }.count, 1, "\(store.verify())")
        try store.putProject(module: module().sha256, file: file, rev: 9, artifact: code, review: document,
                             environment: environment)
        XCTAssertEqual(store.verify().filter { $0.contains("is not in the module's history") }.count, 1)
    }

    func testAnEnvironmentSaysWhatAnInstallDoesNotShare() {
        let made = ProjectEnvironment(ghidra: "12.2", languagePatch: "descriptor-tables-1", types: nil, passes: [],
                                      recipe: "r", ownerBuild: 1)
        XCTAssertEqual(made.differences(ghidra: "12.2", languagePatch: "descriptor-tables-1"), [])
        XCTAssertEqual(made.differences(ghidra: "12.3", languagePatch: nil).count, 2)
    }

    /// A revision keeps the code it published: the history names the
    /// artifact, `gc` keeps it although no analysis manifest does, `verify`
    /// says when it is gone, and a revision naming one the store does not
    /// hold is refused.
    func testARevisionKeepsTheCodeItPublished() throws {
        let document = try store.putObject(Data(#"{"rev":1}"#.utf8))
        let code = SHA256Digest(data: artifact())
        try store.putObject(artifact())
        let reading = AnalysisReading(project: "p", rev: 1, review: document)
        try store.recordRevision(module: module().sha256, reading: reading, artifact: code, by: "agent")
        // The analysis names other bytes: the revision's code is kept by the
        // history alone, which is the point.
        try store.putAnalysis(module: module(), recipe: recipe(),
                              artifact: Data("the analysis's own artifact".utf8), reading: reading)
        XCTAssertEqual(try store.reviewHistory(module: module().sha256)?.revisions.last?.artifact, code)
        XCTAssertEqual(try store.collectGarbage(dryRun: false).objects, 0, "the history keeps the code")
        XCTAssertTrue(store.hasObject(code))
        XCTAssertEqual(store.verify(), [])
        XCTAssertEqual(try store.object(code), artifact())

        try FileManager.default.removeItem(at: store.objectURL(code))
        XCTAssertEqual(store.verify().count, 1)
        XCTAssertTrue(store.verify()[0].contains("artifact"), store.verify()[0])
        XCTAssertThrowsError(try store.recordRevision(
            module: module().sha256, reading: AnalysisReading(project: "p", rev: 2, review: document),
            artifact: SHA256Digest(data: Data("never stored".utf8))))
    }

    func testARevisionNeedsItsDocumentFirst() {
        let missing = SHA256Digest(data: Data("not stored".utf8))
        XCTAssertThrowsError(try store.recordRevision(
            module: module().sha256, reading: AnalysisReading(project: "p", rev: 1, review: missing)))
        XCTAssertThrowsError(try store.recordRevision(
            module: module().sha256, reading: AnalysisReading(project: "p", rev: 1)))
    }

    func testAPublishThatStoppedAfterTheHistoryIsReportedAndRepeatedOver() throws {
        _ = try publish(1, document: #"{"rev":1}"#)
        // Revision 2 recorded, its analysis never stored.
        let stray = try store.putObject(Data(#"{"rev":"2, first try"}"#.utf8))
        try store.recordRevision(module: module().sha256,
                                 reading: AnalysisReading(project: "p", rev: 2, review: stray))
        XCTAssertEqual(store.verify().count, 1)
        XCTAssertTrue(store.verify()[0].contains("revision 2 of p is ahead of its analysis"), store.verify()[0])
        // The next publish is revision 2 again, and overwrites the entry.
        let again = try publish(2, document: #"{"rev":2}"#, functions: 2)
        let history = try XCTUnwrap(try store.reviewHistory(module: module().sha256))
        XCTAssertEqual(history.revisions.map(\.rev), [1, 2])
        XCTAssertEqual(history.revisions.last?.review, again.review)
        XCTAssertEqual(store.verify(), [])
    }

    func testABundleCarriesTheReviewDocumentItsReadingNames() throws {
        let reading = try publish(1, document: #"{"functions":{}}"#)
        let url = directory.appendingPathComponent("reviewed.zip")
        try store.exportBundle([AnalysisKey(module: module().sha256, recipe: recipe().id)!], to: url)
        let other = try ContentStore(root: directory.appendingPathComponent("other", isDirectory: true))
        XCTAssertEqual(try other.importBundle(from: url).imported.count, 1)
        XCTAssertEqual(try other.object(reading.review!), Data(#"{"functions":{}}"#.utf8))
        XCTAssertEqual(other.verify(), [])
    }

    // MARK: - The module description

    /// A revision with a description: the description is an object of its
    /// own, recorded in the history, read back by the manifest, kept by gc,
    /// carried by a bundle, and missing is a problem `verify` names.
    func testTheDescriptionIsAnObjectTheReadingAndTheHistoryName() throws {
        let document = try store.putObject(Data(#"{"rev":1}"#.utf8))
        let description = try store.putObject(Data("# CpuPei\n\nInitialises the CPU.\n".utf8))
        let reading = AnalysisReading(project: "p", rev: 1, review: document, description: description)
        try store.recordRevision(module: module().sha256, reading: reading, by: "agent")
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                             reading: reading)
        XCTAssertEqual(try store.moduleDescription(for: manifest), "# CpuPei\n\nInitialises the CPU.\n")
        XCTAssertEqual(try store.reviewHistory(module: module().sha256)?.revisions.last?.description, description)
        XCTAssertEqual(try store.collectGarbage(dryRun: false).objects, 0)
        XCTAssertTrue(store.hasObject(description))

        let url = directory.appendingPathComponent("described.zip")
        try store.exportBundle([manifest.key!], to: url)
        let other = try ContentStore(root: directory.appendingPathComponent("other", isDirectory: true))
        XCTAssertEqual(try other.importBundle(from: url).imported.count, 1)
        XCTAssertEqual(try other.object(description), Data("# CpuPei\n\nInitialises the CPU.\n".utf8))

        try FileManager.default.removeItem(at: store.objectURL(description))
        XCTAssertEqual(store.verify().count, 2, "the manifest and the history both name it")
    }

    /// Only the description changed: the same artifact takes the next
    /// revision, and the history records it.
    func testADescriptionAloneMakesTheNextRevision() throws {
        let document = try store.putObject(Data(#"{"rev":1}"#.utf8))
        let first = AnalysisReading(project: "p", rev: 1, review: document)
        try store.recordRevision(module: module().sha256, reading: first)
        try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(), reading: first)
        let description = try store.putObject(Data("# Module\n".utf8))
        let second = AnalysisReading(project: "p", rev: 2, review: document, description: description)
        try store.recordRevision(module: module().sha256, reading: second)
        let manifest = try store.putAnalysis(module: module(), recipe: recipe(), artifact: artifact(),
                                             reading: second)
        XCTAssertEqual(manifest.reading, second)
        XCTAssertEqual(try store.reviewHistory(module: module().sha256)?.revisions.map(\.rev), [1, 2])
        var undescribed = manifest
        undescribed.reading = first
        XCTAssertNil(try store.moduleDescription(for: undescribed))
    }

    func testARevisionNeedsItsDescriptionFirst() throws {
        let document = try store.putObject(Data(#"{"rev":1}"#.utf8))
        let missing = SHA256Digest(data: Data("# not stored\n".utf8))
        XCTAssertThrowsError(try store.recordRevision(
            module: module().sha256,
            reading: AnalysisReading(project: "p", rev: 1, review: document, description: missing)))
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

    // MARK: - What a revision changed

    private func codeArtifact(_ functions: [(String, String?)]) -> Data {
        let list = functions.map { entry, c -> [String: Any] in
            var function: [String: Any] = ["entry": entry, "name": entry, "instructions": []]
            if let c { function["c"] = c }
            return function
        }
        return try! JSONSerialization.data(withJSONObject: ["script_version": 5, "functions": list])
    }

    func testARevisionRecordsTheFunctionsItChanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Changed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = SHA256Digest(data: Data("module".utf8))
        let review = try store.putObject(Data("review".utf8))
        func record(_ rev: Int, _ functions: [(String, String?)]) throws -> ReviewRevision {
            let artifact = try store.putObject(codeArtifact(functions))
            let history = try store.recordRevision(module: module,
                                                   reading: AnalysisReading(project: "p", rev: rev, review: review),
                                                   artifact: artifact)
            return try XCTUnwrap(history.revisions.first { $0.rev == rev })
        }
        let first = try record(1, [("0x10", "int a;\n"), ("0x20", "int b;\n"), ("0x30", nil)])
        XCTAssertEqual(first.changedFunctions, ["0x10", "0x20"], "all there is, at the start")
        let second = try record(2, [("0x10", "int a;\n"), ("0x20", "int c;\n"), ("0x30", nil)])
        XCTAssertEqual(second.changedFunctions, ["0x20"])
        XCTAssertEqual(second.changedEntries, [CodeAddress(0x20)])
        let third = try record(3, [("0x20", "int c;\n"), ("0x30", "new\n")])
        XCTAssertEqual(third.changedFunctions, ["0x10", "0x30"], "one gone and one that gained C")
        let same = try record(4, [("0x20", "int c;\n"), ("0x30", "new\n")])
        XCTAssertEqual(same.changedFunctions, [], "the same code changes nothing")
    }

    /// A history from before says nothing; the store works it out once, and a
    /// mirror, whose code may not be here, leaves it to its server.
    func testAnOlderHistoryIsWorkedOutOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Backfill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = SHA256Digest(data: Data("module".utf8))
        let review = try store.putObject(Data("review".utf8))
        let one = try store.putObject(codeArtifact([("0x10", "a\n")]))
        let two = try store.putObject(codeArtifact([("0x10", "b\n")]))
        let old = ReviewHistory(module: module, revisions: [
            ReviewRevision(project: "p", rev: 1, review: review, artifact: one, recordedAt: "t"),
            ReviewRevision(project: "p", rev: 2, review: review, artifact: two, recordedAt: "t"),
            ReviewRevision(project: "p", rev: 3, review: review, recordedAt: "t")
        ])
        let url = store.reviewHistoryURL(module)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"changed_functions\":null,", with: "")
        try Data(text.utf8).write(to: url)
        XCTAssertNil(try store.reviewHistory(module: module)?.revisions[0].changedFunctions, "an older history reads")

        var mirror = store
        mirror.objectSource = { _ in Data() }
        XCTAssertFalse(try mirror.backfillChangedFunctions(module: module))

        XCTAssertEqual(store.backfillChangedFunctions(), 1)
        let revisions = try XCTUnwrap(store.reviewHistory(module: module)?.revisions)
        XCTAssertEqual(revisions[0].changedFunctions, ["0x10"])
        XCTAssertEqual(revisions[1].changedFunctions, ["0x10"])
        XCTAssertNil(revisions[2].changedFunctions, "no code, nothing to say")
        XCTAssertEqual(store.backfillChangedFunctions(), 0, "once")
    }

    /// Only a mirror lacking the object has anything to fetch.
    func testAStoreMustFetchOnlyWhatAMirrorLacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try ContentStore(root: root)
        let held = try store.putObject(Data("held".utf8))
        let absent = SHA256Digest(data: Data("absent".utf8))
        XCTAssertFalse(store.mustFetch(absent), "a store of its own has nowhere to fetch from")
        store.objectSource = { _ in Data() }
        XCTAssertTrue(store.mustFetch(absent))
        XCTAssertFalse(store.mustFetch(held))
    }

    func testAMirrorMustFetchOnlyThePartsOfWhatIsRead() throws {
        func function(_ entry: Int) -> [String: Any] {
            let name = "F\(entry)", address = "0x\(String(entry, radix: 16))"
            return ["entry": address, "name": name, "signature": "void \(name)(void)", "size": 1,
                    "c": "void \(name)(void) { /* \(String(repeating: name, count: 40)) */ }",
                    "instructions": [["address": address, "bytes": "C3", "mnemonic": "RET", "text": "RET"]]]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try ContentStore(root: folder.appendingPathComponent("server"))
        let artifact = try JSONSerialization.data(withJSONObject: [
            "script_version": 9, "program": ["image_base": "0x0"],
            "functions": [function(0x1000), function(0x2000)]
        ], options: [.sortedKeys])
        let digest = try server.putObject(artifact)
        let parts = server.parts(of: digest)
        XCTAssertEqual(try server.objectRoot(digest).flatMap { PartedObject.functions(ofRoot: $0) }?.count, 2,
                       "the artifact is cut, or this tests nothing")

        var mirror = try ContentStore(root: folder.appendingPathComponent("mirror"))
        mirror.partSource = ContentStore.PartSource(root: { try server.objectRoot($0) },
                                                    files: { names in
            try Dictionary(uniqueKeysWithValues: names.map { ($0, try server.gzippedObject($0)) })
        })
        let first = try XCTUnwrap(CodeAddress(hex: "0x1000"))
        XCTAssertTrue(mirror.mustFetch(digest, function: first), "the root is not here")
        try mirror.fetch(digest, function: first)
        XCTAssertFalse(mirror.mustFetch(digest, function: first), "all that function takes is here")
        XCTAssertTrue(mirror.mustFetch(digest, function: CodeAddress(hex: "0x2000")), "the other's part is not")
        XCTAssertTrue(mirror.mustFetch(digest), "nor is the whole here")
        XCTAssertLessThan(parts.filter(mirror.hasObject).count, parts.count)
        try mirror.fetch(digest)
        XCTAssertFalse(mirror.mustFetch(digest))
    }
}

