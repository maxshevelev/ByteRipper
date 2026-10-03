import Foundation
import HelpBook
import LenovoDMI
import Localization
import ToolModuleKit

/// One label/value line of the detail list.
public struct LenovoDMIField: Equatable, Sendable {
    public var label: String
    public var value: String
    /// A value that reads as a problem — a checksum that does not add up.
    public var isProblem: Bool

    public init(_ label: String, _ value: String, isProblem: Bool = false) {
        self.label = label
        self.value = value
        self.isProblem = isProblem
    }
}

/// One row of the panel's tree: the log, a block, or something in one.
public struct LenovoDMIRow: Equatable, Sendable {
    /// Stable across re-reads of the same layout, and the id of the row's zone.
    public var id: String
    public var name: String
    public var value: String
    public var range: Range<UInt64>
    /// The row says something is wrong — drawn in the problem colour.
    public var isProblem: Bool
    /// What the detail list shows under the row's name.
    public var fields: [LenovoDMIField]
    /// The glossary entry the detail's `?` opens for this row.
    public var term: HelpTermID?
    /// The block Open Decoded Block opens from this row — the block itself,
    /// or the one an entry is in. Nil for the log, and for a block that cannot
    /// be decoded with confidence.
    public var decodableBlock: String?
    public var children: [LenovoDMIRow]
}

/// What Open Decoded Block hands the host: what to call the panel, the
/// block it comes from, and the codec that decodes it and puts it back.
public struct LenovoDMIDecodedPart: Sendable {
    public var name: String
    public var source: Range<UInt64>
    public var codec: LenovoDMIBlockCodec
}

/// A finding, worded, as the panel lists it under the tree.
public struct LenovoDMINote: Equatable, Sendable {
    public var text: String
    public var isProblem: Bool
}

/// What the panel shows: built in the pure target, so the view controller
/// lays it out without deciding anything.
public struct LenovoDMIDisplay: Equatable, Sendable {
    /// The line over the tree.
    public var summary: String
    public var rows: [LenovoDMIRow]
    public var notes: [LenovoDMINote]
    /// The blocks that can be opened decoded, by their row's id.
    public var blocks: [String: LENVBlock] = [:]

    public static let empty = LenovoDMIDisplay(summary: "", rows: [], notes: [])

    /// The block Open Decoded Block opens from row `id`.
    public func decodedPart(from id: String) -> LenovoDMIDecodedPart? {
        guard let blockID = row(id)?.decodableBlock, let block = blocks[blockID],
              let name = row(blockID)?.name else { return nil }
        return LenovoDMIDecodedPart(name: L("%1$@ (decoded)", name), source: block.range,
                                      codec: LenovoDMIBlockCodec(block: block))
    }

    /// The row with `id`, anywhere in the tree.
    public func row(_ id: String) -> LenovoDMIRow? {
        func find(_ rows: [LenovoDMIRow]) -> LenovoDMIRow? {
            for row in rows {
                if row.id == id { return row }
                if let found = find(row.children) { return found }
            }
            return nil
        }
        return find(rows)
    }

    /// The top-level row holding `id` — itself, for a top-level row.
    public func parent(of id: String) -> LenovoDMIRow? {
        rows.first { $0.id == id || $0.children.contains { $0.id == id } }
    }

    /// What the dump draws with `focus` selected: the row in focus as the
    /// active zone, and — for an entry or a log record — the block or the log
    /// it is in as an inactive one around it, so the reader sees both where
    /// the bytes are and what they belong to. Outlines around every part and
    /// every entry at once are a lattice over a few kilobytes that says nothing
    /// the tree does not, so nothing else is drawn. Nothing in focus, nothing
    /// drawn.
    public func zones(focus: String?) -> ZoneMap {
        guard let focus, let row = row(focus) else { return .empty }
        guard let parent = parent(of: focus), parent.id != focus else {
            return ZoneMap(zones: [Zone(id: row.id, name: row.name, range: row.range)], focus: focus)
        }
        return ZoneMap(zones: [
            Zone(id: parent.id, name: parent.name, range: parent.range),
            Zone(id: row.id, name: parent.name + " · " + row.name, range: row.range)
        ], focus: focus)
    }
}

