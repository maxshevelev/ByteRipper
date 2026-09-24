import XCTest
import Foundation
@testable import MEFirmware

/// Phase — Chipset Initialization Table decode (`mphytbl` + `pch_init_anl`,
/// upstream MEA.py 8956–9131), closed over row 81. Synthetic mphytbl content
/// slices reproduce the new (bytes [4:6] == FF FF) and old layouts and every
/// stepping-rule branch the engine identity + manifest date selects. Tests never
/// touch the network and never read real dumps.
final class PCHInitTests: XCTestCase {

    // MARK: - decodeTable fixtures

    /// New-layout mphytbl slice: FF FF marker @[4:6], init-table revision @6,
    /// chipset-ID byte @7, stepping nibble as the high half of byte @8.
    private static func newTable(chipset: Int, stepping: Int,
                                 revision: Int = 0) -> Data {
        var d = Data(repeating: 0x5A, count: 9)
        d[4] = 0xFF; d[5] = 0xFF
        d[6] = UInt8(revision & 0xFF)
        d[7] = UInt8(chipset & 0xFF)
        d[8] = UInt8((stepping & 0xF) << 4)
        return d
    }

    /// Old-layout mphytbl slice: revision @2, chipset-ID nibble as the high half
    /// of byte @3, stepping nibble as its low half. Kept to 4 bytes so the
    /// FF-marker test never misdetects it as new.
    private static func oldTable(chipset: Int, stepping: Int,
                                 revision: Int = 0) -> Data {
        var d = Data(repeating: 0x5A, count: 4)
        d[2] = UInt8(revision & 0xFF)
        d[3] = UInt8(((chipset & 0xF) << 4) | (stepping & 0xF))
        return d
    }

    /// Decode one table for the usual oracle stub identity/date (callers that
    /// exercise a different branch override the relevant arguments).
    private static func step(_ table: Data, variant: String = "CSME", major: Int = 15,
                             minor: Int = 40, build: Int = 2500,
                             year: Int = 2020, month: Int = 6, day: Int = 1) -> MFSPCHInitRecord? {
        PCHInitDecoder.decodeTable(table, variant: variant, major: major,
                                   minor: minor, build: build,
                                   year: year, month: month, day: day)
    }

    // MARK: - layout detection & field extraction

