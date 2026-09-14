import Foundation
import ToolModuleKit
import UEFIImage

/// The Top Swap backup of the block the FIT lives in.
///
/// A chipset with Top Swap set maps the block directly below the top block of
/// the BIOS region at the top of memory instead, so a board can start from a
/// second copy of its boot block while the first is being rewritten. Such an
/// image carries the top block twice — the same volumes, microcode and ACM, and
/// a FIT of its own at the same place in the block naming the same addresses —
/// and a change to the table has to land in both. A change to one leaves the
/// machine starting, after a swap, from a copy that no longer agrees with the
/// other.
///
/// The block's size is a chipset strap whose place in the descriptor moves
/// from one PCH generation to the next, so the copy is recognised by what it has
/// to hold instead: the FIT pointer with the same value, and the `_FIT_` table
/// at the same distance below.
public struct FITTopSwapBackup: Equatable, Sendable {
    /// The top block, ending where the address space does.
    public var top: Range<UInt64>
    /// Its copy, directly below.
    public var backup: Range<UInt64>

    public var size: UInt64 { top.upperBound - top.lowerBound }

    /// The sizes a Top Swap block comes in: a power of two from 64 KiB to 16 MiB.
    static let smallestBlock: UInt64 = 0x1_0000
    static let largestBlock: UInt64 = 0x100_0000

    /// The backup of the block holding `table`, or nil when the image has none.
    public static func find(for table: FITTable, in reader: ImageReader) -> FITTopSwapBackup? {
        let topEnd = table.pointerOffset + (0x1_0000_0000 - FIT.pointerAddress)
        var size = smallestBlock
        while size <= largestBlock, size * 2 <= topEnd {
            let top = (topEnd - size)..<topEnd
            if top.lowerBound <= table.range.lowerBound, table.range.upperBound <= top.upperBound,
               reader.uint32(at: table.pointerOffset - size).map(UInt64.init) == table.pointerAddress,
               reader.uint64(at: table.range.lowerBound - size) == FIT.signature {
                return FITTopSwapBackup(top: top, backup: (top.lowerBound - size)..<top.lowerBound)
            }
            size *= 2
        }
        return nil
    }

    /// Where an offset is once the blocks trade places: a byte of either block
    /// is the same byte of the other, and everything else stays put.
    public func swap(_ offset: UInt64) -> UInt64 {
        if top.contains(offset) { return offset - size }
        if backup.contains(offset) { return offset + size }
        return offset
    }

    /// Whether the two copies are the same bytes — the one state in which a
    /// change worked out for the top block is right for the backup as well.
    public func copiesMatch(in reader: ImageReader) -> Bool {
        let chunk: UInt64 = 0x1_0000
        var offset: UInt64 = 0
        while offset < size {
            let count = min(chunk, size - offset)
            guard let upper = reader.bytes(at: top.lowerBound + offset, count: count),
                  let lower = reader.bytes(at: backup.lowerBound + offset, count: count),
                  upper == lower
            else { return false }
            offset += count
        }
        return true
    }

    /// `transaction`, with every write into the top block made at the same
    /// place in the backup too. A write outside both blocks is made once: both
    /// tables name it by the same address. One that reaches into either block
    /// without lying wholly inside the top one has no place in the other copy.
    public func mirroring(_ transaction: ToolTransaction) -> Result<ToolTransaction, FITEditProblem> {
        var writes = transaction.writes
        for write in transaction.writes {
            let range = write.range
            if top.lowerBound <= range.lowerBound, range.upperBound <= top.upperBound {
                writes.append(ToolTransaction.Write(offset: write.offset - size, bytes: write.bytes))
            } else if range.overlaps(top) || range.overlaps(backup) {
                return .failure(.topSwapWriteCrossesTheBlocks(at: range.lowerBound))
            }
        }
        return .success(ToolTransaction(name: transaction.name, writes: writes))
    }

    /// An edit worked out for the top block, carried into the backup when the
    /// image has one: refused when the copies already differ, since one change
    /// cannot then be right for both, and `record`ed on the outcome otherwise.
    static func mirroring<Outcome>(
        _ result: Result<(ToolTransaction, Outcome), FITEditProblem>,
        table: FITTable,
        reader: ImageReader,
        record: (inout Outcome, Range<UInt64>) -> Void
    ) -> Result<(ToolTransaction, Outcome), FITEditProblem> {
        guard case .success(let (transaction, found)) = result,
              let copy = find(for: table, in: reader)
        else { return result }
        guard copy.copiesMatch(in: reader) else {
            return .failure(.topSwapCopiesDiffer(backup: copy.backup))
        }
        switch copy.mirroring(transaction) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let mirrored):
            var outcome = found
            record(&outcome, copy.backup)
            return .success((mirrored, outcome))
        }
    }
}

