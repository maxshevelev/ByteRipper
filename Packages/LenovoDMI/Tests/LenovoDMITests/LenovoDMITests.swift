import XCTest
import PartCodec
@testable import LenovoDMI

final class LocateTests: XCTestCase {
    func testFindsTheAreaWhereverItIs() {
        let areas = LenovoDMI.locate(in: TestStore.standardImage())
        XCTAssertEqual(areas.map(\.offset), [0x3000])
        XCTAssertEqual(areas.first?.blocks.map(\.offset), [0x5000, 0x6000])
    }

    /// A stray `LDBG` — in a driver's code, say — with zeros after it but no
    /// blocks behind it is not the store. Upstream takes the first match.
    func testAStrayLDBGIsNotTheStore() {
        var image = [UInt8](repeating: 0xFF, count: 0x1000)
        image += Array("LDBG".utf8) + [UInt8](repeating: 0, count: 0x5000)
        image += TestStore.standardImage()
        let areas = LenovoDMI.locate(in: image)
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas.first?.offset, 0x1000 + 0x5004 + 0x3000)
    }

    func testAnImageTooShortForTheAreaHasNone() {
        let image = Array(TestStore.standardImage().prefix(0x3000 + 0x3800))
        XCTAssertEqual(LenovoDMI.locate(in: image), [])
    }
}

final class LENVBlockTests: XCTestCase {
    func testReadsAnEncodedBlock() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let block = area.blocks[0]
        XCTAssertTrue(block.hasSignature)
        XCTAssertEqual(block.generation, 127)
        XCTAssertEqual(block.xorKey, 0x7F)
        XCTAssertEqual(block.encoding, .encoded)
        XCTAssertTrue(block.entriesFit)
        XCTAssertTrue(block.checksumIsValid)
        XCTAssertEqual(block.entries.map(\.key), TestStore.standardEntries.map(\.key))
        XCTAssertEqual(block.entry(.smbios(0x0400))?.data, Array("PF0TEST1".utf8))
    }

    func testPlacesEachEntryInTheFile() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let first = area.blocks[0].entries[0]
        XCTAssertEqual(first.offset, 0x5010)
        XCTAssertEqual(first.dataRange, 0x5028..<0x5030)
        let second = area.blocks[0].entries[1]
        XCTAssertEqual(second.offset, 0x5030)
    }

    /// What upstream's "decode" toggle leaves: the body in the clear under a
    /// non-zero key. Told apart by which reading parses, not by the last byte.
    func testReadsABlockStoredInTheClear() {
        let stored = TestStore.block(generation: 5, key: 0x77, entries: TestStore.standardEntries,
                                     encode: false)
        let block = LENVBlock(offset: 0, stored: stored)
        XCTAssertEqual(block.encoding, .plain)
        XCTAssertEqual(block.effectiveKey, 0)
        XCTAssertEqual(block.entry(.smbios(0x0200))?.data, Array("82XX0000GE".utf8))
    }

    func testAKeyOfZeroIsNeitherReading() {
        let stored = TestStore.block(generation: 5, key: 0, entries: TestStore.standardEntries)
        XCTAssertEqual(LENVBlock(offset: 0, stored: stored).encoding, .keyIsZero)
    }

    func testACountThatRunsPastTheBlockIsUndetermined() {
        let stored = TestStore.block(generation: 5, key: 0x7F, entries: TestStore.standardEntries,
                                     declared: 400)
        let block = LENVBlock(offset: 0, stored: stored)
        XCTAssertEqual(block.encoding, .undetermined)
        XCTAssertFalse(block.entriesFit)
        // What the encoded reading got through before it ran out is kept.
        XCTAssertEqual(block.entries.count, TestStore.standardEntries.count)
    }

    /// The sum is over the body as stored — encoded — which is what makes it
    /// line up on every real block examined.
    func testTheChecksumIsOverTheStoredBody() {
        let good = LENVBlock(offset: 0, stored: TestStore.block(
            generation: 1, key: 0x7F, entries: TestStore.standardEntries))
        let bad = LENVBlock(offset: 0, stored: TestStore.block(
            generation: 1, key: 0x7F, entries: TestStore.standardEntries, checksum: 0x1234))
        XCTAssertTrue(good.checksumIsValid)
        XCTAssertFalse(bad.checksumIsValid)
        XCTAssertEqual(bad.computedChecksum, good.checksum)
    }
}

