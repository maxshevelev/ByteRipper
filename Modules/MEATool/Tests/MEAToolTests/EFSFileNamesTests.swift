import XCTest
import MEFirmware
@testable import MEATool

/// `EFSFileNames` + the file rows it names — the panel's half of upstream's
/// `efs_anl` file walk. An EFS volume's files have no name in their bytes at
/// all: the `EFST` records say where each one sits and what it is called, the
/// `FTBL` rows beside them give it a path and its flags, and both are text the
/// analysis never carries.
final class EFSFileNamesTests: XCTestCase {
    // MARK: - Fixtures

    /// The shape of the real table, cut down to the platform/dictionary the
    /// CSME 15 oracle dump's MFS volume header names and the files that dump's
    /// EFS volume carries.
    private let json = """
    {
      "04": {
        "0B": {
          "EFST": {
            "01": {
              "00000000": "0,0,12288,6,0,ICC_MPHYTBL",
              "00003004": "3,76,548,5,0,BUP_MBP",
              "0000322C": "3,628,80,4,0,POLICY_CPU_SID"
            },
            "02": {
              "00000000": "0,0,12288,6,0,RENAMED_LATER"
            }
          },
          "FTBL": {
            "10038900": "/home/chipsetinit/mphytbl,0,0,0,8,206,0,6,384",
            "10008D00": "/home/bup/mbp,1,0,0,0,0,3,5,384",
            "10008000": "/home/policy/skumgr/cpu_sid,1,0,1,40,346,85,4,448"
          }
        },
        "0A": { "FTBL": { "10009900": "/home/icc/default,0,0,0,0,0,0,6,0" } }
      },
      "01": {
        "0A": { "FTBL": { "10009900": "/home/icc/default,0,0,0,0,0,0,6,0" } }
      }
    }
    """

    private func table() throws -> FileTable { try FileTable.parse(json) }

    /// An EFS volume carrying `files`, the way one arrives once the engine has
    /// cut its data area at the table's offsets. `split` file IDs end with an
    /// Integrity table the engine took off.
    private func volume(dictionaryRevision: Int = 1,
                        files: [(id: Int, offset: Int)] = [(6, 0), (5, 0x3004),
                                                           (4, 0x322C)],
                        split: Set<Int> = [5]) throws -> EFSVolume {
        let integrity: [String: Any] = [
            "size": 0x28, "hmacHex": "AABB", "flagsRaw": 2,
            "antiReplayProtection": true, "encryptionProtection": false,
            "antiReplayIndex": 3, "securityVersion": 0,
            "arRandom": 0x99, "arCounter": 7, "nonceHex": "CCDD",
        ]
        let json: [String: Any] = [
            "offset": 0x463000, "pageSize": 0x1000, "systemPageCount": 1,
            "dataPageCount": 14, "scratchPageCount": 1, "scratchPagesEmpty": true,
            "dataPageCountMatchesSystem": true, "dictionary": 0x0B,
            "revision": 1, "unknown1": 2, "dictionaryRevision": dictionaryRevision,
            "dataPagesCommitted": 10, "dataPagesReserved": 4,
            "systemHeaderCRCValid": true, "indexesCRCValid": true,
            "firstIndexPaddingEmpty": true, "dataPageOrder": [],
            "dataPageHeaderCRCsValid": true, "dataPageFooterCRCsValid": true,
            "files": files.map { file -> [String: Any] in
                guard split.contains(file.id) else {
                    return ["fileID": file.id, "dataOffset": file.offset,
                            "storedSize": 0x100, "metadataUnknown": 0xAB12,
                            "contentSize": 0x100]
                }
                return ["fileID": file.id, "dataOffset": file.offset,
                        "storedSize": 0x100, "metadataUnknown": 0xAB12,
                        "contentSize": 0x100 - 0x28, "integrity": integrity]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(EFSVolume.self, from: data)
    }

    /// The analysis as it arrives on a CSME 15 dump: an MFS volume that names
    /// the platform and dictionary, and the EFS volume beside it.
    private func analysis(with volume: EFSVolume,
                          platform: Int = 4, dictionary: Int = 0x0B) throws
        -> FirmwareAnalysis {
        let mfs: [String: Any] = [
            "offset": 0x1FF000, "pageSize": 0x2000, "pageCount": 49,
            "systemPageCount": 1, "dataPageCount": 48, "signatureValid": true,
            "volumeSize": 0x64000, "computedVolumeSize": 0x64000,
            "fileRecordCount": 1024, "usedFileCount": 0,
            "ftblDictionary": dictionary, "ftblPlatform": platform,
            "ftblReserved": 0, "usesFTBL": true, "presentFileCount": 0,
            "fileBytes": 0, "files": [], "configurations": [],
            "reservedIntegrity": [],
        ]
        let base: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1716],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x800000, "regions": [], "issues": [],
            "mfsVolume": mfs,
            "efsVolume": try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(volume)),
        ]
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    private func names(_ volume: EFSVolume, platform: Int = 4,
                       dictionary: Int = 0x0B) throws -> EFSFileNames {
        EFSFileNames(table: try table(), volume: volume,
                     platform: platform, dictionary: dictionary)
    }

