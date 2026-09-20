import Foundation

/// What `MEAToolSession` reaches to get at the pane's own whole-region cache
/// of the last `FirmwareAnalysis`, without depending on the app that owns it.
///
/// Distinct from `UEFIImage.UEFITreeProviding` (defined in `UEFIImage`, not
/// here, since that type belongs to the UEFI tree): MEFirmware's own engine
/// has no partial/lazy re-scan of its own — a byte changed anywhere inside
/// the ME region invalidates the whole analysis, so the cache this protocol
/// reaches is whole-region granularity, not a tree of subtrees.
@MainActor
public protocol MEAAnalysisProviding: AnyObject {
    /// The pane's cached analysis, or nil if there is none (never analyzed
    /// yet, or invalidated by an edit inside the region it was computed for).
    func cachedMEAnalysis() -> FirmwareAnalysis?

    /// Records the result of a fresh analysis and the byte range it covered,
    /// so a later edit inside that range can drop it again.
    func setCachedMEAnalysis(_ analysis: FirmwareAnalysis?, meRegion: Range<UInt64>?)

    /// The analysis for `meRegion`: the cached one when there is one, else
    /// `analysing()` — run once however many panels ask for it at the same
    /// moment.
    ///
    /// Two panels on one file make the same ask in the same moment: the UEFI
    /// Structure opening the ME region, and the ME Analyzer re-parsing on the
    /// switch to it. What stands behind that ask is the largest read the app
    /// makes — a whole region, up to 16 MB — so the second ask joins the first
    /// rather than starting a second one. The data source dedupes its own
    /// fetches the same way (`FreshData.Freshened`); this is that, for the
    /// analysis.
    ///
    /// The caller writes the cache itself, after its own guard: a result an
    /// edit has since invalidated must not reach the cache, and only the caller
    /// knows that.
    func meAnalysis(
        for meRegion: Range<UInt64>?,
        analysing: @escaping @MainActor () async -> Result<FirmwareAnalysis, Error>
    ) async -> Result<FirmwareAnalysis, Error>
}
