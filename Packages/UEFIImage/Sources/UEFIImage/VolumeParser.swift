import Foundation
import Localization

/// `EFI_FIRMWARE_VOLUME_HEADER` and what follows from it (§3).
enum FV {
    /// `_FVH`, which sits at a fixed `0x28` from the start of the header. The
    /// search is for the signature and the header is found by stepping back —
    /// there is nothing at offset zero of a volume worth matching on.
    static let signature: UInt32 = 0x4856_465F
    static let signatureOffset: UInt64 = 0x28
    /// Up to the block map.
    static let headerSize: UInt64 = 0x38
    static let blockMapEntrySize: UInt64 = 8
    /// A block map long enough to be a loop rather than a map.
    static let maxBlockMapEntries = 0x1000
    static let erasePolarity: UInt32 = 0x0000_0800
    static let checksumOffset = 0x32
    /// A Mac's microcode volume: no FFS inside, a run of microcode images
    /// after a header the reference takes as `0x100` bytes, whatever the
    /// header says of itself (`EFI_APPLE_MICROCODE_VOLUME_HEADER_SIZE`).
    static let appleMicrocodeFileSystem = KnownGUIDs.guid("153D2197-29BD-44DC-AC59-887F70E41A6B")
    static let appleMicrocodeHeaderSize: UInt64 = 0x100
}

/// A volume header that passed every test in §3.1 — which is what separates a
/// volume from four bytes of compressed data that happen to read `_FVH`.
struct VolumeHeader {
    var offset: UInt64
    var fileSystem: EFIGUID
    var fvLength: UInt64
    var attributes: UInt32
    var headerLength: UInt16
    var checksum: UInt16
    var revision: UInt8
    /// Header through extended header, aligned — where the body starts (§3.2).
    var headerSize: UInt64
    /// Σ NumBlocks · Length, the volume's size as the block map tells it.
    var blockMapSize: UInt64?
    /// The extended header the volume points at runs off the end of the image.
    var extendedHeaderMissing: Bool

    /// What an unwritten byte in this volume reads as (§3.5), inherited by
    /// everything inside it.
    var emptyByte: UInt8 {
        attributes & FV.erasePolarity != 0 ? 0xFF : 0x00
    }
}

extension Parser {
    /// Reads and validates a header. Pure: a candidate that fails leaves no
    /// diagnostic, because a false `_FVH` inside compressed data is not a
    /// defect in the image — and an image with a hundred of them would
    /// otherwise arrive with a hundred complaints.
    func readVolumeHeader(at offset: UInt64) -> VolumeHeader? {
        // The signature first, and on its own. This is asked at every
        // unclaimed byte of an NVRAM walk (§9) — twelve recognisers a byte,
        // and this is the last of them — so the seven reads below it must not
        // be paid by the bytes that are not a volume at all. Measured on a
        // 16 MiB image with a 258 KiB run of written-over padding in its NVRAM
        // volume: 409 ms of the walk's 473 was this function reading a GUID, a
        // length and five more fields before looking at the four bytes that
        // decide.
        guard reader.uint32(at: offset + FV.signatureOffset) == FV.signature else { return nil }

        guard let fileSystem = reader.guid(at: offset + 0x10),
              let fvLength = reader.uint64(at: offset + 0x20),
              let attributes = reader.uint32(at: offset + 0x2C),
              let headerLength = reader.uint16(at: offset + 0x30),
              let checksum = reader.uint16(at: offset + 0x32),
              let extHeaderOffset = reader.uint16(at: offset + 0x34),
              let revision = reader.uint8(at: offset + 0x37)
        else { return nil }

        guard revision == 1 || revision == 2,
              fvLength >= FV.headerSize + 2 * FV.blockMapEntrySize,
              fvLength < UInt64(UInt32.max),
              UInt64(headerLength) >= FV.headerSize,
              let alignedHeader = alignUp(UInt64(headerLength), to: 8),
              reader.range(at: offset, count: alignedHeader) != nil
        else { return nil }

        var headerSize = UInt64(headerLength)
        var extendedHeaderMissing = false
        if revision > 1 && extHeaderOffset != 0 {
            let extOffset = offset + UInt64(extHeaderOffset)
            if let extSize = reader.uint32(at: extOffset + 0x10), extSize > 0 {
                headerSize = UInt64(extHeaderOffset) + UInt64(extSize)
            } else {
                extendedHeaderMissing = true
            }
        }
        guard var aligned = alignUp(headerSize, to: 8), aligned <= fvLength else { return nil }
        if fileSystem == FV.appleMicrocodeFileSystem {
            guard FV.appleMicrocodeHeaderSize <= fvLength else { return nil }
            aligned = FV.appleMicrocodeHeaderSize
        }

        return VolumeHeader(
            offset: offset,
            fileSystem: fileSystem,
            fvLength: fvLength,
            attributes: attributes,
            headerLength: headerLength,
            checksum: checksum,
            revision: revision,
            headerSize: aligned,
            blockMapSize: blockMapSize(at: offset + FV.headerSize),
            extendedHeaderMissing: extendedHeaderMissing
        )
    }

