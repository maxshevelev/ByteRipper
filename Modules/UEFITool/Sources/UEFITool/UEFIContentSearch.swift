import BytePattern
import Foundation
import LenovoDMI
import UEFIImage

/// A search through what a firmware's tree holds, not through the file as it
/// is stored (`Design/UEFI_STRUCTURE_TOOL.md`, "Searching the contents").
///
/// The file keeps a driver inside a compressed section, and its text is not
/// in the file's bytes for a search of the dump to find. This search opens
/// every container under the node it starts from, reads every compressed
/// section's decompressed bytes — and a BIOS Guard update's assembled region,
/// and a Lenovo LENV block stored XOR-encoded, decoded — and looks for the
/// pattern in each, as well as in the node's own bytes. Each match is placed
/// in the tree: the deepest node that holds it whole, and the volume that node
/// is in. An ME region is left out altogether, its bytes and what is under it:
/// it is another structure, read by the ME tools.
///
/// Not a step-by-step search: it runs to the end and hands back the list. The
/// same search asked again of the same bytes — the same tree, no edit since,
/// the same node, the same patterns — is answered with the last result, not
/// run again.
@MainActor
public enum UEFIContentSearch {
    /// One occurrence.
    public struct Match: Equatable, Sendable {
        /// Which of the patterns matched.
        public var pattern: Int
        /// The bytes it is in: the file, or what a compressed section
        /// decompressed to.
        public var space: ByteSpace
        /// Where, in `space`.
        public var range: Range<UInt64>
        /// The key, when the match is in a LENV block's decoded bytes — the
        /// file holds them XOR-encoded at the same addresses.
        public var decodedXORKey: UInt8?
        /// The deepest node holding the match whole; nil between the nodes of
        /// the top level.
        public var node: NodeID?
        /// The volume `node` is in, or is.
        public var volume: NodeID?
        /// From the volume's first byte, when the volume is in the same bytes
        /// as the match.
        public var volumeOffset: UInt64?
        /// From `node`'s first byte.
        public var nodeOffset: UInt64?
        /// The innermost compressed section whose decompressed bytes hold the
        /// match; nil for a match in the file.
        public var section: NodeID?
        /// The bytes around the match — `excerptPadding` either side where
        /// the bytes searched go that far — as they were searched: decoded
        /// for a LENV block, decompressed in a compressed section.
        public var excerpt: [UInt8] = []
        /// Where the match is in `excerpt`.
        public var excerptMatch: Range<Int> = 0..<0

        /// The match as file addresses; nil inside a compressed section.
        public var fileRange: Range<UInt64>? { space == .file ? range : nil }
    }

    public struct Result: Equatable, Sendable {
        /// The first matches, in tree order.
        public var matches: [Match]
        /// Every match, kept or not.
        public var total: Int
        /// How many bytes were searched, the decompressed ones included.
        public var searchedBytes: UInt64
        /// How many decompressed or decoded buffers were searched besides the
        /// node's own bytes.
        public var buffers: Int
        /// Compressed sections whose contents could not be read, and so were
        /// not searched.
        public var unreadSections: [NodeID]
    }

    /// What one pass of the scan reads: a stretch of one space, or of a LENV
    /// block decoded.
    struct Scope: Sendable {
        var space: ByteSpace
        var range: Range<UInt64>
        /// Decoded bytes standing in for the space's at `range`.
        var decoded: [UInt8]?
        var xorKey: UInt8?
        /// The node to place matches under; nil for the top of the tree.
        var base: NodeID?
        var section: NodeID?
        /// A stretch of the start's own bytes, not a buffer under it.
        var isOwn = false
    }

    /// How many bytes an excerpt shows either side of a match — as many as
    /// the dump's own search results show.
    nonisolated public static let excerptPadding: UInt64 = 8

    /// The most matches a search keeps; it goes on counting past them.
    nonisolated public static let defaultKeep = 10_000

