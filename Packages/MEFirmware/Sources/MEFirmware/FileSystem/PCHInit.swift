import Foundation

/// Chipset Initialization Table decode of an Intel Configuration stream,
/// upstream `mphytbl` (MEA.py 8956) + `pch_init_anl` (MEA.py 9097).
///
/// The stream is a list of *file* records over one blob of bytes: each record
/// says where its file's content sits inside that same blob, exactly as
/// upstream slices `buffer[rec_offset:rec_offset+rec_size]`. A record named
/// `mphytbl*` is a chipset init table — its first bytes name the chipset
/// platform, a stepping nibble and an init table revision. Which stepping rule
/// decodes the nibble is chosen by the engine identity (`variant`/`major`/
/// `minor`/`build`) and the manifest date, so this decode runs only after
/// identification. `pch_dict` (MEA.py 10839) and the `pch_stp_val` letter table
/// are compile-time constants.
///
/// Three streams carry one, and upstream reads all three through the same
/// `mfs_cfg_anl`:
///
/// * the MFS volume's low-level file 6 in the **named** 0x1C layout (CSME
///   11/12 and their analogues), whose records spell the file name themselves;
/// * the same file 6 in the **ID-keyed** 0xC layout (CSME 13–16), whose
///   records carry a File ID and are named by the `FTBL` row `FileTable.dat`
///   keys under it;
/// * the FTPR `$CPD` module **`intl.cfg`**, which is file 6 kept as a module.
///
/// The third one *wins*: upstream prefers the FTPR copy over the MFS one "when
/// possible (i.e. MFS & FTPR) or necessary (i.e. FTPR only, MFS empty)" and
/// overwrites `pch_init_final` with whatever it yields, empty included (MEA.py
/// 5999–6009). That is the only source a CSME 15/16 image has: its FTBL volume
/// carries no file 6 at all, which is why those images read no chipset until
/// `intl.cfg` is read.
enum PCHInitDecoder {

    /// `pch_dict`, MEA.py 10839–10856: chipset-ID byte/nibble → platform label.
    static let platformLabels: [Int: String] = [
        0x0: "LBG-H", 0x3: "ICP-LP", 0x4: "ICP-N", 0x5: "ICP-H",
        0x6: "TGP-LP", 0x7: "TGP/EBG-H", 0x8: "SPT/KBP-LP", 0x9: "SPT-H",
        0xB: "KBP/BSF/GCF-H", 0xC: "CNP/CMP-LP", 0xD: "CNP/CMP-H",
        0xE: "LKF-LP", 0xF: "MCC-LP", 0x10: "JSP-N", 0x11: "EBG-H",
        0x12: "ADP-LP",
    ]

    /// `pch_stp_val`, MEA.py 8957: stepping nibble 0–15 → letter A–P.
    private static let steppingLetters = Array("ABCDEFGHIJKLMNOP").map(String.init)

    /// One configuration record reduced to what the chipset scan needs: what
    /// the file is called, and where its bytes sit in the stream carrying it.
    struct NamedRecord {
        var name: String
        var offset: Int
        var size: Int
    }

    /// The **named** (0x1C) Intel Configuration of an MFS volume: low-level
    /// file 6 and the records the volume decode already read out of it.
    /// Returns nil when the volume carries no file 6, no configuration owned by
    /// it, or no `mphytbl*` record in it (upstream's `pch_init_info` stays empty
    /// and mphytbl never fires).
    static func decode(files: [MFSLowLevelFile],
                       configurations: [MFSConfigDecode],
                       variant: String, major: Int, minor: Int, build: Int,
                       year: Int, month: Int, day: Int) -> MFSPCHInit? {
        guard let intel = files.first(where: { $0.index == 6 }),
              let config = configurations.first(where: { $0.owningFile == 6 })
        else { return nil }
        let records = config.records
            .filter { !$0.isFolder }
            .map { NamedRecord(name: $0.name, offset: $0.offset, size: $0.size) }
        return decode(stream: intel.content, records: records,
                      variant: variant, major: major, minor: minor, build: build,
                      year: year, month: month, day: day)
    }

