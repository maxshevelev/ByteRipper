import Foundation
import XCTest
@testable import CodeAnalysis

/// The analysis profiles: derived from a module's facts, a fixed catalogue,
/// and the stamp a revision records.
final class AnalysisProfileTests: XCTestCase {
    private func ec(_ family: String) -> ECModuleFacts {
        ECModuleFacts(family: family, extent: 0x2497C, extentSource: "crt0", sliceSize: 0x30000,
                      rawSHA256: String(repeating: "0", count: 64), masked: [], chipRead: false,
                      hostUpdateSize: nil, version: nil)
    }

    func testAPE32OrTEModuleIsUEFI() {
        XCTAssertEqual(AnalysisProfile.derive(kind: "PE32", ecFamily: nil), .uefi)
        XCTAssertEqual(AnalysisProfile.derive(kind: "TE", ecFamily: nil), .uefi)
        let identity = ModuleIdentity(sha256: SHA256Digest(data: Data("pe".utf8)), size: 2, name: "m",
                                      kind: "PE32", phase: "pei")
        XCTAssertEqual(AnalysisProfile.derive(for: identity)?.stamp, "uefi@1")
    }

    func testAnITEECModuleIsEcIteNds32() {
        let identity = ModuleIdentity(sha256: SHA256Digest(data: Data("ec".utf8)), size: 2, name: "m",
                                      kind: "EC", ec: ec("ite-nds32"))
        XCTAssertEqual(AnalysisProfile.derive(for: identity), .ecIteNds32)
        XCTAssertEqual(AnalysisProfile.derive(for: identity)?.stamp, "ec-ite-nds32@1")
    }

    /// An unknown kind is refused, never given UEFI's rules.
    func testAnUnknownKindOrFamilyHasNoProfile() {
        XCTAssertNil(AnalysisProfile.derive(kind: nil, ecFamily: nil))
        XCTAssertNil(AnalysisProfile.derive(kind: "ELF", ecFamily: nil))
        XCTAssertNil(AnalysisProfile.derive(kind: "EC", ecFamily: nil))
        XCTAssertNil(AnalysisProfile.derive(kind: "EC", ecFamily: "ene-8051"))
        // The EC family alone does not make a PE module an EC one.
        XCTAssertEqual(AnalysisProfile.derive(kind: "PE32", ecFamily: "ite-nds32"), .uefi)
    }

    func testTheCatalogue() {
        let catalogue = AnalysisProfile.catalogue
        XCTAssertEqual(catalogue.map(\.stamp), ["uefi@1", "ec-ite-nds32@1"])
        XCTAssertEqual(Set(catalogue.map(\.id)).count, catalogue.count)
        for profile in catalogue {
            XCTAssertEqual(Set(profile.records.map(\.id)).count, profile.records.count, profile.id)
            XCTAssertEqual(Set(profile.gates.map(\.id)).count, profile.gates.count, profile.id)
            XCTAssertFalse(profile.typeGroups.isEmpty)
            XCTAssertEqual(AnalysisProfile.named(profile.stamp), profile)
        }
        XCTAssertNil(AnalysisProfile.named("uefi@0"))

        let uefi = AnalysisProfile.uefi
        XCTAssertEqual(uefi.skill, "ghidra-uefi")
        XCTAssertEqual(uefi.records.map(\.id), ["interfaces", "post_codes"])
        XCTAssertEqual(uefi.libraryKinds, [.edk2, .amd, .intel])
        XCTAssertTrue(uefi.inapplicableTools.isEmpty, "uefi keeps every tool it has today")
        XCTAssertEqual(uefi.typeGroup(bits: 32), "Ia32")
        XCTAssertEqual(uefi.typeGroup(bits: 64), "X64")
        XCTAssertNil(uefi.typeGroup(bits: nil))

        let ec = AnalysisProfile.ecIteNds32
        XCTAssertEqual(ec.skill, "ghidra-ec")
        XCTAssertEqual(ec.records.map(\.id), ["irq_map", "host_commands", "ec_ram", "smbus_peers", "gpio", "eflash_area"])
        XCTAssertTrue(ec.records.allSatisfy(\.unansweredGate))
        XCTAssertEqual(ec.libraryKinds, [.toolchain, .ite])
        XCTAssertEqual(ec.typeGroup(bits: nil), "Nds32")
        XCTAssertEqual(ec.typeGroup(bits: 64), "Nds32")
        XCTAssertNotNil(ec.inapplicable("ghidra_set_interfaces"))
        XCTAssertNil(ec.inapplicable("ghidra_rename"))
        XCTAssertTrue(ec.references.contains("ghidra-ec/reference/it83xx-irqs.tsv"))
    }

