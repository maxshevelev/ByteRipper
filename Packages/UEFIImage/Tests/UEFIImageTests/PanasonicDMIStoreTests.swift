import XCTest
@testable import UEFIImage

/// Panasonic's DMI area (`PanasonicDMIStore`): a header, a directory and the
/// records it lists, read out of the padding it lies in. The format is read
/// off dumps of an FZ-55 mk2, a CF-53 mk1 and a CF-AX2, so the tests carry a
/// synthetic block of the same shape: short and long record headers, records
/// back to back and with a gap, every part summing to 0, and no real serial
/// or key.
final class PanasonicDMIStoreTests: XCTestCase {
    private static let size: UInt64 = 0x10000
    /// Where a 64 KiB chip's file offset 0 is in the CPU's view of it.
    private static let base: UInt32 = 0xFFFF_0000
    private static let serial = "TEST0000SERIAL1"
    private static let key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"

    static func put(_ bytes: inout [UInt8], _ data: [UInt8], at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + data.count), with: data)
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }

    /// The records, each `(id, offset in the block, length, long header?)`.
    private static let records: [(id: UInt32, at: Int, length: Int, long: Bool)] = [
        (0x02, 0x100, 0x80, false),
        (0x03, 0x180, 0x40, false),
        (0x15, 0x1C0, 0x108, true),   // ends at 0x2C8, the next starts at 0x2D0
        (0x16, 0x2D0, 0x39, true),    // the next starts right after it
        (0x1F, 0x309, 0x107, true)
    ]
    private static let areaLength: UInt64 = 0x410

    /// Makes the bytes of `range` sum to 0 by the byte at `at`.
    static func fix(_ bytes: inout [UInt8], _ range: Range<Int>, at: Int) {
        bytes[at] = 0
        bytes[at] = 0 &- bytes[range].reduce(0, &+)
    }

    /// The block at `offset` in the file: zero where nothing is written, as
    /// the dumps have it, every checksum holding.
    private static func block(at offset: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(areaLength))
        put(&bytes, Array("MEI_FZ55-2".utf8), at: 0)
        put(&bytes, Array("FZ55FZ-52M4".utf8), at: 0x28)
        put(&bytes, Array("MEI___CF".utf8), at: 0x3A)
        // The directory's length in 8-byte units counts its own first eight.
        put(&bytes, le16(UInt16(records.count + 1)), at: 0x80)
        for (index, record) in records.enumerated() {
            put(&bytes, le32(record.id) + le32(base + UInt32(offset + record.at)), at: 0x88 + index * 8)
            put(&bytes, record.long ? le32(UInt32(record.length)) + [0, 0x40, 0, 0] : le16(UInt16(record.length)) + [0],
                at: record.at)
        }
        put(&bytes, Array("No Asset Tag".utf8), at: 0x103)
        put(&bytes, [0x01] + Array((serial + "\r\n").utf8), at: 0x183)
        put(&bytes, le32(1) + le32(0) + le32(1) + le32(0) + le32(29) + Array(key.utf8), at: 0x2D8)
        fix(&bytes, 0..<0x80, at: 0x16)
        fix(&bytes, 0x80..<(0x88 + records.count * 8), at: 0x82)
        for record in records {
            fix(&bytes, record.at..<(record.at + record.length), at: record.at + (record.long ? 4 : 2))
        }
        return bytes
    }

    /// A 64 KiB image with no descriptor: the block at `offset`, and a volume
    /// ending in the Volume Top File flush against the image's end.
    private static func image(blockAt offset: Int = 0x8000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        put(&bytes, block(at: offset), at: offset)
        let volume = TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        return bytes
    }

    private func stores(_ parsed: UEFIImage) -> [UEFINode] {
        parsed.allNodes.filter { $0.kind == .panasonicDMIStore }
    }

    /// The block is read out of the padding it lies in, in place, as one row
    /// with its header's fields and a row per record.
    func testTheBlockIsReadOutOfPadding() throws {
        let parsed = UEFIParser.parse(Self.image())
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(stores(parsed).count, 1)
        XCTAssertEqual(store.range, 0x8000..<(0x8000 + Self.areaLength))
        XCTAssertEqual(store.name, "Panasonic DMI")
        XCTAssertTrue(store.isFixed)
        XCTAssertEqual(store.children.map(\.name),
                       ["Model", "Model code", "Record 0x02", "Record 0x03", "Record 0x15", "Record 0x16", "Record 0x1F"])
        let records = store.children.filter { $0.kind == .panasonicDMIRecord }
        XCTAssertEqual(records.map(\.subtype), [0x02, 0x03, 0x15, 0x16, 0x1F])
        XCTAssertEqual(records.map(\.header), [0x8100..<0x8103, 0x8180..<0x8183, 0x81C0..<0x81C8,
                                               0x82D0..<0x82D8, 0x8309..<0x8311])
        XCTAssertEqual(records.map(\.range.upperBound), [0x8180, 0x81C0, 0x82C8, 0x8309, 0x8410])
        XCTAssertEqual(records.map { $0.children.map(\.name) },
                       [["Asset tag"], ["Serial"], [], ["Windows product key"], []])
        let outer = try XCTUnwrap(parsed.roots[0].children.first { $0.range.contains(0x8000) })
        XCTAssertEqual(outer.children.map(\.kind), [.padding, .panasonicDMIStore, .padding])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    func testTheFieldsAreRead() throws {
        let bytes = Self.image()
        let area = try XCTUnwrap(PanasonicDMIArea.read(at: 0x8000, end: 0xF000, reader: ImageReader(bytes)))
        XCTAssertEqual(area.model, "FZ55-2")
        XCTAssertEqual(area.modelCode, "FZ55FZ-52M4")
        XCTAssertEqual(area.assetTag, "No Asset Tag")
        XCTAssertEqual(area.serial, Self.serial, "to the line end")
        XCTAssertEqual(area.productKey, Self.key)
        XCTAssertEqual(area.records.map(\.headerSize), [3, 3, 8, 8, 8])
        XCTAssertTrue(area.headerChecksumIsValid)
        XCTAssertTrue(area.directoryChecksumIsValid)
        XCTAssertTrue(area.records.allSatisfy(\.checksumIsValid))
        let parsed = UEFIParser.parse(bytes)
        let reader = ImageReader(bytes)
        let values = parsed.allNodes.filter { $0.kind == .dmiField }.compactMap { DMIField.text(of: $0, reader: reader) }
        XCTAssertEqual(values, ["FZ55-2", "FZ55FZ-52M4", "No Asset Tag", Self.serial, Self.key])
    }

    /// To UEFITool these bytes are padding.
    func testTheStoreClassifiesAsPadding() throws {
        let store = try XCTUnwrap(stores(UEFIParser.parse(Self.image())).first)
        for node in store.flattened {
            XCTAssertEqual(node.uefiItemType, UEFITypes.Item.padding.rawValue, "\(node.kind)")
        }
    }

    func testTheDMIStoresSeeTheBlock() throws {
        let parsed = UEFIParser.parse(Self.image())
        XCTAssertEqual(DMIStore.all(in: parsed.roots),
                       [DMIStore(kind: .panasonicDMIStore, range: 0x8000..<(0x8000 + Self.areaLength))])
    }

    // MARK: - What is not one

    /// The signature alone is not a block: a directory whose records do not
    /// chain is padding still, and leaves no diagnostic behind.
    func testABrokenChainIsNotRead() throws {
        func parse(_ mutate: (inout [UInt8]) -> Void) -> UEFIImage {
            var bytes = Self.image()
            mutate(&bytes)
            return UEFIParser.parse(bytes)
        }
        var parsed = parse { $0[0x8180] = 0x50 } // record 0x03's length overruns the next
        XCTAssertTrue(stores(parsed).isEmpty, "a length that does not end where the next starts")
        parsed = parse { Self.put(&$0, Self.le32(Self.base + 0x8100), at: 0x8094) } // two records at one place
        XCTAssertTrue(stores(parsed).isEmpty, "addresses that do not rise")
        parsed = parse { Self.put(&$0, Self.le16(2), at: 0x8080) } // one record listed
        XCTAssertTrue(stores(parsed).isEmpty, "a directory of one")
        parsed = parse { $0[0x8000] = 0x4E } // "NEI_"
        XCTAssertTrue(stores(parsed).isEmpty, "no signature")
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// A start not on a 4 KiB boundary is not read.
    func testAnUnalignedStartIsNotRead() throws {
        XCTAssertTrue(stores(UEFIParser.parse(Self.image(blockAt: 0x8800))).isEmpty)
    }

    /// A key that does not read as one is not shown as one: the record stays,
    /// the field does not.
    func testAKeyThatIsNotOneIsNotAField() throws {
        var bytes = Self.image()
        bytes[0x82EC + 5] = 0x41 // the first dash
        let area = try XCTUnwrap(PanasonicDMIArea.read(at: 0x8000, end: 0xF000, reader: ImageReader(bytes)))
        XCTAssertNil(area.productKey)
        XCTAssertEqual(area.records.count, 5)
    }

    /// A checksum that fails does not hide the block: it is read, and says
    /// which sum fails and what the byte should be.
    func testAFailingChecksumIsReadAndSaid() throws {
        var bytes = Self.image()
        bytes[0x8183 + 1] = 0x58 // the serial's first character, its sum left as it was
        bytes[0x8084] = 0x01     // the directory's reserved word, its sum left as it was
        let area = try XCTUnwrap(PanasonicDMIArea.read(at: 0x8000, end: 0xF000, reader: ImageReader(bytes)))
        XCTAssertTrue(area.headerChecksumIsValid)
        XCTAssertFalse(area.directoryChecksumIsValid)
        XCTAssertEqual(area.expectedDirectoryChecksum, area.directoryChecksum &- 1)
        let serial = try XCTUnwrap(area.record(0x03))
        XCTAssertFalse(serial.checksumIsValid)
        XCTAssertEqual(serial.expectedChecksum, serial.checksum &- (0x58 &- 0x54))
        XCTAssertEqual(area.records.filter { !$0.checksumIsValid }.map(\.id), [0x03])
    }
}
