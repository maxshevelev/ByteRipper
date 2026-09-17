import XCTest
import MEFirmware
@testable import MEATool

/// `ConfigRecordPaths` + the record rows it names — the panel's half of the 0xC
/// branch of upstream's `mfs_cfg_anl`. An ID-keyed Configuration record carries
/// no name: the path is the `FTBL` row stored under the record's own File ID as
/// its key, which is DB text and so never a field of the analysis.
final class ConfigRecordPathsTests: XCTestCase {
    // MARK: - Fixtures

    /// Real rows of the file, at the platform/dictionary the CSME 15 dump's MFS
    /// volume header names, for File IDs its FITC payload actually carries.
    private let json = """
    {
      "04": {
        "0B": {
          "FTBL": {
            "10080A00": "/home/amt/rtfd/PrivacyLvl,1,0,0,0,0,85,394,384",
            "10080700": "/home/amt/rtfd/UC.Config,1,0,0,0,0,85,391,384",
            "10004A00": "/home/mca/deploy,1,0,0,40,206,69,0,420"
          }
        }
      },
      "01": {
        "0A": { "FTBL": { "10009900": "/home/icc/default,0,0,0,0,0,0,6,0" } }
      }
    }
    """

    private func table() throws -> FileTable { try FileTable.parse(json) }

    /// The three records of the fixture payload: two the table names and one it
    /// does not.
    private let records = [
        MFSConfigIDRecord(fileID: 0x1008_0A00, offset: 0, size: 1,
                          oemConfigurable: true, unknownFlags: 0),
        MFSConfigIDRecord(fileID: 0x1008_0700, offset: 1, size: 0x10,
                          oemConfigurable: false, unknownFlags: 0),
        MFSConfigIDRecord(fileID: 0xDEAD_BEEF, offset: 0x11, size: 4,
                          oemConfigurable: false, unknownFlags: 3),
    ]

    private func paths(platform: Int = 4, dictionary: Int = 0x0B) throws
        -> ConfigRecordPaths {
        ConfigRecordPaths(table: try table(), fileIDs: records.map(\.fileID),
                          platform: platform, dictionary: dictionary)
    }

