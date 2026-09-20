import Foundation
import MEFirmware

/// What an FTBL-mode MFS volume's low-level files are called, looked up in
/// `FileTable.dat` for the one platform and dictionary that volume's header
/// names (§11 of the ME tool; upstream `mfs_home13_anl`, MEA.py 8303).
///
/// Why this is a value the panel carries rather than a field of the analysis:
/// such a volume has **no names in its bytes**. The FAT chains are numbered,
/// and the number is all the flash says; the path comes out of an upstream
/// database. The result model holds facts decoded from bytes and never
/// DB-derived display text (reference/result-model.md), so the join happens
/// here, on the way to the rows — the engine keeps saying `index` and `size`,
/// and the panel is where a name is put on them.
///
/// `.none` is a panel with nothing looked up: before the table arrives, on a
/// legacy volume (which names its own files through the home directory), and
/// on a machine that cannot reach the database at all. The rows then read as
/// they always have — `File 63` — which is the honest answer, not a gap.
public struct MFSFileNames: Sendable, Equatable {
    /// Nothing looked up.
    public static let none = MFSFileNames(entries: [:], resolution: nil)

    /// File index → the record that names it. One, not a list: upstream stops
    /// at the first record claiming a `vfsID` (`break`, MEA.py 8444), and a
    /// `vfsID` is claimed twice more often than not — the records it never
    /// reaches are names the file does not have.
    public let entries: [Int: FileTable.Entry]

    /// Which table the lookup read, and whether either half of it was assumed
    /// rather than named by the volume. Nil when nothing was looked up.
    public let resolution: FileTable.Resolution?

    public init(entries: [Int: FileTable.Entry], resolution: FileTable.Resolution?) {
        self.entries = entries
        self.resolution = resolution
    }

    /// The names for one volume: every present file's index looked up once,
    /// up front, so the rows are built from a value and not from a search.
    public init(table: FileTable, volume: MFSVolume) {
        guard !table.isEmpty else {
            self = .none
            return
        }
        let resolution = table.resolve(platform: volume.ftblPlatform,
                                       dictionary: volume.ftblDictionary)
        guard !resolution.missing else {
            self = MFSFileNames(entries: [:], resolution: resolution)
            return
        }
        var found: [Int: FileTable.Entry] = [:]
        for index in Set(volume.files.map(\.index)) {
            if let record = table.record(namingFileIndex: index,
                                         platform: resolution.platform,
                                         dictionary: resolution.dictionary) {
                found[index] = record
            }
        }
        self = MFSFileNames(entries: found, resolution: resolution)
    }

    /// True when no name was found for any file — a table that does not
    /// describe this volume at all. The panel then says nothing about naming
    /// rather than claiming a table it could not use.
    public var isEmpty: Bool { entries.isEmpty }

    /// The record naming `index`, or nil.
    public func record(for index: Int) -> FileTable.Entry? {
        entries[index]
    }

    /// What the row is called, or nil where the table names nothing for that
    /// index — the row keeps its number then, the way upstream falls back to
    /// `/Unknown/<idx>.bin`.
    public func path(for index: Int) -> String? {
        entries[index]?.path
    }

    /// How the table the names came from is named on the volume's own row:
    /// the platform and dictionary in the form the file keys them by, and a
    /// word when either was assumed rather than read from the volume
    /// (upstream warns in the same place — `check_ftbl_pl` / `check_ftbl_id`).
    public var tableLabel: String? {
        guard let resolution else { return nil }
        let table = String(format: "%02X / %02X", resolution.platform, resolution.dictionary)
        if resolution.missing { return "\(table) — not in FileTable.dat" }
        let assumed = [resolution.assumedPlatform ? "platform" : nil,
                       resolution.assumedDictionary ? "dictionary" : nil].compactMap { $0 }
        guard !assumed.isEmpty else { return table }
        return "\(table) (assumed \(assumed.joined(separator: " and ")))"
    }
}