    /// The block map is a second opinion about the volume's size. A volume
    /// whose two sizes disagree is damaged but still worth reading (§3.1), so
    /// this is reported and `FvLength` is believed.
    private func blockMapSize(at offset: UInt64) -> UInt64? {
        var total: UInt64 = 0
        var at = offset
        for _ in 0..<FV.maxBlockMapEntries {
            guard let blocks = reader.uint32(at: at),
                  let length = reader.uint32(at: at + 4)
            else { return nil }
            if blocks == 0 && length == 0 { return total }
            total &+= UInt64(blocks) * UInt64(length)
            at += FV.blockMapEntrySize
        }
        return nil
    }

    /// A volume and everything in it. Nil when the header does not check out,
    /// which is the scanner's cue to keep looking.
    func parseVolume(at offset: UInt64, limit: UInt64, depth: Int) -> UEFINode? {
        guard let header = readVolumeHeader(at: offset) else { return nil }

        var size = header.fvLength
        // A header that claims more than its block map does is believed — the
        // reference believes it — unless the block map's end is where
        // something else plainly starts: another volume, or the HP signature
        // block that signs one. The HP FS volume of the ProDesk 600 G4 says
        // `0x110000`, its block map `0x11000`, and at `0x11000` the block and
        // then the BIOS volume it signs begin (§3.1).
        if let blockMapSize = header.blockMapSize, blockMapSize < size,
           blockMapSize >= header.headerSize, offset + blockMapSize < limit,
           startsAnotherStructure(at: offset + blockMapSize, limit: limit) {
            size = blockMapSize
        }
        if offset + size > limit {
            note(.truncated(.volumeBody), at: offset)
            size = limit - offset
        }
        if let blockMapSize = header.blockMapSize, blockMapSize != header.fvLength {
            note(
                .sizeMismatch(.volumeHeader, stored: header.fvLength, computed: blockMapSize),
                at: offset + 0x20
            )
        }
        if header.extendedHeaderMissing {
            note(.truncated(.volumeExtendedHeader), at: offset + 0x34)
        }
        verifyVolumeChecksum(header)

        let bodyStart = min(offset + header.headerSize, offset + size)
        let body = bodyStart..<(offset + size)

        // The file walk of the body is the other expensive half of this parser
        // — a few hundred files, each read back for its own sections — and is
        // always left for `TreeMaterialization` to run when something asks for
        // this volume's children. The header, which is what says the volume is
        // a volume at all, has already been read and checked above.
        return UEFINode(
            kind: .volume,
            subtype: header.revision,
            name: KnownGUIDs.name(of: header.fileSystem) ?? "Volume",
            guid: header.fileSystem,
            header: offset..<bodyStart,
            body: body,
            isFixed: false,
            isExpandable: !body.isEmpty,
            childDepth: depth
        )
    }

    /// Whether a structure no volume holds starts at `offset`: a volume header
    /// of its own, or an HP signature block.
    private func startsAnotherStructure(at offset: UInt64, limit: UInt64) -> Bool {
        readVolumeHeader(at: offset) != nil
            || HPSignatureBlock.read(at: offset, limit: limit, in: reader) != nil
    }

