import XCTest
@testable import UEFIImage

/// Insyde's `$BVDT$` table (`UEFI_IMAGE_FORMAT.md` §9), laid out the way the
/// dumps at hand lay it out.
final class InsydeBVDTTests: XCTestCase {
    /// A table: the signature, three strings at their fixed places, erased
    /// bytes, then the tagged records up to `$ENDOFBVDT`.
    static func table(
        version: String = "J2CN57WW",
        product: String = "Legion 570 Series Intel",
        kernel: String = "05.43.44",
        records: [UInt8] = Array("$RDATE".utf8) + [0x24, 0x01, 0x08],
        afterEnd: [UInt8] = []
    ) -> [UInt8] {
        func field(_ text: String, to end: Int, from start: Int) -> [UInt8] {
            let bytes = [UInt8(ascii: "$")] + Array(text.utf8)
            return bytes + [UInt8](repeating: 0, count: end - start - bytes.count)
        }
        var bytes = Array("$BVDT$".utf8) + [0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00]
        bytes += field(version, to: 0x26, from: 0x0D)
        bytes += field(product, to: 0x40, from: 0x26)
        bytes += field(kernel, to: 0x66, from: 0x40)
        bytes += [UInt8](repeating: 0xFF, count: 0x12F - bytes.count)
        bytes += Array("$BME$".utf8) + [0x00, 0xA0, 0x0A, 0x00]
        bytes += records + Array("$ENDOFBVDT".utf8) + afterEnd
        return bytes + [UInt8](repeating: 0xFF, count: 0x1000 - bytes.count)
    }

    private func read(_ bytes: [UInt8]) -> InsydeBVDT? {
        InsydeBVDT.read(0..<UInt64(bytes.count), in: ImageReader(bytes))
    }

    func testTheStringsAndTheDateAreRead() {
        XCTAssertEqual(read(Self.table()), InsydeBVDT(
            biosVersion: "J2CN57WW",
            productName: "Legion 570 Series Intel",
            kernelVersion: "05.43.44",
            releaseDate: "2024-01-08"
        ))
    }

    func testWithoutTheSignatureThereIsNoTable() {
        var bytes = Self.table()
        bytes[1] = UInt8(ascii: "X")
        XCTAssertNil(read(bytes))
    }

    /// A field whose `$` is not where the layout puts it, or that is empty,
    /// is not guessed at.
    func testAFieldOutOfPlaceOrEmptyIsAbsent() {
        var bytes = Self.table(kernel: "")
        bytes[0x26] = 0
        let table = read(bytes)
        XCTAssertEqual(table?.biosVersion, "J2CN57WW")
        XCTAssertNil(table?.productName)
        XCTAssertNil(table?.kernelVersion)
    }

    /// Three bytes that are not a BCD date are not one.
    func testADateThatIsNotBCDIsAbsent() {
        let table = read(Self.table(records: Array("$RDATE".utf8) + [0x24, 0x1A, 0x08]))
        XCTAssertNotNil(table)
        XCTAssertNil(table?.releaseDate)
    }

    /// The records end at `$ENDOFBVDT`; a tag after it is not the table's.
    func testATagAfterTheEndIsNotRead() {
        let table = read(Self.table(records: [], afterEnd: Array("$RDATE".utf8) + [0x24, 0x01, 0x08]))
        XCTAssertNil(table?.releaseDate)
    }
}
