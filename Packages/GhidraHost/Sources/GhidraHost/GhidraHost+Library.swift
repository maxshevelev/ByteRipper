import CodeAnalysis
import Foundation

// The library registry applied to a module (`Design/LIBRARY_REGISTRY_PLAN.md`
// §4): the owner hashes the program's functions against the registry's
// bodies, the host decides what each match calls for, and the owner applies
// the entries under the host's lease.

extension GhidraHost {
    /// What a client asks of a module's matches with the registry.
    public struct LibraryRequest: Codable, Equatable, Sendable {
        public enum Action: String, Codable, Sendable {
            /// The matches and what each calls for; nothing written.
            case status
            /// Every match that applies by itself, or the one at `address`.
            case apply
            /// The entry `id` is not offered for the function at `address` again.
            case decline
            /// One entry: its review and its history.
            case entry
        }

        public var action: Action
        public var address: String?
        public var id: String?
        /// Why a candidate is taken as a variant, or why an entry is declined.
        public var reason: String?
        /// With `address`: the entry's review replaces the function's, where
        /// the function's review differs or was edited since.
        public var replace: Bool?

        public init(action: Action, address: String? = nil, id: String? = nil, reason: String? = nil,
                    replace: Bool? = nil) {
            self.action = action
            self.address = address
            self.id = id
            self.reason = reason
            self.replace = replace
        }
    }

    /// One function as the owner matched it (`POST /v1/library/match`).
    struct LibraryMatch: Decodable, Equatable {
        struct Mark: Decodable, Equatable {
            var id: String
            var version: Int
            var edited: Bool
            var codes: [String]?
        }

        var address: String
        var name: String
        var named: Bool
        var key: String
        var kind: String?
        var exact: String?
        var near: [String]?
        var mark: Mark?
        var declined: [String]?
    }

    /// A constant where the function and an entry of its shape differ.
    public struct LibraryConstant: Codable, Equatable, Sendable {
        public var offset: String
        public var operand: Int
        public var value: String
        public var entryValue: String
        /// The value is the argument of a call to an assert routine.
        public var isAssert: Bool

        private enum CodingKeys: String, CodingKey {
            case offset, operand, value
            case entryValue = "entry_value"
            case isAssert = "assert"
        }
    }

    /// The owner's comparison of a function with an entry of its shape.
    struct LibraryComparison: Decodable, Equatable {
        var comparable: Bool
        var why: String?
        var differences: [LibraryConstant]?
        var assertCodesOnly: Bool?

        private enum CodingKeys: String, CodingKey {
            case comparable, why, differences
            case assertCodesOnly = "assert_codes_only"
        }
    }

    /// What one match calls for.
    public struct LibraryStep: Codable, Equatable, Sendable {
        public var address: String
        /// The function's name now and the entry's.
        public var name: String
        public var entryName: String
        public var id: String
        public var version: Int
        /// `whole`, `fill` or `variant`: how the entry would be applied.
        public var mode: String?
        /// `unnamed`, `named`, `newer_version`, `assert_codes`, `applied`,
        /// `edited`, `candidate` or `declined`.
        public var state: String
        public var codes: [String]?
        public var differences: [LibraryConstant]?
        public var why: String?

        private enum CodingKeys: String, CodingKey {
            case address, name, id, version, mode, state, codes, differences, why
            case entryName = "entry_name"
        }
    }

    /// A module's matches with the registry, sorted by what they call for.
    public struct LibraryPlan: Codable, Equatable, Sendable {
        public var entries: Int
        public var hashed: Int
        /// Functions carrying the current version of their entry.
        public var applied: [LibraryStep] = []
        /// Matches that apply by themselves: a function no review named, one
        /// a review named (the entry's name, and only what the review left
        /// empty), a newer version of an entry applied before, a body that
        /// differs from an entry only in assert codes.
        public var toApply: [LibraryStep] = []
        /// Functions applied from an entry and edited since: the review's now.
        public var edited: [LibraryStep] = []
        /// Bodies of an entry's shape with other constants: other functions
        /// until an agent says why they are not.
        public var candidates: [LibraryStep] = []
        public var declined: [LibraryStep] = []

        private enum CodingKeys: String, CodingKey {
            case entries, hashed, applied, edited, candidates, declined
            case toApply = "to_apply"
        }
    }

    // MARK: - Deciding

    /// `<size>-<full>` of a body key: what bodies that differ only in constants share.
    static func shape(of key: String) -> String {
        key.split(separator: "-").prefix(2).joined(separator: "-")
    }

    /// The keys the owner matches against: every body of every entry, and
    /// the shapes with the entries that have one.
    static func libraryKeys(_ index: LibraryIndex) -> (bodies: [String: String], shapes: [String: [String]]) {
        var shapes: [String: [String]] = [:]
        for (key, id) in index.bodies {
            let shape = shape(of: key)
            if !(shapes[shape] ?? []).contains(id) { shapes[shape, default: []].append(id) }
        }
        return (index.bodies, shapes.mapValues { $0.sorted() })
    }

