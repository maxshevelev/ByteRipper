import Foundation
import MEPresentation
import ToolModuleKit

/// Where ranges of the ME region are in the structure the ME engine decoded,
/// for answers that are not the module's own — the runs a byte comparison
/// found (`ToolAgentLocator`, `Design/AGENT_PLAN.md` stage 8).
///
/// Finer than the UEFI tree inside the ME region, so it wins there
/// (`precedence` 1). The areas are the partition table's entries — of the
/// top groups of `me_tree`, the one whose rows with bytes cover the most of
/// the file. A range is placed in the area that covers it and at the
/// smallest node of the whole tree that covers it whole. Inside a file system
/// it goes one further: an MFS or EFS file has no one range, its bytes are
/// scattered over the volume's pages, so a range is placed at the file when
/// that file is the only one whose stored bytes it touches — what else it
/// touches is the volume's own bookkeeping, a chunk's CRC or a page's header.
/// Nothing is analysed for a range outside the ME region, nor for a file with
/// none.
@MainActor
public enum MEAAgentLocator {
    nonisolated public static let locator = ToolAgentLocator(
        precedence: 1,
        areas: { host in
            guard let roots = await roots(host) else { return [] }
            return areas(in: roots).map(place)
        },
        locate: { host, ranges in
            let none = ranges.map { _ -> [ToolAgentPlace] in [] }
            guard let region = await MEAAgentQueries.region(host),
                  ranges.contains(where: { $0.overlaps(region) }),
                  let roots = await roots(host)
            else { return none }
            let areas = areas(in: roots)
            let all = flattened(roots)
            let nodes = all.filter { $0.range != nil }
            let files = FileIndex(all.filter { $0.extents?.isEmpty == false })
            return ranges.map { range in
                guard range.overlaps(region) else { return [] }
                let covering = nodes.filter { $0.range!.lowerBound <= range.lowerBound && range.upperBound <= $0.range!.upperBound }
                guard var deepest = covering.min(by: { a, b in
                    a.range!.count != b.range!.count ? a.range!.count < b.range!.count : a.path.count > b.path.count
                }) else { return [] }
                // The file, when the range stays inside the partition the file
                // is in: a run past it touches the file and much besides.
                if let file = files.only(touching: range), let extents = file.extents,
                   let lower = extents.map(\.lowerBound).min(), let upper = extents.map(\.upperBound).max(),
                   let home = nodes.filter({ $0.range!.lowerBound <= lower && upper <= $0.range!.upperBound })
                       .min(by: { $0.range!.count < $1.range!.count }),
                   home.range!.lowerBound <= range.lowerBound, range.upperBound <= home.range!.upperBound {
                    deepest = file
                }
                let area = areas.first { $0.range!.lowerBound <= range.lowerBound && range.upperBound <= $0.range!.upperBound }
                if let area, area.path != deepest.path { return [place(area), place(deepest)] }
                return [place(deepest)]
            }
        }
    )

    /// The decoded tree, or nil for a file with no ME region the descriptor
    /// names, or one the engine could not read.
    private static func roots(_ host: any ToolReadHost) async -> [MEANode]? {
        guard await MEAAgentQueries.region(host) != nil,
              let analysis = try? await MEAAgentQueries.analysis(host) else { return nil }
        return await MEAAgentQueries.present(analysis)
    }

    /// The partition table's rows: of the top groups, the one whose rows with
    /// bytes cover the most, those rows in address order, an overlapping one
    /// left out.
    static func areas(in roots: [MEANode]) -> [MEANode] {
        func rows(_ group: MEANode) -> [MEANode] { group.children.filter { $0.range != nil } }
        func coverage(_ group: MEANode) -> UInt64 { rows(group).reduce(0) { $0 + UInt64($1.range!.count) } }
        guard let table = roots.max(by: { coverage($0) < coverage($1) }), coverage(table) > 0 else { return [] }
        var result: [MEANode] = []
        for row in rows(table).sorted(by: { $0.range!.lowerBound < $1.range!.lowerBound }) where !row.range!.isEmpty {
            if let last = result.last, last.range!.upperBound > row.range!.lowerBound { continue }
            result.append(row)
        }
        return result
    }

    /// The file rows' stretches in address order, so a range finds the files
    /// it touches without a pass over every chunk of every file.
    struct FileIndex {
        private let stretches: [(range: Range<UInt64>, file: Int)]
        private let files: [MEANode]

        init(_ files: [MEANode]) {
            self.files = files
            stretches = files.enumerated()
                .flatMap { index, file in file.extents!.map { ($0, index) } }
                .sorted { $0.0.lowerBound < $1.0.lowerBound }
        }

        /// The one file whose stretches `range` overlaps; nil when it touches
        /// none, or more than one.
        func only(touching range: Range<UInt64>) -> MEANode? {
            var low = 0
            var high = stretches.count
            while low < high {
                let mid = (low + high) / 2
                if stretches[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
            }
            // Stretches never overlap, so from the first one ending after the
            // range starts, every one that starts before it ends is touched.
            var found: Int?
            for stretch in stretches[low...] {
                guard stretch.range.lowerBound < range.upperBound else { break }
                guard stretch.range.overlaps(range) else { continue }
                if let found, found != stretch.file { return nil }
                found = stretch.file
            }
            return found.map { files[$0] }
        }
    }

    private static func flattened(_ nodes: [MEANode]) -> [MEANode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }

    static func place(_ node: MEANode) -> ToolAgentPlace {
        ToolAgentPlace(kind: "me", id: MEAAgentQueries.id(node.path), name: node.title, range: node.range)
    }
}
