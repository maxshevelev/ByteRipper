import XCTest
@testable import CodeAnalysis

/// How far a module's review has got, read from its manifest alone: the UEFI
/// tree's badge beside the module's name.
final class ReviewProgressTests: XCTestCase {
    private let digest = SHA256Digest(data: Data("described".utf8))

    private func manifest(levels: [String: Int]?, reading: AnalysisReading?) -> AnalysisManifest {
        let bytes = Data("module".utf8)
        return AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count, name: "module"),
            recipe: AnalysisRecipe(id: "code-v7-ghidra-12.1.2", exporter: 7, ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(sha256: SHA256Digest(data: bytes), size: 1, mediaType: "application/json"),
            analyzedAt: "2026-11-11T00:00:00Z", stats: AnalysisStats(reviewLevels: levels), reading: reading)
    }

    func testGhidrasAnalysisAloneIsMechanical() {
        XCTAssertEqual(manifest(levels: ["decompiled": 12], reading: nil).reviewProgress, .mechanical)
        XCTAssertEqual(manifest(levels: nil, reading: nil).reviewProgress, .mechanical)
    }

    func testEveryFunctionDoneAndADescriptionIsComplete() {
        let done = ["full": 10, "library": 4, "no_body": 1, "partial": 0]
        XCTAssertEqual(manifest(levels: done, reading: AnalysisReading(rev: 3, description: digest)).reviewProgress,
                       .complete)
    }

    func testAFunctionShortOfTheBarIsPartial() {
        let levels = ["full": 10, "partial": 1]
        XCTAssertEqual(manifest(levels: levels, reading: AnalysisReading(rev: 3, description: digest)).reviewProgress,
                       .partial)
    }

    func testNoDescriptionIsPartial() {
        XCTAssertEqual(manifest(levels: ["full": 10], reading: AnalysisReading(rev: 3)).reviewProgress, .partial)
    }

    /// A manifest written before the levels were counted: a review exists,
    /// how far it got is unknown, so it is not called complete.
    func testLevelsNotCountedArePartial() {
        XCTAssertEqual(manifest(levels: nil, reading: AnalysisReading(rev: 3, description: digest)).reviewProgress,
                       .partial)
    }

    /// The origin rides in the review document and reaches the reading; a
    /// document without one, or with a word the app does not know, gives none.
    func testTheOriginIsReadFromTheReviewDocument() throws {
        func document(_ origin: Any?) throws -> Data {
            var object: [String: Any] = ["functions": [:], "schema": 1]
            if let origin { object["origin"] = origin }
            return try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(ModuleOrigin.of(reviewDocument: try document(["category": "vendor", "confidence": "inferred",
                                                                    "vendor": "Insyde"])),
                       ModuleOrigin(category: .vendor, confidence: .inferred, vendor: "Insyde"))
        XCTAssertEqual(ModuleOrigin.of(reviewDocument: try document(["category": "edk2_modified",
                                                                    "confidence": "established"])),
                       ModuleOrigin(category: .edk2Modified, confidence: .established))
        XCTAssertNil(ModuleOrigin.of(reviewDocument: try document(nil)))
        XCTAssertNil(ModuleOrigin.of(reviewDocument: try document(["category": "phoenix", "confidence": "inferred"])))
    }

    /// `unknown` carries no confidence; it is read as the review set it.
    func testAnUnknownOriginNeedsNoConfidence() throws {
        let data = try JSONSerialization.data(withJSONObject: ["origin": ["category": "unknown"]])
        XCTAssertEqual(ModuleOrigin.of(reviewDocument: data)?.category, .unknown)
    }

    /// A reading without an origin is written as before: no `origin` key.
    func testAReadingWithoutAnOriginWritesNoKey() throws {
        let plain = try JSONEncoder().encode(AnalysisReading(rev: 2, review: digest))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("origin"))
        let placed = AnalysisReading(rev: 2, review: digest,
                                     origin: ModuleOrigin(category: .amd, confidence: .established))
        let encoded = try JSONEncoder().encode(placed)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisReading.self, from: encoded), placed)
    }

    func testTheArtifactsLevelsAreCountedWithALinkAsLibrary() throws {
        let artifact = try JSONSerialization.data(withJSONObject: ["functions": [
            ["entry": "0x10", "review_level": "full"],
            ["entry": "0x20", "review_level": "full"],
            ["entry": "0x30", "review_level": "partial"],
            ["entry": "0x40", "registry": ["id": "x", "version": 1]],
            ["entry": "0x50"],
        ]])
        XCTAssertEqual(ArtifactStats.count(in: artifact).reviewLevels, ["full": 2, "partial": 1, "library": 1])
    }

    /// An artifact with no levels at all leaves the field out.
    func testAnArtifactWithoutLevelsLeavesTheFieldOut() throws {
        let artifact = try JSONSerialization.data(withJSONObject: ["functions": [["entry": "0x10"]]])
        XCTAssertNil(ArtifactStats.count(in: artifact).reviewLevels)
        let encoded = try JSONEncoder().encode(ArtifactStats.count(in: artifact))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("review_levels"))
    }

    func testAnOlderManifestReadsWithoutTheField() throws {
        let old = #"{"functions":3,"instructions":10,"strings":0,"post_code_writes":0,"status_code_candidates":0}"#
        let stats = try JSONDecoder().decode(AnalysisStats.self, from: Data(old.utf8))
        XCTAssertNil(stats.reviewLevels)
        XCTAssertEqual(stats.functions, 3)
    }

    /// A store written before the levels were counted gets them once, from
    /// each artifact; nothing else in the manifest moves.
    func testAnOldStoreIsRecountedOnceAndOnlyTheCountsMove() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewProgressTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let recipe = AnalysisRecipe(id: "code-v7-ghidra-12.1.2", exporter: 7, ghidra: "12.1.2", script: "ExportCode.java")
        func module(_ name: String) -> ModuleIdentity {
            ModuleIdentity(sha256: SHA256Digest(data: Data(name.utf8)), size: name.utf8.count, name: name)
        }
        let reviewed = try JSONSerialization.data(withJSONObject: ["functions": [
            ["entry": "0x10", "name": "Reads", "c": "void Reads(void) {}", "review_level": "full"],
            ["entry": "0x20", "review_level": "no_body"]]])
        let plain = try JSONSerialization.data(withJSONObject: ["functions": [["entry": "0x10"]]])
        let old = try store.putAnalysis(module: module("Reviewed"), recipe: recipe, artifact: reviewed,
                                        reading: AnalysisReading(rev: 2, description: digest))
        _ = try store.putAnalysis(module: module("Plain"), recipe: recipe, artifact: plain)
        // As an earlier build wrote it: no review_levels.
        var written = old
        written.stats.reviewLevels = nil
        let url = store.manifestURL(try XCTUnwrap(old.key))
        try JSONEncoder().encode(written).write(to: url)
        XCTAssertEqual(try store.analysis(module: old.module.sha256)?.reviewProgress, .partial)

        let preview = try store.recountStats(dryRun: true)
        XCTAssertEqual(preview.map(\.name), ["Reviewed"], "the plain one has no levels to count")
        XCTAssertNil(try store.analysis(module: old.module.sha256)?.stats.reviewLevels, "a dry run writes nothing")

        XCTAssertEqual(try store.recountStats().map(\.reviewLevels), [["full": 1, "no_body": 1]])
        var now = try XCTUnwrap(try store.analysis(module: old.module.sha256))
        XCTAssertEqual(now.reviewProgress, .complete)
        now.stats.reviewLevels = nil
        XCTAssertEqual(now, written, "only the counts moved")
        XCTAssertEqual(try store.recountStats(), [], "once")
    }
}
