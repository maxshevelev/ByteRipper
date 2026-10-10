import XCTest
@testable import UEFIImage

/// Acer's DMI area (`AcerDMIStore`): an 8 KiB block of the machine's identity
/// read out of the padding it lies in. The format is read off the dumps it was
/// surveyed from, so the tests carry a synthetic block that holds the
/// factory patterns.
final class AcerDMIStoreTests: XCTestCase {
    private static let size: UInt64 = 0x10000

    /// 22 alphanumerics: "N" first, "00" at 7, "3400" at the end.
    private static let serial = "N51TEST000000000003400"
    /// 22 alphanumerics: "NB" first, "1100" at 5, "3400" at the end.
    private static let tag = "NB2TE11000000000003400"
    /// Version 1, variant 1; the last six bytes are the tail the block copies.
    private static let uuid: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0x17, 0x88, 0x89, 0xCD,
                                        0xEF, 0x01, 0x02, 0x03, 0x04, 0x05]
    /// The Insyde flash device map's name for the bytes it carves out of the
    /// padding with no type of its own — where it lays the Acer DMI area.
    private static let unusedRegion = KnownGUIDs.guid("13C8B020-4F27-453B-8F80-1BFCA187380F")

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

    /// A 64 KiB image with no descriptor: the block at `offset`, and a volume
    /// ending in the Volume Top File flush against the image's end.
    private static func image(blockAt offset: Int = 0x8000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: Int(size))
        bytes.replaceSubrange(offset..<(offset + block().count), with: block())
        let volume = TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile())
        bytes.replaceSubrange(0xF000..<0x10000, with: volume)
        return bytes
    }

    /// The image above with an Insyde flash device map at `0x4000` that names
    /// the block's eight kilobytes as an "Unused" region — how the Insyde map
    /// lays the area out of the padding.
    private static func imageWithUnusedMap(blockAt offset: Int = 0x8000) -> [UInt8] {
        var bytes = image(blockAt: offset)
        let map = TestFlashDeviceMap.map(
            [(unusedRegion, UInt64(offset), AcerDMIArea.size)],
            base: 0x1_0000_0000 - size
        )
        bytes.replaceSubrange(0x4000..<(0x4000 + map.count), with: map)
        return bytes
    }

    private func stores(_ parsed: UEFIImage) -> [UEFINode] {
        parsed.allNodes.filter { $0.kind == .acerDMIStore }
    }

    /// The block is read out of the padding it lies in, in place, as one row.
    func testTheBlockIsReadOutOfPadding() throws {
        let parsed = UEFIParser.parse(Self.image())
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(stores(parsed).count, 1)
        XCTAssertEqual(store.range, 0x8000..<0xA000)
        XCTAssertEqual(store.name, "Acer DMI")
        XCTAssertTrue(store.isFixed, "the firmware finds it where the layout puts it")
        XCTAssertTrue(store.children.isEmpty, "one blob, no rows of its own")
        let outer = try XCTUnwrap(parsed.roots[0].children.first { $0.range.contains(0x8000) })
        XCTAssertEqual(outer.kind, .padding)
        XCTAssertEqual(outer.children.map(\.kind), [.padding, .acerDMIStore, .padding])
        XCTAssertEqual(outer.children.first?.range.upperBound, 0x8000)
        XCTAssertEqual(outer.children.last?.range.lowerBound, 0xA000)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// Where the Insyde flash device map carves the block out of the padding
    /// and names it "Unused", it is read the same way — a row inside the
    /// region, not lost in the padding the region replaced.
    func testTheBlockIsReadOutOfAMapRegion() throws {
        let parsed = UEFIParser.parse(Self.imageWithUnusedMap(blockAt: 0x8000))
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(stores(parsed).count, 1)
        XCTAssertEqual(store.range, 0x8000..<0xA000)
        XCTAssertEqual(store.name, "Acer DMI")
        let region = try XCTUnwrap(
            parsed.allNodes.first { $0.kind == .flashDeviceMapRegion && $0.range == 0x8000..<0xA000 }
        )
        XCTAssertEqual(region.name, "Unused")
        XCTAssertEqual(region.children.map(\.kind), [.acerDMIStore])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// The one board whose block is 4 KiB-aligned but not 8 KiB-aligned: a
    /// start at 0x9000 reads the same way.
    func testAStartNotEightKAlignedIsRead() throws {
        let parsed = UEFIParser.parse(Self.image(blockAt: 0x9000))
        let store = try XCTUnwrap(stores(parsed).first)
        XCTAssertEqual(store.range, 0x9000..<0xB000)
    }

    /// To UEFITool these bytes are padding, as a GPNV store's are.
    func testTheStoreClassifiesAsPadding() throws {
        let store = try XCTUnwrap(stores(UEFIParser.parse(Self.image())).first)
        for node in store.flattened {
            XCTAssertEqual(node.uefiItemType, UEFITypes.Item.padding.rawValue, "\(node.kind)")
        }
    }

    /// The bench's "show the DMI area" finds the row wherever it lies.
    func testTheDMIStoresSeeTheBlock() throws {
        let parsed = UEFIParser.parse(Self.image())
        XCTAssertEqual(DMIStore.all(in: parsed.roots),
                       [DMIStore(kind: .acerDMIStore, range: 0x8000..<0xA000)])
    }

    /// The tree finds the store without the panel opening the way to it:
    /// a copy with every container in the file opened says where it is.
    @MainActor
    func testTheTreeFindsTheStoreWhereverItLies() async {
        let tree = LazyUEFITree(Self.image())
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveDMIStores { continuation.resume() } }
        XCTAssertEqual(tree.dmiStores, [DMIStore(kind: .acerDMIStore, range: 0x8000..<0xA000)])
    }

    // MARK: - The checks a wiped or tampered block fails

    /// A wiped dump is an all-FF block: no signature, no row.
    func testAWipedBlockIsNotRead() throws {
        var bytes = Self.image()
        bytes.replaceSubrange(0x8000..<0xA000, with: [UInt8](repeating: 0xFF, count: Int(AcerDMIArea.size)))
        let parsed = UEFIParser.parse(bytes)
        XCTAssertTrue(stores(parsed).isEmpty)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// The checks, one at a time: a signature whose surroundings fail one of
    /// them is padding still, and leaves no diagnostic behind.
    func testATamperedBlockIsNotRead() throws {
        func parse(_ mutate: (inout [UInt8]) -> Void) -> UEFIImage {
            var bytes = Self.image()
            mutate(&bytes)
            return UEFIParser.parse(bytes)
        }
        let at = 0x8000
        var parsed = parse { $0[at + 0x00] = 0x58 } // the serial does not start with "N"
        XCTAssertTrue(stores(parsed).isEmpty, "the serial is not one")
        parsed = parse {
            $0.replaceSubrange(at + 0x50..<(at + 0x50 + 22), with: Array("MB2TE11000000000003400".utf8))
        }
        XCTAssertTrue(stores(parsed).isEmpty, "the service tag is not one")
        parsed = UEFIParser.parse(Self.image(blockAt: 0x9800)) // a start not 4 KiB-aligned
        XCTAssertTrue(stores(parsed).isEmpty, "the start is not aligned")
        parsed = parse { $0[at + 0x200] = 0x42 } // data where only padding may be
        XCTAssertTrue(stores(parsed).isEmpty, "the block is not sparse")
    }

    /// A block whose eight kilobytes do not fit before the padding ends is
    /// not read: the signature is there, the block is not.
    func testABlockThatOverrunsThePaddingIsNotRead() throws {
        let parsed = UEFIParser.parse(Self.image(blockAt: 0xE000))
        XCTAssertTrue(stores(parsed).isEmpty)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    // MARK: - The fields, read off the block

    func testTheFieldsAreReadOffTheBlock() throws {
        let area = try XCTUnwrap(AcerDMIArea.found(stored: Self.block(), offset: 0x8000))
        XCTAssertEqual(area.systemSerial, Self.serial)
        XCTAssertEqual(area.serviceTag, Self.tag)
        XCTAssertEqual(area.uuid, Self.uuid)
        XCTAssertEqual(area.uuidText, "78563412-AB90-1788-89CD-EF0102030405")
        XCTAssertEqual(area.model, "TEST-1050")
        XCTAssertEqual(area.productName, "Test Model")
        XCTAssertNil(area.assetTag, "its padding is no asset tag")
        XCTAssertNil(area.manufacturingCode, "not written in this block")
    }

    func testTheAssetTagAndTheManufacturingCodeAreReadWhereWritten() throws {
        var bytes = Self.block()
        Self.put(&bytes, "Asset0001", at: 0xA0)
        Self.put(&bytes, "1234567890123", at: 0x690)
        var area = try XCTUnwrap(AcerDMIArea.found(stored: bytes, offset: 0x8000))
        XCTAssertEqual(area.assetTag, "Asset0001")
        XCTAssertEqual(area.manufacturingCode, "1234567890123")
        bytes = Self.block()
        Self.put(&bytes, "12345678", at: 0x6A0) // the later of the two places
        area = try XCTUnwrap(AcerDMIArea.found(stored: bytes, offset: 0x8000))
        XCTAssertEqual(area.manufacturingCode, "12345678")
        bytes = Self.block()
        Self.put(&bytes, "123", at: 0x690) // too short to be one
        area = try XCTUnwrap(AcerDMIArea.found(stored: bytes, offset: 0x8000))
        XCTAssertNil(area.manufacturingCode)
    }

    // MARK: - What reads wrong

    /// A factory block passes every integrity check.
    func testAFactoryBlockHasNoFindings() throws {
        let area = try XCTUnwrap(AcerDMIArea.found(stored: Self.block(), offset: 0x8000))
        XCTAssertEqual(area.findings, [])
    }

    func testWhatAMutatedBlockFinds() throws {
        func findings(_ mutate: (inout [UInt8]) -> Void) -> [AcerDMIFinding] {
            var bytes = Self.block()
            mutate(&bytes)
            return try! AcerDMIArea.found(stored: bytes, offset: 0x8000)!.findings
        }
        XCTAssertEqual(findings { $0[7] = 0x35 }, [.serialPattern], "the serial's pattern is gone")
        XCTAssertEqual(findings { $0[0x50 + 5] = 0x32 }, [.serviceTagPattern], "the tag's pattern is gone")
        XCTAssertEqual(findings { $0[0x70 + 6] = 0x47 }, [.uuidVersion], "the UUID is version 4")
        XCTAssertEqual(findings { $0[0x70 + 8] = 0x09 }, [.uuidVariant], "the variant bit is not set")
        XCTAssertEqual(findings { $0[0xF3] = 0x00 }, [.constantWrong], "the constant is not 02")
        XCTAssertEqual(findings { $0.replaceSubrange(0x130..<(0x130 + 6), with: [0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]) },
                       [.tailCopyStale], "the copy does not read as the tail")
        XCTAssertEqual(findings {
            $0.replaceSubrange(0x128..<(0x128 + 6), with: [UInt8](repeating: 0xFF, count: 6))
            $0.replaceSubrange(0x130..<(0x130 + 6), with: [UInt8](repeating: 0xFF, count: 6))
        }, [.tailCopyErased], "the copy is erased")
    }
}
