import Foundation

// The shared registry of library functions (`Design/LIBRARY_REGISTRY_PLAN.md`):
// a library function's review kept once, keyed by its body, for every module
// whose function has the same body. The store holds it under `library/`; the
// entries themselves are objects, as review documents are.

/// A function's body as Ghidra's Function ID hashes it: the code units, the
/// full hash (operands that are addresses masked) and the specific hash
/// (constants kept). Two bodies with the same key are the same code.
public struct LibraryBody: Codable, Hashable, Comparable, Sendable {
    public var size: Int
    public var full: String
    public var specific: String

    public init(size: Int, full: String, specific: String) {
        self.size = size
        self.full = full.lowercased()
        self.specific = specific.lowercased()
    }

    /// `<size>-<full>-<specific>`, the index's key for this body.
    public var key: String { "\(String(size, radix: 16))-\(full)-\(specific)" }

    /// `<size>-<full>`: what bodies that differ only in constants share.
    public var shape: String { "\(String(size, radix: 16))-\(full)" }

    /// A body as the owner reports it: 64-bit hashes in hex, a size above 0.
    public var isValid: Bool {
        size > 0 && Self.isHash(full) && Self.isHash(specific)
    }

    static func isHash(_ text: String) -> Bool {
        text.count == 16 && text.allSatisfy { $0.isHexDigit }
    }

    public static func < (left: Self, right: Self) -> Bool { left.key < right.key }
}

/// Who published a version of an entry: the module, the function's address
/// in it, the revision of the module's reading, and who published it. A
/// record of the history, not an owner — every module whose function has the
/// body holds the entry alike.
public struct LibrarySource: Codable, Equatable, Sendable {
    public var module: SHA256Digest
    public var address: String
    public var rev: Int?
    public var by: String?

    public init(module: SHA256Digest, address: String, rev: Int?, by: String?) {
        self.module = module
        self.address = address
        self.rev = rev
        self.by = by
    }
}

/// One body an entry covers. An entry starts with one; bodies that differ
/// from it only in assert codes are added as variants, each with the codes
/// it carries.
public struct LibraryVariant: Codable, Equatable, Sendable {
    public var body: LibraryBody
    public var module: SHA256Digest
    /// The assert codes this body holds where the entry's first body holds
    /// others; nil for the first body.
    public var codes: [String]?

    public init(body: LibraryBody, module: SHA256Digest, codes: [String]? = nil) {
        self.body = body
        self.module = module
        self.codes = codes
    }
}

/// An entry as the index lists it: its current version and the object that
/// holds it, the name and kind a reader looks for, and its bodies.
public struct LibraryIndexEntry: Codable, Equatable, Sendable {
    public var version: Int
    public var entry: SHA256Digest
    public var name: String
    public var kind: String
    public var source: LibrarySource
    public var variants: [LibraryVariant]
    /// `assert` for an assert routine: the codes it is called with make
    /// variants of its callers' entries. Nil for any other function.
    public var role: String?

    public init(version: Int, entry: SHA256Digest, name: String, kind: String, source: LibrarySource,
                variants: [LibraryVariant], role: String? = nil) {
        self.version = version
        self.entry = entry
        self.name = name
        self.kind = kind
        self.source = source
        self.variants = variants
        self.role = role
    }
}

/// `library/index.json`: every entry by its id, and every body of every entry
/// by its key, so an exact match is one lookup.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public var schema = 1
    public var entries: [String: LibraryIndexEntry] = [:]
    public var bodies: [String: String] = [:]

    public init() {}

    /// The entry a body belongs to.
    public func entry(for body: LibraryBody) -> (id: String, entry: LibraryIndexEntry)? {
        guard let id = bodies[body.key], let entry = entries[id] else { return nil }
        return (id, entry)
    }
}

/// One version of an entry as its history keeps it.
public struct LibraryVersion: Codable, Equatable, Sendable {
    public var version: Int
    public var entry: SHA256Digest
    public var source: LibrarySource
    /// Why this version differs: what an agent said on taking a review the
    /// entry's current version was not the base of, or the function's reason for
    /// a signature that changed. Nil for the first version and for a change
    /// nobody gave a reason for.
    public var reason: String?
    public var recordedAt: String

