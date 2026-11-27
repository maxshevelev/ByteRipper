import AnalysisProfiles
import Foundation

/// A review's records — the tables an analysis profile declares (`irq_map`,
/// `host_commands`, `ec_ram`, …) — as the review document carries them under
/// `records`: each id a status, an optional note and its rows. A record the
/// review has not set is not there, and reads as `unanswered`.
///
/// The manifest keeps only each record's status (`AnalysisReading.records`):
/// a list's marks and the review's progress need nothing more, and the rows
/// are read from the document by the panel that shows them.
public struct ModuleRecords: Equatable, Sendable {
    public var records: [String: Record]

    public init(_ records: [String: Record] = [:]) { self.records = records }

    /// One record as the review set it.
    public struct Record: Equatable, Sendable {
        public var status: AnalysisProfile.RecordStatus
        public var note: String?
        public var rows: [[String: RecordValue]]

        public init(status: AnalysisProfile.RecordStatus, note: String? = nil, rows: [[String: RecordValue]] = []) {
            self.status = status
            self.note = note
            self.rows = rows
        }
    }

    /// The records a review document carries; empty when it carries none.
    /// A record whose status is not a word the app knows is left out.
    public static func of(reviewDocument document: Data) -> ModuleRecords {
        guard let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
              let stored = object["records"] as? [String: Any] else { return ModuleRecords() }
        var records: [String: Record] = [:]
        for (id, value) in stored {
            guard let record = value as? [String: Any],
                  let status = (record["status"] as? String).flatMap(AnalysisProfile.RecordStatus.init) else { continue }
            let rows = (record["rows"] as? [[String: Any]] ?? []).map { $0.mapValues(RecordValue.init) }
            records[id] = Record(status: status, note: record["note"] as? String, rows: rows)
        }
        return ModuleRecords(records)
    }

    /// Each record's status, as a reading keeps it; nil when there is none.
    public var statuses: [String: String]? {
        records.isEmpty ? nil : records.mapValues(\.status.rawValue)
    }

    public subscript(id: String) -> Record? { records[id] }

    /// Whether record `id` is answered: complete, or none with the reason.
    public func answered(_ id: String) -> Bool { records[id]?.status.answers ?? false }

    /// The profile's gated table records not answered — partial ones
    /// included — in the profile's order.
    public func unanswered(profile: AnalysisProfile) -> [String] {
        profile.records.filter { $0.unansweredGate && !$0.columns.isEmpty && !answered($0.id) }.map(\.id)
    }

    // MARK: - Revisions compared

    /// What changed in one record between two revisions, row by row by the
    /// record's key.
    public struct RowChanges: Equatable, Sendable {
        /// Key texts (`RowKey.text`) of rows only the new revision has.
        public var added: [String]
        /// Key texts of rows both have, with different contents.
        public var changed: [String]
        /// Key texts of rows only the old revision has.
        public var removed: [String]
        public var statusChanged: Bool

        public init(added: [String] = [], changed: [String] = [], removed: [String] = [], statusChanged: Bool = false) {
            self.added = added
            self.changed = changed
            self.removed = removed
            self.statusChanged = statusChanged
        }

        public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty && !statusChanged }
    }

    /// The records that differ between `old` and `new`, by the key `profile`
    /// gives each; a record with no change is left out. A record the profile
    /// does not declare is compared by its whole rows.
    public static func diff(_ old: ModuleRecords, _ new: ModuleRecords,
                            profile: AnalysisProfile) -> [String: RowChanges] {
        var answer: [String: RowChanges] = [:]
        for id in Set(old.records.keys).union(new.records.keys) {
            let key = profile.records.first { $0.id == id }?.key ?? []
            let before = old.records[id], after = new.records[id]
            func keyed(_ rows: [[String: RecordValue]]) -> [String: [String: RecordValue]] {
                var keyed: [String: [String: RecordValue]] = [:]
                for row in rows { keyed[rowKey(row, key: key)] = row }
                return keyed
            }
            let a = keyed(before?.rows ?? []), b = keyed(after?.rows ?? [])
            var changes = RowChanges()
            changes.added = b.keys.filter { a[$0] == nil }.sorted()
            changes.removed = a.keys.filter { b[$0] == nil }.sorted()
            changes.changed = b.keys.filter { a[$0] != nil && a[$0] != b[$0] }.sorted()
            changes.statusChanged = (before?.status ?? .unanswered) != (after?.status ?? .unanswered)
            if !changes.isEmpty { answer[id] = changes }
        }
        return answer
    }

    /// A row's key as text, `column value` pairs in the key's order:
    /// `irq 4`, `ports 62/66, cmd 0x80, mode normal`. A record without a key
    /// is keyed by the whole row.
    public static func rowKey(_ row: [String: RecordValue], key: [String]) -> String {
        guard !key.isEmpty else {
            return row.keys.sorted().map { "\($0) \(row[$0]!.text)" }.joined(separator: ", ")
        }
        return key.compactMap { column in
            guard let value = row[column], value != .null else { return nil }
            return "\(column) \(value.text)"
        }.joined(separator: ", ")
    }
}

