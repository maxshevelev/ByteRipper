import Foundation
import ToolModuleKit
import UEFIImage

/// Where ranges of the file are in the UEFI structure, for answers that are
/// not the module's own — the runs a byte comparison found
/// (`ToolAgentLocator`, `Design/AGENT_PLAN.md` stage 8).
///
/// The areas are the parts of the image a reader names first: the
/// descriptor's regions, and inside the BIOS region its volumes and the
/// padding between them — the children of the region in `uefi_tree`. A
/// range is placed by the chain of nodes holding its first byte and the chain
/// holding its last, opened as `uefi_at` opens them: the deepest node the two
/// share covers the range whole. Nodes inside a compressed section have no
/// file address, so a range there is placed at the compressed section.
@MainActor
public enum UEFIAgentLocator {
    nonisolated public static let locator = ToolAgentLocator(
        precedence: 0,
        areas: { host in
            guard let tree = try? await UEFIAgentQueries.readyTree(host) else { return [] }
            return await areas(in: tree).map(place)
        },
        locate: { host, ranges in
            guard let tree = try? await UEFIAgentQueries.readyTree(host) else { return ranges.map { _ in [] } }
            let areaIDs = Set(await areas(in: tree).map(\.id))
            var result: [[ToolAgentPlace]] = []
            for range in ranges {
                result.append(await locate(range, in: tree, areas: areaIDs))
            }
            return result
        }
    )

    /// The top-level parts of the image, in address order.
    static func areas(in tree: LazyUEFITree) async -> [UEFINode] {
        var result: [UEFINode] = []
        func walk(_ nodes: [UEFINode]) async {
            for node in nodes where node.fileRange != nil {
                switch node.kind {
                case .capsule, .intelImage, .uefiImage:
                    await walk(await UEFIAgentQueries.expanded(node.id, in: tree))
                case .region where node.subtype == UInt8(FlashRegionType.bios.rawValue)
                    || node.subtype == UInt8(FlashRegionType.bios2.rawValue):
                    let children = await UEFIAgentQueries.expanded(node.id, in: tree).filter { $0.fileRange != nil }
                    if children.isEmpty { result.append(node) } else { result += children }
                default:
                    result.append(node)
                }
            }
        }
        await walk(tree.rootNodes)
        return result.sorted { ($0.fileRange?.lowerBound ?? 0) < ($1.fileRange?.lowerBound ?? 0) }
    }

    /// The area `range` is in and the deepest node covering it whole; one
    /// place when the two are the same node, none when no node covers it.
    static func locate(_ range: Range<UInt64>, in tree: LazyUEFITree, areas: Set<NodeID>) async -> [ToolAgentPlace] {
        guard !range.isEmpty else { return [] }
        let first = await chain(containing: range.lowerBound, in: tree)
        let last = range.count == 1 ? first : await chain(containing: range.upperBound - 1, in: tree)
        var shared: [UEFINode] = []
        for (a, b) in zip(first, last) {
            guard a.id == b.id else { break }
            shared.append(a)
        }
        guard let deepest = shared.last else { return [] }
        let area = shared.first { areas.contains($0.id) }
        if let area, area.id != deepest.id { return [place(area), place(deepest)] }
        return [place(deepest)]
    }

    private static func chain(containing offset: UInt64, in tree: LazyUEFITree) async -> [UEFINode] {
        await withCheckedContinuation { continuation in
            tree.materialize(containing: offset) { continuation.resume(returning: $0) }
        }
    }

    static func place(_ node: UEFINode) -> ToolAgentPlace {
        ToolAgentPlace(kind: "uefi", id: node.id.description,
                       name: UEFITreeDisplay.ownName(of: node) ?? node.name, range: node.fileRange)
    }
}
