import XCTest
import Foundation
@testable import MEFirmware

/// Phase 9 (newer FS) — EFS paged-volume + FITC "OEM Configuration" structural
/// decode. Synthetic fixtures reproduce the on-flash layout upstream walks
/// (efs_anl MEA.py 8621 / fitc_anl 8572): an EFS System page whose header,
/// index area and Data Page header/footer CRCs are filled by an *independent*
/// bitwise IV-0 CRC (not the table-driven `CRC32.crc32IV0Raw` under test), so a
/// shared wrong implementation cannot fake a "valid". The two real-byte CRC
/// vectors live in ChecksumTests. Facts asserted here mirror the CSME 15.0.30
/// dump (1.bin: EFS @0x267000 1 System + 14 Data + 1 Scratch page, dict 0x0A;
/// FITC @0x1F2000 revision 1) plus negative cases. Tests never touch the network.
///
/// The file walk (`dataArea` + `files`, upstream 8745–8850) is covered from the
/// same fixtures: what the data area is assembled out of, and how a table entry
/// plus the FTBL Integrity flag cut a file out of it. The whole walk is checked
/// against upstream's own `-unp86` output on `CSME 15.bin` — 12 files, every
/// content size, metadata word, HMAC, nonce and 0x28/0x38 tail identical —
/// which is a run, not a test: no dump is committed.
final class EFSTests: XCTestCase {

    // MARK: Fixtures

    private static let pageSize = 0x1000
    private static let pageHeaderSize = 0x10
    private static let indexPaddingLength = 0x08