final class LiveBlockTests: XCTestCase {
    private func area(_ generation1: UInt32, _ generation2: UInt32) -> LenovoDMIArea {
        let image = TestStore.image(
            log: TestStore.log([], key: 0x7F),
            blocks: [
                TestStore.block(generation: generation1, key: 0x7F, entries: TestStore.standardEntries),
                TestStore.block(generation: generation2, key: 0x7F, entries: TestStore.standardEntries)
            ]
        )
        return LenovoDMI.locate(in: image)[0]
    }

    func testTheHigherGenerationIsLive() {
        XCTAssertEqual(area(127, 126).liveIndex, 0)
        XCTAssertEqual(area(83, 84).liveIndex, 1)
    }

    func testATieGoesToBlockOne() {
        XCTAssertEqual(area(9, 9).liveIndex, 0)
    }

    func testGenerationZeroIsNeverLive() {
        XCTAssertEqual(area(0, 3).liveIndex, 1)
        XCTAssertNil(area(0, 0).liveIndex)
    }

    func testAWipedStoreSaysSo() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.wipedImage()).first)
        XCTAssertTrue(area.blocks.allSatisfy(\.isBlank))
        XCTAssertNil(area.liveIndex)
        XCTAssertEqual(area.findings, [.wiped])
        XCTAssertEqual(area.log.writeOffsetProblem, .erased)
        XCTAssertEqual(area.log.entries, [])
    }

    func testBlocksThatDifferAreNamedByKey() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        // Block 2 lacks the last entry, which is what a newer write leaves.
        XCTAssertEqual(area.findings, [.blocksDiffer(keys: [.smbios(0x0200)])])
        XCTAssertFalse(area.findings[0].isProblem)
    }
}

final class LDBGLogTests: XCTestCase {
    func testReadsThirtyTwoByteEntriesUnderTheBlocksKey() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let log = area.log
        XCTAssertEqual(log.writeOffset, 0x20 + 3 * 0x20)
        XCTAssertNil(log.writeOffsetProblem)
        XCTAssertEqual(log.key, 0x7F)
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.key), TestStore.standardLog.map(\.key))
        XCTAssertEqual(log.entries.map(\.size), [1, 16, 8])
        XCTAssertEqual(log.entries[2].knownOperation, .setData)
        XCTAssertEqual(log.entries[2].offset, 0x3000 + 0x20 + 2 * 0x20)
    }

    /// `22 20` is 2022: a BCD year and a BCD century, not "2000 + a byte".
    func testTheYearIsACenturyAndAYear() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        XCTAssertEqual(area.log.entries[2].timestampText, "2022-06-29 20:30:25")
        XCTAssertEqual(area.log.entries[1].timestampText, "2015-11-15 00:01:08")
    }

    func testATimestampWrittenBeforeTheClockWasSetIsNoDate() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        XCTAssertNil(area.log.entries[0].timestamp)
    }

    func testAMisalignedWriteOffsetIsReported() {
        let stored = TestStore.log(TestStore.standardLog, key: 0x7F, writeOffset: 0x30)
        let log = LDBGLog(offset: 0, stored: stored, candidateKeys: [0x7F])
        XCTAssertEqual(log.writeOffsetProblem, .misaligned)
    }

    func testAWriteOffsetPastTheEndReadsNothing() {
        let stored = TestStore.log(TestStore.standardLog, key: 0x7F, writeOffset: 0x9000)
        let log = LDBGLog(offset: 0, stored: stored, candidateKeys: [0x7F])
        XCTAssertEqual(log.writeOffsetProblem, .outOfRange)
        XCTAssertEqual(log.entries, [])
    }
}

final class ValueTests: XCTestCase {
    private func entry(_ fixture: TestStore.Entry) -> LENVEntry {
        LENVEntry(index: 0, offset: 0, key: fixture.key, flags: 0, unknown1: 0, unknown2: 0,
                  data: fixture.data)
    }

    func testTextReadsAsText() {
        XCTAssertEqual(LenovoDMIValue.text(of: entry(TestStore.serial)), "PF0TEST1")
    }

    func testPaddingIsNotPartOfTheText() {
        let padded = TestStore.Entry(key: .smbios(0x0200), data: Array("82XX".utf8) + [0, 0, 0x20])
        XCTAssertEqual(LenovoDMIValue.text(of: entry(padded)), "82XX")
    }

