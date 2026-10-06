import Foundation
import Localization
import ToolModuleKit
import UEFIImage

/// A dump's BIOS region held against the region a vendor's update file carries
/// (`BIOSGuardUpdate`), part by part as the file's table names them: which
/// parts are the same, which differ, and which hold what belongs to this one
/// board rather than to the model.
///
/// It answers two questions a bench asks of a dump: is the firmware in it the
/// vendor's, untouched — and, where it is not, what writing the vendor's back
/// would change. The answer to the second is a transaction that writes only
/// the bytes that differ, in the parts the user chose, so that what the dump
/// shows as modified afterwards is exactly what changed.
///
/// What it does not decide is which values are right for the board. A part
/// whose name says it is NVRAM or the vendor's per-board store is kept by
/// default, because those are the bytes an update file cannot hold for this
/// board; the user can still choose to write them.
public struct UEFIUpdateComparison: Equatable, Sendable {
    /// One part of the region, as the update file's table names it.
    public struct Row: Equatable, Sendable {
        public var name: String
        /// The flasher's switch for it — `/P`, `/N` — or empty.
        public var key: String
        public var blockCount: Int
        /// Where it lies in the dump.
        public var range: Range<UInt64>
        /// How many of its bytes the dump holds differently.
        public var differingBytes: UInt64
        /// Its name or switch says it holds this board's own data.
        public var isBoardData: Bool
        /// The update holds nothing here — every byte erased.
        public var isErasedInUpdate: Bool
        /// Where the dump differs, as ranges of the dump: runs of differing
        /// bytes, joined across gaps shorter than `joinGap`.
        public var differences: [Range<UInt64>]

        public var isIdentical: Bool { differingBytes == 0 }
        /// What the sheet ticks before the user has touched it.
        public var writesByDefault: Bool { !isIdentical && !isBoardData }
    }

    public var platform: String
    /// The dump's BIOS region.
    public var region: Range<UInt64>
    public var rows: [Row]

    public init(platform: String, region: Range<UInt64>, rows: [Row]) {
        self.platform = platform
        self.region = region
        self.rows = rows
    }

    /// Why there is no comparison.
    public enum Problem: Error, Equatable, Sendable {
        case notAnUpdate
        case unreadable(BIOSGuardUpdate.Problem)
        /// The update carries a region of `update` bytes; the dump's is `region`.
        case sizeMismatch(update: UInt64, region: UInt64)

        public var message: String {
            switch self {
            case .notAnUpdate:
                return L("This is not an AMI BIOS Guard update file.")
            case .unreadable(let problem):
                switch problem {
                case .notAnUpdate: return L("This is not an AMI BIOS Guard update file.")
                case .noEntries: return L("The update file lists no blocks.")
                case .truncated(let block):
                    return L("The update file ends inside block %1$@.", block + 1)
                case .notABlock(let block):
                    return L("Block %1$@ of the update file does not read as a block.", block + 1)
                }
            case .sizeMismatch(let update, let region):
                return L("The update file carries a BIOS region of %1$@ bytes, and the BIOS region of this dump is %2$@ bytes. It is not an update for this board.",
                         UEFIUpdateComparison.hex(update), UEFIUpdateComparison.hex(region))
            }
        }
    }

    /// Differing runs closer than this are written as one: a write per stray
    /// byte would make thousands of writes of the same change.
    public static let joinGap: UInt64 = 16

    /// Reads `file` as an update and compares it with `dump`, the dump's BIOS
    /// region, which starts at `regionStart` in the dump.
    public static func compare(file: [UInt8], with dump: [UInt8], at regionStart: UInt64)
    -> Result<(UEFIUpdateComparison, BIOSGuardUpdate), Problem> {
        guard BIOSGuardUpdate.isUpdate(file) else { return .failure(.notAnUpdate) }
        switch BIOSGuardUpdate.parse(file) {
        case .failure(let problem):
            return .failure(.unreadable(problem))
        case .success(let update):
            return compare(update, with: dump, at: regionStart).map { ($0, update) }
        }
    }

