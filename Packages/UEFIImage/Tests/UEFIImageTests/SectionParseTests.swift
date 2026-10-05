import XCTest
@testable import UEFIImage

/// A file's body read as sections, and the encapsulating ones where the tree
/// stops being a list (§6).
final class SectionParseTests: XCTestCase {
    private func file(_ sections: [[UInt8]], ffs: EFIGUID = KnownGUIDs.ffsV2) -> UEFINode {
        UEFIParser.parse(TestImage.volume(
            fileSystem: ffs,
            files: [TestImage.sectionedFile(sections: sections)]
        )).roots[0].children[0]
    }

    private func diagnostics(_ sections: [[UInt8]]) -> [UEFIDiagnostic.Kind] {
        UEFIParser.parse(TestImage.volume(
            files: [TestImage.sectionedFile(sections: sections)]
        )).diagnostics.map(\.kind)
    }

    func testSectionsAreReadInOrder() {
        let node = file([
            TestImage.section(type: 0x10, body: [UInt8](repeating: 0xAB, count: 8)),
            TestImage.section(type: 0x13, body: [0x08])
        ])

        XCTAssertEqual(node.children.map(\.kind), [.section, .section])
        XCTAssertEqual(node.children.map(\.name), ["PE32 image", "DXE dependency"])
        XCTAssertEqual(node.children.map(\.range), [0x60..<0x6C, 0x6C..<0x71])
        XCTAssertEqual(node.children[0].header, 0x60..<0x64)
        XCTAssertEqual(node.children[0].body, 0x64..<0x6C)
    }

    /// Sections sit on four-byte boundaries where files sit on eight, and the
    /// bytes in between are still bytes.
    func testTheAlignmentGapBetweenSectionsIsKept() {
        let node = file([
            TestImage.section(type: 0x10, body: [1, 2, 3]),
            TestImage.section(type: 0x10, body: [4, 5, 6, 7])
        ])

        XCTAssertEqual(node.children.map(\.kind), [.section, .padding, .section])
        XCTAssertEqual(node.children.map(\.range), [0x60..<0x67, 0x67..<0x68, 0x68..<0x70])
    }

    /// Without this a volume is three hundred rows of GUIDs.
    func testANameSectionNamesTheFile() {
        let node = file([
            TestImage.section(type: 0x10, body: [1, 2, 3, 4]),
            TestImage.nameSection("PciBusDxe")
        ])

        XCTAssertEqual(node.name, "PciBusDxe")
        XCTAssertEqual(node.children.last?.name, "PciBusDxe")
    }

    /// And it is worth looking for one level down: a name section is often
    /// wrapped along with the image it names.
    func testANameSectionInsideAnEncapsulationStillNamesTheFile() {
        let node = file([TestImage.section(
            type: Section.disposable,
            body: TestImage.nameSection("SetupUtility")
        )])

        XCTAssertEqual(node.name, "SetupUtility")
    }

    /// The extended-size marker means an extended size only in an FFSv3
    /// volume. Anywhere else it is a size of `0xFFFFFF` — more than the file
    /// holds, so no section at all — and reading four extra bytes of header
    /// would eat the start of the body.
    func testTheExtendedSizeMarkerIsOnlyExtendedInFfsV3() {
        let sections = [TestImage.section(type: 0x10, body: [1, 2, 3, 4], extendedSize: true)]
        let node = file(sections)

        XCTAssertEqual(node.children.map(\.name), ["Non-UEFI data"])
        XCTAssertEqual(node.children[0].range.lowerBound, 0x60)
        XCTAssertEqual(diagnostics(sections), [.nonUEFIDataInSections])
    }