    /// Over `HeaderLength` bytes and not over the whole header: the extended
    /// header is outside the sum (§3.3), and including it is the mistake that
    /// makes every Revision 2 volume look corrupt.
    private func verifyVolumeChecksum(_ header: VolumeHeader) {
        guard var bytes = reader.bytes(at: header.offset, count: UInt64(header.headerLength))
        else { return }
        bytes[FV.checksumOffset] = 0
        bytes[FV.checksumOffset + 1] = 0
        guard let computed = Checksums.checksum16(bytes), computed != header.checksum else { return }
        note(
            .checksumMismatch(
                .volumeHeader,
                stored: UInt64(header.checksum),
                computed: UInt64(computed)
            ),
            at: header.offset + UInt64(FV.checksumOffset)
        )
    }

    /// Not `private`: `TreeMaterialization` calls this directly to derive a
    /// volume's children when something expands it, scoped to just that one
    /// node rather than restarting the parse from the image root.
    func volumeChildren(
        _ header: VolumeHeader,
        body: Range<UInt64>,
        depth: Int
    ) -> [UEFINode] {
        guard !body.isEmpty else { return [] }
        guard depth < limits.maxDepth else {
            note(.recursionLimit, at: header.offset)
            return []
        }
        // An NVRAM store volume is read as a run of stores, not as FFS files
        // (§9) — its file-system GUID is not an FFS version, so it has to be
        // checked before the FFS dispatch would call it unknown.
        if NvramGuids.isStoreVolume(header.fileSystem) {
            return walkNvramVolumeBody(body, emptyByte: header.emptyByte, depth: depth + 1)
        }
        if header.fileSystem == FV.appleMicrocodeFileSystem {
            return walkMicrocodeVolumeBody(body, emptyByte: header.emptyByte)
        }
        if header.fileSystem == KnownGUIDs.appleReservedVolume,
           reader.isFilled(body, with: header.emptyByte) {
            return [UEFINode(kind: .freeSpace, name: L("Free space"), range: body, isErased: true)]
        }
        guard let ffsVersion = KnownGUIDs.ffsVersion(ofFileSystem: header.fileSystem) else {
            // A volume we cannot read the inside of still keeps its bytes (§3.4).
            note(.unknownFileSystem(header.fileSystem), at: header.offset + 0x10)
            return []
        }
        return walkVolumeBody(
            body,
            ffsVersion: ffsVersion,
            volumeRevision: header.revision,
            emptyByte: header.emptyByte,
            depth: depth + 1
        )
    }

    /// The file walk of §5.8: files back to back, each one aligned up to eight,
    /// until an all-empty header says the rest is free space.
    func walkVolumeBody(
        _ body: Range<UInt64>,
        ffsVersion: Int,
        volumeRevision: UInt8,
        emptyByte: UInt8,
        depth: Int
    ) -> [UEFINode] {
        var nodes: [UEFINode] = []
        var offset = body.lowerBound

        while offset < body.upperBound {
            guard body.upperBound - offset >= FFS.headerSize else {
                nodes.append(nonUEFIData(offset..<body.upperBound, emptyByte: emptyByte, depth: depth))
                break
            }
            if reader.isFilled(offset..<(offset + FFS.headerSize), with: emptyByte) {
                nodes += freeSpace(
                    from: offset, to: body.upperBound, of: body,
                    emptyByte: emptyByte, depth: depth
                )
                break
            }
            // A header that declares more than the volume has left is not a
            // file cut short but data of some other kind: the rest of the
            // volume, said once, as the reference keeps it (§5.8).
            if let size = declaredFileSize(at: offset, ffsVersion: ffsVersion, volumeRevision: volumeRevision),
               size > body.upperBound - offset {
                note(.nonUEFIDataInVolume, at: offset)
                nodes.append(nonUEFIData(offset..<body.upperBound, emptyByte: emptyByte, depth: depth))
                break
            }
            guard let file = parseFile(
                at: offset,
                limit: body.upperBound,
                ffsVersion: ffsVersion,
                volumeRevision: volumeRevision,
                volumeErasePolarity: emptyByte == 0xFF,
                depth: depth
            ) else { break }

            nodes.append(file.node)
            guard let next = alignUp(offset + file.size - body.lowerBound, to: 8)
                .map({ body.lowerBound + $0 }), next > offset
            else { break }
            // The bytes a file's size stops short of the next eight-byte
            // boundary belong to nobody, and a byte in no node is a byte that
            // cannot be written back (§11).
            nodes += padding(from: offset + file.size, to: min(next, body.upperBound),
                             emptyByte: emptyByte)
            offset = next
        }
        return nodes
    }