/// The image as the chipset maps it with Top Swap set: the two blocks traded.
/// The backup's FIT reads through it with the same reader, at the same
/// addresses, as the top one reads through the image itself.
struct FITSwappedSource: ByteSource {
    let base: ImageReader
    let copy: FITTopSwapBackup

    var byteCount: UInt64 { base.count }

    func bytes(in range: Range<UInt64>) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(range.upperBound - range.lowerBound))
        var offset = range.lowerBound
        while offset < range.upperBound {
            // The run up to the next block edge maps as one piece.
            let edge: UInt64
            if copy.top.contains(offset) { edge = copy.top.upperBound }
            else if copy.backup.contains(offset) { edge = copy.backup.upperBound }
            else if offset < copy.backup.lowerBound { edge = copy.backup.lowerBound }
            else { edge = range.upperBound }
            let end = min(edge, range.upperBound)
            let start = copy.swap(offset)
            bytes += base.source.bytes(in: start..<(start + (end - offset)))
            offset = end
        }
        return bytes
    }
}

/// The Top Swap backup's FIT, read at its own offsets and set against the top
/// block's table.
public struct FITBackupReading: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The two blocks are the same bytes.
        case identical
        /// The tables and what they point at inside the block agree; other
        /// bytes of the block do not.
        case otherBytesDiffer
        /// The tables disagree: these rows, by index, differ in their own bytes
        /// or in what they point at inside the block — or the table bytes do,
        /// when the list is empty.
        case tableDiffers(rows: [Int])
        /// No table where the backup's pointer leads.
        case noTable
    }

    public var block: FITTopSwapBackup
    /// The backup's table, at its own offsets in the file.
    public var table: FITTable?
    public var status: Status
    /// Whether the table's own bytes are the top one's — what a repair of the
    /// table's checksum is copied on.
    public var tableBytesMatch: Bool

    /// The backup of the block `table` is in, read, compared, and what the
    /// comparison has to say; nil when the image keeps none.
    static func read(
        beside table: FITTable, reader: ImageReader, image: UEFIImage?
    ) -> (reading: FITBackupReading, findings: [FITProblem])? {
        guard let copy = FITTopSwapBackup.find(for: table, in: reader) else { return nil }
        let swapped = FITReader.read(ImageReader(FITSwappedSource(base: reader, copy: copy)),
                                     image: image, readsBackup: false)
        let own = swapped.problems.map { problem -> FITProblem in
            var moved = problem
            moved.offset = problem.offset.map(copy.swap)
            moved.inBackup = true
            return moved
        }
        guard let backupTable = swapped.table.map({ $0.swapping(copy) }) else {
            let reading = FITBackupReading(block: copy, table: nil, status: .noTable, tableBytesMatch: false)
            return (reading, [FITProblem(.topSwapBackupHasNoTable(backupAt: copy.backup.lowerBound),
                                         at: copy.backup.lowerBound)] + own)
        }

        let tableBytesMatch = reader.bytes(table.range) == reader.bytes(backupTable.range)
        var differing: [Int] = []
        for (index, row) in table.rows.enumerated() {
            guard index < backupTable.rows.count else {
                differing.append(index)
                continue
            }
            let other = backupTable.rows[index]
            var same = reader.bytes(at: row.entry.offset, count: FITEntry.size)
                == reader.bytes(at: other.entry.offset, count: FITEntry.size)
            // What a row points at inside the block has a copy of its own; what
            // it points at outside both blocks is the one set of bytes both
            // tables share.
            if same, let range = componentRange(of: row),
               copy.top.lowerBound <= range.lowerBound, range.upperBound <= copy.top.upperBound {
                same = reader.bytes(range) == reader.bytes((range.lowerBound - copy.size)..<(range.upperBound - copy.size))
            }
            if !same { differing.append(index) }
        }
        if backupTable.rows.count > table.rows.count {
            differing += Array(table.rows.count..<backupTable.rows.count)
        }

        let status: Status
        var findings: [FITProblem] = []
        if !tableBytesMatch || !differing.isEmpty {
            status = .tableDiffers(rows: differing)
            findings.append(FITProblem(.topSwapTableDiffers(at: backupTable.range.lowerBound),
                                       at: backupTable.range.lowerBound))
            for index in differing where index < backupTable.rows.count {
                findings.append(FITProblem(.topSwapEntryDiffers, entry: index,
                                           at: backupTable.rows[index].entry.offset, inBackup: true))
            }
            findings += own
        } else if !copy.copiesMatch(in: reader) {
            status = .otherBytesDiffer
            findings.append(FITProblem(.topSwapBlockDiffers(backup: copy.backup), at: copy.backup.lowerBound))
        } else {
            status = .identical
        }
        let reading = FITBackupReading(block: copy, table: backupTable, status: status,
                                       tableBytesMatch: tableBytesMatch)
        return (reading, findings)
    }

    /// The bytes a row stands for beyond its own sixteen, where they are known.
    private static func componentRange(of row: FITRow) -> Range<UInt64>? {
        switch row.target {
        case .microcode(let header): return header.range
        case .emptyMicrocodeSlot(let offset): return offset..<(offset + 4)
        case .bytes(let offset, _): return row.effectiveSize.map { offset..<(offset + $0) }
        case .nothing, .indexIORegisters, .outsideTheImage: return nil
        }
    }
}

