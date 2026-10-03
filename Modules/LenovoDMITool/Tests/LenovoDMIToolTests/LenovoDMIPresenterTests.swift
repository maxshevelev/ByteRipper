import XCTest
import LenovoDMI
import LenovoDMITool
import ToolModuleKit

/// A store laid out the way the real dumps lay theirs out, with made-up
/// values. `LenovoDMI`'s own tests take the format apart; these check what the
/// panel makes of a store, so a few entries are enough.
private enum Store {
    static func block(generation: UInt32, key: UInt8, entries: [(UInt16, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        for (type, data) in entries {
            body += LenovoDMIFormat.smbiosNamespace
            body += [UInt8(type & 0xFF), UInt8(type >> 8)]
            body += le32(UInt32(data.count)) + [0, 0, 0, 0] + data
        }
        body += [UInt8](repeating: 0, count: 0x1000 - 16 - body.count)
        body = body.map { $0 ^ key }
        let sum = body.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        return Array("LENV".utf8) + le32(generation) + le32(UInt32(entries.count))
            + [0, key, UInt8(sum & 0xFF), UInt8(sum >> 8)] + body
    }

    static func log(key: UInt8) -> [UInt8] {
        var entry: [UInt8] = [0x22, 0x20, 0x06, 0x29, 0x20, 0x30, 0x25, 0x02]
        entry += LenovoDMIFormat.smbiosNamespace + [0x00, 0x04] + le32(8) + [0, 0, 0, 0]
        var body = entry
        body += [UInt8](repeating: 0, count: 0x2000 - 0x20 - body.count)
        return Array("LDBG".utf8) + le32(0x40) + [UInt8](repeating: 0, count: 24)
            + body.map { $0 ^ key }
    }

    static let serial: (UInt16, [UInt8]) = (0x0400, Array("PF0TEST1".utf8))
    static let mtm: (UInt16, [UInt8]) = (0x0200, Array("82XX0000GE".utf8))
    static let unknown: (UInt16, [UInt8]) = (0x0700, [0x19])

    static func image(_ blocks: [[UInt8]]) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 0x1000) + log(key: 0x77) + Array(blocks.joined())
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
}

final class LenovoDMIPresenterTests: XCTestCase {
    private func display(_ blocks: [[UInt8]]) -> LenovoDMIDisplay {
        LenovoDMIPresenter.display(LenovoDMI.locate(in: Store.image(blocks)))
    }

    private var standard: LenovoDMIDisplay {
        display([
            Store.block(generation: 83, key: 0x77, entries: [Store.serial, Store.unknown, Store.mtm]),
            Store.block(generation: 84, key: 0x77, entries: [Store.serial, Store.unknown])
        ])
    }

    func testTheTreeIsTheLogAndBothBlocks() {
        let display = standard
        XCTAssertEqual(display.rows.map(\.name), ["Change log (LDBG)", "LENV block 1", "LENV block 2"])
        XCTAssertEqual(display.rows.map(\.id), ["a0.log", "a0.lenv1", "a0.lenv2"])
        XCTAssertEqual(display.rows[0].children.count, 1)
        XCTAssertEqual(display.rows[1].children.count, 3)
    }

    func testTheSummaryNamesTheLiveBlock() {
        XCTAssertEqual(standard.summary, "LENV block 2 is live: generation 84.")
        XCTAssertEqual(standard.rows[2].value, "Generation 84 · live")
        XCTAssertEqual(standard.rows[1].value, "Generation 83")
    }

    func testEntriesReadByTheirKnownNamesAndUnknownOnesSayUnknown() {
        let entries = standard.rows[1].children
        XCTAssertEqual(entries.map(\.name),
                       ["Baseboard serial number", "Unknown SMBIOS entry 0x0700", "Machine type/model"])
        XCTAssertEqual(entries.map(\.value), ["PF0TEST1", "19", "82XX0000GE"])
    }

    /// The detail says whether the other block agrees: what a bench needs to
    /// know before copying a value from one dump to another.
    func testAnEntrySaysWhatTheOtherCopyHolds() {
        func otherCopy(_ row: LenovoDMIRow) -> String? {
            row.fields.first { $0.label == "Other copy" }?.value
        }
        let entries = standard.rows[1].children
        XCTAssertEqual(otherCopy(entries[0]), "The same in LENV block 2")
        XCTAssertEqual(otherCopy(entries[2]), "Not in LENV block 2")
    }

    func testTheLogEntryReadsAsADatedWrite() {
        let entry = standard.rows[0].children[0]
        XCTAssertEqual(entry.name, "2022-06-29 20:30:25")
        XCTAssertEqual(entry.value, "Set · Baseboard serial number · 8 bytes")
    }

    func testABadChecksumIsAProblemAndSaysWhatItShouldBe() throws {
        var bad = Store.block(generation: 2, key: 0x77, entries: [Store.serial])
        bad[0x0E] ^= 0xFF
        let display = display([bad, Store.block(generation: 1, key: 0x77, entries: [Store.serial])])
        XCTAssertTrue(display.rows[1].isProblem)
        let checksum = try XCTUnwrap(display.rows[1].fields.first { $0.label == "Checksum" })
        XCTAssertTrue(checksum.isProblem)
        XCTAssertTrue(checksum.value.contains("should be"))
        XCTAssertTrue(display.notes.contains { $0.isProblem && $0.text.contains("checksum") })
    }

    func testNoStoreSaysSo() {
        let display = LenovoDMIPresenter.display([])
        XCTAssertEqual(display.summary, "No Lenovo DMI store in this image.")
        XCTAssertEqual(display.rows, [])
    }

    /// Every part of the area is drawn; the entries of only the part in focus.
    func testZonesOpenThePartInFocus() {
        let display = standard
        XCTAssertEqual(display.zones(focus: nil).zones.map(\.id), ["a0.log", "a0.lenv1", "a0.lenv2"])
        let focused = display.zones(focus: "a0.lenv1.0")
        XCTAssertEqual(focused.focus, "a0.lenv1.0")
        XCTAssertEqual(focused.zones.map(\.id),
                       ["a0.log", "a0.lenv1", "a0.lenv1.0", "a0.lenv1.1", "a0.lenv1.2", "a0.lenv2"])
        XCTAssertEqual(focused.zones[2].name, "LENV block 1 · Baseboard serial number")
        XCTAssertEqual(focused.zones[2].range, 0x3010..<0x3030)
    }

    func testTheRowsCarryTheirGlossaryEntries() {
        XCTAssertEqual(standard.rows.map(\.term?.rawValue), ["ldbg", "lenv", "lenv"])
    }
}
