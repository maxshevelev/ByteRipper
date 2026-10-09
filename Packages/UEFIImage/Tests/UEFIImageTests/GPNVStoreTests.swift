import XCTest
@testable import UEFIImage

/// AMI's GPNV store (`GPNVRecord`): read where ASUS puts it — after the free
/// space of a volume of its own, and in padding — as a row with a row per
/// record, and nowhere else.
final class GPNVStoreTests: XCTestCase {
    /// A record as the dumps lay one out: 0x100 bytes of data, FF where
    /// nothing is written.
    private func record(_ name: String, current: Bool, data: [UInt8] = [], length: UInt16 = 0x10C) -> [UInt8] {
        var w = BinaryWriter()
        w.raw(Array("GPNV".utf8))
        w.u16(length)
        w.u8(current ? 1 : 0)
        w.raw(Array(name.utf8))
        w.u8(0)
        w.raw(data)
        w.pad(to: UInt64(length), with: 0xFF)
        return w.bytes
    }

    private var records: [UInt8] {
        record("MFG0", current: false, data: Array("M8NRKD00311031C".utf8))
            + record("OA30", current: true, data: msdm("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"))
            + record("MFG0", current: true, data: Array("M8NRKD00311031C".utf8))
    }

    private func msdm(_ key: String) -> [UInt8] {
        var w = BinaryWriter()
        w.u32(1); w.u32(0); w.u32(1); w.u32(0)
        w.u32(UInt32(key.utf8.count))
        w.raw(Array(key.utf8))
        return w.bytes
    }

    /// The AMD board's layout: a volume holding no files, free space where
    /// the first file would be, and the store after it.
    func testAStoreAfterAVolumesFreeSpaceIsItsData() throws {
        let gpnv = KnownGUIDs.guid("3F8E4F19-8523-407F-8ACB-C562F5A36D35")
        let free = [UInt8](repeating: 0xFF, count: 0x78 - 0x5C)
        let bytes = TestImage.image(TestImage.volume(length: 0x1000, extendedHeader: gpnv, trailing: free + records))
        let parsed = UEFIParser.parse(bytes)

        let store = try XCTUnwrap(parsed.allNodes.first { $0.kind == .gpnvStore })
        XCTAssertEqual(store.range, 0x78..<(0x78 + 3 * 0x10C))
        XCTAssertEqual(store.uefiItemType, UEFITypes.Item.padding.rawValue)
        let parent = try XCTUnwrap(parsed.nodes(containing: 0x78).dropLast(2).last)
        XCTAssertEqual(parent.kind, .nonUEFIData, "the store is what the data is")
        XCTAssertEqual(store.children.map(\.name), ["MFG0", "OA30", "MFG0"])
        XCTAssertEqual(store.children.map(\.subtype), [0, 1, 1], "the record in force, and the one it replaced")
        XCTAssertEqual(store.children[0].header, 0x78..<0x84)
        XCTAssertEqual(store.children[0].body, 0x84..<0x184)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// The Intel board's: in the padding after NVRAM, on a 4 KiB boundary.
    func testAStoreInPaddingIsReadOutOfIt() throws {
        var bytes = TestImage.image(TestImage.volume(length: 0x1000), after: 0x3000)
        bytes.replaceSubrange(0x2000..<(0x2000 + records.count), with: records)
        let parsed = UEFIParser.parse(bytes)

        let store = try XCTUnwrap(parsed.allNodes.first { $0.kind == .gpnvStore })
        XCTAssertEqual(store.range, 0x2000..<(0x2000 + 3 * 0x10C))
        let padding = try XCTUnwrap(parsed.nodes(containing: 0x2000).dropLast(2).last)
        XCTAssertEqual(padding.kind, .padding)
        XCTAssertEqual(padding.range, 0x1000..<0x4000, "the padding keeps its place and range")
        XCTAssertEqual(padding.children.map(\.kind), [.padding, .gpnvStore, .padding])
    }

    /// ASUS's store is where the board's identity is, as Lenovo's is.
    func testTheStoreIsADMIStore() {
        var bytes = TestImage.image(TestImage.volume(length: 0x1000), after: 0x3000)
        bytes.replaceSubrange(0x2000..<(0x2000 + records.count), with: records)
        XCTAssertEqual(DMIStore.all(in: UEFIParser.parse(bytes).roots),
                       [DMIStore(kind: .gpnvStore, range: 0x2000..<(0x2000 + 3 * 0x10C))])
    }

    /// A header that is nearly one — a state that is neither, a length past
    /// the end — is not a store, and nothing is said about it.
    func testANearMissIsNoStore() {
        var state = record("MFG0", current: true)
        state[6] = 2
        let long = record("MFG0", current: true, length: 0x10C)
        for (bytes, limit) in [(state, UInt64(state.count)), (long, UInt64(long.count - 1))] {
            XCTAssertNil(GPNVRecord.read(at: 0, limit: limit, in: ImageReader(bytes)))
        }
        var image = TestImage.image(TestImage.volume(length: 0x1000), after: 0x3000)
        image.replaceSubrange(0x2000..<(0x2000 + state.count), with: state)
        XCTAssertFalse(UEFIParser.parse(image).allNodes.contains { $0.kind == .gpnvStore })
    }

    func testTheWindowsKeyAndTheTextsAreRead() {
        XCTAssertEqual(GPNVRecord.productKey(of: msdm("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE")),
                       "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE")
        XCTAssertNil(GPNVRecord.productKey(of: [UInt8](repeating: 0xFF, count: 0x100)))

        let body = Array("M8NRKD".utf8) + [0xFF, 0xFF, 0x41, 0xFF] + Array("90NR0551 ".utf8) + [0]
        XCTAssertEqual(GPNVRecord.texts(in: body).map(\.offset), [0, 10], "a lone letter is not text")
        XCTAssertEqual(GPNVRecord.texts(in: body).map(\.text), ["M8NRKD", "90NR0551"])
    }
}
