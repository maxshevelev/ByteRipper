import Foundation
import ToolModuleKit

/// The zones the panel publishes while a tree row is selected — one focused
/// zone for the row's bytes, `.empty` when the row (or nothing) is picked.
/// A row without bytes of its own (a manifest, a group) never zones; only rows
/// that stand for real file bytes do — one stretch, or an MFS or EFS file's
/// chunks wherever the volume put them (#31).
public enum MEAZones {
    /// The zone map for `focus`: a single zone whose id is the node's path (the
    /// same identity a parked selection keeps) — over the node's byte range, or
    /// over a file's extents in the file's order. `.empty` when the node has
    /// neither.
    public static func build(focus: MEANode?) -> ZoneMap {
        guard let node = focus else { return .empty }
        let ranges: [Range<UInt64>]
        if let range = node.range {
            ranges = [range]
        } else if let extents = node.extents?.filter({ !$0.isEmpty }), !extents.isEmpty {
            ranges = extents
        } else {
            return .empty
        }
        let id = node.path.map(String.init).joined(separator: "/")
        let zone = Zone(id: id, name: node.title.isEmpty ? "(unnamed)" : node.title,
                        ranges: ranges)
        return ZoneMap(zones: [zone], focus: id)
    }

    /// The zone-map identity of a row — its tree path as one id string. What a
    /// parked session stores to re-find a selection after a re-parse.
    public static func id(of node: MEANode) -> String {
        node.path.map(String.init).joined(separator: "/")
    }
}
