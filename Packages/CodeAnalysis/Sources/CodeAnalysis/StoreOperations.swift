import Foundation

/// The store's operations as `byteripper-cas` runs them, on a directory or on
/// a served store. The command line parses an argument once and calls this,
/// so `--server` changes where a command runs, not what it means.
protocol StoreOperations {
    func hello() throws -> [String: Any]
    func putObject(_ data: Data) throws -> SHA256Digest
    func hasObject(_ digest: SHA256Digest) throws -> Bool
    func object(_ digest: SHA256Digest) throws -> Data
    func putAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data,
                     source: SourceIdentity, reading: AnalysisReading?, replace: Bool,
                     discardReading: Bool) throws -> AnalysisManifest
    func analysis(module: SHA256Digest, recipe: String?) throws -> AnalysisManifest?
    func recipes(ofModule module: SHA256Digest) throws -> [String]
    func analyses() throws -> [AnalysisManifest]
    func conflicts() throws -> [AnalysisManifest]
    func recordRevision(module: SHA256Digest, reading: AnalysisReading, by: String?) throws -> ReviewHistory
    func reviewHistory(module: SHA256Digest) throws -> ReviewHistory?
    func setRef(_ name: String, analyses: [AnalysisKey]) throws -> AnalysisRef
    func refs() throws -> [AnalysisRef]
    func removeRef(_ name: String) throws -> Bool
    func verify() throws -> [String]
    func collectGarbage(dryRun: Bool, deleteUnreferencedAnalyses: Bool) throws -> GarbageReport
    func exportBundle(_ keys: [AnalysisKey], to url: URL) throws -> BundleInfo
    func importBundle(from url: URL) throws -> BundleImport
}

/// A store on a directory this machine can open.
struct LocalOperations: StoreOperations {
    let root: URL
    let create: Bool

    private func store() throws -> ContentStore { try ContentStore(root: root, create: create) }

    func hello() throws -> [String: Any] {
        ["protocol": CASCommand.protocolVersion, "schema": CodeAnalysisSchema.current,
         "store": root.standardizedFileURL.path]
    }
    func putObject(_ data: Data) throws -> SHA256Digest { try store().putObject(data) }
    func hasObject(_ digest: SHA256Digest) throws -> Bool { try store().hasObject(digest) }
    func object(_ digest: SHA256Digest) throws -> Data { try store().object(digest) }
    func putAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data,
                     source: SourceIdentity, reading: AnalysisReading?, replace: Bool,
                     discardReading: Bool) throws -> AnalysisManifest {
        try store().putAnalysis(module: module, recipe: recipe, artifact: artifact, source: source,
                                reading: reading, replace: replace, discardReading: discardReading)
    }
    func analysis(module: SHA256Digest, recipe: String?) throws -> AnalysisManifest? {
        let store = try store()
        return try recipe.map { try store.analysis(module: module, recipe: $0) } ?? store.analysis(module: module)
    }
    func recipes(ofModule module: SHA256Digest) throws -> [String] { try store().recipes(ofModule: module) }
    func analyses() throws -> [AnalysisManifest] { try store().analyses() }
    func conflicts() throws -> [AnalysisManifest] { try store().conflicts() }
    func recordRevision(module: SHA256Digest, reading: AnalysisReading, by: String?) throws -> ReviewHistory {
        try store().recordRevision(module: module, reading: reading, by: by)
    }
    func reviewHistory(module: SHA256Digest) throws -> ReviewHistory? { try store().reviewHistory(module: module) }
    func setRef(_ name: String, analyses: [AnalysisKey]) throws -> AnalysisRef {
        try store().setRef(name, analyses: analyses)
    }
    func refs() throws -> [AnalysisRef] { try store().refs() }
    func removeRef(_ name: String) throws -> Bool { try store().removeRef(name) }
    func verify() throws -> [String] { try store().verify() }
    func collectGarbage(dryRun: Bool, deleteUnreferencedAnalyses: Bool) throws -> GarbageReport {
        try store().collectGarbage(dryRun: dryRun, deleteUnreferencedAnalyses: deleteUnreferencedAnalyses)
    }
    func exportBundle(_ keys: [AnalysisKey], to url: URL) throws -> BundleInfo {
        try store().exportBundle(keys, to: url)
    }
    func importBundle(from url: URL) throws -> BundleImport { try store().importBundle(from: url) }
}

/// A served store (`byteripper-server`), through `RemoteStore`.
struct RemoteOperations: StoreOperations {
    let remote: RemoteStore

