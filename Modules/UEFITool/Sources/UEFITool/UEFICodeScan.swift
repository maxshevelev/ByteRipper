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
    /// - Parameters:
    ///   - only: the nodes to examine; nil for every materialized node.
    ///   - bytesOf: the node's body, or nil when its space cannot be read.
    public static func scan(
        in image: UEFIImage,
        index: CodeAnalysisIndex,
        only: Set<NodeID>? = nil,
        bytesOf: @Sendable (UEFINode) -> Data?
    ) -> Set<NodeID> {
        guard !index.isEmpty else { return [] }
        let candidates = image.allNodes.filter { node in
            guard only?.contains(node.id) ?? true,
                  UEFICodeCandidates.isCandidate(node)
            else { return false }
            return index.analyzedSizes.contains(node.body.count)
        }
        var found: Set<NodeID> = []
        for node in candidates {
            if Task.isCancelled { break }
            guard let data = bytesOf(node), data.count == node.body.count,
                  UEFICodeCandidates.isImage(data)
            else { continue }
            if index.hasUsableAnalysis(for: SHA256Digest(data: data)) {
                found.insert(node.id)
            }
        }
        return found
    }
}
