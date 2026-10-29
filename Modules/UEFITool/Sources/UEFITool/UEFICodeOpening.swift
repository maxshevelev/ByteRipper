import CodeAnalysis
import Foundation
import Localization
import UEFIImage

/// Everything a Code panel is opened with, read and checked: the module's
/// bytes, the analysis that matches them, its artifact, and where the part
/// links back to in the dump.
///
/// One way to it for every route: **Open with Code** in the tree, an agent's
/// `open_code`, a double-click on an annotation on code. None of them needs
/// the UEFI panel to have scanned the tree first — the node's bytes are
/// hashed here, and the store says which analysis they have.
///
/// In the pure target, because an agent's `code_query` by a node reads the
/// same thing with no panel at all — in the app and in `byteripper-server`
/// (`Packages/AgentDocuments`). The codec a panel is opened with is the UI
/// target's (`UEFICodeOpening+Codec.swift`).
public struct UEFICodeOpening: Sendable {
    public let partName: String
    public let source: Range<UInt64>
    public let bytes: [UInt8]
    public let manifest: AnalysisManifest
    public let artifact: CodeArtifact
    /// Every readable analysis of the module, for the panel's dropdown.
    public let recipes: [AnalysisManifest]

    /// What stopped an opening, in the words the panel shows.
    public enum Failure: Error, Equatable, Sendable {
        case noAnalysis
        case unreadableBytes
        case changed
        case unreadableAnalysis

        /// Put into words by whoever shows it: the panel in the app's
        /// language (`message`, the UI target's).
        public var text: LocalizedText {
            switch self {
            case .noAnalysis: L("There is no code analysis to open here.")
            case .unreadableBytes: L("Those bytes could not be read.")
            case .changed: L("The module changed after this analysis.")
            case .unreadableAnalysis: L("The code analysis could not be read.")
            }
        }
    }

    /// Reads node `id`'s module and the analysis stored for it.
    ///
    /// - Parameter preferred: the analysis to open when it still matches the
    ///   bytes — the one the tree's badge was drawn from — at its recipe's
    ///   latest revision; otherwise the newest the store has for them.
    @MainActor
    public static func prepare(node id: NodeID, in tree: LazyUEFITree, store root: URL?,
                               preferred: AnalysisManifest? = nil) async throws -> UEFICodeOpening {
        let image = tree.image()
        guard let root, let node = image.node(id), UEFICodeCandidates.isCandidate(node),
              let open = UEFIPresenter.nodeOpen(for: node, in: image, body: true)
        else { throw Failure.noAnalysis }
        let readers = tree.spaceReaders
        let space = node.space
        let body = node.body
        let bytes = await Task.detached(priority: .userInitiated) {
            readers.reader(for: space)?.bytes(body)
        }.value
        guard let bytes, !bytes.isEmpty else { throw Failure.unreadableBytes }
        let loaded = await Task.detached(priority: .userInitiated)
        { () -> (manifest: AnalysisManifest, artifact: CodeArtifact?, recipes: [AnalysisManifest])? in
            let digest = SHA256Digest(data: Data(bytes))
            let index = CodeAnalysisIndex.load(from: root)
            let manifest = preferred.flatMap { preferred in
                // The preferred analysis as the store has it now: the tree
                // drew its badge from a revision a publish has since replaced.
                index.manifests(for: digest).first { $0.recipe.id == preferred.recipe.id }
            } ?? index.newest(for: digest)
            guard let manifest else { return nil }
            let artifact = try? ContentStore(root: root, create: false).artifact(for: manifest)
            return (manifest, artifact, index.manifests(for: digest))
        }.value
        guard let loaded else {
            throw preferred == nil ? Failure.noAnalysis : Failure.changed
        }
        guard let artifact = loaded.artifact else { throw Failure.unreadableAnalysis }
        return UEFICodeOpening(partName: UEFIPresenter.codePartName(of: id, in: image, bytes: bytes) ?? open.partName,
                               source: open.source, bytes: bytes,
                               manifest: loaded.manifest, artifact: artifact,
                               recipes: loaded.recipes)
    }
}