public enum LenovoDMIPresenter {
    public static func display(_ areas: [LenovoDMIArea]) -> LenovoDMIDisplay {
        display(LenovoDMIReading(areas: areas, blocks: []))
    }

    public static func display(_ reading: LenovoDMIReading) -> LenovoDMIDisplay {
        let areas = reading.areas
        guard !areas.isEmpty else {
            return reading.blocks.isEmpty ? noStore : blocksOnTheirOwn(reading.blocks)
        }
        return storesDisplay(areas)
    }

    private static var noStore: LenovoDMIDisplay {
        LenovoDMIDisplay(
            summary: L("No Lenovo DMI store in this image."),
            rows: [],
            notes: [LenovoDMINote(
                text: L("The tool looks for the LDBG change log followed by two LENV blocks. A Lenovo InsydeH2O image without them is either another platform or has had the area cut out."),
                isProblem: false
            )]
        )
    }

    /// LENV blocks with no store around them — what a fragment panel holds
    /// when a block was opened out of the dump. Each is read as a block: its
    /// header, its entries, its checksum. Which of two copies the firmware
    /// reads is not a question a lone block can answer, so it is not asked.
    private static func blocksOnTheirOwn(_ found: [LENVBlock]) -> LenovoDMIDisplay {
        var rows: [LenovoDMIRow] = []
        var blocks: [String: LENVBlock] = [:]
        for (number, block) in found.enumerated() {
            let id = "b\(number)"
            let name = found.count == 1
                ? L("LENV block")
                : L("LENV block at %1$@", hex(block.offset, 8))
            rows.append(blockRow(block, id: id, name: name, live: nil, other: nil, otherNumber: 0))
            if LenovoDMIDecodedBlock.canOpen(block) { blocks[id] = block }
        }
        var notes = [LenovoDMINote(
            text: L("A LENV block on its own: the change log and the other copy are not in this file."),
            isProblem: false
        )]
        for block in found where !block.isBlank && !block.checksumIsValid {
            notes.append(LenovoDMINote(
                text: L("The checksum is %1$@, the body adds up to %2$@.",
                        hex(UInt64(block.checksum), 4), hex(UInt64(block.expectedChecksum), 4)),
                isProblem: true
            ))
        }
        let summary: String
        if found.count == 1, let block = found.first {
            summary = block.isBlank
                ? L("A LENV block, empty.")
                : L("A LENV block: generation %1$@, %2$@.", block.generation, encodingText(block.encoding).lowercased())
        } else {
            summary = L("LENV blocks found: %1$@.", found.count)
        }
        return LenovoDMIDisplay(summary: summary, rows: rows, notes: notes, blocks: blocks)
    }

    private static func storesDisplay(_ areas: [LenovoDMIArea]) -> LenovoDMIDisplay {
        var rows: [LenovoDMIRow] = []
        var notes: [LenovoDMINote] = []
        var blocks: [String: LENVBlock] = [:]
        for (number, area) in areas.enumerated() {
            let prefix = areas.count == 1 ? "" : L("Store %1$@", number + 1) + " · "
            let id = "a\(number)"
            rows.append(logRow(area.log, id: id + ".log", prefix: prefix))
            for index in area.blocks.indices {
                let blockID = id + ".lenv\(index + 1)"
                rows.append(blockRow(index, in: area, id: blockID, prefix: prefix))
                if LenovoDMIDecodedBlock.canOpen(area.blocks[index]) {
                    blocks[blockID] = area.blocks[index]
                }
            }
            notes += area.findings.map { LenovoDMINote(text: prefix + $0.text, isProblem: $0.isProblem) }
        }
        if areas.count > 1 {
            notes.insert(LenovoDMINote(
                text: L("This image holds %1$@ stores. Which of them the firmware reads is not known.", areas.count),
                isProblem: true
            ), at: 0)
        }
        return LenovoDMIDisplay(summary: summary(areas[0]), rows: rows, notes: notes, blocks: blocks)
    }

