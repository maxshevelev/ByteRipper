import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// A DMI area's row and details: the row says the serial, the detail lists
/// the identity fields and what the integrity checks found in them, and `?`
/// opens the entry. The format is `UEFIImage`'s and tested there.
final class UEFIAcerDMIDetailTests: XCTestCase {
    /// 22 alphanumerics: "N" first, "00" at 7, "3400" at the end.
    private static let serial = "N51TEST000000000003400"
    /// 22 alphanumerics: "NB" first, "1100" at 5, "3400" at the end.
    private static let tag = "NB2TE11000000000003400"
    /// Version 1, variant 1; the last six bytes are the tail the block copies.
    private static let uuid: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0x17, 0x88, 0x89, 0xCD,
                                        0xEF, 0x01, 0x02, 0x03, 0x04, 0x05]

    private static func put(_ bytes: inout [UInt8], _ text: String, at offset: Int) {
        for (index, byte) in text.utf8.enumerated() {
            bytes[offset + index] = byte
        }
    }

    /// The factory-shaped block: every field of the layout written, the rest
    /// FF.
    private static func block() -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(AcerDMIArea.size))
        put(&bytes, serial, at: 0x00)
        bytes[0x30] = 0x01
        for (index, byte) in AcerDMIArea.signature.enumerated() {
            bytes[Int(AcerDMIArea.signatureOffset) + index] = byte
        }
        put(&bytes, tag, at: 0x50)
        for (index, byte) in uuid.enumerated() {
            bytes[0x70 + index] = byte
        }
        put(&bytes, "TEST-1050", at: 0x80)
        put(&bytes, "Test Model", at: 0xC0)
        bytes[0xF3] = 0x02
        for (index, byte) in uuid[10...].enumerated() {
            bytes[0x130 + index] = byte
        }
        return bytes
    }

    /// Padding, the block at `0x4000`, and padding.
    private static func image(block: [UInt8] = block()) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 0x4000) + block + [UInt8](repeating: 0xFF, count: 0x4000)
    }

    private func parsed() throws -> (image: UEFIImage, node: UEFINode, reader: ImageReader) {
        try parsed(Self.image())
    }

    private func parsed(_ bytes: [UInt8]) throws -> (image: UEFIImage, node: UEFINode, reader: ImageReader) {
        let image = UEFIParser.parse(bytes)
        let node = try XCTUnwrap(image.allNodes.first { $0.kind == .acerDMIStore })
        return (image, node, ImageReader(bytes))
    }

    private func value(_ label: String, in detail: UEFINodeDetail) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    /// The detail lists the identity fields, in the order the bench asks them;
    /// a factory block has no problems and no notes.
    func testTheAreaSaysWhatItHolds() throws {
        let parsed = try parsed()
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader)
        XCTAssertEqual(value("Kind", in: detail), "Acer DMI")
        XCTAssertEqual(value("System serial", in: detail), Self.serial)
        XCTAssertEqual(value("Service tag", in: detail), Self.tag)
        XCTAssertEqual(value("UUID", in: detail), "78563412-AB90-1788-89CD-EF0102030405")
        XCTAssertEqual(value("Model", in: detail), "TEST-1050")
        XCTAssertEqual(value("Product name", in: detail), "Test Model")
        XCTAssertNil(value("Asset tag", in: detail), "its padding is no asset tag")
        XCTAssertNil(value("Manufacturing code", in: detail), "not written in this block")
        XCTAssertEqual(detail.fields.filter { $0.isProblem }.count, 0)
        XCTAssertEqual(detail.tables, [])
    }

    /// The optional fields are rows where written, and no rows over their
    /// padding.
    func testTheOptionalFieldsAreRowsWhereWritten() throws {
        var block = Self.block()
        Self.put(&block, "Asset0001", at: 0xA0)
        Self.put(&block, "12345678", at: 0x6A0)
        let parsed = try parsed(Self.image(block: block))
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader)
        XCTAssertEqual(value("Asset tag", in: detail), "Asset0001")
        XCTAssertEqual(value("Manufacturing code", in: detail), "12345678")
    }

    /// The row answers what a bench opens the area for: the serial.
    func testTheRowSaysWhatItHolds() throws {
        let parsed = try parsed()
        let name = UEFITreeDisplay.name(for: parsed.node, catalogue: .empty, reader: parsed.reader)
        XCTAssertEqual(name, "Acer DMI · \(Self.serial)")
        XCTAssertEqual(UEFITreeDisplay.typeText(for: parsed.node), "Padding", "padding to UEFITool")
        XCTAssertEqual(UEFIHelpTerms.term(for: parsed.node), HelpTermID("acer-dmi"))
    }

    /// What the integrity checks found is a problem where a factory block
    /// would not read that way, a note where only the copy went stale.
    func testATamperedAreaSaysWhatReadsWrong() throws {
        var block = Self.block()
        block[0x70 + 8] = 0x09 // the variant bit is not set
        block[0xF3] = 0x00 // the constant is not 02
        block.replaceSubrange(0x130..<(0x130 + 6), with: [UInt8](repeating: 0xAA, count: 6)) // the copy went stale
        let parsed = try parsed(Self.image(block: block))
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader)
        let problems = detail.fields.filter { $0.label == "Problem" }
        XCTAssertEqual(problems.count, 3)
        XCTAssertTrue(problems.allSatisfy(\.isProblem))
        XCTAssertEqual(detail.fields.filter { $0.label == "Note" }.count, 0)
    }

    /// An erased copy is worth knowing, not a fault: the block has no
    /// checksum, so nothing checks wrong because of it.
    func testAnErasedTailCopyIsANote() throws {
        var block = Self.block()
        block.replaceSubrange(0x130..<(0x130 + 6), with: [UInt8](repeating: 0xFF, count: 6))
        let parsed = try parsed(Self.image(block: block))
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader)
        let notes = detail.fields.filter { $0.label == "Note" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes.allSatisfy { !$0.isProblem })
        XCTAssertEqual(detail.fields.filter { $0.isProblem }.count, 0)
    }
}
