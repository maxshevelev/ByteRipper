import Foundation

/// The one place a collapsed node's children are computed from the bytes.
///
/// The parser never opens the two containers that cost a scan — a raw-area
/// region and a volume's body — so what `Parser` returns is always a tree with
/// holes in it. Filling one is this type's whole job, and both drivers go
/// through it: `LazyUEFITree`, which fills one node at a time off the main
/// actor as something asks for it, and `UEFIParser.parse(_:)`, which fills
/// every one of them in a row and hands back the finished `UEFIImage` a test
/// or an oracle comparison wants.
///
/// Free of state of its own — every function takes the reader and gives back
/// what it computed — so a `Task.detached` can call it without carrying an
/// object across the isolation boundary.
enum TreeMaterialization {
    /// Nodes, and whatever the parse of them had to complain about. The
    /// diagnostics travel with the nodes because a lazy tree accumulates them
    /// as it expands: a volume's "unknown file system" is not known until
    /// something opens that volume.
    /// `Sendable` because a lazy tree computes one of these off the main actor
    /// and hands it back when it lands.
    struct Result: Sendable {
        var nodes: [UEFINode]
        var diagnostics: [UEFIDiagnostic]
    }

    /// The top level, and nothing below it that can be deferred: a capsule's
    /// envelope, an Intel image's regions, or — for an image with no
    /// descriptor — the raw-area scan that decides what the top level even is.
    ///
    /// That last one is the one case where "the top level" costs a walk of the
    /// whole file: nothing announces the structures in a plain chip dump but
    /// the signatures inside it, so they have to be looked for before there is
    /// anything to show. It is why a caller builds this off the main actor.
    ///
    /// `layout` is what the bytes are when that is known from outside them — a
    /// part of another image opened on its own (`UEFIRootLayout`). A layout the
    /// bytes do not bear out falls back to reading them as an image, with the
    /// failed attempt's complaints left out.
    static func roots(
        reader: ImageReader,
        limits: UEFIParser.Limits,
        layout: UEFIRootLayout = .image,
        progress: ProgressSink? = nil
    ) -> Result {
        guard reader.count > 0 else { return Result(nodes: [], diagnostics: []) }
        let parser = Parser(reader: reader, limits: limits, progress: progress)
        let empty = Parser.defaultEmptyByte
        switch layout {
        case .image:
            break
        case .volume:
            if let volume = parser.parseVolume(at: 0, limit: reader.count, depth: 0) {
                let nodes = [volume] + parser.padding(
                    from: volume.range.upperBound, to: reader.count, emptyByte: empty
                )
                return Result(nodes: nodes, diagnostics: parser.diagnostics)
            }
        case .file(let ffsVersion, let volumeRevision):
            if let file = parser.parseFile(
                at: 0, limit: reader.count, ffsVersion: ffsVersion,
                volumeRevision: volumeRevision, depth: 0
            ) {
                let nodes = [file.node] + parser.padding(
                    from: file.size, to: reader.count, emptyByte: empty
                )
                return Result(nodes: nodes, diagnostics: parser.diagnostics)
            }
        case .sections(let ffsVersion):
            let nodes = parser.walkSections(
                reader.all, ffsVersion: ffsVersion, emptyByte: empty, depth: 0
            )
            return Result(nodes: nodes, diagnostics: parser.diagnostics)
        }
        let image = layout == .image
            ? parser
            : Parser(reader: reader, limits: limits, progress: progress)
        let nodes = image.parseTopLevel(reader.all, depth: 0)
        return Result(nodes: nodes, diagnostics: image.diagnostics)
    }

