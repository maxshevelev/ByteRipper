import Foundation
import Localization

/// AMI's NVAR variable store (§9): the format Aptio firmware keeps its
/// variables in, and the one most laptops and desktop boards in a repair shop
/// carry.
///
/// Not a store with a header of its own. An NVAR store is the body of an FFS
/// file — one of three GUIDs — or of a raw section, and it is a run of entries
/// back to back, each opening `NVAR`. Whatever follows the last entry is free
/// space, and the store's last bytes, counted from its end backwards, are a
/// table of the GUIDs the entries name by index.
///
/// A variable is rarely one entry. Firmware does not rewrite an entry in
/// place: it clears the old one's valid bit and appends a new one, or — for a
/// variable written often — gives the first entry a `next` offset and appends
/// data-only entries along the chain. The entry that holds a variable's
/// current value is the last link of its chain, and only the first one carries
/// the name and the GUID.
///
/// Ported from UEFITool's `NvramParser::parseNvarStore` and
/// `common/ksy/ami_nvar.ksy`, `new_engine`.
enum NVAR {
    /// `NVAR`.
    static let signature: UInt32 = 0x5241_564E
    /// The byte the reference's walk decides on: an entry starts here, or the
    /// store has ended.
    static let signatureFirst: UInt8 = 0x4E
    /// Signature, a 16-bit size, a 24-bit `next` and the attributes byte.
    static let headerSize: UInt64 = 10
    /// A `next` with every bit set is the end of a chain.
    static let noNext: UInt32 = 0xFF_FFFF

    // The attribute bits (`NVRAM_NVAR_ENTRY_*`).
    static let runtime: UInt8 = 0x01
    static let asciiName: UInt8 = 0x02
    /// The GUID is in the entry, not an index into the store's GUID table.
    static let localGuid: UInt8 = 0x04
    /// No GUID and no name: a later link of a chain.
    static let dataOnly: UInt8 = 0x08
    static let extendedHeader: UInt8 = 0x10
    static let hwErrorRecord: UInt8 = 0x20
    static let authWrite: UInt8 = 0x40
    /// Cleared when the firmware supersedes the entry.
    static let valid: UInt8 = 0x80

    // The extended attribute bits (`NVRAM_NVAR_ENTRY_EXT_*`).
    static let extendedChecksum: UInt8 = 0x01
    static let extendedAuthWrite: UInt8 = 0x10
    static let extendedTimeBased: UInt8 = 0x20

    /// The extended header ends in its own 16-bit size, and is at least its
    /// attributes byte and that size to count as one.
    static let extendedHeaderMinimum: UInt64 = 3
    /// The checksum, when there is one, is the byte before the size.
    static let extendedChecksumMinimum: UInt64 = 4
    static let timestampSize: UInt64 = 8
    static let hashSize: UInt64 = 32

    static let guidSize: UInt64 = 16
}

