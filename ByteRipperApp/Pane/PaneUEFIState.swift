import Foundation
import UEFIImage
import MEFirmware
import MEReads
import ByteRipperCore

/// The one shared, lazily-materialized UEFI parse for this pane's open file,
/// plus MEA's own whole-region analysis cache — created on first request by
/// whichever tool-module asks first, torn down whenever the pane's content is
/// replaced wholesale.
///
/// Owned by `PaneViewModel` (`let uefiState = PaneUEFIState()`) so it lives
/// exactly as long as the file does — unlike `PaneToolHost`, which
/// `ToolController` tears down and rebuilds on every tool-module activation.
/// A `PaneToolHost` reaches this through its (weak) `pane` reference, which
/// is what lets a fresh host on every activation still hand a tool-module the
/// same tree/cache an earlier session already built.
///
/// `invalidate(_:)` is called from `PaneViewModel.signalEdit`, the one place
/// every edit already passes through — not from `ToolController`, which only
/// hears about edits while some tool-module session is bound to this pane.
/// The tree and cache have to survive the tool panel being on None, so their
/// invalidation cannot depend on one being open.
@MainActor final class PaneUEFIState {
    private(set) var tree: LazyUEFITree?
    /// Which rows the UEFI panel had open. Kept here rather than in the
    /// panel's parked state because it is about the *file*: the panel is built
    /// again on every activation, and this outlives it exactly as the tree
    /// does.
    var openUEFIRows: Set<NodeID> = []
    private var cachedAnalysis: FirmwareAnalysis?
    /// The byte range `cachedAnalysis` was computed for — an edit landing
    /// inside it is what drops the cache; one outside it leaves the analysis
    /// exactly as valid as it was.
    private var cachedAnalysisRegion: Range<UInt64>?
    /// The analysis being computed right now, if any, and the range it is being
    /// computed for. Two panels on one file ask for the same region in the same
    /// moment — the UEFI Structure opening it, the ME Analyzer re-parsing on the
    /// switch — and both would otherwise find the cache empty and read the whole
    /// region. The second ask awaits this instead.
    private var analysisInFlight: Task<Result<FirmwareAnalysis, Error>, Never>?
    private var analysisInFlightRegion: Range<UInt64>?
    /// Which in-flight analysis is the current one, so the starter of an
    /// abandoned one does not clear a newer ask's marker on its way out.
    private var analysisRun = 0
    /// Listening for a newer firmware database. Cancelled by `reset()`, and
    /// started when there is something for it to invalidate.
    private var databaseWatch: Task<Void, Never>?

    /// The tree, building it against `makeSource()` the first time anything
    /// asks. `makeSource` produces a *live* `ByteSource` — one that reads
    /// through to the document's actual storage rather than a frozen
    /// snapshot — so nothing here ever needs to hand the tree fresher bytes;
    /// `invalidate` only ever needs to say which memoized subtrees to forget.
    /// `layout` is what the bytes are when the pane holds a part of another
    /// file (`DocumentOrigin.layout`); it is read when the tree is built.
    func tree(makeSource: () -> any ByteSource, layout: UEFIRootLayout = .image) -> LazyUEFITree? {
        if let tree { return tree }
        let newTree = LazyUEFITree(makeSource(), layout: layout)
        tree = newTree
        return newTree
    }

    func cachedMEAnalysis() -> FirmwareAnalysis? {
        cachedAnalysis
    }

    func setCachedMEAnalysis(_ analysis: FirmwareAnalysis?, meRegion: Range<UInt64>?) {
        cachedAnalysis = analysis
        cachedAnalysisRegion = meRegion
        if analysis != nil { watchTheDatabase() }
    }

