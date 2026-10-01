import Foundation

/// How full an NVRAM store is, and how much of it still counts
/// (`UEFI_IMAGE_FORMAT.md` §9).
///
/// A variable store is written by appending: a variable that changes gets a
/// new entry and the old one is marked, never overwritten in place, until the
/// firmware reclaims the store — copies what is current and erases the rest.
/// So a store's free space runs out long before its variables would fill it,
/// and a store close to full is a store close to a reclaim, which is where a
/// power cut breaks things. This counts what the parser already found: the
/// bytes the free-space nodes cover, and the entries by what their subtype
/// says about them.
///
/// Read off the node's children, so it is the same for every store format;
/// an NVAR store, which has no node of its own, is counted on the file,
/// section or entry whose body it is.
public struct NvramStoreFill: Equatable, Sendable {
    /// The store's body: the room its entries are written into.
    public var size: UInt64
    /// Erased room the store can still write into.
    public var free: UInt64
    /// Entries whose value is the variable's value now.
    public var current: Int
    /// Entries a later one replaced: the earlier links of an NVAR chain, and
    /// a marked entry whose variable — the same name and GUID — has a current
    /// entry in the store.
    public var superseded: Int
    /// Marked entries of a variable the store no longer holds. A VSS store
    /// marks a replaced entry and a deleted one alike; which of the two it
    /// was is told only by whether the variable is still there. The tree
    /// names a marked VSS entry `Invalid`, as UEFITool does, so its name is
    /// read here from where the variable keeps it.
    public var deleted: Int

    public var used: UInt64 { size - free }

    /// The share of the store in use, in whole percent, rounded down — a
    /// store with any room left never reads as 100.
    public var percentUsed: Int {
        size == 0 ? 0 : Int(used * 100 / size)
    }

    static let entryKinds: Set<UEFINodeKind> = [.vssEntry, .sysFEntry, .evsaEntry, .nvarEntry]

    /// The fill of the store `node` is, or nil when it holds no entries.
    /// `reader` reads the space the node is in.
    public static func of(_ node: UEFINode, reader: ImageReader) -> NvramStoreFill? {
        let entries = node.children.filter { entryKinds.contains($0.kind) }
        guard !entries.isEmpty else { return nil }
        let free = node.children.filter { $0.kind == .freeSpace }.reduce(UInt64(0)) { $0 + UInt64($1.range.count) }
        var fill = NvramStoreFill(
            size: UInt64(node.body.count), free: min(free, UInt64(node.body.count)),
            current: 0, superseded: 0, deleted: 0
        )
        struct Key: Hashable { var name: String; var guid: EFIGUID? }
        func isMarked(_ entry: UEFINode) -> Bool {
            switch entry.subtype {
            case UEFITypes.Sub.invalidNvarEntry, UEFITypes.Sub.invalidLinkNvarEntry,
                 UEFITypes.Sub.invalidVssEntry, UEFITypes.Sub.invalidSysFEntry,
                 UEFITypes.Sub.invalidEvsaEntry:
                return true
            default:
                return false
            }
        }
        let live = Set(entries.filter {
            !isMarked($0) && $0.subtype != UEFITypes.Sub.linkNvarEntry
        }.map { Key(name: $0.name, guid: $0.guid) })
        for entry in entries {
            if entry.subtype == UEFITypes.Sub.linkNvarEntry {
                fill.superseded += 1
            } else if isMarked(entry) {
                let name = entry.kind == .vssEntry
                    ? (variableName(entry, inVss2: node.kind == .vss2Store, reader) ?? entry.name)
                    : entry.name
                if !name.isEmpty, live.contains(Key(name: name, guid: entry.guid)) {
                    fill.superseded += 1
                } else {
                    fill.deleted += 1
                }
            } else {
                fill.current += 1
            }
        }
        return fill
    }

    /// A VSS variable's name: UCS-2 up to the first NUL. A `$VSS` variable's
    /// name opens its body; a VSS2 variable's closes its header, after the
    /// standard or the authenticated fields. Nil when what is there does not
    /// read as one.
    static func variableName(_ entry: UEFINode, inVss2: Bool, _ reader: ImageReader) -> String? {
        var start = entry.body.lowerBound
        var end = entry.body.upperBound
        if inVss2 {
            let h = entry.header.lowerBound
            guard let attributes = reader.uint32(at: h + 4),
                  let lenName = reader.uint32(at: h + 8),
                  let lenData = reader.uint32(at: h + 12)
            else { return nil }
            let isAuth = Parser.isAuthenticatedVss2Variable(attributes: attributes, lenName: lenName, lenData: lenData)
            start = h + (isAuth ? NVRAM.vssAuthHeaderSize : NVRAM.vssStandardHeaderSize)
            end = entry.header.upperBound
        }
        guard start < end else { return nil }
        let length = min(end - start, 0x200) & ~1
        guard length >= 2, let bytes = reader.bytes(at: start, count: length) else { return nil }
        var units: [UInt16] = []
        for i in stride(from: 0, to: bytes.count, by: 2) {
            let unit = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            if unit == 0 { break }
            guard (0x20..<0x7F).contains(unit) else { return nil }
            units.append(unit)
        }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }
}