extension Parser {
    /// The entries of the NVAR store that fills `store`, then its free space
    /// and its GUID table — or nil when the bytes are not an NVAR store.
    ///
    /// `probe` is for a body that might be one: a raw section, which the
    /// reference tries every one of. A probe that fails leaves nothing behind.
    /// A body that is meant to be one — a file with an NVAR GUID — says so
    /// when it is not.
    ///
    /// The reference reads the whole store before it builds a node, and gives
    /// up on all of it when one entry does not read. This keeps the entries
    /// before the broken one and calls the rest padding: the variables a
    /// technician is looking for are usually in the part that reads.
    func parseNvarStore(
        _ store: Range<UInt64>,
        emptyByte: UInt8,
        probe: Bool,
        depth: Int
    ) -> [UEFINode]? {
        guard !store.isEmpty else { return probe ? nil : [] }
        guard depth < limits.maxDepth else {
            note(.recursionLimit, at: store.lowerBound)
            return nil
        }

        var nodes: [UEFINode] = []
        // Each entry with a `next`, by the offset it points at — the nearest
        // one wins, being the last written.
        var linksTo: [UInt64: NvarLink] = [:]
        // The table at the store's end holds as many GUIDs as the highest
        // index any entry names. Nothing else says how long it is.
        var guidsInStore: UInt64 = 0
        var offset = store.lowerBound

        while offset < store.upperBound {
            guard reader.uint8(at: offset) == NVAR.signatureFirst else {
                // The first byte that does not open an entry ends the walk:
                // free space, or padding, then the GUID table.
                return nvarStoreEnd(
                    at: offset, store: store, guidsInStore: guidsInStore,
                    emptyByte: emptyByte, probe: probe, nodes: nodes
                )
            }
            guard let entry = readNvarEntry(at: offset, store: store) else {
                guard offset > store.lowerBound else {
                    if !probe { note(.unreadableNvarEntry, at: offset) }
                    return nil
                }
                note(.unreadableNvarEntry, at: offset)
                return nodes + nvramPadding(from: offset, to: store.upperBound, emptyByte: emptyByte)
            }

            var node = nvarNode(entry, store: store, linkedFrom: linksTo[offset], guidsInStore: &guidsInStore)
            if entry.next != NVAR.noNext {
                linksTo[offset + UInt64(entry.next)] = NvarLink(
                    isValid: node.subtype != UEFITypes.Sub.invalidNvarEntry
                        && node.subtype != UEFITypes.Sub.invalidLinkNvarEntry,
                    name: node.name,
                    guid: node.guid
                )
            }

            // An entry whose value is itself an NVAR store — the defaults a
            // vendor keeps inside one variable — opens onto it.
            if node.subtype == UEFITypes.Sub.dataNvarEntry || node.subtype == UEFITypes.Sub.fullNvarEntry,
               node.body.count >= 4, reader.uint32(at: node.body.lowerBound) == NVAR.signature {
                node.children = parseNvarStore(
                    node.body, emptyByte: emptyByte, probe: false, depth: depth + 1
                ) ?? []
            }
            nodes.append(node)
            offset = entry.end
        }
        return nodes
    }

    /// What the walk keeps of an entry with a `next`: what the entry it points
    /// at inherits.
    private struct NvarLink {
        var isValid: Bool
        var name: String
        var guid: EFIGUID?
    }

    /// The fields of one entry, its parts laid out as header, data and
    /// extended header.
    struct NvarEntry {
        var offset: UInt64
        var end: UInt64
        var next: UInt32
        var attributes: UInt8
        /// Where the data starts: after the GUID or its index, and the name.
        var dataStart: UInt64
        /// Where the extended header starts, which is where the data ends.
        var extendedStart: UInt64
        var guidIndex: UInt8?
        var localGuid: EFIGUID?
        var text: String?

        var isValid: Bool { attributes & NVAR.valid != 0 }
        var isDataOnly: Bool { attributes & NVAR.dataOnly != 0 }
    }

    private func readNvarEntry(at offset: UInt64, store: Range<UInt64>) -> NvarEntry? {
        Self.readNvarEntry(at: offset, store: store, reader: reader)
    }