    /// An analysis with a FITC partition whose payload carries `records`, the
    /// way one arrives once the identity-gated decode has run.
    private func analysis(payloadOffset: Int? = 0x315010,
                          streamOnVolume: Bool = false) throws -> FirmwareAnalysis {
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(records))
        var oem: [String: Any] = [
            "offset": 0x315000, "headerRevision": 1, "dataLength": 0x3061,
            "headerCRCValid": true, "dataCRCValid": true,
            "recordsByID": encoded,
        ]
        if let payloadOffset { oem["payloadOffset"] = payloadOffset }
        var mfs: [String: Any] = [
            "offset": 0x322000, "pageSize": 0x2000, "pageCount": 49,
            "systemPageCount": 1, "dataPageCount": 48, "signatureValid": true,
            "volumeSize": 0x64000, "computedVolumeSize": 0x64000,
            "fileRecordCount": 1024, "usedFileCount": 0,
            "ftblDictionary": 0x0B, "ftblPlatform": 4, "ftblReserved": 0,
            "usesFTBL": true, "presentFileCount": 0, "fileBytes": 0,
            "files": [], "configurations": [], "reservedIntegrity": [],
        ]
        if streamOnVolume {
            mfs["configurationsByID"] = [["owningFile": 7, "records": encoded]]
        }
        let base: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1716],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x2000000, "regions": [], "issues": [],
            "mfsVolume": mfs, "oemConfiguration": oem,
        ]
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    private func field(_ label: String, in node: MEANode) -> String? {
        node.fields.first(where: { $0.label == label })?.value
    }

    private func recordRows(_ roots: [MEANode], group: String = "OEM Configuration")
        throws -> MEANode {
        let oem = try XCTUnwrap(roots.first(where: { $0.title == group }))
        return try XCTUnwrap(oem.children.first(where: { $0.title == "Configuration Records" }))
    }

    // MARK: - The lookup

    /// The path is the row stored under the record's File ID, not the row whose
    /// `vfsID` happens to equal it.
    func testARecordIsNamedByTheRowAtItsOwnKey() throws {
        let paths = try paths()
        XCTAssertEqual(paths.path(for: 0x1008_0A00), "/home/amt/rtfd/PrivacyLvl")
        XCTAssertTrue(paths.isNamed(0x1008_0A00))
        XCTAssertEqual(paths.path(for: 0x1008_0700), "/home/amt/rtfd/UC.Config")
    }

    /// An ID the table has no row for reads as upstream writes the file out,
    /// which says the record is real and its name is not known.
    func testAnUnknownIDReadsAsUpstreamsFallback() throws {
        let paths = try paths()
        XCTAssertEqual(paths.path(for: 0xDEAD_BEEF), "/Unknown/DEADBEEF.bin")
        XCTAssertFalse(paths.isNamed(0xDEAD_BEEF))
    }

    /// Before anything was looked up there is no fallback either: nothing has
    /// been asked, so the row keeps its File ID rather than claiming the table
    /// had nothing for it.
    func testWithNothingLookedUpThereIsNoPathAtAll() {
        XCTAssertNil(ConfigRecordPaths.none.path(for: 0x1008_0A00))
        XCTAssertNil(ConfigRecordPaths.none.tableLabel)
        XCTAssertTrue(ConfigRecordPaths.none.isEmpty)
    }

    /// An empty table is nothing looked up, not a lookup that found nothing.
    func testAnEmptyTableIsNone() throws {
        let paths = ConfigRecordPaths(table: FileTable(), fileIDs: [1, 2],
                                      platform: 4, dictionary: 0x0B)
        XCTAssertEqual(paths, .none)
    }

    /// The platform and dictionary are the MFS volume's, with upstream's own
    /// fallbacks when it has none — and the label says when either was assumed.
    func testTheFallbacksAreReportedOnTheLabel() throws {
        XCTAssertEqual(try paths().tableLabel, "04 / 0B")
        let assumed = try paths(platform: -1, dictionary: -1)
        XCTAssertEqual(assumed.resolution?.platform, 0x01)
        XCTAssertEqual(assumed.tableLabel, "01 / 0A (assumed platform and dictionary)")
        XCTAssertFalse(assumed.isNamed(0x1008_0A00), "another platform's table")
        XCTAssertEqual(assumed.path(for: 0x1008_0A00), "/Unknown/10080A00.bin",
                       "so the record reads as upstream writes it out")
    }

    // MARK: - The rows

    /// A named row reads as the path, carries what the record says about itself,
    /// and stands for the bytes it points at — the payload's position plus the
    /// record's own offset.
    func testANamedRowCarriesTheRecordsFactsAndItsBytes() throws {
        let roots = MEACurator.present(try analysis(), configPaths: try paths())
        let rows = try recordRows(roots)
        XCTAssertEqual(rows.subtitle, "3 records")
        let first = try XCTUnwrap(rows.children.first)
        XCTAssertEqual(first.title, "/home/amt/rtfd/PrivacyLvl")
        XCTAssertEqual(field("File ID", in: first), "0x10080A00")
        XCTAssertEqual(field("Size", in: first), "0x1 (1 bytes)")
        XCTAssertEqual(field("Offset", in: first), "0x0")
        XCTAssertEqual(field("OEM Configurable", in: first), "Yes")
        XCTAssertEqual(field("Reserved Flags", in: first), "0x0")
        XCTAssertEqual(first.range, 0x315010..<0x315011)

        let second = try XCTUnwrap(rows.children.dropFirst().first)
        XCTAssertEqual(second.range, 0x315011..<0x315021, "payload start + its offset")
        XCTAssertEqual(field("OEM Configurable", in: second), "No")
    }

    /// The row the table could not name still reads as a record, under the name
    /// upstream gives it.
    func testAnUnnamedRowKeepsItsFallbackName() throws {
        let roots = MEACurator.present(try analysis(), configPaths: try paths())
        let last = try XCTUnwrap(try recordRows(roots).children.last)
        XCTAssertEqual(last.title, "/Unknown/DEADBEEF.bin")
        XCTAssertEqual(field("Path", in: last), "/Unknown/DEADBEEF.bin")
        XCTAssertEqual(field("Reserved Flags", in: last), "0x3")
    }

    /// Before the table arrives the rows are the records the engine decoded,
    /// under the ID the stream keys them by — and they still point at bytes.
    func testWithoutTheTableTheRowsAreTheirFileIDs() throws {
        let roots = MEACurator.present(try analysis())
        let rows = try recordRows(roots)
        XCTAssertEqual(rows.children.map(\.title),
                       ["Record 0x10080A00", "Record 0x10080700", "Record 0xDEADBEEF"])
        XCTAssertNil(field("Path", in: rows.children[0]))
        XCTAssertEqual(rows.children[0].range, 0x315010..<0x315011)
    }

    /// A payload whose position is unknown leaves the rows without bytes rather
    /// than pointing them at an offset that means nothing in the image.
    func testWithoutAPayloadOffsetTheRowsPointAtNothing() throws {
        let roots = MEACurator.present(try analysis(payloadOffset: nil),
                                       configPaths: try paths())
        for row in try recordRows(roots).children {
            XCTAssertNil(row.range)
        }
    }

    /// The group says which table the paths came from, and the record list is
    /// rows rather than the reflected "N entries" a field would be.
    func testTheGroupNamesTheTableAndDropsTheReflectedList() throws {
        let roots = MEACurator.present(try analysis(), configPaths: try paths())
        let oem = try XCTUnwrap(roots.first(where: { $0.title == "OEM Configuration" }))
        XCTAssertEqual(field("File Table", in: oem), "04 / 0B")
        XCTAssertNil(field("recordsByID", in: oem))
        XCTAssertNil(field("records", in: oem))
        XCTAssertEqual(field("headerRevision", in: oem), "1")
    }

    /// A volume that carries its own ID-keyed stream shows it under the volume,
    /// named after the low-level file it came from — and without byte ranges:
    /// those records live in a FAT chain, not at one place in the image.
    func testAVolumesOwnStreamIsARowUnderTheVolume() throws {
        let roots = MEACurator.present(try analysis(streamOnVolume: true),
                                       configPaths: try paths())
        let mfs = try XCTUnwrap(roots.first(where: { $0.title == "File System (MFS)" }))
        let stream = try XCTUnwrap(mfs.children.first(where: {
            $0.title == "OEM Configuration"
        }))
        XCTAssertEqual(stream.subtitle, "3 records")
        XCTAssertEqual(stream.children.first?.title, "/home/amt/rtfd/PrivacyLvl")
        XCTAssertNil(stream.children.first?.range)
    }
}