    private enum CodingKeys: String, CodingKey {
        case version, entry, source, reason
        case recordedAt = "recorded_at"
    }
}

/// `library/history/<id>.json`: every version of one entry, oldest first.
public struct LibraryHistory: Codable, Equatable, Sendable {
    public var id: String
    public var versions: [LibraryVersion]
}

/// Which conflicts a publish takes — none, every one, or those it names, each
/// with the reason the history keeps. A review made on the entry's current
/// version needs no decision; this decides the others.
public struct LibraryTake: Equatable, Sendable {
    /// Take every conflicting entry, with one reason.
    public var all: Bool
    /// The entries to take by id, each with a reason of its own.
    public var reasons: [String: String]
    /// The reason a take of every conflict keeps.
    public var reason: String?

    public static let none = LibraryTake()

    public static func all(_ reason: String) -> LibraryTake {
        LibraryTake(all: true, reason: reason, reasons: [:])
    }

    /// Take the entries named, in the order of their reasons — each needs one.
    public static func these(_ reasons: [String: String]) -> LibraryTake {
        LibraryTake(all: false, reason: nil, reasons: reasons)
    }

    private init(all: Bool = false, reason: String? = nil, reasons: [String: String] = [:]) {
        self.all = all
        self.reason = reason
        self.reasons = reasons
    }

    /// The ids this decision names.
    public var ids: Set<String> { Set(reasons.keys) }

    public var isEmpty: Bool { !all && reasons.isEmpty }

    /// The reason for an entry this decision takes, nil when it does not take it.
    public func reason(for id: String) -> String? {
        all ? reason : reasons[id]
    }
}

/// What a publish offers the registry: one tagged function reviewed to the
/// bar, its body, and its review as the canonical JSON object the entry is.
public struct LibraryProposal: Codable, Equatable, Sendable {
    public var body: LibraryBody
    public var name: String
    public var kind: String
    public var address: String
    /// The entry object's bytes: sorted keys, nothing of the module in it.
    public var entry: Data
    /// The entry this body was applied from as a variant, and the assert
    /// codes that made it one.
    public var variantOf: String?
    public var codes: [String]?
    /// `assert` for an assert routine.
    public var role: String?
    /// The entry and version the function was applied from or marked with
    /// at its last publish (its `ByteRipper.libraryEntry` mark): a change
    /// made on the entry's current version is its next version, from any
    /// module.
    public var basedOn: String?
    public var base: Int?
    /// The function's reason for its signature: not the review's text, so not
    /// in `entry`. The history keeps it for a version that changes the signature.
    public var signatureReason: String?
    /// The function carries the entry's mark and was not edited since.
    public var linked: Bool = false

    public init(body: LibraryBody, name: String, kind: String, address: String, entry: Data,
                variantOf: String? = nil, codes: [String]? = nil, role: String? = nil,
                basedOn: String? = nil, base: Int? = nil, signatureReason: String? = nil,
                linked: Bool = false) {
        self.linked = linked
        self.body = body
        self.name = name
        self.kind = kind
        self.address = address
        self.entry = entry
        self.variantOf = variantOf
        self.codes = codes
        self.role = role
        self.basedOn = basedOn
        self.signatureReason = signatureReason
        self.base = base
    }
}

/// What a write did, entry by entry.
public struct LibraryWriteResult: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: Int
    }

    /// The entry for this body holds another review, and this module's was
    /// not made on its current version.
    public struct Conflict: Codable, Equatable, Sendable {
        public var id: String
        /// The name the entry holds and the name this module proposes.
        public var name: String
        public var proposedName: String
        /// Who published the entry's current version.
        public var heldBy: LibrarySource
        public var version: Int
        /// The version this module's review was made on; nil when the
        /// function never carried the entry.
        public var base: Int?

        private enum CodingKeys: String, CodingKey {
            case id, name, version, base
            case proposedName = "proposed_name"
            case heldBy = "held_by"
        }
    }

    public var added: [Change] = []
    public var updated: [Change] = []
    public var unchanged: [Change] = []
    public var conflicts: [Conflict] = []
    /// Bodies added to an entry as variants; nil from a store that has none.
    public var variants: [Change]?

    public init() {}
}

