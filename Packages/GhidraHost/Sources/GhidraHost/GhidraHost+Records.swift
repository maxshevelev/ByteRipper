import AnalysisProfiles
import CodeAnalysis
import Foundation

/// A review's records — an analysis profile's tables (`irq_map`, `ec_ram`, …)
/// kept in the program and harvested into the review document. The owner
/// checks and keeps the rows; the profile is the host's: it gives each write
/// the record's schema, so the owner holds no copy of a profile, and it
/// answers each read with what only the profile knows — the records not set,
/// which of them keep the review short of complete, and the refs nothing
/// answers.
extension GhidraHost {
    static let setRecordPath = "/v1/set/record"
    static let recordsPath = "/v1/records"

    /// The profile of the module's project; refused when it has none.
    func recordProfile(_ module: SHA256Digest) throws -> AnalysisProfile {
        let state = try project(module).state()
        guard let profile = AnalysisProfile.derive(kind: state.module.kind, ecFamily: state.module.ec?.family) else {
            throw GhidraHostError(.refused, "no analysis profile covers a module of kind \(state.module.kind): "
                                  + "it keeps no records", status: 422)
        }
        return profile
    }

    /// A `set/record` body with the record's schema put in: `key`, `columns`,
    /// `parameters`, and `ref_keys` — the key columns of every record a column
    /// refers to. Refuses a record the profile does not have, or one without a
    /// table.
    func recordWriteBody(_ module: SHA256Digest, body: Data) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw GhidraHostError(.refused, "the body is not a JSON object", status: 400)
        }
        let profile = try recordProfile(module)
        guard let id = object["record"] as? String, !id.isEmpty else {
            throw GhidraHostError(.refused, "give `record`: one of " + profile.records.map(\.id).joined(separator: ", "),
                                  status: 400)
        }
        guard let record = profile.records.first(where: { $0.id == id }) else {
            throw GhidraHostError(.refused, "`\(id)` is not a record of \(profile.stamp): its records are "
                                  + profile.records.map(\.id).joined(separator: ", "), status: 400)
        }
        guard !record.columns.isEmpty else {
            throw GhidraHostError(.refused, "`\(id)` has no columns to write"
                                  + (id == "interfaces" ? ": write it with ghidra_set_interfaces" : ""), status: 400)
        }
        object["schema"] = try Self.schema(of: record, in: profile)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func schema(of record: AnalysisProfile.Record, in profile: AnalysisProfile) throws -> [String: Any] {
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        var refKeys: [String: Any] = [:]
        func collect(_ columns: [AnalysisProfile.Column]) throws {
            for column in columns {
                if let target = column.ref, let referenced = profile.records.first(where: { $0.id == target }) {
                    refKeys[target] = try json(referenced.key.compactMap { referenced.column($0) })
                }
                try collect(column.columns ?? [])
            }
        }
        try collect(record.columns)
        var schema: [String: Any] = ["key": record.key, "columns": try json(record.columns),
                                     "parameters": record.parameters, "ref_keys": refKeys]
        // The branches a note may be given for: the values of the column
        // the list groups by.
        if let group = record.groupBy, let values = record.column(group)?.values, !values.isEmpty {
            schema["branches"] = values
        }
        return schema
    }

    /// The owner's `records` answer as `ghidra_records` gives it: every
    /// record of the profile (or `only`) in its order, each with `status`
    /// (`unanswered` when not set), `note`, `rows`, `gate`; `unanswered`, the
    /// gated records neither complete nor none; `warnings`, the refs no row
    /// answers. With `only`, also the record's `key`, `columns` and
    /// `parameters`.
    func recordsAnswer(_ module: SHA256Digest, owner data: Data, only: String?) throws -> Data {
        let profile = try recordProfile(module)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        // The owner answers every record it holds, so a ref's target is
        // whole even when one record is asked for.
        let stored = object["records"] as? [String: Any] ?? [:]
        if let only, !profile.records.contains(where: { $0.id == only }) {
            throw GhidraHostError(.refused, "`\(only)` is not a record of \(profile.stamp): its records are "
                                  + profile.records.map(\.id).joined(separator: ", "), status: 400)
        }
        var records: [[String: Any]] = []
        var unanswered: [String] = []
        for record in profile.records where record.columns.isEmpty == false {
            let set = stored[record.id] as? [String: Any]
            let status = set?["status"] as? String ?? "unanswered"
            if record.unansweredGate, AnalysisProfile.RecordStatus(rawValue: status)?.answers != true {
                unanswered.append(record.id)
            }
            guard only == nil || only == record.id else { continue }
            var entry: [String: Any] = ["id": record.id, "title": record.title, "status": status,
                                        "gate": record.unansweredGate]
            // All records with their rows outgrow one answer (103 KB on the
            // EC module): without `record` only how many rows each has.
            let rows = set?["rows"] as? [Any] ?? []
            if only != nil { entry["rows"] = rows } else { entry["row_count"] = rows.count }
            if let note = set?["note"] { entry["note"] = note }
            if let notes = set?["branch_notes"] { entry["branch_notes"] = notes }
            if only != nil {
                entry["key"] = record.key
                entry["columns"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.columns))
                if !record.parameters.isEmpty { entry["parameters"] = record.parameters }
            }
            records.append(entry)
        }
        object["records"] = records
        object["unanswered"] = unanswered
        object["warnings"] = Self.danglingRefs(profile, stored)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A ref whose row the target record does not hold: a warning, never a
    /// refusal — the row may come in a later call.
    static func danglingRefs(_ profile: AnalysisProfile, _ stored: [String: Any]) -> [String] {
        func text(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value],
                                                         options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
        func rows(_ id: String) -> [[String: Any]] {
            ((stored[id] as? [String: Any])?["rows"] as? [[String: Any]]) ?? []
        }
        func keyText(_ row: [String: Any], _ key: [String]) -> String {
            text(key.map { row[$0] ?? NSNull() })
        }
        /// A row as a reader names it: `irq 4`, `ports 62/66, cmd 0x80, mode normal`.
        func label(_ row: [String: Any], _ key: [String]) -> String {
            key.compactMap { column in
                guard let value = row[column], !(value is NSNull) else { return nil }
                return "\(column) \(value as? String ?? "\(value)")"
            }.joined(separator: ", ")
        }
        var warnings: [String] = []
        for record in profile.records {
            for column in record.columns where column.kind == .ref || (column.kind == .list && column.of == .ref) {
                guard let target = column.ref,
                      let referenced = profile.records.first(where: { $0.id == target }) else { continue }
                let held = Set(rows(target).map { keyText($0, referenced.key) })
                for row in rows(record.id) {
                    guard let value = row[column.id] else { continue }
                    let values = column.kind == .list ? (value as? [Any] ?? []) : [value]
                    for item in values {
                        let named = referenced.key.count == 1
                            ? keyText([referenced.key[0]: item], referenced.key)
                            : keyText(item as? [String: Any] ?? [:], referenced.key)
                        if !held.contains(named) {
                            warnings.append("\(record.id)[\(label(row, record.key))].\(column.id): "
                                            + "\(item as? String ?? String(text(item).dropFirst().dropLast())) names no row of \(target)")
                        }
                    }
                }
            }
        }
        return warnings
    }
}
