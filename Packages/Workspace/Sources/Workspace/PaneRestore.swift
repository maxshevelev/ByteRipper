import Foundation

/// What of a pane's saved state applies to the file as it is now
/// (`Design/WORKSPACE_PLAN.md`, "Restoring").
///
/// The position always comes back. Past the end of a file that got shorter,
/// the caret, the selection and the first row on screen move to the last
/// address. What was measured on the old bytes — segments, a tool's choice —
/// comes back only if the file is still the file it was measured on.
public struct PaneRestore: Equatable, Sendable {
    public var selection: Range<UInt64>
    public var topOffset: UInt64
    public var inputRegion: InputRegion
    public var insertMode: Bool
    /// False when the file changed on disk: segments and tool state are left
    /// out, because their offsets point into bytes that are no longer there.
    public var keepsMeasuredState: Bool

    /// - Parameters:
    ///   - saved: the pane as it was written down.
    ///   - size: the document's size now.
    ///   - unchanged: whether the document is still the one `saved` was taken
    ///     of.
    public init(_ saved: PaneState, size: UInt64, unchanged: Bool) {
        // The last address, not the end: a caret on the end of a file is
        // legal, but a file that shrank under the reader is better shown at
        // its last byte than past it.
        let last = size == 0 ? 0 : size - 1
        let start = min(saved.selectionStart, saved.selectionEnd)
        let end = max(saved.selectionStart, saved.selectionEnd)
        if unchanged {
            selection = min(start, size)..<min(end, size)
        } else {
            let clampedStart = min(start, last)
            selection = clampedStart..<max(clampedStart, min(end, size))
        }
        topOffset = min(saved.topOffset, last)
        inputRegion = saved.inputRegion
        insertMode = saved.insertMode
        keepsMeasuredState = unchanged
    }
}

extension Array where Element == BookmarkState {
    /// The bookmarks that still mark a row of some file in the tab: one past
    /// the end of every file marks nothing, and a list of them collapsing
    /// onto the last row would point at the wrong place.
    public func restorable(withinLargest size: UInt64?) -> [BookmarkState] {
        guard let size else { return self }
        return filter { $0.row < size }
    }
}

extension SegmentationState {
    /// Whether these pieces still describe a document of `size` whose bytes
    /// are unchanged: the cuts were made on these bytes and no others.
    public func applies(toSize size: UInt64, unchanged: Bool) -> Bool {
        unchanged && contentSize == size && pieces.first?.start == 0
            && zip(pieces, pieces.dropFirst()).allSatisfy { $0.start < $1.start }
            && (pieces.last.map { $0.start < size || size == 0 } ?? false)
    }
}

/// Something a restore could not bring back as it was, for the one warning
/// shown once everything is open.
public enum RestoreIssue: Equatable, Sendable {
    /// The file is no longer at its path; its pane stays empty.
    case missing(path: String)
    /// The file opened, but it changed on disk since the workspace was
    /// written: its position was kept, its segments and tool state were not.
    case changed(path: String)
}
