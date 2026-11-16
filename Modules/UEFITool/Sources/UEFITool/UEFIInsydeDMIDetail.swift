import Foundation
import Localization
import UEFIImage

/// What the details say of InsydeH2O's `$DMI` store (`InsydeDMIStore`): the
/// values it writes over the firmware's SMBIOS tables, each a way to the
/// record it is read from, then every record, each a way to its row. A store
/// with no record says so: the firmware then keeps the values of its own
/// tables.
///
/// A row keeps only its place, so the store is read again from the file on
/// each selection.
public enum UEFIInsydeDMIDetail {
    static func reads(_ kind: UEFINodeKind) -> Bool {
        kind == .insydeDMIStore
    }

    static func build(for node: UEFINode, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, reads(node.kind), let area = area(of: node, reader: reader)
        else { return ([], []) }
        guard !area.records.isEmpty else {
            return ([.init(L("Records", in: language),
                           L("None. The firmware keeps the values of its own SMBIOS tables.", in: language))], [])
        }
        let all = node.flattened
        var fields: [UEFIDetailField] = [.init(
            L("Records", in: language),
            L("%1$@, in force %2$@", in: language, "\(area.records.count)", "\(area.records.filter(\.isCurrent).count)"))]
        let unmarked = area.fieldsWithoutOneCurrent.map { $0.text(in: language) }
        if !unmarked.isEmpty {
            fields += UEFIDMIEntries.findings([(
                L("No single record is marked in force for: %1$@. The value shown is the last record's.",
                  "\(unmarked.joined(separator: ", "))"),
                false)], in: language)
        }
        // A value's link goes to the record it is read from: the record is
        // the row, there is no row for the value alone.
        let rows = UEFIDMIEntries.rows(area.fields, reader: reader, in: language).map { row in
            var row = row
            row.source = area.records.first { $0.body == row.source }?.range ?? row.source
            return row
        }
        let entries = UEFIDMIEntries.table(rows, among: all, in: language)
        let records = UEFIDetailTable(
            title: L("Records", in: language),
            symbol: "list.bullet.rectangle",
            columns: [L("Offset", in: language), L("Type", in: language), L("Offset in structure", in: language),
                      L("State", in: language), L("Field", in: language), L("Value", in: language)],
            rows: area.records.map { record in
                let value = reader.bytes(record.body).map {
                    DMIField.text(of: $0, as: record.isUUID ? .smbiosUUID : .ascii)
                } ?? ""
                return [.init(String(format: "0x%X", record.range.lowerBound)),
                        .init("\(record.type)"),
                        .init(String(format: "0x%02X", record.field)),
                        state(of: record, in: language),
                        .init(InsydeDMIArea.meaning(type: record.type, field: record.field)?.text(in: language)
                              ?? L("Unknown", in: language)),
                        .init(value.isEmpty ? "—" : value)]
            },
            rowTargets: area.records.map { record in
                all.first { $0.kind == .insydeDMIRecord && $0.range == record.range }.map { .node($0.id) }
            },
            linkColumn: 0
        )
        return (fields, [entries, records])
    }

    /// The store `node` is, read from the file: its records chain from the
    /// signature to the end of the row, and nothing has to follow them.
    static func area(of node: UEFINode, reader: ImageReader) -> InsydeDMIArea? {
        guard let bytes = reader.bytes(node.range), bytes.starts(with: InsydeDMIArea.signature) else { return nil }
        var records: [InsydeDMIArea.Record] = []
        var at = InsydeDMIArea.signature.count
        while at + 5 <= bytes.count {
            let length = Int(bytes[at + 3]) | Int(bytes[at + 4]) << 8
            guard length >= 5, at + length <= bytes.count else { return nil }
            let start = node.range.lowerBound + UInt64(at)
            records.append(.init(type: bytes[at], field: bytes[at + 1], flag: bytes[at + 2],
                                 range: start..<(start + UInt64(length))))
            at += length
        }
        return InsydeDMIArea(offset: node.range.lowerBound, records: records)
    }

    /// A record: the structure, the field, the third byte, the length and
    /// the value.
    static func recordFields(for node: UEFINode, reader: ImageReader, in language: AppLanguage) -> [UEFIDetailField] {
        guard let record = InsydeDMIArea.record(of: node, reader: reader) else { return [] }
        let value = InsydeDMIArea.value(of: record, reader: reader) ?? ""
        return [
            .init(L("SMBIOS type", in: language), "\(record.type)"),
            .init(L("Offset in structure", in: language), String(format: "0x%02X", record.field)),
            .init(L("Field", in: language), InsydeDMIArea.meaning(type: record.type, field: record.field)?
                .text(in: language) ?? L("Unknown", in: language)),
            .init(L("Flag", in: language), String(format: "0x%02X", record.flag)),
            .init(L("State", in: language), state(of: record, in: language).text),
            .init(L("Length", in: language), "0x" + String(record.range.count, radix: 16, uppercase: true)),
            .init(L("Value", in: language), value.isEmpty ? "—" : value)
        ]
    }

    /// `Insyde DMI · BOHB-WAX9 · 7WFPM21A08001740`: the store's name, the
    /// product name and the system serial it writes; `Insyde DMI · empty`
    /// for a store with no record.
    static func row(_ node: UEFINode, reader: ImageReader, in language: AppLanguage) -> String {
        guard let area = area(of: node, reader: reader) else { return node.displayName(in: language) }
        let name = node.displayName(in: language)
        guard !area.records.isEmpty else { return L("%1$@ · %2$@", in: language, name, L("empty", in: language)) }
        return [area.text(type: 1, field: 0x05, reader: reader), area.text(type: 1, field: 0x07, reader: reader)]
            .compactMap { $0 }
            .reduce(name) { L("%1$@ · %2$@", in: language, $0, $1) }
    }

    /// Whether a record is in force: FF in its third byte, or 00 once a
    /// later record of its field replaced it.
    static func state(of record: InsydeDMIArea.Record, in language: AppLanguage) -> UEFIDetailTable.Cell {
        switch record.flag {
        case 0xFF: return .init(L("In force", in: language), tone: .yes)
        case 0x00: return .init(L("Replaced", in: language))
        default: return .init(String(format: "0x%02X", record.flag))
        }
    }

    /// Whether the row of `node` is a record a later one replaced: the tree
    /// draws it grey, as it does empty space.
    public static func isReplaced(_ node: UEFINode, reader: ImageReader) -> Bool {
        InsydeDMIArea.record(of: node, reader: reader).map { $0.flag == 0x00 } ?? false
    }

    /// `Board version = M1050`: the field a record writes and its value.
    static func recordRow(_ node: UEFINode, reader: ImageReader?, in language: AppLanguage) -> String {
        guard let reader, let record = InsydeDMIArea.record(of: node, reader: reader),
              let value = InsydeDMIArea.value(of: record, reader: reader)
        else { return node.displayName(in: language) }
        return L("%1$@ = %2$@", in: language, node.displayName(in: language), value.isEmpty ? "—" : value)
    }
}
