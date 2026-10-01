import Foundation

/// Dell's DVAR variable store (§9): the format Dell firmware keeps its own
/// settings in, beside or instead of the standard VSS store.
///
/// A store is `DVAR`, its size and a flags byte, then entries back to back
/// until one opens on the erase byte. Every field after the signature is
/// stored as its complement — `0xFF - value`, `0xFFFF - value` — so a field
/// is written by clearing bits. An entry is a state, flags, a type that says
/// how wide its name id and data size are, attributes and a namespace id;
/// then, on an entry that declares a namespace, its GUID; then the name id,
/// the data size and the data. A variable has no name of its own: it is a
/// number in a namespace, and an entry that does not declare one names its
/// namespace by the id another entry declared it under.
///
/// Ported from UEFITool's `FfsParser::parseRawArea` (`Types::DellDvarStore`)
/// and `common/ksy/dell_dvar.ksy`.
enum DVAR {
    /// `DVAR`.
    static let signature: UInt32 = 0x5241_5644
    /// Signature, the store size and the flags byte.
    static let headerSize: UInt64 = 9
    /// State, flags, type, attributes and the namespace id.
    static let entryHeaderSize: UInt64 = 5

    // States, after the complement.
    static let storing: UInt8 = 0x01
    static let stored: UInt8 = 0x05
    static let deleting: UInt8 = 0x15
    static let deleted: UInt8 = 0x55
    static let states: Set<UInt8> = [storing, stored, deleting, deleted]

    /// The variable is named by a number.
    static let flagNameId: UInt8 = 0x02
    /// The entry declares its namespace's GUID. Its state applies to the
    /// variable it carries, not to the declaration, which stands regardless.
    static let flagNamespaceGuid: UInt8 = 0x04

    // Types: how wide the name id and the data size are.
    static let nameId8Size8: UInt8 = 0x00
    static let nameId16Size8: UInt8 = 0x04
    static let nameId16Size16: UInt8 = 0x05

    /// One entry's header, its fields already complemented back.
    struct Entry {
        var offset: UInt64
        var state: UInt8
        var flags: UInt8
        var type: UInt8
        var attributes: UInt8
        var namespaceId: UInt8
        var namespaceGuid: EFIGUID?
        var nameId: UInt16
        var dataStart: UInt64
        var end: UInt64

        var declaresNamespace: Bool { flags == DVAR.flagNameId | DVAR.flagNamespaceGuid }
    }

    /// The entry at `offset`, read up to the end of the store. Nil when its
    /// fields run past the store; `known` is false when its state, flags or
    /// type are none the format is known to use, and the rest is not read.
    static func entry(at offset: UInt64, storeEnd: UInt64, in reader: ImageReader) -> (entry: Entry?, known: Bool) {
        guard offset + entryHeaderSize <= storeEnd,
              let raw = reader.bytes(at: offset, count: entryHeaderSize)
        else { return (nil, true) }
        let state = 0xFF - raw[0], flags = 0xFF - raw[1], type = 0xFF - raw[2]
        let known = states.contains(state)
            && (flags == flagNameId || flags == flagNameId | flagNamespaceGuid)
            && (type == nameId8Size8 || type == nameId16Size8 || type == nameId16Size16)
        guard known else { return (nil, false) }

        var cursor = offset + entryHeaderSize
        var namespaceGuid: EFIGUID?
        if flags & flagNamespaceGuid != 0 {
            guard cursor + 16 <= storeEnd, let guid = reader.guid(at: cursor) else { return (nil, true) }
            namespaceGuid = guid
            cursor += 16
        }
        let wideName = type != nameId8Size8
        let wideSize = type == nameId16Size16
        let fieldsEnd = cursor + (wideName ? 2 : 1) + (wideSize ? 2 : 1)
        guard fieldsEnd <= storeEnd else { return (nil, true) }
        let nameId = wideName
            ? 0xFFFF - (reader.uint16(at: cursor) ?? 0xFFFF)
            : UInt16(0xFF - (reader.uint8(at: cursor) ?? 0xFF))
        cursor += wideName ? 2 : 1
        let size = wideSize
            ? UInt64(0xFFFF - (reader.uint16(at: cursor) ?? 0xFFFF))
            : UInt64(0xFF - (reader.uint8(at: cursor) ?? 0xFF))
        cursor += wideSize ? 2 : 1
        guard cursor + size <= storeEnd else { return (nil, true) }
        return (Entry(offset: offset, state: state, flags: flags, type: type,
                      attributes: 0xFF - raw[3], namespaceId: 0xFF - raw[4],
                      namespaceGuid: namespaceGuid, nameId: nameId,
                      dataStart: cursor, end: cursor + size), true)
    }

    /// Every namespace a run of entries declares, by its id. The first
    /// declaration of an id holds, as in the reference.
    static func namespaces(_ entries: [UEFINode], in reader: ImageReader) -> [UInt8: EFIGUID] {
        var map: [UInt8: EFIGUID] = [:]
        for node in entries where node.kind == .dvarEntry {
            guard let raw = reader.bytes(at: node.header.lowerBound, count: entryHeaderSize),
                  0xFF - raw[1] == flagNameId | flagNamespaceGuid,
                  let guid = reader.guid(at: node.header.lowerBound + entryHeaderSize)
            else { continue }
            let id = 0xFF - raw[4]
            if map[id] == nil { map[id] = guid }
        }
        return map
    }

