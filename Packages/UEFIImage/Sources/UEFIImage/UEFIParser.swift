import Foundation

/// Parses a firmware image into a tree.
///
/// Two passes (`Design/UEFI/UEFI_IMAGE_FORMAT.md`): the first builds the tree
/// purely by offsets, the second works out where the image lands in memory and
/// reads what only makes sense with an address in hand. The split is not
/// tidiness — the second pass needs a node the first pass has to find.
///
/// Nothing throws. Every level collects diagnostics and carries on with the
/// bytes it still understands, because the images worth opening a tool on are
/// the ones with something already wrong in them (§11).
public enum UEFIParser {
    public struct Limits: Sendable {
        /// Volume, file, section, volume again — real images nest a dozen rows
        /// deep, and a corrupt one nests forever (§11). The count is the
        /// parser's own recursion, which a nested volume costs about three
        /// of: a Dell XPS image needs more than 16, and 32 leaves room.
        public var maxDepth: Int
        /// The most a compressed section may decompress to. The size comes
        /// from an untrusted header (`COMPRESSED_SECTIONS.md` §3.1): a DXE
        /// volume is tens of megabytes, so a section that claims more than this
        /// is reported and kept whole rather than allocated.
        public var maxDecompressedSize: UInt64

        public init(maxDepth: Int = 32, maxDecompressedSize: UInt64 = 128 * 1024 * 1024) {
            self.maxDepth = maxDepth
            self.maxDecompressedSize = maxDecompressedSize
        }
    }

    /// Parses `source` into a whole tree, every container opened, in one call.
    ///
    /// The same materialization a `LazyUEFITree` performs one node at a time,
    /// driven straight through instead of on demand: build the top level, open
    /// every collapsed node under it, then work out where the image is mapped.
    /// There is no second implementation of the parse behind this — a tree
    /// built here and a tree a user expanded by hand come out of the same
    /// `TreeMaterialization` calls.
    ///
    /// Deliberately not what the app uses: opening a 16 MiB image this way
    /// takes about a second and reads every file body in it, which is exactly
    /// the wait `LazyUEFITree` exists to remove. What wants a finished tree in
    /// one value — this package's own tests, an oracle comparison against
    /// UEFITool's output — asks here.
    ///
    /// When `progress` is given it is called, on whichever thread the parse
    /// happens to be running on, with how far the scan has got through the
    /// image — monotonically, from just above 0 up to 1. Nothing calls it with
    /// the parse finished; whoever asked for progress decides what "done"
    /// means and announces it itself. It is `@Sendable` because a caller runs
    /// the parse off its main actor and must be able to hand the callback
    /// across to the scanning thread.
    ///
    /// `readsProtectedRanges` reads the Boot Guard and vendor protected ranges
    /// and hashes them (`BOOT_GUARD_PROTECTED_RANGES.md` §9.1) — which hashes
    /// megabytes, so a caller that has no use for them says so.
    public static func parse(
        _ source: ByteSource,
        limits: Limits = Limits(),
        layout: UEFIRootLayout = .image,
        readsProtectedRanges: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> UEFIImage {
        let reader = ImageReader(source)
        let sink = progress.map { report in
            ProgressSink(total: reader.count, report: { report($0) })
        }

        let built = TreeMaterialization.roots(
            reader: reader, limits: limits, layout: layout, progress: sink
        )
        var roots = built.nodes
        var diagnostics = built.diagnostics
        let buffers = DecompressedBuffers()
        TreeMaterialization.materializeAll(
            &roots, reader: reader, limits: limits, buffers: buffers,
            diagnostics: &diagnostics, progress: sink
        )

        let parser = Parser(reader: reader, limits: limits)
        let second = roots.isEmpty ? Parser.SecondPass() : parser.runSecondPass(&roots)
        let image = UEFIImage(
            size: reader.count,
            roots: roots,
            diagnostics: diagnostics + parser.diagnostics,
            addressDiff: second.addressDiff,
            resetVector: second.resetVector
        )
        guard readsProtectedRanges else { return image }
        let readers = SpaceReaders(file: reader, buffers: buffers, limit: limits.maxDecompressedSize)
        return image.adding(ProtectedRanges.read(image, readers: readers))
    }
}

/// The parse in progress: the reader, the limits, and the diagnostics as they
/// accumulate. A class because every level appends to one list, and threading
/// an `inout` array through a recursion this deep is how one branch's
/// diagnostics get dropped on the way back up.
final class Parser {
    let reader: ImageReader
    let limits: UEFIParser.Limits
    private(set) var diagnostics: [UEFIDiagnostic] = []
    /// Who the scan tells how far it has got, or nil to scan quietly. Shared
    /// with every other `Parser` of the same materialization, so the fractions
    /// move forward across the whole job rather than restarting per node.
    private let onProgress: ProgressSink?
    /// What the image's FIT names (`fitComponents`), once it has been asked.
    var fitComponentsCache: [FITComponent]?
    /// What the AMD PSP's directories map (`amdFirmware`), once it has been
    /// asked: nil inside when there is no EFS.
    var amdFirmwareCache: AMDFirmware??

