import Cocoa
import ByteRipperCore
import ToolModuleKit
import UEFIImage

/// What a surface's minimap needs from the tab it lives in
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Everything here is something a map cannot know from the panes it draws: how
/// two of them are arranged, what the comparison index has settled, which menus
/// the gutter offers, and whether this surface's panels move the window's edge.
///
/// It is a protocol so the map physically cannot ask the window a question it
/// was not offered. Every mistake this file exists to prevent had the same
/// shape — a method that took the surface it draws for and then read the
/// window's mode anyway — and the compiler could not see it, because the type
/// was right and the data was somebody else's.
@MainActor protocol MinimapHost: AnyObject {
    /// How two maps sit beside each other, following the panes they map.
    func minimapPairLayout() -> MinimapView.MapLayout

    /// The overview's snapshot of a pane: its bytes, and what the comparison
    /// has settled about them.
    func overviewSource(for pane: PaneViewModel) -> SurfaceMinimapController.OverviewSource

    /// Which build of the comparison index the snapshots came from, so an
    /// overview can tell when the index has moved under it.
    var comparisonIndexBuild: Int { get }

    /// Makes the pane behind map `index` the active one — what clicking the
    /// second map of a comparison means, as clicking its dump does.
    func activatePane(showingMapAt index: Int)

    /// The gutter's and the strip's own menus, which are the tab's commands.
    func minimapSegmentMenu(mapIndex: Int, pieceIndex: Int, point: NSPoint) -> NSMenu?
    func minimapZoneMenu(mapIndex: Int, zoneID: Zone.ID) -> NSMenu?

    /// The window move that goes with showing or hiding this surface's panel,
    /// or nil for a surface that opens its panels inside the room it was given.
    func minimapWindowResize(visible: Bool) -> ((CGFloat) -> Void)?
}

/// One surface's minimap: the map, its chrome, everything that map is in the
/// middle of, and every rule about what it draws
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// One of these per surface. The tab has one for its own panes; a fragment
/// panel has one for the part it holds. What differs between them is answered
/// by the surface — which panes are map 0 and map 1 — and by the host, and
/// nothing here can reach past either.
@MainActor final class SurfaceMinimapController {
    /// The map itself. It knows nothing about panes or files: it addresses by
    /// map index and pulls what it draws, which is what makes a second one
    /// possible at all.
    let view = MinimapView()

    /// The map plus its chrome — the header's mode switch and the status bar's
    /// rebuild progress (§19.2).
    private(set) lazy var panel = MinimapPanelView(mapView: view)

    /// The surface this map belongs to, which answers what it maps.
    private unowned let surface: DocumentSurface
    private weak var host: MinimapHost?

    /// Whether the panel is shown. Drives the split's divider clamp: while
    /// hidden, the clamp pins the divider to the trailing edge so the panel
    /// sits at zero width and the dump reclaims the content area (§19).
    private(set) var isPanelVisible = false

    init(surface: DocumentSurface, host: MinimapHost?) {
        self.surface = surface
        self.host = host
    }

    // MARK: - What this map maps

    private func panes() -> [PaneViewModel] { surface.panesInMapOrder() }
    private func paneViews() -> [FilePaneView] { surface.paneViewsInMapOrder() }
    private func pane(at index: Int) -> PaneViewModel? { surface.mappedPane(at: index) }

    // MARK: - What the map is built out of

    /// One pane's inputs for an overview summary, snapshotted on the main thread
    /// before the background pass reads anything. Internal so a test can drive
    /// the row engine directly.
    struct OverviewSource: Sendable {
        let storage: (any ByteStorage)?
        /// What the bytes are painted modified against (§6, §21.7): the saved
        /// file, or — in an image with no file of its own — each linked piece's
        /// own source.
        let baseline: ModifiedBaseline
        let size: UInt64
        /// Where the edit overlay has written — the only offsets a modified byte
        /// can sit at.
        let edited: [Range<UInt64>]
        /// The comparison index, kept whole rather than flattened into a list of
        /// differing ranges: the rows being computed ask it for the blocks in
        /// their own window (§8). Flattening it here walked every block in the
        /// index on every keystroke — a third of the main thread on a 16 MB
        /// comparison, and the sticking that came with it. Nil in single-file
        /// mode and before the first index lands.
        let differences: DiffBlockIndex?
    }

    /// Adds up what the concurrent passes have finished and reports it to the
    /// panel's status bar, in twentieths: a progress bar told about every one of
    /// a thousand rows would cost more than the pass it measures.
    private final class OverviewProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private var done = 0
        private var reportedStep = -1
        // The callback is always invoked on the main actor — `advance` hops there
        // before firing it — so it is declared main-actor isolated; otherwise a
        // caller updating the panel from it would warn.
        private let onChange: @Sendable @MainActor (Double) -> Void

        init(total: Int, onChange: @escaping @Sendable @MainActor (Double) -> Void) {
            self.total = max(1, total)
            self.onChange = onChange
        }

