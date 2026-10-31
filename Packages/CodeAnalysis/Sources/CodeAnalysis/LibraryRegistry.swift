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

/// Where an entry's current version came from: the module, the function's
/// address in it, the revision of the module's reading that published it, and
/// who published it.
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
/// from it only in assert codes are added as variants (phase 2).
public struct LibraryVariant: Codable, Equatable, Sendable {
    public var body: LibraryBody
    public var module: SHA256Digest

    public init(body: LibraryBody, module: SHA256Digest) {
        self.body = body
        self.module = module
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
    /// Why an agent took another module's review over the one held; nil for
    /// the first version and for the holding module's own changes.
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

/// What a publish offers the registry: one tagged function reviewed to the
/// bar, its body, and its review as the canonical JSON object the entry is.
public struct LibraryProposal: Codable, Equatable, Sendable {
    public var body: LibraryBody
    public var name: String
    public var kind: String
    public var address: String
    /// The entry object's bytes: sorted keys, nothing of the module in it.
    public var entry: Data

    public init(body: LibraryBody, name: String, kind: String, address: String, entry: Data) {
        self.body = body
        self.name = name
        self.kind = kind
        self.address = address
        self.entry = entry
    }
}

/// What a write did, entry by entry.
public struct LibraryWriteResult: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: Int
    }

    /// Another module holds the entry for this body, with a different review.
    public struct Conflict: Codable, Equatable, Sendable {
        public var id: String
        /// The name the entry holds and the name this module proposes.
        public var name: String
        public var proposedName: String
        public var heldBy: LibrarySource
        public var version: Int

        private enum CodingKeys: String, CodingKey {
            case id, name, version
            case proposedName = "proposed_name"
            case heldBy = "held_by"
        }
    }

    public var added: [Change] = []
    public var updated: [Change] = []
    public var unchanged: [Change] = []
    public var conflicts: [Conflict] = []

    public init() {}
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
    /// key. A body it holds: the same review is no change; another review
    /// from the module that wrote the entry is the entry's next version; another
    /// review from a different module is a conflict, and the entry stays —
    /// unless `take` is set, when it becomes the next version, with `reason`,
    /// which the history keeps and which taking requires.
    @discardableResult
    public func putLibraryEntries(module: SHA256Digest, rev: Int?, by: String?,
                                  proposals: [LibraryProposal], take: Bool = false,
                                  reason: String? = nil) throws -> LibraryWriteResult {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if take, reason?.isEmpty ?? true {
            throw CodeAnalysisError.analysisMismatch("taking a library conflict needs a reason")
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
        // revision that names it.
        let stored = try proposals.map { try putObject($0.entry) }
        return try withLock {
            var index = try libraryIndex()
            var result = LibraryWriteResult()
            var histories: [String: LibraryHistory] = [:]
            let now = Timestamps.now()
            for (proposal, digest) in zip(proposals, stored).sorted(by: { $0.0.body < $1.0.body }) {
                let source = LibrarySource(module: module, address: proposal.address, rev: rev, by: by)
                guard let (id, held) = index.entry(for: proposal.body) else {
                    let id = proposal.body.key
                    index.entries[id] = LibraryIndexEntry(
                        version: 1, entry: digest, name: proposal.name, kind: proposal.kind, source: source,
                        variants: [LibraryVariant(body: proposal.body, module: module)])
                    index.bodies[proposal.body.key] = id
                    histories[id] = LibraryHistory(id: id, versions: [
                        LibraryVersion(version: 1, entry: digest, source: source, reason: nil, recordedAt: now)
                    ])
                    result.added.append(.init(id: id, name: proposal.name, version: 1))
                    continue
                }
                if held.entry == digest {
                    result.unchanged.append(.init(id: id, name: held.name, version: held.version))
                    continue
                }
                let own = held.source.module == module
                guard own || take else {
                    result.conflicts.append(.init(id: id, name: held.name, proposedName: proposal.name,
                                                  heldBy: held.source, version: held.version))
                    continue
                }
                var next = held
                next.version += 1
                next.entry = digest
                next.name = proposal.name
                next.kind = proposal.kind
                next.source = source
                index.entries[id] = next
                var history = try histories[id] ?? libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
                history.versions.append(LibraryVersion(version: next.version, entry: digest, source: source,
                                                       reason: own ? nil : reason, recordedAt: now))
                histories[id] = history
                result.updated.append(.init(id: id, name: proposal.name, version: next.version))
            }
            guard !histories.isEmpty else { return result }
            for (id, history) in histories.sorted(by: { $0.key < $1.key }) {
                try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            }
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return result
        }
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
        for id in index.entries.keys {
            if let history = try? libraryHistory(id: id) {
                objects.formUnion(history.versions.map(\.entry))
            }
        }
        return objects
    }
}
