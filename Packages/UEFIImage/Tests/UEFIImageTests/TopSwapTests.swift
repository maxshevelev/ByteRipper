import XCTest
@testable import UEFIImage

/// The Top Swap copy of the boot block, found through the FIT and read with
/// the protected ranges (`UEFI_IMAGE_FORMAT.md` §11).
final class TopSwapTests: XCTestCase {
    private static let block: UInt64 = 0x1_0000
    private static let fitGUID = KnownGUIDs.guid("FD000000-0000-4000-8000-0000000000F1")

    /// One block: a volume holding a file for the FIT and ending in the
    /// Volume Top File, the FIT in that file and the pointer at `0xFFFFFFC0`,
    /// for an image `imageSize` bytes long whose last block this is.
    private static func block(imageSize: UInt64) -> [UInt8] {
        var bytes = TestImage.volume(
            length: block,
            files: [TestImage.file(guid: fitGUID, body: [UInt8](repeating: 0xFF, count: 0x100))],
            lastFile: TestImage.volumeTopFile(size: 0x100)
        )
        let fit = UEFIParser.parse(bytes, readsProtectedRanges: false).allNodes
            .first { $0.kind == .file && $0.guid == fitGUID }!.body.lowerBound
        let addressDiff = 0x1_0000_0000 - imageSize
        var table = BinaryWriter()
        table.u64(TopSwapCopy.fitSignature)
        table.u24(1)
        table.u8(0)
        table.u16(0x0100)
        table.u8(0)
        table.u8(0)
        bytes.replaceSubrange(Int(fit)..<(Int(fit) + 16), with: table.bytes)
        var pointer = BinaryWriter()
        pointer.u32(UInt32(imageSize - block + fit + addressDiff))
        bytes.replaceSubrange(Int(block - 0x40)..<Int(block - 0x3C), with: pointer.bytes)
        return bytes
    }

    private static var twoBlocks: [UInt8] {
        block(imageSize: 2 * block) + block(imageSize: 2 * block)
    }

    func testTheCopyBelowTheTopBlockIsFoundAndCompared() {
        let ranges = UEFIParser.parse(Self.twoBlocks).protectedRanges
        XCTAssertEqual(ranges?.topSwap, TopSwapCopy(top: 0x1_0000..<0x2_0000, backup: 0..<0x1_0000))
        XCTAssertEqual(ranges?.topSwapCopiesMatch, true)
    }

    func testCopiesThatDifferSaySo() {
        var bytes = Self.twoBlocks
        bytes[0x200] ^= 0xFF
        let ranges = UEFIParser.parse(bytes).protectedRanges
        XCTAssertNotNil(ranges?.topSwap)
        XCTAssertEqual(ranges?.topSwapCopiesMatch, false)
    }

    func testOneBlockHasNoCopy() {
        XCTAssertNil(UEFIParser.parse(Self.block(imageSize: Self.block)).protectedRanges?.topSwap)
    }

    /// Bytes below the top block that hold no FIT of their own are not a copy.
    func testABlockBelowWithoutItsOwnFITIsNoCopy() {
        let bytes = [UInt8](repeating: 0xFF, count: Int(Self.block)) + Self.block(imageSize: 2 * Self.block)
        XCTAssertNil(UEFIParser.parse(bytes).protectedRanges?.topSwap)
    }

    /// A block swapped in is the other block's byte; anything else stays.
    func testSwapTradesTheBlocks() {
        let copy = TopSwapCopy(top: 0x2_0000..<0x3_0000, backup: 0x1_0000..<0x2_0000)
        XCTAssertEqual(copy.swap(0x2_0010), 0x1_0010)
        XCTAssertEqual(copy.swap(0x1_0010), 0x2_0010)
        XCTAssertEqual(copy.swap(0x10), 0x10)
    }
}
