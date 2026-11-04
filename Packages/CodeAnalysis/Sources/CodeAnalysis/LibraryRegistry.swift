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
    /// The digest of what this body's data references point at, as its module
    /// reported it. Nil for a body with none, and until its module publishes
    /// under an exporter that reports it.
    public var referenceBytes: String?

    public init(body: LibraryBody, module: SHA256Digest, codes: [String]? = nil, referenceBytes: String? = nil) {
        self.body = body
        self.module = module
        self.codes = codes
        self.referenceBytes = referenceBytes
    }

    private enum CodingKeys: String, CodingKey {
        case body, module, codes
        case referenceBytes = "reference_bytes"
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
    /// Bodies given back to their modules, by key. Nil while there are none.
    public var takenOut: [String: LibraryTakenOut]?
    /// Where a body's constant is defined in its library's source, by key.
    public var sources: [String: LibraryCitation]?
    /// The citations later calls replaced or removed, by key. Nil while none.
    public var sourceChanges: [String: [LibraryCitationChange]]?
    public init() {}

    /// Whether a body's data references point at other bytes than the entry
    /// holds for it. Either side not knowing says nothing.
    public func bytesDiffer(id: String, body: String, referenceBytes: String?) -> Bool {
        guard let referenceBytes,
              let held = entries[id]?.variants.first(where: { $0.body.key == body })?.referenceBytes else { return false }
        return held != referenceBytes
    }

    private enum CodingKeys: String, CodingKey {
        case schema, entries, bodies, sources
        case takenOut = "taken_out"
        case sourceChanges = "source_changes"
    }

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
    /// The module this row's change was asked from, when `source` still names
    /// the review's author and so is not it. Nil from a build that predates it,
    /// and on a row whose `source` is the module that made the change.
    public var changedFrom: SHA256Digest? = nil

    private enum CodingKeys: String, CodingKey {
        case version, entry, source, reason
        case recordedAt = "recorded_at"
        case changedFrom = "changed_from"
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
    /// Why this publish changes an entry whose current version its review was
    /// made on, by entry id. That change takes no decision, but it needs a reason.
    public var entryReasons: [String: String] = [:]

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

    /// This decision, with the reasons for the entries the publish moves.
    public func with(entryReasons: [String: String]) -> LibraryTake {
        var copy = self
        copy.entryReasons = entryReasons
        return copy
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
    /// Why the function has its name, as the review wrote it.
    public var nameReason: String?
    /// The function carries the entry's mark and was not edited since.
    public var linked: Bool = false
    /// The digest of what the body's data references point at (`LibraryVariant`).
    public var referenceBytes: String?
    /// What the body refers to, by offset from its entry, and what it calls:
    /// what decides whether it depends on a module. Nil from an owner that
    /// does not say. Beside the review, not part of it.
    public var dataReferences: [String]?
    public var callees: [LibraryCallee]?

    public init(body: LibraryBody, name: String, kind: String, address: String, entry: Data,
                variantOf: String? = nil, codes: [String]? = nil, role: String? = nil,
                basedOn: String? = nil, base: Int? = nil, signatureReason: String? = nil, nameReason: String? = nil,
                linked: Bool = false, dataReferences: [String]? = nil, callees: [LibraryCallee]? = nil,
                referenceBytes: String? = nil) {
        self.linked = linked
        self.referenceBytes = referenceBytes
        self.dataReferences = dataReferences
        self.callees = callees
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
        self.nameReason = nameReason
        self.base = base
    }
}

/// What a write did, entry by entry.
public struct LibraryWriteResult: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: Int
        /// For a publish's update: the review's fields it changes, so an entry
        /// gaining its recorded function is told from one whose text moves.
        public var changed: [String]?
        /// The module whose publish or write made this change, and why it was
        /// made: what a reader of the answer checks. Nil on a row that changes
        /// nothing, and from a store that predates them.
        public var module: SHA256Digest?
        public var reason: String?
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
    /// Entries this publish would move with no reason given: a dry run names
    /// them, a publish is refused. Each row says the version it would become.
    /// Nil when there are none, and from a store that predates the rule.
    public var needsReason: [Change]?
    /// Bodies added to an entry as variants; nil from a store that has none.
    public var variants: [Change]?
    /// Functions refused because another entry holds the name: a different
    /// body is a different function, and the review gives it a narrower name.
    /// Nil from a store that has none.
    public var nameConflicts: [NameConflict]?
    /// Functions the registry did not take: they depend on a module, or were
    /// taken out. Nil from a store that has none.
    public var notLibrary: [NotLibrary]?
    /// What a change on the registry itself did; nil otherwise.
    public var takenOut: [Change]?
    public var cited: [String]?
    public var citations: [LibraryCitationResult]?

    public struct NotLibrary: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var body: String
        /// `data`: a data reference no citation covers. `callee`: a call to a
        /// function the registry does not hold. `taken_out`: taken out before.
        public var why: String
        public var reason: String?
        public var data: [String]?
        public var callees: [String]?

        public init(address: String, name: String, body: String, why: String, reason: String? = nil,
                    data: [String]? = nil, callees: [String]? = nil) {
            self.address = address
            self.name = name
            self.body = body
            self.why = why
            self.reason = reason
            self.data = data
            self.callees = callees
        }
    }

    public struct NameConflict: Codable, Equatable, Sendable {
        public var address: String
        public var name: String
        public var body: String
        public var heldBy: String
        public var heldVersion: Int

        public init(address: String, name: String, body: String, heldBy: String, heldVersion: Int) {
            self.address = address
            self.name = name
            self.body = body
            self.heldBy = heldBy
            self.heldVersion = heldVersion
        }

        private enum CodingKeys: String, CodingKey {
            case address, name, body
            case heldBy = "held_by"
            case heldVersion = "held_version"
        }
    }

    public init() {}

    /// What a publish that would move entries with no reason is refused with.
    public var reasonRefusal: String? {
        guard let rows = needsReason, !rows.isEmpty else { return nil }
        let named = rows.map { "\($0.id) (\($0.name), to version \($0.version))" }.joined(separator: ", ")
        return "this publish would change library entries with no reason given: \(named). Nothing was stored. "
            + "Publish again with `entry_reasons`, an object of entry id to why this module changes it."
    }

    /// A store that predates the rule leaves its rows without a module, and
    /// would take a change with no reason, whatever `entry_reasons` says.
    public var fromAStoreBeforeReasons: Bool {
        (added + updated + (variants ?? [])).contains { $0.module == nil }
    }

    /// What a publish is refused with before it is sent, nil when it goes.
    public var publishRefusal: String? {
        if fromAStoreBeforeReasons {
            return "the store predates the rule that a change to a library entry names its module and reason: "
                + "it would take this publish with no reason. Nothing was stored. Update the store's server first."
        }
        return reasonRefusal
    }

    private enum CodingKeys: String, CodingKey {
        case added, updated, unchanged, conflicts, variants
        case needsReason = "needs_reason"
        case cited, citations
        case nameConflicts = "name_conflicts"
        case notLibrary = "not_library"
        case takenOut = "taken_out"
    }
}

