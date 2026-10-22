import Foundation
import Localization
import UEFIImage

/// What the details say of Panasonic's DMI area (`PanasonicDMIStore`): which
/// of its checksums fail, the identity fields it holds — the model, the
/// asset tag, the serial, the Windows product key — each a way to its row,
/// then its directory: the records it lists, each a way to its row too, with
/// whether its checksum holds. What most records hold is not known, and the
/// table says so rather than guessing.
///
/// A row keeps only its place, so the area is read again from the file on
/// each selection: its header and its records, summed.
public enum UEFIPanasonicDMIDetail {
    static func reads(_ kind: UEFINodeKind) -> Bool {
        kind == .panasonicDMIStore
    }

    static func build(for node: UEFINode, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, reads(node.kind), let area = area(of: node, reader: reader)
        else { return ([], []) }
        let all = node.flattened
        var fields: [UEFIDetailField] = []
        if !area.headerChecksumIsValid {
            fields.append(.init(L("Problem", in: language),
                                L("The header's first 0x80 bytes do not sum to 0.", in: language), isProblem: true))
        }
        fields.append(.init(
            L("Directory checksum", in: language),
            Checksums.text(area.directoryChecksum, valid: area.directoryChecksumIsValid,
                           expected: area.directoryChecksumIsValid ? nil : UInt64(area.expectedDirectoryChecksum))
                .text(in: language),
            isProblem: !area.directoryChecksumIsValid))
        let failing = area.records.filter { !$0.checksumIsValid }.count
        if failing > 0 {
            fields.append(.init(L("Problem", in: language),
                                L("%1$@ of the records fail their checksum.", in: language, "\(failing)"),
                                isProblem: true))
        }
        let entries = UEFIDMIEntries.table(UEFIDMIEntries.rows(area.fields.map(\.field), reader: reader, in: language),
                                           among: all, in: language)
        let records = UEFIDetailTable(
            title: L("Directory", in: language),
            symbol: "list.bullet.rectangle",
            columns: [L("ID", in: language), L("Address", in: language), L("Length", in: language),
                      L("Checksum", in: language), L("Holds", in: language)],
            rows: area.records.map { record in
                [.init(String(format: "0x%02X", record.id)),
                 .init(String(format: "0x%08X", record.address)),
                 .init("0x" + String(record.range.count, radix: 16, uppercase: true)),
                 .init(record.checksumIsValid ? L("OK", in: language) : L("Invalid", in: language),
                       tone: record.checksumIsValid ? .yes : .no),
                 .init(PanasonicDMIArea.meaning(of: record.id)?.text(in: language) ?? L("Unknown", in: language))]
            },
            rowTargets: area.records.map { record in
                all.first { $0.kind == .panasonicDMIRecord && $0.range == record.range }.map { .node($0.id) }
            },
            linkColumn: 0
        )
        return (fields, [entries, records])
    }

    /// The area `node` is, read from the file.
    static func area(of node: UEFINode, reader: ImageReader) -> PanasonicDMIArea? {
        PanasonicDMIArea.read(at: node.range.lowerBound, end: node.range.upperBound, reader: reader)
    }

    /// A record's header: its ID, its length and its checksum — whether the
    /// record's bytes sum to 0 with it, and the byte that would make them —
    /// and what the record holds.
    static func recordFields(for node: UEFINode, reader: ImageReader, in language: AppLanguage) -> [UEFIDetailField] {
        guard node.kind == .panasonicDMIRecord, let bytes = reader.bytes(node.header),
              let header = PanasonicDMIArea.recordHeader(bytes),
              let sum = Checksums.sum8(of: node.range, in: reader)
        else { return [] }
        var fields: [UEFIDetailField] = []
        if let id = node.subtype {
            fields.append(.init(L("ID", in: language), String(format: "0x%02X", id)))
        }
        fields.append(.init(L("Length", in: language), "0x" + String(header.length, radix: 16, uppercase: true)))
        let valid = sum == 0
        fields.append(.init(
            L("Checksum", in: language),
            Checksums.text(header.checksum, valid: valid,
                           expected: valid ? nil : UInt64(header.checksum &- sum)).text(in: language),
            isProblem: !valid))
        let meaning = node.subtype.flatMap { PanasonicDMIArea.meaning(of: UInt32($0)) }
        fields.append(.init(L("Holds", in: language), meaning?.text(in: language) ?? L("Unknown", in: language)))
        return fields
    }

    /// `Panasonic DMI · FZ55-2 · 1613…`: the area's name, the model and the
    /// serial it holds; the rest is in the detail.
    static func row(_ node: UEFINode, reader: ImageReader, in language: AppLanguage) -> String {
        guard let area = area(of: node, reader: reader) else { return node.displayName(in: language) }
        return [area.model, area.serial ?? ""].filter { !$0.isEmpty }.reduce(node.displayName(in: language)) {
            L("%1$@ · %2$@", in: language, $0, $1)
        }
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