    /// SMBIOS order: the first three fields little-endian. That is what gives a
    /// version-1 UUID on the dumps examined.
    func testTheUUIDReadsInSMBIOSOrder() {
        XCTAssertEqual(LenovoDMIValue.text(of: entry(TestStore.uuid)),
                       "2B678236-3B1B-11ED-80F2-010203040506")
    }

    func testAnUnknownEntryThatIsNotTextReadsAsHex() {
        XCTAssertEqual(LenovoDMIValue.text(of: entry(TestStore.unknown)), "19")
        XCTAssertEqual(LenovoDMIValue.name(of: TestStore.unknown.key), "Unknown SMBIOS entry 0x0700")
        XCTAssertEqual(LenovoDMIValue.name(of: TestStore.serial.key), "Baseboard serial number")
    }
}

final class EditTests: XCTestCase {
    private func apply(_ writes: [LenovoDMIEdit.Write], to image: [UInt8]) -> [UInt8] {
        var image = image
        for write in writes {
            let start = Int(write.offset)
            image.replaceSubrange(start..<(start + write.bytes.count), with: write.bytes)
        }
        return image
    }

    /// The new value lands in both copies, encoded, with both checksums
    /// right — and reads back as what was written.
    func testSetsBothCopies() throws {
        let image = TestStore.standardImage()
        let area = try XCTUnwrap(LenovoDMI.locate(in: image).first)
        let result = try LenovoDMIEdit.set(.smbios(0x0400), to: Array("PF9NEW99".utf8), in: area)
        XCTAssertEqual(result.blocks, [0, 1])

        let after = try XCTUnwrap(LenovoDMI.locate(in: apply(result.writes, to: image)).first)
        for block in after.blocks {
            XCTAssertTrue(block.checksumIsValid)
            XCTAssertEqual(block.encoding, .encoded)
            XCTAssertEqual(block.entry(.smbios(0x0400))?.data, Array("PF9NEW99".utf8))
            XCTAssertEqual(block.generation, area.blocks[after.blocks.firstIndex(of: block)!].generation)
        }
        // The log is the firmware's record, and nothing was added to it.
        XCTAssertEqual(after.log, area.log)
    }

    func testAnEntryOnlyOneBlockHoldsIsWrittenThereAlone() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let result = try LenovoDMIEdit.set(.smbios(0x0200), to: Array("82YY1111GE".utf8), in: area)
        XCTAssertEqual(result.blocks, [0])
    }

    func testTheLengthNeverChanges() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        XCTAssertThrowsError(try LenovoDMIEdit.set(.smbios(0x0400), to: Array("SHORT".utf8), in: area)) {
            XCTAssertEqual($0 as? LenovoDMIEdit.Refusal, .lengthChanges(expected: 8, got: 5))
        }
    }

    func testAProtectedEntryIsRefused() throws {
        var serial = TestStore.serial
        serial.flags = 1
        let image = TestStore.image(
            log: TestStore.log([], key: 0x7F),
            blocks: [
                TestStore.block(generation: 2, key: 0x7F, entries: [serial]),
                TestStore.block(generation: 1, key: 0x7F, entries: [serial])
            ]
        )
        let area = try XCTUnwrap(LenovoDMI.locate(in: image).first)
        XCTAssertThrowsError(try LenovoDMIEdit.set(.smbios(0x0400), to: Array("PF9NEW99".utf8), in: area)) {
            XCTAssertEqual($0 as? LenovoDMIEdit.Refusal, .writeProtected(block: 0))
        }
    }

    func testAKeyNoBlockHoldsIsRefused() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        XCTAssertThrowsError(try LenovoDMIEdit.set(.smbios(0x1000), to: [1, 2, 3], in: area)) {
            XCTAssertEqual($0 as? LenovoDMIEdit.Refusal, .noSuchEntry)
        }
    }

    /// A block left decoded is written decoded: the edit does not quietly
    /// change how the block is stored.
    func testABlockInTheClearStaysInTheClear() throws {
        let image = TestStore.image(
            log: TestStore.log([], key: 0x7F),
            blocks: [
                TestStore.block(generation: 2, key: 0x7F, entries: TestStore.standardEntries, encode: false),
                TestStore.block(generation: 1, key: 0x7F, entries: TestStore.standardEntries)
            ]
        )
        let area = try XCTUnwrap(LenovoDMI.locate(in: image).first)
        let result = try LenovoDMIEdit.set(.smbios(0x0400), to: Array("PF9NEW99".utf8), in: area)
        let after = try XCTUnwrap(LenovoDMI.locate(in: apply(result.writes, to: image)).first)
        XCTAssertEqual(after.blocks.map(\.encoding), [.plain, .encoded])
        XCTAssertTrue(after.blocks.allSatisfy(\.checksumIsValid))
    }
}

