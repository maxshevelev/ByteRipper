import XCTest
import LenovoDMI
import ToolModuleKit
import UEFIImage
@testable import UEFITool

/// What the details and the tree say of Lenovo's DMI store: the store's row
/// sums it up, and every row below it says what it holds, decoded. The
/// format is `LenovoDMI`'s and the rows `UEFIImage`'s, tested there.
final class UEFILenovoDMIDetailTests: XCTestCase {
    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private static func block(generation: UInt32, key: UInt8, entries: [(UInt16, [UInt8])]) -> [UInt8] {
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

    private static func log(key: UInt8) -> [UInt8] {
        var body: [UInt8] = [0x22, 0x20, 0x06, 0x29, 0x20, 0x30, 0x25, 0x02]
        body += LenovoDMIFormat.smbiosNamespace + [0x00, 0x04] + le32(8) + [0, 0, 0, 0]
        body += [UInt8](repeating: 0, count: 0x2000 - 0x20 - body.count)
        return Array("LDBG".utf8) + le32(0x40) + [UInt8](repeating: 0, count: 24) + body.map { $0 ^ key }
    }

    private static let serial: (UInt16, [UInt8]) = (0x0400, Array("PF0TEST1".utf8))
    private static let mtm: (UInt16, [UInt8]) = (0x0200, Array("82XX0000GE".utf8))

    /// Padding, the store at `0x4000` — block 1 at generation 3 with both
    /// entries, block 2 at generation 4 with the serial only — and padding.
    private var parsed: (image: UEFIImage, reader: ImageReader) {
        let store = Self.log(key: 0x77)
            + Self.block(generation: 3, key: 0x77, entries: [Self.serial, Self.mtm])
            + Self.block(generation: 4, key: 0x77, entries: [Self.serial])
        let bytes = [UInt8](repeating: 0xFF, count: 0x4000) + store + [UInt8](repeating: 0xFF, count: 0x4000)
        return (UEFIParser.parse(bytes), ImageReader(bytes))
    }

    private func node(_ kind: UEFINodeKind, _ index: Int = 0, in image: UEFIImage) throws -> UEFINode {
        let found = image.allNodes.filter { $0.kind == kind }
        XCTAssertGreaterThan(found.count, index, "\(kind)")
        return try XCTUnwrap(found.dropFirst(index).first)
    }

    private func detail(_ node: UEFINode, _ parsed: (image: UEFIImage, reader: ImageReader)) -> UEFINodeDetail {
        UEFIDetail.build(for: node, image: parsed.image, reader: parsed.reader)
    }

    private func value(_ label: String, in detail: UEFINodeDetail) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    /// The store's row answers what a bench opens it for: which block the
    /// firmware reads, and what that block holds, each value a way to its row.
    func testTheStoreSaysWhichBlockIsInUseAndWhatItHolds() throws {
        let parsed = parsed
        let store = try node(.lenovoDMIStore, in: parsed.image)
        let detail = detail(store, parsed)
        XCTAssertEqual(value("Block in use", in: detail), "LENV block 2, generation 4")
        XCTAssertTrue(detail.fields.contains { $0.label == "Note" && $0.value.contains("different values") },
                      "the blocks differ, which is worth knowing: \(detail.fields)")

        let table = try XCTUnwrap(detail.tables.first)
        XCTAssertEqual(table.title, "Entries in use")
        XCTAssertEqual(table.rows.map { $0.map(\.text) }, [["Baseboard serial number", "PF0TEST1"]])
        let entry = try node(.lenvEntry, 2, in: parsed.image)
        XCTAssertEqual(table.rowTargets, [.node(entry.id)], "block 2's entry, not block 1's")
    }

    func testABlockSaysWhetherTheFirmwareReadsIt() throws {
        let parsed = parsed
        let first = detail(try node(.lenvBlock, 0, in: parsed.image), parsed)
        let second = detail(try node(.lenvBlock, 1, in: parsed.image), parsed)
        XCTAssertEqual(value("Type", in: first), "Not in use")
        XCTAssertEqual(value("Type", in: second), "In use")
        XCTAssertEqual(value("Firmware reads it", in: second), "Yes — the higher generation")
        XCTAssertEqual(value("Generation", in: first), "3")
        XCTAssertEqual(value("Checksum", in: first)?.hasSuffix("(Valid)"), true)
    }

    /// An entry is its value decoded, and whether the other block agrees.
    func testAnEntrySaysItsValueAndTheOtherCopy() throws {
        let parsed = parsed
        let mtm = detail(try node(.lenvEntry, 1, in: parsed.image), parsed)
        XCTAssertEqual(value("Value", in: mtm), "82XX0000GE")
        XCTAssertEqual(value("Other copy", in: mtm), "Not in LENV block 2")
        let serial = detail(try node(.lenvEntry, 0, in: parsed.image), parsed)
        XCTAssertEqual(value("Other copy", in: serial), "The same in LENV block 2")
    }

    func testALogEntrySaysWhatWasWritten() throws {
        let parsed = parsed
        let write = detail(try node(.ldbgEntry, in: parsed.image), parsed)
        XCTAssertEqual(value("Operation", in: write), "Set")
        XCTAssertEqual(value("Entry", in: write), "Baseboard serial number")
    }

    /// A block stored encoded wears a lock; the same block opened decoded —
    /// in the clear under its key — an open one; the store and the entries
    /// wear neither.
    func testABlocksRowSaysWhetherItIsEncoded() throws {
        let parsed = parsed
        func roles(_ node: UEFINode, _ image: UEFIImage, _ reader: ImageReader) -> [ToolRowMarks.Role] {
            UEFITreeMarks.marks(for: node, in: image, reader: reader).roles
        }
        let block = try node(.lenvBlock, 1, in: parsed.image)
        XCTAssertEqual(roles(block, parsed.image, parsed.reader),
                       [.encoded("Encoded with the XOR key 0x77", decoded: false)])
        XCTAssertEqual(roles(try node(.lenovoDMIStore, in: parsed.image), parsed.image, parsed.reader), [])
        XCTAssertEqual(roles(try node(.lenvEntry, in: parsed.image), parsed.image, parsed.reader), [])
        XCTAssertEqual(UEFITreeMarks.marks(for: block, in: parsed.image).roles, [],
                       "without the bytes, nothing is said")

        let stored = try XCTUnwrap(parsed.reader.bytes(block.range))
        let decoded = LenovoDMIDecodedBlock.decode(LENVBlock(offset: 0, stored: stored))
        let alone = UEFIParser.parse(decoded)
        let row = try node(.lenvBlock, in: alone)
        XCTAssertEqual(roles(row, alone, ImageReader(decoded)),
                       [.encoded("Decoded: the key 0x77 encodes it again on the way back", decoded: true)])
    }

    /// The tree's rows say what they hold without being opened.
    func testTheTreesRowsSayWhatTheyHold() throws {
        let parsed = parsed
        func name(_ node: UEFINode) -> String {
            let parent = parsed.image.node(NodeID(Array(node.id.path.dropLast())))
            return UEFITreeDisplay.name(for: node, catalogue: .empty, in: parsed.image,
                                        reader: parsed.reader, store: parent)
        }
        XCTAssertEqual(name(try node(.lenvEntry, 1, in: parsed.image)), "Machine type/model = 82XX0000GE")
        XCTAssertEqual(name(try node(.lenvBlock, 1, in: parsed.image)), "LENV block 2 · Generation 4")
        XCTAssertEqual(name(try node(.ldbgEntry, in: parsed.image)),
                       "2022-06-29 20:30:25 · Set · Baseboard serial number")
        XCTAssertEqual(UEFITreeDisplay.subtypeText(for: try node(.lenvBlock, 1, in: parsed.image)), "In use")
        XCTAssertTrue(UEFITreeDisplay.showsValue(try node(.lenvEntry, in: parsed.image)))
    }
}
