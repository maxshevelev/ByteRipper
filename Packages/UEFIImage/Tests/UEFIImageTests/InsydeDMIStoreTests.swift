import XCTest
@testable import UEFIImage

/// InsydeH2O's `$DMI` store (`InsydeDMIStore`): the signature, records of
/// {type, field offset, flag, u16 length} back to back, then FF. The format
/// is read off Huawei, Acer and Schenker boards, so the tests carry a
/// synthetic store of the same shape — a log in which every field has one
/// record in force (FF) and the records it replaced read 00, a value written
/// again later with another text — and no real serial.
final class InsydeDMIStoreTests: XCTestCase {
    private static let size: UInt64 = 0x10000
    private static let uuid: [UInt8] = [0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66,
                                        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]

    static func put(_ bytes: inout [UInt8], _ data: [UInt8], at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + data.count), with: data)
    }

    static func record(_ type: UInt8, _ field: UInt8, _ flag: UInt8, _ value: [UInt8]) -> [UInt8] {
        let length = 5 + value.count
        return [type, field, flag, UInt8(length & 0xFF), UInt8(length >> 8)] + value
    }

    static func text(_ type: UInt8, _ field: UInt8, _ value: String) -> [UInt8] {
        record(type, field, 0x00, Array(value.utf8)) + record(type, field, 0xFF, Array(value.utf8))
    }

    /// The records: the product, the system serial, the UUID, the board
    /// serial, an OEM string, then the product written again with another
    /// text — both of its first two records replaced.
    private static let records: [UInt8] =
        record(1, 0x05, 0x00, Array("TEST-PRODUCT".utf8)) + record(1, 0x05, 0x00, Array("TEST-PRODUCT".utf8))
        + text(1, 0x07, "TESTSERIAL0001")
        + record(1, 0x08, 0x00, uuid) + record(1, 0x08, 0xFF, uuid)
        + text(2, 0x07, "TESTBOARD0001")
        + text(11, 0x05, "$TEST001")
        + text(1, 0x05, "TEST-PRODUCT-2")

    /// The store: the signature and `records`, FF to 4 KiB.
    private static func store(_ records: [UInt8] = records) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: 0x1000)
        put(&bytes, Array("$DMI".utf8) + records, at: 0)
        return bytes
    }

    /// A 64 KiB image with no descriptor: `stores` at their offsets, and a
    /// volume ending in the Volume Top File flush against the image's end.
    private static func image(_ stores: [(at: Int, bytes: [UInt8])] = [(0x8000, store())]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        for store in stores { put(&bytes, store.bytes, at: store.at) }
        let volume = TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        return bytes
    }

    private func stores(_ parsed: UEFIImage) -> [UEFINode] {
        parsed.allNodes.filter { $0.kind == .insydeDMIStore }
    }

    /// The store is read out of the padding it lies in, in place: a row from
    /// the signature to the end of its records, and a row per record named by
    /// the field it writes, with nothing under it.
    func testTheStoreIsReadOutOfPadding() throws {
        let parsed = UEFIParser.parse(Self.image())
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(stores(parsed).count, 1)
        XCTAssertEqual(store.range, 0x8000..<(0x8004 + UInt64(Self.records.count)))
        XCTAssertEqual(store.name, "Insyde DMI")
        XCTAssertTrue(store.isFixed)
        XCTAssertEqual(store.children.count, 12)
        XCTAssertEqual(store.children.map(\.subtype), [1, 1, 1, 1, 1, 1, 2, 2, 11, 11, 1, 1])
        XCTAssertEqual(store.children.map(\.name).prefix(10),
                       ["Product name", "Product name", "System serial number", "System serial number",
                        "UUID", "UUID", "Board serial number", "Board serial number", "OEM string", "OEM string"])
        XCTAssertEqual(store.children[0].header, 0x8004..<0x8009)
        XCTAssertTrue(store.children.allSatisfy { $0.children.isEmpty })
        let outer = try XCTUnwrap(parsed.roots[0].children.first { $0.range.contains(0x8000) })
        XCTAssertEqual(outer.children.map(\.kind), [.padding, .insydeDMIStore, .padding])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// One value per field, from the record in force; the UUID as SMBIOS
    /// stores one.
    func testTheFieldsAreTheRecordsInForce() throws {
        let bytes = Self.image()
        let reader = ImageReader(bytes)
        let area = try XCTUnwrap(InsydeDMIArea.read(at: 0x8000, end: 0xF000, reader: reader))
        XCTAssertEqual(area.records.map(\.flag), [0, 0, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF])
        XCTAssertTrue(area.fieldsWithoutOneCurrent.isEmpty)
        let values = area.fields.map { DMIField.text(of: reader.bytes($0.range)!, as: $0.encoding) }
        XCTAssertEqual(values, ["TEST-PRODUCT-2", "TESTSERIAL0001", "00112233-4455-6677-8899-AABBCCDDEEFF",
                                "TESTBOARD0001", "$TEST001"])
        XCTAssertEqual(area.fields.map { $0.name.text(in: .english) },
                       ["Product name", "System serial number", "UUID", "Board serial number", "OEM string"])
        XCTAssertEqual(area.text(type: 1, field: 0x05, reader: reader), "TEST-PRODUCT-2")
    }

    /// The record in force is the one marked FF, wherever it lies; a field
    /// with none marked, or two, is read from its last record and named.
    func testTheFlagDecidesNotThePlace() throws {
        let reader = { (records: [UInt8]) in ImageReader(Self.image([(0x8000, Self.store(records))])) }
        let marked = Self.record(1, 0x07, 0xFF, Array("FIRST".utf8)) + Self.record(1, 0x07, 0x00, Array("SECOND".utf8))
        var area = try XCTUnwrap(InsydeDMIArea.read(at: 0x8000, end: 0xF000, reader: reader(marked)))
        XCTAssertEqual(area.text(type: 1, field: 0x07, reader: reader(marked)), "FIRST")
        let unmarked = Self.record(1, 0x07, 0x00, Array("FIRST".utf8)) + Self.record(1, 0x07, 0x00, Array("SECOND".utf8))
        area = try XCTUnwrap(InsydeDMIArea.read(at: 0x8000, end: 0xF000, reader: reader(unmarked)))
        XCTAssertEqual(area.text(type: 1, field: 0x07, reader: reader(unmarked)), "SECOND")
        XCTAssertEqual(area.fieldsWithoutOneCurrent.map { $0.text(in: .english) }, ["System serial number"])
    }

    /// A store with no record — the signature and FF — is a row of its own,
    /// with nothing under it.
    func testAnEmptyStoreIsRead() throws {
        let parsed = UEFIParser.parse(Self.image([(0x8000, Self.store([]))]))
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(store.range, 0x8000..<0x8004)
        XCTAssertTrue(store.children.isEmpty)
        XCTAssertEqual(DMIStore.all(in: parsed.roots), [DMIStore(kind: .insydeDMIStore, range: 0x8000..<0x8004)],
                       "alone, an empty store is where the button goes")
    }

    /// An empty store beside a filled one is not where the DMI button goes.
    func testAnEmptyStoreGivesWayToAFilledOne() throws {
        let parsed = UEFIParser.parse(Self.image([(0x4000, Self.store([])), (0x8000, Self.store())]))
        XCTAssertEqual(stores(parsed).count, 2)
        XCTAssertEqual(DMIStore.all(in: parsed.roots).map(\.range.lowerBound), [0x8000])
    }

    /// To UEFITool these bytes are padding.
    func testTheStoreClassifiesAsPadding() throws {
        let store = try XCTUnwrap(stores(UEFIParser.parse(Self.image())).first)
        for node in store.flattened {
            XCTAssertEqual(node.uefiItemType, UEFITypes.Item.padding.rawValue, "\(node.kind)")
        }
    }

    // MARK: - What is not one

    /// The signature alone is not a store: records that do not chain, or
    /// bytes after them that are not FF, leave padding and no diagnostic.
    func testABrokenStoreIsNotRead() throws {
        func parse(_ mutate: (inout [UInt8]) -> Void) -> UEFIImage {
            var store = Self.store()
            mutate(&store)
            return UEFIParser.parse(Self.image([(0x8000, store)]))
        }
        var parsed = parse { $0[0x4 + 3] = 0x02 } // a length shorter than its header
        XCTAssertTrue(stores(parsed).isEmpty, "a length below 5")
        parsed = parse { $0[0x4 + 3] = 0xFF; $0[0x4 + 4] = 0x0F } // past the store's 4 KiB
        XCTAssertTrue(stores(parsed).isEmpty, "a length that overruns the store")
        parsed = parse { $0[0x800] = 0x00 } // a byte behind the records
        XCTAssertTrue(stores(parsed).isEmpty, "something after the records")
        parsed = parse { $0[0] = 0x25 } // "%DMI"
        XCTAssertTrue(stores(parsed).isEmpty, "no signature")
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// A start not on a 4 KiB boundary is not read.
    func testAnUnalignedStartIsNotRead() throws {
        XCTAssertTrue(stores(UEFIParser.parse(Self.image([(0x8800, Self.store())]))).isEmpty)
    }
}