final class DecodedBlockTests: XCTestCase {
    func testTheBodyReadsInTheClearAndTheHeaderAsStored() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let block = area.blocks[0]
        let clear = LenovoDMIDecodedBlock.decode(block)
        XCTAssertEqual(Array(clear[..<16]), Array(block.stored[..<16]))
        let serial = try XCTUnwrap(block.entry(.smbios(0x0400)))
        let start = Int(serial.dataRange.lowerBound - block.offset)
        XCTAssertEqual(Array(clear[start..<(start + 8)]), Array("PF0TEST1".utf8))
    }

    /// Unchanged, it goes back as the very bytes it came out of.
    func testAnUntouchedBlockGoesBackAsItWas() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let block = area.blocks[0]
        let back = try LenovoDMIDecodedBlock.encode(LenovoDMIDecodedBlock.decode(block), encodes: true)
        XCTAssertEqual(back, block.stored)
    }

    /// An edit in the clear lands encoded, with a checksum that adds up.
    func testAnEditGoesBackEncodedWithItsChecksum() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let block = area.blocks[0]
        var clear = LenovoDMIDecodedBlock.decode(block)
        let start = Int(try XCTUnwrap(block.entry(.smbios(0x0400))).dataRange.lowerBound - block.offset)
        clear.replaceSubrange(start..<(start + 8), with: Array("PF9NEW99".utf8))

        let back = LENVBlock(offset: block.offset,
                             stored: try LenovoDMIDecodedBlock.encode(clear, encodes: true))
        XCTAssertEqual(back.encoding, .encoded)
        XCTAssertTrue(back.checksumIsValid)
        XCTAssertEqual(back.entry(.smbios(0x0400))?.data, Array("PF9NEW99".utf8))
    }

    func testABlockStoredInTheClearStaysInTheClear() throws {
        let stored = TestStore.block(generation: 5, key: 0x77, entries: TestStore.standardEntries, encode: false)
        let block = LENVBlock(offset: 0, stored: stored)
        let back = try LenovoDMIDecodedBlock.encode(LenovoDMIDecodedBlock.decode(block), encodes: false)
        XCTAssertEqual(back, stored)
    }

    func testAWipedBlockIsNotOffered() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.wipedImage()).first)
        XCTAssertFalse(LenovoDMIDecodedBlock.canOpen(area.blocks[0]))
    }

    func testAnotherLengthIsRefused() {
        XCTAssertThrowsError(try LenovoDMIDecodedBlock.encode([0, 1, 2], encodes: true))
    }
}

private struct Image: PartReader {
    var bytes: [UInt8]
    var size: UInt64 { UInt64(bytes.count) }
    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        Array(bytes[Int(offset)..<(Int(offset) + length)])
    }
}

final class BlockCodecTests: XCTestCase {
    /// Opened from the file and put back unchanged, the block is the bytes it
    /// was; edited, it lands encoded with a checksum that adds up.
    func testTheBlockOpensInTheClearAndGoesBackEncoded() throws {
        let image = TestStore.standardImage()
        let area = try XCTUnwrap(LenovoDMI.locate(in: image).first)
        let block = area.blocks[0]
        let parent = PartParent(content: Image(bytes: image), source: block.range, name: "dump.bin")
        let codec = LenovoDMIBlockCodec(block: block)

        var clear = try codec.decode(parent)
        XCTAssertEqual(clear, LenovoDMIDecodedBlock.decode(block))
        XCTAssertEqual(try codec.encode(clear, into: parent), .overwriting(block.range, with: block.stored))

        let start = Int(try XCTUnwrap(block.entry(.smbios(0x0400))).dataRange.lowerBound - block.offset)
        clear.replaceSubrange(start..<(start + 8), with: Array("PF9NEW99".utf8))
        let update = try codec.encode(clear, into: parent)
        let back = LENVBlock(offset: block.offset, stored: update.bytes)
        XCTAssertTrue(back.checksumIsValid)
        XCTAssertEqual(back.entry(.smbios(0x0400))?.data, Array("PF9NEW99".utf8))
        XCTAssertEqual(codec.badge?.text, "XOR 7F")
    }
}