    /// One entry as a copy of a variable: the variable — its name id, in
    /// hex, and its namespace's GUID — and whether this copy is the one in
    /// force. That is the entry's own state, stored, for a namespace's
    /// declaration too: the tree shows a declaration as valid whatever its
    /// state, since the declaration stands, but the value it carries is
    /// replaced like any other.
    struct Copy {
        var node: UEFINode
        var name: String
        var guid: EFIGUID?
        var isCurrent: Bool
    }

    static func copies(in store: UEFINode, reader: ImageReader) -> [Copy] {
        let entries = store.children.filter { $0.kind == .dvarEntry }
        let namespaces = self.namespaces(entries, in: reader)
        return entries.compactMap { node in
            guard let read = entry(at: node.header.lowerBound, storeEnd: store.range.upperBound, in: reader).entry
            else { return nil }
            return Copy(node: node, name: name(read.nameId),
                        guid: read.namespaceGuid ?? namespaces[read.namespaceId],
                        isCurrent: read.state == stored)
        }
    }

    /// The name a variable's entry carries: its name id, in hex, as the
    /// reference shows it.
    static func name(_ nameId: UInt16) -> String {
        String(nameId, radix: 16, uppercase: true)
    }
}

extension Parser {
    /// The DVAR store at `offset`, or nil when the bytes there are not one:
    /// a size that does not fit what is left, or entries that run past it.
    func parseDvarStore(at offset: UInt64, limit: UInt64, emptyByte: UInt8) -> UEFINode? {
        guard offset + DVAR.headerSize <= limit,
              reader.uint32(at: offset) == DVAR.signature,
              let sizeC = reader.uint32(at: offset + 4)
        else { return nil }
        let size = UInt64(0xFFFF_FFFF - sizeC)
        guard size >= DVAR.headerSize, offset + size <= limit else { return nil }
        let end = offset + size

        var entries: [UEFINode] = []
        var notes: [(UEFIDiagnostic.Kind, UInt64)] = []
        var cursor = offset + DVAR.headerSize
        var tail: [UEFINode] = []
        while cursor < end {
            // An entry that opens on the erase byte is the end of them.
            if reader.uint8(at: cursor) == 0xFF {
                tail = dvarRest(from: cursor, to: end, emptyByte: emptyByte)
                break
            }
            let (read, known) = DVAR.entry(at: cursor, storeEnd: end, in: reader)
            guard known else {
                // Nothing after an entry of an unknown shape can be trusted to
                // be where it seems; the reference stops here too.
                notes.append((.unknownDvarEntry, cursor))
                tail = [UEFINode(kind: .padding, name: "Padding", range: cursor..<end,
                                 isErased: reader.isFilled(cursor..<end, with: emptyByte))]
                break
            }
            // Fields that run past the store: not a store after all.
            guard let entry = read else { return nil }
            let invalid = !entry.declaresNamespace && entry.state != DVAR.stored
            entries.append(UEFINode(
                kind: .dvarEntry,
                subtype: invalid ? UEFITypes.Sub.invalidDvarEntry
                    : entry.declaresNamespace ? UEFITypes.Sub.namespaceGuidDvarEntry
                    : UEFITypes.Sub.nameIdDvarEntry,
                name: invalid ? "Invalid" : DVAR.name(entry.nameId),
                guid: entry.namespaceGuid,
                header: entry.offset..<entry.dataStart,
                body: entry.dataStart..<entry.end,
                isFixed: true
            ))
            cursor = entry.end
        }

        // A variable named by a number takes its namespace's GUID, from
        // wherever in the store the namespace is declared.
        let namespaces = DVAR.namespaces(entries, in: reader)
        for index in entries.indices where entries[index].subtype == UEFITypes.Sub.nameIdDvarEntry {
            let id = 0xFF - (reader.uint8(at: entries[index].header.lowerBound + 4) ?? 0xFF)
            if let guid = namespaces[id] {
                entries[index].guid = guid
            } else {
                entries[index].name = "Invalid"
                notes.append((.dvarNamespaceMissing, entries[index].header.lowerBound))
            }
        }
        for (kind, at) in notes { note(kind, at: at) }

        return UEFINode(
            kind: .dvarStore,
            name: "DVAR store",
            header: offset..<(offset + DVAR.headerSize),
            body: (offset + DVAR.headerSize)..<end,
            isFixed: true,
            children: entries + tail
        )
    }

    /// What follows the last entry: free space when erased, padding when not.
    private func dvarRest(from start: UInt64, to end: UInt64, emptyByte: UInt8) -> [UEFINode] {
        guard start < end else { return [] }
        let range = start..<end
        if reader.isFilled(range, with: emptyByte) {
            return [UEFINode(kind: .freeSpace, name: "Free space", range: range, isErased: true)]
        }
        return [UEFINode(kind: .padding, name: "Padding", range: range)]
    }
}