extension LibraryProposal {
    /// The top-level fields of a review that differ between two entry objects.
    public static func changedFields(from old: Data, to new: Data) -> [String] {
        func fields(_ data: Data) -> [String: NSObject] {
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: NSObject]) ?? [:]
        }
        let (before, after) = (fields(old), fields(new))
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }

    /// Whether all a review moved is the function's name or signature: all the
    /// function's own reasons speak for. The recorded function is not the review.
    static func movedOnlyNameOrSignature(from held: Data, to offered: Data) -> Bool {
        let notTheReview: Set<String> = ["body", "constants", "function"]
        let nameOrSignature: Set<String> = ["name", "signature", "return_type", "calling_convention", "params"]
        return Set(changedFields(from: held, to: offered)).subtracting(notTheReview).isSubset(of: nameOrSignature)
    }

    /// What the history says of a version this review changed: the function's
    /// own reason, and only one that changed against the function the entry
    /// held, the one for what changed first. An older reason here would read
    /// as the explanation of this change, which is worse than none. So are the
    /// words the server wrote. A held entry with no function gives nothing to
    /// compare with, and no reason comes of it.
    func reason(signatureChanged: Bool, held: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              let function = object["function"] as? [String: Any] else { return nil }
        func own(_ reason: String?, _ key: String) -> String? {
            guard let reason, reason != function[key] as? String,
                  !Self.generatedReasons.contains(where: reason.hasPrefix) else { return nil }
            return reason
        }
        let name = own(nameReason, "name_reason"), signature = own(signatureReason, "signature_reason")
        return signatureChanged ? signature ?? name : name ?? signature
    }

    private static let generatedReasons = ["library registry entry ", "no longer a library function: ", "named in its signature"]

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

    /// The held entry with its function's C as its own module prints it now,
    /// or nil when that is no mere printing. Only the module the C came from,
    /// at the same address, reprints it, so every address in it stays that
    /// module's; and the text must read the same but for a zero pointer's
    /// `NULL`, line breaks, and the warning of a convention nobody names. Any
    /// other difference is a review's, and goes as one. All else of the
    /// function stays the entry's, its reasons with it.
    static func reprinting(_ proposal: Data, in held: Data, heldSource: LibrarySource, source: LibrarySource) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: held)) as? [String: Any],
              var function = object["function"] as? [String: Any], let old = function["c"] as? String,
              let offered = ((try? JSONSerialization.jsonObject(with: proposal)) as? [String: Any])?["function"] as? [String: Any],
              let new = offered["c"] as? String, old != new else { return nil }
        let origin = function["source"] as? [String: Any]
        guard (origin?["module"] as? String ?? heldSource.module.hex) == source.module.hex,
              (origin?["address"] as? String ?? heldSource.address) == source.address,
              samePrinting(old, new) else { return nil }
        for key in ["c", "c_spans", "c_sites", "c_fields", "c_unreachable"] { function[key] = offered[key] }
        object["function"] = function
        return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// Whether two prints of one function differ only as `reprinting` allows.
    static func samePrinting(_ old: String, _ new: String) -> Bool {
        func read(_ text: String) -> String {
            text.replacingOccurrences(of: #"/\*\s*WARNING: Unknown calling convention.*?\*/"#, with: "",
                                      options: .regularExpression)
                .replacingOccurrences(of: #"\([^()]*\)0x0\b"#, with: "NULL", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        }
        return read(old) == read(new)
    }

    /// The held entry object with the proposal's function added, saying which
    /// module's reading it is; nothing else of the proposal comes with it.
    static func recording(_ proposal: Data, in held: Data, source: LibrarySource) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: held) as? [String: Any],
              let offered = try JSONSerialization.jsonObject(with: proposal) as? [String: Any],
              var function = offered["function"] as? [String: Any] else { return proposal }
        var origin: [String: Any] = ["module": source.module.hex, "address": source.address]
        origin["rev"] = source.rev
        function["source"] = origin
        object["function"] = function
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
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
        let entryReasons = take.entryReasons.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let id = entryReasons.first(where: { $0.value.isEmpty })?.key {
            throw CodeAnalysisError.analysisMismatch("the reason given for the library entry \(id) is empty")
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
            let named = take.ids.union(entryReasons.keys)
            if let unknown = named.subtracting(Self.offeredIds(proposals, index)).sorted().first {
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
            // What this publish moves to a next version of its review: only
            // these can be given a reason of their own.
            var moving: Set<String> = []
            var variantConflicts: Set<String> = []
            var variantOf: [String: LibraryProposal] = [:]
            var settled: [String: String] = [:]
            let now = Timestamps.now()
            let admitted = LibraryProposal.admitted(proposals, in: index)
            for (proposal, digest) in zip(proposals, stored).sorted(by: { $0.0.body < $1.0.body }) {
                let source = LibrarySource(module: module, address: proposal.address, rev: rev, by: by)
                // Only a new body is judged here: what the registry already
                // holds is put in order by a review, entry by entry.
                if index.entry(for: proposal.body) == nil, let refusal = proposal.refusal(in: index, admitted: admitted) {
                    result.notLibrary = (result.notLibrary ?? []) + [refusal]
                    continue
                }
                // A body applied as a variant joins its entry when the review
                // is the entry's and the body differs only in its constants:
                // one review, another body. Another shape is other code — a
                // function cut again since it took the entry — never a variant.
                if index.entry(for: proposal.body) == nil, let id = proposal.variantOf,
                   var held = index.entries[id] {
                    if proposal.body.shape == held.variants.first?.body.shape,
                       LibraryProposal.sameReview(try object(held.entry), proposal.entry) {
                        held.variants.append(LibraryVariant(body: proposal.body, module: module,
                                                            codes: proposal.codes,
                                                            referenceBytes: proposal.referenceBytes))
                        index.entries[id] = held
                        index.bodies[proposal.body.key] = id
                        let joined = "the body \(proposal.body.key) joins the entry as a variant"
                        result.variants = (result.variants ?? []) + [.init(
                            id: id, name: held.name, version: held.version, module: module, reason: joined)]
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        history.versions.append(LibraryVersion(version: held.version, entry: held.entry, source: source,
                                                               reason: joined, recordedAt: now))
                        histories[id] = history
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
                // A library function's name is one function's: another body
                // under it is another function, and needs a narrower name.
                func namedOtherwise(than own: String?) -> LibraryWriteResult.NameConflict? {
                    guard let (other, entry) = index.entries.first(where: { $0.key != own && $0.value.name == proposal.name })
                    else { return nil }
                    return .init(address: proposal.address, name: proposal.name, body: proposal.body.key,
                                 heldBy: other, heldVersion: entry.version)
                }
                guard let (id, found) = index.entry(for: proposal.body) else {
                    if let conflict = namedOtherwise(than: nil) {
                        result.nameConflicts = (result.nameConflicts ?? []) + [conflict]
                        continue
                    }
                    let id = proposal.body.key
                    index.entries[id] = LibraryIndexEntry(
                        version: 1, entry: digest, name: proposal.name, kind: proposal.kind, source: source,
                        variants: [LibraryVariant(body: proposal.body, module: module,
                                                  referenceBytes: proposal.referenceBytes)], role: proposal.role)
                    index.bodies[proposal.body.key] = id
                    histories[id] = LibraryHistory(id: id, versions: [
                        LibraryVersion(version: 1, entry: digest, source: source, reason: nil, recordedAt: now)
                    ])
                    result.added.append(.init(id: id, name: proposal.name, version: 1, module: module))
                    settled[id] = "this publish adds it as a new entry, version 1"
                    continue
                }
                // One key, other data: another function, which the entry does not
                // take and whose review says nothing of it.
                if index.bytesDiffer(id: id, body: proposal.body.key, referenceBytes: proposal.referenceBytes) {
                    result.notLibrary = (result.notLibrary ?? []) + [.init(
                        address: proposal.address, name: proposal.name, body: proposal.body.key, why: "reference_bytes",
                        reason: "its data references point at other bytes than the entry \(id) holds for this body")]
                    settled[id] = "this function's data references point at other bytes, so it is not this entry's"
                    continue
                }
                // The module the body came from says what its bytes are: an entry
                // from before this learns them, with no version moving.
                if let bytes = proposal.referenceBytes,
                   let position = found.variants.firstIndex(where: { $0.body.key == proposal.body.key }),
                   found.variants[position].referenceBytes == nil, found.variants[position].module == module {
                    index.entries[id]?.variants[position].referenceBytes = bytes
                    changedIndex = true
                }
                let held = index.entries[id] ?? found
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
                    // Its C printed anew by the module it came from is no change
                    // of the review: no version moves, and no copy is behind.
                    if let reprinted = LibraryProposal.reprinting(proposal.entry, in: heldObject,
                                                                  heldSource: held.source, source: source) {
                        var next = held
                        next.entry = dryRun ? SHA256Digest(data: reprinted) : try putObject(reprinted)
                        index.entries[id] = next
                        var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                        let printed = "the function's C printed again by its module"
                        history.versions.append(LibraryVersion(version: held.version, entry: next.entry, source: held.source,
                                                               reason: printed, recordedAt: now,
                                                               changedFrom: module))
                        histories[id] = history
                        result.updated.append(.init(id: id, name: held.name, version: held.version, changed: ["function"],
                                                    module: module, reason: printed))
                        settled[id] = "its review is the entry's own, at version \(held.version)"
                        continue
                    }
                    result.unchanged.append(.init(id: id, name: held.name, version: held.version))
                    settled[id] = "its review is the entry's own, at version \(held.version)"
                    continue
                }
                if proposal.name != held.name, let conflict = namedOtherwise(than: id) {
                    result.nameConflicts = (result.nameConflicts ?? []) + [conflict]
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
                    settled[id] = "this module's review was not made on its current version: "
                        + "that is a conflict, taken with `take_library_conflicts`"
                    continue
                }
                // Past here sameReview means only what the review lacked gets
                // recorded. Anything else moves the review, and says why.
                let recordsOnly = LibraryProposal.sameReview(heldObject, proposal.entry)
                func signature(_ entry: Data) -> String? {
                    ((try? JSONSerialization.jsonObject(with: entry)) as? [String: Any])?["signature"] as? String
                }
                let signatureChanged = signature(heldObject) != signature(proposal.entry)
                let own = current ? proposal.reason(signatureChanged: signatureChanged, held: heldObject) : nil
                let why: String?
                if recordsOnly {
                    settled[id] = "this publish only records what its review lacked, which asks no reason"
                    why = own ?? (lacksFunction ? "the function's C recorded" : "the body's constants recorded")
                } else {
                    moving.insert(id)
                    // A take speaks for a change on the current version only by
                    // naming the entry; the function's reason only for what it explains.
                    let decided = current ? reasons[id] : taken
                    let explained = LibraryProposal.movedOnlyNameOrSignature(from: heldObject, to: proposal.entry) ? own : nil
                    why = entryReasons[id] ?? decided ?? explained
                }
                guard recordsOnly || why != nil else {
                    result.needsReason = (result.needsReason ?? []) + [.init(
                        id: id, name: proposal.name, version: held.version + 1,
                        changed: LibraryProposal.changedFields(from: heldObject, to: proposal.entry), module: module)]
                    continue
                }
                var next = held
                // The function's C recorded in an entry is no change of its
                // review: no module's copy is behind for it, so none applies
                // the entry again and no module's revision moves.
                if !lacksFunction { next.version += 1 }
                // Recording what the review lacked does not make the module
                // that recorded it the review's author: `source` stays, and the
                // C says where it came from in its own `function.source`. Only
                // the function goes in: all else of the object stays the entry's.
                var recorded = digest
                var written = proposal.entry
                if lacksFunction {
                    written = try LibraryProposal.recording(proposal.entry, in: heldObject, source: source)
                    recorded = dryRun ? SHA256Digest(data: written) : try putObject(written)
                }
                next.entry = recorded
                next.name = proposal.name
                next.kind = proposal.kind
                next.role = proposal.role
                if !completes { next.source = source }
                index.entries[id] = next
                var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                let recordedWhy = lacksFunction
                    ? "the function's C recorded from \(source.module.hex) at \(source.address)" : why
                history.versions.append(LibraryVersion(version: next.version, entry: recorded,
                                                       source: completes ? held.source : source,
                                                       reason: recordedWhy, recordedAt: now,
                                                       changedFrom: completes ? module : nil))
                histories[id] = history
                result.updated.append(.init(id: id, name: proposal.name, version: next.version,
                                            changed: LibraryProposal.changedFields(from: heldObject, to: written),
                                            module: module, reason: recordedWhy))
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
            // A reason for an entry this publish does not move would read as
            // kept, and be nothing: said as a take of a settled entry is.
            if let id = Set(entryReasons.keys).subtracting(moving).sorted().first {
                var text = "the reason given for the entry \(id) has nothing to apply to"
                if let held = index.entries[id] { text += ": \(held.name) is at version \(held.version)" }
                text += ", and " + (settled[id] ?? "this publish does not change it")
                throw CodeAnalysisError.analysisMismatch(text)
            }
            if !dryRun, let refusal = result.reasonRefusal {
                throw CodeAnalysisError.analysisMismatch(refusal)
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

    /// Give an entry a narrower name, for a review that finds it holds one too
    /// wide. A name goes by what the functions mean, not by who came first: the
    /// entry that holds a name another function also has a claim to can give it
    /// up. The reason is the history's, and every module takes the new name at
    /// its next open. `dryRun` answers the same and writes nothing.
    @discardableResult
    public func renameLibraryEntry(id: String, name: String, reason: String, by: String?, changedFrom: SHA256Digest? = nil,
                                   dryRun: Bool = false) throws -> LibraryWriteResult.Change {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CodeAnalysisError.analysisMismatch("renaming a library entry needs a reason") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LibraryEntryReview.isPlaceholder(name) else {
            throw CodeAnalysisError.analysisMismatch("\(name) is not a name a review gives")
        }
        return try withLock {
            var index = try libraryIndex()
            guard var entry = index.entries[id] else {
                throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(id)")
            }
            guard entry.name != name else {
                throw CodeAnalysisError.analysisMismatch("the entry \(id) is already \(name)")
            }
            if let other = index.entries.first(where: { $0.key != id && $0.value.name == name }) {
                throw CodeAnalysisError.analysisMismatch(
                    "the entry \(other.key) holds the name \(name): rename that one first, if the review finds it should")
            }
            guard var review = try JSONSerialization.jsonObject(with: try object(entry.entry)) as? [String: Any] else {
                throw CodeAnalysisError.analysisMismatch("the entry \(id)'s review is not an object")
            }
            let old = entry.name
            Self.rename(&review, from: old, to: name)
            let data = try JSONSerialization.data(withJSONObject: review, options: [.sortedKeys, .withoutEscapingSlashes])
            var history = try libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
            entry.version += 1
            entry.entry = SHA256Digest(data: data)
            entry.name = name
            history.versions.append(LibraryVersion(version: entry.version, entry: entry.entry, source: entry.source,
                                                   reason: "\(why) (was \(old))", recordedAt: Timestamps.now(),
                                                   changedFrom: changedFrom))
            let change = LibraryWriteResult.Change(id: id, name: name, version: entry.version)
            if dryRun { return change }
            _ = try putObject(data)
            index.entries[id] = entry
            try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return change
        }
    }

    /// A review object under another name: its name, and the name in its signatures.
    static func rename(_ review: inout [String: Any], from old: String, to name: String) {
        func renamed(_ signature: String) -> String {
            signature.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: old))\\b",
                                           with: name, options: .regularExpression)
        }
        review["name"] = name
        if let signature = review["signature"] as? String { review["signature"] = renamed(signature) }
        if var function = review["function"] as? [String: Any] {
            function["name"] = name
            if let signature = function["signature"] as? String { function["signature"] = renamed(signature) }
            renameInC(&function, from: old, to: name)
            review["function"] = function
        }
    }

    /// The stored C under the new name: the tokens that print the old one as a
    /// function, and every place written after them moved by as much. A comment
    /// that mentions the name is the review's text and stays.
    private static func renameInC(_ function: inout [String: Any], from old: String, to name: String) {
        guard let c = function["c"] as? String, let spans = function["c_spans"] as? [[Any]] else { return }
        var units = Array(c.utf16)
        let oldUnits = Array(old.utf16), newUnits = Array(name.utf16)
        let delta = newUnits.count - oldUnits.count
        // Old position → how far the text at or after it has moved.
        var moves: [(at: Int, by: Int)] = []
        let order = spans.indices.sorted { (spans[$0].first as? Int ?? 0) < (spans[$1].first as? Int ?? 0) }
        for index in order.reversed() {
            let span = spans[index]
            guard span.count >= 3, let start = span[0] as? Int, let length = span[1] as? Int, span[2] as? String == "function",
                  length == oldUnits.count, start + length <= units.count,
                  Array(units[start..<(start + length)]) == oldUnits else { continue }
            units.replaceSubrange(start..<(start + length), with: newUnits)
            moves.append((at: start + length, by: delta))
        }
        guard !moves.isEmpty else { return }
        func moved(_ position: Int) -> Int {
            position + moves.reduce(0) { $0 + ($1.at <= position ? $1.by : 0) }
        }
        func place(_ row: [Any]) -> [Any] {
            guard row.count >= 2, let start = row[0] as? Int, let length = row[1] as? Int else { return row }
            var row = row
            row[0] = moved(start)
            row[1] = moved(start + length) - moved(start)
            return row
        }
        function["c"] = String(decoding: units, as: UTF16.self)
        function["c_spans"] = spans.map(place)
        for key in ["c_sites", "c_fields", "c_unreachable"] {
            if let rows = function[key] as? [[Any]] { function[key] = rows.map(place) }
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
        // A body taken out keeps its text: its modules take it at their next open.
        objects.formUnion((index.takenOut ?? [:]).values.map(\.entry))
        for id in Set(index.entries.keys).union((index.takenOut ?? [:]).values.map(\.id)) {
            if let history = try? libraryHistory(id: id) {
                objects.formUnion(history.versions.map(\.entry))
            }
        }
        return objects
    }
}