    /// One collapsed node's children, parsed at the depth the node itself
    /// recorded when it was left closed (`UEFINode.childDepth`) — so a node
    /// expanded now lands exactly where an all-at-once parse would have put
    /// it, recursion limit included.
    ///
    /// `reader` is the file's. A node inside a compressed section is read from
    /// the buffer its space names, which `buffers` holds or decodes.
    static func children(
        of node: UEFINode,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        buffers: DecompressedBuffers,
        progress: ProgressSink? = nil
    ) -> Result {
        guard node.isExpandable else { return Result(nodes: [], diagnostics: []) }
        let spaceReader: ImageReader
        switch buffers.reader(for: node.space, file: reader, limit: limits.maxDecompressedSize) {
        case .success(let found):
            spaceReader = found
        case .failure:
            // The section holding this node no longer decodes. The expansion
            // that failed to open it has already said so, at the section.
            return Result(nodes: [], diagnostics: [])
        }
        // Progress is a fraction of the file, which a buffer's offsets are not.
        let parser = Parser(
            reader: spaceReader, limits: limits,
            progress: node.space == .file ? progress : nil
        )
        let nodes: [UEFINode]
        switch node.kind {
        case .volume:
            guard let header = parser.readVolumeHeader(at: node.header.lowerBound) else {
                return Result(
                    nodes: [],
                    diagnostics: parser.diagnostics.map { $0.located(in: node.space) }
                )
            }
            nodes = parser.volumeChildren(header, body: node.body, depth: node.childDepth)
        case .region:
            nodes = parser.scanRawArea(
                node.body, emptyByte: Parser.defaultEmptyByte, depth: node.childDepth
            )
        case .section:
            return decompressedChildren(
                of: node, in: spaceReader, file: reader, limits: limits, buffers: buffers
            )
        default:
            // Nothing else is ever left collapsed, so this is unreachable in
            // practice — and answering "no children" is the honest reading of
            // a node the parser did not gate.
            return Result(nodes: [], diagnostics: [])
        }
        return Result(
            nodes: stamping(nodes, space: node.space),
            diagnostics: parser.diagnostics.map { $0.located(in: node.space) }
        )
    }

    /// A compressed section's children: its body decoded, and the decoded
    /// bytes walked as the run of sections they are — by the same
    /// `walkSections` a file's body goes through, over a reader of the buffer
    /// (`COMPRESSED_SECTIONS.md` §6.1).
    ///
    /// FFSv3's rules inside: a buffer has no volume of its own to say which
    /// revision it follows, and the extended section size is the one thing the
    /// two revisions read differently.
    private static func decompressedChildren(
        of section: UEFINode,
        in parentReader: ImageReader,
        file: ImageReader,
        limits: UEFIParser.Limits,
        buffers: DecompressedBuffers
    ) -> Result {
        let childSpace = section.space.inside(sectionAt: section.header.lowerBound)
        let buffer: ImageReader
        switch buffers.reader(for: childSpace, file: file, limit: limits.maxDecompressedSize) {
        case .success(let found):
            buffer = found
        case .failure(let problem):
            let algorithm = problem.algorithm?.name ?? "Compressed"
            let kind: UEFIDiagnostic.Kind
            switch problem.failure {
            case .tooLarge(let declared):
                kind = .decompressedTooLarge(algorithm: algorithm, declared: declared)
            case .truncated:
                kind = .decompressionFailed(algorithm: algorithm, truncated: true)
            case .corrupt:
                kind = .decompressionFailed(algorithm: algorithm, truncated: false)
            }
            return Result(
                nodes: [],
                diagnostics: [UEFIDiagnostic(kind, at: problem.section).located(in: problem.space)]
            )
        }

        var diagnostics: [UEFIDiagnostic] = []
        if let declared = CompressedSection.locate(
            at: section.header.lowerBound, in: parentReader
        )?.declaredLength, declared != buffer.count {
            diagnostics.append(UEFIDiagnostic(
                .decompressedSizeMismatch(stored: declared, computed: buffer.count),
                at: section.header.lowerBound
            ).located(in: section.space))
        }

        let parser = Parser(reader: buffer, limits: limits)
        let nodes = parser.walkSections(
            buffer.all, ffsVersion: 3, emptyByte: Parser.defaultEmptyByte,
            depth: section.childDepth
        )
        diagnostics += parser.diagnostics.map { $0.located(in: childSpace) }
        return Result(nodes: stamping(nodes, space: childSpace), diagnostics: diagnostics)
    }

    /// Puts `space` on every node a parse over that space's reader built. The
    /// parser itself never knows which space it is reading: a buffer is one
    /// more `ByteSource` to it.
    static func stamping(_ nodes: [UEFINode], space: ByteSpace) -> [UEFINode] {
        guard space != .file else { return nodes }
        return nodes.map { node in
            var stamped = node
            stamped.space = space
            stamped.children = stamping(node.children, space: space)
            return stamped
        }
    }

    /// Fills in `node`'s children in place and marks it materialized. The node
    /// keeps its `isExpandable` only while its children are still unknown, so
    /// a node that turned out to hold nothing does not go on offering a
    /// disclosure triangle for the rest of the session.
    static func expand(
        _ node: inout UEFINode,
        at id: NodeID,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        buffers: DecompressedBuffers,
        diagnostics: inout [UEFIDiagnostic],
        progress: ProgressSink? = nil
    ) {
        let result = children(
            of: node, reader: reader, limits: limits, buffers: buffers, progress: progress
        )
        node.children = stampIDs(result.nodes, under: id)
        node.isExpandable = false
        diagnostics += result.diagnostics
    }