    /// What the last search was asked, and what it answered.
    @MainActor private struct Asked {
        weak var tree: LazyUEFITree?
        var generation: Int
        var start: NodeID
        var patterns: [MaskedPattern]
        var overlapping: Bool
        var keep: Int
        var result: Result

        func answers(_ tree: LazyUEFITree, _ start: NodeID, _ patterns: [MaskedPattern],
                     _ overlapping: Bool, _ keep: Int) -> Bool {
            self.tree === tree && generation == tree.generation && self.start == start
                && self.patterns == patterns && self.overlapping == overlapping && self.keep >= keep
        }
    }

    private static var last: Asked?

    /// Whether a search of these is answered from the last one, without
    /// reading anything — for a test.
    static func isRemembered(_ patterns: [MaskedPattern], from start: NodeID, in tree: LazyUEFITree,
                             overlapping: Bool = false, keep: Int = defaultKeep) -> Bool {
        last?.answers(tree, start, patterns, overlapping, keep) == true
    }

    /// Whether `node` is an ME region, which the search leaves out.
    static func isMERegion(_ node: UEFINode) -> Bool {
        node.kind == .region && node.subtype == UInt8(FlashRegionType.me.rawValue)
    }

    /// Searches `start` — the whole image for `.root` — for `patterns`.
    /// `progress` hears how far the search is, from 0 to 1: the first half
    /// while the branches are opened, by where in the bytes the branch being
    /// opened is; the second by the share of the bytes searched. Throws
    /// `CancellationError` when the task is cancelled.
    public static func run(
        _ patterns: [MaskedPattern],
        from start: NodeID,
        in tree: LazyUEFITree,
        overlapping: Bool = false,
        keep: Int = defaultKeep,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> Result {
        if let last, last.answers(tree, start, patterns, overlapping, keep) {
            progress(1)
            var result = last.result
            result.matches = Array(result.matches.prefix(keep))
            return result
        }
        let generation = tree.generation
        let top: UEFINode?
        if start == .root {
            top = nil
        } else {
            _ = await UEFIAgentQueries.reachable(start, in: tree)
            guard let node = tree.node(start) else { throw UEFIContentSearchError.unknownNode(start) }
            top = node
        }
        var reached = 0.0
        await openEverything(under: top, in: tree) { share in
            guard share > reached else { return }
            reached = share
            progress(share / 2)
        }
        try Task.checkCancellation()
        let (scopes, unread) = scopes(from: top, in: tree)

        let readers = tree.spaceReaders
        let total = scopes.reduce(UInt64(0)) { $0 + UInt64($1.range.count) }
        let reportProgress: @Sendable (Double) -> Void = { share in
            Task { @MainActor in progress(0.5 + share / 2) }
        }
        typealias Found = (scope: Int, pattern: Int, range: Range<UInt64>, excerpt: [UInt8], at: Range<Int>)
        let padding = excerptPadding
        let scan = Task.detached(priority: .userInitiated) { () throws -> (found: [Found], count: Int) in
            var found: [Found] = []
            var count = 0
            var done: UInt64 = 0
            for (index, scope) in scopes.enumerated() {
                try Task.checkCancellation()
                let read: (UInt64, Int) throws -> [UInt8]
                if let decoded = scope.decoded {
                    let base = scope.range.lowerBound
                    read = { offset, length in
                        let from = Int(offset - base)
                        return Array(decoded[from..<min(decoded.count, from + length)])
                    }
                } else if let reader = readers.reader(for: scope.space) {
                    read = { offset, length in reader.bytes(at: offset, count: UInt64(length)) ?? [] }
                } else {
                    continue
                }
                try PatternScan.matches(
                    of: patterns, size: scope.range.upperBound, range: scope.range, overlapping: overlapping,
                    read: read, shouldCancel: { Task.isCancelled }
                ) { range, pattern in
                    count += 1
                    // Gathered past `keep` while the order is not yet known:
                    // the tree's order is decided once every buffer is in.
                    if found.count < max(keep * 4, 250_000) {
                        let from = max(scope.range.lowerBound, range.lowerBound >= padding ? range.lowerBound - padding : 0)
                        let to = min(scope.range.upperBound, range.upperBound + padding)
                        let excerpt = (try? read(from, Int(to - from))) ?? []
                        let at = Int(range.lowerBound - from)..<Int(range.upperBound - from)
                        found.append((index, pattern, range, excerpt, at))
                    }
                    return true
                }
                done += UInt64(scope.range.count)
                if total > 0 { reportProgress(Double(done) / Double(total)) }
            }
            return (found, count)
        }
        let scanned = try await withTaskCancellationHandler {
            try await scan.value
        } onCancel: {
            scan.cancel()
        }

        var matches = scanned.found.map { found in
            var match = place(found.range, pattern: found.pattern, scope: scopes[found.scope], in: tree)
            match.excerpt = found.excerpt
            match.excerptMatch = found.at
            return match
        }
        matches.sort(by: treeOrder)
        let result = Result(
            matches: Array(matches.prefix(keep)),
            total: scanned.count,
            searchedBytes: total,
            buffers: scopes.filter { !$0.isOwn }.count,
            unreadSections: unread)
        // Remembered only when the bytes did not move under the search.
        if tree.generation == generation {
            last = Asked(tree: tree, generation: generation, start: start, patterns: patterns,
                         overlapping: overlapping, keep: keep, result: result)
        }
        return result
    }

    // MARK: - What is searched

    /// Opens every closed container at or under `node` — the whole tree for
    /// nil — depth first, so the place in the file of the branch being opened
    /// only moves on: `progress` hears it as a share of the node's bytes.
    static func openEverything(under node: UEFINode?, in tree: LazyUEFITree,
                               progress: (Double) -> Void = { _ in }) async {
        let span = node?.fileRange ?? fileRange(of: node, in: tree) ?? 0..<max(1, tree.imageReader.count)
        var stack = Array((node.map { [$0] } ?? tree.rootNodes).reversed())
        while let next = stack.popLast() {
            if Task.isCancelled { return }
            if isMERegion(next) { continue }
            if next.isExpandable, let at = fileRange(of: next, in: tree)?.lowerBound, span.count > 0 {
                let inside = min(max(at, span.lowerBound), span.upperBound)
                progress(Double(inside - span.lowerBound) / Double(span.count))
            }
            let children = next.isExpandable ? await UEFIAgentQueries.expanded(next.id, in: tree) : next.children
            stack.append(contentsOf: children.reversed())
        }
        progress(1)
    }

    /// Where `node`'s bytes are in the file: its own range, or for a node in
    /// decompressed bytes the compressed section's they came out of.
    static func fileRange(of node: UEFINode?, in tree: LazyUEFITree) -> Range<UInt64>? {
        guard let node else { return nil }
        if let range = node.fileRange { return range }
        var path = node.id.path
        while !path.isEmpty {
            path.removeLast()
            if let range = tree.node(NodeID(path))?.fileRange { return range }
        }
        return nil
    }

    /// The stretches to scan: the start's own bytes, then every buffer under
    /// it in tree order — and the compressed sections that would not open.
    static func scopes(from top: UEFINode?, in tree: LazyUEFITree) -> ([Scope], [NodeID]) {
        var scopes: [Scope] = []
        var unread: [NodeID] = []
        let readers = tree.spaceReaders
        // The start's own bytes, but for the ME regions in them.
        let space = top?.space ?? .file
        let whole = top?.range ?? 0..<tree.imageReader.count
        var left: [UInt64] = []
        func gatherME(_ nodes: [UEFINode]) {
            for node in nodes where node.space == space {
                if isMERegion(node) {
                    left.append(contentsOf: [node.range.lowerBound, node.range.upperBound])
                } else {
                    gatherME(node.children)
                }
            }
        }
        if let top, isMERegion(top) { return ([], []) }
        gatherME(top.map { [$0] } ?? tree.rootNodes)
        var from = whole.lowerBound
        var cuts = stride(from: 0, to: left.count, by: 2).map { left[$0]..<left[$0 + 1] }
        cuts.sort { $0.lowerBound < $1.lowerBound }
        for cut in cuts + [whole.upperBound..<whole.upperBound] {
            let to = min(max(cut.lowerBound, from), whole.upperBound)
            if to > from {
                scopes.append(Scope(space: space, range: from..<to, base: top?.id,
                                    section: top.flatMap { enclosingSection(of: $0, in: tree) }, isOwn: true))
            }
            from = max(from, cut.upperBound)
        }
        let fileReader = readers.reader(for: .file)
        let image = tree.image()
        func visit(_ node: UEFINode) {
            if isMERegion(node) { return }
            if let body = UEFIPresenter.decompressedBody(for: node) {
                if let reader = readers.reader(for: body.space), reader.count > 0 {
                    scopes.append(Scope(space: body.space, range: 0..<reader.count, base: node.id, section: node.id))
                } else {
                    unread.append(node.id)
                }
            }
            if node.kind == .lenvBlock, let fileReader,
               let found = UEFILenovoDMIDetail.decodableBlock(for: node, image: image, reader: fileReader),
               found.block.encoding == .encoded {
                scopes.append(Scope(space: .file, range: node.range,
                                    decoded: LenovoDMIDecodedBlock.decode(found.block),
                                    xorKey: found.block.xorKey, base: node.id, section: nil))
            }
            node.children.forEach(visit)
        }
        if let top { visit(top) } else { tree.rootNodes.forEach(visit) }
        return (scopes, unread)
    }

    /// The innermost compressed section above `node`, for a node whose bytes
    /// are decompressed ones.
    static func enclosingSection(of node: UEFINode, in tree: LazyUEFITree) -> NodeID? {
        guard node.space != .file else { return nil }
        var path = node.id.path
        while !path.isEmpty {
            path.removeLast()
            if let above = tree.node(NodeID(path)), UEFIPresenter.decompressedBody(for: above)?.space == node.space {
                return above.id
            }
        }
        return nil
    }

    // MARK: - Where a match is

    static func place(_ range: Range<UInt64>, pattern: Int, scope: Scope, in tree: LazyUEFITree) -> Match {
        var match = Match(pattern: pattern, space: scope.space, range: range, decodedXORKey: scope.xorKey,
                          section: scope.section)
        // Down from the scope's node through the children in the match's
        // bytes — for a compressed section, the children its buffer holds.
        var current: UEFINode? = scope.base.flatMap(tree.node)
        var children = current?.children ?? tree.rootNodes
        while let child = children.first(where: {
            $0.space == scope.space && !$0.range.isEmpty
                && $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound
        }) {
            current = child
            children = child.children
        }
        guard let node = current else { return match }
        match.node = node.id
        if node.space == scope.space { match.nodeOffset = range.lowerBound - node.range.lowerBound }
        var path = node.id.path
        while !path.isEmpty {
            if let above = tree.node(NodeID(path)), above.kind == .volume {
                match.volume = above.id
                if above.space == scope.space, above.range.lowerBound <= range.lowerBound {
                    match.volumeOffset = range.lowerBound - above.range.lowerBound
                }
                break
            }
            path.removeLast()
        }
        return match
    }

    /// The tree's order: by the node, outermost index first, and in one node
    /// by where the match is.
    static func treeOrder(_ a: Match, _ b: Match) -> Bool {
        let left = a.node?.path ?? [], right = b.node?.path ?? []
        if left != right { return left.lexicographicallyPrecedes(right) }
        if a.range.lowerBound != b.range.lowerBound { return a.range.lowerBound < b.range.lowerBound }
        return a.pattern < b.pattern
    }
}

public enum UEFIContentSearchError: Error, Equatable {
    case unknownNode(NodeID)
}
