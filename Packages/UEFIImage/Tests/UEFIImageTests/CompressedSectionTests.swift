import XCTest
import FirmwareCompression
import FirmwareCompressionTestSupport
@testable import UEFIImage

/// Compressed sections opened: decoded, walked as sections, every node inside
/// in a space of its own (`Design/UEFI/COMPRESSED_SECTIONS.md` §5, §6).
final class CompressedSectionTests: XCTestCase {
    private let lzmaGUID = KnownGUIDs.guid("EE4E5898-3914-4259-9D6E-DC7BD79403CF")
    private let lzmaX86GUID = KnownGUIDs.guid("D42AE6BD-1352-4BFB-909A-CA72A6EAE889")

    /// A run of sections as a file body lays them out, four-byte aligned.
    private func sections(_ list: [[UInt8]]) -> [UInt8] {
        var body = BinaryWriter()
        for section in list {
            body.pad(to: alignUp(body.count, to: 4)!, with: 0xFF)
            body.raw(section)
        }
        return body.bytes
    }

    /// What most compressed sections hold: a driver's name and its image —
    /// with a `call` in the image, for the x86 filter to have something to do.
    private var driver: [UInt8] {
        sections([
            TestImage.nameSection("InnerDriver"),
            TestImage.section(type: 0x10, body: [0xE8, 0x10, 0x00, 0x00, 0x00]
                + [UInt8](repeating: 0xCC, count: 35))
        ])
    }

    private func lzmaSection(_ inner: [UInt8]) -> [UInt8] {
        TestImage.compressionSection(
            algorithm: 0x02, body: LZMATestEncoder.lzma(inner),
            uncompressedLength: UInt32(inner.count)
        )
    }

    private func parsed(
        _ sections: [[UInt8]],
        limits: UEFIParser.Limits = .init()
    ) -> UEFIImage {
        UEFIParser.parse(
            TestImage.volume(length: 0x2000, files: [TestImage.sectionedFile(sections: sections)]),
            limits: limits
        )
    }

    /// The first section of the volume's first file.
    private func section(in image: UEFIImage) -> UEFINode {
        image.roots[0].children[0].children[0]
    }

    // MARK: - Opening

