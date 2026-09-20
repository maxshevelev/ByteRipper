import XCTest
import MEFirmware
@testable import MEPresentation

/// `MFSFileNames` + the file rows it names — the panel's half of upstream's
/// `mfs_home13_anl`: an FTBL-mode MFS volume's low-level files have no name in
/// their bytes, so the names come out of `FileTable.dat` on the way to the
/// rows, and never out of the analysis.
final class MFSFileNamesTests: XCTestCase {
    // MARK: - Fixtures

    /// The shape of the real table, cut down: platform `04` / dictionary `0A`
    /// is the one the CSME 15 oracle dump's volume header names.
    private let json = """
    {
      "04": {
        "0A": {
          "FTBL": {
            "10003500": "/home/mca/manuf_ver,1,0,0,40,0,70,63,448",
            "10038900": "/home/chipsetinit/mphytbl,0,0,0,8,206,0,6,384",
            "10002000": "/home/ish_srv/bios2ish,1,0,0,3592,0,61,7,384",
            "10040000": "/home/upid/features_state,0,1,1,0,0,7,7,0"
          }
        }
      },
      "01": {
        "0A": { "FTBL": { "10009900": "/home/icc/default,0,0,0,0,0,0,6,0" } }
      }
    }
    """

    private func table() throws -> FileTable { try FileTable.parse(json) }

