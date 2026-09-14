import XCTest
import FirmwareCompression
import FirmwareCompressionTestSupport
@testable import UEFIImage

/// Putting an edited part back (`Design/UEFI/UPDATE_IN_PARENT.md` §6, §8):
/// every result is applied to the file and parsed again.
final class UEFIRebuildTests: XCTestCase {
    private let otherGUID = KnownGUIDs.guid("22222222-3333-4444-5555-666666666666")
    private let lzmaX86GUID = KnownGUIDs.guid("D42AE6BD-1352-4BFB-909A-CA72A6EAE889")

    private func sections(_ list: [[UInt8]]) -> [UInt8] {
        var body = BinaryWriter()
        for section in list {
            body.pad(to: alignUp(body.count, to: 4)!, with: 0x00)
            body.raw(section)
        }
        return body.bytes
    }

    private var fileA: [UInt8] {
        TestImage.sectionedFile(sections: [
            TestImage.nameSection("Drv"), TestImage.section(type: Section.raw, body: [1, 2, 3, 4, 5, 6, 7, 8])
        ])
    }

    private func fileB(type: UInt8 = FFS.rawType, attributes: UInt8 = 0) -> [UInt8] {
        TestImage.file(guid: otherGUID, type: type, attributes: attributes,
                       body: [UInt8](repeating: 0x42, count: 40))
    }

    private func driver(_ name: String = "InnerDriver", extra: Int = 0) -> [UInt8] {
        var list = [
            TestImage.nameSection(name),
            TestImage.section(type: 0x10, body: [0xE8, 0x10, 0x00, 0x00, 0x00] + [UInt8](repeating: 0xCC, count: 35))
        ]
        if extra > 0 {
            list.append(TestImage.section(type: Section.raw,
                                          body: (0..<extra).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        }
        return sections(list)
    }

    private func plan(_ replacement: [UInt8], at target: UEFIRebuild.Target, in file: [UInt8],
                      file line: UInt = #line) throws -> [UInt8] {
        try planned(replacement, at: target, in: file, file: line).file
    }

    /// The file with the plan written, and what the plan said.
    private func planned(_ replacement: [UInt8], at target: UEFIRebuild.Target, in file: [UInt8],
                         file line: UInt = #line) throws -> (file: [UInt8], warnings: [String]) {
        switch UEFIRebuild.plan(replacement, at: target, in: file) {
        case .success(let plan):
            XCTAssertTrue(plan.warnings.contains(UEFIRebuild.rangesNotChecked), line: line)
            var result = file
            result.replaceSubrange(Int(plan.offset)..<(Int(plan.offset) + plan.bytes.count), with: plan.bytes)
            return (result, plan.warnings)
        case .failure(let refusal):
            XCTFail("refused: \(refusal.message)", line: line)
            throw refusal
        }
    }

    private func refusal(_ replacement: [UInt8], at target: UEFIRebuild.Target, in file: [UInt8]) -> String? {
        if case .failure(let refusal) = UEFIRebuild.plan(replacement, at: target, in: file) {
            return refusal.message
        }
        return nil
    }

    private func damage(_ image: UEFIImage) -> [UEFIDiagnostic] {
        image.diagnostics.filter {
            let name = "\($0.kind)"
            return ["checksumMismatch", "sizeMismatch", "truncated", "decompression", "zeroSize"]
                .contains { name.hasPrefix($0) }
        }
    }

    private func bytes(_ file: [UInt8], _ range: Range<UInt64>) -> [UInt8] {
        Array(file[Int(range.lowerBound)..<Int(range.upperBound)])
    }

    // MARK: - In the file

    func testAFileEditedInPlaceGetsItsChecksumsBack() throws {
        let image = TestImage.volume(length: 0x400, files: [fileA])
        let node = UEFIParser.parse(image).roots[0].children[0]
        var edited = bytes(image, node.range)
        edited[edited.count - 1] ^= 0xFF

        let rebuilt = try plan(edited, at: .init(space: .file, range: node.range), in: image)

        let parsed = UEFIParser.parse(rebuilt)
        XCTAssertEqual(damage(parsed), [], "the file's body checksum is put right")
        XCTAssertEqual(rebuilt[Int(node.range.upperBound) - 1], image[Int(node.range.upperBound) - 1] ^ 0xFF)
    }

    /// A grown file pushes the file after it into the volume's free space; the
    /// file after it arrives whole, and nothing is left broken.
    func testAGrownFileMovesTheFileAfterItIntoTheFreeSpace() throws {
        let image = TestImage.volume(length: 0x400, files: [fileA, fileB()])
        let node = UEFIParser.parse(image).roots[0].children[0]
        let grown = TestImage.sectionedFile(sections: [
            TestImage.nameSection("Drv"), TestImage.section(type: Section.raw, body: [1, 2, 3, 4, 5, 6, 7, 8]),
            TestImage.section(type: Section.raw, body: [UInt8](repeating: 9, count: 40))
        ])

        let rebuilt = try plan(grown, at: .init(space: .file, range: node.range), in: image)

        let parsed = UEFIParser.parse(rebuilt)
        XCTAssertEqual(damage(parsed), [])
        let files = parsed.roots[0].children.filter { $0.kind == .file }
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].children.filter { $0.kind == .section }.count, 3)
        XCTAssertEqual(bytes(rebuilt, files[1].body), [UInt8](repeating: 0x42, count: 40))
        XCTAssertGreaterThan(files[1].header.lowerBound, node.range.upperBound)
        XCTAssertEqual(rebuilt.count, image.count)
    }