final class BlockOnItsOwnTests: XCTestCase {
    /// A block opened out of the dump decoded is a block on its own: the
    /// header as the store holds it, the body in the clear.
    func testADecodedBlockOnItsOwnReads() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        let clear = LenovoDMIDecodedBlock.decode(area.blocks[0])
        let reading = LenovoDMI.read(clear)
        XCTAssertEqual(reading.areas, [])
        let block = try XCTUnwrap(reading.blocks.first)
        XCTAssertEqual(block.offset, 0)
        XCTAssertEqual(block.encoding, .plain)
        XCTAssertEqual(block.entry(.smbios(0x0400))?.data, Array("PF0TEST1".utf8))
        // The header's checksum is the encoded body's, and that is in order.
        XCTAssertTrue(block.checksumIsOfEncodedBody)
        XCTAssertTrue(block.checksumIsValid)
    }

    /// An edit in the clear leaves the header's checksum behind, and the block
    /// says what it should be — encoded, since that is the one it carries.
    func testAnEditInTheClearIsAChecksumToRecompute() throws {
        let area = try XCTUnwrap(LenovoDMI.locate(in: TestStore.standardImage()).first)
        var clear = LenovoDMIDecodedBlock.decode(area.blocks[0])
        let start = Int(try XCTUnwrap(area.blocks[0].entry(.smbios(0x0400))).dataRange.lowerBound)
            - Int(area.blocks[0].offset)
        clear[start] = UInt8(ascii: "Q")
        let block = try XCTUnwrap(LenovoDMI.read(clear).blocks.first)
        XCTAssertFalse(block.checksumIsValid)
        let fixed = try LenovoDMIDecodedBlock.encode(clear, encodes: true)
        XCTAssertEqual(block.expectedChecksum, UInt16(fixed[0x0E]) | UInt16(fixed[0x0F]) << 8)
    }

    /// Blocks inside a store are the store's, not blocks on their own.
    func testAStoresBlocksAreNotCountedTwice() {
        let reading = LenovoDMI.read(TestStore.standardImage())
        XCTAssertEqual(reading.areas.count, 1)
        XCTAssertEqual(reading.blocks, [])
    }

    /// `LENV` in code, followed by nothing that parses, is not a block.
    func testAStraySignatureIsNotABlock() {
        var image = [UInt8](repeating: 0x41, count: 0x2000)
        image.replaceSubrange(0x100..<0x104, with: Array("LENV".utf8))
        XCTAssertEqual(LenovoDMI.read(image).blocks, [])
    }
}

final class WindowsKeyTests: XCTestCase {
    private let header: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x1D, 0, 0, 0]
    private let key = "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"

    private func entry(_ data: [UInt8]) -> LENVEntry {
        LENVEntry(index: 0, offset: 0, key: .smbios(0x0001), flags: 0, unknown1: 0, unknown2: 0, data: data)
    }

    /// The value is the key alone, without the MSDM header in front of it.
    func testTheValueIsTheKeyWithoutItsHeader() {
        XCTAssertEqual(LenovoDMIValue.text(of: entry(header + Array(key.utf8))), key)
    }

    /// A header whose length does not match what follows is not guessed at.
    func testALengthThatDoesNotMatchIsShownAsBytes() {
        let short = header + Array(key.utf8.dropLast())
        XCTAssertNil(LenovoDMIValue.WindowsKey(short))
        XCTAssertEqual(LenovoDMIValue.WindowsKey.problem(short), .length(declared: 29, actual: 28))
        XCTAssertEqual(LenovoDMIValue.text(of: entry(short)), LenovoDMIValue.hex(short))
    }

    /// Nor is a header that does not start with the MSDM signature.
    func testAnotherSignatureIsShownAsBytes() {
        var other = header + Array(key.utf8)
        other[8] = 2
        XCTAssertNil(LenovoDMIValue.WindowsKey(other))
        XCTAssertEqual(LenovoDMIValue.WindowsKey.problem(other), .signature(Array(other[..<16])))
    }
}
