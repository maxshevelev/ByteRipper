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

    // MARK: - Open and save

    func testACompressedSectionOffersItsWholeBufferAndANodeInsideOffersItsOwnBytes() throws {
        let built = built()

        let body = try XCTUnwrap(UEFIPresenter.decompressedBody(for: built.section))
        XCTAssertEqual(body.space, .decompressed(chain: [0]))
        XCTAssertEqual(body.saveTitle, "Save Decompressed Body as…")
        XCTAssertEqual(body.openTitle, "Open Decompressed Body")
        XCTAssertEqual(body.suggestedName, "LZMA compressed section decompressed.bin")
        let sectionAsNode = try XCTUnwrap(UEFIPresenter.nodeOpen(for: built.section, in: built.image, body: false))
        XCTAssertEqual(sectionAsNode.suggestedName, "LZMA compressed section.bin",
                       "the section itself keeps its plain name; only what it opens to is marked")
        XCTAssertEqual(UEFIPresenter.nodeOpenTitle(for: built.section, body: false), "Open “LZMA compressed section”",
                       "a node of the file is opened as it always was")
        let buffer = try XCTUnwrap(built.readers.reader(for: body.space))
        XCTAssertEqual(buffer.bytes(buffer.all), TestUEFI.file().bytes)

        // Nothing else is offered for what is inside: opening or saving it is
        // reading those bytes, and the titles say they are decompressed.
        XCTAssertNil(UEFIPresenter.decompressedBody(for: built.inner))
        XCTAssertEqual(UEFIPresenter.nodeOpenTitle(for: built.inner, body: false), "Open Decompressed “Inner”")
        XCTAssertEqual(UEFIPresenter.nodeOpenTitle(for: built.inner, body: true), "Open Decompressed Body of “Inner”")
        XCTAssertEqual(UEFIPresenter.nodeSaveTitle(for: built.inner, body: false), "Save Decompressed “Inner” as…")
        XCTAssertEqual(UEFIPresenter.nodeSaveTitle(for: built.inner, body: true),
                       "Save Decompressed Body of “Inner” as…")
        let unnamed = UEFINode(kind: .section, name: "", header: 0..<4, body: 4..<0x40,
                               space: .decompressed(chain: [0]))
        XCTAssertEqual(UEFIPresenter.nodeOpenTitle(for: unnamed, body: false), "Open Decompressed Node")
        XCTAssertEqual(UEFIPresenter.nodeOpenTitle(for: unnamed, body: true), "Open Decompressed Node Body")
        XCTAssertEqual(UEFIPresenter.nodeSaveTitle(for: unnamed, body: false), "Save Decompressed Node as…")
        XCTAssertEqual(UEFIPresenter.nodeSaveTitle(for: unnamed, body: true), "Save Decompressed Node Body as…")

        let asNode = try XCTUnwrap(UEFIPresenter.nodeOpen(for: built.inner, in: built.image, body: false))
        XCTAssertEqual(asNode.range, 0..<0x100)
        XCTAssertEqual(asNode.suggestedName, "Inner decompressed.bin")
        XCTAssertEqual(asNode.partName(fileName: "bios.rom"), "bios_Inner decompressed.bin",
                       "named after the dump it came out of, then what it is")
        XCTAssertEqual(try XCTUnwrap(UEFIPresenter.nodeOpen(for: built.inner, in: built.image, body: true)).suggestedName,
                       "Inner decompressed body.bin")
        XCTAssertEqual(body.tabName(fileName: "bios.rom"), "bios_LZMA compressed section decompressed.bin")
        XCTAssertEqual(UEFIPresenter.fileSource(of: built.inner, in: built.image),
                       built.section.fileRange,
                       "a panel from inside is linked to the compressed section holding it")
        XCTAssertEqual(UEFIPresenter.fileSource(of: built.section, in: built.image),
                       built.section.fileRange)

        XCTAssertNil(UEFIPresenter.decompressedBody(for: TestUEFI.file().node),
                     "a node of the file has nothing decompressed to save")
    }

    /// The row says it is compressed before it is opened, so the body is
    /// offered then — and reading it decodes it.
    func testAClosedCompressedSectionOffersItsBodyDecodedOnDemand() throws {
        let built = built()
        var closed = built.section
        closed.children = []
        closed.isExpandable = true
        closed.compression = SectionCompression(algorithm: "LZMA", decodes: true)

        let body = try XCTUnwrap(UEFIPresenter.decompressedBody(for: closed))
        XCTAssertEqual(body.space, .decompressed(chain: [0]))
        XCTAssertEqual(body.openTitle, "Open Decompressed Body")
        let buffer = try XCTUnwrap(built.readers.reader(for: body.space))
        XCTAssertEqual(buffer.bytes(buffer.all), TestUEFI.file().bytes)

        var undecodable = closed
        undecodable.compression = SectionCompression(algorithm: "Unknown", decodes: false)
        undecodable.isExpandable = false
        XCTAssertNil(UEFIPresenter.decompressedBody(for: undecodable),
                     "a section the decoder cannot read has nothing to save")

        var failed = closed
        failed.isExpandable = false
        XCTAssertNil(UEFIPresenter.decompressedBody(for: failed),
                     "one that was opened and did not decompress offers nothing either")
    }

    // MARK: - A double click

    /// A double click opens what the node holds: the decompressed body of a
    /// compressed section, the body of any other node, and the node itself
    /// where it has no body apart from itself.
    func testADoubleClickOpensTheDecompressedBodyOrTheBody() {
        let built = built()
        XCTAssertEqual(UEFIPresenter.content(of: built.section), .decompressedBody)
        XCTAssertEqual(UEFIPresenter.content(of: built.inner), .body, "a node inside is read from its buffer")

        var closed = built.section
        closed.children = []
        closed.isExpandable = true
        closed.compression = SectionCompression(algorithm: "LZMA", decodes: true)
        XCTAssertEqual(UEFIPresenter.content(of: closed), .decompressedBody, "decoded when it is asked for")

        var undecodable = closed
        undecodable.compression = SectionCompression(algorithm: "Unknown", decodes: false)
        undecodable.isExpandable = false
        XCTAssertEqual(UEFIPresenter.content(of: undecodable), .body, "what the decoder cannot read is the bytes it is")

        let headerless = UEFINode(kind: .padding, name: "Padding", header: 0..<0, body: 0..<0x40)
        XCTAssertEqual(UEFIPresenter.content(of: headerless), .node)
        let bare = UEFINode(kind: .section, name: "Bare", header: 0..<4, body: 4..<4)
        XCTAssertEqual(UEFIPresenter.content(of: bare), .node, "a header and nothing after it")
    }
}
