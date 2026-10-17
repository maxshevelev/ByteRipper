import XCTest
import MEFirmware
import MEPresentation
import ToolModuleKit
@testable import MEATool

/// `MEASummary` — the pure builder behind the «Summary» tab: the primary
/// Field/Value table of MEA's console default output, then the analysis's
/// messages. Fixtures are decoded JSON, exactly as in `MEACuratorTests`, so the
/// tests exercise the same path the engine hands the module: a decoded
/// `FirmwareAnalysis`.
final class MEASummaryTests: XCTestCase {
    // MARK: - Fixtures

    private func analysis(_ overrides: [String: Any]) throws -> FirmwareAnalysis {
        var base: [String: Any] = [
            "family": "csme",
            "variant": "CSME",
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121],
            "release": "production",
            "type": "region",
            "sku": "",
            "platform": "",
            "sizeBytes": 0x200000,
            "regions": [],
            "issues": [],
        ]
        for (key, value) in overrides { base[key] = value }
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    /// The primary table — always the first block, which carries no title.
    private func tableRows(_ a: FirmwareAnalysis) -> [MEASummaryRow] {
        MEASummary.build(a, in: .english)[0].rows
    }

    private func value(_ label: String, in rows: [MEASummaryRow]) -> MEASummaryValue? {
        rows.first { $0.label == label }?.value
    }

    private func tone(_ label: String, in rows: [MEASummaryRow]) -> ToolValueTone? {
        rows.first { $0.label == label }?.tone
    }