public extension ContentStore {
    /// The records of the review document the manifest's reading names;
    /// nil when it names none.
    func moduleRecords(for manifest: AnalysisManifest) throws -> ModuleRecords? {
        guard let digest = manifest.reading?.review else { return nil }
        return ModuleRecords.of(reviewDocument: try object(digest))
    }
}

/// One value of a record's row, as JSON has it.
public enum RecordValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([RecordValue])
    case object([String: RecordValue])
    case null

    public init(_ any: Any) {
        switch any {
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber:
            if CFNumberIsFloatType(value) { self = .double(value.doubleValue) } else { self = .int(value.intValue) }
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(RecordValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(RecordValue.init))
        default: self = .null
        }
    }

    /// The value as plain text: a string as it is, a number in decimal, a
    /// list joined with commas, an object as `key value` pairs.
    public var text: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .array(let values): values.map(\.text).joined(separator: ", ")
        case .object(let object): object.keys.sorted().map { "\($0) \(object[$0]!.text)" }.joined(separator: ", ")
        case .null: ""
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var int: Int? {
        switch self {
        case .int(let value): value
        case .string(let text): Self.integer(text)
        default: nil
        }
    }
    public var array: [RecordValue]? { if case .array(let values) = self { values } else { nil } }
    public var object: [String: RecordValue]? { if case .object(let value) = self { value } else { nil } }

    /// `0x1F` or `31`.
    public static func integer(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return Int(trimmed.dropFirst(2), radix: 16) }
        return Int(trimmed)
    }
}

/// The `records_answered` gate as a publish reports it: never a refusal.
public struct RecordsGate: Codable, Equatable, Sendable {
    public var passed: Bool
    /// Gated records with no answer at all.
    public var unanswered: [String]
    /// Gated records the review has begun and not finished: `partial` does
    /// not pass the gate.
    public var partial: [String]

    public init(passed: Bool, unanswered: [String], partial: [String]) {
        self.passed = passed
        self.unanswered = unanswered
        self.partial = partial
    }

    /// The gate for `statuses` (id → status) under `profile`; nil for a
    /// profile without the gate. Only records with a table count: the UEFI
    /// profile's interfaces have their own answer (`ModuleInterfaces`).
    public static func of(profile: AnalysisProfile, statuses: [String: String]) -> RecordsGate? {
        guard profile.gates.contains(where: { $0.id == "records_answered" }) else { return nil }
        var unanswered: [String] = [], partial: [String] = []
        for record in profile.records where record.unansweredGate && !record.columns.isEmpty {
            let status = statuses[record.id].flatMap(AnalysisProfile.RecordStatus.init) ?? .unanswered
            if status == .partial { partial.append(record.id) } else if !status.answers { unanswered.append(record.id) }
        }
        return RecordsGate(passed: unanswered.isEmpty && partial.isEmpty, unanswered: unanswered, partial: partial)
    }

    /// The gate of a stored revision, by the profile it was published under.
    public static func of(reading: AnalysisReading) -> RecordsGate? {
        guard let profile = reading.analysisProfile else { return nil }
        return of(profile: profile, statuses: reading.records ?? [:])
    }
}

public extension AnalysisReading {
    /// The profile the reading names — its current version when the stamp
    /// names an older one — or UEFI's for a reading made before profiles
    /// were recorded.
    var analysisProfile: AnalysisProfile? {
        guard let profile else { return .uefi }
        if let named = AnalysisProfile.named(profile) { return named }
        let id = profile.split(separator: "@").first.map(String.init)
        return AnalysisProfile.catalogue.first { $0.id == id }
    }
}
