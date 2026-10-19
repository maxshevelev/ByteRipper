import Foundation
import Workspace

/// A pane's segments as the workspace writes them (`Design/WORKSPACE_PLAN.md`):
/// the pieces by offset, and each link by the path of its source rather than
/// by the id this run minted for it.
extension PaneViewModel {
    /// The partition, or nil when the file is one piece of itself — nothing
    /// worth writing down.
    func workspaceSegments() -> SegmentationState? {
        let current = segmentStore.current
        if current.pieces.count == 1, current.pieces[0].link == nil,
           current.pieces[0].name.isEmpty || current.pieces[0].name == document?.url.lastPathComponent {
            return nil
        }
        return SegmentationState(
            contentSize: current.contentSize,
            pieces: current.pieces.map { piece in
                PieceState(start: piece.start, name: piece.name, link: piece.link.flatMap { link in
                    segmentSources.source(link.source).map { source in
                        PieceLinkState(path: source.url.standardizedFileURL.path,
                                       sourceStart: link.sourceRange.lowerBound,
                                       sourceEnd: link.sourceRange.upperBound)
                    }
                })
            })
    }

    /// Puts a written partition back, re-minting each source's id from its
    /// path. Not an undo step: the session that made the cuts is over, and
    /// undo here would take the pane to a partition it never had.
    func restoreSegments(_ state: SegmentationState) {
        let pieces = state.pieces.map { piece in
            Piece(start: piece.start, name: piece.name, link: piece.link.map { link in
                SegmentLink(source: segmentSources.id(for: URL(fileURLWithPath: link.path)),
                            sourceRange: link.sourceStart..<max(link.sourceStart, link.sourceEnd))
            })
        }
        segmentStore.restore(Segmentation(contentSize: state.contentSize, pieces: pieces))
        refreshSourceWatchers()
    }
}
