import CryptoKit
import XCTest
@testable import UEFIImage

/// HP's signature block (`HPSignatureBlock`): read out of padding as a row,
/// its two ranges marked, the digest checked only where its span is known.
final class HPSignatureBlockTests: XCTestCase {
    /// 64 KiB mapped flush against the top of the address space: the block in
    /// the first 4 KiB, then a volume to the end with the Volume Top File.
    private static let size: UInt64 = 0x10000
    private static let top: UInt64 = 0x1_0000_0000 - size
    private static let volume: Range<UInt64> = 0x1000..<0x10000
    private static let signed: Range<UInt64> = 0x1000..<0x5000

    /// A block of `version`, laid out as the dumps lay it out, naming two
    /// ranges by file offset; `digest` goes where a version-3 payload keeps it.
    private func block(version: UInt32 = 3, first: Range<UInt64>, second: Range<UInt64>,
                       digest: [UInt8] = [], biosVersion: String = "V77") -> [UInt8] {
        let s: UInt32 = version == 3 ? 0x180 : 0x100
        let payload: UInt32 = version == 3 ? 0x336 : 0x140
        var w = BinaryWriter()
        w.u32(0); w.u32(version); w.u32(0); w.u32(s)
        for range in [first, second] {
            w.u32(UInt32(range.lowerBound + Self.top)); w.u32(UInt32(range.count)); w.u32(0xFFFF_FFFF); w.u32(0)
        }
        w.raw((0..<Int(s)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        w.fill(UInt64(s), with: 0xFF)
        w.u32(payload); w.u32(payload - 2)
        var body = [UInt8](repeating: 0, count: Int(payload))
        body[0] = UInt8(version)
        let name = Array(biosVersion.utf8)
        body.replaceSubrange(8..<(8 + name.count), with: name)
        body.replaceSubrange(0x18..<0x20, with: [0xE6, 0x07, 0, 0, 0x0C, 0, 0x1A, 0])      // 2022-12-26
        w.raw(body)
        w.raw((0..<Int(3 * s)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        var bytes = w.bytes
        if version == 3 {
            let id = Array("311547e914957b35a0628d1ef261a46c2f686136".utf8)
            bytes.replaceSubrange(0x368..<(0x368 + id.count), with: id)
            if !digest.isEmpty { bytes.replaceSubrange(0x43A..<(0x43A + digest.count), with: digest) }
        }
        return bytes
    }

    private func image(_ block: [UInt8]) -> [UInt8] {
        var head = block + [UInt8](repeating: 0xFF, count: 0x1000 - block.count)
        head[0xFFF] = 0x5A    // the padding is written, as it is around a real block
        let data = TestImage.file(body: (0..<0x3000).map { UInt8(truncatingIfNeeded: $0 &* 5) })
        return head + TestImage.volume(length: 0xF000, files: [data], lastFile: TestImage.volumeTopFile(size: 0x100))
    }

    private func sha384(_ bytes: [UInt8], _ range: Range<UInt64>) -> [UInt8] {
        Array(SHA384.hash(data: bytes[Int(range.lowerBound)..<Int(range.upperBound)]))
    }

    func testABlockIsARowAndItsDigestOfTheSecondRangeIsChecked() throws {
        var bytes = image(block(first: Self.volume, second: Self.signed, digest: [UInt8](repeating: 0, count: 48)))
        bytes.replaceSubrange(0x43A..<0x46A, with: sha384(bytes, Self.signed))
        let parsed = UEFIParser.parse(bytes)
        let row = try XCTUnwrap(parsed.allNodes.first { $0.kind == .hpSignatureBlock })

        XCTAssertEqual(row.name, "HP signature block V77")
        XCTAssertEqual(row.range, 0..<0xAEE, "header, signature, payload and three blocks after it")
        XCTAssertEqual(row.uefiItemType, UEFITypes.Item.padding.rawValue)
        let block = try XCTUnwrap(HPSignatureBlock.read(at: 0, limit: 0x1000, in: ImageReader(bytes)))
        XCTAssertEqual(block.date, "2022-12-26")
        XCTAssertEqual(block.signatureName, "RSA-3072")
        XCTAssertEqual(block.identifier, "311547e914957b35a0628d1ef261a46c2f686136")

        let hp = try XCTUnwrap(parsed.protectedRanges).ranges.filter { $0.kind == .hp }
        XCTAssertEqual(hp.map(\.range), [Self.volume, Self.signed])
        XCTAssertEqual(hp.map(\.verdict), [.unchecked, .matches])
        XCTAssertEqual(hp.map(\.source), [row.range, row.range])
    }

    /// The digest of a block whose ranges start at one address is the
    /// second range's: one that is not says so.
    func testADigestThatDoesNotMatchIsReported() throws {
        let bytes = image(block(first: Self.volume, second: Self.signed, digest: [UInt8](repeating: 7, count: 48)))
        let parsed = UEFIParser.parse(bytes)

        XCTAssertEqual(parsed.protectedRanges?.ranges.filter { $0.kind == .hp }.map(\.verdict), [.unchecked, .mismatch])
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .protectedRangeHashMismatch("HP signed range") })
    }

    /// The other block's digest covers something nobody has worked out, and
    /// a version-2 block keeps none: their ranges are marked, not checked.
    func testADigestOfUnknownSpanAndAVersion2BlockAreNotChecked() throws {
        let other = image(block(first: 0x4000..<0x10000, second: 0x1000..<0x10000,
                                digest: [UInt8](repeating: 7, count: 48)))
        XCTAssertEqual(UEFIParser.parse(other).protectedRanges?.ranges.filter { $0.kind == .hp }.map(\.verdict),
                       [.unchecked, .unchecked])

        let older = image(block(version: 2, first: Self.volume, second: Self.signed, biosVersion: "Q22"))
        let parsed = UEFIParser.parse(older)
        XCTAssertEqual(parsed.allNodes.first { $0.kind == .hpSignatureBlock }?.range, 0..<0x678)
        XCTAssertEqual(HPSignatureBlock.read(at: 0, limit: 0x1000, in: ImageReader(older))?.signatureName, "RSA-2048")
        XCTAssertEqual(parsed.protectedRanges?.ranges.filter { $0.kind == .hp }.map(\.verdict), [.unchecked, .unchecked])
    }

    /// A header that is nearly one — the signature's filler written over, an
    /// unknown version — is padding, and nothing is said about it.
    func testANearMissIsNoBlock() {
        var filler = block(first: Self.volume, second: Self.signed)
        filler[0x200] = 0
        var unknown = block(first: Self.volume, second: Self.signed)
        unknown[4] = 7
        for bytes in [filler, unknown] {
            XCTAssertNil(HPSignatureBlock.read(at: 0, limit: 0x1000, in: ImageReader(bytes)))
            XCTAssertFalse(UEFIParser.parse(image(bytes)).allNodes.contains { $0.kind == .hpSignatureBlock })
        }
    }
}