    /// Every reference file a profile names is in the repo's skills.
    func testTheReferencesExist() {
        let skills = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Skills")
        for profile in AnalysisProfile.catalogue {
            XCTAssertTrue(FileManager.default.fileExists(atPath: skills.appendingPathComponent(profile.skill)
                .appendingPathComponent("SKILL.md").path), profile.skill)
            for reference in profile.references {
                XCTAssertTrue(FileManager.default.fileExists(atPath: skills.appendingPathComponent(reference).path),
                              reference)
            }
        }
    }

    func testTheProfileEncodesWithSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(AnalysisProfile.ecIteNds32)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["library_kinds"] as? [String], ["toolchain", "ite"])
        XCTAssertNotNil(object["inapplicable_tools"])
        XCTAssertEqual(object["type_groups"] as? [String], ["Nds32"])
        let record = try XCTUnwrap((object["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["unanswered_gate"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisProfile.self, from: data), .ecIteNds32)
    }

    // MARK: - The revision's stamp

    /// A history and a reading written before revisions recorded a profile
    /// read without one.
    func testAnOldRevisionReadsWithoutAProfile() throws {
        let review = SHA256Digest(data: Data("review".utf8)).hex
        let old = """
            {"schema":1,"module":"\(review)","revisions":[{"rev":1,"review":"\(review)",\
            "recorded_at":"2026-01-01T00:00:00Z","by":"agent"}]}
            """
        let history = try JSONDecoder().decode(ReviewHistory.self, from: Data(old.utf8))
        XCTAssertEqual(history.revisions.count, 1)
        XCTAssertNil(history.revisions[0].profile)
        let reading = try JSONDecoder().decode(AnalysisReading.self, from: Data(#"{"rev":2,"review":"\#(review)"}"#.utf8))
        XCTAssertNil(reading.profile)

        var stamped = history.revisions[0]
        stamped.profile = "uefi@1"
        let data = try JSONEncoder().encode(stamped)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""profile":"uefi@1""#))
        XCTAssertEqual(try JSONDecoder().decode(ReviewRevision.self, from: data).profile, "uefi@1")
    }

    /// The store records the profile the reading carries in the revision.
    func testARecordedRevisionKeepsTheReadingsProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = SHA256Digest(data: Data("module".utf8))
        let first = try store.putObject(Data(#"{"schema":1,"n":1}"#.utf8))
        let history = try store.recordRevision(module: module,
                                               reading: AnalysisReading(rev: 1, review: first, profile: "ec-ite-nds32@1"))
        XCTAssertEqual(history.revisions.last?.profile, "ec-ite-nds32@1")
        let second = try store.putObject(Data(#"{"schema":1,"n":2}"#.utf8))
        let next = try store.recordRevision(module: module, reading: AnalysisReading(rev: 2, review: second))
        // No analysis named rev 1, so the store numbers this one 1 again, and
        // it carries its own reading's profile: none.
        XCTAssertNil(next.revisions.last?.profile)
        XCTAssertEqual(try store.reviewHistory(module: module)?.revisions.last?.review, second)
    }
}