extension LibraryProposal {
    /// Whether two entry objects are the same review: equal but for the body
    /// they were read from, its constants, and the function as that module
    /// published it — what the variants of one entry share, and what another
    /// module's addresses and callee names would otherwise make a new version.
    public static func sameReview(_ left: Data, _ right: Data) -> Bool {
        func review(_ data: Data) -> NSDictionary? {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            object["body"] = nil
            object["constants"] = nil
            object["function"] = nil
            return object as NSDictionary
        }
        guard let left = review(left), let right = review(right) else { return false }
        return left.isEqual(right)
    }

    /// Whether the entry object holds the function a reader is shown.
    static func hasFunction(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["function"] != nil
    }

    /// Whether the entry object records the body's constants.
    static func hasConstants(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["constants"] != nil
    }
}

extension ContentStore {
    public var libraryURL: URL { root.appendingPathComponent("library", isDirectory: true) }
    var libraryIndexURL: URL { libraryURL.appendingPathComponent("index.json", isDirectory: false) }

    func libraryHistoryURL(_ id: String) -> URL {
        libraryURL.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// The registry's index; empty while nothing was ever offered.
    public func libraryIndex() throws -> LibraryIndex {
        guard FileManager.default.fileExists(atPath: libraryIndexURL.path) else { return LibraryIndex() }
        do {
            return try decoder.decode(LibraryIndex.self, from: Data(contentsOf: libraryIndexURL))
        } catch {
            throw CodeAnalysisError.io("\(libraryIndexURL.path): \(error)")
        }
    }

    /// One entry's history, nil for an id the registry does not hold.
    public func libraryHistory(id: String) throws -> LibraryHistory? {
        guard SafeName.isSafe(id) else { throw CodeAnalysisError.invalidName(id) }
        let url = libraryHistoryURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(LibraryHistory.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// Offer a published module's library functions to the registry.
    ///
    /// A body the registry does not hold is a new entry, its id the body's
    /// key. A body it holds: the same review is no change; another review made
    /// on the entry's current version — the function carried it — is the
    /// next version, whichever module publishes it; any other review is a
    /// conflict, and the entry stays — unless `take` names it, when it becomes
    /// the next version with the reason `take` carries, which the history
    /// keeps and which every entry taken requires. No module holds an entry
    /// more than another.
    /// `dryRun` answers what the offer would do — the same result, the same
    /// refusals — and writes nothing: not the objects, not the index, not a
    /// history. A publish's preview is read with it.
    @discardableResult
    public func putLibraryEntries(module: SHA256Digest, rev: Int?, by: String?,
                                  proposals: [LibraryProposal], take: LibraryTake = .none,
                                  dryRun: Bool = false) throws -> LibraryWriteResult {
        let allReason = take.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if take.all, allReason?.isEmpty ?? true {
            throw CodeAnalysisError.analysisMismatch("taking a library conflict needs a reason")
        }
        let reasons = take.reasons.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (id, reason) in reasons where reason.isEmpty {
            throw CodeAnalysisError.analysisMismatch("taking the library entry \(id) needs a reason")
        }
        for proposal in proposals {
            guard proposal.body.isValid else {
                throw CodeAnalysisError.analysisMismatch("\(proposal.name): \(proposal.body.key) is not a body key")
            }
            guard LibraryKind(rawValue: proposal.kind) != nil else {
                throw CodeAnalysisError.analysisMismatch("\(proposal.name): \(proposal.kind) is not a library kind")
            }
        }
        // The objects first, as a publish stores its document before the
        // revision that names it — a preview names them without storing them.
        let stored = dryRun
            ? proposals.map { SHA256Digest(data: $0.entry) }
            : try proposals.map { try putObject($0.entry) }
        return try withLock {
            var index = try libraryIndex()
            // A decision that names an entry this publish does not offer is a
            // typo, not a take: refused before anything is written.
            if let unknown = take.ids.subtracting(Self.offeredIds(proposals, index)).sorted().first {
                throw CodeAnalysisError.analysisMismatch(
                    "no proposal in this publish carries the library entry \(unknown)")
            }
            var result = LibraryWriteResult()
            var histories: [String: LibraryHistory] = [:]
            var changedIndex = false
            // What the decision named actually came up a conflict: an entry
            // already settled is not taken silently, and a variant's conflict
            // cannot be the entry's next version.
            var conflicting: Set<String> = []
            var variantConflicts: Set<String> = []
            var variantOf: [String: LibraryProposal] = [:]
            var settled: [String: String] = [:]
            let now = Timestamps.now()
            for (proposal, digest) in zip(proposals, stored).sorted(by: { $0.0.body < $1.0.body }) {
                let source = LibrarySource(module: module, address: proposal.address, rev: rev, by: by)
                // A body applied as a variant joins its entry when the review
                // is the entry's and the body differs only in its constants:
                // one review, another body. Another shape is other code — a
                // function cut again since it took the entry — never a variant.
                if index.entry(for: proposal.body) == nil, let id = proposal.variantOf,
                   var held = index.entries[id] {
                    if proposal.body.shape == held.variants.first?.body.shape,
                       LibraryProposal.sameReview(try object(held.entry), proposal.entry) {
                        held.variants.append(LibraryVariant(body: proposal.body, module: module,
                                                            codes: proposal.codes))
                        index.entries[id] = held
                        index.bodies[proposal.body.key] = id
                        result.variants = (result.variants ?? []) + [.init(id: id, name: held.name,
                                                                          version: held.version)]
                        settled[id] = "this publish joins it as a variant of version \(held.version)"
                        changedIndex = true
                    } else {
                        conflicting.insert(id)
                        variantConflicts.insert(id)
                        variantOf[id] = proposal
                        result.conflicts.append(.init(id: id, name: held.name, proposedName: proposal.name,
                                                      heldBy: held.source, version: held.version,
                                                      base: proposal.basedOn == id ? proposal.base : nil))
                    }
                    continue
                }
                guard let (id, held) = index.entry(for: proposal.body) else {
                    let id = proposal.body.key
                    index.entries[id] = LibraryIndexEntry(
                        version: 1, entry: digest, name: proposal.name, kind: proposal.kind, source: source,
                        variants: [LibraryVariant(body: proposal.body, module: module)], role: proposal.role)
                    index.bodies[proposal.body.key] = id
                    histories[id] = LibraryHistory(id: id, versions: [
                        LibraryVersion(version: 1, entry: digest, source: source, reason: nil, recordedAt: now)
                    ])
                    result.added.append(.init(id: id, name: proposal.name, version: 1))
                    settled[id] = "this publish adds it as a new entry, version 1"
                    continue
                }
                if held.entry == digest {
                    result.unchanged.append(.init(id: id, name: held.name, version: held.version))
                    settled[id] = "its review is the entry's own, at version \(held.version)"
                    continue
                }
                // The same review from another body of the entry — a variant
                // — is no change; so is it from the entry's own body, unless
                // it records the constants the held object lacks.
                let heldObject = try object(held.entry)
                // Only the same review completes an entry with its function: a
                // review that differs is a change, and stays a conflict.
                let lacksFunction = !LibraryProposal.hasFunction(heldObject) && LibraryProposal.hasFunction(proposal.entry)
                    && LibraryProposal.sameReview(heldObject, proposal.entry)
                let completes = lacksFunction || (!LibraryProposal.hasConstants(heldObject)
                    && LibraryProposal.hasConstants(proposal.entry) && proposal.body == held.variants.first?.body)
                if LibraryProposal.sameReview(heldObject, proposal.entry), !completes {
                    result.unchanged.append(.init(id: id, name: held.name, version: held.version))
                    settled[id] = "its review is the entry's own, at version \(held.version)"
                    continue
                }
                let base = proposal.basedOn == id ? proposal.base : nil
                let current = base == held.version
                // A review that differs reaches here: it is the entry's next
                // version, or a conflict the decision takes — or leaves.
                conflicting.insert(id)
                let taken = take.all ? allReason : reasons[id]
                guard current || completes || taken != nil else {
                    result.conflicts.append(.init(id: id, name: held.name, proposedName: proposal.name,
                                                  heldBy: held.source, version: held.version, base: base))
                    continue
                }
                var next = held
                next.version += 1
                next.entry = digest
                next.name = proposal.name
                next.kind = proposal.kind
                next.role = proposal.role
                next.source = source
                index.entries[id] = next
                var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                func signature(_ entry: Data) -> String? {
                    ((try? JSONSerialization.jsonObject(with: entry)) as? [String: Any])?["signature"] as? String
                }
                let signatureChanged = signature(heldObject) != signature(proposal.entry)
                let why = current ? (signatureChanged ? proposal.signatureReason : nil)
                    : completes ? (lacksFunction ? "the function's C recorded" : "the body's constants recorded") : taken
                history.versions.append(LibraryVersion(version: next.version, entry: digest, source: source,
                                                       reason: why, recordedAt: now))
                histories[id] = history
                result.updated.append(.init(id: id, name: proposal.name, version: next.version))
            }
            // A decision that names an entry already settled — the same review,
            // the current version — would read as taken and be nothing: say so,
            // as the unknown id above is said, rather than pass in silence.
            if let id = take.ids.subtracting(conflicting).sorted().first {
                var text = "the entry \(id) is not in conflict in this publish"
                if let held = index.entries[id] {
                    text += ": \(held.name) is at version \(held.version), and "
                } else {
                    text += ": "
                }
                text += settled[id] ?? "this publish does not take it"
                throw CodeAnalysisError.analysisMismatch(text)
            }
            if let id = take.ids.intersection(variantConflicts).sorted().first {
                let proposal = variantOf[id]
                let function = proposal.map { "\($0.name) at \($0.address)" } ?? "this module's function"
                throw CodeAnalysisError.analysisMismatch(
                    "the entry \(id) is the entry of another body, and \(function) is not a variant of it: "
                        + "a variant's review cannot become the entry's — adopt the entry with replace, "
                        + "or review the function on its own")
            }
            guard !dryRun, !histories.isEmpty || changedIndex else { return result }
            for (id, history) in histories.sorted(by: { $0.key < $1.key }) {
                try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            }
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return result
        }
    }

    /// Make one of an entry's bodies its only one, for an entry that took a
    /// body it should not have: the entry's id becomes that body's key, the
    /// review records the body, every other body leaves the index, and the
    /// history moves to the new id with a version saying why. Nothing else of
    /// the review changes. `dryRun` answers the same and writes nothing.
    @discardableResult
    public func rebodyLibraryEntry(id: String, bodyKey: String, reason: String,
                                   dryRun: Bool = false) throws -> LibraryWriteResult.Change {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CodeAnalysisError.analysisMismatch("changing an entry's body needs a reason") }
        return try withLock {
            var index = try libraryIndex()
            guard var entry = index.entries[id] else {
                throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(id)")
            }
            guard let kept = entry.variants.first(where: { $0.body.key == bodyKey }) else {
                throw CodeAnalysisError.analysisMismatch("the entry \(id) has no body \(bodyKey)")
            }
            guard bodyKey != id || entry.variants.count > 1 else {
                throw CodeAnalysisError.analysisMismatch("\(bodyKey) is already the entry's only body")
            }
            if bodyKey != id, index.entries[bodyKey] != nil {
                throw CodeAnalysisError.analysisMismatch("the registry already holds an entry \(bodyKey)")
            }
            guard var review = try JSONSerialization.jsonObject(with: try object(entry.entry)) as? [String: Any] else {
                throw CodeAnalysisError.analysisMismatch("the entry \(id)'s review is not an object")
            }
            review["body"] = ["size": kept.body.size, "full": kept.body.full, "specific": kept.body.specific]
            review["constants"] = nil
            let data = try JSONSerialization.data(withJSONObject: review, options: [.sortedKeys, .withoutEscapingSlashes])
            var history = try libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
            entry.version += 1
            entry.entry = SHA256Digest(data: data)
            entry.variants = [LibraryVariant(body: kept.body, module: kept.module)]
            history.id = bodyKey
            history.versions.append(LibraryVersion(version: entry.version, entry: entry.entry, source: entry.source,
                                                   reason: why, recordedAt: Timestamps.now()))
            let change = LibraryWriteResult.Change(id: bodyKey, name: entry.name, version: entry.version)
            if dryRun { return change }
            _ = try putObject(data)
            index.entries[id] = nil
            index.entries[bodyKey] = entry
            index.bodies = index.bodies.filter { $0.value != id }
            index.bodies[bodyKey] = bodyKey
            // The new history first: a stop between the writes leaves a copy, never a loss.
            try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(bodyKey))
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            if bodyKey != id { try FileManager.default.removeItem(at: libraryHistoryURL(id)) }
            return change
        }
    }

    /// One function, one description: the entries of one library function,
    /// each from a body of its own, become one entry that covers all their
    /// bodies and holds `entry`, the text the review made of them. The kept
    /// id's next version says why. The entries merged in leave the index; their
    /// histories stay on disk, and their objects with them, so nothing a review
    /// wrote is lost. `dryRun` answers the same and writes nothing.
    @discardableResult
    public func mergeLibraryEntries(into id: String, from others: [String], entry data: Data,
                                    module: SHA256Digest, address: String, rev: Int?, by: String?,
                                    reason: String, dryRun: Bool = false) throws -> LibraryWriteResult.Change {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CodeAnalysisError.analysisMismatch("merging library entries needs a reason") }
        guard !others.isEmpty, !others.contains(id) else {
            throw CodeAnalysisError.analysisMismatch("name the entries to merge into \(id), other than itself")
        }
        guard let review = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = review["name"] as? String, LibraryProposal.hasFunction(data) else {
            throw CodeAnalysisError.analysisMismatch("the merged entry needs a name and the function as it reads")
        }
        return try withLock {
            var index = try libraryIndex()
            guard var held = index.entries[id] else {
                throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(id)")
            }
            var history = try libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
            for other in others {
                guard let merged = index.entries[other] else {
                    throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(other)")
                }
                held.variants += merged.variants
            }
            let source = LibrarySource(module: module, address: address, rev: rev, by: by)
            held.version += 1
            held.entry = SHA256Digest(data: data)
            held.name = name
            held.source = source
            history.versions.append(LibraryVersion(
                version: held.version, entry: held.entry, source: source,
                reason: "\(why) (merged \(others.joined(separator: ", ")))", recordedAt: Timestamps.now()))
            let change = LibraryWriteResult.Change(id: id, name: name, version: held.version)
            if dryRun { return change }
            _ = try putObject(data)
            for other in others {
                index.entries[other] = nil
                for (body, owner) in index.bodies where owner == other { index.bodies[body] = id }
            }
            index.entries[id] = held
            try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return change
        }
    }

