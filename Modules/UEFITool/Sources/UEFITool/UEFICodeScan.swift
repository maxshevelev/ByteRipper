import Foundation
import CodeAnalysis
import UEFIImage

/// Marks the image nodes whose own bytes have a usable analysis in the store.
///
/// The bytes are supplied by the caller, so the scan does not know whether a
/// node is in the file or in a decompressed buffer; the session passes a
/// reader for the node's space, and a test passes the bytes directly. A body
/// whose length no analysis was made from is rejected before it is read or
/// hashed.
public enum UEFICodeScan {
    /// The paths analyses name in their `source.node`, once each.
    ///
    /// They are hints, not proof: the path is used to open the branch a module
    /// lives in, and the body's SHA-256 still decides whether the analysis is
    /// about the node now there. A path that does not parse, or the root, is
    /// left out. With `document`, only analyses made from that document are
    /// named: a path is relative to the image it was read from, and the store
    /// holds analyses of other dumps too.
    public static func sourceNodeIDs(
        in index: CodeAnalysisIndex, document: String? = nil
    ) -> [NodeID] {
        var seen = Set<NodeID>()
        var ids: [NodeID] = []
        for manifest in index.manifests {
            guard document == nil || manifest.source.document == document,
                  let text = manifest.source.node,
                  let id = NodeID(text), !id.path.isEmpty,
                  seen.insert(id).inserted
            else { continue }
            ids.append(id)
        }
        return ids
    }

    /// - Parameters:
    ///   - only: the nodes to examine; nil for every materialized node.
    ///   - bytesOf: the node's body, or nil when its space cannot be read.
    public static func scan(
        in image: UEFIImage,
        index: CodeAnalysisIndex,
        only: Set<NodeID>? = nil,
        bytesOf: @Sendable (UEFINode) -> Data?
    ) -> [NodeID: AnalysisManifest] {
        guard !index.isEmpty else { return [:] }
        let candidates = image.allNodes.filter { node in
            guard only?.contains(node.id) ?? true,
                  UEFICodeCandidates.isCandidate(node)
            else { return false }
            return index.analyzedSizes.contains(node.body.count)
        }
        var found: [NodeID: AnalysisManifest] = [:]
        for node in candidates {
            if Task.isCancelled { break }
            guard let data = bytesOf(node), data.count == node.body.count,
                  UEFICodeCandidates.isImage(data),
                  let manifest = index.newest(for: SHA256Digest(data: data))
            else { continue }
            found[node.id] = manifest
        }
        return found
    }
}