    /// What an unwritten byte looks like outside any volume. Inside one it is
    /// the volume's erase polarity that decides (§3.5); out here `0xFF` is what
    /// an erased chip reads as.
    static let defaultEmptyByte: UInt8 = 0xFF

    init(
        reader: ImageReader,
        limits: UEFIParser.Limits,
        progress: ProgressSink? = nil
    ) {
        // Through a window of its own. A parser is built, used and dropped
        // inside one materialization on one thread, which is exactly the
        // lifetime a read cache needs — and the reads it makes are thousands
        // of small fields, mostly forward, which is exactly what a window
        // serves (`WindowedByteSource`).
        self.reader = ImageReader(WindowedByteSource(reader.source))
        self.limits = limits
        self.onProgress = progress
    }

    /// Reports that the scan has reached `offset`, as a fraction of the whole
    /// image.
    private func progressed(to offset: UInt64) {
        onProgress?.reached(offset)
    }

    func note(_ kind: UEFIDiagnostic.Kind, at offset: UInt64) {
        diagnostics.append(UEFIDiagnostic(kind, at: offset))
    }

    /// What kind of thing this is (§1): an update capsule, a full flash dump
    /// with an Intel descriptor, or — the common case for a dump off a chip —
    /// bytes to be searched for anything recognisable.
    ///
    /// Called again for a capsule's body, because what is inside an envelope is
    /// one of the same three things.
    func parseTopLevel(_ range: Range<UInt64>, depth: Int) -> [UEFINode] {
        guard depth < limits.maxDepth else {
            note(.recursionLimit, at: range.lowerBound)
            return []
        }
        let top: [UEFINode]
        if let update = parseBIOSGuardUpdate(at: range.lowerBound, limit: range.upperBound, depth: depth) {
            // What a vendor puts after the blocks — on ASUS's files an Aptio
            // capsule with an ME update in it — is read as any other bytes are.
            top = [update] + scanRawArea(
                update.range.upperBound..<range.upperBound,
                emptyByte: Parser.defaultEmptyByte,
                depth: depth
            )
        } else if let capsule = parseCapsule(at: range.lowerBound, limit: range.upperBound, depth: depth) {
            // A capsule claiming less than the file holds has something after
            // it; the trailing bytes stay as padding beside it (§1.1).
            top = [capsule] + padding(
                from: capsule.range.upperBound,
                to: range.upperBound,
                emptyByte: Parser.defaultEmptyByte
            )
        } else if hasDescriptorSignature(at: range.lowerBound) {
            // The signature is checked at `0x10` as well as at `0x00`: the
            // first sixteen bytes are a reserved vector, `0xFF` on x86 and a
            // real ARM reset vector on some ARM images (§1). An Intel image is
            // already the one node over the whole file, so it is returned as is.
            return parseIntelImage(range, depth: depth)
        } else {
            // Everything else — a lone volume off a chip, a NVRAM blob, bytes
            // to be searched — is a raw-area scan, and the scan decides the
            // top of the tree (§4).
            top = scanRawArea(range, emptyByte: Parser.defaultEmptyByte, depth: depth)
        }
        // The tree has one root. Several things at the top are a file that is
        // more than one image — a run of microcode with padding around it, a
        // capsule with bytes after it — and are grouped under the UEFI image
        // node UEFITool always shows as its root; the single thing a parse
        // found is already a root of its own, and is not wrapped in an image it
        // is not.
        guard top.count > 1 else { return top }
        return [UEFINode(
            kind: .uefiImage,
            subtype: UEFITypes.Sub.uefiImage,
            name: "UEFI image",
            header: range.lowerBound..<range.lowerBound,
            body: range,
            isFixed: true,
            children: top
        )]
    }

