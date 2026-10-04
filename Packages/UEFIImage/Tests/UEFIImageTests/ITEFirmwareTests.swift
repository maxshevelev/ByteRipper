import XCTest
@testable import UEFIImage

/// The identification an ITE EC image carries after its signature block
/// (`UEFI_IMAGE_FORMAT.md` §9), and the names it gives the rows it opens.
final class ITEFirmwareTests: XCTestCase {
    /// A signature block as the dumps at hand have it, the varying bytes set
    /// to values one of them carries.
    static let block: [UInt8] = [0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA4, 0x14,
                                 0x85, 0x12, 0x5A, 0x5A, 0xAA, 0xAF, 0x55, 0x55]

    /// An image `length` bytes long with the block at `at` and the
    /// identification after it, padded to sixteen bytes.
    static func image(_ identification: String = "ITE8380-EC-V1.43", at: Int = 0x80, length: Int = 0x1000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x00, count: length)
        let text = Array(identification.utf8) + [UInt8](repeating: 0, count: 16 - identification.utf8.count)
        bytes.replaceSubrange(at..<(at + 32), with: block + text)
        return bytes
    }

    private func read(_ bytes: [UInt8]) -> ITEFirmware? {
        ITEFirmware.read(at: 0, limit: UInt64(bytes.count), in: ImageReader(bytes))
    }

    func testTheIdentificationAfterTheBlockIsRead() {
        XCTAssertEqual(read(Self.image()), ITEFirmware(identification: "ITE8380-EC-V1.43", start: 0, signatureOffset: 0x80))
    }

    /// The 8051 parts keep the block at `0x40`, and pad the string with spaces.
    func testTheBlockAt0x40IsReadAndTheSpacesDropped() {
        let firmware = read(Self.image("ITE EC-V13.6  ", at: 0x40))
        XCTAssertEqual(firmware?.identification, "ITE EC-V13.6")
        XCTAssertEqual(firmware?.signatureOffset, 0x40)
    }

    /// Text after the sixteen bytes is not part of the identification.
    func testOnlySixteenBytesAreRead() {
        var bytes = Self.image("ITE5507-SB-V0.67")
        bytes.replaceSubrange(0xA0..<0xA8, with: Array("20230426".utf8))
        XCTAssertEqual(read(bytes)?.identification, "ITE5507-SB-V0.67")
    }

    /// The pair after `85 12` is `5A 5A` on most images, and something else
    /// on the `ITE EC-V14.0` ones — which are no less ITE for it.
    func testTheSecondPairMayVary() {
        var bytes = Self.image("ITE EC-V14.0  ", at: 0x40)
        bytes.replaceSubrange(0x40..<0x50, with: [0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0x10,
                                                  0x85, 0x12, 0xB9, 0x9D, 0xAA, 0x7F, 0x55, 0x55])
        XCTAssertEqual(read(bytes)?.identification, "ITE EC-V14.0")
    }

    func testWithoutTheBlockThereIsNoIdentification() {
        var bytes = Self.image()
        bytes[0x80 + 9] = 0x13
        XCTAssertNil(read(bytes))
        XCTAssertNil(read([UInt8](repeating: 0xA5, count: 0x1000)))
    }

    /// A region can hold more than one image; each starts on a 4 KiB boundary.
    func testEveryImageInARangeIsFound() {
        let bytes = Self.image("ITE5507-SB-V0.67") + [UInt8](repeating: 0, count: 0x1000) + Self.image()
        let found = ITEFirmware.all(in: 0..<UInt64(bytes.count), reader: ImageReader(bytes))
        XCTAssertEqual(found.map(\.identification), ["ITE5507-SB-V0.67", "ITE8380-EC-V1.43"])
        XCTAssertEqual(found.map(\.start), [0, 0x2000])
    }

    /// Padding that opens on an ITE image is named by its identification; the
    /// bytes stay padding.
    func testPaddingOpeningOnAnImageIsNamedByIt() {
        var bytes = [UInt8](repeating: 0xFF, count: 0x10000)
        bytes.replaceSubrange(0..<0x1000, with: Self.image("ITE8226-EC-V0.00"))
        bytes.replaceSubrange(0xF000..<0x10000, with: TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile()))
        let first = UEFIParser.parse(bytes).roots[0].children[0]
        XCTAssertEqual(first.kind, .padding)
        XCTAssertEqual(first.range, 0..<0xF000)
        XCTAssertEqual(first.name, "EC firmware (ITE8226-EC-V0.00)")
    }

    /// Padding with nothing at `0x40` or `0x80` keeps its name.
    func testOtherPaddingKeepsItsName() {
        var bytes = [UInt8](repeating: 0xFF, count: 0x10000)
        bytes.replaceSubrange(0..<0x1000, with: Self.image(at: 0x200))
        bytes.replaceSubrange(0xF000..<0x10000, with: TestImage.volume(length: 0x1000, lastFile: TestImage.volumeTopFile()))
        XCTAssertEqual(UEFIParser.parse(bytes).roots[0].children[0].name, "Padding")
    }
}
