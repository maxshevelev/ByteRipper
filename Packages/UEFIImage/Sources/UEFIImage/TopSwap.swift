import Foundation

/// The Top Swap backup of the block the FIT lives in (`UEFI_IMAGE_FORMAT.md`
/// §11).
///
/// A chipset with Top Swap set maps the block directly below the top block of
/// the BIOS region at the top of memory instead, so a board can start from a
/// second copy of its boot block while the first is being rewritten. Such an
/// image carries the top block twice — the same volumes, microcode and ACM, and
/// a FIT of its own at the same place in the block naming the same addresses.
///
/// The block's size is a chipset strap whose place in the descriptor moves
/// from one PCH generation to the next, so the copy is recognised by what it has
/// to hold instead: the FIT pointer with the same value, and the `_FIT_` table
/// at the same distance below.
///
/// Here rather than in the FIT tool-module because the structure panel names
/// the copy too; the module adds the editing.
public struct TopSwapCopy: Equatable, Sendable {
    /// The top block, ending where the address space does.
    public var top: Range<UInt64>
    /// Its copy, directly below.
    public var backup: Range<UInt64>

    public init(top: Range<UInt64>, backup: Range<UInt64>) {
        self.top = top
        self.backup = backup
    }

    public var size: UInt64 { top.upperBound - top.lowerBound }

    /// Where the FIT pointer is (`FIT_TABLE_FORMAT.md` §2).
    static let fitPointerAddress: UInt64 = 0xFFFF_FFC0
    /// `_FIT_   `.
    static let fitSignature: UInt64 = 0x2020_205F_5449_465F
    /// The sizes a Top Swap block comes in: a power of two from 64 KiB to 16 MiB.
    static let smallestBlock: UInt64 = 0x1_0000
    static let largestBlock: UInt64 = 0x100_0000

    /// The backup of the block holding the FIT, given where the pointer is,
    /// what it says, and where the table it leads to lies — or nil when the
    /// image has no such copy.
    public static func find(
        pointerOffset: UInt64,
        pointerAddress: UInt64,
        table: Range<UInt64>,
        in reader: ImageReader
    ) -> TopSwapCopy? {
        let topEnd = pointerOffset + (0x1_0000_0000 - fitPointerAddress)
        var size = smallestBlock
        while size <= largestBlock, size * 2 <= topEnd {
            let top = (topEnd - size)..<topEnd
            if top.lowerBound <= table.lowerBound, table.upperBound <= top.upperBound,
               reader.uint32(at: pointerOffset - size).map(UInt64.init) == pointerAddress,
               reader.uint64(at: table.lowerBound - size) == fitSignature {
                return TopSwapCopy(top: top, backup: (top.lowerBound - size)..<top.lowerBound)
            }
            size *= 2
        }
        return nil
    }

    /// The copy in `image`, found through its FIT, or nil when the image has
    /// no addresses yet, no FIT, or no copy.
    public static func find(in image: UEFIImage, reader: ImageReader) -> TopSwapCopy? {
        guard let pointer = image.offset(forAddress: fitPointerAddress),
              let address = reader.uint32(at: pointer).map(UInt64.init),
              let table = image.offset(forAddress: address),
              reader.uint64(at: table) == fitSignature
        else { return nil }
        return find(pointerOffset: pointer, pointerAddress: address, table: table..<(table + 16), in: reader)
    }

    /// Where an offset is once the blocks trade places: a byte of either block
    /// is the same byte of the other, and everything else stays put.
    public func swap(_ offset: UInt64) -> UInt64 {
        if top.contains(offset) { return offset - size }
        if backup.contains(offset) { return offset + size }
        return offset
    }

    /// Whether the two copies are the same bytes.
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
}
