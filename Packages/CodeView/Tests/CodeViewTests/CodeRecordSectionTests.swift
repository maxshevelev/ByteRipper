import AnalysisProfiles
import CodeAnalysis
@testable import CodeView
import XCTest

/// The record's words and order without a window: what the section's list
/// shows comes from these rules.
final class CodeRecordSectionTests: XCTestCase {
    private let profile = AnalysisProfile.ecIteNds32
    private func section(_ id: String) -> CodeRecordSection {
        CodeRecordSection(profile: profile, record: profile.records.first { $0.id == id })
    }

    func testRowsStandInKeyOrderAndReadByTheirKey() {
        let irq = section("irq_map")
        let rows: [[String: RecordValue]] = [["irq": .int(24), "label": .string("Timer")],
                                             ["irq": .int(3), "label": .string("Keyboard")]]
        let ordered = rows.sorted(by: irq.keyOrder)
        XCTAssertEqual(ordered.map(irq.keyDisplay), ["IRQ 3", "IRQ 24"], "a number as a number")
        XCTAssertEqual(irq.line(ordered[0]), "IRQ 3  Keyboard")
    }

    func testAFilterMatchesTheKeyOrTheLabel() {
        let irq = section("irq_map")
        let rows: [[String: RecordValue]] = [["irq": .int(24), "label": .string("Timer")],
                                             ["irq": .int(3), "label": .string("Keyboard")]]
        XCTAssertEqual(irq.filtered(rows, by: " keyb ").count, 1)
        XCTAssertEqual(irq.filtered(rows, by: "IRQ 24").first?["label"], .string("Timer"))
        XCTAssertEqual(irq.filtered(rows, by: "").count, 2, "no query: every row")
    }

    func testAGroupedRecordHasABranchPerValue() throws {
        let commands = section("host_commands")
        let groupBy = try XCTUnwrap(commands.record?.groupBy)
        let column = try XCTUnwrap(commands.record?.column(groupBy))
        let value = try XCTUnwrap(column.values?.first)
        let rows: [[String: RecordValue]] = [[groupBy: .string(value), "cmd": .int(0x80)]]
        let groups = CodeRecordSection.groups(of: rows, by: column, keepEmpty: false, notes: [:])
        XCTAssertEqual(groups.map(\.value), [value], "a filter on: only branches with rows")
        XCTAssertEqual(groups.first?.rows.count, 1)
        let all = CodeRecordSection.groups(of: rows, by: column, keepEmpty: true, notes: [:])
        XCTAssertGreaterThanOrEqual(all.count, groups.count)
    }
}
