import CodeAnalysis
import Foundation
import Localization
import UEFIToolUI

/// The app's way to the analysis store, for the places that load an artifact
/// after the panel is already open: a recipe chosen in the header, a Code
/// screen restored from a workspace. The tool-module chooses the opening
/// recipe; this only reads what the manifest names.
enum CodeAnalysisStore {
    static var root: URL {
        UEFIToolModule.codeAnalysisRoot ?? CodeAnalysisPaths.defaultRoot
    }

    /// The artifact a manifest names, decoded off the main actor.
    static func artifact(for manifest: AnalysisManifest, root: URL? = nil) async -> CodeArtifact? {
        let root = root ?? self.root
        return await Task.detached(priority: .userInitiated) { () -> CodeArtifact? in
            try? ContentStore(root: root, create: false).artifact(for: manifest)
        }.value
    }

    /// The analyses a project carries, beside its `Project.json`.
    static func bundleURL(in project: URL) -> URL {
        project.appendingPathComponent("Analyses.bundle")
    }

    /// A stable reference for a project's analyses in the store. A project
    /// keeps its own bundle; the reference is what keeps the store from
    /// collecting the objects the bundle was made from.
    static func projectRefName(for project: URL) -> String {
        "project-" + SHA256Digest(data: Data(project.standardizedFileURL.path.utf8)).hex
    }

    /// Bring a project's bundle into the local store before its Code screens
    /// are restored. Missing or unreadable bundles are not an error: the
    /// project still opens, and a Code screen that cannot find its artifact
    /// says so. The import's report is returned for the window to tell what
    /// the project will not show as it was saved (`noticeLines(for:)`).
    @discardableResult
    static func importProjectBundle(at project: URL, root: URL? = nil) -> BundleImport? {
        let url = bundleURL(in: project)
        guard FileManager.default.fileExists(atPath: url.path),
              let store = try? ContentStore(root: root ?? self.root) else { return nil }
        return try? store.importBundle(from: url)
    }

    /// What a notice says about a bundle import, or nothing when every
    /// analysis is shown as the project has it — or is superseded by a later
    /// reading, which is the same work further on.
    static func noticeLines(for result: BundleImport) -> [String]? {
        let kept = result.conflicts.count
        let other = result.skipped.filter { $0.kind == .otherAnalysis }.count
        let damaged = result.skipped.filter { $0.kind == .damaged }.count
        guard kept + other + damaged > 0 else { return nil }
        var lines = [L("Not every code analysis of the project is shown as it was saved")]
        if kept > 0 {
            lines.append(L("Another project's analysis is shown instead: %1$@", String(kept)))
        }
        if other > 0 {
            lines.append(L("A different stored analysis is shown instead: %1$@", String(other)))
        }
        if damaged > 0 {
            lines.append(L("Damaged in the project and not read: %1$@", String(damaged)))
        }
        return lines
    }
}
