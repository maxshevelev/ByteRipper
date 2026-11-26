import Foundation
import XCTest
@testable import AnalysisProfiles

/// The analysis profiles: the catalogue, deriving one from a module's kind,
/// the stamp, the Code panel's part, and the JSON `ghidra_profile` answers.
final class AnalysisProfileTests: XCTestCase {
    func testAPE32OrTEModuleIsUEFI() {
        XCTAssertEqual(AnalysisProfile.derive(kind: "PE32", ecFamily: nil), .uefi)
        XCTAssertEqual(AnalysisProfile.derive(kind: "TE", ecFamily: nil)?.stamp, "uefi@1")
    }

    func testAnITEECModuleIsEcIteNds32() {
        XCTAssertEqual(AnalysisProfile.derive(kind: "EC", ecFamily: "ite-nds32"), .ecIteNds32)
        XCTAssertEqual(AnalysisProfile.derive(kind: "EC", ecFamily: "ite-nds32")?.stamp, "ec-ite-nds32@1")
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
        XCTAssertEqual(uefi.libraryKinds, ["edk2", "amd", "intel"])
        XCTAssertTrue(uefi.inapplicableTools.isEmpty, "uefi keeps every tool it has today")
        XCTAssertEqual(uefi.typeGroup(bits: 32), "Ia32")
        XCTAssertEqual(uefi.typeGroup(bits: 64), "X64")
        XCTAssertNil(uefi.typeGroup(bits: nil))

        let ec = AnalysisProfile.ecIteNds32
        XCTAssertEqual(ec.skill, "ghidra-ec")
        XCTAssertEqual(ec.records.map(\.id), ["irq_map", "host_commands", "ec_ram", "smbus_peers", "gpio", "eflash_area"])
        XCTAssertTrue(ec.records.allSatisfy(\.unansweredGate))
        XCTAssertEqual(ec.libraryKinds, ["toolchain", "ite"])
        XCTAssertEqual(ec.typeGroup(bits: nil), "Nds32")
        XCTAssertEqual(ec.typeGroup(bits: 64), "Nds32")
        XCTAssertNotNil(ec.inapplicable("ghidra_set_interfaces"))
        XCTAssertNil(ec.inapplicable("ghidra_rename"))
        XCTAssertTrue(ec.references.contains("ghidra-ec/reference/it83xx-irqs.tsv"))
    }

    /// Every reference file a profile names is in the repo's skills. The
    /// repo is found by walking up from this file to the folder holding
    /// `Skills/` and `project.yml`, so moving the test does not break it.
    func testTheReferencesExist() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path)
                || !FileManager.default.fileExists(atPath: root.appendingPathComponent("Skills").path) {
            let up = root.deletingLastPathComponent()
            if up.path == root.path { return XCTFail("no repo root above \(#filePath)") }
            root = up
        }
        let skills = root.appendingPathComponent("Skills")
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

    // MARK: - ghidra_profile's JSON

    /// Without its panel fields a profile encodes byte for byte as
    /// `ghidra_profile` answered before they were added (captured from the
    /// code in CodeAnalysis before the move).
    func testTheEncodingMatchesTheGolden() throws {
        for profile in AnalysisProfile.catalogue {
            let url = try XCTUnwrap(Bundle.module.url(forResource: profile.id, withExtension: "json",
                                                      subdirectory: "Golden"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.userInfo[AnalysisProfile.omitsPanelKey] = true
            XCTAssertEqual(String(decoding: try encoder.encode(profile), as: UTF8.self),
                           String(decoding: try Data(contentsOf: url), as: UTF8.self), profile.id)
            // The golden, without a panel, still reads.
            var bare = profile
            bare.panel = nil
            for index in bare.records.indices { bare.records[index].panel = nil }
            XCTAssertEqual(try JSONDecoder().decode(AnalysisProfile.self, from: Data(contentsOf: url)), bare)
        }
    }

    /// The panel's fields are an addition under `panel` keys and round-trip.
    func testThePanelEncodesAsAnAddition() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnalysisProfile.ecIteNds32)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let panel = try XCTUnwrap(object["panel"] as? [String: Any])
        XCTAssertEqual((panel["built_in"] as? [[String: Any]])?.compactMap { $0["section"] as? String },
                       ["interfaces", "post_codes", "strings", "status_codes"])
        let record = try XCTUnwrap((object["records"] as? [[String: Any]])?.first?["panel"] as? [String: Any])
        XCTAssertEqual(record["symbol"] as? String, "bolt")
        XCTAssertEqual(record["order"] as? Int, 0)
        XCTAssertNil(record["replaces"])
        XCTAssertEqual(try JSONDecoder().decode(AnalysisProfile.self, from: data), .ecIteNds32)
    }

    // MARK: - The Code panel

    func testUEFIShowsItsBuiltInSections() {
        let uefi = AnalysisProfile.uefi
        XCTAssertTrue(BuiltInSectionsAll.allSatisfy(uefi.shows))
        XCTAssertEqual(uefi.records.first { $0.id == "interfaces" }?.panel?.replaces, .interfaces)
        XCTAssertEqual(uefi.records.first { $0.id == "post_codes" }?.panel?.replaces, .postCodes)
        XCTAssertTrue(uefi.addedPanelRecords.isEmpty, "uefi's records are the panel's own sections")
    }

    func testTheECHidesInterfacesAndPOSTCodesAndShowsItsRecords() {
        let ec = AnalysisProfile.ecIteNds32
        XCTAssertFalse(ec.shows(.interfaces))
        XCTAssertFalse(ec.shows(.postCodes))
        XCTAssertFalse(ec.shows(.strings))
        XCTAssertFalse(ec.shows(.statusCodes))
        for section in [AnalysisProfile.BuiltInSection.functions, .search] {
            XCTAssertTrue(ec.shows(section), section.rawValue)
        }
        XCTAssertEqual(ec.addedPanelRecords.map(\.id),
                       ["irq_map", "host_commands", "ec_ram", "smbus_peers", "gpio", "eflash_area"])
    }

    func testPanelOrdersAreDistinctPerProfile() {
        for profile in AnalysisProfile.catalogue {
            let orders = profile.records.compactMap(\.panel?.order)
            XCTAssertEqual(Set(orders).count, orders.count, profile.id)
            XCTAssertTrue(profile.records.allSatisfy { !($0.panel?.symbol.isEmpty ?? true) }, profile.id)
        }
    }

    private let BuiltInSectionsAll = AnalysisProfile.BuiltInSection.allCases
}