    /// The firmware database has been replaced. An analysis made against the old
    /// one describes a world that is gone — the identification, the names and
    /// the known-bad hashes all came out of that file — so the cache drops it.
    ///
    /// Which is a fact about the analysis, and is kept with it here rather than
    /// being a panel's errand: it used to be the ME Analyzer clearing this on its
    /// way past, so the panel that noticed was the one that happened to be
    /// running. Every panel now finds it gone, and any that has work of its own
    /// to do about the change still does it — the source fans out to every
    /// subscriber, so this takes the event from nobody.
    private func watchTheDatabase() {
        guard databaseWatch == nil else { return }
        let source = MEReads.dataSource
        databaseWatch = Task { [weak self] in
            for await _ in await source.databaseChanges() {
                guard let self else { return }
                self.cachedAnalysis = nil
                self.cachedAnalysisRegion = nil
            }
        }
    }

    /// The analysis for `meRegion`, with `analysing` run once however many
    /// callers ask at the same moment — the shape `FreshData.Freshened` gives
    /// the data source's own fetches, for the most expensive read the app makes.
    ///
    /// A caller that joins returns what the first computed; neither writes the
    /// cache, which is the caller's to do after its own guard.
    func meAnalysis(
        for meRegion: Range<UInt64>?,
        analysing: @escaping @MainActor () async -> Result<FirmwareAnalysis, Error>
    ) async -> Result<FirmwareAnalysis, Error> {
        if let cachedAnalysis { return .success(cachedAnalysis) }
        if let analysisInFlight, analysisInFlightRegion == meRegion {
            return await analysisInFlight.value
        }
        analysisRun += 1
        let run = analysisRun
        let task = Task { @MainActor in await analysing() }
        analysisInFlight = task
        analysisInFlightRegion = meRegion
        let result = await task.value
        // Only the ask that started it clears it: an edit inside the region may
        // have dropped this marker and a later ask put its own in its place.
        if analysisRun == run {
            analysisInFlight = nil
            analysisInFlightRegion = nil
        }
        return result
    }

    /// Narrows the tree's own stale subtrees, and drops the cached analysis
    /// when the edit falls inside (or, for a size-changing edit, at or after)
    /// the region it was computed for.
    func invalidate(_ edit: DiffEdit) {
        let range: Range<UInt64>
        let sizeDelta: Int64
        switch edit {
        case .overwrite(let editedRange):
            range = editedRange
            sizeDelta = 0
        case .insert(let at, let length):
            range = at..<(at &+ length)
            sizeDelta = Int64(length)
        case .delete(let editedRange):
            range = editedRange.lowerBound..<editedRange.lowerBound
            sizeDelta = -Int64(editedRange.count)
        }

        tree?.invalidate(editedRange: range, sizeDelta: sizeDelta)

        // Whether a whole-region read of `subject` is still a read of what the
        // file holds. A size-changing edit moves everything at or after it, so
        // only a region that ends before the edit survives; an overwrite is
        // local to the bytes it touched.
        func survives(_ subject: Range<UInt64>) -> Bool {
            sizeDelta == 0
                ? !subject.overlaps(range)
                : subject.upperBound <= range.lowerBound
        }

        if let cachedAnalysisRegion, !survives(cachedAnalysisRegion) {
            cachedAnalysis = nil
            self.cachedAnalysisRegion = nil
        }
        // The analysis in flight goes with it: what it is reading is no longer
        // what the file holds, so a panel asking again must not join it. Its own
        // caller drops the result — this only stops anyone new waiting on it.
        if let analysisInFlightRegion, !survives(analysisInFlightRegion) {
            analysisInFlight = nil
            self.analysisInFlightRegion = nil
        }
    }

    /// Drops the tree and the cached analysis entirely — a new file opened
    /// into this pane, a revert, a close: nothing about the old content is
    /// worth keeping.
    func reset() {
        tree = nil
        openUEFIRows = []
        cachedAnalysis = nil
        cachedAnalysisRegion = nil
        analysisInFlight = nil
        analysisInFlightRegion = nil
        databaseWatch?.cancel()
        databaseWatch = nil
    }
}