    // MARK: - Raw areas

    /// Linear search for the structures that announce themselves (§4).
    ///
    /// A BIOS region, the body of a padding element and an image with no flash
    /// descriptor are all read the same way: walk the bytes looking for a
    /// signature, and call everything in between padding. Byte by byte, not
    /// dword by dword — nothing here guarantees a volume starts on a multiple
    /// of four, and images where one does not are common enough that the
    /// reference parser gave up on the shortcut too.
    ///
    /// A volume running past the area is kept, cut and reported — a dump cut
    /// short still has its volumes. `volumesMustFit` turns such a header down
    /// instead, as the reference does everywhere: inside a section, a volume
    /// header with nothing behind it is data that happens to read as one.
    func scanRawArea(_ range: Range<UInt64>, emptyByte: UInt8, depth: Int,
                     volumesMustFit: Bool = false) -> [UEFINode] {
        guard reader.has(range), range.count >= 4 else {
            progressed(to: range.upperBound)
            return padding(from: range.lowerBound, to: range.upperBound, emptyByte: emptyByte)
        }
        var nodes: [UEFINode] = []
        var claimed = range.lowerBound
        var offset = range.lowerBound
        let window: UInt64 = 1 << 20

        scan: while offset + 4 <= range.upperBound {
            // One report per window, on the byte the window starts at: parsing
            // is mostly this scan, so how much of the image it has crossed is
            // how much of the work is done. The report goes out before the
            // window is searched rather than after — it says "reached here",
            // and a caller drawing a bar wants it filled as the scan travels.
            progressed(to: offset)
            let end = min(offset + window, range.upperBound)
            guard let bytes = reader.bytes(offset..<end) else { break }
            var index = 0
            while index + 4 <= bytes.count {
                let dword = UInt32(bytes[index])
                    | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16
                    | UInt32(bytes[index + 3]) << 24
                let at = offset + UInt64(index)
                if let found = element(atSignature: dword, at: at, in: range, emptyByte: emptyByte, depth: depth,
                                       volumesMustFit: volumesMustFit) {
                    nodes += padding(from: claimed, to: found.range.lowerBound, emptyByte: emptyByte)
                    nodes.append(found)
                    claimed = found.range.upperBound
                    offset = claimed
                    continue scan
                }
                index += 1
            }
            if end == range.upperBound { break }
            offset = end - 3    // so a signature straddling the window is still seen
        }

        // Whatever the last window left: the tail after the last structure, or
        // the whole range when nothing was found at all. The scan has crossed
        // the range whether or not a signature announced itself.
        progressed(to: range.upperBound)
        nodes += padding(from: claimed, to: range.upperBound, emptyByte: emptyByte)
        // What tables elsewhere name, then what announces itself only in
        // padding — each read into the padding as rows of its own.
        var read = readingMapRegions(nodes, emptyByte: emptyByte, depth: depth)
        // Before anything else reads padding: the map's three regions become
        // the one store they are.
        read = readingLenovoDMIStores(read, emptyByte: emptyByte)
        read = readingFITComponents(read, emptyByte: emptyByte)
        read = readingECFirmware(read, emptyByte: emptyByte)
        read = readingHPSignatureBlocks(read, emptyByte: emptyByte)
        read = readingGPNVStores(read, emptyByte: emptyByte)
        read = readingAMDMicrocode(read, emptyByte: emptyByte)
        // After the microcode: a patch the directories list is already its
        // row, and keeps it.
        return readingAMDFirmware(read, emptyByte: emptyByte, depth: depth)
    }