    /// An FTBL-mode volume with the three files the table can speak about.
    /// `split` indices carry an Integrity table the engine took off the end,
    /// the way an FTBL volume's flagged files arrive.
    private func volume(platform: Int = 4, dictionary: Int = 0x0A,
                        indices: [Int] = [6, 7, 63, 99],
                        split: Set<Int> = []) throws -> MFSVolume {
        let integrity: [String: Any] = [
            "size": 0x28, "hmacHex": "AABB", "flagsRaw": 2,
            "antiReplayProtection": true, "encryptionProtection": false,
            "antiReplayIndex": 3, "securityVersion": 0,
            "arRandom": 0x99, "arCounter": 7, "nonceHex": "CCDD",
        ]
        let json: [String: Any] = [
            "offset": 0x1FF000, "pageSize": 0x2000, "pageCount": 49,
            "systemPageCount": 1, "dataPageCount": 48,
            "signatureValid": true, "volumeSize": 0x64000,
            "computedVolumeSize": 0x62000, "fileRecordCount": 1024,
            "usedFileCount": indices.count,
            "ftblDictionary": dictionary, "ftblPlatform": platform,
            "ftblReserved": 0, "usesFTBL": true,
            "presentFileCount": indices.count, "fileBytes": 0x100 * indices.count,
            "files": indices.map { index -> [String: Any] in
                guard split.contains(index) else { return ["index": index, "size": 0x100] }
                return ["index": index, "size": 0x100,
                        "contentSize": 0x100 - 0x28, "integrity": integrity]
            },
            "configurations": [], "reservedIntegrity": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(MFSVolume.self, from: data)
    }

    private func analysis(with volume: MFSVolume) throws -> FirmwareAnalysis {
        let base: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1716],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x200000, "regions": [], "issues": [],
            "mfsVolume": try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(volume)),
        ]
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    private func field(_ label: String, in node: MEANode) -> String? {
        node.fields.first(where: { $0.label == label })?.value
    }

    private func files(_ roots: [MEANode]) throws -> MEANode {
        let mfs = try XCTUnwrap(roots.first(where: { $0.title == "File System (MFS)" }))
        return try XCTUnwrap(mfs.children.first(where: { $0.title == "Files" }))
    }

    // MARK: - The lookup

    /// Every present file is looked up once, and only those: a table of two
    /// thousand records describes many volumes, and this volume's files are
    /// the question.
    func testItNamesThePresentFilesAndNothingElse() throws {
        let names = MFSFileNames(table: try table(), volume: try volume())
        XCTAssertEqual(names.path(for: 63), "/home/mca/manuf_ver")
        XCTAssertEqual(names.path(for: 6), "/home/chipsetinit/mphytbl")
        XCTAssertNil(names.path(for: 99), "the table names no file 99")
        XCTAssertEqual(Set(names.entries.keys), [6, 7, 63],
                       "and nothing was looked up for files this volume does not have")
    }

    /// A file two records claim is named by the first of them, as upstream's
    /// `break` names it — the second is a name the file does not have.
    func testAFileClaimedTwiceTakesTheFirstRecord() throws {
        let names = MFSFileNames(table: try table(), volume: try volume())
        XCTAssertEqual(names.path(for: 7), "/home/ish_srv/bios2ish")
        XCTAssertEqual(names.record(for: 7)?.fileID, "10002000")
    }

    /// The volume's own platform and dictionary name the table, and the label
    /// says which — with no word about assuming, because nothing was assumed.
    func testTheLabelNamesTheTableTheVolumeAskedFor() throws {
        let names = MFSFileNames(table: try table(), volume: try volume())
        XCTAssertEqual(names.tableLabel, "04 / 0A")
    }

    /// A volume whose platform this table does not carry is read under
    /// upstream's fallback — and the label says the platform was assumed, so
    /// the panel never presents a guess as a fact.
    func testAnAssumedPlatformIsSaidSo() throws {
        let names = MFSFileNames(table: try table(), volume: try volume(platform: 0x7F))
        XCTAssertEqual(names.tableLabel, "01 / 0A (assumed platform)")
        XCTAssertEqual(names.path(for: 6), "/home/icc/default",
                       "named out of the fallback platform's own table")
    }

    /// Both halves assumed reads as both.
    func testBothHalvesAssumedAreSaidSo() throws {
        let names = MFSFileNames(table: try table(),
                                 volume: try volume(platform: -1, dictionary: -1))
        XCTAssertEqual(names.tableLabel, "01 / 0A (assumed platform and dictionary)")
    }

    /// No table at all — no data source, or a machine that could not reach one
    /// — looks up nothing and says nothing.
    func testAnEmptyTableNamesNothing() throws {
        let names = MFSFileNames(table: FileTable(), volume: try volume())
        XCTAssertEqual(names, .none)
        XCTAssertNil(names.tableLabel)
        XCTAssertTrue(names.isEmpty)
    }

    /// A table that has no `FTBL` for this volume is reported rather than
    /// passed off as a lookup that found nothing: the row's numbers stand, and
    /// the volume says where the panel looked.
    func testAMissingTableIsReported() throws {
        let table = try FileTable.parse("""
        { "02": { "0B": { "EFST": { "01": { "00000000": "0,0,1,0,0,X" } } } } }
        """)
        let names = MFSFileNames(table: table, volume: try volume(platform: 2, dictionary: 0x0B))
        XCTAssertTrue(names.isEmpty)
        XCTAssertEqual(names.tableLabel, "02 / 0B — not in FileTable.dat",
                       "the volume's own table — it exists, it just has no FTBL")
    }

    // MARK: - The rows

    /// Before the table arrives the rows read as they always have: the number
    /// is what the flash says about the file.
    func testTheRowsKeepTheirNumbersWithoutATable() throws {
        let roots = MEACurator.present(try analysis(with: try volume()))
        let files = try files(roots)
        XCTAssertEqual(files.children.map(\.title),
                       ["File 6", "File 7", "File 63", "File 99"])
        XCTAssertNil(field("Path", in: files.children[0]))
        let mfs = try XCTUnwrap(roots.first(where: { $0.title == "File System (MFS)" }))
        XCTAssertNil(field("File Table", in: mfs), "no lookup, nothing to say about one")
    }

    /// With the table in hand a row is called what the table calls it, keeps
    /// the index in its subtitle — a reader compares the panel with the dump,
    /// and with upstream's own `path (0063)` — and carries the record's flags.
    func testANamedRowCarriesThePathAndTheRecordsFlags() throws {
        let volume = try volume()
        let names = MFSFileNames(table: try table(), volume: volume)
        let files = try files(MEACurator.present(try analysis(with: volume), mfsNames: names))

        let named = try XCTUnwrap(files.children.first { $0.title == "/home/mca/manuf_ver" })
        XCTAssertEqual(named.subtitle, "#63 · 0x100 (256 bytes)")
        XCTAssertEqual(field("Index", in: named), "63")
        XCTAssertEqual(field("File ID", in: named), "0x10003500")
        XCTAssertEqual(field("Integrity", in: named), "Yes")
        XCTAssertEqual(field("Encryption", in: named), "No")
        XCTAssertEqual(field("Anti-Replay", in: named), "No")
        XCTAssertEqual(field("User ID", in: named), "0x46")

        // The flags are the record's own, not the volume's: file 6 is the one
        // the table says carries no integrity tail.
        let plain = try XCTUnwrap(files.children.first {
            $0.title == "/home/chipsetinit/mphytbl" })
        XCTAssertEqual(field("Integrity", in: plain), "No")
    }

    /// The row says which record named it, and the record upstream would not
    /// have reached is not a row of its own.
    func testARowNamesOneRecordAndSaysWhichOne() throws {
        let volume = try volume()
        let names = MFSFileNames(table: try table(), volume: volume)
        let files = try files(MEACurator.present(try analysis(with: volume), mfsNames: names))
        let row = try XCTUnwrap(files.children.first { $0.title == "/home/ish_srv/bios2ish" })
        XCTAssertEqual(field("File ID", in: row), "0x10002000",
                       "the record the name came from, checkable against the console")
        XCTAssertNil(files.children.first { $0.title == "/home/upid/features_state" },
                     "the record upstream's break never reaches names nothing here either")
    }

    /// A file the table does not name keeps its number, in the same list as
    /// the named ones.
    func testAnUnnamedFileKeepsItsNumberBesideTheNamedOnes() throws {
        let volume = try volume()
        let names = MFSFileNames(table: try table(), volume: volume)
        let files = try files(MEACurator.present(try analysis(with: volume), mfsNames: names))
        let row = try XCTUnwrap(files.children.first { $0.title == "File 99" })
        XCTAssertEqual(row.subtitle, "0x100 (256 bytes)",
                       "no index in the subtitle: the title is the index")
        XCTAssertNil(field("Path", in: row))
    }

    /// A file whose Integrity table the engine took off the end reads as
    /// upstream prints it: `Size` is the content, the whole chain is beside it,
    /// and the table is a row of its own under the file.
    func testASplitFileShowsItsContentSizeAndItsTable() throws {
        let volume = try volume(split: [63])
        let names = MFSFileNames(table: try table(), volume: volume)
        let files = try files(MEACurator.present(try analysis(with: volume), mfsNames: names))
        let row = try XCTUnwrap(files.children.first { $0.title == "/home/mca/manuf_ver" })

        XCTAssertEqual(field("Size", in: row), "0xD8 (216 bytes)", "0x100 less the 0x28 tail")
        XCTAssertEqual(field("Chain Size", in: row), "0x100 (256 bytes)")
        XCTAssertEqual(row.subtitle, "#63 · 0xD8 (216 bytes)")
        let table = try XCTUnwrap(row.children.first { $0.title == "Integrity" })
        XCTAssertEqual(table.subtitle, "0x28 (40 bytes)")
        XCTAssertFalse(table.fields.isEmpty, "the table's own fields are on its row")
    }

    /// A file with no table is not given a chain-size row it does not need: the
    /// two numbers are the same one.
    func testAFileWithNoTableShowsOneSize() throws {
        let volume = try volume()
        let names = MFSFileNames(table: try table(), volume: volume)
        let files = try files(MEACurator.present(try analysis(with: volume), mfsNames: names))
        let row = try XCTUnwrap(files.children.first { $0.title == "/home/mca/manuf_ver" })
        XCTAssertEqual(field("Size", in: row), "0x100 (256 bytes)")
        XCTAssertNil(field("Chain Size", in: row))
        XCTAssertTrue(row.children.isEmpty)
    }

    /// The volume's own row says which table the names came from, so a reader
    /// can check the panel against upstream's console.
    func testTheVolumeSaysWhichTableNamedItsFiles() throws {
        let volume = try volume()
        let names = MFSFileNames(table: try table(), volume: volume)
        let roots = MEACurator.present(try analysis(with: volume), mfsNames: names)
        let mfs = try XCTUnwrap(roots.first(where: { $0.title == "File System (MFS)" }))
        XCTAssertEqual(field("Uses FileTable.dat", in: mfs), "Yes")
        XCTAssertEqual(field("File Table", in: mfs), "04 / 0A")
    }
}
