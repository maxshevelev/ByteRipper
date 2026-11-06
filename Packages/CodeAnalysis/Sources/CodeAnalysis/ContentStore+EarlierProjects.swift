import Foundation

/// What a module's earlier Ghidra projects left in the store. Before a
/// revision knew nothing of its project, a project made afresh started its own
/// revisions, and the reader hid every analysis of the one it replaced. A
/// module has one history now: those analyses and revisions are nobody's, and
/// go — the objects they name stay for `gc` (`byteripper-cas drop-earlier-projects`).
extension ContentStore {
    /// One module's part of the plan.
    public struct EarlierProject: Codable, Equatable, Sendable {
        public var module: SHA256Digest
        public var name: String?
        /// The project of the module's newest analysis, which stays.
        public var current: String
        /// What stays: the newest analysis's recipe and revision.
        public var keptRecipe: String
        public var keptRev: Int
        /// What goes: the analyses (recipes) and the revisions of other projects,
        /// and the readings an import kept aside.
        public var analyses: [String]
        public var revisions: [Revision]
        public var keptAside: [String]

        public struct Revision: Codable, Equatable, Sendable {
            public var project: String
            public var rev: Int
            public var recordedAt: String

            private enum CodingKeys: String, CodingKey {
                case project, rev
                case recordedAt = "recorded_at"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case module, name, current, analyses, revisions
            case keptRecipe = "kept_recipe"
            case keptRev = "kept_rev"
            case keptAside = "kept_aside"
        }
    }

    /// A registry entry that names a revision on the list as its current
    /// source: it needs a decision before the revision goes.
    public struct EarlierProjectSource: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var module: SHA256Digest
        public var rev: Int
        /// Whether the entry is one taken out of the registry.
        public var takenOut: Bool

        private enum CodingKeys: String, CodingKey {
            case id, name, module, rev
            case takenOut = "taken_out"
        }
    }

    public struct EarlierProjects: Codable, Equatable, Sendable {
        public var modules: [EarlierProject]
        /// Entries whose current source is a revision on the list: `--apply`
        /// refuses while there is one.
        public var sources: [EarlierProjectSource]
        /// Rows of the registry's histories that only name a revision on the list.
        public var historyRows: Int
        public var analyses: Int
        public var revisions: Int
        public var applied: Bool

        private enum CodingKeys: String, CodingKey {
            case modules, sources, analyses, revisions, applied
            case historyRows = "history_rows"
        }
    }