    func testAShrunkFileLeavesMoreFreeSpace() throws {
        let image = TestImage.volume(length: 0x400, files: [fileA, fileB()])
        let parsedBefore = UEFIParser.parse(image)
        let node = parsedBefore.roots[0].children[0]
        let freeBefore = parsedBefore.roots[0].children.first { $0.kind == .freeSpace }?.range.count ?? 0
        let shrunk = TestImage.sectionedFile(sections: [TestImage.nameSection("Drv")])

        let rebuilt = try plan(shrunk, at: .init(space: .file, range: node.range), in: image)

        let parsed = UEFIParser.parse(rebuilt)
        XCTAssertEqual(damage(parsed), [])
        let free = parsed.roots[0].children.first { $0.kind == .freeSpace }?.range.count ?? 0
        XCTAssertGreaterThan(free, freeBefore)
        let files = parsed.roots[0].children.filter { $0.kind == .file }
        XCTAssertEqual(bytes(rebuilt, files[1].body), [UInt8](repeating: 0x42, count: 40))
    }

    func testGrowthPastTheFreeSpaceIsRefusedWithTheNumbers() throws {
        let image = TestImage.volume(length: 0xD0, files: [fileA, fileB()])
        let node = UEFIParser.parse(image).roots[0].children[0]
        let big = TestImage.sectionedFile(sections: [
            TestImage.nameSection("Drv"),
            TestImage.section(type: Section.raw, body: [UInt8](repeating: 9, count: 64))
        ])

        let message = try XCTUnwrap(refusal(big, at: .init(space: .file, range: node.range), in: image))
        XCTAssertTrue(message.contains("free"), message)
    }

    func testAFixedFileIsNotMoved() throws {
        let image = TestImage.volume(length: 0x400, files: [fileA, fileB(attributes: FFS.fixed)])
        let node = UEFIParser.parse(image).roots[0].children[0]
        let grown = TestImage.sectionedFile(sections: [
            TestImage.nameSection("Drv"), TestImage.section(type: Section.raw, body: [UInt8](repeating: 9, count: 64))
        ])

        let message = try XCTUnwrap(refusal(grown, at: .init(space: .file, range: node.range), in: image))
        XCTAssertTrue(message.contains("fixed"), message)
    }

