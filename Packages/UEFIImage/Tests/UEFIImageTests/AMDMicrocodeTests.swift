import XCTest
@testable import UEFIImage

/// AMD microcode read out of padding (`UEFI_IMAGE_FORMAT.md` §7.2): a header
/// with no signature, checked field by field as the reference checks it.
final class AMDMicrocodeTests: XCTestCase {
    /// A Cezanne patch's header, as `SPI_EF6018_128Mbit.*` carries it:
    /// 2023-07-07, revision `0A50000F`, loader `8005`, CPUID `00A50F00`.
    private func header(year: UInt16 = 0x2023, month: UInt8 = 0x07, day: UInt8 = 0x07,
                        revision: UInt32 = 0x0A50_000F, loader: UInt16 = 0x8005,
                        signature: UInt16 = 0xA500, dataSize: UInt8 = 0) -> [UInt8] {
        var writer = BinaryWriter()
        writer.u16(year)
        writer.u8(day)
        writer.u8(month)
        writer.u32(revision)
        writer.u16(loader)
        writer.u8(dataSize)
        writer.u8(0)            // initialisation flag
        writer.u32(0)           // data checksum
        writer.u16(0); writer.u16(0); writer.u16(0); writer.u16(0)
        writer.u16(signature)
        writer.raw([0, 0, 0, 0, 0, 0])
        return writer.bytes
    }

    /// `patch` at `offset` in bytes no scan reads anything else in, the dword
    /// at `0x40` written as the reference wants it.
    private func image(_ patch: [UInt8], at offset: Int = 0x1000, size: Int = 0x4000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x11, count: size)
        bytes.replaceSubrange(offset..<(offset + patch.count), with: patch)
        return bytes
    }

    func testAPatchInPaddingIsARowOfItsOwn() throws {
        let parsed = UEFIParser.parse(image(header()))
        let padding = try XCTUnwrap(parsed.roots.first)

        XCTAssertEqual(padding.kind, .padding, "the padding keeps its place, range and name")
        XCTAssertEqual(padding.range, 0..<0x4000)
        XCTAssertEqual(padding.children.map(\.kind), [.padding, .amdMicrocode, .padding])
        let patch = padding.children[1]
        XCTAssertEqual(patch.name, "AMD microcode A50F00, revision A50000F")
        XCTAssertEqual(patch.range, 0x1000..<(0x1000 + 0x15C0), "family A5 is 0x15C0 long")
        XCTAssertEqual(patch.header, 0x1000..<0x1020)
        XCTAssertEqual(patch.uefiItemType, UEFITypes.Item.amdMicrocode.rawValue)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    func testTheHeaderReadsAsTheReferenceReadsIt() throws {
        let bytes = image(header(revision: 0x0860_0106, loader: 0x8004, signature: 0x8600))
        let patch = try XCTUnwrap(AMDMicrocodeHeader.read(at: 0x1000, limit: 0x4000, in: ImageReader(bytes)))
        XCTAssertEqual(patch.cpuID, 0x0086_0F00)
        XCTAssertEqual(patch.length, 0xC80, "families 80–8A are 0xC80 long")
        XCTAssertEqual(patch.date, "2023-07-07")
    }

    /// A patch AMD shipped dated the thirteenth month is read with the date
    /// the reference gives it. An old family's header says its own length:
    /// `0x20` of data is a patch of `0x3C0`.
    func testAKnownMisdatedPatchIsPutRight() throws {
        let bytes = image(header(year: 0x2013, month: 0x13, day: 0x10, revision: 0x0300_0027,
                                 loader: 0x8004, signature: 0x3010, dataSize: 0x20))
        let header = AMDMicrocodeHeader.read(at: 0x1000, limit: 0x4000, in: ImageReader(bytes))
        XCTAssertEqual(header?.date, "2013-12-10")
        XCTAssertEqual(header?.length, 0x3C0)
    }

    /// A field AMD never writes, a date that is no date, or nothing after the
    /// header: data, not a patch, and nothing said about it.
    func testAHeaderThatDoesNotCheckOutIsNoPatch() {
        let rejected: [[UInt8]] = [
            header(loader: 0x7005),
            header(month: 0x1A),
            header(day: 0x00),
            header(year: 0x2030),
            header(signature: 0xC000)       // a family the size table does not know
        ]
        for bytes in rejected {
            XCTAssertNil(AMDMicrocodeHeader.read(at: 0x1000, limit: 0x4000, in: ImageReader(image(bytes))))
        }
        var silent = image(header())
        silent.replaceSubrange(0x1040..<0x1044, with: [0, 0, 0, 0])
        XCTAssertNil(AMDMicrocodeHeader.read(at: 0x1000, limit: 0x4000, in: ImageReader(silent)))
        XCTAssertNil(AMDMicrocodeHeader.read(at: 0x1000, limit: 0x1000 + 0x1000, in: ImageReader(image(header()))),
                     "a patch the space ends inside is not one")
    }

    /// Two patches in a row, as `W25Q64JW-IQ.orig.bin` keeps three, each a row.
    func testPatchesOneAfterAnotherAreEachARow() throws {
        let first = header(loader: 0x8004, signature: 0x8181)
        let second = header(loader: 0x8004, signature: 0x8180)
        var bytes = image(first)
        bytes.replaceSubrange(0x1D00..<(0x1D00 + second.count), with: second)
        let rows = try XCTUnwrap(UEFIParser.parse(bytes).roots.first).children

        XCTAssertEqual(rows.filter { $0.kind == .amdMicrocode }.map(\.range.lowerBound), [0x1000, 0x1D00])
    }
}