    /// Opens every collapsed node there is, depth first — the whole tree, as
    /// the parser would have built it in one pass if it opened everything on
    /// the way down.
    ///
    /// `opensCompressed: false` leaves compressed sections shut: every volume's
    /// files and sections, and nothing that has to be decoded to be read.
    static func materializeAll(
        _ nodes: inout [UEFINode],
        under parent: NodeID = .root,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        buffers: DecompressedBuffers,
        diagnostics: inout [UEFIDiagnostic],
        opensCompressed: Bool = true,
        progress: ProgressSink? = nil
    ) {
        for index in nodes.indices {
            let id = parent.child(index)
            if nodes[index].isExpandable, opensCompressed || nodes[index].kind != .section {
                expand(
                    &nodes[index], at: id, reader: reader, limits: limits,
                    buffers: buffers, diagnostics: &diagnostics, progress: progress
                )
            }
            materializeAll(
                &nodes[index].children, under: id, reader: reader, limits: limits,
                buffers: buffers, diagnostics: &diagnostics, opensCompressed: opensCompressed,
                progress: progress
            )
        }
    }

    /// The protected ranges of the image `roots` are the top of
    /// (`BOOT_GUARD_PROTECTED_RANGES.md` §9.2), read over a copy of the tree
    /// opened as far as the lists need.
    ///
    /// Every volume's files, because the vendor hash files are among them —
    /// and compressed sections only when a range that starts at the DXE root
    /// volume could not be placed without them, since the DXE Core usually sits
    /// inside an LZMA section and decoding one is megabytes of work.
    static func protectedRanges(
        roots: [UEFINode],
        size: UInt64,
        addressDiff: UInt64?,
        resetVector: ResetVector?,
        reader: ImageReader,
        limits: UEFIParser.Limits,
        buffers: DecompressedBuffers
    ) -> ProtectedRanges {
        var nodes = roots
        // What the copy's parse finds is the tree's to report when a reader
        // opens those branches, not this reading's.
        var discarded: [UEFIDiagnostic] = []
        let readers = SpaceReaders(file: reader, buffers: buffers, limit: limits.maxDecompressedSize)
        func read() -> ProtectedRanges {
            ProtectedRanges.read(
                UEFIImage(size: size, roots: nodes, addressDiff: addressDiff, resetVector: resetVector),
                readers: readers
            )
        }
        materializeAll(&nodes, reader: reader, limits: limits, buffers: buffers,
                       diagnostics: &discarded, opensCompressed: false)
        let shallow = read()
        let needsTheDXECore = shallow.ranges.contains {
            ($0.kind == .postIbb || $0.kind == .amiV1) && $0.range == nil
        }
        guard needsTheDXECore else { return shallow }
        materializeAll(&nodes, reader: reader, limits: limits, buffers: buffers, diagnostics: &discarded)
        return read()
    }

    /// Ids are stamped relative to `parent` the same way `UEFIImage` stamps a
    /// freshly-built tree — the parser itself never carries a counter, a
    /// node's place is only known once its parent has decided to keep it.
    static func stampIDs(_ nodes: [UEFINode], under parent: NodeID) -> [UEFINode] {
        nodes.enumerated().map { index, node in
            var stamped = node
            stamped.id = parent.child(index)
            stamped.children = stampIDs(node.children, under: stamped.id)
            return stamped
        }
    }
}

/// How far a materialization has got, for a caller drawing a bar.
///
/// A reference type, and shared across every `Parser` one materialization
/// runs: the fractions have to move forward across the whole job, and a
/// per-parser counter would walk the bar back to nothing at each new node.
/// Only ever driven from the thread doing the materialization — a background
/// expansion reports nothing at all, so this never crosses an isolation
/// boundary.
final class ProgressSink {
    private let total: UInt64
    private let report: (Double) -> Void
    private var last: Double = 0

    init(total: UInt64, report: @escaping (Double) -> Void) {
        self.total = total
        self.report = report
    }

    /// Reports that the scan has reached `offset`. Drops anything that would
    /// move the bar backwards or not at all: the parser does not always visit
    /// the image in order — a descriptor image parses the BIOS region and then
    /// the smaller region that sits *below* it.
    func reached(_ offset: UInt64) {
        guard total > 0 else { return }
        let fraction = min(Double(offset) / Double(total), 1)
        guard fraction > last else { return }
        last = fraction
        report(fraction)
    }
}
