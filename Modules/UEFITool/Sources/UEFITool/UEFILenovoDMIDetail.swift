import Foundation
import LenovoDMI
import Localization
import ToolModuleKit
import UEFIImage

/// What the details and the tree say of Lenovo's DMI store (`LenovoDMI`):
/// the store's row sums it up — the block the firmware reads, what that block
/// holds, what reads wrong — and each part below it says what it is.
///
/// A row keeps only its place, so the store is read again from the file on
/// each selection: 16 KiB, decoded in microseconds. The entries' values are
/// XORed in the file, which is why they are read here, in the format's own
/// terms, and never from a row's bytes.
public enum UEFILenovoDMIDetail {
    /// The kinds this reads.
    static func reads(_ kind: UEFINodeKind) -> Bool {
        switch kind {
        case .lenovoDMIStore, .ldbgLog, .ldbgEntry, .lenvBlock, .lenvEntry: return true
        default: return false
        }
    }

    /// `firmwareReaders`, once the image's drivers have been searched, adds to
    /// each entry of the store the drivers that ask for it; nil leaves the
    /// line out until then, and for a block on its own for good.
    static func build(for node: UEFINode, image: UEFIImage, reader: ImageReader,
                      firmwareReaders: LenovoDMIFirmwareReaders? = nil)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, reads(node.kind) else { return ([], []) }
        let found = context(of: node, image: image, reader: reader)
        switch node.kind {
        case .lenovoDMIStore:
            guard let area = found.area else { return ([], []) }
            return summary(area, store: node)
        case .ldbgLog:
            guard let log = found.area?.log else { return ([], []) }
            return (logFields(log), [])
        case .ldbgEntry:
            guard let entry = found.area?.log.entries.first(where: { $0.offset == node.range.lowerBound })
            else { return ([], []) }
            return (logEntryFields(entry), [])
        case .lenvBlock:
            if let area = found.area, let index = area.blocks.firstIndex(where: { $0.offset == node.range.lowerBound }) {
                return (blockFields(area.blocks[index], live: liveText(index, in: area)), [])
            }
            guard let block = found.block else { return ([], []) }
            return (blockFields(block, live: nil), [])
        case .lenvEntry:
            let blocks = found.area?.blocks ?? found.block.map { [$0] } ?? []
            for (index, block) in blocks.enumerated() {
                guard let entry = block.entries.first(where: { $0.offset == node.header.lowerBound }) else { continue }
                let other = blocks.count == 2 ? (blocks[1 - index], 2 - index) : nil
                let drivers = found.area == nil ? nil : firmwareReaders?.drivers(of: entry.key)
                return (entryFields(entry, other: other, drivers: drivers), [])
            }
            return ([], [])
        default:
            return ([], [])
        }
    }

    /// The key a LENV block — or the block an entry is in — is stored in the
    /// file encoded with; nil for a block stored in the clear, a block opened
    /// decoded, and any row that is not one. What tells an agent that the
    /// bytes it would read or show at this node are not the text.
    @MainActor public static func storedXORKey(of node: UEFINode, in tree: LazyUEFITree) -> UInt8? {
        guard node.kind == .lenvBlock || node.kind == .lenvEntry,
              let reader = tree.spaceReaders.reader(for: .file),
              let found = decodableBlock(for: node, image: tree.image(), reader: reader),
              found.block.encoding == .encoded else { return nil }
        return found.block.xorKey
    }

    /// The block Open Decoded Block opens from `node` — the block itself, or
    /// the one an entry is in — and the row's name for it; nil on any other
    /// row, and on a block with nothing to decode (`LenovoDMIDecodedBlock`).
    public static func decodableBlock(for node: UEFINode, image: UEFIImage, reader: ImageReader)
        -> (block: LENVBlock, name: String)? {
        guard node.space == .file else { return nil }
        let row: UEFINode?
        switch node.kind {
        case .lenvBlock: row = node
        case .lenvEntry: row = node.id.path.isEmpty ? nil : image.node(NodeID(Array(node.id.path.dropLast())))
        default: return nil
        }
        guard let row, row.kind == .lenvBlock, let stored = reader.bytes(row.range) else { return nil }
        let block = LENVBlock(offset: row.range.lowerBound, stored: stored)
        guard LenovoDMIDecodedBlock.canOpen(block) else { return nil }
        return (block, row.name)
    }

    /// The badge a LENV block's row wears: a lock on a block stored encoded,
    /// an open one on a block in the clear under a key — a block opened
    /// decoded. None on a block with nothing to encode: erased, empty, a key
    /// of zero, or one that reads neither way.
    static func encodingRole(of node: UEFINode, reader: ImageReader) -> ToolRowMarks.Role? {
        guard node.kind == .lenvBlock, node.space == .file, let stored = reader.bytes(node.range) else { return nil }
        let block = LENVBlock(offset: node.range.lowerBound, stored: stored)
        guard block.hasSignature, !block.isBlank else { return nil }
        let key = hex(UInt64(block.xorKey), 2)
        switch block.encoding {
        case .encoded: return .encoded(L("Encoded with the XOR key %1$@", key), decoded: false)
        case .plain: return .encoded(L("Decoded: the key %1$@ encodes it again on the way back", key), decoded: true)
        case .keyIsZero, .undetermined: return nil
        }
    }

    // MARK: - Finding the store

    /// The store `node` is part of, or the block on its own it is or is in.
    private static func context(of node: UEFINode, image: UEFIImage, reader: ImageReader)
        -> (area: LenovoDMIArea?, block: LENVBlock?) {
        var path = node.id.path
        var current: UEFINode? = node
        while let at = current {
            if at.kind == .lenovoDMIStore, let stored = reader.bytes(at.range) {
                return (LenovoDMIArea.read(stored: stored, offset: at.range.lowerBound), nil)
            }
            if at.kind == .lenvBlock {
                let parent = path.isEmpty ? nil : image.node(NodeID(Array(path.dropLast())))
                if parent?.kind != .lenovoDMIStore, let stored = reader.bytes(at.range) {
                    return (nil, LENVBlock(offset: at.range.lowerBound, stored: stored))
                }
            }
            guard !path.isEmpty else { break }
            path.removeLast()
            current = image.node(NodeID(path))
        }
        return (nil, nil)
    }

    /// The area a log or a block of the store starts, read from where the
    /// store starts — the log's first byte. For the tree's rows, which have
    /// their parent but not the image.
    static func area(startingAt offset: UInt64, reader: ImageReader) -> LenovoDMIArea? {
        reader.bytes(at: offset, count: LenovoDMIFormat.areaSize)
            .flatMap { LenovoDMIArea.read(stored: $0, offset: offset) }
    }

    // MARK: - The store

    /// The store's own row: which block the firmware reads, the values that
    /// block holds — each a way to its row — and what reads wrong.
    private static func summary(_ area: LenovoDMIArea, store: UEFINode)
        -> ([UEFIDetailField], [UEFIDetailTable]) {
        var fields: [UEFIDetailField] = []
        if let live = area.liveIndex {
            fields.append(.init(L("Block in use"), L("LENV block %1$@, generation %2$@", live + 1, area.blocks[live].generation)))
        } else {
            fields.append(.init(L("Block in use"), area.blocks.allSatisfy(\.isBlank)
                ? L("None: the store is empty") : L("None: no LENV block the firmware would read"),
                isProblem: !area.blocks.allSatisfy(\.isBlank)))
        }
        for finding in area.findings {
            fields.append(.init(finding.isProblem ? L("Problem") : L("Note"), finding.text,
                                isProblem: finding.isProblem))
        }
        guard let live = area.liveIndex else { return (fields, []) }
        // The rows of the live block's entries, by their place: the store's
        // first child is the log, the blocks follow it.
        let blockRow = store.children.indices.contains(live + 1) ? store.children[live + 1] : nil
        // What the bench reads the store for — the serial number, the UUID,
        // the model, the Windows key — first, then what nobody has named.
        let all = area.blocks[live].entries
        let entries = all.filter { $0.knownType != nil } + all.filter { $0.knownType == nil }
        let table = UEFIDetailTable(
            title: L("Entries in use"),
            symbol: "person.text.rectangle",
            columns: [L("Entry"), L("Value")],
            rows: entries.map { [.init(LenovoDMIValue.name(of: $0.key)), .init(LenovoDMIValue.text(of: $0))] },
            rowTargets: entries.map { entry in
                blockRow?.children.first { $0.header.lowerBound == entry.offset }.map { .node($0.id) }
            },
            linkColumn: 0
        )
        return (fields, [table])
    }

    // MARK: - The log

    private static func logFields(_ log: LDBGLog) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = []
        if log.writeOffsetProblem == .erased {
            fields.append(.init(L("State"), L("Erased: nothing has been written since")))
        }
        let misplaced = log.writeOffsetProblem == .outOfRange || log.writeOffsetProblem == .misaligned
        fields.append(.init(L("Write offset"), hex(UInt64(log.writeOffset), 8), isProblem: misplaced))
        fields.append(.init(L("Entries"), L("%1$@ of %2$@", log.entries.count, log.capacity)))
        fields.append(.init(L("XOR key"), log.key.map { hex(UInt64($0), 2) } ?? "—"))
        fields.append(.init(L("Unknown"), LenovoDMIValue.hex(log.unknownHeader)))
        return fields
    }

    private static func logEntryFields(_ entry: LDBGEntry) -> [UEFIDetailField] {
        [
            .init(L("Time"), entry.timestampText ?? L("Not a date: %1$@", LenovoDMIValue.hex(entry.timestampBytes))),
            .init(L("Operation"), operationName(entry)),
            .init(L("Entry"), LenovoDMIValue.name(of: entry.key)),
            .init(L("Namespace"), namespaceText(entry.key)),
            .init(L("Entry type"), entry.key.typeText),
            .init(L("Size"), L("%1$@ bytes", entry.size)),
            .init(L("Unknown"), LenovoDMIValue.hex(entry.unknown))
        ]
    }

    /// The tree's word for a write: "Set · Baseboard serial number".
    static func logEntryText(_ entry: LDBGEntry) -> String {
        L("%1$@ · %2$@", operationName(entry), LenovoDMIValue.name(of: entry.key))
    }

    private static func operationName(_ entry: LDBGEntry) -> String {
        switch entry.knownOperation {
        case .setData?:
            return entry.size == 0
                ? L("Remove", context: "log operation")
                : L("Set", context: "log operation")
        case .protect?: return L("Protect", context: "log operation")
        case .unprotect?: return L("Unprotect", context: "log operation")
        case nil: return L("Unknown operation %1$@", hex(UInt64(entry.operation), 2))
        }
    }

    // MARK: - A block

    /// `live` is whether the firmware reads the block and why — nil for a
    /// block on its own, where there is no other copy to choose from.
    private static func blockFields(_ block: LENVBlock, live: String?) -> [UEFIDetailField] {
        if block.isErased {
            return [.init(L("State"), L("Erased: every byte is FF"))]
        }
        var fields: [UEFIDetailField] = []
        if block.isBlank {
            fields.append(.init(L("State"), L("Empty: wiped or never written")))
        }
        fields.append(.init(L("Signature", context: "block header"), block.hasSignature ? "LENV" : L("Missing"),
                            isProblem: !block.hasSignature))
        fields.append(.init(L("Generation"), "\(block.generation)"))
        if let live {
            fields.append(.init(L("Firmware reads it"), live))
        }
        fields.append(.init(L("Entries"), L("%1$@ of %2$@ declared", block.entries.count, block.declaredEntries),
                            isProblem: !block.entriesFit))
        fields.append(.init(L("XOR key"), hex(UInt64(block.xorKey), 2)))
        fields.append(.init(L("Stored"), encodingText(block.encoding)))
        fields.append(.init(L("Checksum"), checksumText(block), isProblem: !block.isBlank && !block.checksumIsValid))
        fields.append(.init(L("Access flag"), hex(UInt64(block.accessFlag), 2)))
        fields.append(.init(L("Write-protected"), block.accessFlag & 1 != 0 ? L("Yes") : L("No")))
        return fields
    }

    /// The tree's word for a block: its generation, or why it has none.
    static func blockText(_ block: LENVBlock) -> String? {
        if block.isErased { return L("Erased") }
        if !block.hasSignature { return L("No signature") }
        if block.isBlank { return L("Empty") }
        return L("Generation %1$@", block.generation)
    }

    private static func liveText(_ index: Int, in area: LenovoDMIArea) -> String {
        let block = area.blocks[index]
        if area.liveIndex == index {
            return block.checksumIsValid
                ? L("Yes — the higher generation")
                : L("Yes — the higher generation, although its checksum does not add up. Whether the firmware then falls back to the other block is not known.")
        }
        if !block.hasSignature { return L("No — no signature") }
        if block.generation == 0 { return L("No — generation 0") }
        return L("No — the other block's generation is higher")
    }

    private static func encodingText(_ encoding: LENVBlock.Encoding) -> String {
        switch encoding {
        case .encoded: return L("Encoded")
        case .plain: return L("Decoded")
        case .keyIsZero: return L("Key is zero")
        case .undetermined: return L("Undetermined: the entries do not fit either way")
        }
    }

    private static func checksumText(_ block: LENVBlock) -> String {
        let stored = hex(UInt64(block.checksum), 4)
        if block.checksumIsOfEncodedBody {
            return L("%1$@ (Valid for the body encoded again)", stored)
        }
        return block.checksumIsValid
            ? L("%1$@ (Valid)", stored)
            : L("%1$@ (Invalid), should be %2$@", stored, hex(UInt64(block.expectedChecksum), 4))
    }

    // MARK: - An entry

    /// `other` is the store's other block and its number, for a block in a
    /// store; nil for a block on its own.
    /// `drivers` are the image's drivers that name the entry's key, once
    /// they have been searched.
    private static func entryFields(_ entry: LENVEntry, other: (block: LENVBlock, number: Int)?,
                                    drivers: [String]? = nil) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = [.init(L("Value"), LenovoDMIValue.text(of: entry))]
        if let drivers {
            fields.append(.init(L("Read by the firmware"),
                                drivers.isEmpty ? L("No driver in this image names it") : drivers.joined(separator: ", ")))
        }
        if entry.knownType == .windowsKey {
            fields.append(windowsKeyField(entry))
        }
        if let other {
            let text: String
            switch other.block.entry(entry.key)?.data {
            case nil: text = L("Not in LENV block %1$@", other.number)
            case entry.data?: text = L("The same in LENV block %1$@", other.number)
            default: text = L("Different in LENV block %1$@", other.number)
            }
            fields.append(.init(L("Other copy"), text))
        }
        fields += [
            .init(L("Bytes"), LenovoDMIValue.hex(entry.data)),
            .init(L("Namespace"), namespaceText(entry.key)),
            .init(L("Entry type"), entry.key.typeText),
            .init(L("Size"), L("%1$@ bytes", entry.data.count)),
            .init(L("Write-protected"), entry.isWriteProtected ? L("Yes") : L("No")),
            .init(L("Entry flags"), hex(UInt64(entry.flags), 2)),
            .init(L("Unknown"), hex(UInt64(entry.unknown1), 2) + " " + hex(UInt64(entry.unknown2), 4))
        ]
        return fields
    }

    /// What the MSDM header in front of the Windows key says, or what is
    /// wrong with it.
    private static func windowsKeyField(_ entry: LENVEntry) -> UEFIDetailField {
        let size = LenovoDMIValue.WindowsKey.headerSize
        let label = L("Key header")
        switch LenovoDMIValue.WindowsKey.problem(entry.data) {
        case nil:
            return .init(label, L("MSDM licensing data, %1$@ bytes of key", entry.data.count - size))
        case .tooShort(let count)?:
            return .init(label, L("%1$@ bytes: shorter than the %2$@-byte header.", count, size), isProblem: true)
        case .signature(let head)?:
            return .init(label, L("The first 16 bytes are %1$@, not the MSDM signature %2$@.",
                                  LenovoDMIValue.hex(head), LenovoDMIValue.hex(LenovoDMIValue.WindowsKey.signature)),
                         isProblem: true)
        case .length(let declared, let actual)?:
            return .init(label, L("The header gives the key as %1$@ bytes, and %2$@ follow it.", declared, actual),
                         isProblem: true)
        case .notText?:
            return .init(label, L("The key holds bytes that are not printable."), isProblem: true)
        }
    }

    private static func namespaceText(_ key: LenovoDMIKey) -> String {
        key.isSMBIOS ? "SMBIOS" : key.namespaceText
    }

    private static func hex(_ value: UInt64, _ digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