    private func field(_ label: String, in node: MEANode) -> String? {
        node.fields.first(where: { $0.label == label })?.value
    }

    private func fileRows(_ roots: [MEANode]) throws -> MEANode {
        let efs = try XCTUnwrap(roots.first(where: { $0.title == "EFS Volume" }))
        return try XCTUnwrap(efs.children.first(where: { $0.title == "Files" }))
    }

    // MARK: - The lookup

    /// The two halves are read together: `EFST` gives the name, and the `FTBL`
    /// row with the same file ID gives the path and the flags.
    func testAFileIsNamedByEFSTAndDescribedByFTBL() throws {
        let names = try names(try volume())
        XCTAssertEqual(names.name(for: 5), "BUP_MBP")
        XCTAssertEqual(names.record(for: 5)?.path, "/home/bup/mbp")
        XCTAssertTrue(names.record(for: 5)?.integrity == true)
        XCTAssertEqual(names.name(for: 6), "ICC_MPHYTBL")
        XCTAssertFalse(names.record(for: 6)?.integrity == true)
    }

    /// The revision is the EFS System page's own, and it selects the table: the
    /// same dictionary carries another revision's entries, and they are not the
    /// ones this volume's files are named by.
    func testTheSystemPagesRevisionSelectsTheTable() throws {
        XCTAssertEqual(try names(try volume(dictionaryRevision: 1)).name(for: 6),
                       "ICC_MPHYTBL")
        XCTAssertEqual(try names(try volume(dictionaryRevision: 2)).name(for: 6),
                       "RENAMED_LATER")
        XCTAssertEqual(try names(try volume(dictionaryRevision: 2)).revision, 2)
    }

    /// A revision the table does not carry names nothing — and says which
    /// table was asked, rather than falling back to another revision's names.
    func testARevisionTheTableDoesNotCarryNamesNothing() throws {
        let names = try names(try volume(dictionaryRevision: 9))
        XCTAssertTrue(names.isEmpty)
        XCTAssertTrue(names.hasTable)
        XCTAssertEqual(names.tableLabel, "04 / 0B rev 09 — no EFST at that revision")
    }

    /// The platform and dictionary are the *MFS* volume's, not the EFS page's
    /// own Dictionary field — upstream hands `efs_anl` the values it read out
    /// of the MFS volume header.
    func testTheLookupUsesTheMFSVolumesPlatformAndDictionary() throws {
        let names = try names(try volume(), platform: 4, dictionary: 0x0A)
        XCTAssertTrue(names.isEmpty,
                      "04 / 0A exists — it just carries no EFST, so nothing is named")
        XCTAssertEqual(names.tableLabel, "04 / 0A rev 01 — no EFST in FileTable.dat")
    }

    /// No MFS volume decoded alongside means no platform and no dictionary, and
    /// upstream's fallbacks answer — with the label saying both were assumed.
    func testWithNoMFSVolumeBothHalvesAreAssumed() throws {
        let names = try names(try volume(), platform: -1, dictionary: -1)
        XCTAssertEqual(names.resolution?.platform, 0x01)
        XCTAssertEqual(names.resolution?.dictionary, 0x0A)
        XCTAssertEqual(names.tableLabel,
                       "01 / 0A rev 01 — no EFST in FileTable.dat")
    }

    /// An empty table is nothing looked up, not a lookup that found nothing.
    func testAnEmptyTableIsNone() throws {
        let names = EFSFileNames(table: FileTable(), volume: try volume(),
                                 platform: 4, dictionary: 0x0B)
        XCTAssertEqual(names, .none)
        XCTAssertNil(names.tableLabel)
        XCTAssertNil(names.resolution)
    }

    // MARK: - The rows

