import AnalysisProfiles
import AppKit
import CodeAnalysis
import XCTest
@testable import CodeView

/// A record section's table: columns from the profile, the status line in
/// its four states, address and ref cells that lead somewhere, the filter,
/// the inference mark and Copy Row.
@MainActor
final class CodeRecordSectionViewTests: XCTestCase {
    private func records(_ object: [String: Any]) throws -> ModuleRecords {
        ModuleRecords.of(reviewDocument: try JSONSerialization.data(withJSONObject: ["records": object]))
    }

    private func panel(_ object: [String: Any], show id: String) throws -> CodeRecordSectionView {
        let panel = CodeRecordSectionView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        panel.setRecords(try records(object), statuses: nil, profile: .ecIteNds32)
        panel.show(id: id, fallbackTitle: id, font: .systemFont(ofSize: 11))
        return panel
    }

    /// The outline's row whose `column` reads `text`.
    private func row(_ panel: CodeRecordSectionView, _ column: String, _ text: String) throws -> Int {
        try XCTUnwrap((0..<panel.table.numberOfRows).first { panel.cellText(row: $0, column: column) == text },
                      "\(column) = \(text)")
    }

    private let ram: [String: Any] = [
        "status": "partial", "note": "the battery block is not read yet",
        "rows": [
            ["offset": 0x10, "width": 1, "name": "STATE", "writer": "EC", "meaning": "power state",
             "accessed_by": ["0x1200", "0x1300"], "confidence": "established"],
            ["offset": 0x2A, "width": 2, "name": "FAN", "writer": "host", "meaning": "fan speed",
             "accessed_by": ["0x1400"], "confidence": "inference", "note": "named by its use"]
        ]
    ]

    func testTheColumnsAreTheProfilesAndComputedOnesAreFilledIn() throws {
        let panel = try self.panel(["ec_ram": ram], show: "ec_ram")
        XCTAssertEqual(panel.columnTitles, AnalysisProfile.ecIteNds32.records.first { $0.id == "ec_ram" }!
            .columns.map { CodeRecordSectionView.columnTitle($0.title) })
        XCTAssertEqual(panel.shownRows.count, 2)
        XCTAssertEqual(panel.cellText(row: 0, column: "offset"), "0x10")
        XCTAssertEqual(panel.cellText(row: 0, column: "address"), "0x80410", "ec_ram_base + offset")
        XCTAssertEqual(panel.cellText(row: 0, column: "accessed_by"), "0x1200, 0x1300")

        let smbus = try self.panel(["smbus_peers": [
            "status": "complete",
            "rows": [
                ["channel": "A", "address": 0x0B, "device": "battery", "confidence": "established",
                 "commands": [["cmd": 0x0D, "access": "R", "size": "word", "meaning": "charge"],
                              ["cmd": 0x16, "access": "R", "size": "word", "meaning": "status"]]],
                ["channel": "B", "address": "runtime", "device": "not identified", "confidence": "inference",
                 "note": "the address comes from the host", "commands": []]
            ]]], show: "smbus_peers")
        let battery = try row(smbus, "device", "battery"), other = try row(smbus, "device", "not identified")
        XCTAssertEqual(smbus.cellText(row: battery, column: "address_8bit"), "0x16", "7-bit × 2")
        XCTAssertEqual(smbus.cellText(row: other, column: "address"), "runtime")
        XCTAssertEqual(smbus.cellText(row: other, column: "address_8bit"), "", "no number to compute from")
        let commands = try XCTUnwrap(smbus.cell(row: battery, column: "commands"))
        XCTAssertEqual(commands.textField?.toolTip, "0x0D  R  word  charge\n0x16  R  word  status")
    }

    func testTheStatusLineHasFourStates() throws {
        let unanswered = try panel([:], show: "gpio")
        XCTAssertEqual(unanswered.shownStatus, CodeRecordSectionView.statusText(.unanswered, note: nil))
        XCTAssertEqual(unanswered.shownEmptyText, CodeRecordSectionView.emptyText)

        let partial = try panel(["ec_ram": ram], show: "ec_ram")
        XCTAssertEqual(partial.shownStatus, CodeRecordSectionView.statusText(.partial, note: nil))
        XCTAssertEqual(partial.shownNote, "the battery block is not read yet")

        let none = try panel(["gpio": ["status": "none", "note": "the firmware drives no GPIO", "rows": []]],
                             show: "gpio")
        XCTAssertEqual(none.shownStatus, CodeRecordSectionView.statusText(.none, note: "the firmware drives no GPIO"))
        XCTAssertTrue(none.shownStatus.contains("the firmware drives no GPIO"))
        XCTAssertEqual(none.shownEmptyText, "", "the reason is the status line")

        let complete = try panel(["irq_map": ["status": "complete", "note": "all other IRQs: empty stub", "rows": [
            ["irq": 4, "handler": "0x1200", "source": "timer", "source_status": "firmware",
             "enabled_by_firmware": true, "purpose": "ticks", "confidence": "established"]]]], show: "irq_map")
        XCTAssertEqual(complete.shownStatus, CodeRecordSectionView.statusText(.complete, note: nil))
        XCTAssertEqual(complete.shownNote, "all other IRQs: empty stub")

        // Before the document is read, the manifest's status stands for it.
        let early = CodeRecordSectionView(frame: .zero)
        early.setRecords(nil, statuses: ["gpio": "complete"], profile: .ecIteNds32)
        early.show(id: "gpio", fallbackTitle: "GPIO", font: .systemFont(ofSize: 11))
        XCTAssertEqual(early.shownStatus, CodeRecordSectionView.statusText(.complete, note: nil))
    }

