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
        ranges: [UInt8] = InsydeBVDTTests.ranges,
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
        bytes += Array("$BME$".utf8) + ranges
        bytes += records + Array("$ENDOFBVDT".utf8) + afterEnd
        return bytes + [UInt8](repeating: 0xFF, count: 0x1000 - bytes.count)
    }

    /// `all.orig.bin`'s `$BME$`: the table's own region, the microcode
    /// volume, and a slot not in use.
    static let ranges: [UInt8] = [0x00, 0xA0, 0x0A, 0x00, 0x00, 0x10, 0x00, 0x00, 0x24,
                                  0x00, 0x00, 0xC4, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x24,
                                  0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    /// `all.orig.bin`'s `$_MSC_VER=` and `$ESRT`.
    static let compilerAndESRT: [UInt8] = Array("$_MSC_VER=".utf8) + [0x40, 0x06]
        + Array("$ESRT".utf8) + [0x57, 0x40, 0x22, 0x70,
                                 0x4C, 0x61, 0xF9, 0x94, 0xF2, 0xE5, 0x92, 0x46,
                                 0x81, 0xAE, 0x20, 0xE9, 0xC6, 0x1A, 0x86, 0x64,
                                 0x8B, 0x01, 0x00, 0x00]

    private func read(_ bytes: [UInt8]) -> InsydeBVDT? {
        InsydeBVDT.read(0..<UInt64(bytes.count), in: ImageReader(bytes))
    }

    func testTheStringsAndTheDateAreRead() {
        XCTAssertEqual(read(Self.table()), InsydeBVDT(
            biosVersion: "J2CN57WW",
            productName: "Legion 570 Series Intel",
            kernelVersion: "05.43.44",
            releaseDate: "2024-01-08",
            listedRanges: [0xAA000..<0xAB000, 0xC4_0000..<0xD0_0000]
        ))
    }

    /// The compiler the firmware was built with, and the board's ESRT entry:
    /// the version, then the firmware class Windows Update knows it by.
    func testTheCompilerAndTheESRTEntryAreRead() {
        let table = read(Self.table(records: Self.compilerAndESRT))
        XCTAssertEqual(table?.compilerVersion, 1600)
        XCTAssertEqual(table?.esrtVersion, 0x7022_4057)
        XCTAssertEqual(table?.esrtClass, EFIGUID("94F9614C-E5F2-4692-81AE-20E9C61A8664"))
    }

    /// Three pairs fill the record, and the next record follows them; an
    /// erased slot, or a list cut short with no `$`, ends it.
    func testTheListedRangesStopAtAnErasedSlotOrAMissingSeparator() {
        let three: [UInt8] = [0x00, 0x80, 0x48, 0x00, 0x00, 0x10, 0x00, 0x00, 0x24,
                              0x00, 0x00, 0x56, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x24,
                              0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0xFF]
        XCTAssertEqual(read(Self.table(ranges: three))?.listedRanges,
                       [0x48_8000..<0x48_9000, 0x56_0000..<0x60_0000, 0x2_0000..<0x3_0000])
        let one = Array(three[0..<8]) + [0xFF]
        XCTAssertEqual(read(Self.table(ranges: one))?.listedRanges, [0x48_8000..<0x48_9000])
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
