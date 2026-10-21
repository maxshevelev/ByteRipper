import HelpBook
import Localization
import UEFIImage
import XCTest
@testable import UEFITool

/// Apple's DMI on the SysF store: the row says the serial, the detail lists
/// what the store holds, the DMI menu names it, and `?` opens its entry. The
/// format is `UEFIImage`'s and tested there.
final class UEFIAppleDMIDetailTests: XCTestCase {
    private static let board = "C02542600KXG91TAN"

    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    private static func variable(_ name: String, _ data: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(name.utf8.count)]
        bytes += Array(name.utf8)
        bytes += [UInt8(data.count & 0xFF), UInt8(data.count >> 8)]
        return bytes + data
    }

    private static func text(_ name: String, _ text: String) -> [UInt8] { variable(name, Array(text.utf8)) }

    /// A SysF store of a Mac that keeps its identity, in an NVRAM volume.
    private static func image(serial: String, code: String) -> [UInt8] {
        var variables: [UInt8] = []
        variables += variable(board + "TCFMAC-1", [1, 2, 3, 4])
        variables += variable(board + "MAC-1", [5, 6, 7, 8])
        variables += text("ssn", serial)
        variables += text("hwc", code)
        variables += text("son", "MJVE2D/")
        variables += [3] + Array("EOF".utf8)
        let size = 11 + variables.count + 4
        var store: [UInt8] = le32(0x7379_7346)
        store += [1]
        store += le32(0)
        store += [0, 0]
        store[9] = UInt8(size & 0xFF)
        store[10] = UInt8(size >> 8)
        store += variables
        store += Self.le32(Checksums.crc32(store))
        let length = 0x48 + store.count
        var header = [UInt8](repeating: 0, count: 16)
        header += NvramGuids.nvramMainStoreVolumeGuid.bytes
        header += le32(UInt32(length))
        header += le32(0)
        header += Array("_FVH".utf8)
        header += le32(0x0004_FEFF)
        header += [0x48, 0x00, 0, 0, 0, 0, 0, 0x02]
        header += le32(1)
        header += le32(UInt32(length))
        header += [UInt8](repeating: 0, count: 8)
        var sum: UInt16 = 0
        for index in stride(from: 0, to: 0x48, by: 2) {
            sum &+= UInt16(header[index]) | UInt16(header[index + 1]) << 8
        }
        let checksum = UInt16(0) &- sum
        header[0x32] = UInt8(truncatingIfNeeded: checksum)
        header[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)
        return header + store
    }

    private func parsed(serial: String = "C02TEST00G94", code: String = "0G94") throws
        -> (image: UEFIImage, node: UEFINode, reader: ImageReader) {
        let bytes = Self.image(serial: serial, code: code)
        let image = UEFIParser.parse(bytes)
        let reader = ImageReader(bytes)
        let store = try XCTUnwrap(DMIStore.all(in: image.roots, reader: reader).first)
        let node = try XCTUnwrap(image.allNodes.first { $0.kind == .sysFStore && $0.range == store.range })
        return (image, node, reader)
    }

    /// A field of the detail, or a row of its Entries table, where the
    /// area's values are.
    private func value(_ label: String, in detail: UEFINodeDetail) -> String? {
        if let field = detail.fields.first(where: { $0.label == label }) { return field.value }
        let entries = detail.tables.first { $0.title == "Entries" }
        return entries?.rows.first { $0.first?.text == label }.map { $0[1].text }
    }

    /// The detail lists the four values; a Mac's own has nothing to note.
    func testTheStoreSaysWhoseTheMacIs() throws {
        let parsed = try parsed()
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("Serial number", in: detail), "C02TEST00G94")
        XCTAssertEqual(value("Configuration code", in: detail), "0G94")
        XCTAssertEqual(value("Sales order number", in: detail), "MJVE2D/")
        XCTAssertEqual(value("MLB (board serial)", in: detail), Self.board)
        XCTAssertNil(value("Note", in: detail))
    }

    /// Each value leads to the variable it is read from — the MLB to the
    /// first named by it — and those variables say what they hold.
    func testTheTableLeadsToTheVariables() throws {
        let parsed = try parsed()
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        let entries = try XCTUnwrap(detail.tables.first { $0.title == "Entries" })
        func entry(_ named: (String) -> Bool) -> UEFIDetailTable.Target? {
            parsed.node.children.first { named($0.name) }.map { .node($0.id) }
        }
        XCTAssertEqual(entries.rowTargets, [entry { $0 == "ssn" }, entry { $0 == "hwc" }, entry { $0 == "son" },
                                            entry { $0.hasPrefix(Self.board) }])
        XCTAssertTrue(entries.rowTargets.allSatisfy { $0 != nil })
        let serial = try XCTUnwrap(parsed.node.children.first { $0.name == "ssn" })
        XCTAssertEqual(UEFITreeDisplay.name(for: serial, catalogue: .empty, in: parsed.image,
                                            reader: parsed.reader, language: .english),
                       "ssn = C02TEST00G94")
    }

    /// A placeholder serial is noted twice: its code and its factory.
    func testAPlaceholderSerialIsNoted() throws {
        let parsed = try parsed(serial: "123456789012", code: "HV2H")
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(detail.fields.filter { $0.label == "Note" }.count, 2)
    }

    /// The row answers what a bench opens it for; the menu calls it Apple
    /// DMI; `?` opens its entry.
    func testTheRowTheMenuAndTheTerm() throws {
        let parsed = try parsed()
        let name = UEFITreeDisplay.name(for: parsed.node, catalogue: .empty, in: parsed.image,
                                        reader: parsed.reader, language: .english)
        XCTAssertEqual(name, "Apple SysF store · C02TEST00G94")
        XCTAssertEqual(UEFIHelpTerms.term(for: parsed.node, in: parsed.image, reader: parsed.reader),
                       HelpTermID("apple-dmi"))
        XCTAssertNotEqual(UEFIHelpTerms.term(for: parsed.node), HelpTermID("apple-dmi"), "without the bytes, a store")
        let store = DMIStore(kind: .sysFStore, range: 0x1000..<0x1200)
        XCTAssertEqual(UEFITreeDisplay.dmiStoreTitle(store, in: .english), "Apple DMI at 0x00001000")
    }
}