    func testCodeThatRunsInPlaceIsNotMoved() throws {
        let peim = TestImage.sectionedFile(guid: otherGUID, type: 0x06, sections: [TestImage.nameSection("Pei")])
        let image = TestImage.volume(length: 0x400, files: [fileA, peim])
        let node = UEFIParser.parse(image).roots[0].children[0]
        let grown = TestImage.sectionedFile(sections: [
            TestImage.nameSection("Drv"), TestImage.section(type: Section.raw, body: [UInt8](repeating: 9, count: 64))
        ])

        let message = try XCTUnwrap(refusal(grown, at: .init(space: .file, range: node.range), in: image))
        XCTAssertTrue(message.contains("runs in place"), message)
    }

    /// A volume that fills the file has no empty space after it to grow into.
    func testAVolumeWithNothingAfterItCannotGrow() throws {
        let image = TestImage.volume(length: 0x400, files: [fileA])
        let volume = UEFIParser.parse(image).roots[0]
        let longer = TestImage.volume(length: 0x800, files: [fileA])

        let message = try XCTUnwrap(refusal(longer, at: .init(space: .file, range: volume.range), in: image))
        XCTAssertTrue(message.contains("only 0x0 empty bytes follow it before the end of the file"), message)
    }

    // MARK: - A volume at its own length (§7)

    private let secondVolume = TestImage.volume(length: 0x400, files: [
        TestImage.file(guid: KnownGUIDs.guid("33333333-4444-5555-6666-777777777777"),
                       body: [UInt8](repeating: 0x5A, count: 24))
    ])

    /// `first`, `gap` erased bytes, and a second volume that has to stay put.
    private func volumes(_ first: [UInt8], gap: Int) -> [UInt8] {
        first + [UInt8](repeating: 0xFF, count: gap) + secondVolume
    }

    /// The structures at the top of a file: volumes with padding around them
    /// are held by one image node.
    private func top(_ image: [UInt8]) -> [UEFINode] {
        let roots = UEFIParser.parse(image).roots
        return roots.count == 1 && roots[0].kind == .uefiImage ? roots[0].children : roots
    }

    /// A volume put back longer is written at its new length; the empty space
    /// after it gives up the difference, and the volume after that stays where
    /// it was, byte for byte.
    func testAVolumePutBackLongerTakesTheEmptySpaceAfterIt() throws {
        let image = volumes(TestImage.volume(length: 0x400, files: [fileA]), gap: 0x800)
        let volume = top(image)[0]
        let longer = TestImage.volume(length: 0x800, files: [fileA, fileB()])

        let (rebuilt, warnings) = try planned(longer, at: .init(space: .file, range: volume.range), in: image)

        XCTAssertEqual(damage(UEFIParser.parse(rebuilt)), [])
        let after = top(rebuilt)
        XCTAssertEqual(after.map(\.kind), [.volume, .padding, .volume])
        guard after.count == 3 else { return }
        XCTAssertEqual(after[0].range, 0..<0x800)
        XCTAssertEqual(after[1].range, 0x800..<0xC00)
        XCTAssertEqual(bytes(rebuilt, 0xC00..<0x1000), secondVolume, "the next volume did not move")
        XCTAssertEqual(rebuilt.count, image.count)
        XCTAssertTrue(warnings.contains { $0.contains("flash map") }, "\(warnings)")
    }

    /// A volume put back shorter leaves its old tail erased, as padding.
    func testAVolumePutBackShorterGivesTheRestToTheEmptySpace() throws {
        let image = volumes(TestImage.volume(length: 0x400, files: [fileA]), gap: 0x400)
        let volume = top(image)[0]
        let shorter = TestImage.volume(length: 0x200, files: [fileA])

        let rebuilt = try plan(shorter, at: .init(space: .file, range: volume.range), in: image)

        XCTAssertEqual(damage(UEFIParser.parse(rebuilt)), [])
        let after = top(rebuilt)
        XCTAssertEqual(after.map(\.kind), [.volume, .padding, .volume])
        guard after.count == 3 else { return }
        XCTAssertEqual(after[0].range, 0..<0x200)
        XCTAssertEqual(after[1].range, 0x200..<0x800)
        XCTAssertTrue(after[1].isErased)
        XCTAssertEqual(bytes(rebuilt, 0x800..<0xC00), secondVolume)
    }

