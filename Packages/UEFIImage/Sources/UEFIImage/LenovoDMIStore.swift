import Foundation
import LenovoDMI
import Localization

/// The store Lenovo's InsydeH2O firmware keeps a machine's identity in
/// (`UEFI_IMAGE_FORMAT.md` §9, `LenovoDMI`): the `LDBG` change log and the
/// two `LENV` blocks after it, back to back, 16 KiB in all. The Insyde flash
/// device map declares the three as regions of type "Unknown"; on a dump
/// without the map they lie in padding. Either way they are read here as one
/// row with the log and the blocks under it, and each block's entries under
/// the block — the format itself is `LenovoDMI`'s, so the tree and anything
/// else that reads the store read it one way.
///
/// The entries' bytes are XORed with the block's key in the file; the rows
/// are ranges of the file, as every row is, and what they hold decoded is the
/// panel's to show.
extension Parser {
    /// The store, or a block on its own, starts on a 4 KiB boundary of the
    /// file on every dump examined.
    static let lenovoDMIAlignment: UInt64 = 0x1000

    /// `nodes` with every Lenovo DMI store read out as a row: in place of the
    /// map regions that cover exactly its three parts, or out of the padding
    /// it lies in. A `LENV` block on its own — a block opened out of a dump —
    /// is read out of padding the same way.
    func readingLenovoDMIStores(_ nodes: [UEFINode], emptyByte: UInt8) -> [UEFINode] {
        var result: [UEFINode] = []
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            if let covered = mapRegionsCoveringStore(from: index, in: nodes) {
                result.append(covered.store)
                index += covered.count
                continue
            }
            index += 1
            guard node.kind == .padding || node.kind == .flashDeviceMapRegion else {
                result.append(node)
                continue
            }
            var read = node
            if !node.children.isEmpty {
                read.children = readingLenovoDMIStores(node.children, emptyByte: emptyByte)
            } else if !node.isErased, let rows = lenovoDMIRows(in: node.body, emptyByte: emptyByte) {
                read.children = rows
            }
            result.append(read)
        }
        return result
    }

    /// The store whose log the map region at `index` starts with, when that
    /// region and the ones after it cover the store exactly — the log, then
    /// each block, as the Insyde map declares them — and how many regions
    /// that is.
    private func mapRegionsCoveringStore(
        from index: Int, in nodes: [UEFINode]
    ) -> (store: UEFINode, count: Int)? {
        let first = nodes[index]
        guard first.kind == .flashDeviceMapRegion, first.children.isEmpty,
              let area = lenovoDMIArea(at: first.range.lowerBound)
        else { return nil }
        var end = first.range.upperBound
        var count = 1
        while end < area.range.upperBound, index + count < nodes.count {
            let next = nodes[index + count]
            guard next.kind == .flashDeviceMapRegion, next.children.isEmpty,
                  next.range.lowerBound == end
            else { return nil }
            end = next.range.upperBound
            count += 1
        }
        guard end == area.range.upperBound else { return nil }
        return (lenovoDMIStore(area), count)
    }

    /// The stores and lone blocks in `range`, with padding rows between them;
    /// nil when there is none.
    private func lenovoDMIRows(in range: Range<UInt64>, emptyByte: UInt8) -> [UEFINode]? {
        let step = Self.lenovoDMIAlignment
        var found: [UEFINode] = []
        var at = (range.lowerBound + step - 1) / step * step
        while at + LenovoDMIFormat.lenvSize <= range.upperBound {
            if let area = lenovoDMIArea(at: at, limit: range.upperBound) {
                found.append(lenovoDMIStore(area))
                at = area.range.upperBound
                continue
            }
            if let block = loneLENVBlock(at: at, limit: range.upperBound) {
                found.append(lenvBlock(block, name: L("LENV block"), inUse: nil))
                at = block.range.upperBound
                continue
            }
            at += step
        }
        guard !found.isEmpty else { return nil }
        var rows: [UEFINode] = []
        var claimed = range.lowerBound
        for node in found {
            rows += padding(from: claimed, to: node.range.lowerBound, emptyByte: emptyByte)
            rows.append(node)
            claimed = node.range.upperBound
        }
        return rows + padding(from: claimed, to: range.upperBound, emptyByte: emptyByte)
    }

    private func lenovoDMIArea(at offset: UInt64, limit: UInt64? = nil) -> LenovoDMIArea? {
        let size = LenovoDMIFormat.areaSize
        guard offset + size <= (limit ?? reader.count),
              reader.bytes(at: offset, count: 4) == LenovoDMIFormat.ldbgSignature,
              let stored = reader.bytes(at: offset, count: size)
        else { return nil }
        return LenovoDMIArea.found(stored: stored, offset: offset)
    }

    private func loneLENVBlock(at offset: UInt64, limit: UInt64) -> LENVBlock? {
        let size = LenovoDMIFormat.lenvSize
        guard offset + size <= limit,
              reader.bytes(at: offset, count: 4) == LenovoDMIFormat.lenvSignature,
              let stored = reader.bytes(at: offset, count: size)
        else { return nil }
        return LENVBlock.found(stored: stored, offset: offset)
    }

    /// The store's row: the log, then both blocks, the one the firmware reads
    /// marked by its subtype. The firmware finds the store where the map says
    /// it is, so none of it moves.
    func lenovoDMIStore(_ area: LenovoDMIArea) -> UEFINode {
        let live = area.liveIndex
        var store = UEFINode(kind: .lenovoDMIStore, name: L("Lenovo DMI"), range: area.range)
        store.isFixed = true
        store.children = [ldbgLog(area.log)] + area.blocks.enumerated().map { index, block in
            lenvBlock(block, name: L("LENV block %1$@", index + 1), inUse: live.map { $0 == index } ?? false)
        }
        return store
    }

    private func ldbgLog(_ log: LDBGLog) -> UEFINode {
        let header = log.offset..<(log.offset + UInt64(LenovoDMIFormat.ldbgHeaderSize))
        var node = UEFINode(
            kind: .ldbgLog,
            name: L("Change log (LDBG)"),
            header: header,
            body: header.upperBound..<log.range.upperBound,
            isFixed: true
        )
        node.children = log.entries.map { entry in
            UEFINode(
                kind: .ldbgEntry,
                subtype: entry.operation,
                name: entry.timestampText ?? "\(entry.index)",
                header: entry.range,
                body: entry.range.upperBound..<entry.range.upperBound,
                isFixed: true
            )
        }
        return node
    }

    /// A block's row, its subtype 1 for the block the firmware reads and 0
    /// for the other; none for a block on its own, which has no other to be
    /// chosen over. An erased block has no entries to show.
    func lenvBlock(_ block: LENVBlock, name: String, inUse: Bool?) -> UEFINode {
        let header = block.offset..<(block.offset + UInt64(LenovoDMIFormat.lenvHeaderSize))
        var node = UEFINode(
            kind: .lenvBlock,
            subtype: inUse.map { $0 ? 1 : 0 },
            name: name,
            header: header,
            body: header.upperBound..<block.range.upperBound,
            isFixed: true,
            isErased: block.isErased
        )
        guard block.hasSignature else { return node }
        node.children = block.entries.map { entry in
            UEFINode(
                kind: .lenvEntry,
                subtype: entry.flags,
                name: LenovoDMIValue.name(of: entry.key),
                header: entry.offset..<entry.dataRange.lowerBound,
                body: entry.dataRange,
                isFixed: true
            )
        }
        return node
    }
}
