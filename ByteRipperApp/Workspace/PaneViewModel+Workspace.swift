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
        return workspaceState(of: current)
    }

    /// A partition as the workspace writes it, links by path.
    func workspaceState(of segmentation: Segmentation) -> SegmentationState {
        SegmentationState(
            contentSize: segmentation.contentSize,
            pieces: segmentation.pieces.map { piece in
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
        segmentStore.restore(segmentation(of: state))
        refreshSourceWatchers()
    }

    /// A written partition as this pane's own, each source's id re-minted
    /// from its path.
    func segmentation(of state: SegmentationState) -> Segmentation {
        let pieces = state.pieces.map { piece in
            Piece(start: piece.start, name: piece.name, link: piece.link.map { link in
                SegmentLink(source: segmentSources.id(for: URL(fileURLWithPath: link.path)),
                            sourceRange: link.sourceStart..<max(link.sourceStart, link.sourceEnd))
            })
        }
        return Segmentation(contentSize: state.contentSize, pieces: pieces)
    }

    private static let segmentsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted: equal partitions encode alike, so the log writes a repeat as
        // a flag (`HistoryLogWriter.appendSegments`).
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// A segment snapshot paired with an undo step, as a kept history's log
    /// carries it.
    func encodedSegments(_ segmentation: Segmentation) -> Data? {
        try? Self.segmentsEncoder.encode(workspaceState(of: segmentation))
    }

    func decodedSegments(_ data: Data) -> Segmentation? {
        (try? JSONDecoder().decode(SegmentationState.self, from: data)).map(segmentation(of:))
    }
}