    /// Bytes added to a volume in its tab without touching its header: the
    /// header is made to say the new length, in whole blocks.
    func testAVolumeWhoseHeaderDoesNotSayItsLengthIsGivenIt() throws {
        let image = volumes(TestImage.volume(length: 0x400, files: [fileA], blockMapLength: 0x100), gap: 0x400)
        let volume = top(image)[0]
        let longer = bytes(image, volume.range) + [UInt8](repeating: 0xFF, count: 0x200)

        let (rebuilt, warnings) = try planned(longer, at: .init(space: .file, range: volume.range), in: image)

        XCTAssertEqual(damage(UEFIParser.parse(rebuilt)), [])
        XCTAssertEqual(top(rebuilt).first?.range, 0..<0x600)
        XCTAssertTrue(warnings.contains { $0.contains("header now gives 0x600") }, "\(warnings)")

        let odd = bytes(image, volume.range) + [UInt8](repeating: 0xFF, count: 8)
        let message = try XCTUnwrap(refusal(odd, at: .init(space: .file, range: volume.range), in: image))
        XCTAssertTrue(message.contains("whole blocks"), message)
    }

    func testAVolumeLongerThanTheEmptySpaceAfterItIsRefused() throws {
        let image = volumes(TestImage.volume(length: 0x400, files: [fileA]), gap: 0x100)
        let volume = top(image)[0]
        let longer = TestImage.volume(length: 0x800, files: [fileA])

        let message = try XCTUnwrap(refusal(longer, at: .init(space: .file, range: volume.range), in: image))
        XCTAssertTrue(message.contains("only 0x100 empty bytes follow it"), message)
    }

    func testAVolumeHoldingTheVolumeTopFileKeepsItsSize() throws {
        let vtf = TestImage.volumeTopFile(size: 0x100)
        let image = volumes(TestImage.volume(length: 0x800, files: [fileA], lastFile: vtf), gap: 0x800)
        let volume = self.top(image)[0]
        let longer = TestImage.volume(length: 0x1000, files: [fileA], lastFile: vtf)

        let message = try XCTUnwrap(refusal(longer, at: .init(space: .file, range: volume.range), in: image))
        XCTAssertTrue(message.contains("Volume Top File"), message)
    }

    /// A file that outgrows a volume in the file grows the volume by whole
    /// blocks into the empty space after it.
    func testAVolumeInTheFileGrowsIntoTheEmptySpaceAfterIt() throws {
        let image = volumes(TestImage.volume(length: 0x100, files: [fileA]), gap: 0x400)
        let node = try XCTUnwrap(top(image).first?.children.first { $0.kind == .file })
        let big = TestImage.file(body: [UInt8](repeating: 0x22, count: 0x180))

        let (rebuilt, warnings) = try planned(big, at: .init(space: .file, range: node.range), in: image)

        XCTAssertEqual(damage(UEFIParser.parse(rebuilt)), [])
        XCTAssertEqual(top(rebuilt).first?.range, 0..<0x200, "0x48 + 0x198 = 0x1E0 takes two blocks of 0x100")
        XCTAssertEqual(bytes(rebuilt, 0x500..<0x900), secondVolume)
        XCTAssertTrue(warnings.contains { $0.contains("taken from the empty space") }, "\(warnings)")
    }