    /// The entry at `offset`, or nil when it does not read: the signature is
    /// not whole, the size is too small for the header or runs past the store,
    /// the name has no end, or the extended header claims more than the data.
    ///
    /// The walk reads a superseded entry — its valid bit cleared — as the
    /// reference does, as a header and a body; `asIfValid` reads its GUID,
    /// name and extended header too, which a variable's history needs to
    /// tell whose copy it was (`NvramVariableHistory`).
    static func readNvarEntry(
        at offset: UInt64, store: Range<UInt64>, reader: ImageReader, asIfValid: Bool = false
    ) -> NvarEntry? {
        guard reader.uint32(at: offset) == NVAR.signature,
              let size = reader.uint16(at: offset + 4),
              UInt64(size) > NVAR.headerSize,
              let next = reader.uint24(at: offset + 6),
              let attributes = reader.uint8(at: offset + 9)
        else { return nil }
        let end = offset + UInt64(size)
        guard end <= store.upperBound else { return nil }

        var entry = NvarEntry(
            offset: offset, end: end, next: next, attributes: attributes,
            dataStart: offset + NVAR.headerSize, extendedStart: end
        )
        var cursor = entry.dataStart

        // A valid entry that is not a later link carries its GUID, or its
        // index into the store's table, and then its name.
        let readsAsValid = entry.isValid || asIfValid
        if readsAsValid && !entry.isDataOnly {
            if attributes & NVAR.localGuid != 0 {
                guard cursor + NVAR.guidSize <= end, let guid = reader.guid(at: cursor) else { return nil }
                entry.localGuid = guid
                cursor += NVAR.guidSize
            } else {
                guard cursor < end, let index = reader.uint8(at: cursor) else { return nil }
                entry.guidIndex = index
                cursor += 1
            }
            if attributes & NVAR.asciiName != 0 {
                guard let bytes = reader.bytes(cursor..<end),
                      let zero = bytes.firstIndex(of: 0)
                else { return nil }
                entry.text = String(decoding: bytes[..<zero], as: UTF8.self)
                cursor += UInt64(zero) + 1
            } else {
                guard let bytes = reader.bytes(cursor..<end) else { return nil }
                var units: [UInt16] = []
                var index = 0
                var terminated = false
                while index + 1 < bytes.count {
                    let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                    index += 2
                    if unit == 0 { terminated = true; break }
                    units.append(unit)
                }
                guard terminated else { return nil }
                entry.text = String(decoding: units, as: UTF16.self)
                cursor += UInt64(index)
            }
        }
        entry.dataStart = cursor

        // The extended header sits at the entry's end and ends in its own
        // size. The reference takes the size only when it is big enough to be
        // one, and only on a valid entry.
        var extendedSize: UInt64 = 0
        if readsAsValid, attributes & NVAR.extendedHeader != 0,
           UInt64(size) > NVAR.headerSize + 2,
           let field = reader.uint16(at: end - 2),
           UInt64(field) >= NVAR.extendedHeaderMinimum {
            extendedSize = UInt64(field)
        }
        guard extendedSize <= end - entry.dataStart else { return nil }
        entry.extendedStart = end - extendedSize
        return entry
    }

    /// The node for an entry, named and classified the way the reference does.
    private func nvarNode(
        _ entry: NvarEntry,
        store: Range<UInt64>,
        linkedFrom previous: NvarLink?,
        guidsInStore: inout UInt64
    ) -> UEFINode {
        var subtype = UEFITypes.Sub.fullNvarEntry
        var name = ""
        var guid: EFIGUID?

        if !entry.isValid {
            subtype = UEFITypes.Sub.invalidNvarEntry
            name = "Invalid"
        } else {
            if entry.next != NVAR.noNext {
                subtype = UEFITypes.Sub.linkNvarEntry
            }
            if entry.isDataOnly {
                // A later link: the name and GUID are the chain's, taken
                // from the entry whose `next` points here. The reference
                // searches back to the second entry of the store and never
                // the first — an off-by-one that calls a chain started by the
                // first entry broken. Every entry counts here.
                if let previous, previous.isValid {
                    name = previous.name
                    guid = previous.guid
                    if entry.next == NVAR.noNext {
                        subtype = UEFITypes.Sub.dataNvarEntry
                    }
                } else {
                    subtype = UEFITypes.Sub.invalidLinkNvarEntry
                    name = "Invalid link"
                }
            } else {
                if let local = entry.localGuid {
                    guid = local
                } else if let index = entry.guidIndex {
                    // The table is read from the store's end backwards: index
                    // 0 is the last sixteen bytes.
                    let count = UInt64(index) + 1
                    guidsInStore = max(guidsInStore, count)
                    if UInt64(store.count) >= NVAR.guidSize * count {
                        guid = reader.guid(at: store.upperBound - NVAR.guidSize * count)
                    }
                }
                name = entry.text ?? ""
                if name.isEmpty { name = guid?.description ?? "" }
            }
        }

        verifyNvarChecksum(entry)

        return UEFINode(
            kind: .nvarEntry,
            subtype: subtype,
            name: name,
            guid: guid,
            header: entry.offset..<entry.dataStart,
            body: entry.dataStart..<entry.extendedStart,
            tail: entry.extendedStart..<entry.end,
            isFixed: true
        )
    }

