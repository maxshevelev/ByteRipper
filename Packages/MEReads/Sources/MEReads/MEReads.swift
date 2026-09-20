import Foundation
import MEFirmware
import MEPresentation
import ToolModuleKit

/// The ME region's bytes, and the reads both tool-modules make over them
/// (`Design/ME_REGION_IN_UEFI_TREE_PLAN.md`).
///
/// The UEFI Structure and the ME Analyzer read the same region the same way,
/// down to the fallback for a dump with no descriptor. That reading used to be
/// written out twice, once in each tool-module, where a fix to either copy
/// could drift from the other — which is what the project's rule about code two
/// tool-modules need is for.
///
/// Everything here does its own work off the main actor, because both callers
/// are on it: a panel that materialised a 16 MB region on the main actor would
/// take the window with it.
public enum MEReads {
    /// Where the fresh firmware database comes from. One seam for both
    /// tool-modules rather than one each: the reads below are shared, so the
    /// source they read from is shared too, and a test that installs its own
    /// covers both panels. The tool-modules keep their own `dataSource` as the
    /// name their tests and their doc comments use — each forwards here.
    public static var dataSource: any MEADataSource = MEAGitHubDataRepository()

    // MARK: - Bytes

    /// The whole content, as one `Data`. The engine takes a region buffer, so
    /// the reader is materialised; chunked so a large image is never assembled
    /// in one giant append.
    public static func readAll(_ snapshot: any ToolContentReader) throws -> Data {
        try readRange(snapshot, 0..<snapshot.size)
    }

    /// `range`, as one `Data` — the same chunked-read shape as `readAll`,
    /// narrowed to just the bytes the engine actually needs.
    public static func readRange(
        _ snapshot: any ToolContentReader, _ range: Range<UInt64>
    ) throws -> Data {
        var data = Data()
        let chunk = 1 << 20
        var offset = range.lowerBound
        while offset < range.upperBound {
            let length = Int(min(UInt64(chunk), range.upperBound - offset))
            data.append(contentsOf: try snapshot.read(at: offset, length: length))
            offset += UInt64(length)
        }
        return data
    }

    /// The bytes handed to the engine: the ME region when the shared tree could
    /// resolve it, the whole file otherwise. Both the parse and the later
    /// checksum request go through here, so the digests describe the same
    /// buffer the analysis was made from and not a differently chosen one.
    ///
    /// A region that is empty rather than absent names no bytes, and falls back
    /// with the rest.
    public static func regionBytes(
        _ snapshot: any ToolContentReader, _ meRegion: Range<UInt64>?
    ) throws -> Data {
        if let meRegion, meRegion.lowerBound < meRegion.upperBound {
            return try readRange(snapshot, meRegion)
        }
        return try readAll(snapshot)
    }

    /// Where `regionBytes` starts in the open file.
    public static func regionBase(_ meRegion: Range<UInt64>?) -> Int {
        guard let meRegion, meRegion.lowerBound < meRegion.upperBound else { return 0 }
        return Int(meRegion.lowerBound)
    }

    // MARK: - The engine

    /// Off the main actor: materialise just the ME region (when the shared tree
    /// could resolve it) and hand it to the engine at that region's own base
    /// offset, so every address the engine reports is still absolute in the
    /// open file. Falls back to the whole file when the region is not known —
    /// no descriptor recognized yet, or a bare ME dump with no descriptor at
    /// all — where the engine's own `$FPT` search over the whole buffer is what
    /// covers it, unchanged.
    public static func analyze(
        _ snapshot: any ToolContentReader,
        analyzer: MEFirmwareAnalyzer,
        meRegion: Range<UInt64>?
    ) async -> Result<FirmwareAnalysis, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let data = try regionBytes(snapshot, meRegion)
                let baseOffset = regionBase(meRegion)
                let analysis = try await analyzer.analyze(region: data, baseOffset: baseOffset)
                return .success(analysis)
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// Off the main actor: the same region `analyze` was given, digested. An
    /// unreadable file leaves every field nil, and the group then goes rather
    /// than standing there promising numbers it cannot get.
    public static func checksums(
        _ snapshot: any ToolContentReader, meRegion: Range<UInt64>?
    ) async -> MEFirmware.Checksums {
        // `Checksums` is spelled out: `UEFIImage` has one of its own, and a
        // caller of this can see both.
        await Task.detached(priority: .userInitiated) {
            guard let data = try? regionBytes(snapshot, meRegion) else {
                return MEFirmware.Checksums()
            }
            return await MEFirmwareAnalyzer.checksums(of: data)
        }.value
    }

    /// Off the main actor: the table fetched (or taken from the source's own
    /// in-memory cache) and turned into this volume's names. Nil when there is
    /// nothing to name with — no source configured, no network, a table that
    /// cannot be parsed — which the caller treats as "the rows keep their
    /// numbers".
    public static func fileNames(
        mfs: MFSVolume?,
        efs: EFSVolume?,
        configIDs: [Int],
        platform: Int,
        dictionary: Int
    ) async -> (mfs: MFSFileNames?, efs: EFSFileNames?, config: ConfigRecordPaths?)? {
        guard let table = try? await dataSource.fileTable() else { return nil }
        return await Task.detached(priority: .utility) {
            (mfs.map { MFSFileNames(table: table, volume: $0) },
             efs.map {
                 EFSFileNames(table: table, volume: $0,
                              platform: platform, dictionary: dictionary)
             },
             configIDs.isEmpty ? nil
                 : ConfigRecordPaths(table: table, fileIDs: configIDs,
                                     platform: platform, dictionary: dictionary))
        }.value
    }

    /// A data error's line for the status row. The engine's `MEADataError` is a
    /// `LocalizedError` with its own wording; anything else is an internal
    /// failure worth saying plainly.
    public static func describe(_ error: Error) -> String {
        (error as? MEADataError)?.errorDescription
            ?? "The analysis failed: \(error.localizedDescription)"
    }
}