    private static func summary(_ area: LenovoDMIArea) -> String {
        guard let live = area.liveIndex else {
            return area.blocks.allSatisfy(\.isBlank)
                ? L("The store is empty.")
                : L("No LENV block the firmware would read.")
        }
        let block = area.blocks[live]
        return L("LENV block %1$@ is in use: generation %2$@.", live + 1, block.generation)
    }

    // MARK: - The log

    private static func logRow(_ log: LDBGLog, id: String, prefix: String) -> LenovoDMIRow {
        let value: String
        switch log.writeOffsetProblem {
        case .erased?: value = L("Erased")
        case .outOfRange?: value = L("Write offset out of range")
        default: value = L("%1$@ entries", log.entries.count)
        }
        var fields = [
            LenovoDMIField(L("Offset"), hex(log.offset, 8)),
            LenovoDMIField(L("Size"), hex(UInt64(log.stored.count), 4)),
            LenovoDMIField(L("Write offset"), hex(UInt64(log.writeOffset), 8),
                           isProblem: log.writeOffsetProblem == .outOfRange
                               || log.writeOffsetProblem == .misaligned),
            LenovoDMIField(L("Entries"), L("%1$@ of %2$@", log.entries.count, log.capacity)),
            LenovoDMIField(L("XOR key"), log.key.map { hex(UInt64($0), 2) } ?? "—"),
            LenovoDMIField(L("Unknown"), LenovoDMIValue.hex(log.unknownHeader))
        ]
        if log.writeOffsetProblem == .erased {
            fields.insert(LenovoDMIField(L("State"), L("Erased: nothing has been written since")), at: 0)
        }
        return LenovoDMIRow(
            id: id, name: prefix + L("Change log (LDBG)"), value: value, range: log.range,
            isProblem: log.writeOffsetProblem == .outOfRange || log.writeOffsetProblem == .misaligned,
            fields: fields, term: HelpTermID("ldbg"), decodableBlock: nil,
            children: log.entries.map { logEntryRow($0, id: id + ".\($0.index)") }
        )
    }