    func testAnAddressCellOpensItsAddress() throws {
        let panel = try self.panel(["irq_map": ["status": "complete", "rows": [
            ["irq": 4, "handler": "0x1200", "body": "0x1240", "source": "timer", "source_status": "firmware",
             "enabled_by_firmware": true, "purpose": "ticks", "confidence": "established"]]]], show: "irq_map")
        var opened: [CodeAddress] = []
        panel.onOpenAddress = { opened.append($0) }
        panel.click(row: 0, column: "handler")
        panel.click(row: 0, column: "body")
        panel.click(row: 0, column: "purpose")
        XCTAssertEqual(opened, [CodeAddress(0x1200), CodeAddress(0x1240)])
        XCTAssertEqual(panel.cell(row: 0, column: "handler")?.textField?.textColor, .linkColor)
        XCTAssertEqual(panel.cell(row: 0, column: "purpose")?.textField?.textColor, .labelColor)
    }

    func testARefCellShowsTheRecordItNamesWithTheRowSelected() throws {
        let panel = try self.panel([
            "ec_ram": ram,
            "host_commands": ["status": "complete", "rows": [
                ["ports": "62/66", "mode": "normal", "cmd": 0x80, "handler": "0x1500", "effect": "read EC RAM",
                 "ec_ram": [0x2A], "confidence": "established"]]]
        ], show: "host_commands")
        let command = try row(panel, "cmd", "0x80")
        XCTAssertEqual(panel.cellText(row: command, column: "ec_ram"), "0x2A")
        var asked: [String] = []
        panel.onShowRecord = { id in
            asked.append(id)
            panel.show(id: id, fallbackTitle: id, font: .systemFont(ofSize: 11))
        }
        panel.click(row: command, column: "ec_ram")
        XCTAssertEqual(asked, ["ec_ram"])
        XCTAssertEqual(panel.recordID, "ec_ram")
        XCTAssertEqual(panel.table.selectedRow, 1)
    }

    func testTheFilterNarrowsTheRowsAndSortingOrdersThem() throws {
        let panel = try self.panel(["ec_ram": ram], show: "ec_ram")
        panel.setFilter("fan")
        XCTAssertEqual(panel.shownRows.count, 1)
        XCTAssertEqual(panel.cellText(row: 0, column: "name"), "FAN")
        panel.setFilter("nothing like it")
        XCTAssertEqual(panel.shownRows.count, 0)
        XCTAssertFalse(panel.shownEmptyText.isEmpty)
        panel.setFilter("")
        XCTAssertEqual(panel.shownRows.count, 2)
        panel.table.sortDescriptors = [NSSortDescriptor(key: "offset", ascending: false)]
        XCTAssertEqual(panel.cellText(row: 0, column: "name"), "FAN")
        XCTAssertEqual(panel.tsv(rows: IndexSet(integer: 1)).split(separator: "\t").first, "0x10")
    }

