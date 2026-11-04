import Foundation

// Putting the registry in order (`Design/LIBRARY_REGISTRY_PLAN.md`, "What a
// library function is"): the writes a review makes on the registry itself, not
// through a module's publish. A library function depends on no module: it
// refers to no data but a constant of its library's own source, and calls only
// other library functions. A body that does not qualify goes back to its
// modules, and is not offered again.

/// A body the registry gave back to its modules: what it was and why, so a
/// publish does not offer it again, a module takes its text at its next open,
/// and a wrong decision can be taken back.
public struct LibraryTakenOut: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var role: String?
    /// The entry's version that records the taking out, and its last review.
    public var version: Int
    public var entry: SHA256Digest
    public var variant: LibraryVariant
    public var source: LibrarySource
    public var reason: String
    public var by: String?
    public var at: String
}

/// Where a body's constant is defined in its library's own source, as an agent
/// who compared the bytes with the source cites it. The store cannot check
/// this: it only requires that somebody said so, and keeps who.
public struct LibraryCitation: Codable, Equatable, Sendable {
    public var file: String
    public var line: Int
    public var note: String?
    public var by: String?
    public var at: String
    /// The body's other citations: a body with two constants has two. Kept
    /// inside the first so that a build that knows one citation reads the index.
    public var also: [LibraryCitation]?

    /// This citation and the others it holds, each alone.
    public var all: [LibraryCitation] {
        var head = self
        head.also = nil
        return [head] + (also ?? []).flatMap(\.all)
    }

    /// One citation holding the rest; nil when there are none.
    static func holding(_ citations: [LibraryCitation]) -> LibraryCitation? {
        guard var head = citations.first else { return nil }
        head.also = citations.count > 1 ? Array(citations.dropFirst()) : nil
        return head
    }

    func sameLine(as other: LibraryCitation) -> Bool { file == other.file && line == other.line }
}

/// A citation a later call replaced or removed: what it said, and who changed
/// it. The index keeps these, since a citation is no version of an entry.
public struct LibraryCitationChange: Codable, Equatable, Sendable {
    public var action: String
    public var old: LibraryCitation
    public var by: String?
    public var at: String
}

/// What a citation call did to one body. `old` is what it replaced or removed.
public struct LibraryCitationResult: Codable, Equatable, Sendable {
    public var body: String
    public var action: String
    public var old: LibraryCitation?
}

/// What a body refers to outside itself, as the owner reads it from the
/// instructions; the registry decides on it, and it is not part of the review.
public struct LibraryCallee: Codable, Equatable, Sendable {
    public var name: String
    /// The callee's body key; nil for one Function ID cannot hash, or an external.
    public var body: String?

    public init(name: String, body: String?) {
        self.name = name
        self.body = body
    }
}

/// One write on the registry itself.
public struct LibraryChange: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case takeOut = "take_out"
        case restore
        case split
        case cite
        case readThrough = "read_through"
    }

    public var action: Action
    public var id: String?
    public var body: String?
    public var name: String?
    public var reason: String?
    public var file: String?
    public var line: Int?
    public var on: Bool?
    /// With `cite`: take this file and line away rather than add it.
    public var remove: Bool?

    public init(action: Action, id: String? = nil, body: String? = nil, name: String? = nil, reason: String? = nil,
                file: String? = nil, line: Int? = nil, on: Bool? = nil, remove: Bool? = nil) {
        self.action = action
        self.id = id
        self.body = body
        self.name = name
        self.reason = reason
        self.file = file
        self.line = line
        self.on = on
        self.remove = remove
    }
}

extension LibraryProposal {
    /// The new bodies of one publish that can enter together: each one's
    /// callees are held or are among them. So a function and its callee enter in
    /// one publish, and a pair that call each other enter as a pair: neither
    /// depends on anything but the other. A body with a refusal of its own, or a
    /// name another entry holds, does not enter, and neither does what calls it.
    static func admitted(_ proposals: [LibraryProposal], in index: LibraryIndex) -> Set<String> {
        var admitted = Set(proposals.filter { proposal in
            index.bodies[proposal.body.key] == nil
                && !index.entries.values.contains { $0.name == proposal.name }
                && proposal.refusal(in: index, admitted: Set(proposals.map(\.body.key))) == nil
        }.map(\.body.key))
        var changed = true
        while changed {
            changed = false
            for proposal in proposals where admitted.contains(proposal.body.key) {
                if proposal.refusal(in: index, admitted: admitted) != nil {
                    admitted.remove(proposal.body.key)
                    changed = true
                }
            }
        }
        return admitted
    }

