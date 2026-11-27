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
        XCTAssertEqual(AnalysisProfile.derive(kind: "EC", ecFamily: "ite-nds32")?.stamp, "ec-ite-nds32@3")
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
        XCTAssertEqual(catalogue.map(\.stamp), ["uefi@1", "ec-ite-nds32@3"])
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
        XCTAssertEqual(uefi.inapplicableTools.map(\.tool), ["register_registry"],
                       "uefi keeps every tool it had; only the EC register registry does not apply")
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

    /// A record's header and grouping and a column's value summaries encode
    /// snake_case, only where set, and JSON written before them still reads.
    func testHeaderGroupingAndValueSummariesAreAnAddition() throws {
        let host = try XCTUnwrap(AnalysisProfile.ecIteNds32.records.first { $0.id == "host_commands" })
        XCTAssertEqual(host.groupBy, "ports")
        XCTAssertFalse(host.header?.isEmpty ?? true)
        XCTAssertEqual(host.column("ports")?.valueSummaries?.keys.sorted(), ["60/64", "62/66", "68/6C"])
        XCTAssertEqual(AnalysisProfile.ecIteNds32.records.first { $0.id == "smbus_peers" }?.groupBy, "channel")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        XCTAssertEqual(object["group_by"] as? String, "ports")
        XCTAssertNotNil(object["header"] as? String)
        let ports = try XCTUnwrap((object["columns"] as? [[String: Any]])?.first { $0["id"] as? String == "ports" })
        XCTAssertEqual((ports["value_summaries"] as? [String: String])?.count, 3)
        let mode = try XCTUnwrap((object["columns"] as? [[String: Any]])?.first { $0["id"] as? String == "mode" })
        XCTAssertNil(mode["value_summaries"], "omitted when there are none")
        XCTAssertEqual(try JSONDecoder().decode(AnalysisProfile.Record.self, from: JSONEncoder().encode(host)), host)

        let irq = try XCTUnwrap(AnalysisProfile.ecIteNds32.records.first { $0.id == "irq_map" })
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(irq)) as? [String: Any])
        XCTAssertNil(plain["header"])
        let ram = try XCTUnwrap(AnalysisProfile.ecIteNds32.records.first { $0.id == "ec_ram" })
        let flat = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ram)) as? [String: Any])
        XCTAssertNil(flat["group_by"])

        let old = #"{"id":"r","title":"R","summary":"s","unanswered_gate":true,"key":["a"],"#
            + #""columns":[{"id":"a","title":"A","kind":"enum","required":true,"values":["x"],"summary":"a"}]}"#
        let read = try JSONDecoder().decode(AnalysisProfile.Record.self, from: Data(old.utf8))
        XCTAssertNil(read.header)
        XCTAssertNil(read.groupBy)
        XCTAssertNil(read.columns.first?.valueSummaries)
        XCTAssertNil(read.columns.first?.valueTitles)
    }

    /// Every EC record takes a short `label` for the panel's list; GPIO a
    /// `group`; the records the panel groups name their branches.
    func testLabelsGroupsAndBranchTitles() throws {
        func record(_ id: String) throws -> AnalysisProfile.Record {
            try XCTUnwrap(AnalysisProfile.ecIteNds32.records.first { $0.id == id })
        }
        for record in AnalysisProfile.ecIteNds32.records {
            let label = try XCTUnwrap(record.column("label"), record.id)
            XCTAssertEqual(label.kind, .text)
            XCTAssertFalse(label.required)
            XCTAssertFalse(record.key.contains("label"))
        }
        XCTAssertEqual(try record("gpio").column("group")?.values,
                       ["power", "chipset", "input", "indicator", "usb", "other"])
        XCTAssertEqual(try record("gpio").groupBy, "group")
        XCTAssertEqual(try record("irq_map").groupBy, "enabled_by_firmware")
        XCTAssertEqual(try record("irq_map").column("enabled_by_firmware")?.valueTitles,
                       ["true": "Enabled", "false": "Not enabled"])
        XCTAssertNil(try record("ec_ram").groupBy)
        XCTAssertNil(try record("eflash_area").groupBy)
        let host = try record("host_commands")
        XCTAssertEqual(host.column("ports")?.valueTitles, ["60/64": "Keyboard controller", "62/66": "ACPI EC",
                                                          "68/6C": "OEM channel"])
        XCTAssertFalse(host.header?.contains("PMC") ?? true, "the port pairs' words are their own")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        let ports = try XCTUnwrap((object["columns"] as? [[String: Any]])?.first { $0["id"] as? String == "ports" })
        XCTAssertEqual((ports["value_titles"] as? [String: String])?.count, 3)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisProfile.Record.self, from: JSONEncoder().encode(host)), host)
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

    // MARK: - Record tables

    /// Every EC record has a table: its key columns exist, a ref names a
    /// record of the profile, a computed column says how, and nothing is
    /// declared twice.
    func testTheECRecordsHaveTables() throws {
        let ec = AnalysisProfile.ecIteNds32
        XCTAssertEqual(ec.version, 3)
        let ids = Set(ec.records.map(\.id))
        for record in ec.records {
            XCTAssertFalse(record.columns.isEmpty, record.id)
            XCTAssertFalse(record.key.isEmpty, record.id)
            XCTAssertEqual(Set(record.columns.map(\.id)).count, record.columns.count, record.id)
            for key in record.key {
                let column = try XCTUnwrap(record.column(key), "\(record.id).\(key)")
                XCTAssertNotEqual(column.kind, .computed, "\(record.id).\(key)")
            }
            for column in record.columns {
                XCTAssertFalse(["status", "note", "confidence"].contains(column.id), "common fields are not declared")
                if column.kind == .ref || column.of == .ref {
                    XCTAssertTrue(ids.contains(column.ref ?? ""), "\(record.id).\(column.id) -> \(column.ref ?? "nil")")
                }
                if column.kind == .list { XCTAssertNotNil(column.of, "\(record.id).\(column.id)") }
                if column.kind == .enum { XCTAssertFalse(column.values?.isEmpty ?? true, "\(record.id).\(column.id)") }
                if column.kind == .computed {
                    XCTAssertNotNil(column.compute)
                    XCTAssertFalse(column.required)
                }
                if column.kind == .rows { XCTAssertFalse(column.columns?.isEmpty ?? true) }
                if let pattern = column.pattern { XCTAssertNoThrow(try NSRegularExpression(pattern: pattern)) }
            }
        }
        let ram = try XCTUnwrap(ec.records.first { $0.id == "ec_ram" })
        XCTAssertEqual(ram.parameters["ec_ram_base"], "0x80400")
        XCTAssertEqual(ram.column("address")?.compute, "ec_ram_address")
        XCTAssertEqual(ec.records.first { $0.id == "host_commands" }?.key, ["ports", "cmd", "sub", "mode"])
        XCTAssertEqual(ec.records.first { $0.id == "host_commands" }?.column("ec_ram")?.ref, "ec_ram")
        XCTAssertEqual(ec.records.first { $0.id == "eflash_area" }?.column("host_commands")?.ref, "host_commands")
        XCTAssertEqual(ec.records.first { $0.id == "smbus_peers" }?.column("address_8bit")?.compute, "smbus_address_8bit")
        XCTAssertFalse(ec.inapplicableTools.contains { $0.hint.contains("###") }, "records are no longer subsections")
        // UEFI's records have no table.
        XCTAssertTrue(AnalysisProfile.uefi.records.allSatisfy { $0.columns.isEmpty && $0.key.isEmpty })
    }

    /// The columns encode in snake case and round-trip; a record without a
    /// table encodes no table keys.
    func testColumnsEncodeAndDecode() throws {
        let data = try JSONEncoder().encode(AnalysisProfile.ecIteNds32)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let smbus = try XCTUnwrap(records.first { $0["id"] as? String == "smbus_peers" })
        XCTAssertEqual(smbus["key"] as? [String], ["channel", "address"])
        let address = try XCTUnwrap((smbus["columns"] as? [[String: Any]])?.first { $0["id"] as? String == "address" })
        XCTAssertEqual(address["note_for"] as? [String], ["runtime", "mailbox"])
        XCTAssertEqual(address["kind"] as? String, "int")
        XCTAssertEqual(address["max"] as? Int, 0x7F)
        let commands = try XCTUnwrap((smbus["columns"] as? [[String: Any]])?.first { $0["id"] as? String == "commands" })
        XCTAssertEqual(commands["optional_when"] as? [String: [String]], ["address": ["runtime", "mailbox"]])
        XCTAssertEqual(try JSONDecoder().decode(AnalysisProfile.self, from: data), .ecIteNds32)
        let uefi = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AnalysisProfile.uefi))
                                 as? [String: Any])
        for record in try XCTUnwrap(uefi["records"] as? [[String: Any]]) {
            XCTAssertNil(record["columns"])
            XCTAssertNil(record["key"])
            XCTAssertNil(record["parameters"])
        }
    }

    /// A record written before tables — no key, columns or parameters — reads.
    func testARecordWithoutColumnsDecodes() throws {
        let old = #"{"id":"gpio","title":"GPIO","summary":"Pins.","unanswered_gate":true}"#
        let record = try JSONDecoder().decode(AnalysisProfile.Record.self, from: Data(old.utf8))
        XCTAssertEqual(record.id, "gpio")
        XCTAssertTrue(record.columns.isEmpty)
        XCTAssertTrue(record.key.isEmpty)
        XCTAssertTrue(record.parameters.isEmpty)
    }

    private let BuiltInSectionsAll = AnalysisProfile.BuiltInSection.allCases
}