    private static func logEntryRow(_ entry: LDBGEntry, id: String) -> LenovoDMIRow {
        let operation = operationName(entry)
        let entryName = LenovoDMIValue.name(of: entry.key)
        let sizeText = L("%1$@ bytes", entry.size)
        return LenovoDMIRow(
            id: id,
            name: entry.timestampText ?? L("No date"),
            value: L("%1$@ · %2$@ · %3$@", operation, entryName, sizeText),
            range: entry.range,
            isProblem: false,
            fields: [
                LenovoDMIField(L("Time"), entry.timestampText
                    ?? L("Not a date: %1$@", LenovoDMIValue.hex(entry.timestampBytes))),
                LenovoDMIField(L("Operation"), operation),
                LenovoDMIField(L("Entry"), entryName),
                LenovoDMIField(L("Namespace"), namespaceText(entry.key)),
                LenovoDMIField(L("Type"), entry.key.typeText),
                LenovoDMIField(L("Size"), sizeText),
                LenovoDMIField(L("Unknown"), LenovoDMIValue.hex(entry.unknown)),
                LenovoDMIField(L("Offset"), hex(entry.offset, 8))
            ],
            term: HelpTermID("ldbg"), decodableBlock: nil,
            children: []
        )
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

    private static func blockRow(
        _ index: Int, in area: LenovoDMIArea, id: String, prefix: String
    ) -> LenovoDMIRow {
        let other = area.blocks.indices.first { $0 != index }.map { area.blocks[$0] }
        return blockRow(area.blocks[index], id: id, name: prefix + L("LENV block %1$@", index + 1),
                        live: (area.liveIndex == index, liveText(index, in: area)),
                        other: other, otherNumber: index == 0 ? 2 : 1)
    }

    /// One block's row. `live` is whether the firmware reads it and why — nil
    /// for a block on its own, where there is no other copy to choose from.
    private static func blockRow(
        _ block: LENVBlock, id: String, name: String, live: (isLive: Bool, text: String)?,
        other: LENVBlock?, otherNumber: Int
    ) -> LenovoDMIRow {
        let value: String
        if !block.hasSignature {
            value = L("No signature")
        } else if block.isBlank {
            value = L("Empty")
        } else {
            value = live?.isLive == true
                ? L("Generation %1$@ · in use", block.generation)
                : L("Generation %1$@", block.generation)
        }

        var fields = [
            LenovoDMIField(L("Offset"), hex(block.offset, 8)),
            LenovoDMIField(L("Signature"), block.hasSignature ? "LENV" : L("Missing"),
                           isProblem: !block.hasSignature),
            LenovoDMIField(L("Generation"), "\(block.generation)"),
            LenovoDMIField(L("Entries"), L("%1$@ of %2$@ declared", block.entries.count, block.declaredEntries),
                           isProblem: !block.entriesFit),
            LenovoDMIField(L("XOR key"), hex(UInt64(block.xorKey), 2)),
            LenovoDMIField(L("Stored"), encodingText(block.encoding)),
            LenovoDMIField(L("Checksum"), checksumText(block), isProblem: !block.isBlank && !block.checksumIsValid),
            LenovoDMIField(L("Access flag"), hex(UInt64(block.accessFlag), 2)),
            LenovoDMIField(L("Write-protected"), block.accessFlag & 1 != 0 ? L("Yes") : L("No"))
        ]
        if let live {
            fields.insert(LenovoDMIField(L("Firmware reads it"), live.text), at: 3)
        }
        if block.isBlank {
            fields.insert(LenovoDMIField(L("State"), L("Empty: wiped or never written")), at: 0)
        }

        let decodeable = LenovoDMIDecodedBlock.canOpen(block) ? id : nil
        return LenovoDMIRow(
            id: id, name: name, value: value, range: block.range,
            isProblem: !block.hasSignature || !block.entriesFit
                || (!block.isBlank && !block.checksumIsValid),
            fields: fields, term: HelpTermID("lenv"), decodableBlock: decodeable,
            children: block.entries.map {
                entryRow($0, id: id + ".\($0.index)", other: other, otherNumber: otherNumber,
                         decodableBlock: decodeable)
            }
        )
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

    private static func entryRow(
        _ entry: LENVEntry, id: String, other: LENVBlock?, otherNumber: Int,
        decodableBlock: String?
    ) -> LenovoDMIRow {
        let value = LenovoDMIValue.text(of: entry)
        var fields = [
            LenovoDMIField(L("Value"), value),
            LenovoDMIField(L("Bytes"), LenovoDMIValue.hex(entry.data)),
            LenovoDMIField(L("Namespace"), namespaceText(entry.key)),
            LenovoDMIField(L("Type"), entry.key.typeText),
            LenovoDMIField(L("Size"), L("%1$@ bytes", entry.data.count)),
            LenovoDMIField(L("Write-protected"), entry.isWriteProtected ? L("Yes") : L("No")),
            LenovoDMIField(L("Flags"), hex(UInt64(entry.flags), 2)),
            LenovoDMIField(L("Unknown"), hex(UInt64(entry.unknown1), 2) + " " + hex(UInt64(entry.unknown2), 4)),
            LenovoDMIField(L("Offset"), hex(entry.offset, 8)),
            LenovoDMIField(L("Value at"), hex(entry.dataRange.lowerBound, 8))
        ]
        if let other {
            let text: String
            switch other.entry(entry.key)?.data {
            case nil: text = L("Not in LENV block %1$@", otherNumber)
            case entry.data?: text = L("The same in LENV block %1$@", otherNumber)
            default: text = L("Different in LENV block %1$@", otherNumber)
            }
            fields.insert(LenovoDMIField(L("Other copy"), text), at: 2)
        }
        return LenovoDMIRow(
            id: id, name: LenovoDMIValue.name(of: entry.key), value: value,
            range: entry.range, isProblem: false, fields: fields,
            term: HelpTermID("lenv"), decodableBlock: decodableBlock, children: []
        )
    }

    private static func namespaceText(_ key: LenovoDMIKey) -> String {
        key.isSMBIOS ? "SMBIOS" : key.namespaceText
    }

    private static func hex(_ value: UInt64, _ digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