    /// Why this body cannot be a library function, nil when it can. A proposal
    /// that does not say what it refers to is not judged on it. `admitted` are
    /// the bodies entering with it, which count as held.
    func refusal(in index: LibraryIndex, admitted: Set<String> = []) -> LibraryWriteResult.NotLibrary? {
        if let out = index.takenOut?[body.key] {
            return .init(address: address, name: name, body: body.key, why: "taken_out", reason: out.reason)
        }
        let foreign = (callees ?? []).filter { callee in
            guard let key = callee.body else { return true }
            return key != body.key && index.bodies[key] == nil && !admitted.contains(key)
        }
        if !foreign.isEmpty {
            return .init(address: address, name: name, body: body.key, why: "callee", callees: foreign.map(\.name))
        }
        if let data = dataReferences, !data.isEmpty, index.sources?[body.key] == nil {
            return .init(address: address, name: name, body: body.key, why: "data", data: data)
        }
        return nil
    }
}

extension ContentStore {
    /// Apply one change. `dryRun` answers the same and writes nothing.
    @discardableResult
    public func changeLibrary(_ change: LibraryChange, by: String?, changedFrom: SHA256Digest? = nil,
                              dryRun: Bool = false) throws -> LibraryWriteResult {
        switch change.action {
        case .takeOut: return try takeOutOfLibrary(change, by: by, changedFrom: changedFrom, dryRun: dryRun)
        case .restore: return try restoreToLibrary(change, by: by, changedFrom: changedFrom, dryRun: dryRun)
        case .split: return try splitLibraryEntry(change, by: by, changedFrom: changedFrom, dryRun: dryRun)
        case .cite: return try citeLibrarySource(change, by: by, dryRun: dryRun)
        case .readThrough:
            guard let on = change.on else {
                throw CodeAnalysisError.analysisMismatch("turning read-through on or off takes `on`")
            }
            return try withLock {
                var index = try libraryIndex()
                index.readThrough = on
                var result = LibraryWriteResult()
                result.readThrough = on
                if !dryRun { try atomicWrite(try encoder.encode(index), to: libraryIndexURL) }
                return result
            }
        }
    }

    private func required(_ reason: String?, _ what: String) throws -> String {
        let why = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !why.isEmpty else { throw CodeAnalysisError.analysisMismatch("\(what) needs a reason") }
        return why
    }

    /// The bodies named leave the registry; with none named, the whole entry
    /// does, and its name is free. The history stays under the entry's id.
    private func takeOutOfLibrary(_ change: LibraryChange, by: String?, changedFrom: SHA256Digest?, dryRun: Bool) throws -> LibraryWriteResult {
        let why = try required(change.reason, "taking a body out of the registry")
        guard let id = change.id else { throw CodeAnalysisError.analysisMismatch("name the entry by `id`") }
        return try withLock {
            var index = try libraryIndex()
            guard var entry = index.entries[id] else {
                throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(id)")
            }
            if let body = change.body, !entry.variants.contains(where: { $0.body.key == body }) {
                throw CodeAnalysisError.analysisMismatch("the entry \(id) has no body \(body)")
            }
            let leaving = entry.variants.filter { change.body == nil || $0.body.key == change.body }
            let now = Timestamps.now()
            entry.version += 1
            var history = try libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
            let what = change.body.map { "body \($0) taken out" } ?? "taken out"
            history.versions.append(LibraryVersion(version: entry.version, entry: entry.entry, source: entry.source,
                                                   reason: "\(what): \(why)", recordedAt: now, changedFrom: changedFrom))
            var out = index.takenOut ?? [:]
            for variant in leaving {
                let key = variant.body.key
                out[key] = LibraryTakenOut(id: id, name: entry.name, kind: entry.kind, role: entry.role,
                                           version: entry.version, entry: entry.entry, variant: variant,
                                           source: entry.source, reason: why, by: by, at: now)
                index.bodies[key] = nil
            }
            index.takenOut = out
            entry.variants.removeAll { variant in leaving.contains { $0.body == variant.body } }
            index.entries[id] = entry.variants.isEmpty ? nil : entry
            var result = LibraryWriteResult()
            result.takenOut = [.init(id: id, name: entry.name, version: entry.version)]
            if dryRun { return result }
            try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return result
        }
    }

