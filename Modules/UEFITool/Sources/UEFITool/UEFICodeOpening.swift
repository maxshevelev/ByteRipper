import CodeAnalysis
import Foundation
import Localization
import ToolModuleKit
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
    /// The dependency expression of the FFS file holding the image, for the
    /// panel's Interfaces tab: every route to a Code panel shows it, not only
    /// the tree's. Nil where the image sits in no file.
    public let dependencies: DependencyOutline?

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
    /// - Parameter index: the store's index the tree already read: given, the
    ///   store's manifests are not read again, only the artifact.
    @MainActor
    public static func prepare(node id: NodeID, in tree: LazyUEFITree, store root: URL?,
                               preferred: AnalysisManifest? = nil,
                               index known: CodeAnalysisIndex? = nil,
                               names: GuidsCatalogue = .empty) async throws -> UEFICodeOpening {
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
            let index = known ?? CodeAnalysisIndex.load(from: root)
            let manifest = preferred.flatMap { preferred in
                // The preferred analysis as the store has it now: the tree
                // drew its badge from a revision a publish has since replaced.
                index.manifests(for: digest).first { $0.recipe.id == preferred.recipe.id }
            } ?? index.newest(for: digest)
            guard let manifest else { return nil }
            let artifact = try? ContentStore(root: root, create: false).artifactToShow(for: manifest)
            return (manifest, artifact, index.manifests(for: digest))
        }.value
        guard let loaded else {
            throw preferred == nil ? Failure.noAnalysis : Failure.changed
        }
        guard let artifact = loaded.artifact else { throw Failure.unreadableAnalysis }
        return UEFICodeOpening(partName: UEFIPresenter.codePartName(of: id, in: image, bytes: bytes) ?? open.partName,
                               source: open.source, bytes: bytes,
                               manifest: loaded.manifest, artifact: artifact,
                               recipes: loaded.recipes,
                               dependencies: dependencyOutline(ofModule: id, in: tree, names: names))
    }

    /// The dependency expression of the FFS file holding image `nodeID`, with
    /// the GUIDs named; `.none` where the file has none, nil where the image
    /// sits in no file.
    @MainActor
    public static func dependencyOutline(ofModule nodeID: NodeID, in tree: LazyUEFITree,
                                         names: GuidsCatalogue) -> DependencyOutline? {
        let image = tree.image()
        guard let file = UEFITreeMarks.moduleFile(of: nodeID, in: image), let node = image.node(file) else { return nil }
        guard let section = UEFIAgentQueries.dependencySection(of: node), let type = section.subtype,
              let kind = DependencyExpression.Kind(sectionType: type),
              let reader = tree.spaceReaders.reader(for: section.space),
              let bytes = reader.bytes(section.body) else { return DependencyOutline.none }
        return outline(of: DependencyExpression(kind: kind, bytes: bytes), names: names)
    }

    /// The expression for the code panel: each GUID with its name, a choice
    /// as a group of its own.
    public static func outline(of expression: DependencyExpression, names: GuidsCatalogue) -> DependencyOutline {
        func convert(_ condition: DependencyExpression.Condition) -> DependencyOutline.Condition {
            switch condition {
            case .guid(let guid): .interface(guid: guid.description, name: names.name(of: guid))
            case .not(let operand): .not(convert(operand))
            case .allOf(let list): .allOf(list.map(convert))
            case .anyOf(let list): .anyOf(list.map(convert))
            case .always: .always
            case .never: .never
            }
        }
        guard let conditions = expression.conditions, !expression.isMalformed else {
            return DependencyOutline(conditions: [], prefix: expression.dispatchPrefix?.name, unreadable: true)
        }
        return DependencyOutline(conditions: conditions.map(convert), prefix: expression.dispatchPrefix?.name)
    }

    /// The image node in `tree` whose bytes are the module `manifest` was
    /// made from: the node the analysis names first, when this is its file,
    /// then every node the tree has open, then — the last resort — the tree
    /// with every compressed section opened. How a Code panel that did not
    /// come from the tree — one a session brings back — finds its file.
    @MainActor
    public static func imageNode(of manifest: AnalysisManifest, in tree: LazyUEFITree,
                                 fileName: String) async -> NodeID? {
        let index = CodeAnalysisIndex(manifests: [manifest])
        for id in UEFICodeScan.sourceNodeIDs(in: index, document: fileName) {
            _ = await UEFIAgentQueries.reachable(id, in: tree)
        }
        for pass in 0..<2 {
            if pass == 1 { await UEFIContentSearch.openEverything(under: nil, in: tree) }
            let image = tree.image()
            let readers = tree.spaceReaders
            let found = await Task.detached(priority: .userInitiated) {
                UEFICodeScan.scan(in: image, index: index) { node in
                    guard let reader = readers.reader(for: node.space), let bytes = reader.bytes(node.body)
                    else { return nil }
                    return Data(bytes)
                }
            }.value
            if let id = found.keys.min(by: { $0.path.lexicographicallyPrecedes($1.path) }) { return id }
        }
        return nil
    }
}
