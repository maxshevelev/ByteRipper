import AgentKit
import Foundation
import UEFIImage

/// A match of the search through what the tree holds (`UEFIContentSearch`), as
/// an agent reads it: `find_bytes` with `node` — the node and everything under
/// it, decompressed and decoded — answers each match in this shape.
@MainActor
public enum UEFIAgentContentSearch {
    /// One match: `node` (as `uefi_tree` gives it) and `node_offset`,
    /// `volume` and `volume_offset`, `start`/`end` in the file — or
    /// `in_compressed`, `buffer_start`/`buffer_end` and the `section` whose
    /// decompressed bytes hold it — and `decoded` for a LENV block decoded.
    public static func entry(for match: UEFIContentSearch.Match, encoding: String, in tree: LazyUEFITree) -> JSONValue {
        var members: [String: JSONValue] = ["encoding": .string(encoding)]
        if let node = match.node.flatMap(tree.node) {
            members["node"] = UEFIAgentQueries.summary(of: node, in: tree)
        }
        if let offset = match.nodeOffset { members["node_offset"] = .string(offset.hexNumber) }
        if let volume = match.volume.flatMap(tree.node) {
            members["volume"] = ["id": .string(volume.id.description),
                                 "label": .string(UEFIAgentQueries.label(of: volume, in: tree))]
        }
        if let offset = match.volumeOffset { members["volume_offset"] = .string(offset.hexNumber) }
        if let range = match.fileRange {
            members["start"] = .string(range.lowerBound.hexNumber)
            members["end"] = .string(range.upperBound.hexNumber)
        } else {
            members["in_compressed"] = true
            members["buffer_start"] = .string(match.range.lowerBound.hexNumber)
            members["buffer_end"] = .string(match.range.upperBound.hexNumber)
        }
        if let section = match.section { members["section"] = .string(section.description) }
        if let key = match.decodedXORKey { members["decoded"] = .string(String(format: "XOR %02X", key)) }
        return .object(members)
    }
}