    /// A body taken out by a wrong decision comes back to its entry.
    private func restoreToLibrary(_ change: LibraryChange, by: String?, changedFrom: SHA256Digest?, dryRun: Bool) throws -> LibraryWriteResult {
        let why = try required(change.reason, "restoring a body to the registry")
        guard let body = change.body else { throw CodeAnalysisError.analysisMismatch("name the `body` to restore") }
        return try withLock {
            var index = try libraryIndex()
            guard let out = index.takenOut?[body] else {
                throw CodeAnalysisError.analysisMismatch("the body \(body) was not taken out of the registry")
            }
            var entry: LibraryIndexEntry
            if var held = index.entries[out.id] {
                held.variants.append(out.variant)
                entry = held
            } else {
                if let other = index.entries.first(where: { $0.value.name == out.name }) {
                    throw CodeAnalysisError.analysisMismatch(
                        "the entry \(other.key) holds the name \(out.name) now: rename one of them first")
                }
                entry = LibraryIndexEntry(version: out.version, entry: out.entry, name: out.name, kind: out.kind,
                                          source: out.source, variants: [out.variant], role: out.role)
            }
            entry.version += 1
            index.entries[out.id] = entry
            index.bodies[body] = out.id
            index.takenOut?[body] = nil
            var history = try libraryHistory(id: out.id) ?? LibraryHistory(id: out.id, versions: [])
            history.versions.append(LibraryVersion(version: entry.version, entry: entry.entry, source: entry.source,
                                                   reason: "body \(body) restored: \(why)", recordedAt: Timestamps.now(), changedFrom: changedFrom))
            var result = LibraryWriteResult()
            result.updated = [.init(id: out.id, name: entry.name, version: entry.version)]
            if dryRun { return result }
            try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(out.id))
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return result
        }
    }

    /// A different body is a different function: one of an entry's bodies
    /// becomes an entry of its own, under the name its code earns, starting
    /// from the review they shared. The body the entry is keyed by stays: give
    /// it its narrower name with a rename, and split the others off.
    private func splitLibraryEntry(_ change: LibraryChange, by: String?, changedFrom: SHA256Digest?, dryRun: Bool) throws -> LibraryWriteResult {
        let why = try required(change.reason, "splitting a library entry")
        guard let id = change.id, let key = change.body, let wanted = change.name else {
            throw CodeAnalysisError.analysisMismatch("splitting takes `id`, `body` and `name`")
        }
        let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LibraryEntryReview.isPlaceholder(name) else {
            throw CodeAnalysisError.analysisMismatch("\(name) is not a name a review gives")
        }
        return try withLock {
            var index = try libraryIndex()
            guard var entry = index.entries[id] else {
                throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(id)")
            }
            guard let variant = entry.variants.first(where: { $0.body.key == key }) else {
                throw CodeAnalysisError.analysisMismatch("the entry \(id) has no body \(key)")
            }
            guard entry.variants.count > 1 else {
                throw CodeAnalysisError.analysisMismatch("\(key) is the entry's only body: rename the entry instead")
            }
            guard key != id, index.entries[key] == nil else {
                throw CodeAnalysisError.analysisMismatch(
                    "\(key) is the body the entry is keyed by: rename the entry, and split its other bodies off")
            }
            if let other = index.entries.first(where: { $0.value.name == name }) {
                throw CodeAnalysisError.analysisMismatch(
                    "the entry \(other.key) holds the name \(name): rename that one first, if the review finds it should")
            }
            guard var review = try JSONSerialization.jsonObject(with: try object(entry.entry)) as? [String: Any] else {
                throw CodeAnalysisError.analysisMismatch("the entry \(id)'s review is not an object")
            }
            Self.rename(&review, from: entry.name, to: name)
            review["body"] = ["size": variant.body.size, "full": variant.body.full, "specific": variant.body.specific]
            review["constants"] = nil
            let data = try JSONSerialization.data(withJSONObject: review, options: [.sortedKeys, .withoutEscapingSlashes])
            let now = Timestamps.now()
            let digest = SHA256Digest(data: data)
            let new = LibraryIndexEntry(version: 1, entry: digest, name: name, kind: entry.kind, source: entry.source,
                                        variants: [LibraryVariant(body: variant.body, module: variant.module)],
                                        role: entry.role)
            let newHistory = LibraryHistory(id: key, versions: [
                LibraryVersion(version: 1, entry: digest, source: entry.source,
                               reason: "split from \(id) (\(entry.name)): \(why)", recordedAt: now, changedFrom: changedFrom)
            ])
            entry.version += 1
            entry.variants.removeAll { $0.body.key == key }
            var history = try libraryHistory(id: id) ?? LibraryHistory(id: id, versions: [])
            history.versions.append(LibraryVersion(version: entry.version, entry: entry.entry, source: entry.source,
                                                   reason: "body \(key) split off as \(name): \(why)", recordedAt: now, changedFrom: changedFrom))
            var result = LibraryWriteResult()
            result.added = [.init(id: key, name: name, version: 1)]
            result.updated = [.init(id: id, name: entry.name, version: entry.version)]
            if dryRun { return result }
            _ = try putObject(data)
            index.entries[id] = entry
            index.entries[key] = new
            index.bodies[key] = key
            // The new history first: a stop between the writes leaves a history nothing names, never a loss.
            try atomicWrite(try encoder.encode(newHistory), to: libraryHistoryURL(key))
            try atomicWrite(try encoder.encode(history), to: libraryHistoryURL(id))
            try atomicWrite(try encoder.encode(index), to: libraryIndexURL)
            return result
        }
    }

    /// Where a body's constant is defined, for a body the registry holds or
    /// one about to be offered: it is what lets a body with a data reference in.
    private func citeLibrarySource(_ change: LibraryChange, by: String?, dryRun: Bool) throws -> LibraryWriteResult {
        let file = change.file?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !file.isEmpty, let line = change.line, line > 0 else {
            throw CodeAnalysisError.analysisMismatch("a citation takes the source `file` and its `line`")
        }
        return try withLock {
            var index = try libraryIndex()
            var keys: [String] = []
            if let id = change.id {
                guard let entry = index.entries[id] else {
                    throw CodeAnalysisError.analysisMismatch("the registry holds no entry \(id)")
                }
                keys = entry.variants.map(\.body.key)
            }
            if let body = change.body {
                guard body.split(separator: "-").count == 3 else {
                    throw CodeAnalysisError.analysisMismatch("\(body) is not a body key")
                }
                if change.id != nil, !keys.contains(body) {
                    throw CodeAnalysisError.analysisMismatch("the entry \(change.id ?? "") has no body \(body)")
                }
                keys = [body]
            }
            guard !keys.isEmpty else { throw CodeAnalysisError.analysisMismatch("name an `id` or a `body`") }
            var sources = index.sources ?? [:]
            var changes = index.sourceChanges ?? [:]
            var results: [LibraryCitationResult] = []
            let now = Timestamps.now()
            let cited = LibraryCitation(file: file, line: line, note: change.reason, by: by, at: now)
            for key in keys {
                var held = sources[key]?.all ?? []
                let at = held.firstIndex { $0.sameLine(as: cited) }
                if change.remove == true {
                    guard let at else {
                        throw CodeAnalysisError.analysisMismatch("\(key) has no citation of \(file):\(line)")
                    }
                    changes[key, default: []].append(.init(action: "removed", old: held[at], by: by, at: now))
                    results.append(.init(body: key, action: "removed", old: held[at]))
                    held.remove(at: at)
                } else if let at {
                    changes[key, default: []].append(.init(action: "replaced", old: held[at], by: by, at: now))
                    results.append(.init(body: key, action: "replaced", old: held[at]))
                    held[at] = cited
                } else {
                    results.append(.init(body: key, action: "added", old: nil))
                    held.append(cited)
                }
                sources[key] = LibraryCitation.holding(held)
            }
            index.sources = sources
            index.sourceChanges = changes.isEmpty ? nil : changes
            var result = LibraryWriteResult()
            result.cited = keys
            result.citations = results
            if !dryRun { try atomicWrite(try encoder.encode(index), to: libraryIndexURL) }
            return result
        }
    }
}
