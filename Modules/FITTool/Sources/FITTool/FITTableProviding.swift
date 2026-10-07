import Foundation
import UEFIImage

/// The last table a FIT panel read, with what was worked out beside it — kept
/// by the pane, so a panel built again finds it instead of reading it again.
public struct CachedFITTable: Equatable, Sendable {
    /// The reading with the names of what its rows point into.
    public var report: FITReport
    /// The image's protected ranges, once they have been read.
    public var ranges: ProtectedRanges?

    public init(report: FITReport, ranges: ProtectedRanges?) {
        self.report = report
        self.ranges = ranges
    }
}

/// What the FIT panel's session reaches to get at the pane's own copy of the
/// last table it read, without depending on the app that owns it.
///
/// A session is built fresh on every activation of the tool, and the table is
/// a reading of the file: it belongs to the file, as the tree and the ME
/// analysis do. An edit or a new file in the pane drops it.
@MainActor
public protocol FITTableProviding: AnyObject {
    func cachedFITTable() -> CachedFITTable?
    func setCachedFITTable(_ table: CachedFITTable?)
}