    /// The pairs of a function and an entry of its shape that the owner is
    /// asked to compare: bodies with no exact match, not yet the entry's.
    static func comparisons(_ matches: [LibraryMatch]) -> [(address: String, id: String)] {
        matches.flatMap { match -> [(address: String, id: String)] in
            guard match.exact == nil else { return [] }
            return (match.near ?? []).filter { id in
                !(match.declined ?? []).contains(id) && match.mark?.id != id
            }.map { (match.address, $0) }
        }
    }

    /// What each match calls for (`LIBRARY_REGISTRY_PLAN.md` §1, "Applying an
    /// exact match", and "Other constants are another function").
    static func libraryPlan(_ matches: [LibraryMatch], index: LibraryIndex, hashed: Int,
                            comparisons: [String: LibraryComparison]) -> LibraryPlan {
        var plan = LibraryPlan(entries: index.entries.count, hashed: hashed)
        for match in matches {
            func step(_ id: String, _ held: LibraryIndexEntry, mode: String?, state: String,
                      codes: [String]? = nil, differences: [LibraryConstant]? = nil, why: String? = nil) -> LibraryStep {
                LibraryStep(address: match.address, name: match.name, entryName: held.name, id: id,
                            version: held.version, mode: mode, state: state, codes: codes,
                            differences: differences, why: why)
            }
            // A function carrying an entry's mark: current, behind, or the
            // review's since it was edited.
            func marked(_ id: String, _ held: LibraryIndexEntry, mode: String) -> Bool {
                guard let mark = match.mark, mark.id == id else { return false }
                if mark.edited {
                    plan.edited.append(step(id, held, mode: nil, state: "edited",
                                            why: mark.version < held.version
                                                ? "version \(held.version) is newer than the v\(mark.version) applied" : nil))
                } else if mark.version >= held.version {
                    plan.applied.append(step(id, held, mode: nil, state: "applied", codes: mark.codes))
                } else {
                    plan.toApply.append(step(id, held, mode: mode, state: "newer_version", codes: mark.codes))
                }
                return true
            }
            if let id = match.exact, let held = index.entries[id] {
                if (match.declined ?? []).contains(id) {
                    plan.declined.append(step(id, held, mode: nil, state: "declined"))
                } else if marked(id, held, mode: "whole") {
                } else if !match.named {
                    plan.toApply.append(step(id, held, mode: "whole", state: "unnamed"))
                } else {
                    plan.toApply.append(step(id, held, mode: "fill", state: "named"))
                }
                continue
            }
            var applying = false
            for id in match.near ?? [] {
                guard let held = index.entries[id] else { continue }
                if (match.declined ?? []).contains(id) {
                    plan.declined.append(step(id, held, mode: nil, state: "declined"))
                    continue
                }
                if marked(id, held, mode: "variant") { applying = true; continue }
                let comparison = comparisons["\(match.address) \(id)"]
                if !applying, let comparison, comparison.comparable, comparison.assertCodesOnly == true {
                    applying = true
                    plan.toApply.append(step(id, held, mode: "variant", state: "assert_codes",
                                             codes: comparison.differences?.map(\.value),
                                             differences: comparison.differences))
                } else {
                    plan.candidates.append(step(id, held, mode: "variant", state: "candidate",
                                                differences: comparison?.differences,
                                                why: comparison?.why ?? (comparison == nil
                                                    ? "not compared" : "other constants: another function, "
                                                        + "until a review says why they make no difference")))
                }
            }
        }
        return plan
    }

    // MARK: - Asking the owner

