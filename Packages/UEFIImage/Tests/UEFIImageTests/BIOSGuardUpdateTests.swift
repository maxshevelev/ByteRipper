import XCTest
@testable import UEFIImage

/// An AMI BIOS Guard update file (`BIOSGuardUpdate`, `UEFI_IMAGE_FORMAT.md`
/// §1.2): the table read as entries, the blocks' data laid end to end as the
/// region, and every way a file can fail to be one said as such.
final class BIOSGuardUpdateTests: XCTestCase {
    private struct Line {
        var key: String
        var name: String
        var blocks: [[UInt8]]
    }

    /// A file laid out as ASUS's `X1704VAPF.306` is: header, table, blocks
    /// with a short script and an RSA-2048 signature unless asked otherwise,
    /// and whatever the vendor appends after them.
    private func file(_ lines: [Line], platform: String = "RAPTORLAKE", signature: Int = 0x20C,
                      signed: Bool = true, tail: [UInt8] = []) -> [UInt8] {
        var text = "AMI_BIOS_GUARD_FLASH_CONFIGURATIONSII00010000\r\n"
        for line in lines {
            text += "1 \(line.key) \(line.blocks.count) ;\(line.name)\r\n"
        }
        var w = BinaryWriter()
        let headerSize = 0x11 + text.utf8.count
        w.u32(UInt32(headerSize))
        w.u32(0xD814)
        w.raw(Array("_AMIPFAT".utf8))
        w.u8(0x63)
        w.raw(Array(text.utf8))
        for data in lines.flatMap(\.blocks) {
            let script = [UInt8](repeating: 0x51, count: 0x20)
            w.u16(2); w.u16(0)
            var id = Array(platform.utf8)
            id += [UInt8](repeating: 0, count: 16 - id.count)
            w.raw(id)
            w.u32(signed ? 0x0D : 0x0C)
            w.u16(2); w.u16(0)
            w.u32(UInt32(script.count))
            w.u32(UInt32(data.count))
            w.u32(0x57000); w.u32(0xFFFF_FFFF); w.u32(0)
            w.raw(script)
            w.raw(data)
            if signed {
                w.u32(1); w.u32(1)
                w.fill(UInt64(signature - 8), with: 0xA5)
            }
        }
        w.raw(tail)
        return w.bytes
    }

    private func block(_ byte: UInt8, _ count: Int) -> [UInt8] {
        [UInt8](repeating: byte, count: count)
    }

    private var lines: [Line] {
        [Line(key: "/B", name: "FV_BB", blocks: [block(0x11, 0x100)]),
         Line(key: "/N", name: "NVRAM", blocks: [block(0x22, 0x80)]),
         Line(key: "/P", name: "FV_MAIN_WRAPPER", blocks: [block(0x33, 0x100), block(0x44, 0x40)])]
    }

    func testTheEntriesAreTheTablesLinesPlacedOneAfterAnother() throws {
        let update = try BIOSGuardUpdate.parse(file(lines)).get()
        XCTAssertEqual(update.platform, "RAPTORLAKE")
        XCTAssertEqual(update.blockCount, 4)
        XCTAssertEqual(update.entries, [
            .init(name: "FV_BB", key: "/B", blockCount: 1, range: 0..<0x100),
            .init(name: "NVRAM", key: "/N", blockCount: 1, range: 0x100..<0x180),
            .init(name: "FV_MAIN_WRAPPER", key: "/P", blockCount: 2, range: 0x180..<0x2C0)
        ])
    }

    func testTheRegionIsTheBlocksDataInFileOrderWithoutScriptsOrSignatures() throws {
        let update = try BIOSGuardUpdate.parse(file(lines, tail: block(0xEE, 0x200))).get()
        XCTAssertEqual(update.region, block(0x11, 0x100) + block(0x22, 0x80) + block(0x33, 0x100) + block(0x44, 0x40))
    }

    func testAnRSA3072SignatureIsSteppedOverAsWell() throws {
        let update = try BIOSGuardUpdate.parse(file(lines, signature: 0x30C)).get()
        XCTAssertEqual(update.region.count, 0x2C0)
        XCTAssertEqual(update.entries.last?.range, 0x180..<0x2C0)
    }

    func testAnUnsignedBlockHasNoSignatureAfterIt() throws {
        let update = try BIOSGuardUpdate.parse(file(lines, signed: false)).get()
        XCTAssertEqual(update.region.count, 0x2C0)
    }

    func testALineWithoutAKeyIsStillAnEntry() {
        let lines = BIOSGuardUpdate.table(in: ArraySlice(Array("Title\r\n1 /P 7 ;FV_MAIN\r\n1 2 ;RAW\r\nnonsense\r\n".utf8)))
        XCTAssertEqual(lines.map(\.name), ["FV_MAIN", "RAW"])
        XCTAssertEqual(lines.map(\.key), ["/P", ""])
        XCTAssertEqual(lines.map(\.blockCount), [7, 2])
    }

    func testWhatIsNotAnUpdateIsSaidToBeNone() {
        XCTAssertFalse(BIOSGuardUpdate.isUpdate(block(0xFF, 0x100)))
        XCTAssertEqual(BIOSGuardUpdate.parse(block(0xFF, 0x100)), .failure(.notAnUpdate))
        XCTAssertEqual(BIOSGuardUpdate.parse([]), .failure(.notAnUpdate))
    }

