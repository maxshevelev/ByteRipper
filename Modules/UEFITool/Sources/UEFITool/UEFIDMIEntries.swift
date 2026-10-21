import Foundation
import Localization
import UEFIImage

/// The table an identity area's details list its values in — Acer's block,
/// HP's `HP_MUD`, Apple's SysF store — each a way to the row it is read
/// from, as Lenovo's store lists its entries in use
/// (`UEFILenovoDMIDetail`). One table for every vendor, so the areas read
/// alike whatever layout is under them.
enum UEFIDMIEntries {
    struct Row {
        var name: String
        /// Nil or empty where the area has no value: a dash.
        var value: String?
        /// Where the row the value is read from lies; nil for a value no row
        /// holds.
        var source: Range<UInt64>?
    }

    /// The table, a row's link going to the one of `nodes` that lies where
    /// its value is read from.
    static func table(_ rows: [Row], among nodes: [UEFINode], in language: AppLanguage) -> UEFIDetailTable {
        UEFIDetailTable(
            title: L("Entries", in: language),
            symbol: "person.text.rectangle",
            columns: [L("Entry", in: language), L("Value", in: language)],
            rows: rows.map { row in
                [.init(row.name), .init((row.value ?? "").isEmpty ? "—" : row.value!)]
            },
            rowTargets: rows.map { row in
                row.source.flatMap { source in nodes.first { $0.range == source } }.map { .node($0.id) }
            },
            linkColumn: 0
        )
    }

    /// The rows of an area whose values are fields of its own bytes, read
    /// from `reader`.
    static func rows(_ fields: [DMIField], reader: ImageReader, in language: AppLanguage) -> [Row] {
        fields.map { field in
            Row(name: field.name.text(in: language),
                value: reader.bytes(field.range).map { DMIField.text(of: $0, as: field.encoding) },
                source: field.range)
        }
    }

    /// What reads wrong, as the details say it under the table's heading.
    static func findings(_ findings: [(text: LocalizedText, isProblem: Bool)], in language: AppLanguage) -> [UEFIDetailField] {
        findings.map { finding in
            .init(finding.isProblem ? L("Problem", in: language) : L("Note", in: language),
                  finding.text.text(in: language), isProblem: finding.isProblem)
        }
    }
}