    /// The registry against the module: an answer for `ghidra_library` and
    /// `ghidra_library_apply`, and what `ghidra_open` applies.
    public func library(_ module: SHA256Digest, _ request: LibraryRequest) async throws -> Data {
        switch request.action {
        case .entry:
            guard let id = request.id else { throw GhidraHostError(.refused, "name the entry by `id`", status: 400) }
            let index = try await writer.readLibraryIndex()
            guard let held = index.entries[id] else {
                throw GhidraHostError(.refused, "the registry holds no entry \(id)", status: 404)
            }
            let review = try JSONSerialization.jsonObject(with: try await writer.readObject(held.entry))
            var answer: [String: Any] = ["id": id, "index": try Self.plain(held), "review": review]
            if let history = try await writer.readLibraryHistory(id: id) { answer["history"] = try Self.plain(history) }
            return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        case .status:
            let (plan, _) = try await libraryPlan(module)
            return try JSONSerialization.data(withJSONObject: try Self.plain(plan), options: [.sortedKeys])
        case .decline:
            guard let address = request.address else {
                throw GhidraHostError(.refused, "name the function by `address`", status: 400)
            }
            let (plan, _) = try await libraryPlan(module)
            let all = plan.toApply + plan.candidates + plan.applied + plan.edited
            guard let id = request.id ?? all.first(where: { $0.address == address })?.id else {
                throw GhidraHostError(.refused, "no entry matches the function at \(address)", status: 404)
            }
            let body = try JSONSerialization.data(withJSONObject: ["address": address, "id": id,
                                                                   "reason": request.reason ?? "", "by": "agent"])
            return try await write(module, "/v1/library/decline", body: body)
        case .apply:
            let (plan, index) = try await libraryPlan(module)
            var steps = plan.toApply
            if let address = request.address {
                steps = try Self.chosen(plan, address: address, id: request.id, reason: request.reason,
                                        replace: request.replace ?? false)
            }
            var answer = try Self.plain(plan) as? [String: Any] ?? [:]
            guard !steps.isEmpty else {
                answer["results"] = []
                return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
            }
            var items: [[String: Any]] = []
            for step in steps {
                guard let held = index.entries[step.id] else { continue }
                var item: [String: Any] = [
                    "address": step.address, "id": step.id, "version": held.version,
                    "entry": try JSONSerialization.jsonObject(with: try await writer.readObject(held.entry)),
                    "mode": step.mode ?? "fill"
                ]
                item["codes"] = step.codes
                if request.address != nil { item["reason"] = request.reason }
                items.append(item)
            }
            let body = try JSONSerialization.data(withJSONObject: ["items": items])
            let applied = try JSONSerialization.jsonObject(with: try await write(module, "/v1/library/apply", body: body))
            answer["results"] = (applied as? [String: Any])?["items"] ?? []
            return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        }
    }

    /// The step `ghidra_library_apply` names by address: a match that
    /// applies by itself; a candidate, taken as a variant with a reason; or
    /// with `replace`, a function whose review differs or was edited since.
    static func chosen(_ plan: LibraryPlan, address: String, id: String?, reason: String?,
                       replace: Bool) throws -> [LibraryStep] {
        func at(_ steps: [LibraryStep]) -> LibraryStep? {
            steps.first { $0.address.caseInsensitiveCompare(address) == .orderedSame && (id == nil || $0.id == id) }
        }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if var step = at(plan.toApply) {
            if replace, step.mode == "fill" { step.mode = "whole" }
            return [step]
        }
        if var step = at(plan.candidates) {
            guard !reason.isEmpty else {
                throw GhidraHostError(.refused, "the function at \(address) holds other constants than "
                    + "\(step.entryName): say in `reason` why they make no difference, or review it as a "
                    + "function of its own", status: 409)
            }
            step.codes = step.differences?.map(\.value)
            return [step]
        }
        if var step = at(plan.edited) ?? at(plan.applied) ?? at(plan.declined) {
            guard replace else {
                throw GhidraHostError(.refused, "the function at \(address) is \(step.state): `replace: true` "
                    + "puts the entry's review in place of the function's", status: 409)
            }
            step.mode = step.codes == nil ? "whole" : "variant"
            return [step]
        }
        throw GhidraHostError(.refused, "no registry entry matches the function at \(address)", status: 404)
    }

    /// The module's matches and what each calls for, with the index they were made against.
    func libraryPlan(_ module: SHA256Digest) async throws -> (LibraryPlan, LibraryIndex) {
        let index = try await writer.readLibraryIndex()
        guard !index.entries.isEmpty else { return (LibraryPlan(entries: 0, hashed: 0), index) }
        let record = try await owner(of: module)
        let keys = Self.libraryKeys(index)
        let request = try JSONSerialization.data(withJSONObject: ["bodies": keys.bodies, "shapes": keys.shapes])
        let data = try await Self.call(record.port, "POST", "/v1/library/match", body: request, timeout: 600).data
        struct Answer: Decodable { var hashed: Int; var matches: [LibraryMatch] }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        let asserts = index.entries.filter { $0.value.role == "assert" }
        let assertKeys = asserts.values.flatMap { $0.variants.map(\.body.key) }.sorted()
        var comparisons: [String: LibraryComparison] = [:]
        for (address, id) in Self.comparisons(answer.matches) {
            guard let held = index.entries[id] else { continue }
            let entry = try JSONSerialization.jsonObject(with: try await writer.readObject(held.entry))
            let body = try JSONSerialization.data(withJSONObject: [
                "address": address, "entry": entry, "assert_keys": assertKeys,
                "assert_ids": asserts.keys.sorted()
            ])
            let compared = try await Self.call(record.port, "POST", "/v1/library/compare", body: body).data
            comparisons["\(address) \(id)"] = try JSONDecoder().decode(LibraryComparison.self, from: compared)
        }
        return (Self.libraryPlan(answer.matches, index: index, hashed: answer.hashed, comparisons: comparisons), index)
    }

    /// A Codable value as plain JSON objects, to put beside the owner's own.
    static func plain<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: try encoder.encode(value))
    }
}
