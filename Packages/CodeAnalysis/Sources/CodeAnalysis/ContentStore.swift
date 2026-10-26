import CryptoKit
import Darwin
import Foundation

/// The local content-addressed store for code artifacts.
///
/// The layout is the one `Skills/ghidra-uefi/reference/cas.md` describes:
/// immutable objects under `objects/<sha256>`, a manifest for each analysis
/// under `analyses/<module-sha>/<recipe>/manifest.json`, and named references
/// under `refs/`, another project's reading of an analysis kept aside under
/// `conflicts/<module-sha>/<recipe>/<artifact-sha>.json`, and the revisions of
/// a module's readings under `reviews/<module-sha>/manifest.json`. The
/// directory is the index; a reader walks it.
///
/// This is the store's one implementation. The skill's Python reaches it
/// through the `byteripper-cas` tool (`CASCommand`), so a rule — which reading
/// replaces which — is written once.
///
/// Writes are atomic and the writes that can race — a manifest, a reference, a
/// collection — take a file lock. Reads verify an object against its hash. The
/// store links nothing: CryptoKit hashes, Foundation writes, Darwin locks.
public struct ContentStore: Sendable {
    public let root: URL

    public init(root: URL, create: Bool = true) throws {
        self.root = root.standardizedFileURL
        if create {
            for folder in [self.root, objectsURL, analysesURL, refsURL, tmpURL] {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
        }
    }

    // MARK: - Paths

    public var objectsURL: URL { root.appendingPathComponent("objects", isDirectory: true) }
    public var analysesURL: URL { root.appendingPathComponent("analyses", isDirectory: true) }
    public var refsURL: URL { root.appendingPathComponent("refs", isDirectory: true) }
    public var tmpURL: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    public var conflictsURL: URL { root.appendingPathComponent("conflicts", isDirectory: true) }
    public var reviewsURL: URL { root.appendingPathComponent("reviews", isDirectory: true) }
    private var lockURL: URL { root.appendingPathComponent(".lock") }

    public func objectURL(_ digest: SHA256Digest) -> URL {
        objectsURL.appendingPathComponent(digest.hex, isDirectory: false)
    }

    public func manifestURL(_ key: AnalysisKey) -> URL {
        analysesURL
            .appendingPathComponent(key.module.hex, isDirectory: true)
            .appendingPathComponent(key.recipe, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    public func reviewHistoryURL(_ module: SHA256Digest) -> URL {
        reviewsURL
            .appendingPathComponent(module.hex, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    public func refURL(_ name: String) throws -> URL {
        guard SafeName.isSafe(name) else { throw CodeAnalysisError.invalidName(name) }
        return refsURL.appendingPathComponent("\(name).json", isDirectory: false)
    }

    // MARK: - Objects

    public func hasObject(_ digest: SHA256Digest) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: objectURL(digest).path,
                                              isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    @discardableResult
    public func putObject(_ data: Data) throws -> SHA256Digest {
        let digest = SHA256Digest(data: data)
        let url = objectURL(digest)
        if FileManager.default.fileExists(atPath: url.path) {
            return digest
        }
        try atomicWrite(data, to: url)
        return digest
    }

    public func object(_ digest: SHA256Digest) throws -> Data {
        let url = objectURL(digest)
        guard let data = try? Data(contentsOf: url) else {
            throw CodeAnalysisError.objectMissing(digest.hex)
        }
        guard SHA256Digest(data: data) == digest else {
            throw CodeAnalysisError.objectCorrupt(digest.hex)
        }
        return data
    }

    /// The typed artifact a manifest names: its object, checked against its
    /// hash, then decoded. The one way the app and an agent load an artifact,
    /// so a reader that refuses an exporter version refuses it everywhere.
    public func artifact(for manifest: AnalysisManifest) throws -> CodeArtifact {
        let data = try object(manifest.artifact.sha256)
        do {
            return try JSONDecoder().decode(CodeArtifact.self, from: data)
        } catch let error as CodeArtifactError {
            throw error
        } catch {
            throw CodeArtifactError.invalid("\(error)")
        }
    }

    // MARK: - Analyses

    /// Store an artifact and the manifest that names it.
    ///
    /// The same artifact under the same key is the same analysis: what the
    /// caller names of its source is merged in, and a newer reading — over
    /// none, or a later revision of the same project — replaces the stored
    /// one. Another artifact replaces the stored one
    /// when its reading is newer (`ReadingOrder.newer`). Otherwise it is
    /// refused, except that `replace` lets a mechanical artifact replace a
    /// mechanical one — a re-run by hand — and `discardReading` lets anything
    /// replace anything.
    @discardableResult
    public func putAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe,
                            artifact: Data, source: SourceIdentity = SourceIdentity(),
                            reading: AnalysisReading? = nil,
                            replace: Bool = false,
                            discardReading: Bool = false) throws -> AnalysisManifest {
        guard SafeName.isSafe(recipe.id) else {
            throw CodeAnalysisError.invalidRecipe(recipe.id)
        }
        let digest = try putObject(artifact)
        let manifest = AnalysisManifest(
            module: module,
            recipe: recipe,
            artifact: AnalysisArtifact(sha256: digest, size: artifact.count,
                                       mediaType: "application/json"),
            source: source,
            analyzedAt: Timestamps.now(),
            stats: ArtifactStats.count(in: artifact),
            reading: reading)
        let url = manifestURL(manifest.key!)
        return try withLock {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try decodeManifest(at: url)
                if existing.artifact.sha256 == digest {
                    // The artifact is the same analysis; a re-run may still
                    // know where it came from. Merge only what the caller
                    // names, so a later run without a node does not erase the
                    // binding an earlier one wrote.
                    var merged = existing.source
                    var rebound = false
                    if let path = source.path, path != merged.path {
                        merged.path = path
                        rebound = true
                    }
                    if let document = source.document, document != merged.document {
                        merged.document = document
                        rebound = true
                    }
                    if let node = source.node, node != merged.node {
                        merged.node = node
                        rebound = true
                    }
                    // A newer revision of the same reading may render to the
                    // same artifact — a comment is in the review document, not
                    // in the artifact — and still has to name its document.
                    var updated = existing
                    if let reading, reading != existing.reading,
                       ReadingOrder(incoming: reading, stored: existing.reading) == .newer {
                        updated.reading = reading
                        rebound = true
                    }
                    guard rebound else { return existing }
                    updated.source = merged
                    try atomicWrite(try encoder.encode(updated), to: url)
                    return updated
                }
                if !discardReading {
                    let key = manifest.key!
                    switch ReadingOrder(incoming: reading, stored: existing.reading) {
                    case .newer:
                        break
                    case .unreviewed:
                        guard replace else {
                            throw CodeAnalysisError.analysisMismatch(
                                "\(key) already exists with another artifact; pass replace")
                        }
                    case .notNewer:
                        throw CodeAnalysisError.analysisMismatch(
                            "\(key) already holds revision \(existing.reading!.rev) of this reading")
                    case .unreviewedOverReviewed:
                        throw CodeAnalysisError.analysisMismatch(
                            "\(key) holds a reviewed reading; pass discard-reading to replace it")
                    case .otherProject:
                        throw CodeAnalysisError.analysisMismatch(
                            "\(key) holds another project's reading; pass discard-reading to replace it")
                    }
                }
            }
            try atomicWrite(try encoder.encode(manifest), to: url)
            return manifest
        }
    }

    public func analysis(module: SHA256Digest, recipe: String) throws -> AnalysisManifest? {
        guard SafeName.isSafe(recipe) else {
            throw CodeAnalysisError.invalidRecipe(recipe)
        }
        let url = manifestURL(AnalysisKey(module: module, recipe: recipe)!)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decodeManifest(at: url)
    }

    /// The newest analysis of a module, whatever its recipe.
    public func analysis(module: SHA256Digest) throws -> AnalysisManifest? {
        var manifests: [AnalysisManifest] = []
        for recipe in recipes(ofModule: module) {
            if let manifest = try analysis(module: module, recipe: recipe) {
                manifests.append(manifest)
            }
        }
        return manifests.max { left, right in
            if left.analyzedAt == right.analyzedAt {
                return left.recipe.id < right.recipe.id
            }
            return left.analyzedAt < right.analyzedAt
        }
    }

    public func recipes(ofModule module: SHA256Digest) -> [String] {
        let folder = analysesURL.appendingPathComponent(module.hex, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { FileManager.default.fileExists(atPath: $0
                .appendingPathComponent("manifest.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Every valid manifest, module by module, recipe by recipe. An unreadable
    /// manifest is left out here and reported by `verify`.
    public func analyses() -> [AnalysisManifest] {
        loadedManifests().loaded.map(\.manifest).sorted {
            if $0.module.sha256 == $1.module.sha256 { return $0.recipe.id < $1.recipe.id }
            return $0.module.sha256 < $1.module.sha256
        }
    }

    /// The analyses the panel may offer: a readable manifest whose artifact
    /// object is present. An object whose bytes are corrupt is still present;
    /// opening it reports that, and `verify` names it before then.
    ///
    /// This is the one walk the code-analysis index makes. It never reads an
    /// artifact body, so an empty or missing store costs no hashing.
    public func usableAnalyses() -> [AnalysisManifest] {
        analyses().filter { hasObject($0.artifact.sha256) }
    }

    public func key(of manifest: AnalysisManifest) -> AnalysisKey? { manifest.key }

    /// The readings a bundle import kept aside, because another project's
    /// reading of the same analysis is stored.
    public func conflicts() -> [AnalysisManifest] {
        var found: [AnalysisManifest] = []
        for module in contents(of: conflictsURL) where isDirectory(module) {
            for recipe in contents(of: module) where isDirectory(recipe) {
                for url in contents(of: recipe) where url.pathExtension == "json" {
                    if let manifest = try? decodeManifest(at: url) { found.append(manifest) }
                }
            }
        }
        return found.sorted {
            ($0.key?.description ?? "", $0.artifact.sha256) < ($1.key?.description ?? "", $1.artifact.sha256)
        }
    }

    private func conflictURL(for manifest: AnalysisManifest, key: AnalysisKey) -> URL {
        conflictsURL
            .appendingPathComponent(key.module.hex, isDirectory: true)
            .appendingPathComponent(key.recipe, isDirectory: true)
            .appendingPathComponent("\(manifest.artifact.sha256.hex).json", isDirectory: false)
    }

    // MARK: - Review history

    /// Record a revision of a reading in its module's history. A publish
    /// stores, in this order, the review document, this revision, and then the
    /// analysis whose `reading` names it (`Design/GHIDRA_SHARED_PLAN.md` §5.4):
    /// the document must already be here, and a revision a failed publish left
    /// behind is overwritten by the next publish of the same revision.
    @discardableResult
    public func recordRevision(module: SHA256Digest, reading: AnalysisReading,
                               by: String? = nil) throws -> ReviewHistory {
        guard let review = reading.review else {
            throw CodeAnalysisError.analysisMismatch("a revision names its review document")
        }
        guard hasObject(review) else { throw CodeAnalysisError.objectMissing(review.hex) }
        let url = reviewHistoryURL(module)
        return try withLock {
            var history = try reviewHistory(module: module) ?? ReviewHistory(module: module)
            let revision = ReviewRevision(project: reading.project, rev: reading.rev, review: review,
                                          recordedAt: Timestamps.now(), by: by)
            if let at = history.revisions.firstIndex(where: {
                $0.project == reading.project && $0.rev == reading.rev
            }) {
                guard history.revisions[at].review != review else { return history }
                history.revisions[at] = revision
            } else {
                history.revisions.append(revision)
            }
            try atomicWrite(try encoder.encode(history), to: url)
            return history
        }
    }

    public func reviewHistory(module: SHA256Digest) throws -> ReviewHistory? {
        let url = reviewHistoryURL(module)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(ReviewHistory.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    /// Every module's history; an unreadable one is left out here and
    /// reported by `verify`.
    public func reviewHistories() -> [ReviewHistory] {
        contents(of: reviewsURL).compactMap { folder in
            SHA256Digest(hex: folder.lastPathComponent).flatMap { try? reviewHistory(module: $0) }
        }
    }

    // MARK: - References

    @discardableResult
    public func setRef(_ name: String, analyses keys: [AnalysisKey]) throws -> AnalysisRef {
        let url = try refURL(name)
        for key in keys {
            guard try analysis(module: key.module, recipe: key.recipe) != nil else {
                throw CodeAnalysisError.analysisMissing(key.description)
            }
        }
        let record = AnalysisRef(name: name, analyses: Array(Set(keys)).sorted(),
                                 updatedAt: Timestamps.now())
        return try withLock {
            try atomicWrite(try encoder.encode(record), to: url)
            return record
        }
    }

    public func refs() -> [AnalysisRef] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: refsURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(AnalysisRef.self,
                                              from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    public func referencedKeys() -> Set<AnalysisKey> {
        Set(refs().flatMap(\.analyses))
    }

    @discardableResult
    public func removeRef(_ name: String) throws -> Bool {
        let url = try refURL(name)
        return try withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        }
    }

    // MARK: - Integrity

    /// Every object's hash, every manifest's path and artifact, every
    /// reference's target. Empty means the store is sound.
    public func verify() -> [String] {
        var problems: [String] = []
        let objects = contents(of: objectsURL)
        for url in objects {
            let name = url.lastPathComponent
            guard let digest = SHA256Digest(hex: name) else {
                problems.append("objects/\(name): not a SHA-256 name")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                problems.append("objects/\(name): cannot be read")
                continue
            }
            if SHA256Digest(data: data) != digest {
                problems.append("objects/\(name): bytes hash to \(SHA256Digest(data: data).hex)")
            }
        }

        let loaded = loadedManifests()
        problems += loaded.problems
        for entry in loaded.loaded {
            let manifest = entry.manifest
            guard let key = manifest.key else {
                problems.append("\(entry.module)/\(entry.recipe): manifest key is not a name")
                continue
            }
            if key.module.hex != entry.module || key.recipe != entry.recipe {
                problems.append("\(entry.module)/\(entry.recipe): manifest names \(key.description)")
            }
            if !hasObject(manifest.artifact.sha256) {
                problems.append("\(key.description): artifact \(manifest.artifact.sha256.hex) is missing")
            }
            if let review = manifest.reading?.review, !hasObject(review) {
                problems.append("\(key.description): review document \(review.hex) is missing")
            }
        }

        // A history entry ahead of every manifest of its project is a publish
        // that stopped after recording the revision.
        let readings = loaded.loaded.map(\.manifest) + conflicts()
        for folder in contents(of: reviewsURL) {
            let name = folder.lastPathComponent
            guard let module = SHA256Digest(hex: name) else {
                problems.append("reviews/\(name): not a SHA-256 name")
                continue
            }
            guard let history = try? reviewHistory(module: module) else {
                problems.append("reviews/\(name): cannot be read")
                continue
            }
            var latest: [String: Int] = [:]
            for revision in history.revisions {
                if !hasObject(revision.review) {
                    problems.append("reviews/\(name): revision \(revision.rev) of \(revision.project): "
                                    + "review document \(revision.review.hex) is missing")
                }
                latest[revision.project] = max(latest[revision.project] ?? 0, revision.rev)
            }
            for (project, rev) in latest.sorted(by: { $0.key < $1.key }) {
                let named = readings
                    .filter { $0.module.sha256 == module && $0.reading?.project == project }
                    .compactMap(\.reading?.rev).max()
                if named.map({ $0 < rev }) ?? true {
                    problems.append("reviews/\(name): revision \(rev) of \(project) is ahead of its analysis"
                                    + (named.map { " (revision \($0))" } ?? ""))
                }
            }
        }

        for manifest in conflicts() where !hasObject(manifest.artifact.sha256) {
            problems.append("conflicts/\(manifest.key?.description ?? "?"): artifact "
                            + "\(manifest.artifact.sha256.hex) is missing")
        }

        let refEntries = contents(of: refsURL).filter { $0.pathExtension == "json" }
        for url in refEntries {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(AnalysisRef.self, from: data) else {
                problems.append("refs/\(url.lastPathComponent): cannot be read")
                continue
            }
            for key in record.analyses {
                if (try? analysis(module: key.module, recipe: key.recipe)) == nil {
                    problems.append("refs/\(record.name): no analysis for \(key.description)")
                }
            }
        }
        return problems
    }

    // MARK: - Collection

    /// Remove objects no manifest names; with `deleteUnreferencedAnalyses`,
    /// also analyses no reference names. A dry run reports without deleting.
    public func collectGarbage(dryRun: Bool = true,
                               deleteUnreferencedAnalyses: Bool = false) throws -> GarbageReport {
        let referenced = referencedKeys()
        let all = analyses()
        let keep: [AnalysisManifest]
        let drop: [AnalysisManifest]
        if deleteUnreferencedAnalyses {
            keep = all.filter { manifest in
                manifest.key.map(referenced.contains) ?? false
            }
            drop = all.filter { manifest in
                manifest.key.map { !referenced.contains($0) } ?? false
            }
        } else {
            keep = all
            drop = []
        }
        // An object stays while a kept manifest names it: as its artifact, or
        // as the review document of its reading. A reading kept aside is still
        // a person's to choose, so its objects stay too.
        let named = keep + conflicts()
        // Every document a history names stays too: the history is the base
        // for a diff, and pruning it is what lets its documents go.
        let keepObjects = Set(named.map(\.artifact.sha256))
            .union(named.compactMap(\.reading?.review))
            .union(reviewHistories().flatMap { $0.revisions.map(\.review) })
        let orphanObjects = contents(of: objectsURL).filter {
            guard let digest = SHA256Digest(hex: $0.lastPathComponent) else { return true }
            return !keepObjects.contains(digest)
        }
        let report = GarbageReport(objects: orphanObjects.count, analyses: drop.count,
                                   keptAnalyses: keep.count, keptObjects: keepObjects.count,
                                   dryRun: dryRun)
        guard !dryRun else { return report }

        return try withLock {
            for manifest in drop {
                guard let key = manifest.key else { continue }
                try? FileManager.default.removeItem(at: manifestURL(key).deletingLastPathComponent())
            }
            for url in orphanObjects {
                try? FileManager.default.removeItem(at: url)
            }
            for folder in contents(of: analysesURL) {
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            for url in contents(of: tmpURL) {
                try? FileManager.default.removeItem(at: url)
            }
            return report
        }
    }

    // MARK: - Bundles

    /// Write the chosen analyses and their objects as a stored zip. The
    /// bundle is what a project carries to another machine.
    @discardableResult
    public func exportBundle(_ keys: [AnalysisKey], to url: URL) throws -> BundleInfo {
        var manifests: [AnalysisManifest] = []
        for key in keys {
            guard let manifest = try analysis(module: key.module, recipe: key.recipe) else {
                throw CodeAnalysisError.analysisMissing(key.description)
            }
            manifests.append(manifest)
        }
        let info = BundleInfo(createdAt: Timestamps.now(), analyses: keys)
        var entries: [String: Data] = ["bundle.json": try encoder.encode(info)]
        for manifest in manifests {
            guard let key = manifest.key else {
                throw CodeAnalysisError.invalidRecipe(manifest.recipe.id)
            }
            let manifestURL = manifestURL(key)
            entries["analyses/\(key.description)/manifest.json"] = try Data(contentsOf: manifestURL)
            entries["objects/\(manifest.artifact.sha256.hex)"] =
                try object(manifest.artifact.sha256)
            // The reading travels with its rendering.
            if let review = manifest.reading?.review {
                entries["objects/\(review.hex)"] = try object(review)
            }
        }
        try BundleArchive.write(entries: entries, to: url)
        return info
    }

    /// Read a bundle and take each analysis it carries by the rule
    /// `putAnalysis` follows: a new key or a newer reading is written, the
    /// same artifact is left as it is, another project's reading is kept
    /// aside under `conflicts/`, and the rest is skipped. Every object that
    /// matches its hash is stored, so a workspace naming a skipped artifact
    /// still opens it. Only a bundle with no readable `bundle.json` throws.
    @discardableResult
    public func importBundle(from url: URL) throws -> BundleImport {
        let entries = try BundleArchive.read(from: url)
        guard let bundleData = entries["bundle.json"],
              let bundle = try? decoder.decode(BundleInfo.self, from: bundleData) else {
            throw CodeAnalysisError.bundleInvalid("bundle.json is missing or unreadable")
        }
        guard bundle.schema == CodeAnalysisSchema.current else {
            throw CodeAnalysisError.bundleInvalid("schema \(bundle.schema) is not \(CodeAnalysisSchema.current)")
        }
        var result = BundleImport()
        for key in bundle.analyses {
            let name = key.description
            let manifestPath = "analyses/\(name)/manifest.json"
            guard let manifestData = entries[manifestPath],
                  let manifest = try? decoder.decode(AnalysisManifest.self, from: manifestData) else {
                result.skipped.append(.init(key: name, reason: "\(manifestPath) is missing or unreadable", kind: .damaged))
                continue
            }
            guard manifest.schema == CodeAnalysisSchema.current else {
                result.skipped.append(.init(key: name, reason: "schema is not \(CodeAnalysisSchema.current)", kind: .damaged))
                continue
            }
            guard manifest.key == key else {
                result.skipped.append(.init(key: name, reason: "the manifest names another analysis", kind: .damaged))
                continue
            }
            let objectPath = "objects/\(manifest.artifact.sha256.hex)"
            guard let artifact = entries[objectPath],
                  SHA256Digest(data: artifact) == manifest.artifact.sha256 else {
                result.skipped.append(.init(key: name, reason: "\(objectPath) is missing or does not match its hash", kind: .damaged))
                continue
            }
            try putObject(artifact)
            // A bundle written before documents travelled has none; the
            // analysis still imports, and `verify` names the missing document.
            if let review = manifest.reading?.review,
               let document = entries["objects/\(review.hex)"],
               SHA256Digest(data: document) == review {
                try putObject(document)
            }
            let target = manifestURL(key)
            try withLock {
                guard FileManager.default.fileExists(atPath: target.path) else {
                    try atomicWrite(manifestData, to: target)
                    result.imported.append(manifest)
                    return
                }
                let existing = try decodeManifest(at: target)
                if existing.artifact.sha256 == manifest.artifact.sha256 {
                    result.unchanged.append(existing)
                    return
                }
                switch ReadingOrder(incoming: manifest.reading, stored: existing.reading) {
                case .newer:
                    try atomicWrite(manifestData, to: target)
                    result.imported.append(manifest)
                case .notNewer:
                    result.skipped.append(.init(key: name, reason: "the store holds a later revision of this reading",
                                                      kind: .olderRevision))
                case .unreviewedOverReviewed:
                    result.skipped.append(.init(key: name, reason: "the store holds a reviewed reading", kind: .reviewedStored))
                case .unreviewed:
                    result.skipped.append(.init(key: name, reason: "the store holds another analysis", kind: .otherAnalysis))
                case .otherProject:
                    try atomicWrite(manifestData, to: conflictURL(for: manifest, key: key))
                    result.conflicts.append(.init(key: name, reason: "the store holds another project's reading",
                                                        kind: .otherProject))
                }
            }
        }
        return result
    }

    // MARK: - Files

    private struct LoadedManifest {
        let module: String
        let recipe: String
        let manifest: AnalysisManifest
    }

    private func loadedManifests() -> (loaded: [LoadedManifest], problems: [String]) {
        var loaded: [LoadedManifest] = []
        var problems: [String] = []
        for moduleFolder in contents(of: analysesURL) {
            guard isDirectory(moduleFolder) else { continue }
            for recipeFolder in contents(of: moduleFolder) {
                guard isDirectory(recipeFolder) else { continue }
                let url = recipeFolder.appendingPathComponent("manifest.json")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    let manifest = try decodeManifest(at: url)
                    loaded.append(LoadedManifest(module: moduleFolder.lastPathComponent,
                                                 recipe: recipeFolder.lastPathComponent,
                                                 manifest: manifest))
                } catch {
                    problems.append("\(moduleFolder.lastPathComponent)/"
                                    + "\(recipeFolder.lastPathComponent): \(error)")
                }
            }
        }
        return (loaded, problems)
    }

    private func decodeManifest(at url: URL) throws -> AnalysisManifest {
        do {
            return try decoder.decode(AnalysisManifest.self, from: Data(contentsOf: url))
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    private func contents(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CodeAnalysisError.io("\(url.path): \(error)")
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw CodeAnalysisError.io("cannot open \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CodeAnalysisError.io("cannot lock \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        return try body()
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }
}

/// The counts a manifest carries, read from the artifact without knowing the
/// artifact's own model. The Code panel will read the model; the store only
/// needs enough to list and to show what an analysis holds.
enum ArtifactStats {
    static func count(in data: Data) -> AnalysisStats {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AnalysisStats()
        }
        let functions = root["functions"] as? [[String: Any]] ?? []
        let instructions = functions.reduce(0) { total, function in
            total + ((function["instructions"] as? [Any])?.count ?? 0)
        }
        return AnalysisStats(
            functions: functions.count,
            instructions: instructions,
            strings: (root["strings"] as? [Any])?.count ?? 0,
            postCodeWrites: (root["post_codes"] as? [Any])?.count ?? 0,
            statusCodeCandidates: (root["status_code_calls"] as? [Any])?.count ?? 0)
    }
}