    /// The tail of a volume's body. Usually all erased; when it is not, the
    /// bytes after the last erased one are data somebody put there on purpose
    /// and the reference parser reads heuristically (§5.8). Keeping them as a
    /// node of their own is what makes them visible at all.
    private func freeSpace(
        from start: UInt64,
        to end: UInt64,
        of body: Range<UInt64>,
        emptyByte: UInt8,
        depth: Int
    ) -> [UEFINode] {
        guard let firstUsed = reader.firstOffset(in: start..<end, notEqualTo: emptyByte) else {
            return [UEFINode(kind: .freeSpace, name: L("Free space"), range: start..<end, isErased: true)]
        }
        // Back to the eight-byte boundary at or before the byte: what follows a
        // volume's free space starts aligned, whatever it turns out to be.
        var boundary = firstUsed
        if let up = alignUp(firstUsed - body.lowerBound, to: 8), up != firstUsed - body.lowerBound {
            boundary = body.lowerBound + up - 8
        }
        var nodes: [UEFINode] = []
        if boundary > start {
            nodes.append(UEFINode(
                kind: .freeSpace, name: L("Free space"), range: start..<boundary, isErased: true
            ))
        }
        nodes.append(nonUEFIData(boundary..<end, emptyByte: emptyByte, depth: depth))
        return nodes
    }

    /// Bytes inside a volume that are not files. Searched all the same (§5.8):
    /// vendors put whole volumes and runs of microcode in the space after a
    /// volume's files, and leaving it as one opaque block would hide them.
    func nonUEFIData(_ range: Range<UInt64>, emptyByte: UInt8, depth: Int) -> UEFINode {
        var node = UEFINode(
            kind: .nonUEFIData,
            name: L("Non-UEFI data"),
            range: range,
            isErased: reader.isFilled(range, with: emptyByte)
        )
        if !node.isErased, depth < limits.maxDepth {
            let found = scanRawArea(range, emptyByte: emptyByte, depth: depth + 1)
            // Nothing but padding means the search found nothing, and a single
            // padding child that repeats its parent is noise — unless the
            // padding has rows of its own read into it.
            if found.contains(where: { $0.kind != .padding || !$0.children.isEmpty }) {
                node.children = found
            }
        }
        return node
    }
}

extension Parser {
    /// An Apple microcode volume's body: microcode images back to back, and
    /// whatever follows the last of them as padding (UEFITool's
    /// `parseMicrocodeVolumeBody`).
    ///
    /// The walk stops at the first stretch that is not a microcode, as the
    /// reference's does — at an erased tail, or at bytes whose header does not
    /// read — and keeps the rest as one padding node. A microcode that runs
    /// past the body is cut and reported, as one found anywhere else is.
    func walkMicrocodeVolumeBody(_ body: Range<UInt64>, emptyByte: UInt8) -> [UEFINode] {
        var nodes: [UEFINode] = []
        var offset = body.lowerBound
        while offset < body.upperBound {
            let rest = offset..<body.upperBound
            guard !reader.isFilled(rest, with: 0x00), !reader.isFilled(rest, with: 0xFF),
                  reader.uint32(at: offset) == Microcode.headerType,
                  let microcode = parseMicrocode(at: offset, limit: body.upperBound),
                  microcode.range.upperBound > offset
            else {
                return nodes + padding(from: offset, to: body.upperBound, emptyByte: emptyByte)
            }
            nodes.append(microcode)
            offset = microcode.range.upperBound
        }
        return nodes
    }
}
