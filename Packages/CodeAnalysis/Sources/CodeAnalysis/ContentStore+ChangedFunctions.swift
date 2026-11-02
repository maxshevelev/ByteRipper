import Foundation

extension ReviewRevision {
    /// The functions whose C this revision reads differently from the revision
    /// before it, in the sense of a non-empty diff: what a picker of revisions
    /// to compare with asks of a function, without reading any code.
    public var changedEntries: Set<CodeAddress>? {
        changedFunctions.map { Set($0.compactMap(CodeAddress.init(hex:))) }
    }
}

extension ContentStore {
    /// The functions `artifact` changes after `previous`, as entries; every
    /// function with C when there is no revision before it. Nil when either
    /// artifact cannot be read here.
    func changedFunctions(in artifact: SHA256Digest, after previous: SHA256Digest?) -> [String]? {
        guard let new = functionCode(of: artifact) else { return nil }
        guard let previous else {
            return new.filter { !$0.value.isEmpty }.keys.map(\.description).sorted()
        }
        guard let old = functionCode(of: previous) else { return nil }
        return Set(old.keys).union(new.keys).filter { entry in
            let before = old[entry] ?? "", after = new[entry] ?? ""
            guard before != after else { return false }
            let diff = LineDiff.between(before, after)
            return diff.added > 0 || diff.removed > 0
        }.map(\.description).sorted()
    }

    /// What this revision follows: the latest of its reading before it with code.
    func revisionBefore(project: String, rev: Int, in revisions: [ReviewRevision]) -> SHA256Digest? {
        revisions.filter { $0.project == project && $0.rev < rev && $0.artifact != nil }
            .max { $0.rev < $1.rev }?.artifact
    }

    /// Works out what the revisions of a history written before they said so
    /// changed. Needs their code here, so a mirror leaves it to its server.
    /// Answers whether the history was written.
    @discardableResult
    public func backfillChangedFunctions(module: SHA256Digest) throws -> Bool {
        guard objectSource == nil, let history = try reviewHistory(module: module) else { return false }
        var found: [Int: [String]] = [:]
        for (index, revision) in history.revisions.enumerated() where revision.changedFunctions == nil {
            guard let artifact = revision.artifact else { continue }
            let before = revisionBefore(project: revision.project, rev: revision.rev, in: history.revisions)
            found[index] = changedFunctions(in: artifact, after: before)
        }
        guard !found.isEmpty else { return false }
        let url = reviewHistoryURL(module)
        return try withLock {
            guard var current = try reviewHistory(module: module) else { return false }
            var wrote = false
            for (index, changed) in found {
                let revision = history.revisions[index]
                guard let at = current.revisions.firstIndex(where: {
                    $0.project == revision.project && $0.rev == revision.rev && $0.artifact == revision.artifact
                }), current.revisions[at].changedFunctions == nil else { continue }
                current.revisions[at].changedFunctions = changed
                wrote = true
            }
            if wrote { try atomicWrite(try encoder.encode(current), to: url) }
            return wrote
        }
    }

    /// Every module's history; a module that cannot be worked out stays as it
    /// is. Answers how many were written.
    @discardableResult
    public func backfillChangedFunctions() -> Int {
        reviewHistories().reduce(0) { count, history in
            count + (((try? backfillChangedFunctions(module: history.module)) ?? false) ? 1 : 0)
        }
    }

    /// Each function's C, read without the rest of what a function holds: a
    /// tenth of the time of the whole artifact.
    private func functionCode(of artifact: SHA256Digest) -> [CodeAddress: String]? {
        struct Code: Decodable {
            struct Function: Decodable {
                let entry: CodeAddress
                let c: String?
            }
            let functions: [Function]
        }
        guard let data = try? object(artifact),
              let code = try? JSONDecoder().decode(Code.self, from: data) else { return nil }
        var functions: [CodeAddress: String] = [:]
        for function in code.functions where functions[function.entry] == nil {
            functions[function.entry] = function.c ?? ""
        }
        return functions
    }
}
