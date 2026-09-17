import Foundation
import MEFirmware

/// What an EFS volume's files are called, and what the file table says about
/// them, looked up in `FileTable.dat` (upstream `efs_anl`, MEA.py 8817).
///
/// An EFS volume needs *two* tables, which is what makes this a value of its
/// own rather than the MFS lookup with another key. `EFST` says where each file
/// sits in the volume's data area and what it is called; the `FTBL` rows beside
/// it — keyed by the same file ID — hold the path and the Integrity flag. The
/// engine has already used the halves it needs to cut the data area into files
/// (`EFSVolume.files`); what is looked up here is the text, which the result
/// model never carries (reference/result-model.md): the name, the path and the
/// flags the table states about each file.
///
/// `.none` is a panel with nothing looked up: before the table arrives, and on
/// a machine that cannot reach the database. The engine's file list is then
/// empty too — a volume whose pages carry no directory has nothing to list
/// without the table — so there is nothing to name.
public struct EFSFileNames: Sendable, Equatable {
    /// Nothing looked up.
    public static let none = EFSFileNames(names: [:], records: [:],
                                          resolution: nil, revision: nil,
                                          hasTable: false)

    /// File ID → the `EFST` record that names it.
    public let names: [Int: FileTable.EFSEntry]

    /// File ID → the `FTBL` record that gives it a path and its flags. Missing
    /// where no row claims the file — upstream prints an error and stores the
    /// file anyway (MEA.py 8936), and the row here keeps its name.
    public let records: [Int: FileTable.Entry]

    /// Which table the lookup read, and whether either half of it was assumed
    /// rather than named by the MFS volume beside this one. Nil when nothing
    /// was looked up.
    public let resolution: FileTable.Resolution?

    /// The table revision the EFS System page names (`dictionaryRevision`).
    public let revision: Int?

    /// Whether that platform and dictionary carry an `EFST` at all, so the
    /// panel can tell "no table for this volume" from "a table that named
    /// nothing in it".
    public let hasTable: Bool

    public init(names: [Int: FileTable.EFSEntry], records: [Int: FileTable.Entry],
                resolution: FileTable.Resolution?, revision: Int?, hasTable: Bool) {
        self.names = names
        self.records = records
        self.resolution = resolution
        self.revision = revision
        self.hasTable = hasTable
    }

    /// The names for one volume, looked up once up front.
    ///
    /// `platform` and `dictionary` are the **MFS** volume's, not this volume's
    /// own Dictionary field: upstream hands `efs_anl` the values it read out of
    /// the MFS volume header (MEA.py 5618), and the EFS page's Dictionary is
    /// only checked against them (`EFSVolume.matchesMFSDictionary`). −1 for
    /// either means no MFS volume decoded alongside, which the table's own
    /// fallbacks then answer.
    public init(table: FileTable, volume: EFSVolume,
                platform: Int, dictionary: Int) {
        guard !table.isEmpty else {
            self = .none
            return
        }
        let resolution = table.resolve(platform: platform, dictionary: dictionary)
        let revision = Int(volume.dictionaryRevision)
        let hasTable = table.hasEFST(platform: resolution.platform,
                                     dictionary: resolution.dictionary)
        let entries = table.efsEntries(platform: resolution.platform,
                                       dictionary: resolution.dictionary,
                                       revision: revision) ?? []
        var names: [Int: FileTable.EFSEntry] = [:]
        var records: [Int: FileTable.Entry] = [:]
        for entry in entries {
            names[entry.fileID] = entry
            if let record = table.record(namingFileIndex: entry.fileID,
                                         platform: resolution.platform,
                                         dictionary: resolution.dictionary) {
                records[entry.fileID] = record
            }
        }
        self = EFSFileNames(names: names, records: records,
                            resolution: resolution, revision: revision,
                            hasTable: hasTable)
    }

    /// True when the lookup named nothing — no `EFST` for this volume, or none
    /// at its revision.
    public var isEmpty: Bool { names.isEmpty }

    /// What the file is called, e.g. `BUP_MBP`.
    public func name(for fileID: Int) -> String? { names[fileID]?.name }

    /// The `FTBL` row that describes the file, or nil where none claims it.
    public func record(for fileID: Int) -> FileTable.Entry? { records[fileID] }

    /// How the tables the rows were read from are named on the volume's own
    /// row: the platform and dictionary in the form the file keys them by, the
    /// table revision the volume asked for, and a word when either half was
    /// assumed rather than named by the MFS volume (upstream warns in the same
    /// place — `check_ftbl_pl` / `check_ftbl_id`).
    public var tableLabel: String? {
        guard let resolution, let revision else { return nil }
        var text = String(format: "%02X / %02X rev %02X",
                          resolution.platform, resolution.dictionary, revision)
        if !hasTable { return "\(text) — no EFST in FileTable.dat" }
        if names.isEmpty { return "\(text) — no EFST at that revision" }
        let assumed = [resolution.assumedPlatform ? "platform" : nil,
                       resolution.assumedDictionary ? "dictionary" : nil].compactMap { $0 }
        if !assumed.isEmpty {
            text += " (assumed \(assumed.joined(separator: " and ")))"
        }
        return text
    }
}
