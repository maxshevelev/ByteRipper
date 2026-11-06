import Foundation

/// The revision a registry source names. A publish numbers what it gives the
/// registry before the store has recorded the revision, and the store makes
/// none when the module's code and review are those of its last one: the
/// sources then say the number the revision would have had, and are put back
/// on the one it is.
extension ContentStore {
    /// Every source of `module` that names revision `from` — an entry's, a
    /// taken-out entry's, a history row's — made to name `to`. The count of
    /// sources changed; with `dryRun`, the count that would be, and nothing
    /// written.
    @discardableResult
    public func renumberLibrarySources(module: SHA256Digest, from: Int, to: Int, dryRun: Bool = false) throws -> Int {
        guard from != to else { return 0 }
        func moved(_ source: inout LibrarySource) -> Bool {
            guard source.module == module, source.rev == from else { return false }
            source.rev = to
            return true
        }
        return try withLock {
            var count = 0
            var index = try libraryIndex()
            var indexChanged = false
            for id in index.entries.keys.sorted() where moved(&index.entries[id]!.source) {
                count += 1
                indexChanged = true
            }
            for id in (index.takenOut ?? [:]).keys.sorted() where moved(&index.takenOut![id]!.source) {
                count += 1
                indexChanged = true
            }
            var histories: [(LibraryHistory, URL)] = []
            for url in contents(of: libraryURL.appendingPathComponent("history", isDirectory: true))
            where url.pathExtension == "json" {
                var history: LibraryHistory
                do {
                    history = try decoder.decode(LibraryHistory.self, from: Data(contentsOf: url))
                } catch {
                    throw CodeAnalysisError.io("\(url.path): \(error)")
                }
                var changed = false
                for row in history.versions.indices where moved(&history.versions[row].source) {
                    count += 1
                    changed = true
                }
                if changed { histories.append((history, url)) }
            }
            guard !dryRun else { return count }
            for (history, url) in histories { try atomicWrite(try encoder.encode(history), to: url) }
            if indexChanged { try atomicWrite(try encoder.encode(index), to: libraryIndexURL) }
            return count
        }
    }

    /// Registry sources that name a revision the module's history does not
    /// hold. A mirror holds the histories it was asked for, and says nothing.
    func verifyLibrarySources() -> [String] {
        guard partSource == nil, let index = try? libraryIndex() else { return [] }
        var revisions: [SHA256Digest: Set<Int>] = [:]
        func holds(_ source: LibrarySource) -> Bool {
            guard let rev = source.rev else { return true }
            if revisions[source.module] == nil {
                revisions[source.module] = Set(((try? reviewHistory(module: source.module))?.revisions ?? []).map(\.rev))
            }
            return revisions[source.module]!.contains(rev)
        }
        func said(_ what: String, _ source: LibrarySource) -> String {
            "\(what): its source names revision \(source.rev ?? 0) of \(source.module.hex), which the module's history does not hold"
        }
        var problems: [String] = []
        for (id, entry) in index.entries.sorted(by: { $0.key < $1.key }) where !holds(entry.source) {
            problems.append(said("library entry \(id)", entry.source))
        }
        for (id, out) in (index.takenOut ?? [:]).sorted(by: { $0.key < $1.key }) where !holds(out.source) {
            problems.append(said("taken-out entry \(id)", out.source))
        }
        let folder = libraryURL.appendingPathComponent("history", isDirectory: true)
        for url in contents(of: folder).sorted(by: { $0.path < $1.path }) where url.pathExtension == "json" {
            guard let history = try? decoder.decode(LibraryHistory.self, from: Data(contentsOf: url)) else { continue }
            for row in history.versions where !holds(row.source) {
                problems.append(said("library history \(history.id) version \(row.version)", row.source))
            }
        }
        return problems
    }
}
