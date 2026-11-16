import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// Insyde's `$DMI` store's row and details: the row says the product and the
/// system serial, the detail lists the values and the records, a record says
/// what its header holds, and `?` opens the entry. The format is
/// `UEFIImage`'s and tested there.
final class UEFIInsydeDMIDetailTests: XCTestCase {
    private static let serial = "TESTSERIAL0001"

    private static func record(_ type: UInt8, _ field: UInt8, _ flag: UInt8, _ value: String) -> [UInt8] {
        let length = 5 + value.utf8.count
        return [type, field, flag, UInt8(length), 0] + Array(value.utf8)
    }

    /// Padding, at `0x4000` a store of `records`, FF to its 4 KiB, padding.
    private static func image(_ records: [UInt8]) -> [UInt8] {
        var store = [UInt8](repeating: 0xFF, count: 0x1000)
        let written = Array("$DMI".utf8) + records
        store.replaceSubrange(0..<written.count, with: written)
        return [UInt8](repeating: 0x00, count: 0x4000) + store + [UInt8](repeating: 0x00, count: 0x3000)
    }

    private static let records: [UInt8] =
        record(1, 0x05, 0x00, "TEST-PRODUCT") + record(1, 0x05, 0xFF, "TEST-PRODUCT")
        + record(1, 0x07, 0x00, serial) + record(1, 0x07, 0xFF, serial)
        + record(0x80, 0x04, 0xFF, "VENDOR")

    private func parsed(_ bytes: [UInt8] = image(records)) throws -> (image: UEFIImage, node: UEFINode, reader: ImageReader) {
        let image = UEFIParser.parse(bytes)
        let node = try XCTUnwrap(image.allNodes.first { $0.kind == .insydeDMIStore })
        return (image, node, ImageReader(bytes))
    }

    private func value(_ label: String, in detail: UEFINodeDetail) -> String? {
        if let field = detail.fields.first(where: { $0.label == label }) { return field.value }
        let entries = detail.tables.first { $0.title == "Entries" }
        return entries?.rows.first { $0.first?.text == label }.map { $0[1].text }
    }

    func testTheStoreSaysWhatItWrites() throws {
        let parsed = try parsed()
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("Kind", in: detail), "Insyde DMI")
        XCTAssertEqual(value("Records", in: detail), "5, in force 3")
        XCTAssertNil(detail.fields.first { $0.label == "Note" }, "every field has one record in force")
        XCTAssertEqual(value("Product name", in: detail), "TEST-PRODUCT")
        XCTAssertEqual(value("System serial number", in: detail), Self.serial)
        XCTAssertEqual(value("Type 128, offset 0x04", in: detail), "VENDOR", "a field the list does not name")
        let entries = try XCTUnwrap(detail.tables.first { $0.title == "Entries" })
        XCTAssertTrue(entries.rowTargets.allSatisfy { $0 != nil }, "each value is a way to its row")
        let records = try XCTUnwrap(detail.tables.first { $0.title == "Records" })
        XCTAssertEqual(records.rows.map { $0.map(\.text) }, [
            ["0x4004", "1", "0x05", "Replaced", "Product name", "TEST-PRODUCT"],
            ["0x4015", "1", "0x05", "In force", "Product name", "TEST-PRODUCT"],
            ["0x4026", "1", "0x07", "Replaced", "System serial number", Self.serial],
            ["0x4039", "1", "0x07", "In force", "System serial number", Self.serial],
            ["0x404C", "128", "0x04", "In force", "Unknown", "VENDOR"]
        ])
        XCTAssertEqual(records.rows.map { $0[3].tone }, [.plain, .yes, .plain, .yes, .yes])
        XCTAssertEqual(records.rowTargets,
                       parsed.node.children.filter { $0.kind == .insydeDMIRecord }.map { .node($0.id) })
    }

    func testAnEmptyStoreSaysSo() throws {
        let parsed = try parsed(Self.image([]))
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("Records", in: detail), "None. The firmware keeps the values of its own SMBIOS tables.")
        XCTAssertNil(detail.tables.first { $0.title == "Records" })
    }

    func testARecordSaysWhatItsHeaderHolds() throws {
        let parsed = try parsed()
        let record = try XCTUnwrap(parsed.node.children.first { $0.kind == .insydeDMIRecord })
        let detail = UEFIDetail.build(for: record, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("SMBIOS type", in: detail), "1")
        XCTAssertEqual(value("Offset in structure", in: detail), "0x05")
        XCTAssertEqual(value("Field", in: detail), "Product name")
        XCTAssertEqual(value("Flag", in: detail), "0x00")
        XCTAssertEqual(value("State", in: detail), "Replaced")
        XCTAssertEqual(value("Length", in: detail), "0x11")
        XCTAssertEqual(value("Value", in: detail), "TEST-PRODUCT")
    }

    func testTheRowsSayWhatTheyHold() throws {
        let parsed = try parsed()
        func name(_ node: UEFINode) -> String {
            UEFITreeDisplay.name(for: node, catalogue: .empty, in: parsed.image, reader: parsed.reader, language: .english)
        }
        XCTAssertEqual(name(parsed.node), "Insyde DMI · TEST-PRODUCT · \(Self.serial)")
        let serial = try XCTUnwrap(parsed.node.children.dropFirst(2).first)
        XCTAssertEqual(name(serial), "System serial number = \(Self.serial)")
        XCTAssertTrue(serial.children.isEmpty, "the value is on the record's own row")
        XCTAssertEqual(name(try XCTUnwrap(parsed.node.children.last)), "Type 128, offset 0x04 = VENDOR",
                       "a field the list does not name")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: parsed.node), "Padding", "padding to UEFITool")
        XCTAssertEqual(UEFIHelpTerms.term(for: parsed.node), HelpTermID("insyde-dmi"))
        XCTAssertEqual(UEFIHelpTerms.term(for: serial), HelpTermID("insyde-dmi"))
        let empty = try self.parsed(Self.image([]))
        XCTAssertEqual(UEFITreeDisplay.name(for: empty.node, catalogue: .empty, in: empty.image,
                                            reader: empty.reader, language: .english),
                       "Insyde DMI · empty")
    }

    /// A record a later one replaced is drawn grey; the one in force is not.
    func testAReplacedRecordIsGrey() throws {
        let parsed = try parsed()
        let flags = parsed.node.children.map { UEFIInsydeDMIDetail.isReplaced($0, reader: parsed.reader) }
        XCTAssertEqual(flags, [true, false, true, false, false])
    }

    /// A field with no record marked in force is read from its last record,
    /// and the details say which.
    func testAFieldWithoutARecordInForceIsNoted() throws {
        let parsed = try parsed(Self.image(Self.record(1, 0x07, 0x00, "OLD") + Self.record(1, 0x07, 0x00, "NEW")))
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("System serial number", in: detail), "NEW")
        XCTAssertEqual(detail.fields.first { $0.label == "Note" }?.value,
                       "No single record is marked in force for: System serial number. The value shown is the last record's.")
    }
}
