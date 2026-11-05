import Foundation

/// Where the app and the Ghidra skill keep code analyses. The skill's own
/// default is the same path, so an analysis written there is found here without
/// configuration.
public enum CodeAnalysisPaths {
    /// Posted on the main queue when the app reads its analyses from another
    /// directory — the local store, or a served store's mirror — so whatever
    /// follows the store follows the new one.
    public static let rootDidChange = Notification.Name("CodeAnalysisRootDidChange")

    /// Where the mirrors of served stores are kept, one folder per store.
    public static var mirrorsRoot: URL {
        defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("Analysis Mirrors", isDirectory: true)
    }

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("ByteRipper", isDirectory: true)
            .appendingPathComponent("Analysis", isDirectory: true)
    }
}

/// The usable analyses in a store, arranged by module, for a panel that asks
/// "does this node's body have one?" without reading the artifact.
///
/// A value, not a live view: load it off the main actor, compare it with the
/// one already in hand, and replace it when it changed. The `sizes` set is the
/// prefilter: a module whose body length is not one of these cannot match, so
/// the caller does not read or hash it.
public struct CodeAnalysisIndex: Equatable, Sendable {
    /// Every usable manifest, module by module, recipe by recipe.
    public let manifests: [AnalysisManifest]
    /// The body lengths some analysis was made from.
    public let analyzedSizes: Set<Int>

    private let byModule: [SHA256Digest: [AnalysisManifest]]

    public init(manifests: [AnalysisManifest]) {
        self.manifests = manifests
        byModule = Dictionary(grouping: manifests, by: \.module.sha256)
        analyzedSizes = Set(manifests.map(\.module.size))
    }

    public static let empty = CodeAnalysisIndex(manifests: [])

    /// Read the store's manifests and keep the usable ones. A missing store is
    /// not an error: it is an image nobody has analyzed yet.
    public static func load(from root: URL) -> CodeAnalysisIndex {
        guard let store = try? ContentStore(root: root, create: false) else {
            return .empty
        }
        return CodeAnalysisIndex(manifests: store.usableAnalyses())
    }

    public var isEmpty: Bool { manifests.isEmpty }

    public func hasUsableAnalysis(for module: SHA256Digest) -> Bool {
        !(byModule[module]?.isEmpty ?? true)
    }

    /// A module's analyses a reader may be shown. A review from a project since
    /// replaced by a fresh one is no longer among them: it stays in the store,
    /// and has no value to a reader.
    public func manifests(for module: SHA256Digest) -> [AnalysisManifest] {
        let all = byModule[module] ?? []
        guard let project = Self.newest(of: all)?.reading?.project else { return all }
        return all.filter { $0.reading.map { $0.project == project } ?? true }
    }

    /// The newest readable analysis of a module: what `Open with Code` will
    /// take before the panel offers the others.
    public func newest(for module: SHA256Digest) -> AnalysisManifest? {
        manifests(for: module).max { left, right in
            if left.analyzedAt == right.analyzedAt {
                return left.recipe.id < right.recipe.id
            }
            return left.analyzedAt < right.analyzedAt
        }
    }

    /// The analysis that carries a manifest's reading now: itself, or the
    /// same project's later revision under another recipe of the module. A
    /// publish through a newer exporter stores the next revision beside the
    /// old recipe, which keeps the revision it had; a screen that followed
    /// only its recipe would stay there.
    private static func newest(of manifests: [AnalysisManifest]) -> AnalysisManifest? {
        manifests.max(by: ContentStore.olderThan)
    }

    public func latestReading(of manifest: AnalysisManifest) -> AnalysisManifest {
        guard let reading = manifest.reading else { return manifest }
        // A project made afresh replaced the one this reading came from.
        if let newest = Self.newest(of: byModule[manifest.module.sha256] ?? []), let current = newest.reading,
           current.project != reading.project {
            return latestReading(of: newest)
        }
        let later = manifests(for: manifest.module.sha256).filter {
            guard let other = $0.reading else { return false }
            return other.project == reading.project && other.rev > reading.rev
        }
        return later.max { left, right in
            if left.reading!.rev == right.reading!.rev {
                return ContentStore.olderThan(left, right)
            }
            return left.reading!.rev < right.reading!.rev
        } ?? manifest
    }
}
