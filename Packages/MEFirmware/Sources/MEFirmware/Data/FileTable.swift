import Foundation

/// Parsed `FileTable.dat`: the table that gives an MFS/AFS volume's low-level
/// files their names.
///
/// An FTBL-mode volume (CSME 15/16 — `MFSVolume.usesFTBL`) carries no names in
/// its bytes at all. Its FAT chains are numbered, and the number is the only
/// thing the flash says about a file; the *name* lives in this upstream JSON,
/// keyed by the volume header's own FTBL **platform** and **dictionary** —
/// both of which the volume decode already reads. So a name here is a DB
/// answer to a byte question, which is why it is a lookup the panel makes and
/// never a field of `FirmwareAnalysis` (reference/result-model.md).
///
/// The shape, as upstream writes it (`mfs_home13_anl`, MEA.py 8303):
///
/// ```json
/// { "04": { "0A": { "FTBL": { "10003500": "/home/mca/manuf_ver,1,0,0,40,0,70,63,448" },
///                   "EFST": { "00003004": "3,76,548,5,0,BUP_MBP" } } } }
/// ```
///
/// — platform → dictionary → table → file ID → one comma-joined record. The
/// `FTBL` record is `path,integrity,encryption,antiReplay,accessUnknown,
/// groupID,userID,vfsID,unknown`, and **`vfsID` is the low-level file index**
/// the MFS walk assembles (`MFSLowLevelFile.index`), which is the whole join.
///
/// The records are kept as written and parsed on demand for the one platform
/// and dictionary a volume asks about. The file holds ~67 000 records across
/// 70 tables and a volume reads one of them: eagerly typing all of it would be
/// work for a thousand names nobody asked for.
public struct FileTable: Sendable, Equatable {
    /// One `FTBL` record: a file's name and the flags that go with it.
    public struct Entry: Sendable, Equatable {
        /// The record's key in the table, as written — upstream prints it as
        /// the File ID (`0x10003500`).
        public let fileID: String
        /// The file's path inside the volume, e.g. `/home/mca/manuf_ver`.
        public let path: String
        /// Whether the file's content carries a trailing `MFS_Integrity_Table`.
        /// The flag is what says so — an FTBL volume's files have no uniform
        /// tail to recognise by shape.
        public let integrity: Bool
        public let encryption: Bool
        public let antiReplay: Bool
        /// The rest of the access bitfield, which upstream prints as 13 bits
        /// and does not name.
        public let accessUnknown: Int
        public let groupID: Int
        public let userID: Int
        /// The low-level file index this record names.
        public let vfsID: Int
        /// Upstream's trailing unnamed value (printed as 64 bits).
        public let unknown: Int

        public init(fileID: String, path: String, integrity: Bool, encryption: Bool,
                    antiReplay: Bool, accessUnknown: Int, groupID: Int, userID: Int,
                    vfsID: Int, unknown: Int) {
            self.fileID = fileID
            self.path = path
            self.integrity = integrity
            self.encryption = encryption
            self.antiReplay = antiReplay
            self.accessUnknown = accessUnknown
            self.groupID = groupID
            self.userID = userID
            self.vfsID = vfsID
            self.unknown = unknown
        }
    }

    /// Which table a volume's header actually landed on, and how (§
    /// `check_ftbl_pl` / `check_ftbl_id`, MEA.py 7405–7445).
    ///
    /// Upstream falls back rather than giving up, and says so in a warning:
    /// a volume with no platform is read as `0x01` (ICP) and one with no
    /// dictionary — or a dictionary this platform does not have — as `0x0A`
    /// (CON). `assumedPlatform`/`assumedDictionary` carry that "said so", so
    /// the panel can pass it on instead of presenting a guess as a fact.
    public struct Resolution: Sendable, Equatable {
        public var platform: Int
        public var dictionary: Int
        public var assumedPlatform: Bool
        public var assumedDictionary: Bool
        /// True when even the fallback has no `FTBL` table — nothing here can
        /// name this volume's files.
        public var missing: Bool
    }

    /// Upstream's two fallbacks, as the values they fall back to.
    public static let defaultPlatform = 0x01   // ICP
    public static let defaultDictionary = 0x0A // CON

    /// platform → dictionary → table name → file ID → record, exactly as the
    /// file is written.
    private let tables: [String: [String: [String: [String: String]]]]

    public init() { self.tables = [:] }

    init(tables: [String: [String: [String: [String: String]]]]) {
        self.tables = tables
    }

    /// True when nothing was loaded — a source that has no table to give.
    /// Upstream only warns about a missing entry when it *has* a file to look
    /// in; an empty table says nothing at all.
    public var isEmpty: Bool { tables.isEmpty }

