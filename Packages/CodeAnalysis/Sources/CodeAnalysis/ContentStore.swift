import CryptoKit
import Darwin
import Foundation

/// The local content-addressed store for code artifacts.
///
/// The layout is the one `Skills/ghidra-uefi/reference/cas.md` describes:
/// immutable objects under `objects/<sha256>`, a manifest for each analysis
/// under `analyses/<module-sha>/<recipe>/manifest.json`, and named references
/// under `refs/`. The directory is the index; a reader walks it, and the
/// Python collector and a Swift reader agree on the bytes.
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

    public func refURL(_ name: String) throws -> URL {
        guard SafeName.isSafe(name) else { throw CodeAnalysisError.invalidName(name) }
        return refsURL.appendingPathComponent("\(name).json", isDirectory: false)
    }

    // MARK: - Objects

    public func hasObject(_ digest: SHA256Digest) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(digest).path)
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

    // MARK: - Analyses

    @discardableResult
    public func putAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe,
                            artifact: Data, source: SourceIdentity = SourceIdentity(),
                            replace: Bool = false) throws -> AnalysisManifest {
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
            stats: ArtifactStats.count(in: artifact))
        let url = manifestURL(manifest.key!)
        return try withLock {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try decodeManifest(at: url)
                if existing.artifact.sha256 == digest {
                    return existing
                }
                if !replace {
                    throw CodeAnalysisError.analysisMismatch(
                        "\(manifest.key!) already exists with another artifact; pass replace")
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

    public func key(of manifest: AnalysisManifest) -> AnalysisKey? { manifest.key }

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
        let keepObjects = Set(keep.map(\.artifact.sha256))
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
        }
        try BundleArchive.write(entries: entries, to: url)
        return info
    }

    /// Read a bundle, verify every object and store what is not already here.
    /// An analysis already present with another artifact is refused.
    @discardableResult
    public func importBundle(from url: URL) throws -> [AnalysisManifest] {
        let entries = try BundleArchive.read(from: url)
        guard let bundleData = entries["bundle.json"],
              let bundle = try? decoder.decode(BundleInfo.self, from: bundleData) else {
            throw CodeAnalysisError.bundleInvalid("bundle.json is missing or unreadable")
        }
        guard bundle.schema == CodeAnalysisSchema.current else {
            throw CodeAnalysisError.bundleInvalid("schema \(bundle.schema) is not \(CodeAnalysisSchema.current)")
        }
        var imported: [AnalysisManifest] = []
        for key in bundle.analyses {
            let manifestPath = "analyses/\(key.description)/manifest.json"
            guard let manifestData = entries[manifestPath],
                  let manifest = try? decoder.decode(AnalysisManifest.self, from: manifestData) else {
                throw CodeAnalysisError.bundleInvalid("\(manifestPath) is missing or unreadable")
            }
            guard manifest.schema == CodeAnalysisSchema.current else {
                throw CodeAnalysisError.bundleInvalid("\(key.description): schema is not \(CodeAnalysisSchema.current)")
            }
            guard manifest.key == key else {
                throw CodeAnalysisError.bundleInvalid("\(key.description): manifest names another analysis")
            }
            let objectPath = "objects/\(manifest.artifact.sha256.hex)"
            guard let artifact = entries[objectPath] else {
                throw CodeAnalysisError.bundleInvalid("\(objectPath) is missing")
            }
            guard SHA256Digest(data: artifact) == manifest.artifact.sha256 else {
                throw CodeAnalysisError.bundleInvalid("\(objectPath) does not match its hash")
            }
            try putObject(artifact)
            let target = manifestURL(key)
            if FileManager.default.fileExists(atPath: target.path) {
                let existing = try decodeManifest(at: target)
                if existing.artifact.sha256 != manifest.artifact.sha256 {
                    throw CodeAnalysisError.analysisMismatch(
                        "\(key.description) is already present with another artifact")
                }
                imported.append(existing)
                continue
            }
            try atomicWrite(manifestData, to: target)
            imported.append(manifest)
        }
        return imported
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