    func testAnInferredRowIsMarked() throws {
        let panel = try self.panel(["ec_ram": ram], show: "ec_ram")
        let inferred = try XCTUnwrap(panel.cell(row: 1, column: "offset"))
        let mark = try XCTUnwrap(inferred.viewWithTag(6_001) as? NSImageView)
        XCTAssertFalse(mark.isHidden)
        XCTAssertEqual(mark.toolTip, CodeRecordSectionView.inferenceToolTip(note: "named by its use"))
        XCTAssertTrue(inferred.textField?.font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertEqual(panel.cell(row: 1, column: "name")?.textField?.toolTip, "named by its use")

        let established = try XCTUnwrap(panel.cell(row: 0, column: "offset"))
        XCTAssertTrue((established.viewWithTag(6_001) as? NSImageView)?.isHidden ?? true)
        XCTAssertFalse(established.textField?.font?.fontDescriptor.symbolicTraits.contains(.italic) ?? true)
    }

    // MARK: - A grouped record

    private let commands: [String: Any] = [
        "status": "partial",
        "rows": [
            ["ports": "68/6C", "mode": "flash", "cmd": 0x10, "handler": "0x1700", "effect": "enter flash",
             "confidence": "established"],
            ["ports": "62/66", "mode": "normal", "cmd": 0x81, "handler": "0x1600", "effect": "write EC RAM",
             "confidence": "established"],
            ["ports": "62/66", "mode": "normal", "cmd": 0x80, "handler": "0x1500", "effect": "read EC RAM",
             "ec_ram": [0x2A], "confidence": "inference", "note": "from the ACPI spec"],
            ["ports": "68/6C", "mode": "normal", "cmd": 0x10, "handler": "0x1800", "effect": "set mode",
             "confidence": "established"]
        ]
    ]

    func testHostCommandsCarryTheirHeaderAndAreGroupedByPortPair() throws {
        let panel = try self.panel(["host_commands": commands, "ec_ram": ram], show: "host_commands")
        XCTAssertEqual(panel.shownHeader, CodeRecordSectionView.header(AnalysisProfile.hostCommandsHeader))
        XCTAssertFalse(panel.shownHeader.isEmpty)
        let ports = try XCTUnwrap(AnalysisProfile.ecIteNds32.records.first { $0.id == "host_commands" }?.column("ports"))
        XCTAssertEqual(panel.shownGroups.map(\.value), ["60/64", "62/66", "68/6C"],
                       "every port pair, the one with no commands too")
        XCTAssertEqual(panel.shownGroups.map(\.rows), [0, 2, 2])
        XCTAssertEqual(panel.shownGroups.map(\.summary),
                       ["60/64", "62/66", "68/6C"].map { ports.valueSummaries?[$0].map(CodeRecordSectionView.valueSummary) })
        // A branch, then its rows in key order: the command, normal before flash.
        XCTAssertEqual((0..<panel.table.numberOfRows).map { panel.cellText(row: $0, column: "effect") },
                       ["", "", "read EC RAM", "write EC RAM", "", "set mode", "enter flash"])
        XCTAssertEqual(panel.shownRows.count, 4)
        XCTAssertTrue(panel.table.isItemExpanded(panel.table.item(atRow: 1)), "open by default")
        XCTAssertEqual(panel.tsv(rows: IndexSet(integer: 1)), "", "a branch's own row copies nothing")
        XCTAssertEqual(panel.tsv(rows: IndexSet(integer: 2)).split(separator: "\t").first, "62/66")

        // The other records are tables still; a record without a header shows none.
        let ramPanel = try self.panel(["ec_ram": ram], show: "ec_ram")
        XCTAssertEqual(ramPanel.shownHeader, "")
        XCTAssertTrue(ramPanel.shownGroups.isEmpty)
    }

    func testTheFilterHidesBranchesWithNothingThatMatches() throws {
        let panel = try self.panel(["host_commands": commands], show: "host_commands")
        panel.setFilter("flash")
        XCTAssertEqual(panel.shownGroups.map(\.value), ["68/6C"])
        XCTAssertEqual(panel.shownRows.count, 1)
        panel.setFilter("")
        XCTAssertEqual(panel.shownGroups.count, 3)
        panel.table.sortDescriptors = [NSSortDescriptor(key: "cmd", ascending: false)]
        XCTAssertEqual(panel.cellText(row: 2, column: "cmd"), "0x81", "sorted within the branch")
    }

    func testARefSelectsARowInsideAClosedBranchAndLinksStillWork() throws {
        let panel = try self.panel(["host_commands": commands, "ec_ram": ram], show: "host_commands")
        var opened: [CodeAddress] = []
        panel.onOpenAddress = { opened.append($0) }
        let read = try row(panel, "effect", "read EC RAM")
        panel.click(row: read, column: "handler")
        XCTAssertEqual(opened, [CodeAddress(0x1500)])
        XCTAssertEqual(panel.cell(row: read, column: "handler")?.textField?.textColor, .linkColor)
        let mark = try XCTUnwrap(panel.cell(row: read, column: "ports")?.viewWithTag(6_001) as? NSImageView)
        XCTAssertFalse(mark.isHidden, "an inferred row is marked inside a branch")

        // The EC RAM row names this command's branch: a ref from elsewhere opens it.
        panel.table.collapseItem(panel.table.item(atRow: 1))
        XCTAssertEqual(panel.table.numberOfRows, 5)
        let key = ModuleRecords.rowKey(["ports": .string("62/66"), "cmd": .int(0x81), "mode": .string("normal")],
                                       key: ["ports", "cmd", "sub", "mode"])
        panel.select(key: key)
        XCTAssertTrue(panel.table.isItemExpanded(panel.table.item(atRow: 1)))
        XCTAssertEqual(panel.cellText(row: panel.table.selectedRow, column: "effect"), "write EC RAM")
    }
}
