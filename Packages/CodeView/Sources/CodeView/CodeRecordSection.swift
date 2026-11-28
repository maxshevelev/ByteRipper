import AnalysisProfiles
import CodeAnalysis
import Foundation
import Localization

/// The words and the order of a module record's rows, apart from how they
/// are drawn: a row's key and label as the list writes them, a value as its
/// column writes it, the rows in key order, the branches of a grouped record,
/// what a filter keeps, and the review's note read in its parts.
///
/// `CodeRecordSectionView` draws what this says; a test reaches the rules
/// without a window.
struct CodeRecordSection {
    let profile: AnalysisProfile?
    let record: AnalysisProfile.Record?

    /// A branch of a grouped record: a value of its `groupBy` column, its
    /// words, and its rows.
    struct Group {
        let value: String
        /// The value's short name, empty when the profile gives none.
        let title: String
        /// What the branch's row reads: "62/66  ACPI EC", "Enabled", "Channel A".
        let label: String
        let summary: String?
        /// The review's note for the branch, in the review's words.
        let note: String?
        let rows: [[String: RecordValue]]
    }

    /// The status line: what the review has done with the record.
    static func statusText(_ status: AnalysisProfile.RecordStatus, note: String?) -> String {
        switch status {
        case .unanswered: L("Not answered yet.")
        case .partial: L("Review continues.")
        case .complete: L("Complete.")
        case .none: L("None: %1$@", note ?? "")
        }
    }


    var columns: [AnalysisProfile.Column] { record?.columns ?? [] }

    /// The column that says what a row does, by record: its first sentence
    /// is the label a row without one shows, and the details' sentence.
    var mainColumn: AnalysisProfile.Column? {
        for id in ["effect", "purpose", "meaning", "function", "device"] {
            if let column = record?.column(id) { return column }
        }
        return nil
    }

    /// The first sentence of `text`.
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [". ", "; ", "\n"] {
            if let range = trimmed.range(of: separator) {
                return String(trimmed[..<range.lowerBound])
            }
        }
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// The row's short label: the review's `label`, or the first sentence of
    /// its main text, whole — the line cuts it at the list's width, not here.
    func label(_ row: [String: RecordValue]) -> String {
        // A pin reads as the board names its signal, then what it is.
        if record?.id == "gpio", let net = row["net"]?.string, !net.isEmpty {
            let short = row["label"]?.string ?? ""
            return short.isEmpty ? net : net + ": " + short
        }
        if let label = row["label"]?.string, !label.isEmpty { return label }
        guard let main = mainColumn else { return "" }
        return Self.firstSentence(text(of: row, main))
    }

    /// The row's key as the list writes it: `IRQ 24`, `0x59/0x02`, the range
    /// `0x2A–0x2B` of a wider EC RAM field, `0x0B`, `GPJ5`, `0x2A600`.
    func keyDisplay(_ row: [String: RecordValue]) -> String {
        func hex(_ id: String) -> String? { row[id].flatMap(Self.number).map { String(format: "0x%02X", $0) } }
        switch record?.id {
        case "irq_map":
            return row["irq"].flatMap(Self.number).map { "IRQ \($0)" } ?? ""
        case "host_commands":
            let cmd = hex("cmd") ?? ""
            return hex("sub").map { "\(cmd)/\($0)" } ?? cmd
        case "ec_ram":
            guard let offset = row["offset"].flatMap(Self.number) else { return row["offset"]?.text ?? "" }
            let width = row["width"].flatMap(Self.number) ?? 1
            let first = String(format: "0x%02X", offset)
            return width > 1 ? "\(first)–" + String(format: "0x%02X", offset + width - 1) : first
        default:
            return (record?.key ?? []).filter { $0 != record?.groupBy }.compactMap { id -> String? in
                guard let column = record?.column(id) else { return nil }
                let part = text(of: row, column)
                return part.isEmpty ? nil : part
            }.joined(separator: " ")
        }
    }

    static func line(key: String, label: String) -> String {
        label.isEmpty ? key : "\(key)  \(label)"
    }

