import Foundation
import MEFirmware

/// What the files of an ID-keyed Configuration stream are called — the paths
/// the `FTBL` table of `FileTable.dat` stores under each record's **File ID as
/// its key** (upstream `mfs_cfg_anl`'s 0xC branch, MEA.py 8546).
///
/// This is a second, different lookup into the same table: an MFS or EFS file
/// is found by the `vfsID` written *inside* a record (`MFSFileNames`,
/// `EFSFileNames`), while a Configuration record carries the key itself and the
/// row at it is the answer. Both are DB text, so both live here rather than in
/// the analysis (reference/result-model.md) — the records the engine decodes
/// say where the bytes are, how long they are and whether an OEM setting may
/// override the Intel one, and nothing about a name.
///
/// `.none` is a panel with nothing looked up: before the table arrives, and on
/// a machine that cannot reach the database. A row then reads as its File ID,
/// which is what the stream itself says about it.
public struct ConfigRecordPaths: Sendable, Equatable {
    /// Nothing looked up.
    public static let none = ConfigRecordPaths(paths: [:], resolution: nil)

    /// File ID → the path the table keys under it. A record the table has no
    /// row for is absent, and reads as upstream's own fallback.
    public let paths: [Int: String]

    /// Which table the lookup read, and whether either half of it was assumed
    /// rather than named by the MFS volume. Nil when nothing was looked up.
    public let resolution: FileTable.Resolution?

    public init(paths: [Int: String], resolution: FileTable.Resolution?) {
        self.paths = paths
        self.resolution = resolution
    }

    /// The paths for one set of records, looked up once up front.
    ///
    /// `platform` and `dictionary` are the MFS volume header's, as upstream
    /// passes them into `mfs_cfg_anl` (and through `fitc_anl` into it); −1 for
    /// either means no MFS volume decoded alongside, which the table's own
    /// fallbacks then answer.
    public init(table: FileTable, fileIDs: some Sequence<Int>,
                platform: Int, dictionary: Int) {
        guard !table.isEmpty else {
            self = .none
            return
        }
        let resolution = table.resolve(platform: platform, dictionary: dictionary)
        var paths: [Int: String] = [:]
        for id in Set(fileIDs) {
            if let record = table.record(withFileID: id,
                                         platform: resolution.platform,
                                         dictionary: resolution.dictionary) {
                paths[id] = record.path
            }
        }
        self = ConfigRecordPaths(paths: paths, resolution: resolution)
    }

    /// True when no record was named — a table that does not describe this
    /// image's configuration at all.
    public var isEmpty: Bool { paths.isEmpty }

    /// What the record's file is called.
    ///
    /// Nil before anything was looked up — the row then keeps its File ID,
    /// rather than claiming the table had nothing for it. Once a lookup *has*
    /// happened, a record no row is keyed for reads as upstream writes it out:
    /// `/Unknown/<ID>.bin`.
    public func path(for fileID: Int) -> String? {
        if let path = paths[fileID] { return path }
        guard resolution != nil else { return nil }
        return String(format: "/Unknown/%08X.bin", fileID)
    }

    /// Whether the table actually named this record, as against falling back.
    public func isNamed(_ fileID: Int) -> Bool { paths[fileID] != nil }

    /// How the table the paths came from is named on the group's own row — the
    /// same form the MFS volume's row uses.
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