    func testAnLZMACompressionSectionOpensIntoTheSectionsItHolds() {
        let image = parsed([lzmaSection(driver)])
        let section = section(in: image)
        let inside = ByteSpace.decompressed(chain: [section.header.lowerBound])

        XCTAssertEqual(section.name, "LZMA compressed section")
        XCTAssertEqual(section.space, .file, "the section's own bytes are the file's")
        XCTAssertFalse(section.isExpandable, "a full parse opened it")
        XCTAssertEqual(section.children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertEqual(section.children.map(\.space), [inside, inside])
        XCTAssertEqual(section.children[0].header.lowerBound, 0,
                       "offsets start again at the beginning of the buffer")
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    func testAnLZMAGuidDefinedSectionOpensLikeACompressionSection() {
        let image = parsed([TestImage.guidedSection(
            guid: lzmaGUID, body: LZMATestEncoder.lzma(driver), attributes: 0x01
        )])

        XCTAssertEqual(section(in: image).children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    func testAnLZMAWithX86FilterSectionOpens() {
        let image = parsed([TestImage.guidedSection(
            guid: lzmaX86GUID, body: LZMATestEncoder.lzmaX86(driver), attributes: 0x01
        )])

        XCTAssertEqual(section(in: image).children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    /// A compressed section inside a volume inside a compressed section: the
    /// inner one's children name both sections on the way in.
    func testANestedCompressedSectionNamesBothSectionsInItsSpace() throws {
        let innerVolume = TestImage.volume(
            length: 0x800,
            files: [TestImage.sectionedFile(sections: [lzmaSection(driver)])]
        )
        let volumeImage = TestImage.section(type: 0x17, body: innerVolume)
        let image = parsed([lzmaSection(sections([volumeImage]))])

        let outer = section(in: image)
        let outerSpace = ByteSpace.decompressed(chain: [outer.header.lowerBound])
        let volume = try XCTUnwrap(outer.children.first?.children.first)
        XCTAssertEqual(volume.kind, .volume)
        XCTAssertEqual(volume.space, outerSpace)

        let inner = volume.children[0].children[0]
        XCTAssertEqual(inner.space, outerSpace)
        XCTAssertEqual(inner.children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertEqual(inner.children[0].space,
                       .decompressed(chain: [outer.header.lowerBound, inner.header.lowerBound]))
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    func testATianoCompressionSectionOpens() {
        let image = parsed([TestImage.compressionSection(
            algorithm: 0x01, body: TianoTestEncoder.tiano(driver),
            uncompressedLength: UInt32(driver.count)
        )])

        XCTAssertEqual(section(in: image).name, "Tiano compressed section")
        XCTAssertEqual(section(in: image).children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    /// The same compression type holds EFI 1.1, which only decoding tells.
    func testAnEFI11CompressionSectionOpens() {
        let image = parsed([TestImage.compressionSection(
            algorithm: 0x01, body: TianoTestEncoder.efi11(driver),
            uncompressedLength: UInt32(driver.count)
        )])

        XCTAssertEqual(section(in: image).children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    func testATianoGuidDefinedSectionOpens() {
        let tianoGUID = KnownGUIDs.guid("A31280AD-481E-41B6-95E8-127F4C984779")
        let image = parsed([TestImage.guidedSection(
            guid: tianoGUID, body: TianoTestEncoder.tiano(driver), attributes: 0x01
        )])

        XCTAssertEqual(section(in: image).children.map(\.name), ["InnerDriver", "PE32 image"])
        XCTAssertTrue(image.diagnostics.isEmpty, "\(image.diagnostics.map(\.message))")
    }

    /// Both readings decoding is the case only the bytes settle: the one that
    /// walks as sections wins, and Tiano when both — or neither — do.
    func testWhenBothReadingsDecodeTheOneThatReadsAsSectionsIsKept() {
        let noise = [UInt8](repeating: 0xAB, count: 40)

        let efi11Wins = CompressedSection.chooseTiano(.init(tiano: noise, efi11: driver))
        XCTAssertEqual(efi11Wins.variant, .efi11)
        XCTAssertEqual(efi11Wins.bytes, driver)

        XCTAssertEqual(CompressedSection.chooseTiano(.init(tiano: driver, efi11: driver)).variant, .tiano)
        XCTAssertEqual(CompressedSection.chooseTiano(.init(tiano: noise, efi11: noise)).variant, .tiano)
        XCTAssertEqual(CompressedSection.chooseTiano(.init(tiano: nil, efi11: noise)).variant, .efi11)
    }

    /// A compressed section says what it is compressed with, and whether it
    /// opens here — what a panel marks it by — decoded or not.
    func testACompressedSectionSaysItsAlgorithmAndWhetherItOpens() {
        let lzma = section(in: parsed([lzmaSection(driver)]))
        XCTAssertEqual(lzma.compression, SectionCompression(algorithm: "LZMA", decodes: true))

        let brotliGUID = KnownGUIDs.guid("3D532050-5CDA-4FD0-879E-0F7F630D5AFB")
        let brotli = section(in: parsed([TestImage.guidedSection(
            guid: brotliGUID, body: [UInt8](repeating: 0x11, count: 16)
        )]))
        XCTAssertEqual(brotli.compression, SectionCompression(algorithm: "Brotli", decodes: false))

        let crc32GUID = KnownGUIDs.guid("FC1BCDB0-7D31-49AA-936A-A4600D9DD083")
        let crc32 = section(in: parsed([TestImage.guidedSection(guid: crc32GUID, body: driver)]))
        XCTAssertNil(crc32.compression, "a CRC32 section checks its body and does not compress it")
    }

    // MARK: - What goes wrong

    func testADataThatDoesNotDecodeStaysALeafAndSaysWhy() {
        let garbage = [0x5D, 0x00, 0x00, 0x01, 0x00, 0x28, 0, 0, 0, 0, 0, 0, 0]
            + [UInt8](repeating: 0xA5, count: 40)
        let image = parsed([TestImage.compressionSection(
            algorithm: 0x02, body: garbage, uncompressedLength: 0x28
        )])
        let section = section(in: image)

        XCTAssertTrue(section.children.isEmpty)
        XCTAssertFalse(section.isExpandable)
        XCTAssertEqual(image.diagnostics.map(\.offset), [section.header.lowerBound])
        guard case .decompressionFailed(let algorithm, _) = image.diagnostics.first?.kind else {
            return XCTFail("\(image.diagnostics.map(\.message))")
        }
        XCTAssertEqual(algorithm, "LZMA")
    }

    /// The size is a number in an untrusted header: over the limit, the
    /// section is reported and nothing is allocated for it.
    func testASectionClaimingMoreThanTheLimitStaysALeaf() {
        let image = parsed([lzmaSection(driver)], limits: .init(maxDecompressedSize: 16))

        XCTAssertTrue(section(in: image).children.isEmpty)
        XCTAssertEqual(image.diagnostics.map(\.kind), [
            .decompressedTooLarge(algorithm: "LZMA", declared: UInt64(driver.count))
        ])
    }

    func testAnUncompressedLengthThatIsNotWhatCameOutIsReported() {
        let image = parsed([TestImage.compressionSection(
            algorithm: 0x02, body: LZMATestEncoder.lzma(driver),
            uncompressedLength: UInt32(driver.count) + 4
        )])

        XCTAssertEqual(section(in: image).children.count, 2, "it still opens")
        XCTAssertEqual(image.diagnostics.map(\.kind), [
            .decompressedSizeMismatch(stored: UInt64(driver.count) + 4, computed: UInt64(driver.count))
        ])
    }

    func testACompressedGuidDefinedSectionWithoutProcessingRequiredIsReported() {
        let image = parsed([TestImage.guidedSection(
            guid: lzmaGUID, body: LZMATestEncoder.lzma(driver), attributes: 0
        )])
        let section = section(in: image)

        XCTAssertEqual(section.children.count, 2, "and it is decoded all the same")
        XCTAssertEqual(image.diagnostics, [
            UEFIDiagnostic(.processingRequiredNotSet, at: section.header.lowerBound)
        ])
    }

    /// Trouble inside a buffer is located at bytes of the file — the section
    /// that holds it — with the offset inside kept.
    func testADiagnosticInsideIsLocatedAtTheCompressedSection() throws {
        let inner = sections([TestImage.section(type: 0x1A, body: [1, 2, 3, 4])])
        let image = parsed([lzmaSection(inner)])
        let section = section(in: image)
        let diagnostic = try XCTUnwrap(image.diagnostics.first)

        XCTAssertEqual(diagnostic.kind, .unknownType(.sectionHeader, 0x1A))
        XCTAssertEqual(diagnostic.offset, section.header.lowerBound)
        XCTAssertEqual(diagnostic.inside, .init(
            space: .decompressed(chain: [section.header.lowerBound]), offset: 3
        ))
        XCTAssertTrue(diagnostic.message.contains("decompresses to"), diagnostic.message)
    }

    // MARK: - Lookups by file offset

    func testALookupByFileOffsetEndsAtAnOpenedSection() {
        let image = parsed([lzmaSection(driver)])
        let section = section(in: image)

        XCTAssertEqual(image.innermostNode(containing: section.body.lowerBound + 2), section)
    }

    // MARK: - The buffers

    func testABufferIsDecodedOnceAndDroppedOnlyByAnEditOverItsSection() throws {
        let compressed = lzmaSection(driver)
        let file = ImageReader([UInt8](repeating: 0xFF, count: 0x20) + compressed)
        let buffers = DecompressedBuffers()
        let space = ByteSpace.file.inside(sectionAt: 0x20)

        let reader = try buffers.reader(for: space, file: file, limit: 1 << 20).get()
        XCTAssertEqual(reader.bytes(reader.all), driver)
        XCTAssertEqual(buffers.count, 1)

        buffers.drop(overlapping: 0..<0x10)
        XCTAssertEqual(buffers.count, 1, "an edit before the section leaves it")
        buffers.drop(overlapping: 0x30..<0x31)
        XCTAssertEqual(buffers.count, 0, "an edit inside it does not")
    }

    func testAnEvictedBufferIsDecodedAgainFromTheFile() throws {
        let file = ImageReader(lzmaSection(driver) + [0xFF, 0xFF, 0xFF, 0xFF] + lzmaSection(driver))
        let second = UInt64(lzmaSection(driver).count + 4)
        let buffers = DecompressedBuffers(budget: driver.count)

        _ = try buffers.reader(for: .file.inside(sectionAt: 0), file: file, limit: 1 << 20).get()
        _ = try buffers.reader(for: .file.inside(sectionAt: second), file: file, limit: 1 << 20).get()
        XCTAssertEqual(buffers.count, 1, "the budget holds one")

        let again = try buffers.reader(for: .file.inside(sectionAt: 0), file: file, limit: 1 << 20).get()
        XCTAssertEqual(again.bytes(again.all), driver)
    }
}

/// The same sections, opened one at a time by a lazy tree.
@MainActor
final class LazyCompressedSectionTests: XCTestCase {
    private func built(_ bytes: [UInt8]) async -> LazyUEFITree {
        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in
            tree.whenReady { continuation.resume() }
        }
        return tree
    }

    private func expandAsync(_ tree: LazyUEFITree, _ id: NodeID) async -> [UEFINode] {
        await withCheckedContinuation { continuation in
            tree.expand(id) { continuation.resume(returning: $0) }
        }
    }

    private func chain(_ tree: LazyUEFITree, containing offset: UInt64) async -> [UEFINode] {
        await withCheckedContinuation { continuation in
            tree.materialize(containing: offset) { continuation.resume(returning: $0) }
        }
    }

    private var driver: [UInt8] {
        TestImage.nameSection("InnerDriver")
    }

    /// Two volumes back to back: the compressed section in the first, the
    /// edit that must not touch it in the second.
    private func image() -> [UInt8] {
        let compressed = TestImage.compressionSection(
            algorithm: 0x02, body: LZMATestEncoder.lzma(driver),
            uncompressedLength: UInt32(driver.count)
        )
        return TestImage.volume(
            length: 0x1000, files: [TestImage.sectionedFile(sections: [compressed])]
        ) + TestImage.volume(length: 0x1000, files: [TestImage.file(body: [1, 2, 3])])
    }

    func testAReachedSectionIsNotDecodedUntilItIsOpened() async throws {
        let tree = await built(image())
        // The section's header is at 0x60: volume header 0x48, file header 0x18.
        let reached = await chain(tree, containing: 0x70)
        let section = try XCTUnwrap(reached.last)

        XCTAssertEqual(section.kind, .section)
        XCTAssertTrue(section.isExpandable, "reaching it does not open it")
        XCTAssertTrue(section.children.isEmpty)

        let children = await expandAsync(tree, section.id)
        XCTAssertEqual(children.map(\.name), ["InnerDriver"])
        XCTAssertEqual(children.first?.space, .decompressed(chain: [0x60]))
    }

    func testAnEditOverTheSectionClosesItAndAnEditElsewhereDoesNot() async throws {
        let tree = await built(image())
        let reached = await chain(tree, containing: 0x70)
        let section = try XCTUnwrap(reached.last)
        _ = await expandAsync(tree, section.id)

        tree.invalidate(editedRange: 0x1100..<0x1101, sizeDelta: 0)
        XCTAssertEqual(tree.node(section.id)?.children.map(\.name), ["InnerDriver"],
                       "an edit in the other volume leaves the opened section open")

        tree.invalidate(editedRange: 0x70..<0x71, sizeDelta: 0)
        let closed = try XCTUnwrap(tree.node(section.id))
        XCTAssertTrue(closed.children.isEmpty, "an edit over its bytes closes it")
        XCTAssertTrue(closed.isExpandable, "and it can be opened again")
    }
}
