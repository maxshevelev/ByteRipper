import Foundation
import Localization

/// The store as found in one image: the change log, the two `LENV` blocks,
/// and which block the firmware reads.
///
/// The three sit back to back — log, block 1, block 2 — on every dump
/// examined, and an Insyde flash device map declares them as three regions of
/// exactly those sizes. Where in the image they are moves from board to board
/// (upstream's `0xFF620000` is one platform's address), so they are found by
/// signature, not by address.
public struct LenovoDMIArea: Equatable, Sendable {
    /// Where the area starts — the log's first byte.
    public var offset: UInt64
    public var log: LDBGLog
    /// Block 1 and block 2, in file order. Either may be unsigned.
    public var blocks: [LENVBlock]

    public var range: Range<UInt64> { offset..<(offset + LenovoDMIFormat.areaSize) }

    /// The block the firmware reads: the usable one with the higher
    /// generation, and block 1 on a tie, which is how upstream decides it.
    /// Nil when neither is usable — a wiped store.
    ///
    /// Whether the firmware also passes over a block whose checksum is wrong
    /// is not known; the panel says so where it matters.
    public var liveIndex: Int? {
        let usable = blocks.indices.filter { blocks[$0].isUsable }
        return usable.max { a, b in
            blocks[a].generation != blocks[b].generation
                ? blocks[a].generation < blocks[b].generation
                : a > b
        }
    }

    public var live: LENVBlock? { liveIndex.map { blocks[$0] } }

    /// Every key either block holds, in the live block's order, then the
    /// other block's.
    public var keys: [LenovoDMIKey] {
        var seen: [LenovoDMIKey] = []
        let order = liveIndex.map { live in [live] + blocks.indices.filter { $0 != live } }
            ?? Array(blocks.indices)
        for index in order {
            for entry in blocks[index].entries where !seen.contains(entry.key) {
                seen.append(entry.key)
            }
        }
        return seen
    }

    /// What reads wrong in the area, worst first.
    public var findings: [LenovoDMIFinding] {
        var found: [LenovoDMIFinding] = []
        if blocks.allSatisfy(\.isBlank) {
            found.append(.wiped)
        } else if liveIndex == nil {
            found.append(.noUsableBlock)
        }
        for (index, block) in blocks.enumerated() {
            if block.isErased {
                found.append(.erased(block: index))
                continue
            }
            if !block.hasSignature {
                found.append(.missingSignature(block: index))
                continue
            }
            if block.isBlank { continue }
            if !block.checksumIsValid {
                found.append(.checksumMismatch(block: index, stored: block.checksum,
                                               computed: block.expectedChecksum))
            }
            if !block.entriesFit {
                found.append(.entriesDoNotFit(block: index))
            }
            if block.encoding == .plain {
                found.append(.storedInTheClear(block: index))
            }
        }
        if blocks.count == 2, blocks.allSatisfy(\.isUsable) {
            let differing = keys.filter { key in
                blocks[0].entry(key)?.data != blocks[1].entry(key)?.data
            }
            if !differing.isEmpty {
                found.append(.blocksDiffer(keys: differing))
            }
        }
        switch log.writeOffsetProblem {
        case .outOfRange?: found.append(.logWriteOffsetOutOfRange(log.writeOffset))
        case .misaligned?: found.append(.logWriteOffsetMisaligned(log.writeOffset))
        case .erased?, nil: break
        }
        return found
    }

    public init(offset: UInt64, log: LDBGLog, blocks: [LENVBlock]) {
        self.offset = offset
        self.log = log
        self.blocks = blocks
    }

    /// Reads the area whose log starts at `offset` of `image`. Nil when the
    /// image ends before the second block does.
    public static func read(_ image: [UInt8], at offset: Int) -> LenovoDMIArea? {
        guard offset >= 0, offset + Int(LenovoDMIFormat.areaSize) <= image.count else { return nil }
        let logEnd = offset + Int(LenovoDMIFormat.ldbgSize)
        let blocks = (0..<2).map { index -> LENVBlock in
            let start = logEnd + index * Int(LenovoDMIFormat.lenvSize)
            return LENVBlock(offset: UInt64(start),
                             stored: Array(image[start..<(start + Int(LenovoDMIFormat.lenvSize))]))
        }
        let log = LDBGLog(offset: UInt64(offset), stored: Array(image[offset..<logEnd]),
                          candidateKeys: blocks.filter(\.hasSignature).map(\.xorKey))
        return LenovoDMIArea(offset: UInt64(offset), log: log, blocks: blocks)
    }
}

/// Something about the area a technician should know before trusting it.
public enum LenovoDMIFinding: Equatable, Sendable {
    /// Both blocks are signed and empty: generation 0, no entries, nothing
    /// written. The board's identity is not here.
    case wiped
    /// Neither block is signed with a generation the firmware would use.
    case noUsableBlock
    case missingSignature(block: Int)
    /// The block's page is all `FF`: erased, and never written again.
    case erased(block: Int)
    case checksumMismatch(block: Int, stored: UInt16, computed: UInt16)
    /// The header's entry count runs past the end of the block under either
    /// reading.
    case entriesDoNotFit(block: Int)
    /// The block's body is not encoded although its key is not zero.
    case storedInTheClear(block: Int)
    /// The two blocks hold different values for these keys. Normal right after
    /// the firmware writes — it rewrites one copy at a time — and the reason a
    /// donor copy has to be read from the live block.
    case blocksDiffer(keys: [LenovoDMIKey])
    case logWriteOffsetOutOfRange(UInt32)
    case logWriteOffsetMisaligned(UInt32)

