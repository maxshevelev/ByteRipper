import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// Panasonic's DMI area's row and details: the row says the model and the
/// serial, the detail lists the identity fields and the records, a record
/// says what its header holds, and `?` opens the entry. The format is
/// `UEFIImage`'s and tested there.
final class UEFIPanasonicDMIDetailTests: XCTestCase {
    private static let serial = "TEST0000SERIAL1"
    private static let key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }

    /// Makes the bytes of `range` sum to 0 by the byte at `at`.
    private static func fix(_ bytes: inout [UInt8], _ range: Range<Int>, at: Int) {
        bytes[at] = 0
        bytes[at] = 0 &- bytes[range].reduce(0, &+)
    }

    /// Padding, at `0x4000` a block of three records — the asset tag and the
    /// serial behind short headers, the key behind a long one — and padding.
    /// Every checksum holds unless `breaking` changes a byte after them.
    private static func image(breaking: ((inout [UInt8]) -> Void)? = nil) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 0x200)
        func put(_ data: [UInt8], at offset: Int) {
            block.replaceSubrange(offset..<(offset + data.count), with: data)
        }
        put(Array("MEI_FZ55-2".utf8), at: 0)
        put(Array("FZ55FZ-52M4".utf8), at: 0x28)
        let records: [(id: UInt32, at: Int, length: Int, long: Bool)] = [
            (0x02, 0x100, 0x80, false),
            (0x03, 0x180, 0x40, false),
            (0x16, 0x1C0, 0x39, true)
        ]
        put(le16(UInt16(records.count + 1)), at: 0x80)
        for (index, record) in records.enumerated() {
            put(le32(record.id) + le32(0xFF40_4000 + UInt32(record.at)), at: 0x88 + index * 8)
            put(record.long ? le32(UInt32(record.length)) + [0, 0x40, 0, 0] : le16(UInt16(record.length)) + [0],
                at: record.at)
        }
        put(Array("No Asset Tag".utf8), at: 0x103)
        put([0x01] + Array((serial + "\r\n").utf8), at: 0x183)
        put(le32(1) + le32(0) + le32(1) + le32(0) + le32(29) + Array(key.utf8), at: 0x1C8)
        fix(&block, 0..<0x80, at: 0x16)
        fix(&block, 0x80..<(0x88 + records.count * 8), at: 0x82)
        for record in records {
            fix(&block, record.at..<(record.at + record.length), at: record.at + (record.long ? 4 : 2))
        }
        breaking?(&block)
        return [UInt8](repeating: 0xFF, count: 0x4000) + block + [UInt8](repeating: 0xFF, count: 0x3E00)
    }

    private func parsed(_ bytes: [UInt8] = image()) throws -> (image: UEFIImage, node: UEFINode, reader: ImageReader) {
        let image = UEFIParser.parse(bytes)
        let node = try XCTUnwrap(image.allNodes.first { $0.kind == .panasonicDMIStore })
        return (image, node, ImageReader(bytes))
    }

    private func value(_ label: String, in detail: UEFINodeDetail) -> String? {
        if let field = detail.fields.first(where: { $0.label == label }) { return field.value }
        let entries = detail.tables.first { $0.title == "Entries" }
        return entries?.rows.first { $0.first?.text == label }.map { $0[1].text }
    }

    func testTheAreaSaysWhatItHolds() throws {
        let parsed = try parsed()
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("Kind", in: detail), "Panasonic DMI")
        XCTAssertEqual(value("Model", in: detail), "FZ55-2")
        XCTAssertEqual(value("Model code", in: detail), "FZ55FZ-52M4")
        XCTAssertEqual(value("Asset tag", in: detail), "No Asset Tag")
        XCTAssertEqual(value("Serial", in: detail), Self.serial)
        XCTAssertEqual(value("Windows product key", in: detail), Self.key)
        let entries = try XCTUnwrap(detail.tables.first { $0.title == "Entries" })
        XCTAssertTrue(entries.rowTargets.allSatisfy { $0 != nil }, "each value is a way to its row")
        let records = try XCTUnwrap(detail.tables.first { $0.title == "Directory" })
        XCTAssertEqual(records.rows.map { $0.map(\.text) }, [
            ["0x02", "0xFF404100", "0x80", "OK", "Asset tag"],
            ["0x03", "0xFF404180", "0x40", "OK", "Serial"],
            ["0x16", "0xFF4041C0", "0x39", "OK", "Windows product key"]
        ])
        XCTAssertEqual(detail.fields.filter(\.isProblem).count, 0, "every sum holds")
        XCTAssertEqual(records.rowTargets,
                       parsed.node.children.filter { $0.kind == .panasonicDMIRecord }.map { .node($0.id) })
    }

    func testARecordSaysWhatItsHeaderHolds() throws {
        let parsed = try parsed()
        let record = try XCTUnwrap(parsed.node.children.first { $0.kind == .panasonicDMIRecord && $0.subtype == 0x02 })
        let detail = UEFIDetail.build(for: record, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("ID", in: detail), "0x02")
        XCTAssertEqual(value("Length", in: detail), "0x80")
        XCTAssertTrue(value("Checksum", in: detail)?.hasSuffix("(Valid)") == true, value("Checksum", in: detail) ?? "")
        XCTAssertEqual(value("Holds", in: detail), "Asset tag")
    }

    /// A record changed without its sum, and a directory likewise: the area
    /// is read all the same, and the details say what fails and what the
    /// byte should be.
    func testAFailingChecksumIsAProblem() throws {
        let parsed = try parsed(Self.image { block in
            block[0x183 + 1] = 0x58 // the serial's first character
            block[0x84] = 0x01      // the directory's reserved word
        })
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(detail.fields.first { $0.label == "Directory checksum" }?.isProblem, true)
        XCTAssertEqual(detail.fields.filter { $0.label == "Problem" }.map(\.value),
                       ["1 of the records fail their checksum."])
        let records = try XCTUnwrap(detail.tables.first { $0.title == "Directory" })
        XCTAssertEqual(records.rows.map { $0[3].text }, ["OK", "Invalid", "OK"])
        let serial = try XCTUnwrap(parsed.node.children.first { $0.subtype == 0x03 })
        let field = try XCTUnwrap(UEFIDetail.build(for: serial, image: parsed.image, reader: parsed.reader, in: .english)
            .fields.first { $0.label == "Checksum" })
        XCTAssertTrue(field.isProblem)
        XCTAssertTrue(field.value.contains("should be"), field.value)
    }

    func testTheRowsSayWhatTheyHold() throws {
        let parsed = try parsed()
        func name(_ node: UEFINode) -> String {
            UEFITreeDisplay.name(for: node, catalogue: .empty, in: parsed.image, reader: parsed.reader, language: .english)
        }
        XCTAssertEqual(name(parsed.node), "Panasonic DMI · FZ55-2 · \(Self.serial)")
        let key = try XCTUnwrap(parsed.node.children.first { $0.subtype == 0x16 })
        XCTAssertEqual(name(key), "Record 0x16 · Windows product key")
        XCTAssertEqual(key.children.map(name), ["Windows product key = \(Self.key)"])
        XCTAssertEqual(UEFITreeDisplay.typeText(for: parsed.node), "Padding", "padding to UEFITool")
        XCTAssertEqual(UEFIHelpTerms.term(for: parsed.node), HelpTermID("panasonic-dmi"))
        XCTAssertEqual(UEFIHelpTerms.term(for: key), HelpTermID("panasonic-dmi"))
    }
}