    /// The **ID-keyed** (0xC) Intel Configuration of an MFS volume: the same
    /// low-level file 6, whose records name nothing themselves — the `FTBL`
    /// row `FileTable.dat` keys under each record's File ID does (upstream
    /// `mfs_cfg_anl`'s 0xC branch, MEA.py 8546). Without a table no record can
    /// be recognised as a chipset table, and the answer is nil rather than a
    /// guess.
    static func decode(files: [MFSLowLevelFile],
                       configurationsByID: [MFSConfigIDDecode],
                       fileTable: FileTable?, platform: Int, dictionary: Int,
                       variant: String, major: Int, minor: Int, build: Int,
                       year: Int, month: Int, day: Int) -> MFSPCHInit? {
        guard let intel = files.first(where: { $0.index == 6 }),
              let config = configurationsByID.first(where: { $0.owningFile == 6 })
        else { return nil }
        return decode(stream: intel.content,
                      records: named(config.records, fileTable: fileTable,
                                     platform: platform, dictionary: dictionary),
                      variant: variant, major: major, minor: minor, build: build,
                      year: year, month: month, day: day)
    }

    /// An Intel Configuration read straight off its own bytes — the FTPR
    /// `$CPD` module `intl.cfg`, which upstream hands to `mfs_cfg_anl` exactly
    /// as it hands it a volume's file 6 (MEA.py 6008). `recordSize` is the
    /// identity's own `get_cfg_rec_size`; the 0xC layout needs the file table
    /// to name its records, the 0x1C one does not.
    static func decode(intelConfiguration stream: Data, recordSize: Int,
                       fileTable: FileTable?, platform: Int, dictionary: Int,
                       variant: String, major: Int, minor: Int, build: Int,
                       year: Int, month: Int, day: Int) -> MFSPCHInit? {
        let records: [NamedRecord]
        if recordSize == 0x1C {
            records = (MFSParser.decodeConfigRecords(stream) ?? [])
                .filter { !$0.isFolder }
                .map { NamedRecord(name: $0.name, offset: $0.offset, size: $0.size) }
        } else {
            records = named(MFSParser.decodeConfigIDRecords(stream) ?? [],
                            fileTable: fileTable,
                            platform: platform, dictionary: dictionary)
        }
        return decode(stream: stream, records: records,
                      variant: variant, major: major, minor: minor, build: build,
                      year: year, month: month, day: day)
    }

    /// What `FileTable.dat` calls each ID-keyed record's file, as the *base
    /// name* upstream tests (`rec_name = os.path.basename(rec_file)`, MEA.py
    /// 8552). A record the table has no row for reads as upstream's own
    /// `/Unknown/<ID>.bin` fallback, which no chipset table is ever called.
    private static func named(_ records: [MFSRawConfigIDRecord],
                              fileTable: FileTable?,
                              platform: Int, dictionary: Int) -> [NamedRecord] {
        records.map { record in
            let path = fileTable?.record(withFileID: record.fileID,
                                         platform: platform,
                                         dictionary: dictionary)?.path
            let name = path.map { String($0.split(separator: "/").last ?? "") }
                ?? String(format: "%08X.bin", record.fileID)
            return NamedRecord(name: name, offset: record.offset, size: record.size)
        }
    }

    /// One configuration stream → the Chipset Initialization Table facts.
    /// Returns nil when nothing in it is an `mphytbl*` file with bytes behind
    /// it: upstream's `pch_init_info` then stays empty and `pch_init_anl`
    /// returns its empty list.
    private static func decode(stream: Data, records: [NamedRecord],
                               variant: String, major: Int, minor: Int, build: Int,
                               year: Int, month: Int, day: Int) -> MFSPCHInit? {
        var decoded: [MFSPCHInitRecord] = []
        for record in records {
            guard record.name.hasPrefix("mphytbl"),
                  record.size > 0, record.offset >= 0,
                  record.offset + record.size <= stream.count
            else { continue }
            let table = stream.subdata(in: record.offset..<(record.offset + record.size))
            guard let table = Self.decodeTable(table, variant: variant,
                                               major: major, minor: minor,
                                               build: build, year: year,
                                               month: month, day: day)
            else { continue }
            decoded.append(table)
        }
        guard !decoded.isEmpty else { return nil }

        return MFSPCHInit(records: decoded, chipsets: Self.aggregate(decoded))
    }

