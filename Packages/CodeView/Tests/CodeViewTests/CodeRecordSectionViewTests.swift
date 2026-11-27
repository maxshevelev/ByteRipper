import AnalysisProfiles
import AppKit
import CodeAnalysis
import XCTest
@testable import CodeView

/// A record section: a narrow list of key and label, branches where the
/// record groups its rows, the selected row's details under it, the legend
/// over it and the filter at its foot.
@MainActor
final class CodeRecordSectionViewTests: XCTestCase {
    private func records(_ object: [String: Any]) throws -> ModuleRecords {
        ModuleRecords.of(reviewDocument: try JSONSerialization.data(withJSONObject: ["records": object]))
    }

    override func tearDown() {
        for record in AnalysisProfile.ecIteNds32.records {
            CodeRecordSectionView.forgetLegend(record.id)
        }
        super.tearDown()
    }

    /// The section in a window at the navigator's narrowest, laid out.
    private func panel(_ object: [String: Any], show id: String, width: CGFloat = 180) throws -> CodeRecordSectionView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let panel = CodeRecordSectionView(frame: NSRect(x: 0, y: 0, width: width, height: 560))
        window.contentView = panel
        panel.setRecords(try records(object), statuses: nil, profile: .ecIteNds32)
        panel.show(id: id, fallbackTitle: id, font: .systemFont(ofSize: 11))
        window.orderFront(nil)
        panel.layoutSubtreeIfNeeded()
        addTeardownBlock { window.orderOut(nil) }
        return panel
    }

    private func lines(_ panel: CodeRecordSectionView) -> [String] {
        (0..<panel.table.numberOfRows).map { panel.listText(row: $0) }
    }

    private func row(_ panel: CodeRecordSectionView, _ text: String) throws -> Int {
        try XCTUnwrap((0..<panel.table.numberOfRows).first { panel.listText(row: $0) == text }, text)
    }

    private func select(_ panel: CodeRecordSectionView, _ text: String) throws {
        panel.table.selectRowIndexes(IndexSet(integer: try row(panel, text)), byExtendingSelection: false)
    }

    // The store's form: hex numbers as text, as the owner's recordValue writes them.
    private let ram: [String: Any] = [
        "status": "partial", "note": "the battery block is not read yet",
        "rows": [
            ["offset": "0x2A", "width": "2", "name": "FAN", "writer": "host", "meaning": "Fan speed. Little-endian.",
             "accessed_by": ["0x1400"], "confidence": "inference", "note": "named by its use"],
            ["offset": "0x10", "width": "1", "name": "STATE", "label": "Power state", "writer": "EC",
             "meaning": "power state", "accessed_by": ["0x1200", "0x1300"], "confidence": "established"],
            ["offset": "0x09", "width": "1", "name": "A", "writer": "EC", "meaning": "a", "confidence": "established"]
        ]
    ]

    private let commands: [String: Any] = [
        "status": "partial",
        "rows": [
            ["ports": "68/6C", "mode": "flash", "cmd": "0x10", "handler": "0x1700", "effect": "enter flash",
             "confidence": "established"],
            ["ports": "62/66", "mode": "normal", "cmd": "0x81", "handler": "0x1600", "effect": "write EC RAM",
             "ec_ram": ["0x2A"], "confidence": "established"],
            ["ports": "62/66", "mode": "normal", "cmd": "0x80", "handler": "0x1500", "effect": "read EC RAM",
             "data_in": "1 byte: offset", "ec_ram": ["0x2A"], "confidence": "inference", "note": "from the ACPI spec"],
            ["ports": "68/6C", "mode": "normal", "cmd": "0x10", "handler": "0x1800", "effect": "set mode",
             "confidence": "established"],
            ["ports": "68/6C", "mode": "normal", "cmd": "0x59", "sub": "0x02", "handler": "0x1900", "label": "Fan full speed",
             "effect": "fan to full speed", "confidence": "established"],
            ["ports": "68/6C", "mode": "normal", "cmd": "0x59", "handler": "0x1910", "effect": "fan control",
             "confidence": "established"]
        ]
    ]

    private let flash: [String: Any] = [
        "status": "complete", "rows": [
            ["address": "0x2A600", "size": "0x100", "format": "bytes", "writers": ["0x5000"], "label": "Shipping flag",
             "meaning": "Battery shipping-mode flag.", "confidence": "established",
             "host_commands": [["ports": "68/6C", "cmd": "0x10", "mode": "normal"]]]
        ]
    ]

    // MARK: - The list

    func testEachRecordWritesItsKeyAndLabel() throws {
        let ramPanel = try panel(["ec_ram": ram], show: "ec_ram")
        XCTAssertEqual(lines(ramPanel), ["0x09  a", "0x10  Power state", "0x2A–0x2B  Fan speed"],
                       "numbers as text sort as numbers; a wider field is its range; no label: the first sentence")
        XCTAssertEqual(ramPanel.table.tableColumns.count, 1)

        let host = try panel(["host_commands": commands], show: "host_commands")
        XCTAssertEqual(lines(host), ["", "", "0x80  read EC RAM", "0x81  write EC RAM", "",
                                     "0x10  set mode", "0x10  enter flash", "0x59  fan control", "0x59/0x02  Fan full speed"],
                       "by command, then subcommand, flash after normal; never a command merged across ports")
        let flashRow = try XCTUnwrap(host.cell(row: try row(host, "0x10  enter flash")))
        XCTAssertTrue(flashRow.textField?.stringValue.contains(CodeRecordSectionView.valueTitle("flash")) ?? false)

        let irq = try panel(["irq_map": ["status": "complete", "rows": [
            ["irq": 24, "handler": "0x1200", "source": "kbc", "source_status": "firmware", "enabled_by_firmware": false,
             "purpose": "keyboard input", "confidence": "established"],
            ["irq": "4", "handler": "0x1300", "source": "timer", "source_status": "firmware", "enabled_by_firmware": true,
             "purpose": "tick", "confidence": "established"]]]], show: "irq_map")
        XCTAssertEqual(irq.shownGroups.map(\.title), ["Enabled", "Not enabled"].map(CodeRecordSectionView.valueTitle))
        XCTAssertEqual(lines(irq), ["", "IRQ 4  tick", "", "IRQ 24  keyboard input"])
        let off = try XCTUnwrap(irq.cell(row: 3)?.textField)
        XCTAssertEqual(off.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .secondaryLabelColor, "an interrupt the firmware leaves off reads in grey")

        let smbus = try panel(["smbus_peers": ["status": "complete", "rows": [
            ["channel": "A", "address": "0x0B", "device": "battery", "pec": true, "commands": [], "confidence": "established"],
            ["channel": "B", "address": "mailbox", "device": "host", "commands": [], "confidence": "established",
             "note": "through the mailbox"]]]], show: "smbus_peers")
        XCTAssertEqual(smbus.shownGroups.map(\.title), ["Channel A", "Channel B"].map {
            $0.replacingOccurrences(of: "Channel", with: CodeRecordSectionView.columnTitle("Channel"))
        })
        XCTAssertEqual(lines(smbus), ["", "0x0B  battery", "", "mailbox  host"])
        XCTAssertTrue(smbus.cell(row: 1)?.textField?.stringValue.contains("PEC") ?? false)

        let gpio = try panel(["gpio": ["status": "complete", "rows": [
            ["pin": "GPJ5", "direction": "in", "function": "Lid switch.", "group": "input", "confidence": "established"],
            ["pin": "GPA3", "direction": "out", "function": "Power LED.", "confidence": "established"]]]], show: "gpio")
        XCTAssertEqual(gpio.shownGroups.map(\.value), ["input", "other"], "a pin with no group stands under Other")
        XCTAssertEqual(lines(gpio), ["", "GPJ5  Lid switch", "", "GPA3  Power LED"])
        XCTAssertEqual((gpio.cell(row: 1) as? RecordRowCell)?.shownMark, CodeRecordSectionView.directionTip("in"))
        XCTAssertEqual((gpio.cell(row: 3) as? RecordRowCell)?.shownMark, CodeRecordSectionView.directionTip("out"))

        let flashPanel = try panel(["eflash_area": flash], show: "eflash_area")
        XCTAssertEqual(lines(flashPanel), ["0x2A600  Shipping flag"])
        XCTAssertTrue(flashPanel.shownGroups.isEmpty)
    }

    func testALabelIsCutAtFortyCharacters() {
        XCTAssertEqual(CodeRecordSectionView.firstSentence("Reads one byte. Then more."), "Reads one byte")
        let long = String(repeating: "word ", count: 20)
        let section = CodeRecordSectionView(frame: .zero)
        section.setRecords(ModuleRecords(), statuses: nil, profile: .ecIteNds32)
        section.show(id: "gpio", fallbackTitle: "GPIO", font: .systemFont(ofSize: 11))
        let label = section.label(["function": .string(long)])
        XCTAssertEqual(label.count, CodeRecordSectionView.labelLimit)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testAnInferredRowCarriesOneTrailingMark() throws {
        let panel = try self.panel(["ec_ram": ram], show: "ec_ram")
        let inferred = try XCTUnwrap(panel.table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? RecordRowCell)
        inferred.layoutSubtreeIfNeeded()
        XCTAssertEqual(inferred.shownMark, CodeRecordSectionView.inferenceToolTip(note: "named by its use"))
        XCTAssertGreaterThan(inferred.markView.frame.minX, inferred.textField?.frame.maxX ?? .infinity,
                             "the mark stands after the line")
        XCTAssertTrue(inferred.textField?.font.map { _ in
            (inferred.textField?.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits.contains(.italic) ?? false } ?? false)
        XCTAssertNil((panel.cell(row: 0) as? RecordRowCell)?.shownMark)
    }

    // MARK: - Branches

    func testHostCommandsStandUnderTheirPortPairs() throws {
        let panel = try self.panel(["host_commands": commands], show: "host_commands")
        XCTAssertEqual(panel.shownGroups.map(\.value), ["60/64", "62/66", "68/6C"])
        XCTAssertEqual(panel.shownGroups.map(\.rows), [0, 2, 4])
        XCTAssertEqual(panel.shownGroups.map(\.title), [
            "60/64  " + CodeRecordSectionView.valueTitle("Keyboard controller"),
            "62/66  " + CodeRecordSectionView.valueTitle("ACPI EC"),
            "68/6C  " + CodeRecordSectionView.valueTitle("OEM channel")])
        let group = try XCTUnwrap(panel.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? RecordGroupCell)
        XCTAssertEqual(group.count.stringValue, "(2)")
        XCTAssertFalse(group.info.isHidden)
        group.info.performClick(nil)
        XCTAssertEqual(panel.shownPopoverText, CodeRecordSectionView.valueSummary(AnalysisProfile.acpiPortsSummary))
    }

    func testAFontStaysAsABranchClosesAndOpens() throws {
        let panel = try self.panel(["host_commands": commands], show: "host_commands")
        func fonts() -> [String] {
            (0..<panel.table.numberOfRows).compactMap { row -> String? in
                let view = panel.table.view(atColumn: 0, row: row, makeIfNecessary: true)
                let field = (view as? RecordGroupCell)?.label ?? (view as? NSTableCellView)?.textField
                guard let text = field?.attributedStringValue, text.length > 0 else { return nil }
                let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                return "\(text.string):\(font?.fontName ?? "")@\(font?.pointSize ?? 0)"
            }
        }
        let before = fonts()
        let group = panel.table.item(atRow: 1)
        panel.table.collapseItem(group)
        panel.layoutSubtreeIfNeeded()
        panel.table.expandItem(group)
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(fonts(), before)
    }

    // MARK: - Details

    func testTheDetailsSayEachFieldOnce() throws {
        let panel = try self.panel(["host_commands": commands, "ec_ram": ram], show: "host_commands")
        XCTAssertTrue(panel.shownDetails.isEmpty, "nothing selected")
        try select(panel, "0x80  read EC RAM")
        XCTAssertEqual(panel.shownDetailTitle, "0x80 · read EC RAM")
        let names = panel.shownDetails.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(CodeRecordSectionView.columnTitle("Label")))
        let details = Dictionary(uniqueKeysWithValues: panel.shownDetails.map { ($0.name, $0.value) })
        XCTAssertEqual(details[CodeRecordSectionView.columnTitle("Handler")], "0x1500")
        XCTAssertEqual(details[CodeRecordSectionView.columnTitle("Data in")], "1 byte: offset")
        XCTAssertEqual(details[CodeRecordSectionView.columnTitle("EC RAM")], "0x2A")
        XCTAssertEqual(details[CodeRecordSectionView.confidenceTitle], CodeRecordSectionView.inferenceTitle)
        XCTAssertEqual(details[CodeRecordSectionView.noteTitle], "from the ACPI spec")

        var opened: [CodeAddress] = []
        panel.onOpenAddress = { opened.append($0) }
        let links = panel.details.content.subviewsDeep.compactMap { $0 as? RecordLinkButton }
        XCTAssertEqual(links.map(\.title), ["0x1500", "0x2A"])
        links[0].performClick(nil)
        XCTAssertEqual(opened, [CodeAddress(0x1500)])
        links[1].performClick(nil)
        XCTAssertEqual(panel.recordID, "ec_ram", "a ref switches to its record")
        XCTAssertEqual(panel.listText(row: panel.table.selectedRow), "0x2A–0x2B  Fan speed")
    }

    func testTheDetailsListTheRowsThatNameThisOne() throws {
        let panel = try self.panel(["host_commands": commands, "ec_ram": ram, "eflash_area": flash], show: "ec_ram")
        try select(panel, "0x2A–0x2B  Fan speed")
        let used = try XCTUnwrap(panel.shownDetails.first { $0.name == CodeRecordSectionView.usedByCommandsTitle })
        XCTAssertEqual(used.value, "0x80  read EC RAM, 0x81  write EC RAM")
        let back = panel.details.content.subviewsDeep.compactMap { $0 as? RecordLinkButton }
            .first { $0.title == "0x81  write EC RAM" }
        back?.performClick(nil)
        XCTAssertEqual(panel.recordID, "host_commands")
        XCTAssertEqual(panel.listText(row: panel.table.selectedRow), "0x81  write EC RAM")

        try select(panel, "0x10  set mode")
        XCTAssertEqual(panel.shownDetails.first { $0.name == CodeRecordSectionView.flashAreasTitle }?.value,
                       "0x2A600  Shipping flag")
    }

    func testAnSMBusDevicesCommandsAreASmallTable() throws {
        let panel = try self.panel(["smbus_peers": ["status": "complete", "rows": [
            ["channel": "A", "address": 0x0B, "device": "battery", "confidence": "established",
             "commands": [["cmd": "0x0D", "access": "R", "size": "word", "meaning": "charge"],
                          ["cmd": "0x16", "access": "R", "size": "word", "meaning": "status"]]]]]], show: "smbus_peers")
        try select(panel, "0x0B  battery")
        let grid = try XCTUnwrap(panel.details.content.subviewsDeep.compactMap { $0 as? NSGridView }.first)
        XCTAssertEqual(grid.numberOfRows, 2)
        XCTAssertEqual(grid.numberOfColumns, 4)
        XCTAssertEqual((grid.cell(atColumnIndex: 0, rowIndex: 1).contentView as? NSTextField)?.stringValue, "0x16")
        XCTAssertEqual(panel.shownDetails.first { $0.name == CodeRecordSectionView.columnTitle("Bus address") }?.value,
                       "0x16")
    }

    // MARK: - The legend, the filter, the width

    func testTheLegendIsShutByDefaultAndRememberedPerRecord() throws {
        let panel = try self.panel(["host_commands": commands, "ec_ram": ram], show: "host_commands")
        XCTAssertFalse(panel.legendIsOpen)
        XCTAssertEqual(panel.shownLegendLine, CodeRecordSectionView.title(of: "host_commands", fallback: "")
            + " · " + String(CodeRecordSectionView.statusText(.partial, note: nil).dropLast()))
        XCTAssertEqual(panel.shownHeader, CodeRecordSectionView.header(AnalysisProfile.hostCommandsHeader))
        panel.legendTitle.performClick(nil)
        XCTAssertTrue(panel.legendIsOpen)

        let again = try self.panel(["host_commands": commands, "ec_ram": ram], show: "host_commands")
        XCTAssertTrue(again.legendIsOpen, "remembered")
        again.show(id: "ec_ram", fallbackTitle: "ec_ram", font: .systemFont(ofSize: 11))
        XCTAssertFalse(again.legendIsOpen, "per record")
        XCTAssertEqual(again.shownNote, "the battery block is not read yet")
        XCTAssertEqual(again.shownHeader, "")

        let bare = try self.panel(["gpio": ["status": "complete", "rows": []]], show: "gpio")
        XCTAssertTrue(bare.legendDisclosure.isHidden, "nothing to open")
    }

    func testTheFilterAtTheFootMatchesKeyAndLabel() throws {
        let panel = try self.panel(["host_commands": commands], show: "host_commands")
        XCTAssertEqual(panel.filterBar.frame.minY, 0)
        XCTAssertLessThan(panel.filterBar.frame.maxY, panel.tableScroll.frame.minY)
        XCTAssertEqual(panel.searchField.placeholderString, CodePaneView.filterPlaceholder)
        panel.setFilter("0x59")
        XCTAssertEqual(panel.shownRows.count, 2)
        panel.setFilter("full speed")
        XCTAssertEqual(panel.shownRows.count, 1)
        XCTAssertEqual(panel.shownGroups.map(\.value), ["68/6C"])
        panel.setFilter("0x1900")
        XCTAssertEqual(panel.shownRows.count, 0, "a handler is a detail, not the line")
        XCTAssertFalse(panel.shownEmptyText.isEmpty)
    }

    func testItFitsTheNarrowestNavigatorWithNoSidewaysScroll() throws {
        for record in AnalysisProfile.ecIteNds32.records where record.panel != nil {
            let panel = try self.panel(["host_commands": commands, "ec_ram": ram, "eflash_area": flash],
                                       show: record.id, width: 180)
            XCTAssertFalse(panel.tableScroll.hasHorizontalScroller)
            XCTAssertLessThanOrEqual(panel.table.frame.width, panel.tableScroll.contentSize.width + 0.5, record.id)
            XCTAssertEqual(panel.table.tableColumns.count, 1, record.id)
        }
    }

    func testTheStatusHasFourStates() throws {
        let unanswered = try panel([:], show: "gpio")
        XCTAssertEqual(unanswered.shownStatus, CodeRecordSectionView.statusText(.unanswered, note: nil))
        XCTAssertEqual(unanswered.shownEmptyText, CodeRecordSectionView.emptyText)
        let none = try panel(["gpio": ["status": "none", "note": "the firmware drives no GPIO", "rows": []]], show: "gpio")
        XCTAssertTrue(none.shownStatus.contains("the firmware drives no GPIO"))
        XCTAssertEqual(none.shownEmptyText, "")
        let early = CodeRecordSectionView(frame: .zero)
        early.setRecords(nil, statuses: ["gpio": "complete"], profile: .ecIteNds32)
        early.show(id: "gpio", fallbackTitle: "GPIO", font: .systemFont(ofSize: 11))
        XCTAssertEqual(early.shownStatus, CodeRecordSectionView.statusText(.complete, note: nil))
    }

    func testCopyRowCopiesEveryField() throws {
        let panel = try self.panel(["ec_ram": ram], show: "ec_ram")
        let tsv = panel.tsv(rows: IndexSet(integer: 0)).split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertTrue(tsv.contains("0x09"))
        XCTAssertTrue(tsv.contains("0x80409"))
    }
}

private extension NSView {
    var subviewsDeep: [NSView] { subviews + subviews.flatMap(\.subviewsDeep) }
}