    /// A named row reads as the file is called, keeps the file ID in its
    /// subtitle, and carries what both tables said about it.
    func testANamedRowCarriesBothTablesFacts() throws {
        let volume = try volume()
        let roots = MEACurator.present(try analysis(with: volume),
                                       efsNames: try names(volume))
        let rows = try fileRows(roots)
        XCTAssertEqual(rows.children.map(\.title),
                       ["ICC_MPHYTBL", "BUP_MBP", "POLICY_CPU_SID"])
        let mbp = try XCTUnwrap(rows.children.first { $0.title == "BUP_MBP" })
        XCTAssertEqual(field("VFS ID", in: mbp), "5")
        XCTAssertEqual(field("Path", in: mbp), "/home/bup/mbp")
        XCTAssertEqual(field("File ID", in: mbp), "0x10008D00")
        XCTAssertEqual(field("Integrity", in: mbp), "Yes")
        XCTAssertEqual(field("Data Offset", in: mbp), "0x3004")
        XCTAssertEqual(mbp.subtitle, "#5 · 0xD8 (216 bytes)")
    }

    /// A file split from an Integrity table shows the content size, the stored
    /// size beside it, and the table as its own row — the difference between
    /// the two is what came off the end.
    func testASplitRowShowsBothSizesAndTheTable() throws {
        let volume = try volume()
        let roots = MEACurator.present(try analysis(with: volume),
                                       efsNames: try names(volume))
        let mbp = try XCTUnwrap(try fileRows(roots).children
            .first { $0.title == "BUP_MBP" })
        XCTAssertEqual(field("Size", in: mbp), "0xD8 (216 bytes)")
        XCTAssertEqual(field("Stored Size", in: mbp), "0x100 (256 bytes)")
        let integrity = try XCTUnwrap(mbp.children.first)
        XCTAssertEqual(integrity.title, "Integrity")
        XCTAssertEqual(integrity.subtitle, "0x28 (40 bytes)")
    }

    /// An unsplit row says one size and nothing about a table it does not
    /// carry.
    func testAnUnsplitRowSaysOneSize() throws {
        let volume = try volume()
        let roots = MEACurator.present(try analysis(with: volume),
                                       efsNames: try names(volume))
        let icc = try XCTUnwrap(try fileRows(roots).children
            .first { $0.title == "ICC_MPHYTBL" })
        XCTAssertEqual(field("Size", in: icc), "0x100 (256 bytes)")
        XCTAssertNil(field("Stored Size", in: icc))
        XCTAssertTrue(icc.children.isEmpty)
    }

    /// Before the names arrive the rows are the files the engine found, under
    /// the number both tables key them by — the volume's own answer, not a gap.
    func testWithoutNamesTheRowsAreNumbered() throws {
        let roots = MEACurator.present(try analysis(with: try volume()))
        let rows = try fileRows(roots)
        XCTAssertEqual(rows.children.map(\.title), ["File 6", "File 5", "File 4"])
        XCTAssertEqual(rows.subtitle, "3 files")
        XCTAssertNil(field("Path", in: rows.children[0]))
    }

    /// The volume's row says which tables the names came from, and the file
    /// list is rows rather than a field on it.
    func testTheVolumeRowNamesTheTableAndDropsTheReflectedList() throws {
        let volume = try volume()
        let roots = MEACurator.present(try analysis(with: volume),
                                       efsNames: try names(volume))
        let efs = try XCTUnwrap(roots.first(where: { $0.title == "EFS Volume" }))
        XCTAssertEqual(field("File Table", in: efs), "04 / 0B rev 01")
        XCTAssertNil(field("files", in: efs), "the list is children, not a field")
        XCTAssertEqual(field("dictionary", in: efs), "11",
                       "and the volume's own reflected facts are still there")
    }

    /// A file no `FTBL` row claims keeps its name and its sizes: upstream
    /// prints an error and stores the file anyway, and the row is the file.
    func testAFileNoFTBLRowClaimsKeepsItsName() throws {
        let volume = try volume(files: [(6, 0), (70, 0x4000)], split: [])
        let names = try names(volume)
        let roots = MEACurator.present(try analysis(with: volume), efsNames: names)
        let rows = try fileRows(roots)
        let orphan = try XCTUnwrap(rows.children.last)
        XCTAssertEqual(orphan.title, "File 70", "no EFST entry either, so no name")
        XCTAssertNil(field("Path", in: orphan))
        XCTAssertEqual(field("VFS ID", in: orphan), "70")
    }
}
