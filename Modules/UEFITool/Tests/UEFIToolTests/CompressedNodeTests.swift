import XCTest
import FirmwareCompressionTestSupport
import ToolModuleKit
import UEFIImage
@testable import UEFITool

/// A node inside a compressed section, as the panel shows it: drawn as the
/// section that holds it, read from the buffer, checked there, and never
/// written (`Design/UEFI/COMPRESSED_SECTIONS.md` §5.3).
final class CompressedNodeTests: XCTestCase {
    private struct Built {
        let bytes: [UInt8]
        let image: UEFIImage
        var section: UEFINode { image.roots[0] }
        var inner: UEFINode { image.roots[0].children[0] }
        var readers: SpaceReaders { SpaceReaders(file: ImageReader(bytes)) }
    }

    /// The smallest image with a node inside a compressed section: an LZMA
    /// compression section at offset 0, holding one FFS file header.
    private func built(innerHeaderChecksum: UInt8 = 0xAA) -> Built {
        let inner = TestUEFI.file(headerChecksum: innerHeaderChecksum).bytes
        let stream = LZMATestEncoder.lzma(inner)
        let size = UInt32(4 + 5 + stream.count)
        var bytes = (0..<3).map { UInt8((size >> (8 * $0)) & 0xFF) } + [0x01]
        bytes += (0..<4).map { UInt8((UInt32(inner.count) >> (8 * $0)) & 0xFF) }
        bytes.append(0x02)
        bytes += stream

        let file = UEFINode(
            kind: .file, subtype: 0x07, name: "Inner", guid: KnownGUIDs.volumeTopFile,
            header: 0..<0x18, body: 0x18..<0x100,
            space: .decompressed(chain: [0])
        )
        let section = UEFINode(
            kind: .section, subtype: 0x01, name: "LZMA compressed section",
            header: 0..<9, body: 9..<UInt64(bytes.count),
            children: [file]
        )
        return Built(
            bytes: bytes,
            image: UEFIImage(size: UInt64(bytes.count), roots: [section], addressDiff: 0xFFFF_0000)
        )
    }

    private func field(_ detail: UEFINodeDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    // MARK: - Zones

    func testANodeInsideIsDrawnAsTheSectionThatHoldsIt() {
        let built = built()
        let zones = UEFIPresenter.zones(for: built.inner, in: built.image)

        XCTAssertEqual(zones.zones.map(\.id), ["0", "0#body"],
                       "picking it in the dump brings back the section")
        XCTAssertEqual(zones.zones.map(\.range), [built.section.range, built.section.body])
        XCTAssertEqual(zones.zones.first?.name, "Inner (in LZMA compressed section)")
        XCTAssertEqual(zones.focus, "0#body")
    }

    /// Without the image there is no way to find the section, and buffer
    /// offsets are never drawn over the file instead.
    func testANodeInsideWithNoImagePublishesNothing() {
        XCTAssertEqual(UEFIPresenter.zones(for: built().inner), .empty)
    }

    // MARK: - Detail

    func testTheDetailReadsTheHeaderFromTheBufferAndSaysWhereFrom() throws {
        let built = built()
        let reader = try XCTUnwrap(built.readers.reader(for: built.inner.space))
        let detail = UEFIDetail.build(for: built.inner, image: built.image, reader: reader)

        XCTAssertEqual(field(detail, "Decompressed from"), "LZMA compressed section at 0x0")
        XCTAssertEqual(field(detail, "Size"), "0x100 (256)", "read from the buffer, not the file")
        XCTAssertNil(field(detail, "Address"), "a compressed node's address means nothing")
    }

    // MARK: - Checksums

    /// A wrong checksum inside is found in the buffer, and its repair is an
    /// offset into the buffer — which is what putting it back proves.
    func testAWrongChecksumInsideIsFoundInTheBuffer() throws {
        let wrong = built(innerHeaderChecksum: 0x00)
        let repairs = UEFIChecksumCheck.repairs(in: wrong.image, readers: wrong.readers)
        let fix = try XCTUnwrap(repairs[wrong.inner.id]?.first, "the stored checksum is not the sum")

        XCTAssertEqual(fix.offset, 0x10, "the header checksum's offset in the buffer")
        XCTAssertEqual(UEFIChecksumCheck.fields(of: repairs, in: wrong.image)[wrong.inner.id],
                       [.fileHeader])

        let right = built(innerHeaderChecksum: fix.bytes[0])
        XCTAssertNil(UEFIChecksumCheck.repairs(in: right.image, readers: right.readers)[right.inner.id])
    }

    // MARK: - Export

    func testAnOpenedSectionExportsItsWholeBufferAndANodeInsideItsOwnBytes() throws {
        let built = built()

        let body = try XCTUnwrap(UEFIPresenter.decompressedExport(for: built.section))
        XCTAssertEqual(body.space, .decompressed(chain: [0]))
        XCTAssertNil(body.range)
        XCTAssertEqual(body.menuTitle, "Export Decompressed Body…")
        let buffer = try XCTUnwrap(built.readers.reader(for: body.space))
        XCTAssertEqual(buffer.bytes(buffer.all), TestUEFI.file().bytes)

        let bytes = try XCTUnwrap(UEFIPresenter.decompressedExport(for: built.inner))
        XCTAssertEqual(bytes.space, built.inner.space)
        XCTAssertEqual(bytes.range, 0..<0x100)
        XCTAssertEqual(bytes.menuTitle, "Export Decompressed Bytes…")
        XCTAssertEqual(bytes.suggestedName, "Inner.bin")
        XCTAssertEqual(body.openTitle, "Open Decompressed Body in New Tab")
        XCTAssertEqual(bytes.openTitle, "Open Decompressed Bytes in New Tab")
        XCTAssertEqual(bytes.tabName(fileName: "bios.rom"), "bios_Inner.bin",
                       "named after the dump it came out of, then what it is")
        XCTAssertEqual(bytes.tabName(fileName: ""), "Inner.bin")

        XCTAssertNil(UEFIPresenter.decompressedExport(for: TestUEFI.file().node),
                     "a node of the file has nothing decompressed to save")
    }
}