    /// A volume inside a section inside a file inside a volume — the point at
    /// which this format starts over one level down.
    func testAVolumeImageSectionHoldsAVolume() {
        let inner = TestImage.volume(
            length: 0x200,
            files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])]
        )
        let node = file([TestImage.section(type: Section.firmwareVolumeImage, body: inner)])
        let volume = node.children[0].children[0]

        XCTAssertEqual(volume.kind, .volume)
        XCTAssertEqual(volume.range, 0x64..<0x264)
        XCTAssertEqual(volume.children.map(\.kind), [.file, .freeSpace])
        XCTAssertEqual(volume.children[0].range, 0xAC..<0xCC)
    }

    /// A compression section that is not actually compressed still holds
    /// sections, and reading it as opaque would hide half an image (§6.2).
    func testAnUncompressedCompressionSectionIsWalkedThrough() {
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.compressionSection(algorithm: 0x00, body: inner)])
        let outer = node.children[0]

        XCTAssertEqual(outer.name, "Uncompressed section")
        XCTAssertEqual(outer.header, 0x60..<0x69)      // common header plus five
        XCTAssertEqual(outer.children.map(\.name), ["PE32 image"])
    }

    /// A compressed section whose body does not decode names its algorithm and
    /// keeps its body whole — no pretending the contents are readable. The
    /// sections that do decode are `CompressedSectionTests`.
    func testACompressedSectionThatDoesNotDecodeIsALeafThatNamesItsAlgorithm() {
        let node = file([TestImage.compressionSection(
            algorithm: 0x86, body: [UInt8](repeating: 0x5A, count: 32)
        )])

        XCTAssertEqual(node.children[0].name, "LZMA with x86 filter section")
        XCTAssertTrue(node.children[0].children.isEmpty)
        XCTAssertFalse(node.children[0].isExpandable, "it was tried, and there is nothing in it")
        XCTAssertEqual(node.children[0].body, 0x69..<0x89)
    }

    func testAGuidDefinedSectionIsNamedByItsGuid() {
        let lzma = KnownGUIDs.guid("EE4E5898-3914-4259-9D6E-DC7BD79403CF")
        let node = file([TestImage.guidedSection(
            guid: lzma, body: [UInt8](repeating: 0x11, count: 16)
        )])

        XCTAssertEqual(node.children[0].name, "LZMA section")
        XCTAssertEqual(node.children[0].guid, lzma)
        XCTAssertTrue(node.children[0].children.isEmpty)
    }

    /// CRC32 only checks the data, so what is inside is still there to read —
    /// the one GUID-defined section whose body is a run of sections.
    func testACrc32SectionIsWalkedThrough() {
        let crc32 = KnownGUIDs.guid("FC1BCDB0-7D31-49AA-936A-A4600D9DD083")
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.guidedSection(guid: crc32, body: inner)])

        XCTAssertEqual(node.children[0].name, "CRC32 section")
        XCTAssertEqual(node.children[0].children.map(\.name), ["PE32 image"])
    }

    /// The body starts where `DataOffset` says, not where the structure ends:
    /// vendors put certificates and their own headers in between (§6.3).
    func testTheDataOffsetDecidesWhereTheBodyStarts() {
        let crc32 = KnownGUIDs.guid("FC1BCDB0-7D31-49AA-936A-A4600D9DD083")
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.guidedSection(
            guid: crc32, body: inner, vendorHeader: [UInt8](repeating: 0xEE, count: 8)
        )])
        let section = node.children[0]

        XCTAssertEqual(section.header, 0x60..<0x80)    // 4 + 20 + 8
        XCTAssertEqual(section.children.map(\.range), [0x80..<0x88])
    }

    func testADisposableSectionIsWalkedThrough() {
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.section(type: Section.disposable, body: inner)])

        XCTAssertEqual(node.children[0].children.map(\.name), ["PE32 image"])
    }

    func testAnUnknownSectionTypeIsReportedAndKept() {
        let node = file([TestImage.section(type: 0x77, body: [1, 2, 3, 4])])

        XCTAssertEqual(node.children.map(\.name), ["Section type 0x77"])
        XCTAssertEqual(
            diagnostics([TestImage.section(type: 0x77, body: [1, 2, 3, 4])]),
            [.unknownType(.sectionHeader, 0x77)]
        )
    }

    /// The gap at `0x1A` is the specification's, and a range that papered over
    /// it would wave through a value that means something is wrong.
    func testTheGapInTheSectionTypesIsNotAType() {
        XCTAssertEqual(
            diagnostics([TestImage.section(type: 0x1A, body: [1, 2, 3, 4])]),
            [.unknownType(.sectionHeader, 0x1A)]
        )
        XCTAssertTrue(diagnostics([TestImage.section(type: 0x1B, body: [1, 2, 3, 4])]).isEmpty)
    }

    /// Zero would put the walk back on the same offset for ever (§11). The
    /// walk stops, and the rest of the body is one row of Non-UEFI data, as
    /// the reference keeps it.
    func testASectionOfZeroSizeStopsTheWalk() {
        let sections = [
            TestImage.section(type: 0x10, body: [1, 2, 3, 4], size: 0),
            TestImage.section(type: 0x13, body: [8])
        ]
        let node = file(sections)

        XCTAssertEqual(node.children.map(\.name), ["Non-UEFI data"])
        XCTAssertEqual(node.children[0].range.upperBound, node.body.upperBound)
        XCTAssertEqual(diagnostics(sections), [.nonUEFIDataInSections])
    }

    /// A size past what is left is not a section cut short but data of some
    /// other kind: said once, kept whole, after the sections that did read.
    func testASectionRunningPastTheFileLeavesTheRestAsNonUEFIData() {
        let sections = [
            TestImage.section(type: 0x10, body: [1, 2, 3, 4]),
            TestImage.section(type: 0x10, body: [1, 2, 3, 4], size: 0x400)
        ]
        let node = file(sections)

        XCTAssertEqual(node.children.map(\.name), ["PE32 image", "Non-UEFI data"])
        XCTAssertEqual(node.children[1].range, 0x68..<node.body.upperBound)
        XCTAssertTrue(node.children[1].children.isEmpty)
        XCTAssertEqual(diagnostics(sections), [.nonUEFIDataInSections])
    }

    /// A RIFF WAV file: `frames` of 16-bit PCM silence at `rate` in `channels`.
    private func wav(rate: UInt32 = 8000, channels: UInt16 = 2, frames: Int = 40) -> [UInt8] {
        var writer = BinaryWriter()
        let data = frames * Int(channels) * 2
        writer.raw(Array("RIFF".utf8))
        writer.u32(UInt32(4 + 8 + 16 + 8 + data))
        writer.raw(Array("WAVEfmt ".utf8))
        writer.u32(16)
        writer.u16(1)
        writer.u16(channels)
        writer.u32(rate)
        writer.u32(rate * UInt32(channels) * 2)
        writer.u16(channels * 2)
        writer.u16(16)
        writer.raw(Array("data".utf8))
        writer.u32(UInt32(data))
        writer.fill(UInt64(data), with: 0)
        return writer.bytes
    }

    /// ASUS keeps its POST sound as a Freeform file's whole body: `RIFF` reads
    /// as a section header whose size runs past the file. The body is Non-UEFI
    /// data, as the reference has it, and the sound a row inside it.
    func testAWAVWhereSectionsWouldBeIsARowOfItsOwn() throws {
        let sound = wav()
        let image = UEFIParser.parse(TestImage.volume(files: [TestImage.file(type: 0x02, body: sound)]))
        let file = image.roots[0].children[0]
        let data = try XCTUnwrap(file.children.first)

        XCTAssertEqual(file.children.map(\.name), ["Non-UEFI data"])
        XCTAssertEqual(data.children.map(\.kind), [.sound])
        XCTAssertEqual(data.children[0].name, "WAV, 8000 Hz, stereo")
        XCTAssertEqual(data.children[0].range, data.range.lowerBound..<(data.range.lowerBound + UInt64(sound.count)))
        XCTAssertEqual(data.children[0].uefiItemType, UEFITypes.Item.padding.rawValue, "padding to UEFITool")
        XCTAssertEqual(image.diagnostics.map(\.kind), [.nonUEFIDataInSections])

        let read = try XCTUnwrap(Sound.read(at: 0, limit: UInt64(sound.count), in: ImageReader(sound)))
        XCTAssertEqual(read.encodingName, "PCM")
        XCTAssertEqual(read.bitsPerSample, 16)
        XCTAssertEqual(read.duration ?? 0, 40.0 / 8000, accuracy: 1e-9)
    }

    /// A RIFF header with no data chunk, or one claiming more than there is,
    /// is not a sound.
    func testARIFFThatDoesNotReadThroughIsNoSound() {
        var cut = wav()
        cut.removeLast(8)
        XCTAssertNil(Sound.read(at: 0, limit: UInt64(cut.count), in: ImageReader(cut)))

        var noData = wav()
        noData.replaceSubrange(36..<40, with: Array("junk".utf8))
        XCTAssertNil(Sound.read(at: 0, limit: UInt64(noData.count), in: ImageReader(noData)))
    }

    /// FFSv3 puts a large section's size in a field of its own, and the header
    /// is four bytes longer for it (§6).
    func testAnExtendedSizeSectionHasALongerHeader() {
        let node = file(
            [TestImage.section(type: 0x10, body: [1, 2, 3, 4], extendedSize: true)],
            ffs: KnownGUIDs.ffsV3
        )

        XCTAssertEqual(node.children[0].header, 0x60..<0x68)
        XCTAssertEqual(node.children[0].body, 0x68..<0x6C)
    }

    /// Volume, file, section, volume again: a real image nests a dozen rows
    /// deep and a corrupt one nests for ever, so every level that can recurse
    /// counts the depth (§11).
    private var nestedImage: [UInt8] {
        let inner = TestImage.volume(length: 0x200, files: [TestImage.file(body: [1, 2, 3, 4])])
        return TestImage.volume(
            length: 0x800,
            files: [TestImage.sectionedFile(sections: [
                TestImage.section(type: Section.firmwareVolumeImage, body: inner)
            ])]
        )
    }

    func testSectionsStopAtTheDepthLimit() {
        let parsed = UEFIParser.parse(nestedImage, limits: UEFIParser.Limits(maxDepth: 2))
        let file = parsed.roots[0].children[0]

        XCTAssertEqual(file.kind, .file)
        XCTAssertTrue(file.children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .recursionLimit })
        XCTAssertEqual(parsed.diagnostics.first { $0.kind == .recursionLimit }?.severity, .error)
    }

    /// `levels` volumes, each the body of a volume-image section in a file of
    /// the one around it, with a plain file in the innermost.
    private func volumes(nested levels: Int) -> [UInt8] {
        var image = TestImage.volume(length: 0x200, files: [TestImage.file(body: [1, 2, 3, 4])])
        for _ in 1..<levels {
            image = TestImage.volume(
                length: UInt64(image.count + 0x200),
                files: [TestImage.sectionedFile(sections: [
                    TestImage.section(type: Section.firmwareVolumeImage, body: image)
                ])]
            )
        }
        return image
    }

    /// A Dell XPS image nests its DXE drivers twelve rows deep — volumes in
    /// compressed sections in volumes — and a volume costs the parser about
    /// three levels. Seven volumes deep is past what a limit of 16 allowed;
    /// the default reads them whole.
    func testTheDefaultLimitReadsSevenNestedVolumes() {
        let parsed = UEFIParser.parse(volumes(nested: 7))
        XCTAssertFalse(parsed.diagnostics.contains { $0.kind == .recursionLimit })

        var node = parsed.roots[0]
        var depth = 1
        while let inner = node.children.first?.children.first?.children.first, inner.kind == .volume {
            node = inner
            depth += 1
        }
        XCTAssertEqual(depth, 7)
        XCTAssertEqual(node.children.first?.kind, .file)
    }

    func testANestedVolumeStopsAtTheDepthLimit() {
        let parsed = UEFIParser.parse(nestedImage, limits: UEFIParser.Limits(maxDepth: 3))
        let volume = parsed.roots[0].children[0].children[0].children[0]

        XCTAssertEqual(volume.kind, .volume)
        XCTAssertTrue(volume.children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .recursionLimit })
    }
}
