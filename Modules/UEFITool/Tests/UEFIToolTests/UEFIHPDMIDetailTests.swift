import HelpBook
import Localization
import UEFIImage
import XCTest
@testable import UEFITool

/// HP's DMI on the `HP_MUD` entry: the row says the serial, the detail lists
/// what BCU reports, the DMI menu names it, and `?` opens its entry. The
/// format is `UEFIImage`'s and tested there.
final class UEFIHPDMIDetailTests: XCTestCase {
    private static let serial = "5CDTEST001"

    private static func utf16(_ text: String, size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        for (index, unit) in text.utf16.enumerated() {
            bytes[2 * index] = UInt8(truncatingIfNeeded: unit)
            bytes[2 * index + 1] = UInt8(truncatingIfNeeded: unit >> 8)
        }
        return bytes
    }

    private static func mud() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: HPDMIArea.mudSize)
        func put(_ text: String, at offset: Int) {
            let units = utf16(text, size: 2 * text.count)
            bytes.replaceSubrange(offset..<(offset + units.count), with: units)
        }
        put(serial, at: 0x000)
        put("TEST123#ABD", at: 0x042)
        put("103C_5336AN HP EliteBook", at: 0x0A4)
        put("PTXTEST01JK100B", at: 0x106)
        put("HP EliteBook Test", at: 0x124)
        bytes.replaceSubrange(0x19E..<0x1AE, with: [0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0x88, 0x47,
                                                    0x89, 0xCD, 0xEF, 0x01, 0x02, 0x03, 0x04, 0x05])
        return bytes
    }

    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// A VSS2 variable as HP writes one: the 60-byte authenticated header,
    /// attributes 07.
    private static func variable(_ name: String, _ data: [UInt8], guid: EFIGUID, state: UInt8) -> [UInt8] {
        let nameBytes = utf16(name, size: 2 * name.count + 2)
        var bytes: [UInt8] = [0xAA, 0x55, state, 0] + le32(7)
        bytes += [UInt8](repeating: 0, count: 28)   // counter, timestamp, key index
        bytes += le32(UInt32(nameBytes.count)) + le32(UInt32(data.count)) + guid.bytes + nameBytes + data
        while bytes.count % 4 != 0 { bytes.append(0xFF) }
        return bytes
    }

    /// An NVRAM volume holding one VSS2 store of HP's variables.
    private static func image(mudState: UInt8) -> [UInt8] {
        let variables = variable("BuildId", utf16("24WWTEST602#SABD#DABD", size: 112), guid: HPDMIArea.factoryGuid, state: 0x3F)
            + variable("FactoryConfig", utf16("476J6S6b.TR", size: 500), guid: HPDMIArea.factoryGuid, state: 0x3F)
            + variable(HPDMIArea.mudName, mud(), guid: HPDMIArea.factoryGuid, state: mudState)
            + variable("HP_TAGS", utf16(serial, size: 324), guid: HPDMIArea.settingsGuid, state: 0x3F)
        let storeSize = 28 + variables.count + 0x40
        var store = NvramGuids.nvramVss2StoreGuid.bytes + le32(UInt32(storeSize)) + [0x5A, 0xFE, 0, 0] + le32(0)
        store += variables + [UInt8](repeating: 0xFF, count: 0x40)
        let length = 0x48 + store.count
        var header = [UInt8](repeating: 0, count: 16) + NvramGuids.nvramMainStoreVolumeGuid.bytes
        header += le32(UInt32(length)) + le32(0) + Array("_FVH".utf8) + le32(0x0004_FEFF)
        header += [0x48, 0x00, 0, 0, 0, 0, 0, 0x02] + le32(1) + le32(UInt32(length)) + [UInt8](repeating: 0, count: 8)
        var sum: UInt16 = 0
        for index in stride(from: 0, to: 0x48, by: 2) {
            sum &+= UInt16(header[index]) | UInt16(header[index + 1]) << 8
        }
        let checksum = UInt16(0) &- sum
        header[0x32] = UInt8(truncatingIfNeeded: checksum)
        header[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)
        return header + store
    }

    private func parsed(mudState: UInt8 = 0x3F) throws -> (image: UEFIImage, node: UEFINode, reader: ImageReader) {
        let bytes = Self.image(mudState: mudState)
        let image = UEFIParser.parse(bytes)
        let reader = ImageReader(bytes)
        let store = try XCTUnwrap(DMIStore.all(in: image.roots, reader: reader).first)
        let node = try XCTUnwrap(image.allNodes.first { $0.kind == .vssEntry && $0.range == store.range })
        return (image, node, reader)
    }

    /// A field of the detail, or a row of its Entries table, where the
    /// area's values are.
    private func value(_ label: String, in detail: UEFINodeDetail) -> String? {
        if let field = detail.fields.first(where: { $0.label == label }) { return field.value }
        let entries = detail.tables.first { $0.title == "Entries" }
        return entries?.rows.first { $0.first?.text == label }.map { $0[1].text }
    }

    /// The fields of `HP_MUD` are rows under its entry, each saying what it
    /// holds; the table's values lead to those rows, and the three read from
    /// the variables beside it to those variables' entries.
    func testTheFieldsAreRowsAndTheTableLeadsToThem() throws {
        let parsed = try parsed()
        let fields = parsed.node.children
        XCTAssertEqual(fields.map(\.kind), Array(repeating: .dmiField, count: 6))
        XCTAssertEqual(fields.map(\.name), ["Serial number", "SKU", "Product family", "CT number", "Product name", "UUID"])
        XCTAssertEqual(UEFITreeDisplay.name(for: fields[0], catalogue: .empty, in: parsed.image,
                                            reader: parsed.reader, language: .english),
                       "Serial number = \(Self.serial)")
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        let entries = try XCTUnwrap(detail.tables.first { $0.title == "Entries" })
        let store = try XCTUnwrap(parsed.image.node(NodeID(Array(parsed.node.id.path.dropLast()))))
        func entry(_ name: String) -> UEFIDetailTable.Target? {
            store.children.first { $0.name == name }.map { .node($0.id) }
        }
        XCTAssertEqual(entries.rowTargets, fields.map { .node($0.id) } + [entry("BuildId"), entry("FactoryConfig"), entry("HP_TAGS")])
        XCTAssertTrue(entries.rowTargets.allSatisfy { $0 != nil })
    }

    /// The detail lists what BCU reports, in its order; a current copy whose
    /// asset tag is the serial has nothing to note.
    func testTheEntrySaysWhoTheMachineIs() throws {
        let parsed = try parsed()
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("Serial number", in: detail), Self.serial)
        XCTAssertEqual(value("SKU", in: detail), "TEST123#ABD")
        XCTAssertEqual(value("Product family", in: detail), "103C_5336AN HP EliteBook")
        XCTAssertEqual(value("CT number", in: detail), "PTXTEST01JK100B")
        XCTAssertEqual(value("Product name", in: detail), "HP EliteBook Test")
        XCTAssertEqual(value("UUID", in: detail), "78563412-AB90-4788-89CD-EF0102030405")
        XCTAssertEqual(value("Build ID", in: detail), "24WWTEST602#SABD#DABD")
        XCTAssertEqual(value("Feature byte", in: detail), "476J6S6b.TR")
        XCTAssertEqual(value("Asset tracking number", in: detail), Self.serial)
        XCTAssertNil(value("Note", in: detail))
    }

    /// A copy the store marks deleted is read all the same, and says so.
    func testADeletedCopyIsReadAndNoted() throws {
        let parsed = try parsed(mudState: 0x3C)
        XCTAssertEqual(parsed.node.name, "Invalid", "UEFITool's name for a marked entry")
        let detail = UEFIDetail.build(for: parsed.node, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertEqual(value("Serial number", in: detail), Self.serial)
        XCTAssertEqual(detail.fields.filter { $0.label == "Note" }.count, 1)
        XCTAssertEqual(detail.fields.filter(\.isProblem).count, 0)
    }

    /// The row answers what a bench opens it for, on a marked copy too; the
    /// menu calls it HP DMI; `?` opens HP's entry.
    func testTheRowTheMenuAndTheTerm() throws {
        for state: UInt8 in [0x3F, 0x3C] {
            let parsed = try parsed(mudState: state)
            let name = UEFITreeDisplay.name(for: parsed.node, catalogue: .empty, in: parsed.image,
                                            reader: parsed.reader, language: .english)
            XCTAssertEqual(name, "HP_MUD · \(Self.serial)")
            XCTAssertEqual(UEFIHelpTerms.term(for: parsed.node, in: parsed.image, reader: parsed.reader),
                           HelpTermID("hp-dmi"))
            XCTAssertEqual(UEFIHelpTerms.term(for: parsed.node), HelpTermID("vss"), "without the bytes, a VSS entry")
        }
        let store = DMIStore(kind: .vssEntry, range: 0x1000..<0x1200)
        XCTAssertEqual(UEFITreeDisplay.dmiStoreTitle(store, in: .english), "HP DMI at 0x00001000")
    }

    /// Another variable of HP's factory GUID is an ordinary VSS entry.
    func testTheOtherEntriesAreOrdinary() throws {
        let parsed = try parsed()
        let buildID = try XCTUnwrap(parsed.image.allNodes.first { $0.kind == .vssEntry && $0.name == "BuildId" })
        let detail = UEFIDetail.build(for: buildID, image: parsed.image, reader: parsed.reader, in: .english)
        XCTAssertNil(value("Serial number", in: detail))
        XCTAssertEqual(UEFIHelpTerms.term(for: buildID, in: parsed.image, reader: parsed.reader), HelpTermID("vss"))
    }
}
