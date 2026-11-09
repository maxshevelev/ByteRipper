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
            /// `candidates` are proposed for the registry, `remove` no longer: in the
            /// project only, and the next publish decides.
            case candidate
            /// One entry: its review and its history.
            case entry
            /// The entry `id` takes the narrower `name`, for `reason`.
            case rename
            /// A write on the registry itself: `change`.
            case change
        }

        public var action: Action
        public var address: String?
        public var id: String?
        /// Why a candidate is taken as a variant, or why an entry is declined.
        public var reason: String?
        public var candidates: [LibraryCandidate]?
        /// The addresses of functions that are candidates no longer.
        public var remove: [String]?
        /// The name `rename` gives the entry.
        public var name: String?
        public var change: LibraryChange?
        /// `apply` at `address` puts the entry's text in the project, in place of
        /// the function's own, for a review that goes on writing over it.
        public var takeText: Bool?
        /// Answer what the apply would do and write nothing: each entry is
        /// applied in its transaction and rolled back.
        public var dryRun: Bool?

        public init(action: Action, address: String? = nil, id: String? = nil, reason: String? = nil,
                    candidates: [LibraryCandidate]? = nil, remove: [String]? = nil, dryRun: Bool? = nil, name: String? = nil,
                    change: LibraryChange? = nil, takeText: Bool? = nil) {
            self.takeText = takeText
            self.candidates = candidates
            self.remove = remove
            self.change = change
            self.name = name
            self.action = action
            self.address = address
            self.id = id
            self.reason = reason
            self.dryRun = dryRun
        }
    }

    /// A function proposed for the registry, and whose library it is: edk2, amd or intel.
    public struct LibraryCandidate: Codable, Equatable, Sendable {
        public var address: String
        public var kind: String
        /// An assert routine: the codes it is called with make variants of the
        /// entries that call it, not functions of their own.
        public var assertRoutine: Bool?

        enum CodingKeys: String, CodingKey {
            case address, kind
            case assertRoutine = "assert_routine"
        }

        public init(address: String, kind: String, assertRoutine: Bool? = nil) {
            self.address = address
            self.kind = kind
            self.assertRoutine = assertRoutine
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
        var exact: String?
        var near: [String]?
        var mark: Mark?
        var declined: [String]?
        /// The digest of what the body's data references point at.
        var referenceBytes: String?
        /// A plate or a comment is written in the project.

        private enum CodingKeys: String, CodingKey {
            case address, name, named, key, exact, near, mark, declined
            case referenceBytes = "reference_bytes"
        }
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
        /// `link`: the function holds the entry's number, and its name and
        /// signature for its callers to print. Everything else is the entry's.
        public var mode: String?
        /// `unnamed`, `named`, `copy`, `newer_version`, `assert_codes`, `applied`,
        /// `edited`, `candidate`, `short_candidate`, `reference_bytes` or `declined`.
        public var state: String
        public var codes: [String]?
        public var differences: [LibraryConstant]?
        public var why: String?
        /// What the function's own review lacks — the live program's, read by
        /// the owner.
        public var gaps: [String]?
        /// What the entry's review lacks, filled by the host from the entry
        /// object for the steps a decision is made about.
        public var entryGaps: [String]?

        private enum CodingKeys: String, CodingKey {
            case address, name, id, version, mode, state, codes, differences, why, gaps
            case entryName = "entry_name"
            case entryGaps = "entry_gaps"
        }
    }

    /// A module's matches with the registry, sorted by what they call for.
    public struct LibraryPlan: Codable, Equatable, Sendable {
        public var entries: Int
        public var hashed: Int
        /// Functions carrying the current version of their entry.
        public var applied: [LibraryStep] = []
        /// Matches that link by themselves: a body the registry holds is the
        /// entry's, whatever the project wrote on it.
        public var toApply: [LibraryStep] = []
        /// Functions applied from an entry and edited since: the review's now.
        public var edited: [LibraryStep] = []
        /// Bodies of an entry's shape with other constants: other functions
        /// until an agent says why they are not.
        public var candidates: [LibraryStep] = []
        public var declined: [LibraryStep] = []
        /// Functions whose body the registry gave back: the module keeps the
        /// text, and the function stops being offered as a library function.
        public var released: [LibraryStep] = []

        private enum CodingKeys: String, CodingKey {
            case entries, hashed, applied, edited, candidates, declined, released
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
        // A body taken out is still looked for: its functions have to be told.
        var bodies = index.bodies
        for (key, out) in index.takenOut ?? [:] { bodies[key] = out.id }
        return (bodies, shapes.mapValues { $0.sorted() })
    }

    /// The pairs of a function and an entry of its shape that the owner is
    /// asked to compare: bodies with no exact match, not yet the entry's.
    static func comparisons(_ matches: [LibraryMatch]) -> [(address: String, id: String)] {
        matches.flatMap { match -> [(address: String, id: String)] in
            guard match.exact == nil, !LibraryBody.isShort(key: match.key) else { return [] }
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
            // The module's function again, if it ever took the entry or was
            // offered as one. Any other function of that body stays untouched:
            // no review of this module said anything about it.
            if let out = index.takenOut?[match.key] {
                if match.mark != nil {
                    plan.released.append(LibraryStep(address: match.address, name: match.name, entryName: out.name,
                                                     id: match.key, version: out.version, mode: "release",
                                                     state: "taken_out", why: out.reason))
                }
                continue
            }
            // A mark on an entry given back, from a body of its own: the same.
            if let mark = match.mark, index.entries[mark.id] == nil,
               let (key, out) = index.takenOut?.first(where: { $0.value.id == mark.id }) {
                plan.released.append(LibraryStep(address: match.address, name: match.name, entryName: out.name,
                                                 id: key, version: out.version, mode: "release",
                                                 state: "taken_out", why: out.reason))
                continue
            }
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
                    // Bound and not dirty: what its project holds stays there.
                    plan.applied.append(step(id, held, mode: nil, state: "applied", codes: mark.codes))
                } else {
                    plan.toApply.append(step(id, held, mode: mode, state: "newer_version", codes: mark.codes))
                }
                return true
            }
            if let id = match.exact, let held = index.entries[id] {
                // One key, other data: another function, whatever it was before.
                if index.bytesDiffer(id: id, body: match.key, referenceBytes: match.referenceBytes) {
                    plan.candidates.append(step(id, held, mode: nil, state: "reference_bytes",
                                                why: "its data references point at other bytes than the entry holds: "
                                                    + "another function"))
                    continue
                }
                if (match.declined ?? []).contains(id) {
                    plan.declined.append(step(id, held, mode: nil, state: "declined"))
                } else if !marked(id, held, mode: "link") {
                    plan.toApply.append(step(id, held, mode: "link", state: match.named ? "named" : "unnamed"))
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
                if marked(id, held, mode: "link") { applying = true; continue }
                // A short body: the same bytes, and a review says which function
                // it is, from how it is called. Nothing links by itself.
                if LibraryBody.isShort(key: match.key) {
                    if match.mark == nil {
                        plan.candidates.append(step(id, held, mode: "link", state: "short_candidate",
                                                    why: "the same bytes as this entry: bind it if the calls show it is that function"))
                    }
                    continue
                }
                let comparison = comparisons["\(match.address) \(id)"]
                if !applying, let comparison, comparison.comparable, comparison.assertCodesOnly == true {
                    applying = true
                    plan.toApply.append(step(id, held, mode: "link", state: "assert_codes",
                                             codes: comparison.differences?.map(\.value),
                                             differences: comparison.differences))
                } else {
                    plan.candidates.append(step(id, held, mode: "link", state: "candidate",
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

    /// A write on the registry itself: the store's rows, naming the module the
    /// write was asked from and the reason it was asked with.
    private static func naming(_ result: LibraryWriteResult, module: SHA256Digest,
                               reason: String?) -> LibraryWriteResult {
        func named(_ rows: [LibraryWriteResult.Change]) -> [LibraryWriteResult.Change] {
            rows.map { row in
                var row = row
                row.module = row.module ?? module
                row.reason = row.reason ?? reason
                return row
            }
        }
        var result = result
        result.added = named(result.added)
        result.updated = named(result.updated)
        result.takenOut = result.takenOut.map(named)
        return result
    }

    /// The registry against the module: an answer for `ghidra_library` and
    /// `ghidra_library_apply`, and what `ghidra_create` applies.
    public func library(_ module: SHA256Digest, _ request: LibraryRequest, holder: String? = nil) async throws -> Data {
        // What writes the module's program needs it in work; the registry's
        // own entries and a read do not.
        switch request.action {
        case .apply, .decline, .candidate: try requireLease(module, holder: holder)
        case .status, .entry: try tellClosed(module, holder: holder)
        case .rename, .change: break
        }
        switch request.action {
        case .rename:
            guard let id = request.id, let name = request.name, let reason = request.reason else {
                throw GhidraHostError(.refused, "renaming an entry takes `id`, `name` and `reason`", status: 400)
            }
            let result = try await writer.renameLibraryEntry(id: id, name: name, reason: reason, by: "agent",
                                                             module: module, dryRun: request.dryRun ?? false)
            return try JSONSerialization.data(withJSONObject: try Self.plain(Self.naming(result, module: module, reason: reason)),
                                              options: [.sortedKeys])
        case .change:
            guard let change = request.change else {
                throw GhidraHostError(.refused, "no change named", status: 400)
            }
            let result = try await writer.changeLibrary(change, by: "agent", module: module,
                                                        dryRun: request.dryRun ?? false)
            return try JSONSerialization.data(withJSONObject: try Self.plain(Self.naming(result, module: module, reason: change.reason)),
                                              options: [.sortedKeys])
        case .entry:
            guard let id = request.id else { throw GhidraHostError(.refused, "name the entry by `id`", status: 400) }
            let index = try await writer.readLibraryIndex()
            guard let held = index.entries[id] else {
                throw GhidraHostError(.refused, "the registry holds no entry \(id)", status: 404)
            }
            let object = try await writer.readObject(held.entry)
            let (lighter, parts) = LibraryEntryParts.lighter(object)
            let review = try JSONSerialization.jsonObject(with: lighter)
            var answer: [String: Any] = ["id": id, "index": try Self.plain(held), "review": review,
                                         "gaps": LibraryEntryReview.gaps(of: object)]
            if !parts.isEmpty {
                answer["function_parts"] = parts.mapValues { ["items": $0.items, "bytes": $0.bytes] }
            }
            if let history = try await writer.readLibraryHistory(id: id) { answer["history"] = try Self.plain(history) }
            return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        case .candidate:
            let candidates = request.candidates ?? [], remove = request.remove ?? []
            guard !candidates.isEmpty || !remove.isEmpty else {
                throw GhidraHostError(.refused, "name the functions: `functions`, each with its `kind`, or `remove`", status: 400)
            }
            // A candidate is a function new to the registry. One it holds already
            // is bound to its entry, and a change to it offers itself at a publish.
            if !candidates.isEmpty {
                let (plan, _) = try await libraryPlan(module)
                let held = plan.toApply + plan.applied + plan.edited
                for candidate in candidates {
                    if let step = held.first(where: { $0.address.caseInsensitiveCompare(candidate.address) == .orderedSame }) {
                        throw GhidraHostError(.refused, "the function at \(candidate.address) is entry \(step.id) (\(step.entryName)) "
                            + "of the registry already: no candidate. A change to it offers itself at a publish", status: 409)
                    }
                }
            }
            return try await write(module, "/v1/library/candidate", body: try JSONSerialization.data(
                withJSONObject: ["items": try Self.plain(candidates), "remove": remove]), byHost: true)
        case .status:
            let (plan, _) = try await libraryPlan(module)
            return try JSONSerialization.data(withJSONObject: try Self.plain(plan), options: [.sortedKeys])
        case .decline:
            guard let address = request.address else {
                throw GhidraHostError(.refused, "name the function by `address`", status: 400)
            }
            let (plan, _) = try await libraryPlan(module)
            guard let id = Self.declineTarget(plan, address: address, id: request.id) else {
                throw GhidraHostError(.refused, "no entry matches the function at \(address)", status: 404)
            }
            // A dry run answers what the decline would leave, and writes nothing.
            if request.dryRun == true {
                return try JSONSerialization.data(withJSONObject: Self.dryDecline(plan, address: address, id: id),
                                                  options: [.sortedKeys])
            }
            let body = try JSONSerialization.data(withJSONObject: ["address": address, "id": id,
                                                                   "reason": request.reason ?? "", "by": "agent"])
            return try await write(module, "/v1/library/decline", body: body, byHost: true)
        case .apply:
            // Linking entries, as an open does, is no review of this module.
            let before = request.address == nil ? (try? project(module).state())?.reviewed : nil
            defer {
                if let before, var state = try? project(module).state(), state.reviewed != before {
                    state.reviewed = before
                    try? project(module).write(state)
                }
            }
            let (plan, index) = try await libraryPlan(module)
            var steps = plan.toApply
            if let address = request.address {
                steps = try Self.chosen(plan, address: address, id: request.id, reason: request.reason)
            }
            var answer = try Self.plain(plan) as? [String: Any] ?? [:]
            // What the registry gave back goes with a plain apply and an open.
            if request.address == nil, !plan.released.isEmpty, request.dryRun != true {
                answer["released"] = try await releaseGivenBack(module, plan: plan, index: index)
            }
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
                    // `take_text` brings the entry's text to the function: its own
                    // goes, and what the review writes next stands on the entry's.
                    "mode": request.takeText == true && request.address != nil
                        ? (step.codes == nil ? "whole" : "variant") : "link"
                ]
                item["codes"] = step.codes
                if request.address != nil {
                    item["reason"] = request.reason
                    // One decompile, for the one function a reader asked about;
                    // applying every match — an open does — pays nothing.
                    item["leftovers"] = true
                }
                items.append(item)
            }
            let body = try JSONSerialization.data(withJSONObject: ["items": items])
            let path = request.dryRun == true ? "/v1/library/apply?dry_run=1" : "/v1/library/apply"
            let applied = try JSONSerialization.jsonObject(with: try await write(module, path, body: body, byHost: true))
            answer["results"] = (applied as? [String: Any])?["items"] ?? []
            return try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        }
    }

    /// The entry a decline at `address` names: `id` when given, else the one
    /// matching there — declined already included, so a decline said twice
    /// answers the same rather than "no entry".
    static func declineTarget(_ plan: LibraryPlan, address: String, id: String?) -> String? {
        if let id { return id }
        let all = plan.toApply + plan.candidates + plan.applied + plan.edited + plan.declined
        return all.first(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame })?.id
    }

    /// What a decline would answer, for a dry run: the entries declined at
    /// `address` with `id` among them. Nothing is written.
    static func dryDecline(_ plan: LibraryPlan, address: String, id: String) -> [String: Any] {
        var declined = plan.declined
            .filter { $0.address.caseInsensitiveCompare(address) == .orderedSame }.map(\.id)
        if !declined.contains(id) { declined.append(id) }
        return ["address": address, "id": id, "declined": declined, "dry_run": true]
    }

    /// The entries this module is the source of learn what their data references
    /// point at. A linked function offers no review, so nothing else tells them.
    func teachEntryBytes(_ module: SHA256Digest, rev: Int?, by: String?) async throws {
        let index = try await writer.readLibraryIndex()
        var unlearned: [String: (id: String, name: String, kind: String?, body: LibraryBody)] = [:]
        for (id, entry) in index.entries {
            for variant in entry.variants where variant.module == module && variant.referenceBytes == nil {
                unlearned[variant.body.key] = (id, entry.name, entry.kind, variant.body)
            }
        }
        guard !unlearned.isEmpty else { return }
        let record = try await owner(of: module)
        let bodies = unlearned.mapValues(\.id)
        let request = try JSONSerialization.data(withJSONObject: ["bodies": bodies, "shapes": [String: [String]]()])
        let data = try await Self.call(record.port, "POST", "/v1/library/match", body: request, timeout: 600).data
        struct Answer: Decodable { var matches: [LibraryMatch] }
        let proposals = try JSONDecoder().decode(Answer.self, from: data).matches.compactMap { match -> LibraryProposal? in
            guard let bytes = match.referenceBytes, let held = unlearned[match.key] else { return nil }
            return LibraryProposal(body: held.body, name: held.name, kind: held.kind ?? "", address: match.address,
                                   entry: Data("{}".utf8), referenceBytes: bytes, teachesBytesOnly: true)
        }
        guard !proposals.isEmpty else { return }
        _ = try await writer.writeLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: .none)
    }

    /// What a publish must tell the registry so that no link reads an entry with
    /// no text. A function that becomes a link to an entry holding no function
    /// records its C there when its review in this module is the entry's — the
    /// owner's offer of a linked function that `withoutLinked` keeps, so nothing
    /// is added here — or only adds to it, or when an administrator takes this
    /// module's review of it; those two are the entry's next version. Any other is a
    /// refusal of the whole publish: a library function's text is never kept in
    /// a module, a link with none reads as nothing, and a C whose review differs
    /// from the entry's would carry a replacement nobody took.
    static func completions(_ raw: Data, offer: [LibraryProposal], offered: [LibraryProposal], reviewed: Bool,
                            take: LibraryTake, writer: any AnalysisWriter) async throws
        -> (proposals: [LibraryProposal], refused: [LibraryRefusal.Row]) {
        let index = try await writer.readLibraryIndex()
        let links = await Self.stored(raw, writer: writer).entries
        guard !links.isEmpty else { return ([], []) }
        var names: [UInt64: String] = [:]
        if let read = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            for function in read["functions"] as? [[String: Any]] ?? [] {
                if let text = function["entry"] as? String, let at = Self.addressValue(text) {
                    names[at] = function["name"] as? String
                }
            }
        }
        let offeredAt = Set(offered.compactMap { Self.addressValue($0.address) })
        var proposals: [LibraryProposal] = [], refused: [LibraryRefusal.Row] = []
        for (address, id) in links.sorted(by: { $0.key < $1.key }) {
            guard let at = Self.addressValue(address), !offeredAt.contains(at), let held = index.entries[id] else { continue }
            let object = try await writer.readObject(held.entry)
            guard let fields = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any],
                  fields["function"] == nil else { continue }
            let name = names[at] ?? held.name
            let lacks = "it would link to the entry \(id), which holds no C"
            guard reviewed else {
                refused.append(.init(address: address, name: name, why: lacks + ", and a publish with no review cannot record it"))
                continue
            }
            guard let own = offer.first(where: { Self.addressValue($0.address) == at }),
                  LibraryProposal.hasFunctionText(own.entry) else {
                refused.append(.init(address: address, name: name, why: lacks
                    + ", and this module offers no review of it the registry could record (short of the bar, or not marked): "
                    + "take the entry's text with `ghidra_library_apply` and `take_text`"))
                continue
            }
            // What only adds to the entry is its next version, from any module; a
            // replacement only an administrator's decision takes.
            if take.all || take.reasons[id] != nil || LibraryProposal.onlyAdds(to: object, offered: own.entry) {
                var taken = own
                taken.basedOn = id
                taken.base = held.version
                taken.linked = false
                proposals.append(taken)
                continue
            }
            let changed = LibraryProposal.changedFields(from: object, to: own.entry)
                .filter { !["body", "constants", "function", "equates"].contains($0) }
            refused.append(.init(address: address, name: name, why: lacks
                + ", and its review here differs from the entry's (" + changed.joined(separator: ", ") + "): "
                + "take the entry's text with `ghidra_library_apply` and `take_text`, or an administrator "
                + "takes this module's review with `take_library_conflicts`"))
        }
        return (proposals, refused)
    }

    /// The bodies the registry holds with no code take it from this module.
    func teachEntryCode(_ module: SHA256Digest, artifact: Data, rev: Int?, by: String?) async throws -> LibraryWriteResult? {
        let index = try await writer.readLibraryIndex()
        let proposals = ModuleFormat.teachings(artifact, index: index).map { teaching in
            var proposal = LibraryProposal(body: teaching.variant.body, name: teaching.name, kind: teaching.kind,
                                           address: teaching.address, entry: Data("{}".utf8), basedOn: teaching.id,
                                           teachesBytesOnly: true)
            proposal.code = teaching.code
            return proposal
        }
        guard !proposals.isEmpty else { return nil }
        return try await writer.writeLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: .none)
    }

    /// The entries this module is the source of, from before entries recorded
    /// their equates, learn the ones their C already prints. A linked function
    /// offers no review, so nothing else tells them. The project still holds
    /// its equates, and its C prints them.
    func teachEntryEquates(_ module: SHA256Digest, artifact: Data, rev: Int?, by: String?) async throws {
        let index = try await writer.readLibraryIndex()
        var unlearned: [(id: String, row: LibraryIndexEntry, body: LibraryBody, object: Data)] = []
        for (id, entry) in index.entries {
            guard let body = entry.variants.first(where: { $0.module == module })?.body,
                  let object = try? await writer.readObject(entry.entry),
                  let fields = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any],
                  fields["equates"] == nil, fields["function"] != nil else { continue }
            unlearned.append((id, entry, body, object))
        }
        guard !unlearned.isEmpty,
              let read = (try? JSONSerialization.jsonObject(with: artifact)) as? [String: Any] else { return }
        let equates = read["equates"] as? [[String: Any]] ?? []
        guard !equates.isEmpty else { return }
        var byBody: [String: [String: Any]] = [:]
        for function in read["functions"] as? [[String: Any]] ?? [] {
            if let key = function["body"] as? String { byBody[key] = function }
        }
        let proposals = unlearned.compactMap { held -> LibraryProposal? in
            guard let function = byBody[held.body.key], let address = function["entry"] as? String,
                  let entry = Self.withEquatesItPrints(held.object, of: function, in: equates) else { return nil }
            return LibraryProposal(body: held.body, name: held.row.name, kind: held.row.kind ?? "", address: address,
                                   entry: entry, basedOn: held.id, base: held.row.version)
        }
        guard !proposals.isEmpty else { return }
        _ = try await writer.writeLibraryEntries(module: module, rev: rev, by: by, proposals: proposals, take: .none)
    }

    /// The held entry with the equates both its C and the project's print, nil
    /// if none. A name only the project prints is a change, and asks a reason.
    static func withEquatesItPrints(_ held: Data, of function: [String: Any], in equates: [[String: Any]]) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              let c = (object["function"] as? [String: Any])?["c"] as? String,
              let printed = printedEquates(of: function, in: equates) else { return nil }
        let both = printed.filter { row in
            guard let name = row["name"] as? String else { return false }
            return c.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
        }
        guard !both.isEmpty else { return nil }
        object["equates"] = both
        return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// The step `ghidra_library_apply` names by address: a match that links by
    /// itself; a candidate, with a reason where its constants differ; or a
    /// dirty function, which stops being dirty and offers nothing.
    static func chosen(_ plan: LibraryPlan, address: String, id: String?, reason: String?) throws -> [LibraryStep] {
        func at(_ steps: [LibraryStep]) -> LibraryStep? {
            steps.first { $0.address.caseInsensitiveCompare(address) == .orderedSame && (id == nil || $0.id == id) }
        }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let step = at(plan.toApply) { return [step] }
        if var step = at(plan.candidates) {
            if step.state == "short_candidate" { return [step] }
            guard !reason.isEmpty else {
                throw GhidraHostError(.refused, "the function at \(address) holds other constants than "
                    + "\(step.entryName): say in `reason` why they make no difference, or review it as a "
                    + "function of its own", status: 409)
            }
            step.codes = step.differences?.map(\.value)
            return [step]
        }
        if var step = at(plan.edited) ?? at(plan.applied) ?? at(plan.declined) {
            step.mode = "link"
            return [step]
        }
        throw GhidraHostError(.refused, "no registry entry matches the function at \(address)", status: 404)
    }

    /// Whether the module's running owner holds a program the store has not
    /// got — modified after the last publish — and nil when no owner runs for
    /// it.
    public func ownerHasUnpublishedWrites(_ module: SHA256Digest) async throws -> Bool? {
        let project = self.project(module)
        guard project.exists, let record = await runningOwner(project) else { return nil }
        let data = try await Self.call(record.port, "GET", "/v1/hello", timeout: 10).data
        guard let hello = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.holdsUnpublishedWrites(hello: hello, published: (try? project.state())?.published)
    }

    /// The owner's count of changes against the one the last publish recorded.
    /// A publish made before the count existed recorded none: any count at all
    /// is then work done since. An owner that has no count compares the
    /// modification number, which holds only within one of its sessions.
    static func holdsUnpublishedWrites(hello: [String: Any], published: ProjectState.Published?) -> Bool? {
        if let writes = hello["writes"] as? Int {
            if let recorded = published?.writes { return writes > recorded }
            return writes > 0 || hello["changed"] as? Bool == true
        }
        if let recorded = published?.modification, let modification = hello["modification"] as? Int {
            return modification > recorded
        }
        return hello["changed"] as? Bool
    }

    /// The module's matches and what each calls for, with the index they were made against.
    func libraryPlan(_ module: SHA256Digest) async throws -> (LibraryPlan, LibraryIndex) {        let index = try await writer.readLibraryIndex()
        guard !index.entries.isEmpty || index.takenOut?.isEmpty == false else { return (LibraryPlan(entries: 0, hashed: 0), index) }
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
        var plan = Self.libraryPlan(answer.matches, index: index, hashed: answer.hashed,
                                    comparisons: comparisons)
        // Both reviews' gaps, for the comparison a decision is made on. The
        // function's are the last published analysis's, not the listing's:
        // the listing's locals include stack slots the decompiled C never
        // mentions, and reading them would call a finished function unfinished.
        let stored = try? await writer.reviewGaps(module: module)
        var entryGaps: [String: [String]] = [:]
        for id in Set((plan.applied + plan.toApply + plan.edited + plan.candidates + plan.declined).map(\.id)) {
            guard let held = index.entries[id], let data = try? await writer.readObject(held.entry) else { continue }
            entryGaps[id] = LibraryEntryReview.gaps(of: data)
        }
        func attached(_ steps: [LibraryStep]) -> [LibraryStep] {
            steps.map { step in
                var step = step
                step.entryGaps = entryGaps[step.id]
                if let stored { step.gaps = stored[step.address.lowercased()] }
                return step
            }
        }
        plan.applied = attached(plan.applied)
        plan.toApply = attached(plan.toApply)
        plan.edited = attached(plan.edited)
        plan.candidates = attached(plan.candidates)
        plan.declined = attached(plan.declined)
        return (plan, index)
    }

    /// A Codable value as plain JSON objects, to put beside the owner's own.
    /// For each conflicting entry, by id: every field the module's review
    /// changes, as the entry holds it and as the module offers it. The
    /// function is its C — the rest of it is the body's own; any other field
    /// is its JSON, a text field its text.
    static func conflictFields(_ conflicts: [LibraryWriteResult.Conflict], offered: [LibraryProposal],
                               writer: AnalysisWriter) async throws -> [String: [[String: String]]] {
        let index = try await writer.readLibraryIndex()
        let wanted = Set(conflicts.map(\.id))
        var found: [String: [[String: String]]] = [:]
        for proposal in offered {
            let candidates = [index.bodies[proposal.body.key], proposal.variantOf,
                              proposal.body.isShort ? proposal.basedOn : nil].compactMap { $0 }
            guard let id = candidates.first(where: wanted.contains), found[id] == nil,
                  let held = index.entries[id] else { continue }
            let heldObject = try await writer.readObject(held.entry)
            func fields(_ data: Data) -> [String: Any] {
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            }
            let (before, after) = (fields(heldObject), fields(proposal.entry))
            let changed = conflicts.first(where: { $0.id == id })?.changed
                ?? LibraryProposal.changedFields(from: heldObject, to: proposal.entry)
            found[id] = changed.map { field in
                ["field": field, "held": Self.fieldText(field, before[field]),
                 "offered": Self.fieldText(field, after[field])]
            }
        }
        return found
    }

    private static func fieldText(_ field: String, _ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if field == "function", let c = (value as? [String: Any])?["c"] as? String { return c }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func plain<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: try encoder.encode(value))
    }
}

extension GhidraHost {
    /// The functions the registry gave back stop being library functions: the
    /// answer of `/v1/library/release`.
    func releaseGivenBack(_ module: SHA256Digest, plan: LibraryPlan, index: LibraryIndex) async throws -> Any {
        var items: [[String: Any]] = []
        for step in plan.released {
            guard let out = index.takenOut?[step.id] else { continue }
            items.append(["address": step.address, "id": out.id, "version": step.version,
                          "entry": try JSONSerialization.jsonObject(with: try await writer.readObject(out.entry))])
        }
        let body = try JSONSerialization.data(withJSONObject: ["items": items])
        return (try JSONSerialization.jsonObject(
            with: try await write(module, "/v1/library/release", body: body, byHost: true)) as? [String: Any])?["items"] ?? []
    }
}
