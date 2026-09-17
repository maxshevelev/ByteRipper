import XCTest
@testable import MEFirmware

/// `FileTable.dat` — the table that names an FTBL-mode MFS volume's low-level
/// files (upstream `mfs_home13_anl` + `check_ftbl_pl` / `check_ftbl_id`,
/// MEA.py 7405–7445, 8303).
///
/// The records here are copied from the real file (platform `04`, dictionary
/// `0A` — the table the CSME 15 oracle dump's volume header points at), so the
/// field order is asserted against what upstream actually ships rather than
/// against a shape invented for a test.
final class FileTableTests: XCTestCase {
    private let json = """
    {
      "04": {
        "0A": {
          "FTBL": {
            "10003500": "/home/mca/manuf_ver,1,0,0,40,0,70,63,448",
            "10038900": "/home/chipsetinit/mphytbl,0,0,0,8,206,0,6,384",
            "10002000": "/home/ish_srv/bios2ish,1,0,0,3592,0,61,256,384",
            "10040000": "/home/upid/features_state,1,1,1,0,0,7,256,0"
          },
          "EFST": {
            "00003004": "3,76,548,5,0,BUP_MBP"
          }
        },
        "0B": {
          "FTBL": {
            "10003500": "/home/mca/other,1,0,0,40,0,70,63,448"
          }
        }
      },
      "01": {
        "0A": {
          "FTBL": {
            "10009900": "/home/icc/default,0,0,0,0,0,0,9,0"
          }
        }
      }
    }
    """

    private func table() throws -> FileTable {
        try FileTable.parse(json)
    }

    // MARK: - The record

    /// The nine fields upstream unpacks, in upstream's order — and `vfsID` is
    /// the seventh number, which is the one the whole lookup turns on.
    func testARecordIsReadInUpstreamsFieldOrder() throws {
        let entry = try XCTUnwrap(
            try table().record(namingFileIndex: 63, platform: 4, dictionary: 0x0A))
        XCTAssertEqual(entry.fileID, "10003500")
        XCTAssertEqual(entry.path, "/home/mca/manuf_ver")
        XCTAssertTrue(entry.integrity)
        XCTAssertFalse(entry.encryption)
        XCTAssertFalse(entry.antiReplay)
        XCTAssertEqual(entry.accessUnknown, 40)
        XCTAssertEqual(entry.groupID, 0)
        XCTAssertEqual(entry.userID, 70)
        XCTAssertEqual(entry.vfsID, 63)
        XCTAssertEqual(entry.unknown, 448)
    }

    /// An index the table names as `0` integrity is not flagged — the flag is
    /// read, not assumed from its neighbours.
    func testTheIntegrityFlagIsPerRecord() throws {
        let entry = try XCTUnwrap(
            try table().record(namingFileIndex: 6, platform: 4, dictionary: 0x0A))
        XCTAssertEqual(entry.path, "/home/chipsetinit/mphytbl")
        XCTAssertFalse(entry.integrity)
    }

    /// Two records claim the same file under different paths — 4836 `vfsID`s
    /// in the real file do — and upstream stops at the first
    /// (`break # Stop searching FTBL Dictionary at first VFS ID match`). The
    /// first is the one written first, which on the data as shipped is the
    /// lowest file ID; the record behind it is a name the file does not have.
    func testAFileClaimedTwiceTakesTheFirstRecordOnly() throws {
        let entry = try XCTUnwrap(
            try table().record(namingFileIndex: 256, platform: 4, dictionary: 0x0A))
        XCTAssertEqual(entry.path, "/home/ish_srv/bios2ish")
        XCTAssertEqual(entry.fileID, "10002000", "the lower file ID of the two")
        XCTAssertFalse(entry.encryption, "and its own flags, not the other record's")
    }

    /// A file the table does not name is not an error: it keeps its index and
    /// the panel says so.
    func testAnIndexTheTableDoesNotNameComesBackEmpty() throws {
        XCTAssertNil(try table().record(namingFileIndex: 1000,
                                        platform: 4, dictionary: 0x0A))
    }

    // MARK: - The two fallbacks

    /// A volume that names a platform and a dictionary this file has is read
    /// exactly there, with nothing assumed.
    func testAKnownPlatformAndDictionaryAreUsedAsGiven() throws {
        let resolution = try table().resolve(platform: 4, dictionary: 0x0A)
        XCTAssertEqual(resolution.platform, 4)
        XCTAssertEqual(resolution.dictionary, 0x0A)
        XCTAssertFalse(resolution.assumedPlatform)
        XCTAssertFalse(resolution.assumedDictionary)
        XCTAssertFalse(resolution.missing)
    }