    /// The Volume Top File stays flush with the end; the pad file in front of it
    /// gives up the room.
    func testTheVolumeTopFileStaysAtTheEnd() throws {
        let image = TestImage.volume(length: 0x800, files: [fileA], lastFile: TestImage.volumeTopFile(size: 0x100))
        let parsedBefore = UEFIParser.parse(image)
        let node = parsedBefore.roots[0].children[0]
        let top = try XCTUnwrap(parsedBefore.allNodes.first { $0.guid == KnownGUIDs.volumeTopFile })
        let grown = TestImage.sectionedFile(sections: [
            TestImage.nameSection("Drv"), TestImage.section(type: Section.raw, body: [UInt8](repeating: 9, count: 200))
        ])

        let rebuilt = try plan(grown, at: .init(space: .file, range: node.range), in: image)

        let parsed = UEFIParser.parse(rebuilt)
        XCTAssertEqual(damage(parsed), [])
        let after = try XCTUnwrap(parsed.allNodes.first { $0.guid == KnownGUIDs.volumeTopFile })
        XCTAssertEqual(after.range, top.range)
        XCTAssertEqual(bytes(rebuilt, after.range), bytes(image, top.range))
    }

    // MARK: - Out of a compressed section

    private func compressedImage(_ section: [UInt8]) -> (file: [UInt8], section: UEFINode) {
        let image = TestImage.volume(length: 0x2000, files: [TestImage.sectionedFile(sections: [section]), fileB()])
        let node = UEFIParser.parse(image).roots[0].children[0].children[0]
        return (image, node)
    }

    private func lzma(_ inner: [UInt8]) -> [UInt8] {
        TestImage.compressionSection(algorithm: 0x02, body: LZMATestEncoder.lzma(inner),
                                     uncompressedLength: UInt32(inner.count))
    }

    private func buffer(of section: UEFINode, in file: [UInt8]) -> [UInt8]? {
        let readers = SpaceReaders(file: ImageReader(file))
        let space = ByteSpace.decompressed(chain: [section.header.lowerBound])
        return readers.reader(for: space).flatMap { $0.bytes($0.all) }
    }

    func testADecompressedBodyGoesBackIntoItsSection() throws {
        let (image, section) = compressedImage(lzma(driver()))
        let edited = driver("InnerDriveX")

        let rebuilt = try plan(edited, at: .init(space: .inside(section)), in: image)

        XCTAssertEqual(damage(UEFIParser.parse(rebuilt)), [])
        XCTAssertEqual(buffer(of: section, in: rebuilt), edited)
    }

    /// A body that grew compresses to a longer stream: the section, its file
    /// and the file after it all make room.
    func testABodyThatGrewMakesRoomAllTheWayOut() throws {
        let (image, section) = compressedImage(lzma(driver()))
        let edited = driver(extra: 600)

        let rebuilt = try plan(edited, at: .init(space: .inside(section)), in: image)

        let parsed = UEFIParser.parse(rebuilt)
        XCTAssertEqual(damage(parsed), [])
        XCTAssertEqual(buffer(of: section, in: rebuilt), edited)
        let files = parsed.roots[0].children.filter { $0.kind == .file }
        XCTAssertEqual(bytes(rebuilt, files[1].body), [UInt8](repeating: 0x42, count: 40))
    }

    func testANodeInsideABufferGoesBack() throws {
        let (image, section) = compressedImage(lzma(driver()))
        let inside = try XCTUnwrap(UEFIParser.parse(image).allNodes.first {
            $0.space == .inside(section) && $0.subtype == Section.userInterface
        })
        let renamed = TestImage.nameSection("OtherDriver")

        let rebuilt = try plan(renamed, at: .init(space: .inside(section), range: inside.range), in: image)

        XCTAssertEqual(buffer(of: section, in: rebuilt), driver("OtherDriver"))
    }

    /// The stream is written the way the section's was: LZMA with the x86
    /// filter stays that, Tiano stays Tiano.
    func testEachSectionIsCompressedItsOwnWay() throws {
        let x86 = TestImage.guidedSection(guid: lzmaX86GUID, body: LZMATestEncoder.lzmaX86(driver()), attributes: 0x01)
        let tiano = TestImage.compressionSection(algorithm: 0x01, body: TianoTestEncoder.tiano(driver()),
                                                 uncompressedLength: UInt32(driver().count))
        for (section, variant) in [(x86, FirmwareDecompression.Variant.lzmaX86), (tiano, .tiano)] {
            let (image, node) = compressedImage(section)
            let edited = driver("InnerDriveX")

            let rebuilt = try plan(edited, at: .init(space: .inside(node)), in: image)

            let located = try XCTUnwrap(CompressedSection.locate(at: node.header.lowerBound, in: ImageReader(rebuilt)))
            guard case .success(let decoded) = CompressedSection.decode(located, in: ImageReader(rebuilt),
                                                                        limit: 1 << 24)
            else { return XCTFail("\(variant) does not decode") }
            XCTAssertEqual(decoded.variant, variant)
            XCTAssertEqual(decoded.bytes, edited)
        }
    }

