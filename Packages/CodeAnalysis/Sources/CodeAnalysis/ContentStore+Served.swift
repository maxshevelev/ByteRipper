import Foundation

/// What a served store (`CASService`) and a mirror of it (`StoreMirror`) need
/// of the store beyond its rules: a name that says which store a mirror
/// copies, a way to copy decisions the server already made, and a fingerprint
/// that says which modules changed.
extension ContentStore {
    private var identityURL: URL { root.appendingPathComponent("store.json") }

    private struct Identity: Codable {
        var schema = 1
        var id: String
    }

    /// The store's own UUID, minted the first time it is asked for. A mirror
    /// keeps a directory per served store, so a server whose store was
    /// replaced is never mistaken for the one it was.
    public func identity() throws -> String {
        if let data = try? Data(contentsOf: identityURL),
           let identity = try? decoder.decode(Identity.self, from: data) {
            return identity.id
        }
        return try withLock {
            if let data = try? Data(contentsOf: identityURL),
               let identity = try? decoder.decode(Identity.self, from: data) {
                return identity.id
            }
            let identity = Identity(id: UUID().uuidString.lowercased())
            try atomicWrite(try encoder.encode(identity), to: identityURL)
            return identity.id
        }
    }

    // MARK: - Mirroring

    /// Make a module's analyses and history exactly what the served store
    /// holds: its manifests are written as they are, without the reading table
    /// — the server already applied it — and a recipe the server no longer has
    /// is removed. Objects are not copied; the mirror fetches them on read.
    public func mirror(_ module: ServedModule) throws {
        for manifest in module.manifests {
            guard manifest.module.sha256 == module.module, manifest.key != nil else {
                throw CodeAnalysisError.analysisMismatch(
                    "a manifest of \(manifest.module.sha256.hex) is not one of \(module.module.hex)")
            }
        }
        try withLock {
            let served = Set(module.manifests.compactMap(\.key?.recipe))
            for recipe in recipes(ofModule: module.module) where !served.contains(recipe) {
                try? FileManager.default.removeItem(
                    at: manifestURL(AnalysisKey(module: module.module, recipe: recipe)!)
                        .deletingLastPathComponent())
            }
            for manifest in module.manifests {
                let url = manifestURL(manifest.key!)
                let data = try encoder.encode(manifest)
                // An unchanged manifest is not written again: a write is an
                // FSEvents change, and the app reloads on it.
                if (try? Data(contentsOf: url)) != data {
                    try atomicWrite(data, to: url)
                }
            }
            let historyURL = reviewHistoryURL(module.module)
            if let history = module.history {
                let data = try encoder.encode(history)
                if (try? Data(contentsOf: historyURL)) != data {
                    try atomicWrite(data, to: historyURL)
                }
            } else {
                try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent())
            }
            let folder = analysesURL.appendingPathComponent(module.module.hex, isDirectory: true)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// The modules this store holds analyses or a history of.
    public func modules() -> Set<SHA256Digest> {
        Set((contents(of: analysesURL) + contents(of: reviewsURL))
            .filter(isDirectory)
            .compactMap { SHA256Digest(hex: $0.lastPathComponent) })
    }

    /// What the store holds of one module, as a served store answers it.
    public func served(_ module: SHA256Digest) -> ServedModule {
        let manifests = recipes(ofModule: module).compactMap {
            try? analysis(module: module, recipe: $0)
        }
        return ServedModule(module: module, manifests: manifests,
                            history: try? reviewHistory(module: module))
    }

    /// A hash of what the store holds of each module: the same exactly when
    /// nothing a reader sees has changed.
    public func fingerprints() -> [SHA256Digest: SHA256Digest] {
        var result: [SHA256Digest: SHA256Digest] = [:]
        for module in modules() {
            if let data = try? encoder.encode(served(module)) {
                result[module] = SHA256Digest(data: data)
            }
        }
        return result
    }
}

/// One module as a served store answers it: every recipe's manifest and the
/// history of its readings.
public struct ServedModule: Codable, Equatable, Sendable {
    public var module: SHA256Digest
    public var manifests: [AnalysisManifest]
    public var history: ReviewHistory?

    public init(module: SHA256Digest, manifests: [AnalysisManifest], history: ReviewHistory?) {
        self.module = module
        self.manifests = manifests
        self.history = history
    }
}