    func testNewLayoutReadsChipsetByteHighNibbleStepAndRevision() throws {
        // CSSPS 4.4: absolute stepping from the high nibble of byte 8, chipset
        // renamed to WTL. stepping 0xF → letter P, revision forwarded from byte 6.
        let r = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x0, stepping: 0xF, revision: 3),
                                        variant: "CSSPS", major: 4, minor: 4))
        XCTAssertEqual(r.chipset, "WTL")
        XCTAssertEqual(r.stepping, "P")
        XCTAssertEqual(r.revision, 3)
    }

    func testOldLayoutReadsChipsetNibbleLowNibbleStepAndRevision() throws {
        // A branch that leaves chipset untouched surfaces the pch_dict label of
        // the old-layout high nibble; stepping comes from the low nibble.
        // CSME 14 (bitfield): nibble 0x3 → bits 0011 → "BA".
        let r = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0xD, stepping: 0x3, revision: 7),
                                        major: 14, minor: 0))
        XCTAssertEqual(r.chipset, "CNP/CMP-H")
        XCTAssertEqual(r.stepping, "BA")
        XCTAssertEqual(r.revision, 7)
    }

    // MARK: - stepping branches (upstream elif order)

    func testCSME15_40BuildRangeSelectsLetter() throws {
        // build in [1000, 7000) → pch_stp_val[(build/1000)-1]; chipset byte
        // survives to its pch_dict label. build 2500 → index 1 → B.
        let r = try XCTUnwrap(Self.step(Self.newTable(chipset: 0xD, stepping: 0x2, revision: 1)))
        XCTAssertEqual(r.chipset, "CNP/CMP-H")
        XCTAssertEqual(r.stepping, "B")
        XCTAssertEqual(r.revision, 1)
    }

    func testCSME15_40BuildRangeBoundariesAndFallback() throws {
        // 1000 → A, 6999 → F; either side of the range falls back to the
        // absolute letter of the raw nibble (0x2 → C).
        let low = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x9, stepping: 0x2), build: 1000))
        XCTAssertEqual(low.stepping, "A")
        let high = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x9, stepping: 0x2), build: 6999))
        XCTAssertEqual(high.stepping, "F")
        for build in [999, 7000] {
            let r = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x9, stepping: 0x2), build: build))
            XCTAssertEqual(r.stepping, "C")          // absolute(0x2)
        }
    }

    func testCSME12GateBitfieldAfter2018AbsoluteBefore() throws {
        // CSME 12 (and CSSPS 5): ≥ 2018-01-25 → bitfield of the nibble;
        // earlier → absolute letter. Boundary day itself is on the bitfield side.
        let r = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0xC, stepping: 0x5, revision: 4),
                                        major: 12, minor: 0, year: 2018, month: 1, day: 25))
        XCTAssertEqual(r.chipset, "CNP/CMP-LP")
        XCTAssertEqual(r.stepping, "CA")             // 0x5 = 0101 → C,A
        let early = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0xC, stepping: 0x5, revision: 4),
                                            major: 12, minor: 0, year: 2018, month: 1, day: 24))
        XCTAssertEqual(early.stepping, "F")          // absolute(0x5)
    }

    func testCSME11GateAbsoluteAfter2015EmptyBefore() throws {
        // CSME 11: ≥ 2015-05-19 → absolute letter; earlier → stepping stays
        // empty (unreliable always-80 stepping).
        let after = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x8, stepping: 0x3, revision: 2),
                                            major: 11, minor: 8, year: 2015, month: 5, day: 19))
        XCTAssertEqual(after.chipset, "SPT/KBP-LP")
        XCTAssertEqual(after.stepping, "D")          // absolute(0x3)
        let before = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x8, stepping: 0x3, revision: 2),
                                             major: 11, minor: 8, year: 2015, month: 5, day: 18))
        XCTAssertEqual(before.stepping, "")
    }

    func testCSSPS4NonFourSharesCSME11DateGate() throws {
        // CSSPS major 4, minor ≠ 4 → the (CSME,11)|(CSSPS,4) date rule.
        let after = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0x8, stepping: 0x1, revision: 0),
                                            variant: "CSSPS", major: 4, minor: 0,
                                            year: 2016, month: 1, day: 1))
        XCTAssertEqual(after.stepping, "B")
        let before = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0x8, stepping: 0x1, revision: 0),
                                             variant: "CSSPS", major: 4, minor: 0,
                                             year: 2014, month: 12, day: 31))
        XCTAssertEqual(before.stepping, "")
    }

    func testCSSPS5SharesCSME12DateGate() throws {
        let r = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x6, stepping: 0xF, revision: 0),
                                       variant: "CSSPS", major: 5, minor: 0,
                                       year: 2019, month: 3, day: 3))
        XCTAssertEqual(r.stepping, "DCBA")           // bitfield(0xF)
        let early = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x6, stepping: 0xF, revision: 0),
                                           variant: "CSSPS", major: 5, minor: 0,
                                           year: 2017, month: 1, day: 1))
        XCTAssertEqual(early.stepping, "P")          // absolute(0xF)
    }

    func testLayoutBranchAbsoluteOnNewBitfieldOnOldAcrossFamilies() throws {
        // (CSME,13/15/16)|(CSSPS,6): new layout → absolute letter, old layout →
        // bitfield of the same nibble.
        for (variant, major) in [("CSME", 13), ("CSME", 15), ("CSME", 16), ("CSSPS", 6)] {
            let minor = variant == "CSME" && major == 15 ? 10 : 0
            let n = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x3, stepping: 0x1),
                                            variant: variant, major: major, minor: minor))
            XCTAssertEqual(n.chipset, "ICP-LP", "\(variant) \(major)")
            XCTAssertEqual(n.stepping, "B", "\(variant) \(major) new → absolute")
            let o = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0x3, stepping: 0x1),
                                            variant: variant, major: major, minor: minor))
            XCTAssertEqual(o.stepping, "A", "\(variant) \(major) old → bitfield(0x1)")
        }
    }

    func testCSME14_5OverridesChipsetToCMP_V() throws {
        let r = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0xB, stepping: 0x4, revision: 6),
                                        major: 14, minor: 5))
        XCTAssertEqual(r.chipset, "CMP-V")
        XCTAssertEqual(r.stepping, "E")              // absolute(0x4)
        XCTAssertEqual(r.revision, 6)
    }

    func testCSME14NonFiveUsesBitfield() throws {
        // 0x6 = 0110 → high→low bits C,B.
        let r = try XCTUnwrap(Self.step(Self.newTable(chipset: 0xE, stepping: 0x6, revision: 9),
                                       major: 14, minor: 0))
        XCTAssertEqual(r.chipset, "LKF-LP")
        XCTAssertEqual(r.stepping, "CB")
        XCTAssertEqual(r.revision, 9)
    }

    func testBitfieldEmptyNibbleYieldsA() throws {
        let r = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x9, stepping: 0x0, revision: 0),
                                       major: 14, minor: 0))
        XCTAssertEqual(r.stepping, "A")
    }

    func testNoMatchingBranchLeavesSteppingEmpty() throws {
        // A (variant, major) upstream never reaches a stepping rule → "".
        let r = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0xC, stepping: 0x2, revision: 1),
                                        major: 9, minor: 0))
        XCTAssertEqual(r.chipset, "CNP/CMP-LP")
        XCTAssertEqual(r.stepping, "")
        XCTAssertEqual(r.revision, 1)
    }

    // MARK: - pch_dict label hit/miss

    func testUnknownChipsetLabelWhenIDNotInPchDict() throws {
        // Old-layout nibble 0xA (and 0x1/0x2) are gaps in pch_dict → Unknown; a
        // new-layout chipset byte beyond 0x12 also misses.
        let r = try XCTUnwrap(Self.step(Self.oldTable(chipset: 0xA, stepping: 0x1, revision: 0),
                                       major: 14, minor: 0))
        XCTAssertEqual(r.chipset, "Unknown")
        let wide = try XCTUnwrap(Self.step(Self.newTable(chipset: 0x20, stepping: 0x1, revision: 0),
                                           major: 14, minor: 0))
        XCTAssertEqual(wide.chipset, "Unknown")
    }

    func testShortTablesReturnNil() {
        XCTAssertNil(Self.step(Data([0x00, 0x01, 0x02])))            // < 4 bytes
        XCTAssertNil(Self.step(Self.newTable(chipset: 0x9, stepping: 0x1).prefix(8)))  // needs ≥ 9
    }

    // MARK: - aggregate (pch_init_anl)

    func testAggregateConcatenatesDedupesAndSortsDescending() {
        let records = [
            MFSPCHInitRecord(chipset: "CNP/CMP-LP", stepping: "CA", revision: 1),
            MFSPCHInitRecord(chipset: "SPT-H", stepping: "B", revision: 1),
            MFSPCHInitRecord(chipset: "CNP/CMP-LP", stepping: "D", revision: 1),
            MFSPCHInitRecord(chipset: "CNP/CMP-LP", stepping: "A", revision: 1),
        ]
        let out = PCHInitDecoder.aggregate(records)
        // First-appearance order; per chipset the union of letters, reverse-sorted.
        XCTAssertEqual(out.map(\.chipset), ["CNP/CMP-LP", "SPT-H"])
        XCTAssertEqual(out[0].steppings, "DCA")       // "CA"+"D"+"A" → {D,C,A}
        XCTAssertEqual(out[1].steppings, "B")
    }

    func testAggregateEarlyReturnsOnEmptyFirstStepping() {
        let records = [
            MFSPCHInitRecord(chipset: "CNP/CMP-LP", stepping: "", revision: 1),
            MFSPCHInitRecord(chipset: "CNP/CMP-LP", stepping: "D", revision: 1),
        ]
        XCTAssertEqual(PCHInitDecoder.aggregate(records), [])
        XCTAssertEqual(PCHInitDecoder.aggregate([]), [])
    }

    func testAggregateSingleRecord() {
        let records = [MFSPCHInitRecord(chipset: "SPT-H", stepping: "BA", revision: 2)]
        let out = PCHInitDecoder.aggregate(records)
        XCTAssertEqual(out.map(\.chipset), ["SPT-H"])
        XCTAssertEqual(out[0].steppings, "BA")
    }

    // MARK: - decode (slicing mphytbl records out of file-6 content)

    private static func fileRecord(name: String, offset: Int, size: Int,
                                   folder: Bool = false) -> MFSRawConfigRecord {
        MFSRawConfigRecord(name: name, isFolder: folder, size: size, offset: offset,
                           unixRights: 0, integrity: false, encryption: false,
                           antiReplay: false, oemConfigurable: false,
                           mcaConfigurable: false, reserved: 0,
                           ownerUserID: 0, ownerGroupID: 0)
    }

    private static func config(_ owningFile: Int, _ records: [MFSRawConfigRecord]) -> [MFSConfigDecode] {
        [MFSConfigDecode(owningFile: owningFile, records: records)]
    }

    func testDecodeSlicesAndAggregatesMphytblRecordsFromFileSix() throws {
        // File 6 carries an old-layout table at 0 and a new-layout table at 0x40;
        // its owning config lists both. CSME 12 @2018-01-25 → bitfield.
        var file6 = Self.oldTable(chipset: 0xC, stepping: 0x5, revision: 4)  // @0 → 4 bytes
        file6.append(Data(repeating: 0xAA, count: 0x40 - 4))                 // pad to 0x40
        file6.append(Self.newTable(chipset: 0xD, stepping: 0x2, revision: 6))// @0x40
        let files = [MFSLowLevelFile(index: 6, content: file6)]
        let configs = Self.config(6, [
            Self.fileRecord(name: "mphytbl0", offset: 0, size: 4),
            Self.fileRecord(name: "mphytbl1", offset: 0x40, size: 9),
        ])

        let out = try XCTUnwrap(PCHInitDecoder.decode(
            files: files, configurations: configs,
            variant: "CSME", major: 12, minor: 0, build: 0,
            year: 2018, month: 1, day: 25))

        XCTAssertEqual(out.records.count, 2)
        XCTAssertEqual(out.records[0].chipset, "CNP/CMP-LP")   // old nibble 0xC
        XCTAssertEqual(out.records[0].stepping, "CA")          // bitfield(0x5)
        XCTAssertEqual(out.records[0].revision, 4)
        XCTAssertEqual(out.records[1].chipset, "CNP/CMP-H")    // new byte 0xD
        XCTAssertEqual(out.records[1].stepping, "B")           // bitfield(0x2)
        XCTAssertEqual(out.records[1].revision, 6)
        XCTAssertEqual(out.chipsets.map(\.chipset), ["CNP/CMP-LP", "CNP/CMP-H"])
        XCTAssertEqual(out.chipsets[0].steppings, "CA")
        XCTAssertEqual(out.chipsets[1].steppings, "B")
    }

    func testDecodeSkipsFoldersNonMphytblAndInvalidRanges() throws {
        // One valid table sits at 0x20; folders, differently-named files, an
        // out-of-bounds slice, a zero-size record and a size-0 record are skipped.
        var content = Data(repeating: 0xAA, count: 0x20)
        content.append(Self.newTable(chipset: 0xE, stepping: 0xF, revision: 1)) // @0x20
        let files = [MFSLowLevelFile(index: 6, content: content)]
        let configs = Self.config(6, [
            Self.fileRecord(name: "mphytblF", offset: 0, size: 4, folder: true),
            Self.fileRecord(name: "other", offset: 0x10, size: 4),
            Self.fileRecord(name: "mphytblOOB", offset: 0x2C, size: 0x40),   // past EOF
            Self.fileRecord(name: "mphytbl0", offset: 0x20, size: 9),
            Self.fileRecord(name: "mphytblEmpty", offset: 0x30, size: 0),
        ])

        let out = try XCTUnwrap(PCHInitDecoder.decode(
            files: files, configurations: configs,
            variant: "CSME", major: 14, minor: 0, build: 0,
            year: 2020, month: 1, day: 1))

        XCTAssertEqual(out.records.map(\.chipset), ["LKF-LP"])
        XCTAssertEqual(out.records.map(\.stepping), ["DCBA"])
    }

    func testDecodeReturnsNilWithoutMphytblRecords() {
        let files = [MFSLowLevelFile(index: 6, content: Data(repeating: 0xAB, count: 0x40))]
        let configs = Self.config(6, [Self.fileRecord(name: "other", offset: 0, size: 4)])
        let out = PCHInitDecoder.decode(
            files: files, configurations: configs,
            variant: "CSME", major: 12, minor: 0, build: 0,
            year: 2018, month: 1, day: 25)
        XCTAssertNil(out)
    }

    func testDecodeReturnsNilWithoutFileSixOrItsConfig() {
        let other = [MFSLowLevelFile(index: 3, content: Data(repeating: 0, count: 8))]
        let six = [MFSLowLevelFile(index: 6, content: Data(repeating: 0, count: 8))]
        let own7 = Self.config(7, [Self.fileRecord(name: "mphytbl0", offset: 0, size: 4)])
        XCTAssertNil(PCHInitDecoder.decode(files: other, configurations: own7,
                                           variant: "CSME", major: 12, minor: 0, build: 0,
                                           year: 2018, month: 1, day: 25))
        XCTAssertNil(PCHInitDecoder.decode(files: six, configurations: own7,
                                           variant: "CSME", major: 12, minor: 0, build: 0,
                                           year: 2018, month: 1, day: 25))
    }

    // MARK: - decode (the ID-keyed layouts, named through FileTable.dat)

    /// The `FTBL` half of a real table, cut to the two rows these tests join
    /// on: the chipset table's File ID and one that is not it. Copied from
    /// `FileTable.dat` platform `10` / dictionary `0A` — what a CSME 16.1
    /// volume header points at.
    private static let ftblJSON = """
    {
      "10": {
        "0A": {
          "FTBL": {
            "10038900": "/home/chipsetinit/mphytbl,1,0,0,1576,316,55,6,33554848",
            "1003A200": "/home/bup/bup_sku/hw_binding,0,0,0,0,0,0,7,0"
          }
        }
      }
    }
    """

    private static func le32(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private static func le16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    /// One ID-keyed (0xC) Configuration stream: the record count, that many
    /// `MFS_Config_Record_0xC` entries, then the bytes they point at — with
    /// offsets into the whole stream, the way a real one's are.
    private static func idStream(_ entries: [(id: Int, body: Data)]) -> Data {
        var head = le32(entries.count)
        var body = Data()
        let base = 4 + entries.count * 0xC
        for entry in entries {
            head.append(le32(entry.id))
            head.append(le32(base + body.count))
            head.append(le16(entry.body.count))
            head.append(le16(0))
            body.append(entry.body)
        }
        return head + body
    }

    /// The same stream in the named (0x1C) layout, for the FTPR copy of a
    /// legacy image's file 6.
    private static func namedStream(_ entries: [(name: String, body: Data)]) -> Data {
        var head = le32(entries.count)
        var body = Data()
        let base = 4 + entries.count * 0x1C
        for entry in entries {
            var name = Data(entry.name.utf8)
            name.append(Data(repeating: 0, count: max(0, 0xC - name.count)))
            head.append(name.prefix(0xC))              // @0x00 FileName
            head.append(le16(0))                       // @0x0C Reserved
            head.append(le16(0))                       // @0x0E AccessMode (RecordType 0 = file)
            head.append(le16(0))                       // @0x10 DeployOptions
            head.append(le16(entry.body.count))        // @0x12 FileSize
            head.append(le16(0))                       // @0x14 OwnerUserID
            head.append(le16(0))                       // @0x16 OwnerGroupID
            head.append(le32(base + body.count))       // @0x18 FileOffset
            body.append(entry.body)
        }
        return head + body
    }

    func testIDKeyedFileSixIsNamedThroughTheFileTable() throws {
        let stream = Self.idStream([
            (0x1003_A200, Data([0, 0, 0, 0])),
            (0x1003_8900, Self.newTable(chipset: 0x12, stepping: 0, revision: 8)),
        ])
        let files = [MFSLowLevelFile(index: 6, content: stream)]
        let configs = [MFSConfigIDDecode(
            owningFile: 6,
            records: try XCTUnwrap(MFSParser.decodeConfigIDRecords(stream)))]

        let out = try XCTUnwrap(PCHInitDecoder.decode(
            files: files, configurationsByID: configs,
            fileTable: try FileTable.parse(Self.ftblJSON),
            platform: 0x10, dictionary: 0x0A,
            variant: "CSME", major: 16, minor: 1, build: 1991,
            year: 2022, month: 8, day: 29))

        XCTAssertEqual(out.chipsets.map(\.chipset), ["ADP-LP"])
        XCTAssertEqual(out.chipsets.map(\.steppings), ["A"])
    }

    /// Without the table no record can be recognised as a chipset table: the
    /// ID is all the stream says, and upstream's own fallback name for an
    /// unkeyed row (`/Unknown/<ID>.bin`) is not one.
    func testIDKeyedFileSixWithoutATableNamesNothing() throws {
        let stream = Self.idStream([
            (0x1003_8900, Self.newTable(chipset: 0x12, stepping: 0, revision: 8)),
        ])
        let configs = [MFSConfigIDDecode(
            owningFile: 6,
            records: try XCTUnwrap(MFSParser.decodeConfigIDRecords(stream)))]
        XCTAssertNil(PCHInitDecoder.decode(
            files: [MFSLowLevelFile(index: 6, content: stream)],
            configurationsByID: configs, fileTable: nil,
            platform: 0x10, dictionary: 0x0A,
            variant: "CSME", major: 16, minor: 1, build: 1991,
            year: 2022, month: 8, day: 29))
    }

    // MARK: - decode (the FTPR intl.cfg stream)

    /// The CSME 15/16 case: the volume carries no file 6 at all and the FTPR
    /// module is the only Intel Configuration there is.
    func testIntelConfigurationStreamReadsTheIDKeyedLayout() throws {
        let stream = Self.idStream([
            (0x1003_A200, Data([0])),
            (0x1003_8900, Self.newTable(chipset: 0x12, stepping: 0, revision: 8)),
        ])
        let out = try XCTUnwrap(PCHInitDecoder.decode(
            intelConfiguration: stream, recordSize: 0xC,
            fileTable: try FileTable.parse(Self.ftblJSON),
            platform: 0x10, dictionary: 0x0A,
            variant: "CSME", major: 16, minor: 1, build: 1991,
            year: 2022, month: 8, day: 29))
        XCTAssertEqual(out.chipsets.map(\.chipset), ["ADP-LP"])
        XCTAssertEqual(out.chipsets.map(\.steppings), ["A"])
    }

    /// A record with no bytes behind it is not a table: upstream's
    /// `and rec_data` drops it, which is why the CSME 16 oracle reads no
    /// chipset although its `intl.cfg` does list an `mphytbl` row.
    func testAZeroLengthChipsetRecordIsSkipped() throws {
        let stream = Self.idStream([(0x1003_8900, Data())])
        XCTAssertNil(PCHInitDecoder.decode(
            intelConfiguration: stream, recordSize: 0xC,
            fileTable: try FileTable.parse(Self.ftblJSON),
            platform: 0x10, dictionary: 0x0A,
            variant: "CSME", major: 16, minor: 1, build: 1991,
            year: 2022, month: 8, day: 29))
    }

    /// The same module in the named layout — a legacy image whose FTPR keeps a
    /// copy of file 6 needs no table to read it.
    func testIntelConfigurationStreamReadsTheNamedLayout() throws {
        let stream = Self.namedStream([
            ("other", Data([0, 0, 0, 0])),
            ("mphytbl0", Self.oldTable(chipset: 0xC, stepping: 0x5, revision: 4)),
        ])
        let out = try XCTUnwrap(PCHInitDecoder.decode(
            intelConfiguration: stream, recordSize: 0x1C,
            fileTable: nil, platform: -1, dictionary: -1,
            variant: "CSME", major: 12, minor: 0, build: 1091,
            year: 2018, month: 1, day: 25))
        XCTAssertEqual(out.chipsets.map(\.chipset), ["CNP/CMP-LP"])
        XCTAssertEqual(out.chipsets.map(\.steppings), ["CA"])
    }
}
