import Foundation
import Localization
import UEFIImage

/// What the details say of Panasonic's DMI area (`PanasonicDMIStore`): the
/// identity fields it holds — the model, the asset tag, the serial, the
/// Windows product key — each a way to its row, then the records its
/// directory lists, each a way to its row too. What most records hold is
/// not known, and the table says so rather than guessing.
///
/// A row keeps only its place, so the area is read again from the file on
/// each selection: its header and the first bytes of each record.
public enum UEFIPanasonicDMIDetail {
    static func reads(_ kind: UEFINodeKind) -> Bool {
        kind == .panasonicDMIStore
    }

    static func build(for node: UEFINode, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, reads(node.kind), let area = area(of: node, reader: reader)
        else { return ([], []) }
        let all = node.flattened
        let entries = UEFIDMIEntries.table(UEFIDMIEntries.rows(area.fields.map(\.field), reader: reader, in: language),
                                           among: all, in: language)
        let records = UEFIDetailTable(
            title: L("Directory", in: language),
            symbol: "list.bullet.rectangle",
            columns: [L("ID", in: language), L("Address", in: language), L("Length", in: language),
                      L("Holds", in: language)],
            rows: area.records.map { record in
                [.init(String(format: "0x%02X", record.id)),
                 .init(String(format: "0x%08X", record.address)),
                 .init("0x" + String(record.range.count, radix: 16, uppercase: true)),
                 .init(PanasonicDMIArea.meaning(of: record.id)?.text(in: language) ?? L("Unknown", in: language))]
            },
            rowTargets: area.records.map { record in
                all.first { $0.kind == .panasonicDMIRecord && $0.range == record.range }.map { .node($0.id) }
            },
            linkColumn: 0
        )
        return ([], [entries, records])
    }

    /// The area `node` is, read from the file.
    static func area(of node: UEFINode, reader: ImageReader) -> PanasonicDMIArea? {
        PanasonicDMIArea.read(at: node.range.lowerBound, end: node.range.upperBound, reader: reader)
    }

    /// A record's header: its ID, its length and the value after it — what
    /// that value is nobody knows — and what the record holds.
    static func recordFields(for node: UEFINode, reader: ImageReader, in language: AppLanguage) -> [UEFIDetailField] {
        guard node.kind == .panasonicDMIRecord, let bytes = reader.bytes(node.header),
              let header = PanasonicDMIArea.recordHeader(bytes)
        else { return [] }
        let digits = bytes.count == 4 ? 4 : 8
        var fields: [UEFIDetailField] = []
        if let id = node.subtype {
            fields.append(.init(L("ID", in: language), String(format: "0x%02X", id)))
        }
        fields.append(.init(L("Length", in: language), "0x" + String(header.length, radix: 16, uppercase: true)))
        fields.append(.init(L("Unknown value", in: language),
                            String(format: "0x%0\(digits)X", header.tag)))
        let meaning = node.subtype.flatMap { PanasonicDMIArea.meaning(of: UInt32($0)) }
        fields.append(.init(L("Holds", in: language), meaning?.text(in: language) ?? L("Unknown", in: language)))
        return fields
    }

    /// `Panasonic DMI · FZ55-2 · 1613…`: the area's name, the model and the
    /// serial it holds; the rest is in the detail.
    static func row(_ node: UEFINode, reader: ImageReader, in language: AppLanguage) -> String {
        guard let area = area(of: node, reader: reader) else { return node.displayName(in: language) }
        let parts = [area.model, area.serial ?? ""].filter { !$0.isEmpty }
        return ([node.displayName(in: language)] + parts).joined(separator: " · ")
    }

    /// `Record 0x16 · Windows product key`: a record's name and what it
    /// holds, where that is known.
    static func recordRow(_ node: UEFINode, in language: AppLanguage) -> String {
        guard let meaning = node.subtype.flatMap({ PanasonicDMIArea.meaning(of: UInt32($0)) }) else {
            return node.displayName(in: language)
        }
        return L("%1$@ · %2$@", in: language, node.displayName(in: language), meaning.text(in: language))
    }
}
