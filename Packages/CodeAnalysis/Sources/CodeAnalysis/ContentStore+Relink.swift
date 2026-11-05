import Foundation

extension ContentStore {
    /// One module whose stored functions became links.
    public struct Relinked: Codable, Equatable, Sendable {
        public var module: SHA256Digest
        public var recipe: String
        public var links: Int
    }

    /// A library function has one place. Every stored analysis is brought to the
    /// stored form against the registry as it is now: a function whose body the
    /// registry holds becomes a link, and the module's text of it goes, from the
    /// artifact and from the review. `bodies` limits the walk to analyses holding
    /// those bodies; nil is all of them.
    @discardableResult
    public func relinkModules(bodies: Set<String>? = nil, dryRun: Bool = false) throws -> [Relinked] {
        // A whole walk first brings the registry its code, from the modules that have it.
        var learned: [SHA256Digest: Data] = [:]
        let index = try bodies == nil ? learnLibraryCode(dryRun: dryRun, learned: &learned) : libraryIndex()
        var done: [Relinked] = []
        for found in analyses() {
            // The artifact's root lists every function's body: most analyses end here.
            if let bodies, let root = try? objectRoot(found.artifact.sha256),
               !bodies.contains(where: { root.range(of: Data($0.utf8)) != nil }) { continue }
            guard let whole = try? object(found.artifact.sha256) else { continue }
            let code = libraryCode(for: whole, index: index).merging(learned) { held, _ in held }
            let stored = ModuleFormat.stored(whole, index: index, code: code)
            let review = try found.reading?.review.map { try object($0) }
            let newReview = review.map { ModuleFormat.review($0, of: stored) }
            guard stored.artifact != whole || newReview != review else { continue }
            done.append(Relinked(module: found.module.sha256, recipe: found.recipe.id, links: stored.functions.count))
            if dryRun { continue }
            let digest = try putObject(stored.artifact)
            let reviewDigest = try newReview.map { try putObject($0) }
            guard let key = found.key else { continue }
            try withLock {
                // A publish that came in meanwhile is the newer word.
                var manifest = try decodeManifest(at: manifestURL(key))
                guard manifest.artifact.sha256 == found.artifact.sha256 else { return }
                manifest.relinkedFrom = manifest.relinkedFrom ?? manifest.artifact.sha256
                manifest.artifact = AnalysisArtifact(sha256: digest, size: stored.artifact.count,
                                                     mediaType: manifest.artifact.mediaType)
                manifest.stats = ArtifactStats.count(in: stored.artifact)
                if let reviewDigest { manifest.reading?.review = reviewDigest }
                try atomicWrite(try encoder.encode(manifest), to: manifestURL(key))
            }
        }
        return done
    }

    /// The code objects an artifact's functions read through.
    func libraryCode(for artifact: Data, index: LibraryIndex) -> [SHA256Digest: Data] {
        var code: [SHA256Digest: Data] = [:]
        for digest in ModuleFormat.codeNeeded(artifact, index: index) {
            if let held = try? object(digest) { code[digest] = held }
        }
        return code
    }

    /// Every body the registry holds with no code takes it from a stored analysis
    /// that still has its instructions, its source module first. No version moves:
    /// the entry's review is what it was. A dry run keeps it to the answer.
    func learnLibraryCode(dryRun: Bool, learned: inout [SHA256Digest: Data]) throws -> LibraryIndex {
        var index = try libraryIndex()
        let all = analyses()
        func teach(_ found: [AnalysisManifest], onlySource: Bool) throws {
            for analysis in found {
                guard let whole = try? object(analysis.artifact.sha256) else { continue }
                for teaching in ModuleFormat.teachings(whole, index: index) {
                    if onlySource, teaching.variant.module != analysis.module.sha256 { continue }
                    guard let position = index.entries[teaching.id]?.variants.firstIndex(where: {
                        $0.body.key == teaching.variant.body.key }) else { continue }
                    let digest = dryRun ? SHA256Digest(data: teaching.code) : try putObject(teaching.code)
                    index.entries[teaching.id]?.variants[position].code = digest
                    learned[digest] = teaching.code
                }
            }
        }
        try teach(all, onlySource: true)
        try teach(all, onlySource: false)
        if !dryRun, !learned.isEmpty {
            let final = index
            try withLock {
                var held = try libraryIndex()
                for (id, entry) in final.entries {
                    guard let row = held.entries[id] else { continue }
                    for variant in entry.variants where variant.code != nil {
                        if let position = row.variants.firstIndex(where: { $0.body.key == variant.body.key }) {
                            held.entries[id]?.variants[position].code = variant.code
                        }
                    }
                }
                try atomicWrite(try encoder.encode(held), to: libraryIndexURL)
            }
            return try libraryIndex()
        }
        return index
    }

    /// How one stored analysis holds the registry's functions, read from its bytes.
    public struct LibraryHolding: Equatable, Sendable {
        public var module: SHA256Digest
        public var name: String
        public var recipe: String
        public var links: Int
        /// Functions with text whose body the registry holds: never, after `stored`.
        public var ownBodiesInRegistry: Int
        /// Links holding a field no link has, and functions holding a word of the
        /// old form: never, after `stored`.
        public var outOfFormat: Int
    }

    /// Every stored analysis, counted. It reads each one whole.
    public func libraryHoldings() throws -> [LibraryHolding] {
        let index = try libraryIndex()
        return analyses().compactMap { found in
            guard let whole = try? object(found.artifact.sha256),
                  let root = (try? JSONSerialization.jsonObject(with: whole)) as? [String: Any],
                  let functions = root["functions"] as? [[String: Any]] else { return nil }
            var holding = LibraryHolding(module: found.module.sha256, name: found.module.name ?? "",
                                         recipe: found.recipe.id, links: 0, ownBodiesInRegistry: 0, outOfFormat: 0)
            for function in functions {
                if function["registry"] != nil {
                    holding.links += 1
                    if !ModuleFormat.isLink(function) { holding.outOfFormat += 1 }
                } else {
                    if ModuleFormat.holdsOldWords(function) { holding.outOfFormat += 1 }
                    if LibraryView.entryID(body: function["body"] as? String, mark: nil,
                                           external: function["external"] as? Bool ?? false,
                                           thunk: function["thunk"] as? Bool ?? false,
                                           referenceBytes: function["reference_bytes"] as? String, in: index) != nil {
                        holding.ownBodiesInRegistry += 1
                    }
                }
            }
            return holding
        }
    }
}
