import CodeAnalysis
import CodeView
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

    /// A revision of a module, as the code panel's picker offers it: the row
    /// to show, and the code to load when it is chosen — nil when the store
    /// holds no code for it, a history written before revisions kept theirs.
    struct RevisionOption {
        let choice: CodePaneView.RevisionChoice
        let artifact: SHA256Digest
    }

    /// The module's revisions the store holds the code of, newest first and
    /// without the one on screen, and whether the module has any history at
    /// all — so the bar can stand where the reader expects it while nothing
    /// is comparable yet. A revision recorded before revisions kept their
    /// code names none and is left out, not listed greyed.
    static func revisions(for manifest: AnalysisManifest, root: URL? = nil)
        async -> (options: [RevisionOption], hasHistory: Bool) {
        let root = root ?? self.root
        let module = manifest.module.sha256
        let current = manifest.reading?.rev
        let project = manifest.reading?.project
        return await Task.detached(priority: .userInitiated) { () -> (options: [RevisionOption], hasHistory: Bool) in
            guard let store = try? ContentStore(root: root, create: false),
                  let history = try? store.reviewHistory(module: module) else { return ([], false) }
            let options = Self.revisionOptions(history, current: current, project: project)
            return (options, !history.revisions.isEmpty)
        }.value
    }

    private nonisolated static func revisionOptions(_ history: ReviewHistory, current: Int?,
                                                    project: String?) -> [RevisionOption] {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        let iso = ISO8601DateFormatter()
        let ordered = history.revisions.sorted { left, right in
            left.rev == right.rev ? left.recordedAt > right.recordedAt : left.rev > right.rev
        }
        var options: [RevisionOption] = []
        for revision in ordered {
            guard revision.rev != current, let artifact = revision.artifact else { continue }
            var title = "r\(revision.rev)"
            if let date = iso.date(from: revision.recordedAt) {
                title += " — " + formatter.string(from: date)
            }
            if let by = revision.by, !by.isEmpty {
                title += ", " + by
            } else if revision.project != project {
                title += ", " + revision.project
            }
            options.append(RevisionOption(
                choice: CodePaneView.RevisionChoice(revision: revision.rev, title: title, hasCode: true),
                artifact: artifact))
        }
        return options
    }

    /// A revision's code, read off the main actor; nil when the store cannot
    /// give it.
    static func artifact(forRevision digest: SHA256Digest, root: URL? = nil) async -> CodeArtifact? {
        let root = root ?? self.root
        return await Task.detached(priority: .userInitiated) { () -> CodeArtifact? in
            guard let store = try? ContentStore(root: root, create: false),
                  let data = try? store.object(digest) else { return nil }
            return try? JSONDecoder().decode(CodeArtifact.self, from: data)
        }.value
    }

    /// The module description a manifest's reading names, read off the main
    /// actor; nil when it has none or the store cannot give it.
    static func moduleDescription(for manifest: AnalysisManifest, root: URL? = nil) async -> String? {
        let root = root ?? self.root
        return await Task.detached(priority: .userInitiated) { () -> String? in
            (try? ContentStore(root: root, create: false).moduleDescription(for: manifest)) ?? nil
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

extension CodePaneView {
    /// Reads the description the pane's reading names and shows it: after
    /// the pane is drawn, so the code never waits for the store.
    func loadModuleDescription() {
        let manifest = self.manifest
        Task { @MainActor [weak self] in
            let text = await CodeAnalysisStore.moduleDescription(for: manifest)
            self?.setModuleDescription(text)
        }
    }
}