    /// The command line is synchronous; each call waits for its answer.
    private func wait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        try RemoteStore.blocking(body)
    }

    func hello() throws -> [String: Any] {
        let remote = self.remote
        let hello = try wait { try await remote.hello() }
        return ["protocol": CASCommand.protocolVersion, "schema": CodeAnalysisSchema.current,
                "server": remote.base.absoluteString, "store": hello.store]
    }
    func putObject(_ data: Data) throws -> SHA256Digest {
        let remote = self.remote
        return try wait { try await remote.putObject(data) }
    }
    func hasObject(_ digest: SHA256Digest) throws -> Bool {
        let remote = self.remote
        return try wait { try await remote.hasObject(digest) }
    }
    func object(_ digest: SHA256Digest) throws -> Data {
        let remote = self.remote
        return try wait { try await remote.object(digest) }
    }
    func putAnalysis(module: ModuleIdentity, recipe: AnalysisRecipe, artifact: Data,
                     source: SourceIdentity, reading: AnalysisReading?, replace: Bool,
                     discardReading: Bool) throws -> AnalysisManifest {
        let remote = self.remote
        return try wait {
            try await remote.putAnalysis(module: module, recipe: recipe, artifact: artifact, source: source,
                                         reading: reading, replace: replace, discardReading: discardReading)
        }
    }
    func analysis(module: SHA256Digest, recipe: String?) throws -> AnalysisManifest? {
        let remote = self.remote
        let manifests = try wait { try await remote.module(module) }.manifests
        if let recipe { return manifests.first { $0.recipe.id == recipe } }
        return manifests.max(by: ContentStore.olderThan)
    }
    func recipes(ofModule module: SHA256Digest) throws -> [String] {
        let remote = self.remote
        return try wait { try await remote.module(module) }.manifests.map(\.recipe.id).sorted()
    }
    func analyses() throws -> [AnalysisManifest] {
        let remote = self.remote
        return try wait { try await remote.modules() }.flatMap(\.manifests).sorted {
            if $0.module.sha256 == $1.module.sha256 { return $0.recipe.id < $1.recipe.id }
            return $0.module.sha256 < $1.module.sha256
        }
    }
    func conflicts() throws -> [AnalysisManifest] {
        let remote = self.remote
        return try wait { try await remote.conflicts() }
    }
    func recordRevision(module: SHA256Digest, reading: AnalysisReading, by: String?) throws -> ReviewHistory {
        let remote = self.remote
        return try wait { try await remote.recordRevision(module: module, reading: reading, by: by) }
    }
    func reviewHistory(module: SHA256Digest) throws -> ReviewHistory? {
        let remote = self.remote
        return try wait { try await remote.reviewHistory(module: module) }
    }
    func setRef(_ name: String, analyses: [AnalysisKey]) throws -> AnalysisRef {
        let remote = self.remote
        return try wait { try await remote.setRef(name, analyses: analyses) }
    }
    func refs() throws -> [AnalysisRef] {
        let remote = self.remote
        return try wait { try await remote.refs() }
    }
    func removeRef(_ name: String) throws -> Bool {
        let remote = self.remote
        do {
            try wait { try await remote.removeRef(name) }
            return true
        } catch RemoteStore.Failure.refused(status: 404, _) {
            return false
        }
    }
    func verify() throws -> [String] {
        let remote = self.remote
        return try wait { try await remote.verify() }
    }
    func collectGarbage(dryRun: Bool, deleteUnreferencedAnalyses: Bool) throws -> GarbageReport {
        throw CodeAnalysisError.analysisMismatch(
            "a served store is collected on the server: run byteripper-cas gc there")
    }
    func exportBundle(_ keys: [AnalysisKey], to url: URL) throws -> BundleInfo {
        let remote = self.remote
        let data = try wait { try await remote.exportBundle(keys) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CodeAnalysisError.io("\(url.path): cannot be written")
        }
        guard let info = try BundleArchive.read(from: url)["bundle.json"]
            .flatMap({ try? JSONDecoder().decode(BundleInfo.self, from: $0) }) else {
            throw CodeAnalysisError.bundleInvalid("the server's bundle has no readable bundle.json")
        }
        return info
    }
    func importBundle(from url: URL) throws -> BundleImport {
        let remote = self.remote
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodeAnalysisError.io("\(url.path): cannot be read")
        }
        return try wait { try await remote.importBundle(data) }
    }
}