extension FITTable {
    /// The table as read through `FITSwappedSource`, moved to where its bytes
    /// really are.
    func swapping(_ copy: FITTopSwapBackup) -> FITTable {
        var moved = self
        let start = copy.swap(range.lowerBound)
        moved.range = start..<(start + (range.upperBound - range.lowerBound))
        moved.pointerOffset = copy.swap(pointerOffset)
        moved.rows = rows.map { row in
            var movedRow = row
            movedRow.entry.offset = copy.swap(row.entry.offset)
            movedRow.target = row.target.swapping(copy)
            return movedRow
        }
        return moved
    }
}

extension FITTarget {
    func swapping(_ copy: FITTopSwapBackup) -> FITTarget {
        switch self {
        case .microcode(var header):
            header.offset = copy.swap(header.offset)
            if let extended = header.extendedTable?.offset {
                header.extendedTable?.offset = copy.swap(extended)
            }
            return .microcode(header)
        case .emptyMicrocodeSlot(let offset):
            return .emptyMicrocodeSlot(offset: copy.swap(offset))
        case .bytes(let offset, let description):
            return .bytes(offset: copy.swap(offset), description: description)
        case .nothing, .indexIORegisters, .outsideTheImage:
            return self
        }
    }
}

extension FITEditor {
    /// Adds a microcode, or replaces the one for the same CPUID — in the top
    /// block and in its Top Swap backup alike (`FITTopSwapBackup`). The rules
    /// are `addOrReplaceMicrocodeInTheTopBlock`'s.
    public static func addOrReplaceMicrocode(
        _ component: [UInt8],
        in table: FITTable,
        image: UEFIImage?,
        reader: ImageReader,
        addressDiff: UInt64,
        protected: ProtectedRanges? = nil
    ) -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        FITTopSwapBackup.mirroring(
            addOrReplaceMicrocodeInTheTopBlock(component, in: table, image: image, reader: reader,
                                               addressDiff: addressDiff, protected: protected),
            table: table, reader: reader
        ) { $0.topSwapBackup = $1 }
    }

    /// Swaps the microcode a row names — in both copies of a Top Swap image.
    /// The rules are `replaceMicrocodeInTheTopBlock`'s.
    public static func replaceMicrocode(
        at index: Int,
        _ component: [UInt8],
        in table: FITTable,
        image: UEFIImage?,
        reader: ImageReader,
        addressDiff: UInt64,
        protected: ProtectedRanges? = nil
    ) -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        FITTopSwapBackup.mirroring(
            replaceMicrocodeInTheTopBlock(at: index, component, in: table, image: image, reader: reader,
                                          addressDiff: addressDiff, protected: protected),
            table: table, reader: reader
        ) { $0.topSwapBackup = $1 }
    }

    /// Takes a microcode out of the table — in both copies of a Top Swap image.
    /// The rules are `removeMicrocodeFromTheTopBlock`'s.
    public static func removeMicrocode(
        _ index: Int,
        from table: FITTable,
        image: UEFIImage?,
        in reader: ImageReader,
        addressDiff: UInt64,
        protected: ProtectedRanges? = nil
    ) -> Result<(ToolTransaction, FITRemovalOutcome), FITEditProblem> {
        FITTopSwapBackup.mirroring(
            removeMicrocodeFromTheTopBlock(index, from: table, image: image, in: reader,
                                           addressDiff: addressDiff, protected: protected),
            table: table, reader: reader
        ) { $0.topSwapBackup = $1 }
    }
}