    /// One mphytbl* table → its chipset platform, stepping letters and init
    /// table revision (upstream `mphytbl` MEA.py 8956–9024). Returns nil when
    /// the blob is too short to hold the layout marker and stepping nibble.
    static func decodeTable(_ data: Data, variant: String, major: Int,
                            minor: Int, build: Int, year: Int, month: Int,
                            day: Int) -> MFSPCHInitRecord? {
        // New layout marker: bytes [4:6] both 0xFF (rec_data[0x4:0x6] == FF*2).
        let newLayout = data.count >= 6 && data[4] == 0xFF && data[5] == 0xFF

        // Chipset ID byte/nibble → platform; stepping nibble; table revision.
        let chipsetID: Int
        let rawStep: Int
        let revision: Int
        if newLayout {
            guard data.count >= 9 else { return nil }
            chipsetID = Int(data[7])
            rawStep = Int(data[8]) >> 4
            revision = Int(data[6])
        } else {
            guard data.count >= 4 else { return nil }
            chipsetID = Int(data[3]) >> 4
            rawStep = Int(data[3]) & 0xF
            revision = Int(data[2])
        }

        var chipset = platformLabels[chipsetID] ?? "Unknown"
        var stepping = ""

        // Detect Actual Chipset Stepping(s) — upstream elif order preserved
        // (MEA.py 8969–9021). Absolute letters decode `pch_stp_val[raw]`; the
        // bitfield spells set high→low bits as D,C,B,A (0000 → "A").
        if (variant, major, minor) == ("CSSPS", 4, 4) {
            stepping = Self.absolute(rawStep)
            chipset = "WTL"                       // LBG-H → LBG-R rename
        } else if (variant, major) == ("CSME", 11) || (variant, major) == ("CSSPS", 4) {
            if Self.date(year, month, day) >= Self.date(2015, 5, 19) {
                stepping = Self.absolute(rawStep) // ≥ 11.0.0.1140 @ 2015-05-19
            }
            // else unreliable (always 80 → SPT/KBP-LP A): stays empty
        } else if (variant, major) == ("CSME", 12) || (variant, major) == ("CSSPS", 5) {
            if Self.date(year, month, day) >= Self.date(2018, 1, 25) {
                stepping = Self.bitfield(rawStep) // ≥ 12.0.0.1058 @ 2018-01-25
            } else {
                stepping = Self.absolute(rawStep)
            }
        } else if (variant, major, minor) == ("CSME", 15, 40) {
            if (1000..<7000).contains(build) {
                stepping = Self.steppingLetters[(build / 1000) - 1]
            } else {
                stepping = Self.absolute(rawStep) // fallback
            }
        } else if (variant, major) == ("CSME", 13) || (variant, major) == ("CSME", 15)
                    || (variant, major) == ("CSME", 16) || (variant, major) == ("CSSPS", 6) {
            stepping = newLayout ? Self.absolute(rawStep) : Self.bitfield(rawStep)
        } else if (variant, major, minor) == ("CSME", 14, 5) {
            stepping = Self.absolute(rawStep)
            chipset = "CMP-V"                     // KBP/BSF/GCF-H rename
        } else if (variant, major) == ("CSME", 14) {
            stepping = Self.bitfield(rawStep)
        }

        return MFSPCHInitRecord(chipset: chipset, stepping: stepping,
                                revision: revision)
    }

    /// `pch_init_anl` (MEA.py 9097–9131), minus the trailing display-only total
    /// cell: dedupe chipsets in first-appearance order, concatenate each
    /// chipset's stepping letters across its tables, then sort unique letters
    /// in reverse (e.g. "A"+"CB" → "CBA"). Empty when no table decoded a
    /// stepping (upstream's early return on an empty first row).
    static func aggregate(_ records: [MFSPCHInitRecord]) -> [MFSPCHInitChipset] {
        guard let first = records.first, !first.stepping.isEmpty else { return [] }
        var chipsets: [MFSPCHInitChipset] = []
        var lettersByChipset: [String: String] = [:]
        for record in records {
            if lettersByChipset[record.chipset] == nil {
                chipsets.append(MFSPCHInitChipset(chipset: record.chipset, steppings: ""))
            }
            lettersByChipset[record.chipset, default: ""] += record.stepping
        }
        for index in chipsets.indices {
            let all = lettersByChipset[chipsets[index].chipset] ?? ""
            chipsets[index] = MFSPCHInitChipset(
                chipset: chipsets[index].chipset,
                steppings: String(Set(all).sorted(by: >)))
        }
        return chipsets
    }

    // MARK: - stepping helpers

    private static func absolute(_ rawStep: Int) -> String {
        steppingLetters[rawStep & 0xF]
    }

    private static func bitfield(_ rawStep: Int) -> String {
        var result = ""
        for i in 0..<4 where rawStep & (1 << (3 - i)) != 0 {
            result.append("DCBA"[String.Index(utf16Offset: i, in: "DCBA")])
        }
        return result.isEmpty ? "A" : result
    }

    /// An absolute calendar date as a comparable value (day/month/year are
    /// already decimal BCD-decoded calendar ints; a plain tuple comparison is
    /// chronological, matching upstream's BCD-byte comparison of the header).
    private static func date(_ year: Int, _ month: Int, _ day: Int) -> (Int, Int, Int) {
        (year, month, day)
    }
}