    func testATableThatNamesNoBlocksIsRefused() {
        XCTAssertEqual(BIOSGuardUpdate.parse(file([])), .failure(.noEntries))
    }

    func testAFileCutShortSaysWhichBlockItEndsIn() {
        let whole = file(lines)
        // Into the data of the fourth block.
        let cut = Array(whole.prefix(whole.count - 0x20C - 0x20))
        XCTAssertEqual(BIOSGuardUpdate.parse(cut), .failure(.truncated(block: 3)))
    }

    func testATableNamingMoreBlocksThanFollowIsRefused() {
        var lines = lines
        lines.append(Line(key: "/X", name: "EXTRA", blocks: []))
        var bytes = file(lines)
        // The table says one block for EXTRA; none was written.
        let text = Array("0 ;EXTRA".utf8)
        if let at = bytes.firstRange(of: text) {
            bytes.replaceSubrange(at, with: Array("1 ;EXTRA".utf8))
        }
        XCTAssertEqual(BIOSGuardUpdate.parse(bytes), .failure(.truncated(block: 4)))
    }

    func testABlockOfAnotherPlatformIsNotABlockOfThisFile() {
        var bytes = file(lines)
        let headerSize = Int(bytes[0]) | Int(bytes[1]) << 8
        // The second block's PlatformID.
        let second = headerSize + 0x30 + 0x20 + 0x100 + 0x20C
        bytes.replaceSubrange((second + 4)..<(second + 14), with: Array("ALDERLAKE\u{0}".utf8))
        XCTAssertEqual(BIOSGuardUpdate.parse(bytes), .failure(.notABlock(block: 1)))
    }

    // MARK: - In the tree

    /// A boot block that is a volume and an NVRAM entry left erased — and,
    /// where asked, something of the vendor's after the blocks.
    private func treeFile(tail: [UInt8] = []) -> [UInt8] {
        file([Line(key: "/B", name: "FV_BB", blocks: [TestImage.volume(length: 0x400)]),
              Line(key: "/N", name: "NVRAM", blocks: [block(0xFF, 0x200)])],
             tail: tail)
    }

    private func update(in image: UEFIImage) throws -> UEFINode {
        try XCTUnwrap(image.roots.flatMap(\.flattened).first { $0.kind == .biosGuardUpdate })
    }

    func testAnUpdateAtTheTopOfTheFileIsARowOverItsHeaderAndBlocks() throws {
        let bytes = treeFile()
        let image = UEFIParser.parse(ImageReader(bytes).source)
        let update = try update(in: image)
        XCTAssertEqual(image.roots.map(\.kind), [.biosGuardUpdate], "the whole file, so the one root")
        let layout = try BIOSGuardUpdate.layout(in: ImageReader(bytes)).get()
        XCTAssertEqual(update.header, 0..<layout.headerSize)
        XCTAssertEqual(update.body, layout.headerSize..<UInt64(bytes.count))
        XCTAssertEqual(update.space, .file)
        XCTAssertEqual(update.compression, SectionCompression(algorithm: "BIOS Guard", decodes: true))
    }

    func testWhatFollowsTheBlocksIsReadBesideTheUpdate() throws {
        let tail = block(0xFF, 0x100) + TestImage.volume(length: 0x400)
        let image = UEFIParser.parse(ImageReader(treeFile(tail: tail)).source)
        let root = try XCTUnwrap(image.roots.first)
        XCTAssertEqual(root.kind, .uefiImage)
        XCTAssertEqual(root.children.map(\.kind), [.biosGuardUpdate, .padding, .volume])
    }

    func testTheEntriesAreStretchesOfTheAssembledRegionAndOpenAsRawAreas() throws {
        let image = UEFIParser.parse(ImageReader(treeFile()).source)
        let entries = try update(in: image).children
        let region = ByteSpace.decompressed(chain: [0])
        XCTAssertEqual(entries.map(\.kind), [.biosGuardEntry, .biosGuardEntry])
        XCTAssertEqual(entries.map(\.name), ["FV_BB", "NVRAM"])
        XCTAssertEqual(entries.map(\.range), [0..<0x400, 0x400..<0x600])
        XCTAssertEqual(entries.map(\.space), [region, region])
        XCTAssertEqual(entries[0].children.map(\.kind), [.volume])
        XCTAssertEqual(entries[0].children.first?.space, region)
        XCTAssertEqual(entries[1].children.map(\.isErased), [true])
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics)")
    }

    func testTheRegionSpaceReadsAsTheBlocksDataLaidEndToEnd() throws {
        let bytes = treeFile()
        let readers = SpaceReaders(file: ImageReader(bytes))
        let region = try XCTUnwrap(readers.reader(for: .decompressed(chain: [0])))
        XCTAssertEqual(region.bytes(region.all), TestImage.volume(length: 0x400) + block(0xFF, 0x200))
    }

    func testAnUpdateCutShortIsNotReadAsOne() {
        let bytes = Array(treeFile().dropLast(0x300))
        let image = UEFIParser.parse(ImageReader(bytes).source)
        XCTAssertFalse(image.roots.flatMap(\.flattened).contains { $0.kind == .biosGuardUpdate })
    }

    func testTheItemClassificationIsUEFIToolsPadding() throws {
        let update = try update(in: UEFIParser.parse(ImageReader(treeFile()).source))
        XCTAssertEqual(update.uefiItemType, UEFITypes.Item.padding.rawValue)
        XCTAssertEqual(update.children.first?.uefiItemType, UEFITypes.Item.padding.rawValue)
    }
}