    /// No platform in the volume header → `0x01` (ICP), and the resolution says
    /// it was assumed, so the panel can pass that on rather than presenting a
    /// guess as a fact (upstream warns in the same place).
    func testAMissingPlatformFallsBackToICP() throws {
        let resolution = try table().resolve(platform: -1, dictionary: 0x0A)
        XCTAssertEqual(resolution.platform, FileTable.defaultPlatform)
        XCTAssertTrue(resolution.assumedPlatform)
        XCTAssertFalse(resolution.missing)

        let entry = try XCTUnwrap(
            try table().record(namingFileIndex: 9, platform: -1, dictionary: 0x0A))
        XCTAssertEqual(entry.path, "/home/icc/default", "read from platform 01")
    }

    /// A platform the file does not carry falls back the same way.
    func testAnUnknownPlatformFallsBackToICP() throws {
        let resolution = try table().resolve(platform: 0x7F, dictionary: 0x0A)
        XCTAssertEqual(resolution.platform, FileTable.defaultPlatform)
        XCTAssertTrue(resolution.assumedPlatform)
    }

    /// A dictionary the platform does not have → `0x0A` (CON).
    func testAnUnknownDictionaryFallsBackToCON() throws {
        let resolution = try table().resolve(platform: 4, dictionary: 0x0C)
        XCTAssertEqual(resolution.platform, 4)
        XCTAssertEqual(resolution.dictionary, FileTable.defaultDictionary)
        XCTAssertTrue(resolution.assumedDictionary)
        XCTAssertFalse(resolution.assumedPlatform)
    }

    /// The fallback is not a claim that it worked: a platform whose fallback
    /// dictionary has no `FTBL` table reports `missing`, and names nothing.
    func testAPlatformWithNoFTBLTableReportsMissing() throws {
        let table = try FileTable.parse("""
        { "02": { "0B": { "EFST": { "00000000": "0,0,1,0,0,X" } } } }
        """)
        let resolution = table.resolve(platform: 2, dictionary: 0x0B)
        XCTAssertTrue(resolution.missing, "no FTBL table to name anything from")
        XCTAssertNil(table.record(namingFileIndex: 0, platform: 2, dictionary: 0x0B))
    }

    /// A dictionary named `0x0A` by a volume that has one is not "assumed" —
    /// the flag says whether the answer came from the volume or from the rule.
    func testTheDefaultDictionaryIsNotReportedAsAssumedWhenItWasAskedFor() throws {
        let resolution = try table().resolve(platform: 4, dictionary: 0x0A)
        XCTAssertFalse(resolution.assumedDictionary)
    }

    // MARK: - The file itself

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try FileTable.parse("not json")) { error in
            XCTAssertEqual(error as? MEADataError, .malformed(file: "FileTable.dat"))
        }
        XCTAssertThrowsError(try FileTable.parse("{}"))
    }

    /// A table of an unexpected shape is skipped rather than fatal: the file
    /// grows tables (`EFST` arrived after `FTBL`), and a reader that threw on
    /// the next one would stop naming anything the day it appears.
    func testAnUnexpectedShapeIsSkippedNotFatal() throws {
        let table = try FileTable.parse("""
        { "04": { "0A": { "FTBL": { "10003500": "/home/mca/manuf_ver,1,0,0,40,0,70,63,448" },
                          "NEW": [1, 2, 3] } } }
        """)
        XCTAssertEqual(
            table.record(namingFileIndex: 63, platform: 4, dictionary: 0x0A)?.path,
            "/home/mca/manuf_ver")
    }

    /// A record short of the nine fields names nothing: a wrong flag on a real
    /// file is worse than no name.
    func testAShortRecordIsNoEntry() {
        XCTAssertNil(FileTable.entry(fileID: "1", record: "/home/x,1,0,0"))
        XCTAssertNil(FileTable.entry(fileID: "1", record: "/home/x,1,0,0,0,0,0,x,0"))
        XCTAssertNotNil(FileTable.entry(fileID: "1", record: "/home/x,1,0,0,0,0,0,7,0"))
    }

    /// An empty table is the "no source configured" case, and says so rather
    /// than looking like a table with nothing in it.
    func testAnEmptyTableIsEmpty() {
        XCTAssertTrue(FileTable().isEmpty)
        XCTAssertNil(FileTable().record(namingFileIndex: 0, platform: 4, dictionary: 0x0A))
    }
}