    /// The platform and dictionary a volume's header values resolve to, with
    /// upstream's fallbacks applied (MEA.py 7405–7445). `platform` or
    /// `dictionary` of −1 means the volume header had none.
    public func resolve(platform: Int, dictionary: Int) -> Resolution {
        var result = Resolution(platform: platform, dictionary: dictionary,
                                assumedPlatform: false, assumedDictionary: false,
                                missing: false)
        if platform < 0 || tables[Self.key(platform)] == nil {
            result.platform = Self.defaultPlatform
            result.assumedPlatform = platform != Self.defaultPlatform
        }
        let platformTables = tables[Self.key(result.platform)]
        if dictionary < 0 || platformTables?[Self.key(dictionary)] == nil {
            result.dictionary = Self.defaultDictionary
            result.assumedDictionary = dictionary != Self.defaultDictionary
        }
        result.missing = platformTables?[Self.key(result.dictionary)]?["FTBL"] == nil
        return result
    }

    /// The `FTBL` record that names low-level file `index` in the table
    /// `platform`/`dictionary` resolves to, or nil where nothing names it.
    ///
    /// **The first match, and only the first** — upstream's loop ends on one
    /// (`break # Stop searching FTBL Dictionary at first VFS ID match`,
    /// MEA.py 8444), and a `vfsID` is shared more often than not: 4836 of the
    /// file's `vfsID`s are claimed by two records under different paths. The
    /// later ones are records upstream never prints, so showing them would be
    /// a name this file does not have.
    ///
    /// "First" is the order the records are written in, which a Swift
    /// dictionary does not keep — so the pick is the lowest **file ID**
    /// instead. The two are the same order on the data as shipped: over all 70
    /// tables and all 4836 shared `vfsID`s, the record written first is the one
    /// with the lowest file ID, every time. A deterministic rule that
    /// reproduces upstream's answer beats keeping 5 MB of text around to
    /// remember what order it was in.
    public func record(namingFileIndex index: Int,
                       platform: Int, dictionary: Int) -> Entry? {
        let resolution = resolve(platform: platform, dictionary: dictionary)
        guard !resolution.missing,
              let records = tables[Self.key(resolution.platform)]?[
                  Self.key(resolution.dictionary)]?["FTBL"] else { return nil }
        var best: Entry?
        for (fileID, record) in records {
            guard let entry = Self.entry(fileID: fileID, record: record),
                  entry.vfsID == index else { continue }
            if best == nil || entry.fileID < best!.fileID { best = entry }
        }
        return best
    }

    /// `FileTable.dat` as it is downloaded. Malformed JSON is an error; a
    /// platform, dictionary or table of an unexpected shape is skipped, which
    /// is how the file grows a new one without breaking this parser.
    public static func parse(_ text: String) throws -> FileTable {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any], !root.isEmpty else {
            throw MEADataError.malformed(file: "FileTable.dat")
        }
        var tables: [String: [String: [String: [String: String]]]] = [:]
        for (platform, dictionaries) in root {
            guard let dictionaries = dictionaries as? [String: Any] else { continue }
            var byDictionary: [String: [String: [String: String]]] = [:]
            for (dictionary, named) in dictionaries {
                guard let named = named as? [String: Any] else { continue }
                var byTable: [String: [String: String]] = [:]
                for (table, records) in named {
                    guard let records = records as? [String: String] else { continue }
                    byTable[table.uppercased()] = records
                }
                if !byTable.isEmpty { byDictionary[dictionary.uppercased()] = byTable }
            }
            if !byDictionary.isEmpty { tables[platform.uppercased()] = byDictionary }
        }
        guard !tables.isEmpty else { throw MEADataError.malformed(file: "FileTable.dat") }
        return FileTable(tables: tables)
    }

    /// One record string, typed. Nil for a record that does not carry the nine
    /// fields upstream unpacks — a shorter or unparseable row names nothing,
    /// and guessing at its fields would put a wrong flag on a real file.
    static func entry(fileID: String, record: String) -> Entry? {
        let parts = record.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 9 else { return nil }
        let numbers = parts.dropFirst().map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        let value = numbers.map { $0! }
        return Entry(fileID: fileID,
                     path: String(parts[0]),
                     integrity: value[0] != 0,
                     encryption: value[1] != 0,
                     antiReplay: value[2] != 0,
                     accessUnknown: value[3],
                     groupID: value[4],
                     userID: value[5],
                     vfsID: value[6],
                     unknown: value[7])
    }

    /// The key form the file uses: two upper-case hex digits.
    private static func key(_ value: Int) -> String {
        String(format: "%02X", value)
    }
}
