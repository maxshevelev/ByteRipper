import XCTest
@testable import UEFIImage

/// A block of EC firmware holding more than one image: a row per image,
/// padding between them, and a copy told by its bytes (`UEFI_IMAGE_FORMAT.md`
/// §9).
final class ECImageTests: XCTestCase {
    /// A Microchip image: the `PHCM` header and `length` bytes of something
    /// that is not the erase byte.
    private static func microchip(length: Int, fill: UInt8 = 0x5A) -> [UInt8] {
        Array("PHCM".utf8) + [UInt8](repeating: fill, count: length - 4)
    }

    /// `parts` placed at their offsets in an erased block `size` long.
    private static func block(_ size: Int, _ parts: [(Int, [UInt8])]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: size)
        for (at, part) in parts { bytes.replaceSubrange(at..<(at + part.count), with: part) }
        return bytes
    }

    /// An image with a descriptor whose EC region is `ec`, and nothing else.
    private func ecRegion(_ ec: [UInt8]) -> UEFINode {
        let start: UInt64 = 0x1000
        let range = start..<(start + UInt64(ec.count))
        let bytes = TestImage.intelImage(size: range.upperBound, regions: [(.ec, range)], contents: [.ec: ec])
        return UEFIParser.parse(bytes).roots[0].children.first { $0.kind == .region }!
    }

    func testEveryImageFoundIsARowAndWhatLiesBetweenIsPadding() {
        let region = ecRegion(Self.block(0x8000, [
            (0x0000, ITEFirmwareTests.image("ITE5507-SB-V0.67", length: 0x1800)),
            (0x3000, ITEFirmwareTests.image("ITE8380-EC-V1.43", length: 0x2100)),
        ]))
        // Each row names its chip; the block names none of them.
        XCTAssertEqual(region.name, "EC region")
        XCTAssertEqual(region.children.map(\.kind), [.ecImage, .padding, .ecImage, .padding])
        // An image runs to its last written byte, rounded up to 4 KiB.
        XCTAssertEqual(region.children.map(\.range), [
            0x1000..<0x3000, 0x3000..<0x4000, 0x4000..<0x7000, 0x7000..<0x9000,
        ])
        XCTAssertEqual(region.children.filter { $0.kind == .ecImage }.map(\.name),
                       ["ITE5507-SB-V0.67", "ITE8380-EC-V1.43"])
        XCTAssertTrue(region.children.allSatisfy { $0.kind != .ecImage || $0.isFixed })
    }

    /// A copy is as long as what it copies: what follows it — a log — stays
    /// padding with data in it.
    func testACopyIsAsLongAsItsOriginal() {
        let image = Self.microchip(length: 0x1F00)
        let log = [UInt8](repeating: 0x01, count: 0x100)
        let region = ecRegion(Self.block(0x8000, [(0x0000, image), (0x2000, image), (0x6000, log)]))
        let rows = region.children

        XCTAssertEqual(region.name, "EC region")
        XCTAssertEqual(rows.map(\.kind), [.ecImage, .ecImage, .padding])
        XCTAssertEqual(rows.map(\.range), [0x1000..<0x3000, 0x3000..<0x5000, 0x5000..<0x9000])
        XCTAssertEqual(rows[0].name, "Microchip MEC image")
        XCTAssertNil(rows[0].subtype)
        XCTAssertEqual(rows[1].subtype, ECImage.copySubtype)
        XCTAssertFalse(rows[2].isErased)

        let found = ECImage.all(in: region.body, reader: ImageReader(TestImage.intelImage(
            size: 0x9000, regions: [(.ec, 0x1000..<0x9000)],
            contents: [.ec: Self.block(0x8000, [(0x0000, image), (0x2000, image), (0x6000, log)])]
        )))
        XCTAssertEqual(found.map(\.written), [0x1F00, 0x1F00])
        XCTAssertEqual(found.map(\.copyOf), [nil, 0x1000])
    }

    /// Bytes that only resemble an earlier image are not a copy of it.
    func testAnImageThatDiffersIsNoCopy() {
        let region = ecRegion(Self.block(0x4000, [
            (0x0000, Self.microchip(length: 0x800)),
            (0x2000, Self.microchip(length: 0x800, fill: 0x5B)),
        ]))
        XCTAssertEqual(region.children.filter { $0.kind == .ecImage }.map(\.subtype), [nil, nil])
    }

    /// Padding holding two images is "EC firmware", and its rows say which.
    func testPaddingWithSeveralImagesNamesNoneOfThem() {
        var bytes = [UInt8](repeating: 0xFF, count: 0x10000)
        bytes.replaceSubrange(0..<0x1000, with: ITEFirmwareTests.image("ITE5507-SB-V0.67"))
        bytes.replaceSubrange(0x2000..<0x3000, with: ITEFirmwareTests.image("ITE8380-EC-V0.00"))
        bytes.replaceSubrange(0xF000..<0x10000, with: TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile()))
        let padding = UEFIParser.parse(bytes).roots[0].children[0]
        XCTAssertEqual(padding.name, "EC firmware")
        XCTAssertTrue(ECImage.isECFirmwarePadding(padding))
        XCTAssertEqual(padding.children.filter { $0.kind == .ecImage }.map(\.name),
                       ["ITE5507-SB-V0.67", "ITE8380-EC-V0.00"])
    }

    /// One image at the block's start is the common case: the block is
    /// named by it, keeps its length as a row would, and gets no rows.
    func testASingleImageAtTheStartAddsNoRows() {
        let region = ecRegion(Self.block(0x4000, [(0x0000, Self.microchip(length: 0x1800))]))
        XCTAssertEqual(region.name, "EC region (Microchip MEC image)")
        XCTAssertEqual(region.namedImageLength, 0x2000)
        XCTAssertTrue(region.children.isEmpty)
    }

    /// Blocks that name no single image carry no length for one.
    func testOnlyABlockNamedAfterOneImageKeepsItsLength() {
        let several = ecRegion(Self.block(0x4000, [(0x0000, Self.microchip(length: 0x800)),
                                                   (0x2000, Self.microchip(length: 0x800))]))
        XCTAssertNil(several.namedImageLength)
        XCTAssertTrue(several.children.allSatisfy { $0.namedImageLength == nil })
    }

    /// One image further in gets a row, so the bytes before it are seen.
    func testASingleImageFurtherInIsARow() {
        let region = ecRegion(Self.block(0x4000, [(0x0000, [0x12, 0x34]), (0x1000, Self.microchip(length: 0x800))]))
        XCTAssertEqual(region.children.map(\.kind), [.padding, .ecImage, .padding])
        XCTAssertFalse(region.children[0].isErased)
    }

    /// An EC region with no image it knows stays as it was.
    func testAnEmptyECRegionStaysAsItWas() {
        let region = ecRegion([UInt8](repeating: 0xFF, count: 0x2000))
        XCTAssertEqual(region.name, "EC region")
        XCTAssertTrue(region.children.isEmpty)
    }

    /// An image classifies as UEFITool's padding.
    func testAnImageClassifiesAsPadding() {
        let region = ecRegion(Self.block(0x4000, [(0x1000, Self.microchip(length: 0x800))]))
        let image = region.children.first { $0.kind == .ecImage }!
        XCTAssertEqual(image.uefiItemType, UEFITypes.Item.padding.rawValue)
        XCTAssertEqual(image.uefiItemSubtype, UEFITypes.Sub.dataPadding)
    }
}