    /// Independent bitwise reflected CRC-32 from register IV 0, no final XOR —
    /// the same *result* as `CRC32.crc32IV0Raw` but computed bit-by-bit so the
    /// fixture builder does not depend on the implementation under test.
    private static func crcIV0Raw(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
        }
        return crc
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private static func le32(_ v: UInt32) -> Data {
        var out = Data()
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8((v >> UInt32(shift)) & 0xFF))
        }
        return out
    }

    /// A System Page: header (dictionary `dict`, Revision/Unknown1 1/2) then one
    /// current index area `[order bytes][8 zero padding][CRC]`, the rest 0xFF.
    private static func systemPage(dictionary: UInt16 = 0x000A,
                                   committed: UInt8 = 2, reserved: UInt8 = 0,
                                   order: [UInt8]) -> Data {
        var page = Data(repeating: 0xFF, count: pageSize)
        // Header: Unknown0 0x0001, Dictionary, Revision 1, Unknown1 2, Com, Res,
        // DictRevision 1, CRC over [0x00:0x0C].
        page.replaceSubrange(0..<2, with: le16(0x0001))
        page.replaceSubrange(2..<4, with: le16(dictionary))
        page.replaceSubrange(4..<8, with: le32(1))
        page[8] = 2
        page[9] = committed
        page[10] = reserved
        page[11] = 1
        page.replaceSubrange(12..<16, with: le32(crcIV0Raw(page[0..<12])))

        // Index area right after the header: order + zero padding + CRC.
        var indexArea = Data(order)
        indexArea.append(Data(repeating: 0x00, count: indexPaddingLength))
        let crc = crcIV0Raw(indexArea)
        indexArea.append(le32(crc))
        page.replaceSubrange(pageHeaderSize..<(pageHeaderSize + indexArea.count),
                             with: indexArea)
        return page
    }

    /// A Data Page (dictionary 0x0000, non-erased Unknown0). `reserved` fills
    /// the body with 0xFF and the footer CRC with 0xFFFFFFFF so the parser skips
    /// its footer check (upstream dat_ftr_crc32_skip); otherwise the body is a
    /// marker pattern and the footer CRC validates it.
    private static func dataPage(seed: UInt8, reserved: Bool = false) -> Data {
        var page = Data(repeating: 0xFF, count: pageSize)
        page.replaceSubrange(0..<2, with: le16(0x0000))   // Unknown0 ≠ 0xFFFF ⇒ Data
        page.replaceSubrange(2..<4, with: le16(0x0000))   // Dictionary 0x0000 (Data)
        page.replaceSubrange(4..<8, with: le32(1))        // Revision (unused for Data)
        page[8] = 0                                       // Unknown1 (unused for Data)
        page[9] = 0
        page[10] = 0
        page[11] = 0
        page.replaceSubrange(12..<16, with: le32(crcIV0Raw(page[0..<12])))

        if !reserved {
            for i in 0..<(pageSize - pageHeaderSize - 4) {
                page[pageHeaderSize + i] = UInt8(truncatingIfNeeded: Int(seed) &+ i)
            }
        }
        page.replaceSubrange((pageSize - 8)..<(pageSize - 4),
                             with: le32(0xFFFF_FFFF))       // Footer Unknown
        let body = page[pageHeaderSize..<(pageSize - 4)]
        let footerCRC: UInt32 = reserved ? 0xFFFF_FFFF : crcIV0Raw(body)
        page.replaceSubrange((pageSize - 4)..<pageSize, with: le32(footerCRC))
        return page
    }

    /// Default 3-page volume: System page + 2 Data pages. Index order [1, 0]
    /// proves the parser reads the permutation, not physical page order.
    private static func makeVolume() -> Data {
        var out = systemPage(committed: 2, reserved: 0, order: [1, 0])
        out.append(dataPage(seed: 0x00))
        out.append(dataPage(seed: 0x40))
        return out
    }

    // MARK: EFS decode

    func testParsesSystemVolumeFacts() throws {
        let region = Self.makeVolume()
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0x1000,
                                                mfsDictionary: 0x0A))
        XCTAssertEqual(vol.offset, 0x1000)
        XCTAssertEqual(vol.pageSize, 0x1000)
        XCTAssertEqual(vol.systemPageCount, 1)
        XCTAssertEqual(vol.dataPageCount, 2)
        XCTAssertEqual(vol.scratchPageCount, 0)
        XCTAssertTrue(vol.scratchPagesEmpty)
        XCTAssertTrue(vol.dataPageCountMatchesSystem)
        XCTAssertEqual(vol.dictionary, 0x000A)
        XCTAssertEqual(vol.revision, 1)
        XCTAssertEqual(vol.unknown1, 2)
        XCTAssertEqual(vol.dataPagesCommitted, 2)
        XCTAssertEqual(vol.dataPagesReserved, 0)
        XCTAssertEqual(vol.dictionaryRevision, 1)
        XCTAssertTrue(vol.systemHeaderCRCValid)
        XCTAssertTrue(vol.indexesCRCValid)
        XCTAssertTrue(vol.firstIndexPaddingEmpty)
        XCTAssertEqual(vol.dataPageOrder, [1, 0])
        XCTAssertTrue(vol.dataPageHeaderCRCsValid)
        XCTAssertTrue(vol.dataPageFooterCRCsValid)
        XCTAssertEqual(vol.matchesMFSDictionary, true)
    }

    func testMatchesMFSDictionaryNilWhenNoMFS() throws {
        let region = Self.makeVolume()
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertNil(vol.matchesMFSDictionary)
    }

    func testMatchesMFSDictionaryFalseOnMismatch() throws {
        let region = Self.makeVolume()
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: 0x0B))
        XCTAssertEqual(vol.matchesMFSDictionary, false)
    }

    func testScratchPagesMustBeAllFF() throws {
        var region = Self.makeVolume()
        // Append a page whose header classifies it as Scratch (dictionary
        // 0xFFFF, Unknown0 0xFFFF) but that carries one dirty byte.
        var scratch = Data(repeating: 0xFF, count: Self.pageSize)
        scratch[0x123] = 0xAB
        region.append(scratch)
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertEqual(vol.scratchPageCount, 1)
        XCTAssertFalse(vol.scratchPagesEmpty)
    }

    func testDataPageReservedSkipsFooterCheck() throws {
        var region = Self.systemPage(committed: 2, reserved: 0, order: [0, 1])
        region.append(Self.dataPage(seed: 0x10))
        region.append(Self.dataPage(seed: 0x00, reserved: true))  // reserved body
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertTrue(vol.dataPageHeaderCRCsValid)
        XCTAssertTrue(vol.dataPageFooterCRCsValid)   // reserved footer skipped
    }

    func testCorruptedHeaderCRCReportedNotThrown() throws {
        var region = Self.makeVolume()
        region[0x0C] ^= 0xFF                          // flip a byte of stored CRC
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertFalse(vol.systemHeaderCRCValid)
        XCTAssertTrue(vol.indexesCRCValid)            // rest still decodes
    }

    func testCorruptedDataPageHeaderCRCReported() throws {
        var region = Self.makeVolume()
        region[Self.pageSize + 0x0C] ^= 0xFF          // page 1 header CRC byte
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertFalse(vol.dataPageHeaderCRCsValid)
    }

    func testDirtyFirstIndexPaddingReported() throws {
        var region = Self.makeVolume()
        // Padding sits at header end + sysDataCount (2 index bytes): byte 0x12.
        // The assertion is on the padding fact alone; the index CRC is left
        // mismatching by the same dirty byte, which is not asserted here.
        region[Self.pageHeaderSize + 2] = 0x01
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertFalse(vol.firstIndexPaddingEmpty)
    }

    func testNonSystemLeadingPageReturnsNil() {
        // A Data-looking first page is not an EFS volume.
        let region = Self.dataPage(seed: 0x00)
        XCTAssertNil(EFSParser.parse(in: region, offset: 0, size: region.count,
                                     absoluteOffset: 0, mfsDictionary: nil))
    }

    func testScratchLeadingPageReturnsNil() {
        let region = Data(repeating: 0xFF, count: Self.pageSize)
        XCTAssertNil(EFSParser.parse(in: region, offset: 0, size: region.count,
                                     absoluteOffset: 0, mfsDictionary: nil))
    }

    // MARK: The file walk (efs_anl 8745–8850)

    /// The data area is the Data pages in *index* order — not physical order —
    /// each stripped of its 0x10 header and 0x8 footer, which is the buffer the
    /// table's offsets are offsets into.
    func testTheDataAreaIsTheDataPagesInIndexOrder() {
        let region = Self.makeVolume()
        let area = EFSParser.dataArea(in: region, offset: 0, size: region.count,
                                      order: [1, 0])
        let pageData = Self.pageSize - Self.pageHeaderSize - 0x08
        XCTAssertEqual(area.count, 2 * pageData)
        // Index [1, 0]: the second physical Data page comes first, and its body
        // starts at its own seed.
        XCTAssertEqual(area[0], 0x40)
        XCTAssertEqual(area[pageData], 0x00)
    }

    /// An index area that is not a permutation of the volume's Data pages
    /// leaves no data area: without it there is no saying which page is first,
    /// and a wrong order would name every file's bytes wrong.
    func testTheDataAreaIsEmptyWhenTheIndexOrderIsNotAPermutation() {
        let region = Self.makeVolume()
        XCTAssertTrue(EFSParser.dataArea(in: region, offset: 0, size: region.count,
                                         order: [0, 0]).isEmpty)
        XCTAssertTrue(EFSParser.dataArea(in: region, offset: 0, size: region.count,
                                         order: [1]).isEmpty)
        XCTAssertTrue(EFSParser.dataArea(in: region, offset: 0, size: region.count,
                                         order: [0, 5]).isEmpty)
    }

    /// A file is its metadata header plus what that header says follows. The
    /// table's own length is not it — upstream prefers the metadata, and the
    /// CSME 15 dump's `ICC_MPHYTBL` is allotted 0x3000 and stores 0x15FC.
    func testAFileIsAsLongAsItsOwnMetadataSays() throws {
        var area = Data(repeating: 0xFF, count: 0x200)
        area.replaceSubrange(0x10..<0x12, with: Self.le16(0x20))     // Size
        area.replaceSubrange(0x12..<0x14, with: Self.le16(0xAB12))   // Unknown
        let entry = FileTable.EFSEntry(dataOffset: 0x10, page: 0, pageOffset: 0x10,
                                       size: 0x100, fileID: 7, reserved: 0,
                                       name: "SOME_FILE")
        let files = EFSParser.files(dataArea: area, entries: [entry],
                                    integrityFileIDs: [], variant: "CSME",
                                    major: 15, minor: 0, platform: 4)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.fileID, 7)
        XCTAssertEqual(file.dataOffset, 0x10)
        XCTAssertEqual(file.storedSize, 0x20)
        XCTAssertEqual(file.contentSize, 0x20, "nothing flagged, nothing split off")
        XCTAssertEqual(file.metadataUnknown, 0xAB12)
        XCTAssertNil(file.integrity)
    }

    /// The Integrity flag comes from the FTBL row, and nothing in the EFS bytes
    /// says so — a file that is flagged ends with the table, one that is not
    /// keeps every byte.
    func testAFlaggedFileIsSplitFromTheTableItEndsWith() throws {
        let table = Self.integrityTable(size: 0x28, flags: 0x2,
                                        hmac: Data(repeating: 0xA1, count: 16),
                                        nonce: Data(repeating: 0xB2, count: 12),
                                        arRandom: 0x55, arCounter: 9)
        var area = Data()
        area.append(Self.le16(UInt16(0x40 + 0x28)))      // file 1: content + table
        area.append(Self.le16(0x1111))
        area.append(Data(repeating: 0x33, count: 0x40))
        area.append(table)
        let flaggedEnd = area.count
        area.append(Self.le16(0x10))                      // file 2: unflagged
        area.append(Self.le16(0x2222))
        area.append(Data(repeating: 0x44, count: 0x10))

        let entries = [
            FileTable.EFSEntry(dataOffset: 0, page: 0, pageOffset: 0, size: 0x100,
                               fileID: 5, reserved: 0, name: "FLAGGED"),
            FileTable.EFSEntry(dataOffset: flaggedEnd, page: 0, pageOffset: 0,
                               size: 0x100, fileID: 6, reserved: 0, name: "PLAIN"),
        ]
        let files = EFSParser.files(dataArea: area, entries: entries,
                                    integrityFileIDs: [5], variant: "CSME",
                                    major: 15, minor: 0, platform: 4)
        XCTAssertEqual(files.map(\.fileID), [5, 6], "in data-area order")
        let flagged = try XCTUnwrap(files.first)
        XCTAssertEqual(flagged.storedSize, 0x40 + 0x28)
        XCTAssertEqual(flagged.contentSize, 0x40, "the content, without the table")
        XCTAssertEqual(flagged.integrity?.size, 0x28)
        XCTAssertEqual(flagged.integrity?.arCounter, 9)
        XCTAssertEqual(flagged.integrity?.hmacHex.prefix(4), "A1A1")
        XCTAssertEqual(files[1].contentSize, 0x10, "unflagged: whole")
        XCTAssertNil(files[1].integrity)
    }

    /// Upstream's 0x28 workaround applies to an EFS file exactly as it does to
    /// an MFS one: a counter no Anti-Replay index would hold means the table
    /// sits 0x10 further back, and the file ends 0x38 from its content.
    func testAnAbsurdCounterMeansTheEFSTableSitsTenBytesEarlier() throws {
        let table = Self.integrityTable(size: 0x28, flags: 0x2,
                                        hmac: Data(repeating: 0xC3, count: 16),
                                        nonce: Data(repeating: 0xD4, count: 12),
                                        arRandom: 0x7, arCounter: 4)
        var area = Data()
        area.append(Self.le16(UInt16(0x20 + 0x38)))
        area.append(Self.le16(0))
        area.append(Data(repeating: 0x66, count: 0x20))
        area.append(table)
        area.append(Data(repeating: 0xEE, count: 0x10))

        let entry = FileTable.EFSEntry(dataOffset: 0, page: 0, pageOffset: 0,
                                       size: 0x100, fileID: 4, reserved: 0,
                                       name: "EXTRA")
        let file = try XCTUnwrap(EFSParser.files(
            dataArea: area, entries: [entry], integrityFileIDs: [4],
            variant: "CSME", major: 15, minor: 0, platform: 4).first)
        XCTAssertEqual(file.storedSize - file.contentSize, 0x38,
                       "0x28 of table plus the 0x10 behind it")
        XCTAssertEqual(file.contentSize, 0x20, "and the content is whole")
        XCTAssertEqual(file.integrity?.arCounter, 4, "read where the table really is")
    }

    /// A metadata size of 0xFFFF is a slot the volume never wrote. Upstream
    /// skips it, and so does the inventory — listing it would be a file that
    /// does not exist.
    func testAnUnwrittenFileIsNotListed() {
        var area = Data(repeating: 0xFF, count: 0x100)
        area.replaceSubrange(0..<2, with: Self.le16(0xFFFF))
        let entry = FileTable.EFSEntry(dataOffset: 0, page: 0, pageOffset: 0,
                                       size: 0x80, fileID: 3, reserved: 0,
                                       name: "NEVER_WRITTEN")
        XCTAssertTrue(EFSParser.files(dataArea: area, entries: [entry],
                                      integrityFileIDs: [], variant: "CSME",
                                      major: 15, minor: 0, platform: 4).isEmpty)
    }

    /// A file whose metadata claims more than the table allotted it means the
    /// table is the wrong one for this volume (upstream warns and skips). The
    /// bytes past the allotment belong to whatever the table put next — naming
    /// them would be a guess.
    func testAFileLongerThanTheTableAllowsIsSkipped() {
        var area = Data(repeating: 0x00, count: 0x200)
        area.replaceSubrange(0..<2, with: Self.le16(0x81))
        let entry = FileTable.EFSEntry(dataOffset: 0, page: 0, pageOffset: 0,
                                       size: 0x80, fileID: 2, reserved: 0,
                                       name: "TOO_LONG")
        XCTAssertTrue(EFSParser.files(dataArea: area, entries: [entry],
                                      integrityFileIDs: [], variant: "CSME",
                                      major: 15, minor: 0, platform: 4).isEmpty)
    }

    /// An entry the data area does not reach — a table written for a volume
    /// with more pages than this one has — is skipped rather than read off the
    /// end.
    func testAnEntryPastTheDataAreaIsSkipped() {
        var area = Data(repeating: 0x00, count: 0x40)
        area.replaceSubrange(0x30..<0x32, with: Self.le16(0x20))  // runs off the end
        let entries = [
            FileTable.EFSEntry(dataOffset: 0x100, page: 1, pageOffset: 0,
                               size: 0x80, fileID: 1, reserved: 0, name: "BEYOND"),
            FileTable.EFSEntry(dataOffset: 0x30, page: 0, pageOffset: 0x30,
                               size: 0x80, fileID: 2, reserved: 0, name: "CUT_OFF"),
        ]
        XCTAssertTrue(EFSParser.files(dataArea: area, entries: entries,
                                      integrityFileIDs: [], variant: "CSME",
                                      major: 15, minor: 0, platform: 4).isEmpty)
    }

    /// A flagged file too short to hold the table it is flagged for still ends
    /// where the flag says — upstream's slice of a too-short buffer is empty,
    /// not negative, and no table is reported for it.
    func testAFlaggedFileTooShortForItsTableHasNoContent() throws {
        var area = Data(repeating: 0x00, count: 0x40)
        area.replaceSubrange(0..<2, with: Self.le16(0x10))
        let entry = FileTable.EFSEntry(dataOffset: 0, page: 0, pageOffset: 0,
                                       size: 0x80, fileID: 8, reserved: 0,
                                       name: "SHORT")
        let file = try XCTUnwrap(EFSParser.files(
            dataArea: area, entries: [entry], integrityFileIDs: [8],
            variant: "CSME", major: 15, minor: 0, platform: 4).first)
        XCTAssertEqual(file.storedSize, 0x10)
        XCTAssertEqual(file.contentSize, 0)
        XCTAssertNil(file.integrity)
    }

    /// The same `MFS_Integrity_Table` builder the MFS split tests use — the
    /// tail an EFS file ends with is that structure, not one of its own.
    private static func integrityTable(size: Int, flags: UInt32, hmac: Data,
                                       nonce: Data, arRandom: UInt32 = 0,
                                       arCounter: UInt32 = 0) -> Data {
        var out = Data(repeating: 0, count: size)
        out.replaceSubrange(0..<min(hmac.count, size), with: hmac)
        if size == 0x28 {
            out.replaceSubrange(0x10..<0x14, with: le32(flags))
            out.replaceSubrange(0x14..<0x18, with: le32(arRandom))
            out.replaceSubrange(0x18..<0x1C, with: le32(arCounter))
            out.replaceSubrange(0x1C..<0x28, with: nonce)
        } else {
            out.replaceSubrange(0x20..<0x24, with: le32(flags))
            out.replaceSubrange(0x24..<0x34, with: nonce)
            out.replaceSubrange(0x24..<0x28, with: le32(arRandom))
            out.replaceSubrange(0x28..<0x2C, with: le32(arCounter))
        }
        return out
    }

    // MARK: FITC decode

    /// A revision-1 FITC header + payload. `mangle` flips a byte of the stored
    /// HeaderChecksum ([4:8]) after the CRCs are computed — the header CRC span
    /// zeroes that field, so only the stored value changes and the revision
    /// stays 1, failing the header check independently of the data checks.
    private static func makeFITC(_ mangle: Bool = false) -> Data {
        let payload = Data((0..<0x80).map { UInt8(($0 * 7 + 3) & 0xFF) })
        var header = Data(repeating: 0x00, count: 0x10)
        header.replaceSubrange(0..<4, with: le32(1))              // HeaderRevision
        header.replaceSubrange(8..<12, with: le32(UInt32(payload.count)))
        // HeaderChecksum over [0:4] + zeroed [4:8] + [8:12]; DataChecksum over payload.
        header.replaceSubrange(4..<8, with: le32(CRC32.crc32(
            header[0..<4] + Data(repeating: 0, count: 4) + header[8..<12])))
        header.replaceSubrange(12..<16, with: le32(CRC32.crc32(payload)))
        if mangle { header[0x04] ^= 0x80 }
        var out = header
        out.append(payload)
        return out
    }

    func testParsesFITCRevision1() throws {
        let region = Self.makeFITC()
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0x1000))
        XCTAssertEqual(oem.offset, 0x1000)
        XCTAssertEqual(oem.headerRevision, 1)
        XCTAssertEqual(oem.dataLength, 0x80)
        XCTAssertEqual(oem.headerCRCStored, CRC32.crc32(
            Data([0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0x80, 0, 0, 0])))
        XCTAssertEqual(oem.headerCRCValid, true)
        XCTAssertEqual(oem.dataCRCValid, true)
        XCTAssertNil(oem.configLength)
        XCTAssertNil(oem.paddingAllFF)
    }

    func testCorruptedFITCHeaderCRCReported() throws {
        let region = Self.makeFITC(true)
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0))
        XCTAssertEqual(oem.headerRevision, 1)
        XCTAssertEqual(oem.headerCRCValid, false)
        XCTAssertEqual(oem.dataLength, 0x80)              // data facts unaffected
        XCTAssertEqual(oem.dataCRCValid, true)
    }

    func testNonRevision1FITCAlphaLayout() throws {
        // CSME 15 TGP alpha layout: no header checksums. Config length u32 at
        // +0, config at +0x04, tail must be 0xFF padding.
        let config = Data((0..<0x20).map { UInt8($0) })
        var region = Data(repeating: 0xFF, count: 0x200)
        region.replaceSubrange(0..<4, with: Self.le32(UInt32(config.count)))
        region.replaceSubrange(4..<(4 + config.count), with: config)
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0))
        // On the alpha layout the first u32 doubles as the config length (and
        // therefore the HeaderRevision read from it is never 1).
        XCTAssertEqual(oem.headerRevision, UInt32(config.count))
        XCTAssertEqual(oem.configLength, config.count)
        XCTAssertEqual(oem.paddingAllFF, true)
        XCTAssertNil(oem.dataLength)
        XCTAssertNil(oem.headerCRCStored)
    }

    func testNonRevision1DirtyPaddingReported() throws {
        let config = Data((0..<0x20).map { UInt8($0) })
        var region = Data(repeating: 0xFF, count: 0x200)
        region.replaceSubrange(0..<4, with: Self.le32(UInt32(config.count)))
        region.replaceSubrange(4..<(4 + config.count), with: config)
        region[0x100] = 0x00                             // dirty the padding tail
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0))
        XCTAssertEqual(oem.configLength, config.count)
        XCTAssertEqual(oem.paddingAllFF, false)
    }

    /// The payload is where the records are read from, and where it starts is
    /// the revision's answer: 0x10 past a revision-1 header, 0x04 past the
    /// alpha layout's own length word. `payloadOffset` says so absolutely, so a
    /// record's own offset becomes a position in the image.
    func testThePayloadIsHandedOutFromBehindTheHeader() throws {
        let region = Self.makeFITC()
        let payload = try XCTUnwrap(FITCParser.configPayload(
            in: region, offset: 0, size: region.count))
        XCTAssertEqual(payload.count, 0x80)
        XCTAssertEqual(Array(payload.prefix(2)), [3, 10], "the payload's own bytes")
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0x315000))
        XCTAssertEqual(oem.payloadOffset, 0x315010)

        let alpha = Data(Self.le32(0x20)) + Data((0..<0x20).map { UInt8($0) })
            + Data(repeating: 0xFF, count: 0x100)
        let alphaPayload = try XCTUnwrap(FITCParser.configPayload(
            in: alpha, offset: 0, size: alpha.count))
        XCTAssertEqual(alphaPayload.count, 0x20)
        XCTAssertEqual(alphaPayload.first, 0)
        let alphaOEM = try XCTUnwrap(FITCParser.parse(in: alpha, offset: 0,
                                                      size: alpha.count,
                                                      absoluteOffset: 0x1000))
        XCTAssertEqual(alphaOEM.payloadOffset, 0x1004)
    }

    /// A length running past the partition is no payload: there is no saying
    /// how much of it was meant, and cutting records out of the remainder would
    /// invent them.
    func testAPayloadLongerThanThePartitionIsNil() {
        var region = Data(repeating: 0x00, count: 0x40)
        region.replaceSubrange(0..<4, with: Self.le32(1))          // revision 1
        region.replaceSubrange(8..<12, with: Self.le32(0x1000))    // DataLength
        XCTAssertNil(FITCParser.configPayload(in: region, offset: 0,
                                              size: region.count))
        // And a header that declares nothing has nothing to hand out.
        var empty = Data(repeating: 0x00, count: 0x40)
        empty.replaceSubrange(0..<4, with: Self.le32(1))
        XCTAssertNil(FITCParser.configPayload(in: empty, offset: 0, size: empty.count))
    }

    func testRegionTooSmallForFITCReturnsNil() {
        XCTAssertNil(FITCParser.parse(in: Data(repeating: 0, count: 0x0F),
                                      offset: 0, size: 0x0F, absoluteOffset: 0))
    }
}