    /// What `dropEarlierProjects` would remove, and what in the registry holds on to it.
    public func earlierProjects() throws -> EarlierProjects {
        var modules: [EarlierProject] = []
        var dropped: [SHA256Digest: [EarlierProject.Revision]] = [:]
        var kept: [SHA256Digest: [ReviewRevision]] = [:]
        let byModule = Dictionary(grouping: analyses(), by: \.module.sha256)
        let aside = Dictionary(grouping: conflicts(), by: \.module.sha256)
        for (module, manifests) in byModule.sorted(by: { $0.key < $1.key }) {
            // The project the reader showed: the newest analysis that names one.
            guard let newest = manifests.filter({ $0.reading?.project != nil }).max(by: ContentStore.olderThan),
                  let current = newest.reading?.project else { continue }
            let other = manifests.filter { ($0.reading?.project).map { $0 != current } ?? false }
            let history = try reviewHistory(module: module)?.revisions ?? []
            let gone = history.filter { ($0.project).map { $0 != current } ?? false }
            let sideways = (aside[module] ?? []).compactMap(\.key?.recipe)
            guard !other.isEmpty || !gone.isEmpty || !sideways.isEmpty else { continue }
            let revisions = gone.map { EarlierProject.Revision(project: $0.project ?? "", rev: $0.rev,
                                                               recordedAt: $0.recordedAt) }
            dropped[module] = revisions
            kept[module] = history.filter { ($0.project).map { $0 == current } ?? true }
            modules.append(EarlierProject(module: module, name: newest.module.name, current: current,
                                          keptRecipe: newest.recipe.id, keptRev: newest.reading?.rev ?? 0,
                                          analyses: other.map(\.recipe.id).sorted(), revisions: revisions,
                                          keptAside: sideways.sorted()))
        }
        // A source names a module and a revision number, not a project: the
        // revision of that number recorded nearest the entry's version is it.
        func isDropped(_ source: LibrarySource, at time: String?) -> Bool {
            guard let rev = source.rev, let gone = dropped[source.module] else { return false }
            let candidates = gone.filter { $0.rev == rev }.map { (true, $0.recordedAt) }
                + (kept[source.module] ?? []).filter { $0.rev == rev }.map { (false, $0.recordedAt) }
            guard let time, let when = Self.instant(time) else { return candidates.contains { $0.0 } }
            return candidates.min { left, right in
                abs((Self.instant(left.1) ?? .distantPast).timeIntervalSince(when))
                    < abs((Self.instant(right.1) ?? .distantPast).timeIntervalSince(when))
            }?.0 ?? false
        }
        let index = try libraryIndex()
        var sources: [EarlierProjectSource] = []
        var rows = 0
        var held: [(id: String, name: String, version: Int, source: LibrarySource, takenOut: Bool)] =
            index.entries.map { ($0.key, $0.value.name, $0.value.version, $0.value.source, false) }
        held += (index.takenOut ?? [:]).values.map { ($0.id, $0.name, $0.version, $0.source, true) }
        for entry in held.sorted(by: { $0.id < $1.id }) {
            let history = try libraryHistory(id: entry.id)?.versions ?? []
            let at = history.last { $0.version == entry.version }?.recordedAt
            if isDropped(entry.source, at: at) {
                sources.append(.init(id: entry.id, name: entry.name, module: entry.source.module,
                                     rev: entry.source.rev ?? 0, takenOut: entry.takenOut))
            }
            rows += history.filter { isDropped($0.source, at: $0.recordedAt) }.count
        }
        return EarlierProjects(modules: modules, sources: sources, historyRows: rows,
                               analyses: modules.reduce(0) { $0 + $1.analyses.count + $1.keptAside.count },
                               revisions: modules.reduce(0) { $0 + $1.revisions.count }, applied: false)
    }

    /// The earlier projects' analyses, revisions and kept-aside readings removed.
    /// Refused while a registry entry's current source is one of the revisions,
    /// or when what would stay is not the module's newest analysis.
    public func dropEarlierProjects(apply: Bool) throws -> EarlierProjects {
        var plan = try earlierProjects()
        guard apply else { return plan }
        if let first = plan.sources.first {
            throw CodeAnalysisError.analysisMismatch(
                "\(plan.sources.count) registry entries name a revision on the list as their source, "
                + "\(first.name) (\(first.id)) the first: decide them before the revisions go")
        }
        try withLock {
            for module in plan.modules {
                for recipe in module.analyses {
                    guard let key = AnalysisKey(module: module.module, recipe: recipe) else { continue }
                    let manifest = try decodeManifest(at: manifestURL(key))
                    // Checked again under the lock: the analysis that stays is never on the list.
                    guard manifest.reading?.project != module.current else { continue }
                    try FileManager.default.removeItem(at: manifestURL(key).deletingLastPathComponent())
                }
                for recipe in module.keptAside {
                    let folder = conflictsURL.appendingPathComponent(module.module.hex, isDirectory: true)
                        .appendingPathComponent(recipe, isDirectory: true)
                    try? FileManager.default.removeItem(at: folder)
                }
                let aside = conflictsURL.appendingPathComponent(module.module.hex, isDirectory: true)
                if (try? FileManager.default.contentsOfDirectory(atPath: aside.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: aside)
                }
                if var history = try reviewHistory(module: module.module) {
                    history.revisions.removeAll { ($0.project).map { $0 != module.current } ?? false }
                    try atomicWrite(try encoder.encode(history), to: reviewHistoryURL(module.module))
                }
            }
        }
        plan.applied = true
        return plan
    }

    static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)
    }
}
