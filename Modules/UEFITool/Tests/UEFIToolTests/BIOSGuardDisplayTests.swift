import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// An AMI BIOS Guard update file in the panel: the update's row says what it
/// is and lists its table, its entries open as stretches of the region, the
/// region itself is offered as a file, and `?` opens the update's entry.
final class BIOSGuardDisplayTests: XCTestCase {
    private static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// Two entries, `/B FV_BB` of one block and `/P FV_MAIN` of two, every
    /// block signed with RSA-2048.
    private static let file: [UInt8] = {
        let lines: [(key: String, name: String, blocks: [Int])] = [("/B", "FV_BB", [0x100]), ("/P", "FV_MAIN", [0x200, 0x80])]
        var text = "AMI_BIOS_GUARD_FLASH_CONFIGURATIONSII00010000\r\n"
        for line in lines { text += "1 \(line.key) \(line.blocks.count) ;\(line.name)\r\n" }
        var bytes = u32(UInt32(0x11 + text.utf8.count)) + u32(0) + Array("_AMIPFAT".utf8) + [0x63] + Array(text.utf8)
        for size in lines.flatMap(\.blocks) {
            bytes += u16(2) + u16(0) + Array("RAPTORLAKE".utf8) + [UInt8](repeating: 0, count: 6)
            bytes += u32(0x0D) + u16(2) + u16(0) + u32(8) + u32(UInt32(size)) + u32(0) + u32(0) + u32(0)
            bytes += [UInt8](repeating: 0x51, count: 8) + [UInt8](repeating: 0xFF, count: size)
            bytes += u32(1) + u32(1) + [UInt8](repeating: 0xA5, count: 0x204)
        }
        return bytes
    }()

    private func parsed() throws -> (UEFIImage, UEFINode) {
        let image = UEFIParser.parse(ImageReader(Self.file).source)
        return (image, try XCTUnwrap(image.roots.first { $0.kind == .biosGuardUpdate }))
    }

    func testTheUpdatesRowSaysWhatItIsAndListsItsTable() throws {
        let (image, update) = try parsed()
        let detail = UEFIDetail.build(for: update, image: image, reader: ImageReader(Self.file))
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(fields["Kind"], "BIOS Guard update")
        XCTAssertEqual(fields["Platform"], "RAPTORLAKE")
        XCTAssertEqual(fields["Blocks"], "3")
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Update table" })
        XCTAssertEqual(table.columns, ["Name", "Switch", "Blocks", "Offset in the region", "Size"])
        XCTAssertEqual(table.rows.map { $0.map(\.text) }, [
            ["FV_BB", "/B", "1", "0x0", "0x100"],
            ["FV_MAIN", "/P", "2", "0x100", "0x280"]
        ])
    }

    func testTheEntriesAreRowsOfTheirOwnInTheRegion() throws {
        let (_, update) = try parsed()
        XCTAssertEqual(update.children.map(\.name), ["FV_BB", "FV_MAIN"])
        XCTAssertEqual(update.children.map { UEFITreeDisplay.typeText(for: $0) }, ["Padding", "Padding"])
        XCTAssertTrue(update.children.allSatisfy { $0.space == .decompressed(chain: [0]) })
    }

    func testTheRegionIsOfferedAsAFileByWhatItIs() throws {
        let (_, update) = try parsed()
        let body = try XCTUnwrap(UEFIPresenter.decompressedBody(for: update))
        XCTAssertEqual(body.space, .decompressed(chain: [0]))
        XCTAssertEqual(body.openTitle, "Open Assembled BIOS Region")
        XCTAssertEqual(body.saveTitle, "Save Assembled BIOS Region as…")
        XCTAssertEqual(body.tabName(fileName: "X1704VAPF.306"), "X1704VAPF_BIOS region.bin")
        XCTAssertEqual(UEFIPresenter.content(of: update), .decompressedBody)
    }

    func testTheQuestionMarkOpensTheUpdatesEntry() throws {
        let (_, update) = try parsed()
        XCTAssertEqual(UEFIHelpTerms.term(for: update), HelpTermID("bios-guard-update"))
        XCTAssertEqual(update.children.first.flatMap(UEFIHelpTerms.term(for:)), HelpTermID("bios-guard-update"))
    }
}