    /// A problem, as opposed to something worth knowing.
    public var isProblem: Bool {
        switch self {
        case .blocksDiffer, .storedInTheClear, .wiped: return false
        default: return true
        }
    }

    public var text: String {
        switch self {
        case .wiped:
            return L("Both LENV blocks are empty: the store has been wiped or was never written. The board's serial number and UUID are not in this image.")
        case .noUsableBlock:
            return L("Neither LENV block is one the firmware would read.")
        case .erased(let block):
            return L("LENV block %1$@ is erased: every byte is FF. The firmware reads the other copy.", block + 1)
        case .missingSignature(let block):
            return L("LENV block %1$@ has no signature where it should start.", block + 1)
        case .checksumMismatch(let block, let stored, let computed):
            return L("LENV block %1$@: the checksum is %2$@, the body adds up to %3$@.",
                     block + 1, LE.hex(UInt64(stored), digits: 4), LE.hex(UInt64(computed), digits: 4))
        case .entriesDoNotFit(let block):
            return L("LENV block %1$@: the entries its header counts do not fit in the block.", block + 1)
        case .storedInTheClear(let block):
            return L("LENV block %1$@ is stored decoded. Whether the firmware accepts that is not known.", block + 1)
        case .blocksDiffer(let keys):
            return L("The two LENV blocks hold different values for: %1$@. The firmware reads the block in use.",
                     keys.map(LenovoDMIValue.name(of:)).joined(separator: ", "))
        case .logWriteOffsetOutOfRange(let value):
            return L("The change log's write offset %1$@ is outside the log.", LE.hex(UInt64(value), digits: 8))
        case .logWriteOffsetMisaligned(let value):
            return L("The change log's write offset %1$@ does not fall on an entry boundary.", LE.hex(UInt64(value), digits: 8))
        }
    }
}

/// What an image holds of the store: whole areas — the log and both blocks —
/// and `LENV` blocks found on their own, outside any area.
///
/// A block on its own is what a fragment panel holds when a block was opened
/// out of the dump, decoded or as it is: the log and the other copy stayed
/// behind, and the block is still worth reading.
public struct LenovoDMIReading: Equatable, Sendable {
    public var areas: [LenovoDMIArea]
    public var blocks: [LENVBlock]

    public init(areas: [LenovoDMIArea], blocks: [LENVBlock]) {
        self.areas = areas
        self.blocks = blocks
    }

    public var isEmpty: Bool { areas.isEmpty && blocks.isEmpty }
}

public enum LenovoDMI {
    /// The areas in `image`, and every `LENV` block outside them whose header
    /// reads as one: signed, a whole page from its start, and holding entries
    /// that fit or nothing at all.
    public static func read(_ image: [UInt8]) -> LenovoDMIReading {
        let areas = locate(in: image)
        let size = Int(LenovoDMIFormat.lenvSize)
        let signature = LenovoDMIFormat.lenvSignature
        var blocks: [LENVBlock] = []
        image.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count >= size else { return }
            var start = 0
            while start + size <= buffer.count {
                guard let hit = memmem(base + start, buffer.count - start, signature, signature.count)
                else { break }
                let offset = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                start = offset + 1
                guard offset + size <= buffer.count,
                      !areas.contains(where: { $0.range.contains(UInt64(offset)) })
                else { continue }
                let block = LENVBlock(offset: UInt64(offset),
                                      stored: Array(buffer[offset..<(offset + size)]))
                // A stray `LENV` in a driver's code has a count that does not
                // parse under either reading; a block emptied has none.
                guard block.entriesFit && (block.declaredEntries > 0 || block.isBlank) else { continue }
                blocks.append(block)
                start = offset + size
            }
        }
        return LenovoDMIReading(areas: areas, blocks: blocks)
    }

    /// Every area in `image`: each `LDBG` signature followed by its write
    /// offset and eight zero bytes (upstream's pattern), with at least one of
    /// the two blocks signed where it should be.
    ///
    /// The second condition is what upstream does not check, and it is what
    /// keeps a stray `LDBG` in a driver's code from being taken for the store.
    public static func locate(in image: [UInt8]) -> [LenovoDMIArea] {
        let signature = LenovoDMIFormat.ldbgSignature
        let areaSize = Int(LenovoDMIFormat.areaSize)
        guard image.count >= areaSize else { return [] }
        var areas: [LenovoDMIArea] = []
        image.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start + areaSize <= buffer.count {
                guard let hit = memmem(base + start, buffer.count - start, signature, signature.count)
                else { break }
                let offset = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                start = offset + 1
                guard offset + areaSize <= buffer.count,
                      buffer[(offset + 8)..<(offset + 16)].allSatisfy({ $0 == 0 }),
                      let area = LenovoDMIArea.read(image, at: offset),
                      area.blocks.contains(where: \.hasSignature)
                else { continue }
                areas.append(area)
                start = offset + areaSize
            }
        }
        return areas
    }
}