    /// Runs copied from anywhere earlier in the data, with a few stray bytes
    /// between them: what the maximum level, searching deeper for matches,
    /// makes hundreds of bytes shorter than the normal one does (measured:
    /// 0x8000 bytes to 2652 against 2140). Word-like text barely differs.
    private func text(_ length: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        func next() -> Int {
            state = state &* 1_103_515_245 &+ 12345
            return Int(state >> 8)
        }
        var out: [UInt8] = (0..<512).map { _ in UInt8(truncatingIfNeeded: next()) }
        while out.count < length {
            let from = next() % max(1, out.count - 64)
            let end = min(out.count, from + 16 + next() % 200)
            out += out[from..<end]
            out += (0..<(next() % 6)).map { _ in UInt8(truncatingIfNeeded: next()) }
        }
        return Array(out.prefix(length))
    }

    /// A body too big for its volume's room at the normal level is compressed
    /// at the maximum level before the rebuild gives up, and the plan says so;
    /// with room enough for the normal level, the normal level is all it takes.
    func testTheMaximumLevelIsTriedOnlyWhenTheNormalOneDoesNotFit() throws {
        let edited = sections([TestImage.nameSection("Drv"),
                               TestImage.section(type: Section.raw, body: text(0x8000, seed: 4))])
        func image(_ length: UInt64) -> (file: [UInt8], section: UEFINode)? {
            let file = TestImage.volume(length: length,
                                        files: [TestImage.sectionedFile(sections: [lzma(driver())]), fileB()])
            guard file.count == Int(length),
                  let node = UEFIParser.parse(file).roots.first?.children.first?.children.first,
                  node.compression != nil else { return nil }
            return (file, node)
        }
        func fits(_ length: UInt64, fallback: Bool) -> Result<UEFIRebuild.Plan, UEFIRebuild.Refusal>? {
            guard let (file, section) = image(length) else { return nil }
            return UEFIRebuild.plan(edited, at: .init(space: .inside(section)), in: file,
                                    maximumCompressionFallback: fallback)
        }
        func smallest(fallback: Bool) -> UInt64? {
            var low: UInt64 = 0x40, high: UInt64 = 0x8000
            guard case .success? = fits(high, fallback: fallback) else { return nil }
            while high - low > 8 {
                let middle = (low + high) / 2 / 8 * 8
                if case .success? = fits(middle, fallback: fallback) { high = middle } else { low = middle }
            }
            return high
        }
        let normalOnly = try XCTUnwrap(smallest(fallback: false))
        let withFallback = try XCTUnwrap(smallest(fallback: true))
        XCTAssertLessThan(withFallback, normalOnly, "the maximum level fits where the normal one does not")

        guard case .success(let squeezed)? = fits(withFallback, fallback: true) else {
            return XCTFail("the maximum level fits")
        }
        XCTAssertTrue(squeezed.warnings.contains { $0.contains("maximum level") }, "\(squeezed.warnings)")
        guard case .success(let roomy)? = fits(normalOnly, fallback: true) else {
            return XCTFail("the normal level fits")
        }
        XCTAssertFalse(roomy.warnings.contains { $0.contains("maximum level") }, "\(roomy.warnings)")
    }

    // MARK: - What a link follows

