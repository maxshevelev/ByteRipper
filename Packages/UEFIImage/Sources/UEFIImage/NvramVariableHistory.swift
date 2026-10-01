import Foundation

/// The copies an NVRAM store keeps of one variable, oldest first
/// (`UEFI_IMAGE_FORMAT.md` §9).
///
/// A store is written by appending: a variable that changes gets a new entry,
/// and the old one is marked rather than overwritten, until the firmware
/// reclaims the store. So until then the store holds the variable's earlier
/// values as well — the boot order before the last boot, Setup before the last
/// change in it — and two copies side by side say what the change was.
///
/// A copy belongs to a variable by name and GUID. A VSS entry carries both,
/// marked or not, and its name is read from the bytes, since the tree calls a
/// marked entry `Invalid` as UEFITool does. An NVAR variable is a chain — the
/// first entry carries the name and GUID, later links only data — or a run of
/// whole entries, each superseded one with its valid bit cleared; a
/// superseded entry's name, GUID and value are read as if it were valid.
///
/// The history is the store's, not the image's: the defaults a board keeps in
/// another store are another variable's copies.
public struct NvramVariableHistory: Equatable, Sendable {
    public struct Version: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// The variable's value now.
            case current
            /// Replaced by a later copy.
            case superseded
            /// The last copy of a variable the store no longer holds.
            case deleted
        }

        /// The entry the copy is.
        public var entry: NodeID
        /// Where the entry starts.
        public var offset: UInt64
        /// The variable's value in this copy.
        public var value: Range<UInt64>
        public var state: State
    }

    public var name: String
    public var guid: EFIGUID?
    /// In store order, which is the order they were written in.
    public var versions: [Version]

    /// What one copy changed against the copy before it.
    public struct Change: Equatable, Sendable {
        public var oldSize: UInt64
        public var newSize: UInt64
        /// The bytes that differ, as runs of offsets into the value, over the
        /// length both copies have.
        public var changed: [Range<UInt64>]

        public var isNone: Bool { oldSize == newSize && changed.isEmpty }
        public var changedBytes: UInt64 { changed.reduce(0) { $0 + UInt64($1.count) } }
    }

    /// The history of the variable `entry` is a copy of, in the store whose
    /// entries are `store`'s children. Nil when `entry` is not a VSS or NVAR
    /// entry, its variable cannot be told, or the store keeps one copy of it.
    public static func of(_ entry: UEFINode, in store: UEFINode, reader: ImageReader) -> NvramVariableHistory? {
        guard entry.kind == .vssEntry || entry.kind == .nvarEntry else { return nil }
        let copies = self.copies(in: store, reader: reader)
        guard let mine = copies.first(where: { $0.entry == entry.id }) else { return nil }
        let versions = copies.filter { $0.key == mine.key }
        guard versions.count > 1 else { return nil }

        var history = NvramVariableHistory(
            name: mine.key.name, guid: mine.key.guid,
            versions: versions.map {
                Version(entry: $0.entry, offset: $0.offset, value: $0.value,
                        state: $0.isCurrent ? .current : .superseded)
            }
        )
        // With no current copy the variable was deleted, and the last copy is
        // the one it was deleted as.
        if !history.versions.contains(where: { $0.state == .current }) {
            history.versions[history.versions.count - 1].state = .deleted
        }
        return history
    }

    /// The variable `entry` is a copy of — its name and GUID — read from the
    /// bytes where the tree cannot name it. Nil when it cannot be told.
    public static func variable(of entry: UEFINode, in store: UEFINode, reader: ImageReader) -> (name: String, guid: EFIGUID?)? {
        guard entry.kind == .vssEntry || entry.kind == .nvarEntry else { return nil }
        return copies(in: store, reader: reader).first { $0.entry == entry.id }
            .map { ($0.key.name, $0.key.guid) }
    }

    /// `to` against `from`: their sizes, and the runs of bytes that differ.
    public static func change(from: Version, to: Version, reader: ImageReader) -> Change? {
        guard let old = reader.bytes(from.value), let new = reader.bytes(to.value) else { return nil }
        var runs: [Range<UInt64>] = []
        var start: Int?
        for index in 0..<min(old.count, new.count) {
            if old[index] != new[index] {
                if start == nil { start = index }
            } else if let open = start {
                runs.append(UInt64(open)..<UInt64(index))
                start = nil
            }
        }
        if let open = start { runs.append(UInt64(open)..<UInt64(min(old.count, new.count))) }
        return Change(oldSize: UInt64(old.count), newSize: UInt64(new.count), changed: runs)
    }

    // MARK: - Reading the copies

    private struct Key: Hashable {
        var name: String
        var guid: EFIGUID?
    }

    private struct Copy {
        var entry: NodeID
        var offset: UInt64
        var key: Key
        var value: Range<UInt64>
        var isCurrent: Bool
    }

    /// Every entry of the store that can be told whose copy it is.
    private static func copies(in store: UEFINode, reader: ImageReader) -> [Copy] {
        let entries = store.children.filter { $0.kind == .vssEntry || $0.kind == .nvarEntry }
        guard let first = entries.first else { return [] }
        return first.kind == .vssEntry
            ? vssCopies(entries, inVss2: store.kind == .vss2Store, reader: reader)
            : nvarCopies(entries, store: store.body, reader: reader)
    }

    private static func vssCopies(_ entries: [UEFINode], inVss2: Bool, reader: ImageReader) -> [Copy] {
        entries.compactMap { entry in
            let isCurrent = entry.subtype != UEFITypes.Sub.invalidVssEntry
            // The same reading for a marked entry and a live one, so the two
            // name a variable alike.
            let read = NvramStoreFill.variableName(entry, inVss2: inVss2, reader)
            guard let name = read ?? (isCurrent ? entry.name : nil) else { return nil }
            return Copy(entry: entry.id, offset: entry.header.lowerBound,
                        key: Key(name: name, guid: entry.guid),
                        value: vssValue(entry, inVss2: inVss2, reader: reader), isCurrent: isCurrent)
        }
    }

    /// A VSS2 entry's body is its value. A `$VSS` entry's body opens with the
    /// name, as long as the header's name size says.
    private static func vssValue(_ entry: UEFINode, inVss2: Bool, reader: ImageReader) -> Range<UInt64> {
        guard !inVss2 else { return entry.body }
        let h = entry.header.lowerBound
        let nameSize: UInt64?
        switch UInt64(entry.header.count) {
        case NVRAM.vssAuthHeaderSize: nameSize = reader.uint32(at: h + 36).map(UInt64.init)
        case NVRAM.vssIntelLegacyHeaderSize: nameSize = 4
        default: nameSize = reader.uint32(at: h + 8).map(UInt64.init)
        }
        let start = min(entry.body.lowerBound + (nameSize ?? 0), entry.body.upperBound)
        return start..<entry.body.upperBound
    }

    /// NVAR entries, read as if each were valid: a whole entry names its
    /// variable, a later link takes the name of the entry whose `next` points
    /// at it — the nearest one before it, being the last written.
    private static func nvarCopies(_ entries: [UEFINode], store: Range<UInt64>, reader: ImageReader) -> [Copy] {
        var linkedFrom: [UInt64: Key] = [:]
        var copies: [Copy] = []
        for node in entries {
            let offset = node.header.lowerBound
            guard let entry = Parser.readNvarEntry(at: offset, store: store, reader: reader, asIfValid: true)
            else { continue }
            var key: Key?
            if entry.isDataOnly {
                key = linkedFrom[offset]
            } else {
                var guid = entry.localGuid
                if guid == nil, let index = entry.guidIndex {
                    let back = NVAR.guidSize * (UInt64(index) + 1)
                    if UInt64(store.count) >= back { guid = reader.guid(at: store.upperBound - back) }
                }
                let name = entry.text ?? ""
                key = Key(name: name.isEmpty ? (guid?.description ?? "") : name, guid: guid)
            }
            if entry.next != NVAR.noNext, let key {
                linkedFrom[offset + UInt64(entry.next)] = key
            }
            guard let key, !key.name.isEmpty else { continue }
            let isCurrent = node.subtype == UEFITypes.Sub.fullNvarEntry
                || node.subtype == UEFITypes.Sub.dataNvarEntry
            copies.append(Copy(entry: node.id, offset: offset, key: key,
                               value: entry.dataStart..<entry.extendedStart, isCurrent: isCurrent))
        }
        return copies
    }
}