    /// The entry ids a publish's proposals may conflict with: the entry their
    /// body belongs to, the id of a body the registry does not hold yet, and
    /// the entry a variant was applied from.
    private static func offeredIds(_ proposals: [LibraryProposal], _ index: LibraryIndex) -> Set<String> {
        var ids: Set<String> = []
        for proposal in proposals {
            ids.insert(proposal.body.key)
            if let held = index.bodies[proposal.body.key] { ids.insert(held) }
            if let variantOf = proposal.variantOf { ids.insert(variantOf) }
        }
        return ids
    }

    /// Make the registry's index what a served store holds: a mirror's copy.
    /// An unchanged index is not written again, as a manifest is not.
    public func mirrorLibrary(_ index: LibraryIndex) throws {
        try withLock {
            let data = try encoder.encode(index)
            if (try? Data(contentsOf: libraryIndexURL)) != data {
                try atomicWrite(data, to: libraryIndexURL)
            }
        }
    }

    /// Every object the registry names: each entry's current object and every
    /// version its history keeps.
    func libraryObjects() -> Set<SHA256Digest> {
        guard let index = try? libraryIndex() else { return [] }
        var objects = Set(index.entries.values.map(\.entry))
        // Every history on disk, an entry merged into another's among them.
        let histories = libraryURL.appendingPathComponent("history", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: histories, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(index.entries.keys).union(files.map { $0.deletingPathExtension().lastPathComponent })
        for id in ids {
            if let history = try? libraryHistory(id: id) {
                objects.formUnion(history.versions.map(\.entry))
            }
        }
        return objects
    }
}
