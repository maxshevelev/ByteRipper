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
}