    /// A zone is something to rebuild around only when it is exactly a volume,
    /// a file or a section.
    func testAZoneIsATargetWhenItIsAStructure() {
        let image = TestImage.volume(length: 0x400, files: [fileA])
        let parsed = UEFIParser.parse(image)
        let file = parsed.roots[0].children[0]

        XCTAssertEqual(UEFIRebuild.target(forFileRange: file.range, in: parsed),
                       .init(space: .file, range: file.range))
        XCTAssertNil(UEFIRebuild.target(forFileRange: 0x50..<0x60, in: parsed))
    }

    /// The plan says where the part is held once written: for a body, the
    /// compressed section's new range, grown with it.
    func testThePlanSaysWhereThePartIsHeldAfterwards() throws {
        let (image, section) = compressedImage(lzma(driver()))
        guard case .success(let plan) = UEFIRebuild.plan(driver(extra: 600), at: .init(space: .inside(section)),
                                                         in: image)
        else { return XCTFail("refused") }

        XCTAssertEqual(plan.source.lowerBound, section.range.lowerBound)
        XCTAssertGreaterThan(plan.source.count, section.range.count)
    }

    // MARK: - A volume a section holds (§6.5)

    /// A file that outgrows the volume a firmware volume image section holds
    /// grows that volume by whole blocks, and the section, the compressed
    /// stream and the files around them follow.
    func testAVolumeASectionHoldsGrowsByWholeBlocks() throws {
        let small = TestImage.file(guid: otherGUID, body: [UInt8](repeating: 0x11, count: 0x40))
        let inner = TestImage.volume(length: 0x100, files: [small])
        let held = sections([TestImage.section(type: Section.firmwareVolumeImage, body: inner)])
        let (image, section) = compressedImage(lzma(held))
        let file = try XCTUnwrap(UEFIParser.parse(image).allNodes.first {
            $0.space == .inside(section) && $0.kind == .file
        })
        let big = TestImage.file(guid: otherGUID, body: [UInt8](repeating: 0x22, count: 0x180))

        let rebuilt = try plan(big, at: .init(space: .inside(section), range: file.range), in: image)

        let after = UEFIParser.parse(rebuilt)
        XCTAssertEqual(damage(after), [])
        let volume = try XCTUnwrap(after.allNodes.first { $0.space == .inside(section) && $0.kind == .volume })
        XCTAssertEqual(volume.range.count, 0x200, "0x48 + 0x198 takes two blocks of 0x100")
        let grown = try XCTUnwrap(after.allNodes.first { $0.space == .inside(section) && $0.kind == .file })
        XCTAssertEqual(bytes(try XCTUnwrap(buffer(of: section, in: rebuilt)), grown.body),
                       [UInt8](repeating: 0x22, count: 0x180))
        let files = after.roots[0].children.filter { $0.kind == .file }
        XCTAssertEqual(bytes(rebuilt, files[1].body), [UInt8](repeating: 0x42, count: 40))
    }

    /// A volume at the top of the file does not grow, however it is laid out.
    func testAVolumeAtTheTopOfTheFileDoesNotGrow() throws {
        let image = TestImage.volume(length: 0x100, files: [fileA])
        let node = UEFIParser.parse(image).roots[0].children[0]
        let big = TestImage.file(body: [UInt8](repeating: 0x22, count: 0x180))

        let message = try XCTUnwrap(refusal(big, at: .init(space: .file, range: node.range), in: image))
        XCTAssertTrue(message.contains("free"), message)
    }

    // MARK: - Progress

    /// A long rebuild says what it is doing and how far it has got: reading the
    /// image, compressing the section again, checking the result — forward
    /// only, and all the way at the end.
    func testARebuildSaysWhatItIsDoing() throws {
        let (image, section) = compressedImage(lzma(driver()))
        let seen = NSLock()
        var reports: [UEFIRebuild.Progress] = []

        let result = UEFIRebuild.plan(driver("InnerDriveX"), at: .init(space: .inside(section)), in: image) {
            seen.lock()
            reports.append($0)
            seen.unlock()
        }

        guard case .success = result else { return XCTFail("refused") }
        let phases = reports.map(\.phase).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(phases.count, 3, "\(phases)")
        XCTAssertTrue(phases[0].hasPrefix("Reading"), phases[0])
        XCTAssertTrue(phases[1].contains("LZMA compressed section"), phases[1])
        XCTAssertTrue(phases[2].hasPrefix("Checking"), phases[2])
        XCTAssertEqual(reports.map(\.fraction), reports.map(\.fraction).sorted(), "never backwards")
        XCTAssertEqual(reports.last?.fraction, 1)
    }