        func advance(_ rows: Int) {
            lock.lock()
            done += rows
            let fraction = min(1, Double(done) / Double(total))
            let step = Int(fraction * 20)
            let changed = step != reportedStep
            if changed { reportedStep = step }
            lock.unlock()
            guard changed else { return }
            Task { @MainActor in onChange(fraction) }
        }
    }

    /// How long a rebuild has to run before its progress is worth showing. A
    /// small dump is binned in a few milliseconds, and a bar that appeared for
    /// one frame would read as a glitch rather than as progress.
    /// Injectable so a test can pin the policy instead of racing a real pass.
    static var overviewProgressDelay: Duration = .milliseconds(80)

    /// Once the bar is up it stays up this long, even if the pass finishes
    /// first. Binning two 16 MB dumps takes ~150 ms, so hiding the bar the
    /// instant the pass ended made it flash for a few frames — visible as a
    /// flicker, unreadable as progress.
    static var overviewProgressMinimumVisible: Duration = .milliseconds(300)

    /// Bins one file into `rowCount` rows of 16 cells: how full each cell's slice
    /// of bytes is, and which cells hold a modified or differing byte.
    ///
    /// Rows are binned over `extent` — the longest open file — so the same row
    /// means the same absolute offset on both maps (§9); rows past this file's
    /// own end stay empty. One read per row keeps the pass sequential and bounded
    /// by the file's size.
    nonisolated private static func overviewSummary(
        source: OverviewSource, extent: UInt64, rowCount: Int,
        shouldCancel: () -> Bool,
        rowsDone: (Int) -> Void = { _ in }
    ) -> MinimapView.OverviewSummary {
        let columns = Int(MinimapView.bytesPerRow)
        let rows = max(0, rowCount)
        let empty = MinimapView.OverviewSummary(
            extent: extent, rowCount: rowCount,
            density: [UInt8](repeating: 0, count: rows * columns),
            modified: [UInt16](repeating: 0, count: rows),
            different: [UInt16](repeating: 0, count: rows)
        )
        guard rowCount > 0, extent > 0,
              let all = overviewRows(source: source, extent: extent, rowCount: rowCount,
                                     rows: 0...(rowCount - 1),
                                     shouldCancel: shouldCancel, rowsDone: rowsDone)
        else { return empty }
        return MinimapView.OverviewSummary(extent: extent, rowCount: rowCount,
                                          density: all.density, modified: all.modified,
                                          different: all.different)
    }

    /// The overview's values for `rows` alone: the density of their cells and
    /// their modified/difference bits. A whole picture is this over every row; a
    /// byte edit is this over the one or two rows it lands in, which is why the
    /// engine takes a row range rather than always walking the file (§19.9).
    ///
    /// Returns nil when cancelled or when `rows` is not inside the picture.
    nonisolated static func overviewRows(
        source: OverviewSource, extent: UInt64, rowCount: Int, rows: ClosedRange<Int>,
        shouldCancel: () -> Bool = { false },
        rowsDone: (Int) -> Void = { _ in }
    ) -> (density: [UInt8], modified: [UInt16], different: [UInt16])? {
        let columns = Int(MinimapView.bytesPerRow)
        guard rowCount > 0, extent > 0, rows.lowerBound >= 0, rows.upperBound < rowCount else {
            return nil
        }
        var density = [UInt8](repeating: 0, count: rows.count * columns)
        var modified = [UInt16](repeating: 0, count: rows.count)
        var different = [UInt16](repeating: 0, count: rows.count)
        guard let storage = source.storage else { return (density, modified, different) }

        // One mapping, shared with the search's match overlay: the two must
        // land on the same cells or the map contradicts itself (§19.4.2).
        let binning = OverviewBinning(extent: extent, rowCount: rowCount)

        /// The first byte of a row's slice of the file.
        func start(ofRow row: Int) -> UInt64 { binning.start(ofRow: row) }

        /// The cells one byte of a row's slice occupies, when the slice is
        /// thinner than the row's 16 cells: the byte is stretched over the cells
        /// it covers, so `index` 0 of a one-byte slice fills the row.
        ///
        /// A row covers fewer bytes than it has cells whenever the file is
        /// smaller than 16 bytes per pixel row — under ~25 KB on a full-height
        /// panel — and covers a *fraction* of a byte once the file is smaller
        /// than the panel has rows. Slicing per cell there gave every cell but
        /// the last an empty byte range: the picture came out a pale field with
        /// the whole file collapsed into a stripe down its right edge (§19.4.2).
        func stretchedColumns(forByteAt index: UInt64, ofSpan span: UInt64) -> ClosedRange<Int> {
            binning.stretchedColumns(forByteAt: index, ofSpan: span)
        }

        /// The row a byte offset falls in, and the cells it occupies there.
        func cells(of offset: UInt64) -> (row: Int, columns: ClosedRange<Int>)? {
            binning.cells(of: offset, within: rows)
        }

        // The byte range these rows cover, so the passes below read and scan
        // only what belongs to them.
        let windowStart = start(ofRow: rows.lowerBound)
        let windowEnd = start(ofRow: rows.upperBound + 1)

        // Density: one read per row, counting the bytes that are not a fill.
        // Progress is reported in blocks of rows, which is granular enough for a
        // bar and rare enough not to matter to the pass.
        var reportedRow = rows.lowerBound
        for row in rows {
            if shouldCancel() { return nil }
            if row - reportedRow >= 64 {
                rowsDone(row - reportedRow)
                reportedRow = row
            }
            let rowStart = start(ofRow: row)
            let rowEnd = start(ofRow: row + 1)
            let span = rowEnd - rowStart
            // A row whose slice is thinner than a byte still stands for the byte
            // its position falls in — read that one, rather than leaving the row
            // blank as it used to be.
            let readEnd = min(max(rowEnd, rowStart + 1), source.size)
            guard rowStart < readEnd else { continue }
            guard let bytes = try? storage.read(at: rowStart, length: Int(readEnd - rowStart)),
                  !bytes.isEmpty else { continue }
            let base = (row - rows.lowerBound) * columns
            bytes.withUnsafeBufferPointer { buffer in
                guard span >= UInt64(columns) else {
                    // Fewer bytes than cells: each byte fills the cells it
                    // covers, so the row reads as a coarse picture of those
                    // bytes instead of one inked cell at its right edge.
                    let count = min(buffer.count, Int(max(span, 1)))
                    for index in 0..<count {
                        guard MainViewController.significantByteCount(buffer, from: index, to: index + 1) > 0 else { continue }
                        for column in stretchedColumns(forByteAt: UInt64(index), ofSpan: span) {
                            density[base + column] = 255
                        }
                    }
                    return
                }
                for column in 0..<columns {
                    let sliceStart = rowStart + span * UInt64(column) / UInt64(columns)
                    let sliceEnd = rowStart + span * UInt64(column + 1) / UInt64(columns)
                    let from = Int(sliceStart - rowStart)
                    let to = Int(min(sliceEnd, readEnd) - rowStart)
                    guard from < to, to <= buffer.count else { continue }
                    let significant = MainViewController.significantByteCount(buffer, from: from, to: to)
                    guard significant > 0 else { continue }
                    density[base + column] =
                        UInt8(min(255, max(1, significant * 255 / (to - from))))
                }
            }
        }

        rowsDone(rows.upperBound + 1 - reportedRow)

        // Modified: where the byte differs from the saved copy — the same rule
        // the panes paint by — inside the rows an edit can have reached.
        //
        // Row by row, cell by cell, comparing whole slices rather than bytes: an
        // insert or a delete shifts every byte after it, so `source.edited`
        // covers the file's whole tail and a per-byte loop over it took seconds.
        // Bytes outside the edited ranges cannot differ from the saved copy, so
        // comparing a cell whole is safe: the untouched part of it compares
        // equal and contributes nothing.
        if source.baseline.marksAnything, !source.edited.isEmpty {
            for row in rows {
                if shouldCancel() { return nil }
                let rowStart = start(ofRow: row)
                let rowEnd = start(ofRow: row + 1)
                let span = rowEnd - rowStart
                let readEnd = min(max(rowEnd, rowStart + 1), source.size)
                guard rowStart < readEnd else { continue }
                // Rows no edit can have reached are skipped, so a clean file
                // costs nothing here and a small edit costs one row.
                guard source.edited.contains(where: {
                    $0.lowerBound < readEnd && $0.upperBound > rowStart
                }) else { continue }
                guard let bytes = try? storage.read(at: rowStart, length: Int(readEnd - rowStart)),
                      !bytes.isEmpty else { continue }
                // One read of the references per row, whichever sources answer
                // for it (§21.7): a row inside a joined half is measured
                // against that half's own file.
                let block = source.baseline.block(in: rowStart..<readEnd)
                let index = row - rows.lowerBound

                guard span >= UInt64(columns) else {
                    // Fewer bytes than cells: compare the handful of bytes and
                    // stretch each one over the cells it covers.
                    for offsetInRow in 0..<bytes.count {
                        let absolute = rowStart + UInt64(offsetInRow)
                        let changed: Bool
                        switch block.reference(at: absolute) {
                        case .unmarked: changed = false
                        case .beyond: changed = true
                        case .byte(let reference): changed = reference != bytes[offsetInRow]
                        }
                        guard changed else { continue }
                        for column in stretchedColumns(forByteAt: UInt64(offsetInRow), ofSpan: span) {
                            modified[index] |= UInt16(1) << UInt16(column)
                        }
                    }
                    continue
                }

                for column in 0..<columns {
                    let sliceStart = rowStart + span * UInt64(column) / UInt64(columns)
                    let sliceEnd = rowStart + span * UInt64(column + 1) / UInt64(columns)
                    let from = Int(sliceStart - rowStart)
                    let to = Int(min(sliceEnd, readEnd) - rowStart)
                    guard from < to, to <= bytes.count else { continue }
                    let slice = sliceStart..<(rowStart + UInt64(to))
                    // Bytes past their reference's end are new by definition,
                    // and bytes with no reference at all are never modified —
                    // both answered without reading one.
                    if block.touchesBeyond(slice) {
                        modified[index] |= UInt16(1) << UInt16(column)
                        continue
                    }
                    if block.isUnreferenced(slice) { continue }
                    if block.isFullyCovered(slice) {
                        // The whole slice has a reference in one buffer: one
                        // memcmp, the way the saved file was always compared.
                        let differs = bytes.withUnsafeBufferPointer { current in
                            block.bytes.withUnsafeBufferPointer { reference in
                                memcmp(current.baseAddress! + from, reference.baseAddress! + from, to - from) != 0
                            }
                        }
                        if differs { modified[index] |= UInt16(1) << UInt16(column) }
                        continue
                    }
                    // A slice straddling two sources' edges: the handful of
                    // bytes at a seam, walked one by one.
                    for offsetInRow in from..<to {
                        let absolute = rowStart + UInt64(offsetInRow)
                        let changed: Bool
                        switch block.reference(at: absolute) {
                        case .unmarked: changed = false
                        case .beyond: changed = true
                        case .byte(let reference): changed = reference != bytes[offsetInRow]
                        }
                        if changed {
                            modified[index] |= UInt16(1) << UInt16(column)
                            break
                        }
                    }
                }
            }
        }

        // Differences: the index's differing blocks that touch these rows, found
        // by binary search rather than by flattening the index. A block spanning
        // whole rows marks every column of them.
        for block in source.differences?.blocks(in: windowStart..<windowEnd) ?? []
        where block.kind == .different {
            if shouldCancel() { return nil }
            binning.mark(block.range, rows: rows, into: &different)
        }

        // A cell past this file's own end holds none of its bytes, so it can
        // neither differ nor be modified — whatever the comparison index says.
        // The index is built over the *union* of the two files (§9), so every
        // byte past the shorter file's end counts as a difference there; drawn
        // as such it painted the shorter map's empty tail solid. The tail is
        // empty, exactly as it is in detail mode.
        for row in rows {
            let slot = row - rows.lowerBound
            guard modified[slot] != 0 || different[slot] != 0 else { continue }
            var covered: UInt16 = 0
            let rowStart = start(ofRow: row)
            let span = start(ofRow: row + 1) - rowStart
            for column in 0..<columns
            where rowStart + span * UInt64(column) / UInt64(columns) < source.size {
                covered |= UInt16(1) << UInt16(column)
            }
            modified[slot] &= covered
            different[slot] &= covered
        }

        return (density, modified, different)
    }

    /// What the overview's match strokes were last computed from: the geometry,
    /// and each pane's set as far as the strokes can tell two sets apart.
    ///
    /// The set is not compared byte for byte — it is compared by the things the
    /// picture is made of. Two sets with the same pattern, the same folding and
    /// the same count over the same extent mark the same rows, so there is
    /// nothing to redo; and while a search is being indexed the count is what
    /// grows, so a batch still reads as a new picture.
    struct MatchPicture: Equatable {
        struct Marks: Equatable {
            let pattern: SearchPattern
            let folding: CaseFolding
            let total: Int

            init?(_ set: MatchSet?) {
                guard let set else { return nil }
                pattern = set.pattern
                folding = set.folding
                total = set.total
            }
        }

        let rowCount: Int
        let extent: UInt64
        let sets: [Marks?]
    }

    /// One map's worth of match bits.
    ///
    /// Walks the **rows**, not the matches: a two-byte pattern in a dump has
    /// hundreds of thousands of occurrences and the overview has a couple of
    /// thousand rows, so per-match work would be the wrong way round. Each row
    /// stops early once every column is marked or after `perRowMarkLimit`
    /// matches — by then the row says all it can say at this scale.
    nonisolated private static func matchOverlay(for set: MatchSet?, current: Range<UInt64>?,
                                                 binning: OverviewBinning,
                                                 rowCount: Int,
                                                 extent: UInt64) -> MinimapView.MatchOverlay {
        guard let set, set.isHighlightable else { return .empty }
        let perRowMarkLimit = 32
        let rows = 0...(rowCount - 1)
        let reach = UInt64(max(set.patternLength - 1, 0))
        var matched = [UInt16](repeating: 0, count: rowCount)

        for row in rows {
            let rowStart = binning.start(ofRow: row)
            let rowEnd = binning.start(ofRow: row + 1)
            guard rowEnd > rowStart else { continue }
            // A match starting just above the row can still reach into it.
            let from = rowStart > reach ? rowStart - reach : 0
            var index = set.index(atOrAfter: from)
            var marks = 0
            while let i = index, marks < perRowMarkLimit, matched[row] != .max {
                guard let start = set.start(at: i), start < rowEnd else { break }
                // The whole row range, not this one row: the marking indexes
                // the bits from the range's start, and the masks are absolute.
                binning.markHexColumns(start..<start + UInt64(set.patternLength),
                                       rows: rows, into: &matched)
                marks += 1
                index = i + 1 < set.total ? i + 1 : nil
            }
        }
        return MinimapView.MatchOverlay(
            extent: extent, rowCount: rowCount, matched: matched,
            current: currentMatchMarks(current, binning: binning, rowCount: rowCount))
    }

    /// The row bits for the find indicator alone — one range, so this is what a
    /// step of ‹ › costs on the map.
    nonisolated private static func currentMatchMarks(_ range: Range<UInt64>?,
                                                      binning: OverviewBinning,
                                                      rowCount: Int) -> [UInt16] {
        var marks = [UInt16](repeating: 0, count: rowCount)
        guard rowCount > 0, let range else { return marks }
        binning.markHexColumns(range, rows: 0...(rowCount - 1), into: &marks)
        return marks
    }

    // MARK: - The gutter's own menus, which are the tab's commands

    private func segmentMenu(mapIndex: Int, pieceIndex: Int, point: NSPoint) -> NSMenu? {
        host?.minimapSegmentMenu(mapIndex: mapIndex, pieceIndex: pieceIndex, point: point)
    }

    private func zoneMenu(mapIndex: Int, zoneID: Zone.ID) -> NSMenu? {
        host?.minimapZoneMenu(mapIndex: mapIndex, zoneID: zoneID)
    }

    // MARK: - What this map is in the middle of

    /// The debounce waiting to start a pass, and the pass itself. Separate
    /// handles because they are cancelled for different reasons: a request that
    /// arrives while a pass runs must not kill it (see `scheduleOverviewRebuild`).
    private var overviewDebounceTask: Task<Void, Never>?

    private var overviewPassTask: Task<Void, Never>?

    /// The row count the running pass is binning for — a diagnostic seam for the
    /// tests, and what a future decision about a pass's usefulness would read.
    private(set) var overviewPassRowCount = 0

    /// Edited ranges whose difference marks are still waiting for the comparison
    /// index to absorb them (§19.9).
    private var overviewRowsAwaitingIndex: [Range<UInt64>] = []

    /// The index build this controller's overview was derived from.
    private var overviewIndexBuildCount = 0

    /// How many full overview passes and how many row patches have run — the
    /// seam for "an edit does not walk the file" (§19.9).
    private(set) var overviewRebuilds = 0

    private(set) var overviewPatches = 0

    /// Full passes that finished and published their picture.
    private(set) var overviewRebuildsCompleted = 0

    /// The rebuild's latest progress, or nil when nothing is running.
    private var overviewProgress: Double?

    private var overviewProgressReveal: Task<Void, Never>?

    private var overviewProgressHide: Task<Void, Never>?

    private var overviewProgressShown: ContinuousClock.Instant?

    private var syncedMatchPicture: MatchPicture?

    /// Whether a match sync is already queued for the next turn, so a run of
    /// presses costs one walk rather than one per press.
    private var minimapMatchSyncScheduled = false

    /// Which sync is current: a walk that finished after a newer one started
    /// has nothing to install.
    private var minimapMatchSyncGeneration = 0

    /// How many times the strokes have actually been walked. The point of the
    /// picture check above is that this does not climb while the set stands
    /// still, which is only observable as a count (§11).
    private(set) var matchOverlayWalksForTesting = 0

    /// The panes' latest visible byte ranges, keyed by pane identity, so a
    /// scroll in either pane rebuilds the minimap's viewport array without
    /// waiting for the other pane to re-report. Cleared on every apply(mode:) —
    /// panes are rebuilt and re-keyed.
    private var paneViewports: [ObjectIdentifier: Range<UInt64>] = [:]

    // The tab's own map, in the spelling that means it. Every minimap method
    // names the surface it acts on; these three are the ones reached from
    // outside this file, where "the minimap" means the window's.



    /// Wires a surface's map to the panes it maps: what it pulls as it draws,
    /// and what a drag, a click or a mode switch over it does
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// Every closure names the surface it was wired for, so a second map — a
    /// fragment panel's — feeds from that panel's pane rather than from the
    /// tab's. `menus` is off for a panel's map for now: the gutter's commands
    /// are menu actions addressed to the tab, and pointing them at a surface is
    /// its own change.
    func wire(menus: Bool = true) {
        // The map is virtualized: it pulls the bytes of its visible window as it
        // draws, and a drag or a wheel over it scrolls the panes (§19).
        view.byteStates = { [weak self] mapIndex, range in
            self?.byteStates(mapIndex: mapIndex, range: range) ?? []
        }
        view.matchRanges = { [weak self] mapIndex, range in
            self?.matchRanges(mapIndex: mapIndex, range: range) ?? []
        }
        view.currentMatchRange = { [weak self] mapIndex in
            self?.currentMatch(mapIndex: mapIndex)
        }
        view.onScrollToOffset = { [weak self] offset in
            self?.scrollPanes(toOffset: offset)
        }
        view.onSelectOffset = { [weak self] mapIndex, offset in
            self?.selectOffset(mapIndex: mapIndex, offset: offset)
        }
        // The segment strip's legend answers (§19.4.4, §21.3): the piece's
        // current name (asked for at hover time, since the store fires no
        // invalidation for a rename), and the right-click menu that acts on the
        // piece under the pointer — the same menu the form's row offers.
        view.segmentPieceName = { [weak self] mapIndex, pieceIndex in
            self?.segmentName(mapIndex: mapIndex, pieceIndex: pieceIndex) ?? ""
        }
        if menus {
            view.segmentStripMenu = { [weak self] mapIndex, pieceIndex, point in
                self?.segmentMenu(mapIndex: mapIndex, pieceIndex: pieceIndex, point: point)
            }
        }
        // And the zone gutter's, on the other side of each map (§19.4.5): the
        // commands that act on the zone under the pointer. Its name and range
        // are the bracket's own — a tool-module republishes its whole map
        // whenever anything about it changes, so there is nothing to ask for
        // live the way a segment's name has to be.
        if menus {
            view.zoneBracketMenu = { [weak self] mapIndex, zoneID in
                self?.zoneMenu(mapIndex: mapIndex, zoneID: zoneID)
            }
        }
        // The overview bins the file into one row per pixel, so a resize changes
        // the bins and the summary has to be recomputed (§19.4).
        view.onOverviewRowCountChanged = { [weak self] in
            self?.scheduleOverviewRebuild()
        }
        // A panel tall enough to magnify the open file takes the Overview choice
        // away, and gives it back when it shrinks again (§19.4).
        view.onOverviewUsefulnessChanged = { [weak self] in
            self?.updateOverviewAvailability()
        }
        panel.onModeChange = { [weak self] mode in
            self?.setRenderMode(mode)
        }
        // The panel aligns its own chrome with the dump, and asks where the dump
        // is on every layout pass (§19.2).
        panel.dumpAreaInWindow = { [weak self] in
            guard let self else { return nil }
            let areas = self.paneViews().compactMap(\.dumpAreaInWindow)
            guard let first = areas.first else { return nil }
            // The maps span every dump: stacked panes (§3.3) put one above the
            // other, and the panel's two maps cover both, so the span the chrome
            // has to match is their union — not the first pane's dump, which
            // ends halfway down the window.
            return areas.dropFirst().reduce(first) { $0.union($1) }
        }
    }

    /// Shows or hides the panel, animating the divider unless the user prefers
    /// reduced motion (then it snaps).
    func setPanelVisible(_ visible: Bool, animated: Bool = true) {
        let changed = isPanelVisible != visible
        isPanelVisible = visible
        // The window grows or shrinks by the panel's width so the hex content
        // area keeps its width (§19). It is handed to the panel's animation
        // rather than run beside it: one clock and one curve, so the window
        // edge and the panel edge move as a single thing. Evaluated here,
        // before the width changes, because it captures the window's start.
        // Only the tab's own panel moves the window's edge: a fragment panel
        // opens its map inside the area it was given, and a window that grew
        // because a panel over it showed a map would be the window moving for
        // something that is not the window's.
        let resize = changed ? host?.minimapWindowResize(visible: visible) : nil
        surface.setMinimapPanelWidth(visible ? surface.minimapPreferredPanelWidth : 0,
                                     animated: animated, windowResize: resize)
        if changed { panelVisibilityChanged(visible) }
    }

    /// Toggles the panel's visibility (§19).
    func togglePanel(animated: Bool = true) {
        setPanelVisible(!isPanelVisible, animated: animated)
    }

    /// A panel-visibility change: while hidden the maps and viewport are stale
    /// (nothing was drawn), so a show refreshes them (§19).
    private func panelVisibilityChanged(_ visible: Bool) {
        if visible {
            updateLayout()
            refreshMaps()
            // The mode was decided when the file opened, panel or no panel
            // (§19.4) — showing the panel must not undo a choice made in it,
            // only settle whether overview is on offer now that it has a height.
            updateOverviewAvailability()
            updateViewports()
            rebuildOverview()
            // The search's marks were not computed while the panel was closed
            // (§11).
            scheduleMatchSync()
        }
    }

    /// Recomputes the minimap's internal map split from the current window mode
    /// and pane arrangement (§19): one map in single-file mode, two maps with a
    /// centered vertical line for side-by-side panes, two maps with a
    /// horizontal line mirroring the panes' divider for stacked panes.
    func updateLayout() {
        guard surface === self.surface else {
            // A fragment panel has one pane, so its map is one map, whatever
            // the tab behind it is showing.
            view.setMapLayout(.single)
            return
        }
        guard panes().count > 1 else {
            view.setMapLayout(.single)
            return
        }
        view.setMapLayout(host?.minimapPairLayout() ?? .single)
    }

    /// Keeps the Overview control in step with what the overview could say about
    /// the open file, and leaves the mode if it has nothing left to say — the
    /// panel is never parked in a view its own switch refuses to offer (§19.4).
    func updateOverviewAvailability() {
        let available = view.overviewIsInformative()
        panel.setOverviewAvailable(available)
        if !available, view.renderMode == .overview {
            setRenderMode(.detail)
        }
    }

    /// Switches the minimap's mode and reflects it in the header switch.
    func setRenderMode(_ mode: MinimapView.RenderMode) {
        // The switch reflects the map's state whatever changed it — the menu
        // item (§15), a file that calls for overview, or the switch itself.
        panel.showMode(mode)
        guard view.renderMode != mode else { return }
        view.setRenderMode(mode)
        if mode == .overview {
            scheduleOverviewRebuild()
        } else {
            cancelOverviewWork()
            reportOverviewProgress(nil)
        }
    }

    /// Runs a full overview pass now, so a test can compare a patched picture
    /// against the one a full pass builds.
    func rebuildForTesting() {
        rebuildOverview()
    }

    /// Recomputes the overview after a change that alters what it shows. Every
    /// row of an overview is on screen at once, so unlike the detail window it
    /// cannot be pulled per repaint — it is computed in the background and
    /// debounced, so a burst of edits costs one pass (§19.4).
    /// The pass waits for the edits to stop: each request restarts the delay, so
    /// a burst of keystrokes — auto-repeat is thirty a second — costs one pass
    /// after it, not one per keystroke. A pass over two 16 MB dumps reads both
    /// files whole; doing that thirty times a second starves the main thread of
    /// the very cache it draws from, which is felt as the typing sticking.
    ///
    /// Waiting is only acceptable because the map does not go silent while it
    /// waits: a shifting edit marks its tail immediately and for free
    /// (`markShiftedTailModified`), and the picture in hand is stretched rather
    /// than dropped. What the pass adds is exactness.
    ///
    /// A pass in flight is cancelled: something changed under it, so whatever it
    /// is halfway through computing is already the wrong picture, and finishing
    /// it costs the reads that make the typing stick. The request that cancelled
    /// it starts the wait again.
    private func scheduleOverviewRebuild() {
        guard isPanelVisible, view.renderMode == .overview else { return }
        overviewPassTask?.cancel()
        overviewPassTask = nil
        reportOverviewProgress(nil)
        overviewDebounceTask?.cancel()
        overviewDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.overviewDebounceTask = nil
            self?.rebuildOverview()
        }
    }

    /// Cancels whatever the overview has in flight — a waiting debounce and a
    /// running pass — and forgets any queued request.
    private func cancelOverviewWork() {
        overviewDebounceTask?.cancel()
        overviewDebounceTask = nil
        overviewPassTask?.cancel()
        overviewPassTask = nil
    }

    private func rebuildOverview() {
        guard isPanelVisible, view.renderMode == .overview else { return }
        let rowCount = view.overviewRowCount()
        let sources = overviewSources()
        let extent = sources.map(\.size).max() ?? 0
        guard rowCount > 0, extent > 0, !sources.isEmpty else {
            view.setOverviewSummaries([])
            return
        }
        overviewPassTask?.cancel()
        overviewPassRowCount = rowCount
        overviewRebuilds += 1
        beginOverviewProgress()
        let progress = OverviewProgressSink(total: rowCount * sources.count) { [weak self] fraction in
            self?.reportOverviewProgress(fraction)
        }
        // Deliberately below the interface's priority: the picture is worth
        // waiting a little longer for, and nothing about it is worth competing
        // with the keystroke being typed. The two files are independent passes
        // and run together, which halves the wait on a comparison.
        overviewPassTask = Task.detached(priority: .utility) { [weak self] in
            let summaries = await withTaskGroup(
                of: (Int, MinimapView.OverviewSummary).self
            ) { group -> [MinimapView.OverviewSummary] in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        (index, Self.overviewSummary(source: source, extent: extent,
                                                     rowCount: rowCount,
                                                     shouldCancel: { Task.isCancelled },
                                                     rowsDone: { progress.advance($0) }))
                    }
                }
                var built: [(Int, MinimapView.OverviewSummary)] = []
                for await pair in group { built.append(pair) }
                return built.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reportOverviewProgress(nil)
                overviewPassTask = nil
                guard !Task.isCancelled, view.renderMode == .overview else { return }
                view.setOverviewSummaries(summaries)
                // The row count the picture was built for is now the panel's,
                // so the match bits are re-binned to match it (§11).
                self.scheduleMatchSync()
                overviewRebuildsCompleted += 1
            }
        }
    }

    /// Starts watching a rebuild: the bar appears only if the pass is still
    /// going when the delay is up.
    private func beginOverviewProgress() {
        overviewProgress = 0
        overviewProgressHide?.cancel()
        overviewProgressHide = nil
        overviewProgressReveal?.cancel()
        overviewProgressReveal = Task { [weak self] in
            try? await Task.sleep(for: Self.overviewProgressDelay)
            guard !Task.isCancelled, let self, let fraction = overviewProgress else { return }
            overviewProgressShown = .now
            panel.setRebuildProgress(fraction)
        }
    }

    /// Moves the bar, or clears the status bar when the rebuild is over (nil).
    private func reportOverviewProgress(_ fraction: Double?) {
        overviewProgress = fraction
        guard let fraction else {
            overviewProgressReveal?.cancel()
            overviewProgressReveal = nil
            hideOverviewProgress()
            return
        }
        // Only move a bar that is already up; whether it appears at all is the
        // reveal task's decision.
        guard !panel.progressBar.isHidden else { return }
        panel.setRebuildProgress(fraction)
    }

    /// Takes the bar down, holding it for the rest of its minimum showing.
    private func hideOverviewProgress() {
        guard let shown = overviewProgressShown else {
            panel.setRebuildProgress(nil)
            return
        }
        let remaining = Self.overviewProgressMinimumVisible - shown.duration(to: .now)
        guard remaining > .zero else {
            overviewProgressShown = nil
            panel.setRebuildProgress(nil)
            return
        }
        // Finish the bar off at 100 % while it waits out its minimum.
        panel.setRebuildProgress(1)
        overviewProgressHide?.cancel()
        overviewProgressHide = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled, let self else { return }
            overviewProgressShown = nil
            overviewProgressHide = nil
            panel.setRebuildProgress(nil)
        }
    }

    /// Re-aligns the panel's chrome with the dump (§19.2). The panel measures the
    /// dump itself on every layout pass; this is for the changes that move the
    /// bytes without touching the panel's own frame — a new pane layout, an
    /// opened Find bar (§11), a taller row (§6).
    func updateChrome() {
        panel.needsLayout = true
    }

    /// The overview's snapshot of a pane. What the comparison has settled about
    /// its bytes is the tab's to know, so it is asked for.
    private func overviewSource(_ pane: PaneViewModel) -> OverviewSource? {
        host?.overviewSource(for: pane)
    }

    /// Feeds the minimap the per-byte state of the rows it is showing.
    ///
    /// The map is virtualized: it asks for the byte range of its visible window
    /// on each repaint and stores nothing, so this reads a couple of thousand
    /// bytes however large the file is. It is also the very call the panes make
    /// to paint their own rows, which is what keeps the map's colours — modified,
    /// difference — identical to theirs instead of a background approximation
    /// that lags behind them.
    private func byteStates(mapIndex: Int, range: Range<UInt64>) -> [HexByteState] {
        pane(at: mapIndex)?.hexByteStates(in: range) ?? []
    }

    /// Feeds the minimap the active search's matches for the rows it is
    /// showing (§11), from the same set the dump paints from — the map cannot
    /// disagree with the dump for the same reason its byte states cannot.
    private func matchRanges(mapIndex: Int, range: Range<UInt64>) -> [Range<UInt64>] {
        pane(at: mapIndex)?.matchRanges(intersecting: range) ?? []
    }

    private func currentMatch(mapIndex: Int) -> Range<UInt64>? {
        pane(at: mapIndex)?.currentMatchRange
    }

    /// Hands the minimap the window's bookmarks (§19.4.3). The store is the one
    /// list both maps mark, so this is a straight copy — which rows a given map
    /// actually shows is the minimap's own geometry to decide, and the names come
    /// along because hovering a mark names it.
    func syncBookmarks() {
        // The list the panes this surface maps are reading, at those panes'
        // own offsets: the window's list for the tab's two, and the same list
        // shifted onto the part for a fragment panel (§20.7). Empty for a panel
        // that has no list at all — a decompressed body.
        view.setBookmarks(panes().first?.bookmarks?.bookmarks ?? [])
    }

    /// Hands the minimap the search's matches for the overview (§11).
    ///
    /// Derived from the pane's match set with the overview's own binning — the
    /// same arithmetic the density picture uses, so a match lands on the cell
    /// its bytes land in — and cheap enough to do on the main actor: a couple of
    /// hundred bytes per map, no file read.
    /// Asks for the map's match marks, later.
    ///
    /// The map is never on the critical path of a search: showing the match the
    /// user asked for is the dump's job and the reveal's, and the marks beside
    /// it are a summary that may as well arrive a frame afterwards. So this
    /// only schedules — coalescing a burst of presses into one sync — and the
    /// walk itself runs off the main thread (§11, §19).
    func scheduleMatchSync() {
        // Nothing on the map is drawn while the panel is closed, so nothing is
        // computed for it. Showing the panel is what asks
        // (`minimapPanelVisibilityChanged`), and the forgotten picture makes
        // that ask rebuild rather than trust what it last saw (§19).
        guard isPanelVisible else {
            syncedMatchPicture = nil
            return
        }
        guard !minimapMatchSyncScheduled else { return }
        minimapMatchSyncScheduled = true
        Task { @MainActor [weak self] in
            self?.minimapMatchSyncScheduled = false
            await self?.syncMatchOverlays()
        }
    }

    /// Hands the minimap the search's matches for the overview (§11).
    ///
    /// The state is read here, on the actor that owns it; the row walk that
    /// turns a set into marks is pure arithmetic over `Sendable` values, so it
    /// runs on a detached task and the result is installed on return. A picture
    /// that has been overtaken while that ran is dropped: a newer sync is
    /// already on its way.
    private func syncMatchOverlays() async {
        guard isPanelVisible else {
            syncedMatchPicture = nil
            return
        }
        let rowCount = view.overviewRowCount()
        let extent = fileSizes().max() ?? 0
        let panes: [PaneViewModel?] = panes()
        guard rowCount > 0, extent > 0, !panes.isEmpty else {
            view.setMatchOverlays([])
            syncedMatchPicture = nil
            return
        }
        let binning = OverviewBinning(extent: extent, rowCount: rowCount)
        let picture = MatchPicture(rowCount: rowCount, extent: extent,
                                   sets: panes.map { MatchPicture.Marks($0?.highlightedMatchSet) })
        if picture == syncedMatchPicture, view.matchOverlays.count == panes.count {
            // The same occurrences over the same geometry are the same strokes.
            // Only the plate can have moved, and re-marking one range is the
            // whole of that — this is the path a press of ‹ › takes, and it
            // used to walk every row of the map instead (§11).
            view.setMatchOverlays(zip(view.matchOverlays, panes).map { overlay, pane in
                var moved = overlay
                moved.current = Self.currentMatchMarks(pane?.currentMatchRange, binning: binning,
                                                       rowCount: rowCount)
                return moved
            })
            return
        }
        // The sets and the plates as values, so the walk needs nothing from the
        // main actor.
        let sets = panes.map { pane -> MatchSet? in
            guard let pane, pane.isOpen else { return nil }
            return pane.highlightedMatchSet
        }
        let currents = panes.map { $0?.currentMatchRange }
        let generation = minimapMatchSyncGeneration + 1
        minimapMatchSyncGeneration = generation
        matchOverlayWalksForTesting += 1
        let overlays = await Task.detached(priority: .utility) {
            zip(sets, currents).map {
                Self.matchOverlay(for: $0, current: $1, binning: binning,
                                  rowCount: rowCount, extent: extent)
            }
        }.value
        guard generation == minimapMatchSyncGeneration else { return }
        syncedMatchPicture = picture
        view.setMatchOverlays(overlays)
    }

    /// Hands the minimap the open panes' segment partitions, so the strip beside
    /// each map paints the dump's pieces (§19.4.4). The tint is by *position* —
    /// the piece's index into the partition — the same rule the dump's row tint
    /// uses, so the strip and the dump are one legend. A pane with a single piece
    /// hands its lone block; the minimap draws no strip for it, and the strip
    /// appears the moment a cut makes a second piece.
    func syncSegments() {
        let panes: [PaneViewModel?] = panes()
        let blocks: [[MinimapView.SegmentBlock]] = panes.map { pane in
            guard let pane, pane.isOpen else { return [] }
            return pane.segmentStore.segments.map {
                MinimapView.SegmentBlock(range: $0.range,
                                         colorIndex: $0.index % HexTheme.segmentTints.count)
            }
        }
        view.setSegmentBlocks(blocks)
    }

    /// Hands the minimap the panes' published zone maps, so the gutter left of
    /// each map brackets what a tool-module found in that file (§19.4.5).
    ///
    /// Read from the panes rather than from the `ToolController`: the pane is
    /// where the map lands once it has been clamped to the file's own size
    /// (`ZoneMap.normalized`), so the gutter and the dump bracket exactly the
    /// same bytes. It also means this needs no idea of which pane a session is
    /// bound to — the other pane's map is simply empty.
    func syncZones() {
        let count = panes().count
        view.setZoneMaps((0..<count).map { index in
            guard let pane = pane(at: index), pane.isOpen else { return ZoneMap.empty }
            return pane.zones
        })
    }

    /// Hands the minimap the open files' sizes. That is all it needs to lay its
    /// maps out — everything it draws it pulls per repaint.
    func refreshMaps() {
        view.setMaps(fileSizes().map { MinimapView.Map(fileSize: $0) })
        updateSelections()
        // The maps were just rebuilt, so the marks have to be handed over again
        // — and a file that grew or shrank changes which of them are drawn (§9).
        syncBookmarks()
        // A content edit moves the cuts with the bytes (§21.2), so the strip's
        // partition follows — and a file that opened or closed changes which
        // panes have a partition at all.
        syncSegments()
        // The same goes for the zones a tool-module published: a file that
        // opened, closed or changed length changes which of them there are to
        // bracket (§19.4.5).
        syncZones()
        // The overview's match bits are binned over the extent, so a file that
        // grew or shrank re-bins them too (§11).
        scheduleMatchSync()
        // An insert or a delete can carry the file across the line where the
        // overview stops magnifying it, so the offer follows the size as well as
        // the panel's height (§19.4). The *mode* is deliberately not re-decided
        // here: this runs on every edit, and the choice belongs where the open
        // files change.
        updateOverviewAvailability()
        // The bytes moved, so an overview summary of them is stale.
        scheduleOverviewRebuild()
    }

    /// The bytes under the maps changed. An overwrite names a bounded range, so
    /// both modes update in place and at once: detail repaints the rows that draw
    /// it (its cells are pulled from the panes as it draws), and overview
    /// recomputes those rows of its picture instead of walking the file again —
    /// a typed byte moves one row of a thousand (§19.9).
    ///
    /// Both maps, because a byte edited in one file changes the difference state
    /// the other one paints at that same offset (§9).
    /// `mapIndex` is the map of the pane the edit happened in — the maps mirror
    /// the panes (§19). Only that map's rows can have moved: a shift in one file
    /// says nothing about the other, which is what painting both of them red
    /// wrongly claimed.
    func repaint(after edit: DiffEdit, mapIndex: Int) {
        switch edit {
        case .overwrite(let range):
            // Typing past EOF grows the file, which re-bins the overview: that is
            // a new picture, not a patch.
            guard view.maps.map(\.fileSize) == fileSizes() else {
                view.invalidateCells()
                refreshMaps()
                return
            }
            view.invalidateBytes(in: range)
            patchOverviewRows(covering: range)
            // The difference marks come from the comparison index, which absorbs
            // the edit in the background: these rows are patched again when it
            // does, instead of the whole picture being rebuilt (§19.9).
            // Only a comparison has an index for the difference marks to wait on,
        // and only a surface with two maps is one.
        if panes().count > 1 {
            overviewRowsAwaitingIndex.append(range)
        }
        case .insert, .delete:
            // Every byte after the change moved, so no range describes it: the
            // exact picture is a full pass, and that pass waits for the typing to
            // settle. Until it lands the map keeps the picture it has — a byte
            // or two out of date, which at a row per 13 KB is invisible.
            //
            // Marking the shifted tail red in the meantime was tried and is
            // wrong: from an edit near the start of a file that paints the whole
            // map red, which is not "the old picture, slightly stale" but a new
            // and much worse one.
            view.invalidateCells()
            refreshMaps()
        }
    }

    /// Recomputes the overview rows that `range` falls in, on every map, and
    /// leaves the rest of the picture untouched. Falls back to a full rebuild
    /// when the picture on screen was binned differently from what these rows
    /// would be (a resize or a new file landed in between).
    private func patchOverviewRows(covering range: Range<UInt64>) {
        guard isPanelVisible, view.renderMode == .overview else { return }
        let summaries = view.overviewSummaries
        let sources = overviewSources()
        guard !summaries.isEmpty, summaries.count == sources.count,
              let extent = summaries.first?.extent, extent > 0,
              let rowCount = summaries.first?.rowCount, rowCount > 0,
              summaries.allSatisfy({ $0.extent == extent && $0.rowCount == rowCount }),
              rowCount == view.overviewRowCount(),
              extent == sources.map(\.size).max() ?? 0 else {
            scheduleOverviewRebuild()
            return
        }
        let last = min(range.upperBound &- 1, extent - 1)
        guard range.lowerBound <= last else { return }
        let firstRow = Int(range.lowerBound * UInt64(rowCount) / extent)
        let lastRow = min(rowCount - 1, Int(last * UInt64(rowCount) / extent))
        guard firstRow <= lastRow else { return }
        let rows = firstRow...lastRow
        for (index, source) in sources.enumerated() {
            guard let patch = Self.overviewRows(source: source, extent: extent,
                                                rowCount: rowCount, rows: rows) else { continue }
            view.updateOverviewRows(rows, density: patch.density, modified: patch.modified,
                                           different: patch.different, forMapAt: index)
        }
        overviewPatches += 1
    }

    /// The open files' sizes, in map order.
    private func fileSizes() -> [UInt64] {
        panes().map(\.fileSize)
    }

    /// One snapshot per map, in map order.
    private func overviewSources() -> [OverviewSource] {
        panes().compactMap { overviewSource($0) }
    }

    /// The comparison index changed. When what changed is the edits this
    /// controller recorded, the overview patches their rows; anything else — a
    /// fresh index, a build starting, a cancel — means the derived picture is
    /// stale as a whole and is rebuilt (§19.9).
    func followIndexChange() {
        guard isPanelVisible, view.renderMode == .overview else {
            overviewRowsAwaitingIndex.removeAll()
            return
        }
        let build = host?.comparisonIndexBuild ?? 0
        guard build == overviewIndexBuildCount else {
            overviewIndexBuildCount = build
            overviewRowsAwaitingIndex.removeAll()
            scheduleOverviewRebuild()
            return
        }
        guard !overviewRowsAwaitingIndex.isEmpty else {
            scheduleOverviewRebuild()
            return
        }
        let ranges = overviewRowsAwaitingIndex
        overviewRowsAwaitingIndex.removeAll()
        for range in ranges { patchOverviewRows(covering: range) }
    }

    /// Centres the pane on the byte clicked on a map, moving the viewport
    /// without touching the caret or the selection — a minimap click navigates
    /// the view, it does not edit the caret's position. In comparison mode the
    /// click also makes that pane active, so the keyboard and the navigation
    /// commands act on the pane the user just pointed at.
    private func selectOffset(mapIndex: Int, offset: UInt64) {
        guard let pane = pane(at: mapIndex), pane.isOpen else { return }
        // Clicking the second map of a comparison also makes that pane active,
        // the way clicking its dump does. A surface with one pane has nothing
        // to point at.
        if panes().count > 1 { host?.activatePane(showingMapAt: mapIndex) }
        let views = paneViews()
        guard mapIndex < views.count else { return }
        views[mapIndex].revealOffsetCentered(offset)
    }

    /// The current name of the piece the strip's hover text names — asked for at
    /// hover time, not stored, because the store fires no invalidation for a
    /// rename (§21.3).
    private func segmentName(mapIndex: Int, pieceIndex: Int) -> String {
        guard let pane = pane(at: mapIndex), pane.isOpen,
              pieceIndex < pane.segmentStore.segments.count else { return "" }
        return pane.segmentStore.segments[pieceIndex].name
    }

    /// Scrolls the panes so `offset`'s hex row sits at the top of the pane —
    /// what the minimap's drag and wheel ask for. In comparison mode scrolling
    /// one pane syncs the other (§9), so driving the active pane is enough.
    private func scrollPanes(toOffset offset: UInt64) {
        let views = paneViews()
        // The active pane when it is one this surface shows — a comparison's
        // map scrolls the pane the reader is in — and otherwise the first,
        // which for a surface with one pane is that pane.
        // The pane the reader is in when this surface shows two, and its one
        // pane when it shows one.
        let active = surface.activeMapIndex()
        let target = active < views.count ? views[active] : views.first
        target?.scrollRowToTop(containing: offset)
    }

    /// Moves each map's selection overlay to its pane's current selection.
    /// Cheap (an overlay repaint), so it rides the caret-changed callbacks.
    func updateSelections() {
        let selections = panes().map { selectionRange($0) }
        for (index, selection) in selections.enumerated() {
            view.updateSelection(selection, forMapAt: index)
        }
    }

    private func selectionRange(_ pane: PaneViewModel) -> Range<UInt64>? {
        let selection = pane.hexSelection()
        guard !selection.isEmpty else { return nil }
        return selection.start..<selection.end
    }

    /// Wires a pane's viewport scrolls into the minimap: every visible-range
    /// change moves the grey viewport band and slides the map's own window,
    /// since the window is derived from the panes (§19).
    func track(_ pane: FilePaneView) {
        pane.onHexViewportChanged = { [weak self, weak pane] range in
            guard let self, let pane else { return }
            self.paneViewports[ObjectIdentifier(pane)] = range
            self.updateViewports()
        }
    }

    /// Forgets every pane's last visible range. Called when the panes are
    /// rebuilt and re-keyed, so a band cannot survive the pane it described.
    func clearViewports() {
        paneViewports.removeAll()
    }

    /// Moves each map's viewport band to its pane's visible byte range, which
    /// also re-derives the shared window. Cheap — no file pass — so it rides the
    /// scroll and resize notifications.
    func updateViewports() {
        view.setViewports(paneViews().map { paneViewports[ObjectIdentifier($0)] })
    }
}
