import AnalysisProfiles
import XCTest
@testable import CodeAnalysis

/// A review's records read from its document, the gate they meet, the
/// review's progress by them, and two revisions compared row by row.
final class ModuleRecordsTests: XCTestCase {
    private let digest = SHA256Digest(data: Data("described".utf8))

    private func document(_ records: [String: Any]?) throws -> Data {
        var object: [String: Any] = ["functions": [:]]
        if let records { object["records"] = records }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private let irqs: [String: Any] = [
        "status": "complete", "note": "all other IRQs: empty stub",
        "rows": [["irq": 4, "handler": "0x1200", "source": "timer", "confidence": "established"],
                 ["irq": 9, "handler": "0x1300", "source": "KBC", "confidence": "inference", "note": "by name"]]
    ]

    func testTheRecordsAreReadFromTheDocument() throws {
        let records = ModuleRecords.of(reviewDocument: try document([
            "irq_map": irqs, "gpio": ["status": "none", "note": "no GPIO touched", "rows": []],
            "ec_ram": ["status": "maybe"]]))
        XCTAssertEqual(records["irq_map"]?.status, .complete)
        XCTAssertEqual(records["irq_map"]?.note, "all other IRQs: empty stub")
        XCTAssertEqual(records["irq_map"]?.rows.count, 2)
        XCTAssertEqual(records["irq_map"]?.rows[0]["irq"], .int(4))
        XCTAssertEqual(records["irq_map"]?.rows[1]["confidence"], .string("inference"))
        XCTAssertNil(records["ec_ram"], "a status the app does not know is left out")
        XCTAssertEqual(records.statuses, ["irq_map": "complete", "gpio": "none"])
        XCTAssertTrue(ModuleRecords.of(reviewDocument: try document(nil)).records.isEmpty)
        XCTAssertNil(ModuleRecords.of(reviewDocument: try document(nil)).statuses)
    }

    func testCompleteAndNoneAnswerPartialDoesNot() throws {
        let records = ModuleRecords.of(reviewDocument: try document([
            "irq_map": irqs, "gpio": ["status": "none", "note": "x", "rows": []],
            "ec_ram": ["status": "partial", "note": "half", "rows": []]]))
        XCTAssertTrue(records.answered("irq_map"))
        XCTAssertTrue(records.answered("gpio"))
        XCTAssertFalse(records.answered("ec_ram"))
        XCTAssertFalse(records.answered("smbus_peers"))
        XCTAssertEqual(records.unanswered(profile: .ecIteNds32), ["host_commands", "ec_ram", "smbus_peers", "eflash_area"])
        let gate = try XCTUnwrap(RecordsGate.of(profile: .ecIteNds32, statuses: records.statuses ?? [:]))
        XCTAssertFalse(gate.passed)
        XCTAssertEqual(gate.partial, ["ec_ram"])
        XCTAssertEqual(gate.unanswered, ["host_commands", "smbus_peers", "eflash_area"])
        XCTAssertNil(RecordsGate.of(profile: .uefi, statuses: [:]), "UEFI has no records gate")
    }

    func testRevisionsAreComparedByTheRecordsKey() throws {
        let old = ModuleRecords.of(reviewDocument: try document(["irq_map": irqs]))
        var changed = irqs
        changed["status"] = "partial"
        changed["rows"] = [["irq": 4, "handler": "0x1200", "source": "timer 0", "confidence": "established"],
                           ["irq": 12, "handler": "0x1400", "source": "PS/2", "confidence": "established"]]
        let new = ModuleRecords.of(reviewDocument: try document([
            "irq_map": changed, "gpio": ["status": "none", "note": "x", "rows": []]]))
        let diff = ModuleRecords.diff(old, new, profile: .ecIteNds32)
        XCTAssertEqual(diff["irq_map"], ModuleRecords.RowChanges(added: ["irq 12"], changed: ["irq 4"],
                                                                 removed: ["irq 9"], statusChanged: true))
        XCTAssertEqual(diff["gpio"], ModuleRecords.RowChanges(statusChanged: true))
        XCTAssertTrue(ModuleRecords.diff(new, new, profile: .ecIteNds32).isEmpty)
        XCTAssertEqual(ModuleRecords.rowKey(["ports": .string("62/66"), "cmd": .string("0x80"), "mode": .string("normal")],
                                            key: ["ports", "cmd", "sub", "mode"]),
                       "ports 62/66, cmd 0x80, mode normal")
    }

    // MARK: - Progress

    private func manifest(levels: [String: Int], reading: AnalysisReading) -> AnalysisManifest {
        let bytes = Data("module".utf8)
        return AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count, name: "module", kind: "EC"),
            recipe: AnalysisRecipe(id: "code-v7-ghidra-12.1.2", exporter: 7, ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(sha256: SHA256Digest(data: bytes), size: 1, mediaType: "application/json"),
            analyzedAt: "2026-11-27T00:00:00Z", stats: AnalysisStats(reviewLevels: levels), reading: reading)
    }

    /// An EC review needs no interfaces, and every gated record complete or none.
    func testAnECReviewIsCompleteOnlyWithEveryRecordAnswered() {
        let all = Dictionary(uniqueKeysWithValues: AnalysisProfile.ecIteNds32.records.map { ($0.id, "complete") })
        func progress(_ records: [String: String]?) -> ReviewProgress {
            manifest(levels: ["full": 3], reading: AnalysisReading(rev: 2, description: digest,
                                                                   profile: "ec-ite-nds32@2", records: records))
                .reviewProgress
        }
        XCTAssertEqual(progress(all), .complete)
        var none = all
        none["gpio"] = "none"
        XCTAssertEqual(progress(none), .complete, "none with the reason answers")
        var partial = all
        partial["gpio"] = "partial"
        XCTAssertEqual(progress(partial), .partial, "partial does not count")
        var missing = all
        missing["gpio"] = nil
        XCTAssertEqual(progress(missing), .partial)
        XCTAssertEqual(progress(nil), .partial)
        XCTAssertEqual(manifest(levels: ["decompiled": 3], reading: AnalysisReading(rev: 1, profile: "ec-ite-nds32@2",
                                                                                   records: ["gpio": "partial"]))
                       .reviewProgress, .partial, "a record is the review's own")
    }

    /// A reading of an older profile version is judged by the current one.
    func testAnOlderProfileStampReadsAsTheCurrentProfile() {
        XCTAssertEqual(AnalysisReading(rev: 1, profile: "ec-ite-nds32@1").analysisProfile?.id, "ec-ite-nds32")
        XCTAssertEqual(AnalysisReading(rev: 1).analysisProfile?.id, "uefi")
    }

    func testTheStatusesRoundTripAndAreLeftOutWhenNone() throws {
        let plain = try JSONEncoder().encode(AnalysisReading(rev: 2, review: digest))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("records"))
        let set = AnalysisReading(rev: 2, review: digest, profile: "ec-ite-nds32@2", records: ["gpio": "none"])
        XCTAssertEqual(try JSONDecoder().decode(AnalysisReading.self, from: try JSONEncoder().encode(set)), set)
    }
}