    /// An entry whose extended header says it carries a checksum: the data, the
    /// extended header, the size and the attributes add up to zero.
    private func verifyNvarChecksum(_ entry: NvarEntry) {
        guard let checksum = NvarChecksum.read(
            entry: entry.offset..<entry.end, dataStart: entry.dataStart,
            extendedStart: entry.extendedStart, in: reader
        ), !checksum.valid
        else { return }
        note(
            .checksumMismatch(.nvarEntry, stored: UInt64(checksum.stored), computed: UInt64(checksum.expected)),
            at: entry.end - 3
        )
    }

    /// The end of the walk at `offset`: free space or padding up to the GUID
    /// table, then the table.
    private func nvarStoreEnd(
        at offset: UInt64,
        store: Range<UInt64>,
        guidsInStore: UInt64,
        emptyByte: UInt8,
        probe: Bool,
        nodes: [UEFINode]
    ) -> [UEFINode]? {
        // Nothing read, and this was only a look: whatever the body is, it is
        // not a store worth showing — and a raw section can be megabytes that
        // there is no point reading to find that out.
        if probe && offset == store.lowerBound { return nil }
        let tableStart = max(offset, store.upperBound - min(NVAR.guidSize * guidsInStore, UInt64(store.count)))
        let rest = offset..<tableStart
        let isFree = reader.isFilled(rest, with: emptyByte)
        if offset == store.lowerBound && !isFree {
            // An erased body is an empty store; anything else is not a store.
            note(.unreadableNvarEntry, at: offset)
            return nil
        }
        var nodes = nodes + nvramPadding(from: rest.lowerBound, to: rest.upperBound, emptyByte: emptyByte)
        if tableStart < store.upperBound {
            nodes.append(UEFINode(
                kind: .nvarGuidStore,
                name: "GUID store",
                header: tableStart..<tableStart,
                body: tableStart..<store.upperBound,
                isFixed: true
            ))
        }
        return nodes
    }
}

/// The checksum an NVAR entry's extended header may carry: the stored byte,
/// whether it adds up, and the byte that would make it.
///
/// Public because the parser checks it and the details panel shows it, and the
/// two must not compute it two ways.
public struct NvarChecksum: Equatable, Sendable {
    public var stored: UInt8
    public var valid: Bool
    public var expected: UInt8

    /// The checksum of an entry the parser read, or nil when it carries none.
    public static func read(_ node: UEFINode, in reader: ImageReader) -> NvarChecksum? {
        guard node.kind == .nvarEntry else { return nil }
        return read(
            entry: node.range, dataStart: node.body.lowerBound,
            extendedStart: node.tail.lowerBound, in: reader
        )
    }

    /// The sum is over the data and the extended header, the 16-bit size and
    /// the attributes — not the signature, the `next` or the name, so an
    /// entry can be relinked without being summed again — and is zero when it
    /// adds up. Only a valid entry's extended header is read at all.
    static func read(
        entry: Range<UInt64>,
        dataStart: UInt64,
        extendedStart: UInt64,
        in reader: ImageReader
    ) -> NvarChecksum? {
        let offset = entry.lowerBound
        guard let attributes = reader.uint8(at: offset + 9),
              attributes & NVAR.valid != 0,
              attributes & NVAR.extendedHeader != 0,
              entry.upperBound - extendedStart >= NVAR.extendedChecksumMinimum,
              let extended = reader.uint8(at: extendedStart),
              extended & NVAR.extendedChecksum != 0,
              let stored = reader.uint8(at: entry.upperBound - 3),
              let covered = reader.bytes(dataStart..<entry.upperBound),
              let size = reader.bytes(at: offset + 4, count: 2)
        else { return nil }
        let sum = Checksums.sum8(covered) &+ Checksums.sum8(size) &+ attributes
        return NvarChecksum(stored: stored, valid: sum == 0, expected: stored &- sum)
    }
}