    public static func compare(_ update: BIOSGuardUpdate, with dump: [UInt8], at regionStart: UInt64)
    -> Result<UEFIUpdateComparison, Problem> {
        guard update.region.count == dump.count else {
            return .failure(.sizeMismatch(update: UInt64(update.region.count), region: UInt64(dump.count)))
        }
        let rows = update.entries.map { entry in
            let range = Int(entry.range.lowerBound)..<Int(entry.range.upperBound)
            let (count, runs) = differences(update.region, dump, in: range)
            return Row(
                name: entry.name, key: entry.key, blockCount: entry.blockCount,
                range: (regionStart + entry.range.lowerBound)..<(regionStart + entry.range.upperBound),
                differingBytes: count,
                isBoardData: isBoardData(name: entry.name, key: entry.key),
                isErasedInUpdate: update.region[range].allSatisfy { $0 == 0xFF },
                differences: runs.map { (regionStart + UInt64($0.lowerBound))..<(regionStart + UInt64($0.upperBound)) }
            )
        }
        return .success(UEFIUpdateComparison(
            platform: update.platform,
            region: regionStart..<(regionStart + UInt64(dump.count)),
            rows: rows
        ))
    }

    /// The writes that put the update's bytes into the rows at `chosen` —
    /// only where they differ. Nil when there is nothing to write.
    public func transaction(writing chosen: Set<Int>, from update: BIOSGuardUpdate) -> ToolTransaction? {
        let writes = chosen.sorted().filter { rows.indices.contains($0) }.flatMap { index in
            rows[index].differences.map { run in
                let from = Int(run.lowerBound - region.lowerBound)
                let to = Int(run.upperBound - region.lowerBound)
                return ToolTransaction.Write(offset: run.lowerBound, bytes: Array(update.region[from..<to]))
            }
        }
        guard !writes.isEmpty else { return nil }
        return ToolTransaction(name: L("Write from Update File"), writes: writes)
    }

    /// The flasher's own switches for NVRAM, its copy and the OA key, and the
    /// words vendors put in the names of their per-board stores — `AsusNVRAM`,
    /// `PEGA_GPNV`, `OA_TABLE`.
    public static func isBoardData(name: String, key: String) -> Bool {
        let key = key.uppercased()
        let name = name.uppercased()
        return ["/N", "/NB", "/OA"].contains(key)
            || ["NVRAM", "GPNV", "DMI", "SMBIOS", "OA_"].contains { name.contains($0) }
            || name == "OA"
    }

    /// How many bytes differ in `range`, and the runs they make, joined across
    /// short gaps. Whole 4 KiB pages are compared first: most of a region is
    /// the same as the dump's, and a page that matches is skipped at once.
    static func differences(_ a: [UInt8], _ b: [UInt8], in range: Range<Int>) -> (UInt64, [Range<Int>]) {
        var count: UInt64 = 0
        var runs: [Range<Int>] = []
        let page = 0x1000
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let base = pa.baseAddress, let other = pb.baseAddress else { return }
                var at = range.lowerBound
                while at < range.upperBound {
                    let end = min(at + page, range.upperBound)
                    if memcmp(base + at, other + at, end - at) == 0 { at = end; continue }
                    for index in at..<end where pa[index] != pb[index] {
                        count += 1
                        if let last = runs.last, index - last.upperBound < Int(joinGap) {
                            runs[runs.count - 1] = last.lowerBound..<(index + 1)
                        } else {
                            runs.append(index..<(index + 1))
                        }
                    }
                    at = end
                }
            }
        }
        return (count, runs)
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

// MARK: - What the sheet says

extension UEFIUpdateComparison.Row {
    /// The State column.
    public var stateText: String {
        if isIdentical { return L("Identical") }
        if isBoardData {
            return isErasedInUpdate
                ? L("Board data; empty in the update")
                : L("Board data; %1$@ bytes differ", differingBytes)
        }
        return L("%1$@ bytes differ", differingBytes)
    }

    /// The Name column: the name, and which of its blocks where there are
    /// several.
    public var nameText: String {
        blockCount > 1 ? L("%1$@ (%2$@ blocks)", name, blockCount) : name
    }
}

extension UEFIUpdateComparison {
    /// The line under the table: how the parts stand, and what pressing Write
    /// would write.
    public func summary(writing chosen: Set<Int>) -> String {
        let identical = rows.filter(\.isIdentical).count
        let bytes = chosen.filter { rows.indices.contains($0) }.reduce(UInt64(0)) { $0 + rows[$1].differingBytes }
        let kept = rows.indices.filter { !rows[$0].isIdentical && !chosen.contains($0) }.count
        return L("%1$@ of %2$@ parts identical. To write: %3$@ parts, %4$@ bytes. Kept as they are: %5$@.",
                 identical, rows.count, chosen.count, bytes, kept)
    }
}