    // MARK: - Protected ranges (§6.4)

    /// A file with the last byte of its body flipped: a change at the body's
    /// end, and one at its checksum in the header.
    private func editedFile() -> (image: [UInt8], edited: [UInt8], target: UEFIRebuild.Target, body: Range<UInt64>) {
        let image = TestImage.volume(length: 0x400, files: [fileA])
        let node = UEFIParser.parse(image).roots[0].children[0]
        var edited = bytes(image, node.range)
        edited[edited.count - 1] ^= 0xFF
        return (image, edited, .init(space: .file, range: node.range), node.body)
    }

    func testAChangeInsideTheIBBIsRefused() {
        let (image, edited, target, body) = editedFile()
        let ibb = UEFIRebuild.ProtectedRange(kind: .ibb, range: body, name: "IBB segment 1")

        guard case .failure(let refusal) = UEFIRebuild.plan(edited, at: target, in: image, protected: [ibb]) else {
            return XCTFail("a change inside the IBB was planned")
        }
        XCTAssertTrue(refusal.message.contains("IBB segment 1"), refusal.message)
    }

    func testAChangeInsideAVendorHashIsWarnedAbout() {
        let (image, edited, target, body) = editedFile()
        let hash = UEFIRebuild.ProtectedRange(kind: .vendorHash, range: body, name: "AMI hash of DXE")

        guard case .success(let plan) = UEFIRebuild.plan(edited, at: target, in: image, protected: [hash]) else {
            return XCTFail("refused")
        }
        XCTAssertTrue(plan.warnings.contains { $0.contains("AMI hash of DXE") }, "\(plan.warnings)")
        XCTAssertFalse(plan.warnings.contains(UEFIRebuild.rangesNotChecked), "they were checked")
    }

    /// Two ranges of one list with one name — two entries of a flash device
    /// map — written through by one change are one warning, not two.
    func testOneNameWrittenThroughTwiceIsOneWarning() {
        let (image, edited, target, body) = editedFile()
        let half = body.lowerBound + UInt64(body.count / 2)
        let ranges = [
            UEFIRebuild.ProtectedRange(kind: .vendorHash, range: body.lowerBound..<half, name: "Insyde flash device map range"),
            UEFIRebuild.ProtectedRange(kind: .vendorHash, range: half..<body.upperBound, name: "Insyde flash device map range")
        ]
        let header = UEFIRebuild.ProtectedRange(kind: .vendorHash, range: (body.lowerBound - 0x18)..<body.lowerBound,
                                                name: "Insyde flash device map range")

        guard case .success(let plan) = UEFIRebuild.plan(edited, at: target, in: image, protected: ranges + [header])
        else { return XCTFail("refused") }
        XCTAssertEqual(plan.warnings.filter { $0.contains("Insyde flash device map range") }.count, 1,
                       "\(plan.warnings)")
    }

    /// Ranges the change does not write into say nothing — nor does a range
    /// that only sits between two changed bytes it does not contain.
    func testRangesTheChangeDoesNotTouchSayNothing() {
        let (image, edited, target, _) = editedFile()
        let far = UEFIRebuild.ProtectedRange(kind: .ibb, range: 0x300..<0x380, name: "IBB segment 2")

        guard case .success(let plan) = UEFIRebuild.plan(edited, at: target, in: image, protected: [far]) else {
            return XCTFail("refused")
        }
        XCTAssertEqual(plan.warnings, [])
    }
}

private extension ByteSpace {
    static func inside(_ section: UEFINode) -> ByteSpace {
        section.space.inside(sectionAt: section.header.lowerBound)
    }
}