    /// Seconds since the Cocoa reference date (the engine's own decode domain)
    /// for a calendar date — what `manufactureDate` carries in a fixture.
    private func referenceInterval(year: Int, month: Int, day: Int) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!.timeIntervalSinceReferenceDate
    }

    private func manifestJSON(productionReady: Bool? = true) -> [String: Any] {
        var manifest: [String: Any] = [
            "offset": 0x1000, "tag": "$MN2", "format": "r1",
            "major": 15, "minor": 40, "hotfix": 37, "build": 3121, "svn": 3,
            "day": 24, "month": 3, "year": 2021,
            "keyHash": "ABCDEF", "signatureHash": "0123456789ABCDEF",
        ]
        if let productionReady { manifest["productionReady"] = productionReady }
        return manifest
    }

    /// A full MFS volume, with the pch_init aggregation's `chipsets` when the
    /// analysis carried a Chipset Initialization decode.
    private func mfsJSON(chipset: String? = nil, steppings: String = "") -> [String: Any] {
        mfsJSON(chipsets: chipset.map { [($0, steppings)] })
    }

    /// The image's final Chipset Initialization aggregate — what the Chipset
    /// row reads. A legacy image's is the copy its MFS volume holds, so the
    /// fixtures set both, the way the engine fills them.
    private func chipsetInitJSON(_ chipsets: [(String, String)]) -> [String: Any] {
        ["records": [],
         "chipsets": chipsets.map { ["chipset": $0.0, "steppings": $0.1] }]
    }

    private func mfsJSON(chipsets: [(String, String)]?) -> [String: Any] {
        var volume: [String: Any] = [
            "offset": 0x70000, "pageSize": 0x1000, "pageCount": 0x40,
            "systemPageCount": 1, "dataPageCount": 0x3F,
            "signatureValid": true, "volumeSize": 0x40000,
            "computedVolumeSize": 0x3E800, "fileRecordCount": 0x40,
            "usedFileCount": 3, "ftblDictionary": 0, "ftblPlatform": 0,
            "ftblReserved": 0, "usesFTBL": false, "presentFileCount": 1,
            "fileBytes": 0x200,
            "files": [["index": 0, "size": 0x200]],
            "configurations": [], "reservedIntegrity": [],
        ]
        if let chipsets {
            volume["pchInit"] = [
                "records": [],
                "chipsets": chipsets.map { ["chipset": $0.0, "steppings": $0.1] },
            ]
        }
        return volume
    }

    /// A whole-flash IFWI carries Boot Partitions — the gate for the Flash
    /// Image Tool row. This boot's BPDT header carries a real FIT version
    /// (12.0.3.1091), so the row reads it.
    private func bootPartitionsJSON() -> [[String: Any]] {
        [["offset": 0x100, "partitionName": "Boot 1", "version": 2,
          "redundancy": true, "checksumValid": true,
          "fitMajor": 12, "fitMinor": 0, "fitHotfix": 3, "fitBuild": 1091,
          "entries": []]]
    }

    /// The same whole-flash shape but with a no-FIT BPDT header — a decoded
    /// 0/0xFFFF marker yields a nil quartet, which JSON encodes as *absent* —
    /// so the Flash Image Tool row then reads "N/A".
    private func bootPartitionsNoFITJSON() -> [[String: Any]] {
        [["offset": 0x100, "partitionName": "Boot 1", "version": 2,
          "redundancy": true, "checksumValid": true, "entries": []]]
    }

    // MARK: - The primary table, filled in

    /// An identified CSME-12-style image with every fact the engine has today:
    /// the table reads as MEA's ledger in order — real values where the bridge
    /// reaches, "coming soon" for the rows it does not answer yet.
    func testAnIdentifiedImageReadsInLedgerOrder() throws {
        let a = try analysis([
            "manifest": manifestJSON(),
            "securityVersion": "1",
            "arbSvn": 2,
            "vcn": 7,
            "nvmCompatibility": 2,
            "sku": "Consumer H",
            "manufactureDate": referenceInterval(year: 2018, month: 5, day: 6),
            "mfsState": "initialized",
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: "BA"),
            "chipsetInit": chipsetInitJSON([("CNP/CMP-H", "BA")]),
            "bootPartitions": bootPartitionsJSON(),
            "firmwareSizeBytes": 0x27C000,
            "fwUpdateSupport": "no",
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121,
                        "meMajor": 1, "meMinor": 4, "meHotfix": 0,
                        "meBuild": 14],
        ])
        let rows = tableRows(a)
        XCTAssertEqual(rows.map(\.label), [
            "Family", "Version", "Release", "Type", "SKU", "Chipset",
            "NVM Compatibility",
            "TCB Security Version Number", "ARB Security Version Number",
            "Version Control Number", "Production Ready", "OEM Configuration",
            "FWUpdate Support", "Date", "File System State",
            // Our three rows, between the file system state they are read
            // beside and the size: a CSME 15 image with a manifest that
            // carries none of the three facts answers each of them honestly —
            // a promise for the Manufacturing row, and the two Boot Guard
            // facts as "this image has none".
            "Manufacturing", "Boot Guard", "OEM Public Key Hash", "Size",
            "Flash Image Tool", "Manifest Extension Utility",
        ])
        XCTAssertEqual(value("Manufacturing", in: rows), .comingSoon)
        XCTAssertEqual(value("Boot Guard", in: rows),
                       .value("No profile record in this image"))
        XCTAssertEqual(value("OEM Public Key Hash", in: rows),
                       .value("No key material in this image"))
        XCTAssertEqual(value("NVM Compatibility", in: rows), .value("SPI"))
        XCTAssertEqual(value("Manifest Extension Utility", in: rows),
                       .value("1.4.0.0014"))
        XCTAssertEqual(value("Family", in: rows), .value("CSME"))
        XCTAssertEqual(value("Version", in: rows), .value("15.40.37.3121"))
        XCTAssertEqual(value("Release", in: rows), .value("Production"))
        XCTAssertEqual(value("Type", in: rows), .comingSoon)
        XCTAssertEqual(value("SKU", in: rows), .value("Consumer H"))
        // The pch_init aggregation's "BA" is comma-joined, like the console.
        XCTAssertEqual(value("Chipset", in: rows), .value("CNP/CMP-H B,A"))
        XCTAssertEqual(value("TCB Security Version Number", in: rows), .value("1"))
        XCTAssertEqual(value("ARB Security Version Number", in: rows), .value("2"))
        XCTAssertEqual(value("Version Control Number", in: rows), .value("7"))
        XCTAssertEqual(value("Production Ready", in: rows), .value("Yes"))
        XCTAssertEqual(value("OEM Configuration", in: rows), .comingSoon)
        XCTAssertEqual(value("FWUpdate Support", in: rows), .value("No"))
        XCTAssertEqual(value("Date", in: rows), .value("2018-05-06"))
        XCTAssertEqual(value("File System State", in: rows), .value("Initialized"))
        XCTAssertEqual(value("Size", in: rows),
                       .value("0x27C000 (2605056 bytes)"),
                       "the firmware's own end, not the region it sits in")
        // Row 19 reads the boot BPDT's FIT version (plain CSME format).
        XCTAssertEqual(value("Flash Image Tool", in: rows), .value("12.0.3.1091"))
        // A derived stepping letter was not present, so the row is not there.
        XCTAssertNil(value("Chipset Stepping", in: rows))
    }

    /// Row 4 shows the classifier's Stock / Update / Extracted word when the
    /// type is on that axis; `.region` and `.unknown` keep the row grey.
    func testTypeRowReflectsClassifierAxis() throws {
        func typeRow(_ raw: String) throws -> MEASummaryValue? {
            value("Type", in: tableRows(try analysis([
                "manifest": manifestJSON(),
                "type": raw,
            ])))
        }
        XCTAssertEqual(try typeRow("extracted"), .value("Extracted"))
        XCTAssertEqual(try typeRow("stock"), .value("Stock"))
        XCTAssertEqual(try typeRow("update"), .value("Update"))
        XCTAssertEqual(try typeRow("region"), .comingSoon)
        XCTAssertEqual(try typeRow("unknown"), .comingSoon)
        // An unidentified image gets no Type row at all (the identified gate).
        XCTAssertNil(value("Type", in: tableRows(try analysis(["type": "extracted"]))))
    }

    /// Row 14 answers the OEM detector's Yes/No — but only for the OEM-axis
    /// families; an identified image of another family omits the row entirely.
    func testOEMConfigurationRowSaysYesOrNo() throws {
        let yes = try analysis(["manifest": manifestJSON(), "oemCustomized": true])
        XCTAssertEqual(value("OEM Configuration", in: tableRows(yes)),
                       .value("Yes"))
        let no = try analysis(["manifest": manifestJSON(), "oemCustomized": false])
        XCTAssertEqual(value("OEM Configuration", in: tableRows(no)),
                       .value("No"))
        // A nil detector story (the fixture omits oemCustomized) stays grey.
        let nilCase = try analysis(["manifest": manifestJSON()])
        XCTAssertEqual(value("OEM Configuration", in: tableRows(nilCase)),
                       .comingSoon)
        // ME is not an OEM-axis family: even signed, the row is off the table.
        let me = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(), "oemCustomized": true,
        ])
        XCTAssertNil(value("OEM Configuration", in: tableRows(me)))
    }

    /// Row 19 with a boot BPDT whose header carries no real FIT reads "N/A",
    /// exactly like upstream's BPDT header print.
    func testFlashImageToolRowShowsNAWithoutARealFIT() throws {
        let a = try analysis([
            "manifest": manifestJSON(),
            "bootPartitions": bootPartitionsNoFITJSON(),
        ])
        XCTAssertEqual(value("Flash Image Tool", in: tableRows(a)), .value("N/A"))
    }

    /// Row 19 on a *non-IFWI* image (no boot BPDT) reads the `$FPT` header's
    /// FIT — the value upstream prints from the real-FIT Extracted branch
    /// (`fptHeaderFIT`, MEA.py 12581–12586). The fixture has no
    /// `bootPartitions`, so only the header FIT can feed the row.
    func testFlashImageToolRowReadsNonIFWIFPTHeaderFIT() throws {
        let a = try analysis([
            "manifest": manifestJSON(),
            "fptHeaderFIT": ["major": 11, "minor": 0, "hotfix": 10, "build": 1002],
        ])
        XCTAssertEqual(value("Flash Image Tool", in: tableRows(a)),
                       .value("11.0.10.1002"))
    }

    /// A non-IFWI image without a header FIT — Stock / Update / SPS / ME 2–7,
    /// or a marker-FIT Extracted leg — keeps the row off the table entirely:
    /// upstream never prints row 19 there (no `fitc_ver_found`), unlike the
    /// IFWI "N/A" a decoded-but-FIT-less boot BPDT reads.
    func testFlashImageToolRowAbsentOnNonIFWIWithoutFIT() throws {
        let a = try analysis(["manifest": manifestJSON()])
        XCTAssertNil(value("Flash Image Tool", in: tableRows(a)))
    }

    // MARK: - What is not known yet

    /// An EFS volume with no files read out of it: what a first reading, made
    /// without `FileTable.dat`, hands over.
    private let efsVolumeJSON: [String: Any] = [
        "offset": 0x463000, "pageSize": 0x1000, "systemPageCount": 1,
        "dataPageCount": 14, "scratchPageCount": 1, "scratchPagesEmpty": true,
        "dataPageCountMatchesSystem": true, "dictionary": 0x0B,
        "revision": 1, "unknown1": 2, "dictionaryRevision": 1,
        "dataPagesCommitted": 10, "dataPagesReserved": 4,
        "systemHeaderCRCValid": true, "indexesCRCValid": true,
        "firstIndexPaddingEmpty": true, "dataPageOrder": [],
        "dataPageHeaderCRCsValid": true, "dataPageFooterCRCsValid": true,
    ]

    /// Whether an EFS volume holds files raises the state, and which files
    /// it holds is in `FileTable.dat`: until the reading with it lands, the row
    /// says so rather than giving the state.
    func testFileSystemStateOfAnEFSVolumeWaitsForTheFileTable() throws {
        let a = try analysis(["manifest": manifestJSON(), "mfsState": "configured",
                              "efsVolume": efsVolumeJSON])
        let waiting = MEASummary.build(a, pending: MEAPending(fileTable: true), in: .english)[0].rows
        XCTAssertEqual(value("File System State", in: waiting), .pending)
        XCTAssertEqual(tone("File System State", in: waiting), .standard)
        XCTAssertEqual(value("File System State", in: tableRows(a)), .value("Configured"))
    }

    /// Without an EFS volume the table does not change the state: nothing to
    /// wait for.
    func testFileSystemStateWithoutAnEFSVolumeDoesNotWait() throws {
        let a = try analysis(["manifest": manifestJSON(), "mfsState": "configured"])
        let rows = MEASummary.build(a, pending: MEAPending(fileTable: true), in: .english)[0].rows
        XCTAssertEqual(value("File System State", in: rows), .value("Configured"))
    }

    /// The module checks need `Huffman.dat`: while it is on the way the
    /// messages end with a row that says so, after the ones already known —
    /// and without it there is no such row, nor a block for nothing.
    func testMessagesSayTheModuleChecksAreToCome() throws {
        let a = try analysis(["manifest": manifestJSON()])
        let waiting = MEASummary.build(a, pending: MEAPending(huffman: true), in: .english)
        let messages = try XCTUnwrap(waiting.last)
        XCTAssertEqual(messages.title, "Messages")
        XCTAssertEqual(messages.rows.last, MEASummaryRow("Module checks", .pending))
        XCTAssertFalse(MEASummary.build(a, in: .english).contains { $0.title == "Messages" })

        let raised = try analysis(["manifest": manifestJSON(), "issues": [
            ["id": 1, "severity": "warning", "message": "Something."],
        ]])
        XCTAssertEqual(MEASummary.build(raised, pending: MEAPending(huffman: true), in: .english).last?.rows.map(\.value),
                       [.value("Something."), .pending])
    }

    /// A placeholder is never bold, whatever the row's tone; its words are
    /// the panel's and a copy's alike.
    func testAPendingValueIsNotEmphasized() {
        XCTAssertFalse(MEASummaryRow("File System State", .pending, tone: .good).isEmphasized)
        XCTAssertTrue(MEASummaryRow("File System State", .value("Configured"), tone: .good).isEmphasized)
        XCTAssertEqual(MEASummaryValue.pending.text(in: .english), "Loading…")
        XCTAssertEqual(MEASummaryValue.comingSoon.text(in: .english), "Coming soon")
    }

    /// The File System State row's tone is its status: both settled states read
    /// green, an in-progress volume brown, a failed decode red — every other row
    /// stays standard.
    func testFileSystemStateCarriesItsStatusTone() throws {
        func state(_ raw: String) throws -> [MEASummaryRow] {
            tableRows(try analysis([
                "manifest": manifestJSON(),
                "mfsState": raw,
            ]))
        }
        XCTAssertEqual(value("File System State", in: try state("unconfigured")),
                       .value("Unconfigured"))
        XCTAssertEqual(tone("File System State", in: try state("unconfigured")),
                       .good)
        XCTAssertEqual(value("File System State", in: try state("configured")),
                       .value("Configured"))
        XCTAssertEqual(tone("File System State", in: try state("configured")),
                       .good)
        XCTAssertEqual(value("File System State", in: try state("initialized")),
                       .value("Initialized"))
        XCTAssertEqual(tone("File System State", in: try state("initialized")),
                       .caution)
        XCTAssertEqual(value("File System State", in: try state("error")),
                       .value("Error"))
        XCTAssertEqual(tone("File System State", in: try state("error")), .bad)
        // Rows without a status to say stay standard.
        XCTAssertEqual(tone("Family", in: try state("configured")), .standard)
    }

    /// The Summary states what the File System State rests on in brackets on
    /// its own row — one line, in the same words as Full Info — and a state an
    /// unread EFS left standing is not green. The case is a dump whose EFS
    /// system page was erased: Configured from the FITC alone.
    func testTheStateCarriesWhatItRestsOn() throws {
        var a = try analysis(["manifest": manifestJSON(), "mfsState": "configured"])
        a.mfsStateBasis = MFSStateBasis(reservedFiles: .notRead, efs: .unreadable(offset: 0x267000),
                                        configuration: ["FITC"], decidedBy: .configuration)
        let rows = tableRows(a)
        XCTAssertEqual(value("File System State", in: rows),
                       .verdict("Configured", evidence: "configuration: FITC; EFS: unreadable"))
        XCTAssertEqual(value("File System State", in: rows)?.text(in: .english),
                       "Configured (configuration: FITC; EFS: unreadable)")
        XCTAssertEqual(tone("File System State", in: rows), .caution, "an incomplete state is not green")
        XCTAssertNil(value("State basis", in: rows), "the basis is in the brackets now")

        a.mfsStateBasis = MFSStateBasis(reservedFiles: .notRead, efs: .noFileContent,
                                        configuration: ["FITC"], decidedBy: .configuration)
        let settled = tableRows(a)
        XCTAssertEqual(value("File System State", in: settled),
                       .verdict("Configured", evidence: "configuration: FITC"))
        XCTAssertEqual(tone("File System State", in: settled), .good)
    }

    /// A chipset with no stepping letters is the plain chipset label, and a
    /// derived stepping letter stands on its own row.
    func testChipsetRowsWhenThereAreLettersOrNot() throws {
        let bare = try analysis([
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: ""),
            "chipsetInit": chipsetInitJSON([("CNP/CMP-H", "")]),
        ])
        XCTAssertEqual(value("Chipset", in: tableRows(bare)),
                       .value("CNP/CMP-H"))

        // Every chipset the tables named, one per line: upstream prints the
        // total cell its aggregation appends, not the last row of it.
        let several = try analysis([
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(chipsets: [("SPT/KBP-LP", "C"), ("SPT-H", "BA")]),
            "chipsetInit": chipsetInitJSON([("SPT/KBP-LP", "C"), ("SPT-H", "BA")]),
        ])
        XCTAssertEqual(value("Chipset", in: tableRows(several)),
                       .value("SPT/KBP-LP C\nSPT-H B,A"))

        // No initialisation table, but a recorded stepping: each letter of it
        // is a stepping of its own, as the console reads them.
        let stepped = try analysis([
            "manifest": manifestJSON(),
            "chipsetStepping": "BA",
        ])
        let rows = tableRows(stepped)
        XCTAssertEqual(value("Chipset Stepping", in: rows), .value("B, A"))
        XCTAssertNil(value("Chipset", in: rows))

        // A CSME 15/16 image: the tables came from the FTPR `intl.cfg`, so the
        // MFS volume holds none and the row reads the image's own aggregate.
        let fromFTPR = try analysis([
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(),
            "chipsetInit": chipsetInitJSON([("ADP-LP", "A")]),
        ])
        XCTAssertEqual(value("Chipset", in: tableRows(fromFTPR)),
                       .value("ADP-LP A"))

        // Neither: upstream's own answer for a firmware whose database row
        // says nothing about its chipset.
        let neither = try analysis(["manifest": manifestJSON()])
        XCTAssertEqual(value("Chipset", in: tableRows(neither)), .value("Unknown"))
        XCTAssertNil(value("Chipset Stepping", in: tableRows(neither)))

        // And nothing at all on a file the engine could not name — there is no
        // family to gate the row on.
        let unnamed = try analysis(["chipsetStepping": "B"])
        XCTAssertNil(value("Chipset", in: tableRows(unnamed)))
        XCTAssertNil(value("Chipset Stepping", in: tableRows(unnamed)))

        // A family with no chipset row at all gets neither, promise included:
        // upstream gates the whole pair on a CS/PMC/GSC variant.
        let pchc = try analysis([
            "family": "pchc", "variant": "PCHC",
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: "BA"),
            "chipsetInit": chipsetInitJSON([("CNP/CMP-H", "BA")]),
        ])
        XCTAssertNil(value("Chipset", in: tableRows(pchc)))
        XCTAssertNil(value("Chipset Stepping", in: tableRows(pchc)))
    }

    /// Row 18 is the firmware's own size — where it ends inside whatever
    /// carries it — and falls back to the analysed region's length only when
    /// the engine could not work that out.
    func testSizeRowPrefersTheFirmwaresOwnEnd() throws {
        let known = try analysis(["manifest": manifestJSON(),
                                  "firmwareSizeBytes": 0x27C000])
        XCTAssertEqual(value("Size", in: tableRows(known)),
                       .value("0x27C000 (2605056 bytes)"))

        let unknown = try analysis(["manifest": manifestJSON()])
        XCTAssertEqual(value("Size", in: tableRows(unknown)),
                       .value("0x200000 (2097152 bytes)"),
                       "no firmware end to read, so the row says how much was analysed")
    }

    /// Row 7 names the storage medium the firmware is built for, and only
    /// when the R2 signed-package extension named one: Undefined and a chain
    /// with no R2 extension at all leave the row off the table, exactly as the
    /// console's `nvm_db` gate does.
    func testNVMCompatibilityRowOnlyWhenAMediumIsNamed() throws {
        func nvmRow(_ raw: Int?) throws -> MEASummaryValue? {
            var fields: [String: Any] = ["manifest": manifestJSON()]
            if let raw { fields["nvmCompatibility"] = raw }
            return value("NVM Compatibility", in: tableRows(try analysis(fields)))
        }
        XCTAssertEqual(try nvmRow(1), .value("UFS"))
        XCTAssertEqual(try nvmRow(2), .value("SPI"))
        // Reserved: upstream's own wording for a value outside its map, so a
        // future medium reads as unknown rather than as UFS or SPI.
        XCTAssertEqual(try nvmRow(3), .value("Unknown (3)"))
        XCTAssertNil(try nvmRow(0), "Undefined is the state that prints no row")
        XCTAssertNil(try nvmRow(nil), "and so is an R1-only extension chain")
    }

    /// Row 20 appears only for a manifest actually built by MEU: an R0
    /// manifest carries no MEU block (the fields decode as nil) and the
    /// 0 / 0xFFFF majors are the markers upstream skips the row on.
    func testManifestExtensionUtilityRowOnlyForARealMEUStamp() throws {
        func meuRow(_ major: Int?) throws -> MEASummaryValue? {
            var version: [String: Any] = ["major": 15, "minor": 40,
                                          "hotfix": 37, "build": 3121]
            if let major {
                version["meMajor"] = major
                version["meMinor"] = 4
                version["meHotfix"] = 0
                version["meBuild"] = 14
            }
            return value("Manifest Extension Utility",
                         in: tableRows(try analysis(["manifest": manifestJSON(),
                                                     "version": version])))
        }
        XCTAssertEqual(try meuRow(1), .value("1.4.0.0014"))
        XCTAssertNil(try meuRow(0), "a zero major is the no-MEU marker")
        XCTAssertNil(try meuRow(0xFFFF), "and so is an erased one")
        XCTAssertNil(try meuRow(nil), "an R0 manifest has no MEU block")
    }

    /// Rows 13 and 21 are ME 7's: Patsburg support, and the two downgrade
    /// blacklists — where "Empty" is an answer, not a missing value.
    func testTheME7RowsAreME7s() throws {
        let seven = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(),
            "version": ["major": 7, "minor": 1, "hotfix": 40, "build": 1214],
            "patsburgSupport": true,
            "downgradeBlacklist": ["sevenZero": ["minor": 0, "hotfix": 10,
                                                 "build": 1200]],
        ])
        let rows = tableRows(seven)
        XCTAssertEqual(value("Patsburg Support", in: rows), .value("Yes"))
        XCTAssertEqual(value("Downgrade Blacklist 7.0", in: rows),
                       .value("<= 7.0.10.1200"))
        XCTAssertEqual(value("Downgrade Blacklist 7.1", in: rows), .value("Empty"),
                       "nothing blacklisted on that line, which is what Empty says")

        // An ME 7 image the engine read no `$SKU` from promises the row rather
        // than answering "No".
        let unread = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(),
            "version": ["major": 7, "minor": 1, "hotfix": 40, "build": 1214],
        ])
        XCTAssertEqual(value("Patsburg Support", in: tableRows(unread)), .comingSoon)
        XCTAssertEqual(value("Downgrade Blacklist 7.0", in: tableRows(unread)),
                       .value("Empty"))

        // ME 8 prints none of the three.
        let eight = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(),
            "version": ["major": 8, "minor": 1, "hotfix": 40, "build": 1214],
            "patsburgSupport": true,
        ])
        XCTAssertNil(value("Patsburg Support", in: tableRows(eight)))
        XCTAssertNil(value("Downgrade Blacklist 7.0", in: tableRows(eight)))
    }

    /// Row 22 names the platform when the engine could name one, and is
    /// absent otherwise — the row the console prints only for a firmware whose
    /// chipset it did not learn from an initialisation table.
    func testChipsetSupportRowNamesThePlatformWhenThereIsOne() throws {
        let named = try analysis(["manifest": manifestJSON(),
                                  "platform": "ADP/RPP"])
        let rows = tableRows(named)
        XCTAssertEqual(value("Chipset Support", in: rows), .value("ADP/RPP"))
        XCTAssertEqual(rows.last?.label, "Chipset Support",
                       "and it closes the table, as it does in the console")

        XCTAssertNil(value("Chipset Support",
                           in: tableRows(try analysis(["manifest": manifestJSON()]))))
    }

    /// The security-number rows and the production bit belong to the families
    /// whose firmware carries them: an ME 7 has none of the four, an ME 8 has
    /// the TCB and VCN pair but no anti-rollback number, and a CSME 12 has all
    /// of them — which is exactly the row set the console prints.
    func testTheSecurityRowsFollowTheFamilyAndMajor() throws {
        func labels(family: String, major: Int) throws -> [String] {
            tableRows(try analysis([
                "family": family, "variant": family.uppercased(),
                "manifest": manifestJSON(),
                "securityVersion": "0", "arbSvn": 0, "vcn": 0,
                "version": ["major": major, "minor": 0, "hotfix": 0, "build": 1],
            ])).map(\.label)
        }

        let seven = try labels(family: "me", major: 7)
        XCTAssertFalse(seven.contains("TCB Security Version Number"))
        XCTAssertFalse(seven.contains("ARB Security Version Number"))
        XCTAssertFalse(seven.contains("Version Control Number"))
        XCTAssertFalse(seven.contains("Production Ready"),
                       "an ME 7 carries no production bit at all")

        let eight = try labels(family: "me", major: 8)
        XCTAssertTrue(eight.contains("TCB Security Version Number"))
        XCTAssertTrue(eight.contains("Version Control Number"))
        XCTAssertTrue(eight.contains("Production Ready"))
        XCTAssertFalse(eight.contains("ARB Security Version Number"),
                       "the anti-rollback number arrived with CSME 12")

        let twelve = try labels(family: "csme", major: 12)
        XCTAssertTrue(twelve.contains("TCB Security Version Number"))
        XCTAssertTrue(twelve.contains("ARB Security Version Number"))
        XCTAssertTrue(twelve.contains("Version Control Number"))
        XCTAssertTrue(twelve.contains("Production Ready"))

        // CSME 11 has the pair but not the anti-rollback number either.
        let eleven = try labels(family: "csme", major: 11)
        XCTAssertTrue(eleven.contains("TCB Security Version Number"))
        XCTAssertFalse(eleven.contains("ARB Security Version Number"))
    }

    /// Rows 12a and 12b belong to CSME 11 alone: its Power Down Mitigation as
    /// the database records it, and the Workstation bit of its client
    /// system-information extension. Any other major prints neither.
    func testTheCSME11RowsAreCSME11sAlone() throws {
        let eleven = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 11, "minor": 8, "hotfix": 92, "build": 4222],
            "powerDownMitigation": "no",
            "workstationSupport": false,
        ])
        let rows = tableRows(eleven)
        XCTAssertEqual(value("Power Down Mitigation", in: rows), .value("No"))
        XCTAssertEqual(value("Workstation Support", in: rows), .value("No"))

        // The database's own "does not know" is printed, not hidden.
        let unsure = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 11, "minor": 8, "hotfix": 92, "build": 4222],
            "powerDownMitigation": "unknown2",
        ])
        XCTAssertEqual(value("Power Down Mitigation", in: tableRows(unsure)),
                       .value("Unknown 2"))

        // A silent database is a promise: the `bup` scan upstream falls back
        // to is not ported, so the row must not read "No".
        let silent = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 11, "minor": 8, "hotfix": 92, "build": 4222],
        ])
        XCTAssertEqual(value("Power Down Mitigation", in: tableRows(silent)),
                       .comingSoon)
        XCTAssertEqual(value("Workstation Support", in: tableRows(silent)),
                       .comingSoon)

        // CSME 12 prints neither row, whatever the model happens to carry.
        let twelve = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 12, "minor": 0, "hotfix": 3, "build": 1091],
            "powerDownMitigation": "no",
            "workstationSupport": true,
        ])
        XCTAssertNil(value("Power Down Mitigation", in: tableRows(twelve)))
        XCTAssertNil(value("Workstation Support", in: tableRows(twelve)))
    }

    /// Engineering builds say so on the Release row, like MEA.
    func testEngineeringSuffixOnRelease() throws {
        let a = try analysis([
            "version": ["major": 12, "minor": 0, "hotfix": 3, "build": 7000],
        ])
        XCTAssertEqual(value("Release", in: tableRows(a)),
                       .value("Production, Engineering"))
    }

    // MARK: - What is promised and what is kept off the table

    /// An identified image the engine has few facts for shows the whole road:
    /// every ledger row MEA would print is there, as "coming soon" — never
    /// hidden, and never lied about.
    func testIdentifiedWithoutFactsPromisesEveryPendingRow() throws {
        let a = try analysis([
            "manifest": manifestJSON(productionReady: nil),
        ])
        let rows = tableRows(a)
        let labels = rows.map(\.label)
        XCTAssertTrue(labels.contains("Type"))
        XCTAssertTrue(labels.contains("SKU"))
        XCTAssertTrue(labels.contains("TCB Security Version Number"))
        XCTAssertTrue(labels.contains("ARB Security Version Number"))
        XCTAssertTrue(labels.contains("Version Control Number"))
        XCTAssertTrue(labels.contains("Production Ready"))
        XCTAssertTrue(labels.contains("OEM Configuration"))
        XCTAssertTrue(labels.contains("FWUpdate Support"))
        XCTAssertTrue(labels.contains("Date"))
        XCTAssertTrue(labels.contains("File System State"))
        XCTAssertEqual(value("SKU", in: rows), .comingSoon)
        XCTAssertEqual(value("TCB Security Version Number", in: rows), .comingSoon)
        XCTAssertEqual(value("ARB Security Version Number", in: rows), .comingSoon)
        XCTAssertEqual(value("Version Control Number", in: rows), .comingSoon)
        XCTAssertEqual(value("Production Ready", in: rows), .comingSoon)
        XCTAssertEqual(value("Date", in: rows), .comingSoon)
        XCTAssertEqual(value("File System State", in: rows), .comingSoon)
        // A chipset row there is: with neither an initialisation table nor a
        // recorded stepping it reads "Unknown", which is what the console
        // says. The row whose gate the analysis cannot prove — no IFWI, no
        // real FIT — stays off the table entirely.
        XCTAssertEqual(value("Chipset", in: rows), .value("Unknown"))
        XCTAssertNil(value("Flash Image Tool", in: rows))
        XCTAssertEqual(value("Family", in: rows), .value("CSME"))
        XCTAssertEqual(value("Version", in: rows), .value("15.40.37.3121"))
        XCTAssertEqual(value("Release", in: rows), .value("Production"))
        XCTAssertEqual(value("Size", in: rows),
                       .value("0x200000 (2097152 bytes)"))
    }

    /// An unidentified file — a pure FPT region, say — gets no roadmap of
    /// promised rows: only what the engine could honestly say.
    func testUnidentifiedImageShowsOnlyRealRows() throws {
        let a = try analysis([:])
        let rows = tableRows(a)
        XCTAssertEqual(rows.map(\.label), ["Family", "Version", "Release", "Size"])
        for row in rows {
            guard case .value = row.value else {
                return XCTFail("unidentified row \(row.label) is promised: \(row.value)")
            }
        }
    }

    /// Row 15 says whether Intel's updater can rewrite the image in place —
    /// including upstream's third answer, and nothing at all for a family or
    /// major the console prints no such row for.
    func testFWUpdateSupportRowReadsAllThreeAnswers() throws {
        func row(_ support: String?, major: Int = 12) throws -> MEASummaryValue? {
            var fields: [String: Any] = [
                "manifest": manifestJSON(),
                "version": ["major": major, "minor": 0, "hotfix": 3, "build": 1091],
            ]
            if let support { fields["fwUpdateSupport"] = support }
            return value("FWUpdate Support", in: tableRows(try analysis(fields)))
        }
        XCTAssertEqual(try row("yes"), .value("Yes"))
        XCTAssertEqual(try row("no"), .value("No"))
        XCTAssertEqual(try row("impossible"), .value("Impossible"))
        // An identified CSME 12+ image the engine could not decide for keeps
        // the row grey rather than reading "No".
        XCTAssertEqual(try row(nil), .comingSoon)
        // And CSME 11 has no such row at all.
        XCTAssertNil(try row("no", major: 11))
    }

    // MARK: - The independent firmware's own tables

    /// The console prints a table of its own for every independent firmware
    /// stitched into the image. This is the CSME-12 oracle's Power Management
    /// Controller, row for row and value for value as the original script
    /// prints it.
    func testThePMCBlockReadsAsTheConsolePrintsIt() throws {
        let pmc: [String: Any] = [
            "family": "pmc", "variant": "PMCCNP",
            "version": ["major": 300, "minor": 2, "hotfix": 11, "build": 1012],
            "release": "production", "type": "region",
            "sku": "H", "platform": "CNP", "chipsetStepping": "B",
            "securityVersion": "1", "arbSvn": 1, "vcn": 0,
            "manifest": manifestJSON(productionReady: false),
            "manufactureDate": referenceInterval(year: 2018, month: 3, day: 8),
            "sizeBytes": 0x14000,
            "regions": [], "issues": [],
        ]
        let a = try analysis(["manifest": manifestJSON(),
                              "version": ["major": 12, "minor": 0,
                                          "hotfix": 3, "build": 1091],
                              "independentFirmware": [pmc]])
        let blocks = MEASummary.build(a, in: .english)
        XCTAssertEqual(blocks.count, 2, "the engine's table, then the PMC's")
        let block = blocks[1]
        XCTAssertEqual(block.title, "Power Management Controller")
        XCTAssertEqual(block.rows.map(\.label), [
            "Family", "Version", "Release", "Type", "Chipset SKU",
            "Chipset Stepping", "TCB Security Version Number",
            "ARB Security Version Number", "Version Control Number",
            "Production Ready", "Date", "Size", "Chipset Support",
        ])
        XCTAssertEqual(block.rows.map(\.value), [
            .value("PMC"), .value("300.2.11.1012"), .value("Production"),
            .value("Independent"), .value("H"), .value("B"), .value("1"),
            .value("1"), .value("0"), .value("No"), .value("2018-03-08"),
            .value("0x14000 (81920 bytes)"), .value("CNP"),
        ])
    }

    /// A PCHC has no SKU or stepping row; a PHY's SKU row is labelled just
    /// "SKU"; and both close with their own MEU stamp and chipset.
    func testThePCHCAndPHYBlocksKeepTheirOwnRowSets() throws {
        func firmware(_ family: String, _ variant: String, sku: String,
                      meu: Bool) -> [String: Any] {
            var version: [String: Any] = ["major": 15, "minor": 0,
                                          "hotfix": 0, "build": 1020]
            if meu {
                version["meMajor"] = 15
                version["meMinor"] = 0
                version["meHotfix"] = 30
                version["meBuild"] = 1659
            }
            return [
                "family": family, "variant": variant, "version": version,
                "release": "production", "type": "region",
                "sku": sku, "platform": "TGP",
                "securityVersion": "0", "arbSvn": 0, "vcn": 0,
                "manifest": manifestJSON(),
                "manufactureDate": referenceInterval(year: 2021, month: 3, day: 5),
                "sizeBytes": 0x1000, "regions": [], "issues": [],
            ]
        }
        let a = try analysis([
            "manifest": manifestJSON(),
            "independentFirmware": [
                firmware("pchc", "PCHCTGP", sku: "", meu: true),
                firmware("phy", "PHYNTGP", sku: "N", meu: false),
            ],
        ])
        let blocks = MEASummary.build(a, in: .english)
        XCTAssertEqual(blocks.count, 3)

        XCTAssertEqual(blocks[1].title, "Platform Controller Hub Configuration")
        XCTAssertEqual(blocks[1].rows.map(\.label), [
            "Family", "Version", "Release", "Type",
            "TCB Security Version Number", "ARB Security Version Number",
            "Version Control Number", "Production Ready", "Date", "Size",
            "Manifest Extension Utility", "Chipset Support",
        ])
        XCTAssertEqual(value("Manifest Extension Utility", in: blocks[1].rows),
                       .value("15.0.30.1659"))

        XCTAssertEqual(blocks[2].title, "USB Type C Physical")
        XCTAssertEqual(value("SKU", in: blocks[2].rows), .value("N"))
        XCTAssertNil(value("Chipset SKU", in: blocks[2].rows))
        XCTAssertNil(value("Chipset Stepping", in: blocks[2].rows),
                     "a PHY has no stepping row")
        XCTAssertNil(value("Manifest Extension Utility", in: blocks[2].rows),
                     "and no MEU stamp on this one")
    }

    /// A firmware stored twice is one table that says where the copy is; a
    /// firmware stored once has no such row.
    func testARedundantCopyIsARowNotASecondTable() throws {
        func pmc(copies: [String]?) -> [String: Any] {
            var firmware: [String: Any] = [
                "family": "pmc", "variant": "PMCTGP",
                "version": ["major": 150, "minor": 1, "hotfix": 10, "build": 1048],
                "release": "production", "type": "region",
                "sku": "LP", "platform": "TGP", "chipsetStepping": "B",
                "manifest": manifestJSON(),
                "sizeBytes": 0x40000, "regions": [], "issues": [],
            ]
            if let copies { firmware["redundantCopies"] = copies }
            return firmware
        }
        let twice = MEASummary.build(try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1659],
            "independentFirmware": [pmc(copies: ["Boot 2"])],
        ]), in: .english)
        XCTAssertEqual(twice.count, 2)
        XCTAssertEqual(twice[1].rows.last?.label, "Redundant Copy")
        XCTAssertEqual(value("Redundant Copy", in: twice[1].rows), .value("Boot 2"))

        let once = MEASummary.build(try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1659],
            "independentFirmware": [pmc(copies: nil)],
        ]), in: .english)
        XCTAssertNil(value("Redundant Copy", in: once[1].rows))
    }

    /// A discrete-graphics PMC has neither of the chipset rows, and a PMC
    /// whose stepping letter the engine could not read says so rather than
    /// leaving the row out.
    func testTheChipsetRowsOfAPMCFollowItsPlatform() throws {
        func rows(platform: String, stepping: String?,
                  hostMajor: Int = 12) throws -> [MEASummaryRow] {
            var pmc: [String: Any] = [
                "family": "pmc", "variant": "PMCDG2",
                "version": ["major": 4, "minor": 2, "hotfix": 0, "build": 1000],
                "release": "production", "type": "region",
                "sku": "H", "platform": platform,
                "manifest": manifestJSON(),
                "manufactureDate": referenceInterval(year: 2021, month: 3, day: 5),
                "sizeBytes": 0x1000, "regions": [], "issues": [],
            ]
            if let stepping { pmc["chipsetStepping"] = stepping }
            return MEASummary.build(try analysis([
                "manifest": manifestJSON(),
                "version": ["major": hostMajor, "minor": 0,
                            "hotfix": 3, "build": 1091],
                "independentFirmware": [pmc],
            ]), in: .english)[1].rows
        }

        // A discrete-graphics PMC has no stepping row at all — but a CSME 12
        // or newer host prints the SKU row regardless of the platform, which
        // is upstream's own first leg of that gate.
        let discrete = try rows(platform: "DG2", stepping: "A")
        XCTAssertNil(value("Chipset Stepping", in: discrete))
        XCTAssertEqual(value("Chipset SKU", in: discrete), .value("H"))

        // Under an older host the platform decides, and a DG one has a single
        // chipset to say nothing about.
        let olderHost = try rows(platform: "DG2", stepping: "A", hostMajor: 11)
        XCTAssertNil(value("Chipset SKU", in: olderHost))
        XCTAssertNil(value("Chipset Stepping", in: olderHost))

        let unread = try rows(platform: "TGP", stepping: nil)
        XCTAssertEqual(value("Chipset Stepping", in: unread), .value("Unknown"))
        XCTAssertEqual(value("Chipset SKU", in: unread), .value("H"))
    }

    // MARK: - Our three rows (End of Manufacturing, Boot Guard, OEM key hash)

    /// The RPMC row: whether the platform binds its SPI part to the chipset —
    /// one byte the tool keeps in `bup_sku/hw_binding`, which its own help
    /// names the FPF hardware and RPMC / RPMB binding. Read for the
    /// generations whose tool has the setting, and saying so where the image
    /// does not carry the file.
    func testTheRPMCBindingIsARow() throws {
        func rows(_ binding: HardwareBinding?, major: Int) throws -> [MEASummaryRow] {
            var a = try analysis([
                "family": "csme", "manifest": manifestJSON(),
                "version": ["major": major, "minor": 0, "hotfix": 1, "build": 100],
            ])
            a.hardwareBinding = binding
            return tableRows(a)
        }
        XCTAssertEqual(value("RPMC", in: try rows(.enabled, major: 15)),
                       .value("Hardware binding: Enabled"))
        XCTAssertEqual(value("RPMC", in: try rows(.disabled, major: 15)),
                       .value("Hardware binding: Disabled"))
        XCTAssertEqual(value("RPMC", in: try rows(.other(0x02), major: 16)),
                       .value("Hardware binding: unexpected value 0x02"))
        XCTAssertEqual(value("RPMC", in: try rows(.notInImage, major: 16)),
                       .value("Not recorded in this image"))
        // A reading, not a verdict: the row carries no tone either way.
        XCTAssertEqual(tone("RPMC", in: try rows(.enabled, major: 15)), .standard)
        // CSME 12 has no such setting: no row, rather than one that can only
        // say the image does not carry it.
        XCTAssertNil(value("RPMC", in: try rows(.notInImage, major: 12)))
        XCTAssertNil(value("RPMC", in: try rows(nil, major: 15)))
    }


    /// The four dumps whose answers are known, as the rows read them: the
    /// factory dump that closed Manufacturing already, the same image built
    /// with MFIT's flag set, the one built without it, and the pair of Boot
    /// Guard facts under them.
    func testTheBenchRowsReadTheFourKnownDumps() throws {
        let protected = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 16, "minor": 1, "hotfix": 25, "build": 1991],
            "manufacturingState": "willClose",
            "manufacturingBasis": ["flag": true, "flexible": 0,
                                   "page": "imageConfiguration",
                                   "descriptorOpen": false,
                                   "liveFilesResolved": true],
            "bootGuardProfile": "5",
        ])
        var protectedKey = protected
        protectedKey.oemPublicKeyHash = .hash(String(repeating: "05", count: 48))
        let rows = tableRows(protectedKey)
        XCTAssertEqual(value("Manufacturing", in: rows),
                       .verdict("Will close on the EOM flag",
                                evidence: "EOM: on, descriptor: locked"))
        // It will close: the tone the File System State draws for Initialized.
        XCTAssertEqual(tone("Manufacturing", in: rows), .caution)
        XCTAssertEqual(value("Boot Guard", in: rows), .value("5 - FVME"))
        // The row carries no tone: a profile is a number the image holds, not a
        // state the platform is in.
        XCTAssertEqual(tone("Boot Guard", in: rows), .standard)
        XCTAssertEqual(value("OEM Public Key Hash", in: rows),
                       .value(Array(repeating: "05", count: 48).joined(separator: " ")))
        // One line for a copy: the verdict, then what it was read from in
        // brackets — and only the verdict is emphasised.
        XCTAssertEqual(value("Manufacturing", in: rows)?.text(in: .english),
                       "Will close on the EOM flag (EOM: on, descriptor: locked)")
        XCTAssertTrue(rows.first { $0.label == "Manufacturing" }?.isEmphasized == true)
        XCTAssertNil(value("Flexible EOM Settings", in: rows))
        XCTAssertEqual(protected.manufacturingBasis?.flexible, 0)
        XCTAssertNil(value("Manufacturing basis", in: rows))

        let willClose = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 16, "minor": 1, "hotfix": 25, "build": 1991],
            "manufacturingState": "willClose",
            "manufacturingBasis": ["flag": true, "flexible": 0,
                                   "page": "imageConfiguration",
                                   "descriptorOpen": false,
                                   "liveFilesResolved": false],
            "bootGuardProfile": "0",
        ])
        XCTAssertEqual(value("Manufacturing", in: tableRows(willClose)),
                       .verdict("Will close on the EOM flag",
                                evidence: "EOM: on, descriptor: locked"))
        XCTAssertEqual(tone("Manufacturing", in: tableRows(willClose)), .caution)
        // Profile 0 and profile 5 read alike: the row is the image's setting,
        // not a verdict about the board.
        XCTAssertEqual(tone("Boot Guard", in: tableRows(willClose)), .standard)

        let willNotClose = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 16, "minor": 1, "hotfix": 25, "build": 1991],
            "manufacturingState": "willNotClose",
            "manufacturingBasis": ["flag": false, "flexible": 0,
                                   "page": "imageConfiguration",
                                   "descriptorOpen": true,
                                   "liveFilesResolved": false],
        ])
        XCTAssertEqual(value("Manufacturing", in: tableRows(willNotClose)),
                       .verdict("Will not close",
                                evidence: "EOM: off, descriptor: open"))
        XCTAssertEqual(value("Manufacturing", in: tableRows(willNotClose))?.text(in: .english),
                       "Will not close (EOM: off, descriptor: open)")
        XCTAssertEqual(tone("Manufacturing", in: tableRows(willNotClose)), .good)
    }

    /// The three rows belong to CSME 11 and later. Manufacturing is decided
    /// there by the descriptor's access rights — which is how it was done
    /// before MFIT grew the flag, and CSME 12 is such a generation: it reads a
    /// verdict of its own, not `noSwitch`.
    func testTheBenchRowsBelongToCSME11AndLater() throws {
        var a = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 12, "minor": 0, "hotfix": 3, "build": 1091],
            "manufacturingState": "willClose",
            "manufacturingBasis": ["descriptorOpen": false,
                                   "liveFilesResolved": false],
            "bootGuardProfile": "4",
        ])
        a.oemPublicKeyHash = .allZeros
        let rows = tableRows(a)
        XCTAssertEqual(value("Manufacturing", in: rows),
                       .verdict("Will close on the descriptor's rights",
                                evidence: "descriptor: locked"))
        XCTAssertEqual(tone("Manufacturing", in: rows), .caution)
        // No flag in this image, so the evidence names the descriptor alone.
        XCTAssertEqual(value("Manufacturing", in: rows)?.text(in: .english),
                       "Will close on the descriptor's rights (descriptor: locked)")
        XCTAssertNil(a.manufacturingBasis?.flexible)
        XCTAssertEqual(value("Boot Guard", in: rows), .value("4 - FVE"))
        XCTAssertEqual(tone("Boot Guard", in: rows), .standard)
        // CSME 12 with a zeroed key field: a finding of its own, not silence.
        XCTAssertEqual(value("OEM Public Key Hash", in: rows), .value("Not set (all zeros)"))

        // ME 7 has none of this machinery.
        let me7 = try analysis([
            "family": "me", "manifest": manifestJSON(),
            "version": ["major": 7, "minor": 1, "hotfix": 70, "build": 2264],
            "manufacturingState": "noSwitch",
        ])
        XCTAssertNil(value("Manufacturing", in: tableRows(me7)))
    }

    // MARK: - The Configuration tab

    /// The tab's blocks: one per configuration file, MFIT's own words for the
    /// file and for the values it enumerates, both copies of a file read side
    /// by side, and no tab at all where the image's generation has no map — a
    /// generation nobody has mapped reads nothing rather than another
    /// generation's offsets.
    func testTheConfigurationTabReadsBothCopiesOfAFileSettingBySetting() throws {
        var a = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 16, "minor": 1, "hotfix": 25, "build": 1991],
        ])
        a.configuration = [
            ConfigurationFile(
                path: "/home/mca/eom_config", alias: "EOM_Config",
                fitc: .init(size: 2, settings: [
                    ConfigurationSetting(name: "EomFirstBootEnabled", number: 0),
                    ConfigurationSetting(name: "FlexibleEomSettings", number: 0),
                ]),
                mfs: .init(size: 2, settings: [
                    ConfigurationSetting(name: "EomFirstBootEnabled", number: 0),
                    ConfigurationSetting(name: "FlexibleEomSettings", number: 2),
                ])),
        ]
        let blocks = MEAConfiguration.build(a, in: .english)
        XCTAssertEqual(blocks.count, 1)
        // The heading is two parts: Intel's own name for the file, which the
        // tab draws bold, and the path without its `/home` with the length.
        XCTAssertEqual(blocks[0].alias, "EOM_Config")
        XCTAssertEqual(blocks[0].detail, "/mca/eom_config, 2 bytes")
        // The row reads as the tool's panel does: its own name for the setting
        // where it states one, the identifier where it shows that instead.
        XCTAssertEqual(blocks[0].rows.map(\.name),
                       ["EOM on First Boot Enabled", "Flexible EOM setting options"])
        // Each row carries the build's value and the file system's, and the
        // pair that disagrees is the one the view marks.
        // MFIT's own words for the flag, which its database calls a Yes/No
        // setting rather than a bit that reads 0 or 1.
        XCTAssertEqual(blocks[0].rows.map(\.fitc), ["No", "Lock Descriptor and OEM Configs"])
        XCTAssertEqual(blocks[0].rows.map(\.mfs), ["No", "Lock Descriptor Only"])
        XCTAssertEqual(blocks[0].rows.map(\.differs), [false, true])

        // A copy that is not there at all is an absent value, not a
        // disagreement: an image nobody has booted has one column and no
        // argument — and the tab still shows the setting.
        var unbooted = a
        unbooted.configuration = [
            ConfigurationFile(path: "/home/mca/eom_config", alias: "EOM_Config",
                              fitc: a.configuration?[0].fitc),
        ]
        let unbootedRows = MEAConfiguration.build(unbooted, in: .english)[0].rows
        XCTAssertEqual(unbootedRows.map(\.mfs), [nil, nil])
        XCTAssertEqual(unbootedRows.map(\.differs), [false, false])
        XCTAssertEqual(unbootedRows.map(\.fitc), ["No", "Lock Descriptor and OEM Configs"])

        // A generation whose map has not been emitted yet reads nothing rather
        // than a guess, even with the same files in hand.
        var unmapped = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 18, "minor": 0, "hotfix": 10, "build": 2285],
        ])
        unmapped.configuration = a.configuration
        XCTAssertTrue(MEAConfiguration.build(unmapped, in: .english).isEmpty)

        // A setting the map does not list has only its identifier to show: the
        // tool's own words for a setting are the map's, and where there is no
        // map entry there is nothing to borrow them from. The map's own order
        // holds, so the unknown one comes last and the setting the copy has not
        // got is still a row — with an absent value rather than a zero.
        var unknown = a
        unknown.configuration = [
            ConfigurationFile(path: "/home/mca/eom_config", alias: "EOM_Config",
                              mfs: .init(size: 2, settings: [
                                  ConfigurationSetting(name: "EomFirstBootEnabled", number: 1),
                                  ConfigurationSetting(name: "NotInTheMap", number: 1),
                              ])),
        ]
        let unknownRows = MEAConfiguration.build(unknown, in: .english)[0].rows
        XCTAssertEqual(unknownRows.map(\.name),
                       ["EOM on First Boot Enabled", "Flexible EOM setting options",
                        "NotInTheMap"])
        XCTAssertEqual(unknownRows.map(\.mfs), ["Yes", nil, "1"])
    }

    /// A setting the tool places conditionally carries what placed it, after
    /// its name — and says so when the branch had to be told from the files the
    /// image carries. A setting the tool switches off carries that too, and its
    /// values are drawn quiet.
    func testAConditionalSettingCarriesItsConditionInTheRow() throws {
        var a = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 15, "minor": 0, "hotfix": 1, "build": 100],
        ])
        a.configuration = [
            ConfigurationFile(path: "/home/mctp/smt2_devices", alias: "Smt2Devices",
                              mfs: .init(size: 6, settings: [
                                  ConfigurationSetting(
                                      name: "MctpEcAddress", number: 0,
                                      condition: ConfigurationCondition(name: "eSpiEnabled",
                                                                        value: 0, assumed: true)),
                              ])),
            ConfigurationFile(path: "/home/smbus/smlink_bus", alias: "SmlinkBus",
                              mfs: .init(size: 1, settings: [
                                  ConfigurationSetting(
                                      name: "SmlinkBusSelection", number: 0,
                                      disabled: ConfigurationCondition(name: "eSpiEnabled", value: 1)),
                              ])),
        ]
        let rows = MEAConfiguration.build(a, in: .english).flatMap(\.rows)

        let address = try XCTUnwrap(rows.first { $0.identifier == "MctpEcAddress" })
        XCTAssertEqual(address.name, "MCTP EC Address · eSpiEnabled = No, assumed",
                       "the tool's identifier and its own word for the value")
        XCTAssertEqual(address.condition, ConfigurationCondition(name: "eSpiEnabled",
                                                                 value: 0, assumed: true))
        XCTAssertEqual(address.disabled, false)

        let bus = try XCTUnwrap(rows.first { $0.identifier == "SmlinkBusSelection" })
        XCTAssertEqual(bus.name, "Bus Selection · disabled by eSpiEnabled = Yes")
        XCTAssertEqual(bus.disabled, true, "which is what the panel draws quiet")
        XCTAssertNil(bus.condition)
    }

    /// The tab reads the board's own half of the generation's map: a file the
    /// mobile map lays out and the desktop one does not is labelled from the
    /// mobile map and reaches the desktop tab by its identifier alone — the
    /// same map the engine read the values through.
    func testTheConfigurationTabReadsTheBoardsOwnHalfOfTheMap() throws {
        func rows(_ family: MEConfigurationMap.MEPlatformFamily?) throws -> [MEAConfigurationRow] {
            var a = try analysis([
                "family": "csme", "manifest": manifestJSON(),
                "version": ["major": 15, "minor": 0, "hotfix": 1, "build": 100],
            ])
            a.platformFamily = family
            a.configuration = [
                ConfigurationFile(path: "/home/smbus/smlink_bus", alias: "SmlinkBus",
                                  mfs: .init(size: 1, settings: [
                                      ConfigurationSetting(name: "SmlinkBusSelection", number: 1),
                                  ])),
            ]
            return MEAConfiguration.build(a, in: .english)[0].rows
        }

        XCTAssertEqual(try rows(.mobile).map(\.name), ["Bus Selection"])
        XCTAssertEqual(try rows(.desktop).map(\.name), ["SmlinkBusSelection"],
                       "the desktop map does not lay this file out: the identifier is all there is")
        XCTAssertEqual(try rows(nil).map(\.name), ["Bus Selection"],
                       "a dump that did not say which half reads as the mobile one")
    }

    /// A row carries what the tool says about its setting, under the
    /// identifier the row itself does not show — the heading of the `?` beside
    /// the name. A setting the map does not list, or one MFIT has nothing to
    /// say about, has neither.
    func testARowCarriesTheToolsHelpAndTheIdentifier() throws {
        var a = try analysis([
            "family": "csme", "manifest": manifestJSON(),
            "version": ["major": 16, "minor": 1, "hotfix": 25, "build": 1991],
        ])
        a.configuration = [
            ConfigurationFile(path: "/home/mca/eom_config", alias: "EOM_Config",
                              mfs: .init(size: 2, settings: [
                                  ConfigurationSetting(name: "EomFirstBootEnabled", number: 1),
                                  ConfigurationSetting(name: "NotInTheMap", number: 1),
                              ])),
        ]

        let rows = MEAConfiguration.build(a, in: .english)[0].rows
        let flag = try XCTUnwrap(rows.first { $0.name == "EOM on First Boot Enabled" })

        XCTAssertEqual(flag.identifier, "EomFirstBootEnabled",
                       "the name a document or a report calls the setting by")
        XCTAssertEqual(flag.help?.hasPrefix("This setting det"), true, flag.help ?? "—")
        XCTAssertEqual(flag.help?.contains("\nNote:"), true,
                       "the tool's paragraph break, as the line it is")
        for row in rows where row.help != nil {
            XCTAssertFalse(row.help?.contains("<br") ?? true, row.identifier)
        }
    }

    // MARK: - The messages block

    func testIssuesBecomeAMessagesBlockAfterTheTable() throws {
        let a = try analysis([
            "issues": [["id": 1, "severity": "error", "message": "checksum mismatch"],
                       ["id": 2, "severity": "note", "message": "odd padding"]],
        ])
        let blocks = MEASummary.build(a, in: .english)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNil(blocks[0].title)
        XCTAssertEqual(blocks[1].title, "Messages")
        XCTAssertEqual(blocks[1].rows.map(\.label), ["Error", "Note"])
        XCTAssertEqual(blocks[1].rows.map(\.value),
                       [.value("checksum mismatch"), .value("odd padding")])
    }

    func testNoIssuesNoMessagesBlock() throws {
        let a = try analysis([:])
        XCTAssertEqual(MEASummary.build(a, in: .english).count, 1)
    }
}