    /// A value as the column writes it: hex where the column is, enum words
    /// raw, a list joined, a nested table as a count.
    func text(of row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String {
        if column.kind == .computed { return computed(row, column) ?? "" }
        guard let value = row[column.id], value != .null else { return "" }
        return Self.text(value, kind: column.kind, column: column, profile: profile)
    }

    /// The number an `int` or `byte` value holds: a JSON number, or the
    /// `0x…` or decimal text the review's store writes.
    static func number(_ value: RecordValue) -> Int? {
        if case .double(let double) = value, double.rounded() == double { return Int(double) }
        return value.int
    }

    static func text(_ value: RecordValue, kind: AnalysisProfile.ColumnKind, column: AnalysisProfile.Column,
                     profile: AnalysisProfile?) -> String {
        switch kind {
        case .byte:
            guard let number = number(value) else { return value.text }
            return String(format: "0x%02X", number)
        case .int:
            // A word the column takes instead of a number (runtime, mailbox)
            // stays a word.
            if let word = value.string, column.values?.contains(word) == true { return word }
            guard let number = number(value) else { return value.text }
            return column.hex == true ? String(format: "0x%02X", number) : String(number)
        case .code, .data:
            guard let number = number(value) else { return value.text }
            return CodeAddress(UInt64(number)).description
        case .bool:
            if case .bool(let on) = value { return on ? L("Yes") : L("No") }
            return value.text
        case .list:
            let element = column.of ?? .text
            return (value.array ?? [value]).map { text($0, kind: element, column: column, profile: profile) }
                .joined(separator: ", ")
        case .rows:
            let count = value.array?.count ?? 0
            return L("%1$@ entries", String(count))
        case .ref:
            return refText(value, column: column, profile: profile)
        default:
            return value.text
        }
    }

    /// A ref as the row it names: its key values, written as their columns are.
    static func refText(_ value: RecordValue, column: AnalysisProfile.Column,
                                profile: AnalysisProfile?) -> String {
        guard let target = profile?.records.first(where: { $0.id == column.ref }) else { return value.text }
        if target.key.count == 1, let keyColumn = target.column(target.key[0]) {
            return text(value, kind: keyColumn.kind, column: keyColumn, profile: profile)
        }
        let object = value.object ?? [:]
        return target.key.compactMap { id in
            guard let part = object[id], let keyColumn = target.column(id) else { return nil }
            return text(part, kind: keyColumn.kind, column: keyColumn, profile: profile)
        }.joined(separator: " ")
    }

    /// A computed column: EC RAM's address in the EC, an SMBus peer's 8-bit
    /// bus address. Nothing where the row has no number to compute from (a
    /// runtime or mailbox address).
    func computed(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String? {
        switch column.compute {
        case "ec_ram_address":
            guard let offset = row["offset"].flatMap(Self.number),
                  let base = record?.parameters["ec_ram_base"].flatMap(RecordValue.integer) else { return nil }
            return CodeAddress(UInt64(base + offset)).description
        case "smbus_address_8bit":
            guard let address = row["address"], address.string.map({ RecordValue.integer($0) != nil }) ?? true,
                  let seven = Self.number(address) else { return nil }
            return String(format: "0x%02X", seven * 2)
        default:
            return nil
        }
    }

    /// The row's key text, as `ModuleRecords.rowKey` writes it.
    func keyText(_ row: [String: RecordValue]) -> String {
        ModuleRecords.rowKey(row, key: record?.key ?? [])
    }

    static func isInference(_ row: [String: RecordValue]) -> Bool {
        row["confidence"]?.string == AnalysisProfile.RowConfidence.inference.rawValue
    }

    /// The `?` beside an inferred row, and what it says.
    static func inferenceToolTip(note: String?) -> String {
        guard let note, !note.isEmpty else { return L("Inference") }
        return L("Inference: %1$@", note)
    }

    static func isLink(_ column: AnalysisProfile.Column) -> Bool {
        [.code, .data, .ref].contains(column.kind)
            || (column.kind == .list && [.code, .data, .ref].contains(column.of ?? .text))
    }


    /// A short word after the key: `flash` for a command taken in flash mode,
    /// `PEC` for an SMBus device whose transfers carry one.
    func tag(_ row: [String: RecordValue]) -> String? {
        switch record?.id {
        case "host_commands" where row["mode"]?.string == "flash": Self.valueTitle("flash")
        case "smbus_peers" where row["pec"] == .bool(true): "PEC"
        // A pin's direction in words, not an arrow: IN, OUT, I/O.
        case "gpio": switch row["direction"]?.string {
            case "in": "IN"
            case "out": "OUT"
            case "bidir": "I/O"
            default: nil
            }
        default: nil
        }
    }


    /// The review's note on a record in its two parts: what the rows cover,
    /// and what is not checked yet. A review that wrote both into `note`, as
    /// `… Not checked: …`, is read apart at those words.
    static func noteParts(note: String?, notChecked: String?) -> (scope: String?, notChecked: String?) {
        let parts = notedParts(note: note, notChecked: notChecked)
        return (parts.scope, parts.open)
    }

    /// The words a review opens what is still open with, in its note: the
    /// part after them is drawn under a warning with these words as its head.
    static let openMarkers = ["Not checked:", "Partial:"]

    static func notedParts(note: String?, notChecked: String?) -> (scope: String?, head: String?, open: String?) {
        func clean(_ text: String?) -> String? {
            let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        if let notChecked = clean(notChecked) { return (clean(note), "Not checked:", notChecked) }
        guard let note = clean(note) else { return (nil, nil, nil) }
        let found = openMarkers.compactMap { marker in note.range(of: marker).map { (marker, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
        guard let (marker, range) = found else { return (note, nil, nil) }
        return (clean(String(note[..<range.lowerBound])), marker, clean(String(note[range.upperBound...])))
    }


    /// The value a row stands under: its own, `other` for a row with none
    /// when the column has that value, a bool as `true` or `false`.
    static func groupValue(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String {
        if case .bool(let on)? = row[column.id] { return on ? "true" : "false" }
        let value = row[column.id]?.text ?? ""
        if value.isEmpty, column.values?.contains("other") == true { return "other" }
        return value
    }

    /// The branches of a grouped record: one per value of `column` in the
    /// order it declares them (a bool: true, then false), then any other
    /// value the rows hold. A value with words of its own is a branch with no
    /// rows too, unless a filter is on.
    static func groups(of rows: [[String: RecordValue]], by column: AnalysisProfile.Column,
                               keepEmpty: Bool, notes: [String: String]) -> [Group] {
        let declared = column.values ?? (column.kind == .bool ? ["true", "false"] : [])
        let found = Set(rows.map { groupValue($0, column) })
        let others = found.subtracting(declared).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (declared + others).compactMap { name in
            let children = rows.filter { groupValue($0, column) == name }
            let english = column.valueSummaries?[name]
            guard !children.isEmpty || (keepEmpty && english != nil) else { return nil }
            let title = column.valueTitles?[name].map(valueTitle) ?? ""
            // A port pair is read by its numbers and its purpose; a branch
            // with a name of its own by the name; a bare value by its column.
            let label = title.isEmpty ? "\(columnTitle(column.title)) \(name)"
                : english != nil ? "\(name)  \(title)" : title
            return Group(value: name, title: title, label: label,
                                   summary: english.map(valueSummary), note: notes[name], rows: children)
        }
    }

    /// Rows in key order, the grouping column aside: a number as a number, a
    /// row without a part (a command with no subcommand) before one with it,
    /// an enum by the order its values are declared (normal before flash).
    func keyOrder(_ left: [String: RecordValue], _ right: [String: RecordValue]) -> Bool {
        for id in record?.key ?? [] where id != record?.groupBy {
            guard let column = record?.column(id) else { continue }
            let a = keyRank(left, column), b = keyRank(right, column)
            if let x = a.number, let y = b.number {
                if x != y { return x < y }
                continue
            }
            if a.number != nil || b.number != nil {
                // A missing part first; a number before a word.
                if a.text.isEmpty != b.text.isEmpty { return a.text.isEmpty }
                return a.number != nil
            }
            let order = a.text.localizedStandardCompare(b.text)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return false
    }

    func keyRank(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> (number: Int?, text: String) {
        if column.kind == .enum, let value = row[column.id]?.text, let index = column.values?.firstIndex(of: value) {
            return (index, value)
        }
        let number: Int? = switch column.kind {
        case .int, .byte, .code, .data: row[column.id].flatMap(Self.number)
        default: nil
        }
        return (number, text(of: row, column))
    }


    /// A record's word on the navigator's switch: short, the trade's term —
    /// nil for a record the app has none for, which keeps its glyph.
    static func tabWord(of id: String) -> String? {
        switch id {
        case "irq_map": L("Int")
        case "host_commands": L("Host")
        case "ec_ram": L("RAM")
        case "smbus_peers": L("SMBus")
        case "gpio": L("GPIO")
        case "eflash_area": L("Data")
        default: nil
        }
    }

    static func columnTitle(_ english: String) -> String {
        switch english {
        case "Access": L("Access")
        case "Accessed by": L("Accessed by")
        case "Active level": L("Active level")
        case "Address": L("Address")
        case "Body": L("Body")
        case "Bus address": L("Bus address")
        case "Callers": L("Callers")
        case "Channel": L("Channel")
        case "Command": L("Command")
        case "Commands": L("Commands")
        case "Data in": L("Data in")
        case "Data out": L("Data out")
        case "Device": L("Device")
        case "Direction": L("Direction")
        case "EC RAM": L("EC RAM")
        case "Effect": L("Effect")
        case "Enabled": L("Enabled")
        case "Format": L("Format")
        case "Function": L("Function")
        case "Group": L("Group")
        case "Handler": L("Handler")
        case "Host commands": L("Host commands")
        case "In the image": L("In the image")
        case "Initial state": L("Initial state")
        case "IRQ": L("IRQ")
        case "Label": L("Label")
        case "Meaning": L("Meaning")
        case "Mode": L("Mode")
        case "Name": L("Name")
        case "Offset": L("Offset")
        case "PEC": L("PEC")
        case "Pin": L("Pin")
        case "Ports": L("Ports")
        case "Purpose": L("Purpose")
        case "Raises": L("Raises")
        case "Readers": L("Readers")
        case "Size": L("Size")
        case "Source known from": L("Source known from")
        case "Source": L("Source")
        case "Subcommand": L("Subcommand")
        case "Task slot": L("Task slot")
        case "Values": L("Values")
        case "Width": L("Width")
        case "Writer": L("Writer")
        case "Writers": L("Writers")
        default: english
        }
    }

    /// The section's title in the reader's language: the profiles carry
    /// English, and an id not listed here keeps the profile's word.
    static func title(of id: String, fallback: String) -> String {
        switch id {
        case "irq_map": L("Interrupts")
        case "host_commands": L("Host commands")
        case "ec_ram": L("EC RAM")
        case "smbus_peers": L("SMBus and I2C")
        case "gpio": L("GPIO")
        case "eflash_area": L("Flash data area")
        default: fallback
        }
    }

    /// What a branch's value stands for, in the reader's language.
    static func valueSummary(_ english: String) -> String {
        switch english {
        case AnalysisProfile.kbcPortsSummary:
            L("Ports 0x60 (data) and 0x64 (command): the keyboard controller interface (KBC, i8042) — keyboard, touchpad and the legacy commands. In the EC the KBC block takes them.")
        case AnalysisProfile.acpiPortsSummary:
            L("Ports 0x62 (data) and 0x66 (command): the standard ACPI embedded controller interface — EC RAM read and write (0x80/0x81), query 0x84 and the SCI. In the EC the first PMC channel (PMC1) takes them.")
        case AnalysisProfile.oemPortsSummary:
            L("Ports 0x68 (data) and 0x6C (command): the second PMC channel (PMC2), usually the manufacturer's (OEM) commands — modes, flash mode, service functions.")
        default: english
        }
    }

    /// A value's short name, in the reader's language.
    static func valueTitle(_ english: String) -> String {
        switch english {
        case "Keyboard controller": L("Keyboard controller")
        case "ACPI EC": L("ACPI EC")
        case "OEM channel": L("OEM channel")
        case "flash": L("flash")
        case "Enabled": L("Enabled")
        case "Not enabled": L("Not enabled")
        case "Power": L("Power")
        case "Chipset": L("Chipset")
        case "Input": L("Input")
        case "Indicators": L("Indicators")
        case "USB": L("USB")
        case "Other": L("Other")
        default: english
        }
    }

    /// The same words for another record of the profile: a back-reference
    /// writes a row of it as its own list does.
    func of(_ other: AnalysisProfile.Record) -> CodeRecordSection {
        CodeRecordSection(profile: profile, record: other)
    }

    /// A row's line in the list: its key and its label.
    func line(_ row: [String: RecordValue]) -> String {
        Self.line(key: keyDisplay(row), label: label(row))
    }

    /// The rows a filter keeps: those whose key or label holds the query.
    func filtered(_ rows: [[String: RecordValue]], by query: String) -> [[String: RecordValue]] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            keyDisplay(row).localizedCaseInsensitiveContains(query)
                || label(row).localizedCaseInsensitiveContains(query)
        }
    }
}
