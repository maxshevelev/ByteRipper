import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// An HP signature block's row: its details read the block, list what it
/// signs with what hashing found, and `?` opens its entry.
final class HPSignatureBlockDisplayTests: XCTestCase {
    private static func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// A version-2 block naming two ranges after it, as the ProDesk 600 G4
    /// keeps one.
    private static let block: [UInt8] = {
        var bytes = u32(0) + u32(2) + u32(0) + u32(0x100)
        for length: UInt32 in [0xF000, 0x4000] { bytes += u32(0xFFFF_1000) + u32(length) + u32(0xFFFF_FFFF) + u32(0) }
        bytes += [UInt8](repeating: 0x5A, count: 0x100) + [UInt8](repeating: 0xFF, count: 0x100)
        bytes += u32(0x140) + u32(0x13E)
        var body = [UInt8](repeating: 0, count: 0x140)
        body.replaceSubrange(8..<11, with: Array("Q22".utf8))
        body.replaceSubrange(0x18..<0x20, with: [0xE7, 0x07, 0, 0, 0x06, 0, 0x0F, 0])
        return bytes + body + [UInt8](repeating: 0x3C, count: 0x300)
    }()

    func testTheDetailsSayWhatTheBlockIsAndWhatItSigns() throws {
        let bytes = Self.block + [UInt8](repeating: 0xFF, count: 0x10000 - Self.block.count)
        let range: Range<UInt64> = 0..<UInt64(Self.block.count)
        let node = UEFINode(kind: .hpSignatureBlock, name: "HP signature block Q22",
                            header: 0..<0x30, body: 0x30..<range.upperBound)
        let root = UEFINode(kind: .uefiImage, name: "UEFI image", header: 0..<0, body: 0..<0x10000, children: [node])
        let image = UEFIImage(size: 0x10000, roots: [root]).adding(ProtectedRanges(ranges: [
            ProtectedRange(kind: .hp, range: 0x1000..<0x10000, source: range),
            ProtectedRange(kind: .hp, range: 0x1000..<0x5000, source: range)
        ]))
        let block = image.roots[0].children[0]
        let detail = UEFIDetail.build(for: block, image: image, reader: ImageReader(bytes))
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(fields["Kind"], "HP signature block")
        XCTAssertEqual(fields["Signature"], "RSA-2048 (0x100)")
        XCTAssertEqual(fields["BIOS version"], "Q22")
        XCTAssertEqual(fields["Date"], "2023-06-15")
        XCTAssertNil(fields["Digest"], "a version-2 block keeps none")
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Signed ranges" })
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows.map { $0[3].text }, ["Not checked", "Not checked"])
        XCTAssertEqual(UEFIHelpTerms.term(for: block), HelpTermID("hp-signature-block"))
    }
}