    /// A signature is a candidate, not a find: the four bytes turn up inside
    /// compressed data all the time, and only a header that checks out makes an
    /// element. Returning nil here means "keep scanning", and it must leave no
    /// diagnostic behind — a false candidate is not a defect in the image.
    private func element(
        atSignature dword: UInt32,
        at offset: UInt64,
        in range: Range<UInt64>,
        emptyByte: UInt8,
        depth: Int,
        volumesMustFit: Bool
    ) -> UEFINode? {
        switch dword {
        case FV.signature:
            guard offset >= range.lowerBound + FV.signatureOffset else { return nil }
            let start = offset - FV.signatureOffset
            if volumesMustFit, let length = reader.uint64(at: start + 0x20),
               length > range.upperBound - start {
                return nil
            }
            return parseVolume(at: start, limit: range.upperBound, depth: depth)
        case Microcode.headerType:
            return parseMicrocode(at: offset, limit: range.upperBound)
        case FlashDeviceMap.signature:
            return parseFlashDeviceMap(at: offset, limit: range.upperBound)
        case DVAR.signature:
            return parseDvarStore(at: offset, limit: range.upperBound, emptyByte: emptyByte)
        case Picture.jfifSignature, Picture.exifSignature, Picture.pngSignature, Picture.gifSignature:
            return parsePicture(at: offset, limit: range.upperBound)
        // A BMP announces itself in two bytes, and its header has to check
        // out field by field before it is one.
        case _ where UInt16(truncatingIfNeeded: dword) == Picture.bmpSignature:
            return parsePicture(at: offset, limit: range.upperBound)
        default:
            return nil
        }
    }

    /// `nodes` with `found` — something read out of padding by what a table
    /// elsewhere says is there: a map's region, a FIT structure — as a row
    /// inside the padding that holds it. The padding is what the structures
    /// around it made it, and keeps its place, its range and its name; what
    /// is read out of it are its rows, with padding rows for the bytes in
    /// between. Nil when no padding `accepts` takes, nor a padding row inside
    /// one, holds the whole of it: it is part of something already read.
    func placingInPadding(
        _ found: UEFINode, in nodes: [UEFINode], emptyByte: UInt8,
        accepts: (UEFINode) -> Bool = { _ in true }
    ) -> [UEFINode]? {
        func holds(_ node: UEFINode) -> Bool {
            node.kind == .padding && accepts(node)
                && node.range.lowerBound <= found.range.lowerBound
                && found.range.upperBound <= node.range.upperBound
        }
        guard let index = nodes.firstIndex(where: holds) else { return nil }
        var outer = nodes[index]
        var rows = outer.children.isEmpty
            ? padding(from: outer.range.lowerBound, to: outer.range.upperBound, emptyByte: emptyByte)
            : outer.children
        guard let row = rows.firstIndex(where: { holds($0) && $0.children.isEmpty }) else { return nil }
        let around = rows[row].range
        rows.replaceSubrange(
            row...row,
            with: padding(from: around.lowerBound, to: found.range.lowerBound, emptyByte: emptyByte)
                + [found]
                + padding(from: found.range.upperBound, to: around.upperBound, emptyByte: emptyByte)
        )
        outer.children = rows
        var result = nodes
        result[index] = outer
        return result
    }

    /// Whatever no structure claimed. Kept as a node rather than dropped: an
    /// image that cannot be put back together byte for byte is one this tool
    /// cannot honestly edit (§11).
    func padding(from start: UInt64, to end: UInt64, emptyByte: UInt8) -> [UEFINode] {
        guard start < end else { return [] }
        let range = start..<end
        let erased = reader.isFilled(range, with: emptyByte)
        return [UEFINode(
            kind: .padding,
            name: erased ? "Empty padding" : "Padding",
            range: range,
            isErased: erased
        )]
    }
}
