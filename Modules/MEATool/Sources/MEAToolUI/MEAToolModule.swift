import AppKit
import MEFirmware
import MEATool
import MEPresentation
import MEReads
import ToolModuleKit
import UEFIImage

/// The "ME Analyzer" instrument: run `MEFirmware`'s analysis over the open
/// file and show the result — on the first tab the MEA-style summary, on the
/// second the full structure the module decoded
/// (`Design/ME_ANALYZER_PANEL.md`).
///
/// The panel is a reader, never a writer: it shows what the engine found and
/// never edits the file, so there is no Fix/repair half to it. The analysis is
/// automatic — every show of the panel and every change of the content re-parses
/// — and each parse runs off the main actor behind an indeterminate bar, because
/// `MEFirmwareAnalyzer.analyze` reports no fractions of its own.
public enum MEAToolModule: ToolModule {
    public static let identifier = "dev.maxik.tool.me-analyzer"
    public static let title = "ME Analyzer"
    /// Two columns — a name and a compact second line (range/count) — plus the
    /// detail list below: the same room the UEFI tree takes.
    public static let preferredPanelWidth: CGFloat = 480

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        MEAToolSession(host: host)
    }
}

/// What a parked session hands back: the tab the user was on and the tree row
/// they were looking at. The analysis is worth doing again — it is the module's
/// whole job, and it is automatic — so only the two choices are kept
/// (`ToolSession.parkedState`).
struct MEAParkedState: ToolSessionState {
    var tabIndex: Int
    var focusPath: [Int]?
}

/// The running instrument: read the file off the main actor, run the engine's
/// analysis in the background, show the curated tree, publish the one zone for
/// the row in focus, and keep nothing else.
@MainActor public final class MEAToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = MEAToolViewController()
    /// The one engine instance this session keeps: `MEFirmwareAnalyzer` holds
    /// the data source, whose in-memory single-flight cache of MEA.dat is what
    /// makes re-reading the same dump cheap.
    private let analyzer: MEFirmwareAnalyzer

    /// The presented tree of the last successful analysis — the outline's data.
    private var roots: [MEANode] = []

    /// Listening for a newer `MEA.dat`. Cancelled in `stop()`.
    private var databaseWatch: Task<Void, Never>?
    /// The analysis those roots were built from, kept so the one group the
    /// engine does not fill — the region's checksums — can be added to it
    /// later without a re-parse.
    private var analysis: FirmwareAnalysis?
    /// The in-flight checksum request, so selecting the row twice asks once.
    private var checksumsTask: Task<Void, Never>?
    /// The names an FTBL-mode volume's low-level files carry, once the table
    /// they come from has arrived. `.none` until then, and on every volume that
    /// names its own files (`MFSFileNames`).
    private var mfsNames: MFSFileNames = .none
    /// The names an EFS volume's files carry, from the same table. `.none`
    /// until it has arrived, and on a dump with no EFS partition
    /// (`EFSFileNames`).
    private var efsNames: EFSFileNames = .none
    /// What the files of an ID-keyed Configuration stream are called — the
    /// FITC partition's records, and a newer volume's own 6/7 streams. `.none`
    /// until the table has arrived (`ConfigRecordPaths`).
    private var configPaths: ConfigRecordPaths = .none
    /// The in-flight `FileTable.dat` request, so a re-present does not start a
    /// second one.
    private var fileTableTask: Task<Void, Never>?
    /// The user's selection as a tree path. Nil before a choice, and after a
    /// re-parse that lost the row.
    private var focusPath: [Int]?
    /// Which tab the panel is on (0 = Summary, 1 = Full Tree).
    private var tabIndex = 0
    /// Which parse is the current one. A file edited twice in quick succession
    /// starts two, and the one that finishes second is not necessarily the one
    /// that read the newer bytes.
    private var generation = 0

    /// Where the fresh firmware database comes from. A test installs its own so
    /// the suite does not reach GitHub — the same public seam as
    /// `FITToolSession.microcodeSource`, for the app-suite tests that live in
    /// another module and drive the session end to end.
    ///
    /// The storage is the shared reads' (`MEReads`), so this and the UEFI
    /// Structure's seam are one source and a test that installs one covers both
    /// panels. The name is kept because this is the one this module's tests and
    /// doc comments use.
    public static var dataSource: any MEADataSource {
        get { MEReads.dataSource }
        set { MEReads.dataSource = newValue }
    }

    /// Called on the main actor once a parse has landed and the panel has been
    /// shown. The analysis runs off the main actor, so a test that waited for it
    /// on the clock would be a test that fails on a busy machine.
    public var onDisplay: ((FirmwareAnalysis?) -> Void)?

    public init(host: any ToolHost) {
        self.host = host
        analyzer = MEFirmwareAnalyzer(data: Self.dataSource)
        controller.onSelect = { [weak self] path in self?.select(path) }
        controller.onTabChanged = { [weak self] tab in self?.selectTab(tab) }
        controller.onRetry = { [weak self] in self?.reparse() }
        // A copy is confirmed over the window rather than in the status row: it
        // is an answer about the whole panel, and the user is looking away from
        // the panel by then — at the place they are about to paste into. The
        // line is the panel's own button's words turned around, and the glyph is
        // that button's, so the plate is recognisably about the control that was
        // clicked (`ToolHost.showNotice`).
        controller.onSummaryCopied = { [weak self] in
            self?.host.showNotice(symbol: MEAToolViewController.copySummaryGlyph,
                                  lines: ["Summary Copied"])
        }
        controller.onScreenshotCopied = { [weak self] in
            self?.host.showNotice(symbol: MEAToolViewController.copyScreenshotGlyph,
                                  lines: ["Screenshot Copied"])
        }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        watchTheDatabase()
        reparse()
    }

    /// `MEA.dat` is re-checked once a day, behind whatever is being read at the
    /// time — so an analysis can be finished against a database that has since
    /// been superseded. When a newer one lands, the reading is done again
    /// against it: the identification, the SKU, the known-bad hashes all come
    /// out of that file, and an answer from last week's copy is exactly what
    /// the check was for.
    private func watchTheDatabase() {
        guard databaseWatch == nil else { return }
        let source = Self.dataSource
        databaseWatch = Task { [weak self] in
            for await _ in await source.databaseChanges() {
                guard let self else { return }
                // The pane's cached analysis was read against the database that
                // has just been replaced, and the pane's own holder drops it —
                // that is the cache's rule now rather than this panel's errand,
                // so that it holds for every panel and not only for the one that
                // happened to be running. What is left here is this panel's own
                // work: an answer from the old file is exactly what the check was
                // for, so the reading is done again, against the new database.
                self.reparse(ignoringCache: true)
            }
        }
    }

    /// Any change is a reason to read again. The analysis is cheap to rebuild
    /// and expensive to keep in sync, so a re-parse is the honest answer to
    /// every edit — and the selection is kept by path, so it survives a
    /// re-parse of the same file and is dropped when the row is gone.
    public func contentChanged(_ change: ToolContentChange) {
        reparse()
    }

    public func stop() {
        databaseWatch?.cancel()
        databaseWatch = nil
        fileTableTask?.cancel()
        fileTableTask = nil
    }

    public var parkedState: (any ToolSessionState)? {
        MEAParkedState(tabIndex: tabIndex, focusPath: focusPath)
    }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? MEAParkedState else { return }
        tabIndex = state.tabIndex
        focusPath = state.focusPath
    }

    // MARK: - Reading

    /// The last analysis's own cache and the tool's shared UEFI tree, reached
    /// through the host: neither is on the base `ToolHost` seam (which stays
    /// format-agnostic), so a tool-module that wants them casts for it, the
    /// same way it would ask for anything else beyond the seam's base
    /// contract. Nil under a host that offers neither (a test double) — the
    /// module falls back to its original, self-contained behavior.
    private var treeProvider: (any UEFITreeProviding)? { host as? any UEFITreeProviding }
    private var analysisProvider: (any MEAAnalysisProviding)? { host as? any MEAAnalysisProviding }

    /// Read the file and the region it names, analyse it, and present the
    /// result.
    ///
    /// `ignoringCache` is for the one caller that knows the cache is wrong: a
    /// firmware database that has just been replaced makes every analysis made
    /// against the old one a description of a world that is gone, and this
    /// panel's answer has to come from the new one. The pane's own holder drops
    /// that analysis on the same event — this is not a consequence of that, it
    /// is this panel not depending on which of the two arrives first.
    private func reparse(ignoringCache: Bool = false) {
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            roots = []
            focusPath = nil
            controller.showSummary([])
            controller.setPlaceholder(.failed)
            controller.say("Could not read the file: \(error)", asProblem: true)
            show()
            return
        }

        // The shared tree already knows the ME region's bounds from the
        // descriptor — a cheap lookup, not a scan — whether or not the UEFI
        // tool-module has ever been opened on this file. Handing it to the
        // engine replaces MEFirmware's own whole-file `$FPT` search with a
        // read of just those bytes.
        let meRegion = treeProvider?.uefiTree()?.region(.me)
        let analysisProvider = self.analysisProvider

        // A cached analysis survives a panel switch untouched: the pane's
        // holder only drops it when an edit actually lands inside the ME
        // region (`PaneUEFIState.invalidate`), so reactivating this
        // tool-module after using another one is instant rather than a
        // second full analysis of data nothing changed.
        if !ignoringCache, let cached = analysisProvider?.cachedMEAnalysis() {
            present(cached)
            // Announced on the next turn rather than from inside this call: a
            // caller that has only just asked for this session — `start()` runs
            // during activation — has had no chance to listen yet, and a cached
            // analysis would otherwise be the one reading it never hears about.
            Task { @MainActor [weak self] in self?.onDisplay?(cached) }
            return
        }

        generation += 1
        let generation = self.generation
        // Whatever the last analysis was, and whatever was being computed for
        // it, belongs to bytes that are no longer the ones on screen.
        checksumsTask?.cancel()
        checksumsTask = nil
        fileTableTask?.cancel()
        fileTableTask = nil
        // The names belong to the volume they were looked up for; a re-parse
        // may be of another file, or of one whose volume has just been edited.
        mfsNames = .none
        efsNames = .none
        configPaths = .none
        analysis = nil
        // Named, not just "Reading…": three panels can be the one on screen and
        // each reads something different, so the line says which this is.
        controller.say("Reading ME…")
        // The empty tab is the whole panel until the analysis lands, so it says
        // what is being waited for rather than promising a summary.
        controller.setPlaceholder(.waiting)
        controller.showBusy()
        let analyzer = self.analyzer
        Task { [weak self] in
            // The UEFI Structure opening the same region in the same moment
            // makes the same ask, so it goes through the pane's cache: one
            // reading, and whichever panel asked second is handed its answer.
            let result: Result<FirmwareAnalysis, Error>
            // A caller that knows the cache is wrong asks the engine directly.
            // The pane's `meAnalysis` is a cache first, and would hand back the
            // very analysis this re-reading exists to replace — whether or not
            // the pane's own watch has got round to dropping it yet.
            if let analysisProvider, !ignoringCache {
                result = await analysisProvider.meAnalysis(for: meRegion) {
                    await MEReads.analyze(snapshot, analyzer: analyzer, meRegion: meRegion)
                }
            } else {
                result = await MEReads.analyze(snapshot, analyzer: analyzer, meRegion: meRegion)
            }
            guard let self, self.generation == generation else { return }
            self.controller.endBusy()
            switch result {
            case .success(let analysis):
                // The reading is over — the line returns to empty, as the other
                // panels' do after a successful parse.
                self.controller.say("")
                analysisProvider?.setCachedMEAnalysis(analysis, meRegion: meRegion)
                self.present(analysis)
                self.onDisplay?(analysis)
            case .failure(let error):
                self.roots = []
                self.focusPath = nil
                self.controller.showSummary([])
                self.controller.setPlaceholder(.failed)
                self.controller.say(
                    MEReads.describe(error), asProblem: true)
                self.controller.showRetry(true)
                self.show()
                self.onDisplay?(nil)
            }
        }
    }

    /// A successful analysis lands here: present the summary and the curated
    /// tree and show them, keeping whatever selection still resolves after the
    /// re-parse.
    private func present(_ analysis: FirmwareAnalysis) {
        self.analysis = analysis
        roots = MEACurator.present(analysis, mfsNames: mfsNames, efsNames: efsNames,
                                   configPaths: configPaths)
        if let path = focusPath, MEATree.node(at: path, in: roots) == nil {
            focusPath = nil
        }
        controller.showRetry(false)
        // An analysis has landed — fresh or out of the cache — so nothing is
        // being waited for. If the summary is still empty it is because this
        // file has no ME firmware, which is what the empty tab now says.
        controller.setPlaceholder(.empty)
        controller.showSummary(MEASummary.build(analysis))
        show()
        loadFileNames()
    }

    /// Names the files of an FTBL-mode MFS volume (§ CSME 15/16), of the EFS
    /// volume beside it, and of the ID-keyed Configuration records either
    /// carries.
    ///
    /// Neither carries names at all: an MFS volume's FAT chains are numbered,
    /// an EFS volume's pages are one flat byte area, and both get their paths
    /// out of upstream's `FileTable.dat` — keyed by the platform and dictionary
    /// the *MFS* volume header names, which is why one fetch serves both. So
    /// this is the one reading the panel does *after* the analysis — like the
    /// checksums group, and for the same reason: it costs a fetch, and most
    /// dumps never need it (a legacy volume names its own files through the
    /// home directory).
    ///
    /// Silent on failure. Offline, rate-limited, or a table that does not
    /// describe this volume all leave the rows reading `File 63`, which is what
    /// the flash says about them — a panel that complained here would be
    /// reporting on an errand of its own, and the file inventory is complete
    /// without it.
    private func loadFileNames() {
        guard let analysis, fileTableTask == nil else { return }
        let volume = analysis.mfsVolume
        let wantsMFS = volume?.usesFTBL == true && volume?.files.isEmpty == false
            && mfsNames.resolution == nil
        let wantsEFS = analysis.efsVolume != nil && efsNames.resolution == nil
        // Every ID-keyed Configuration record in the analysis, wherever it came
        // from: the FITC partition's payload and a newer volume's own 6/7
        // streams are keyed into the same table.
        let configIDs = (analysis.oemConfiguration?.recordsByID ?? []).map(\.fileID)
            + (volume?.configurationsByID ?? []).flatMap { $0.records.map(\.fileID) }
        let wantsConfig = !configIDs.isEmpty && configPaths.resolution == nil
        guard wantsMFS || wantsEFS || wantsConfig else { return }
        let generation = self.generation
        fileTableTask = Task { [weak self] in
            let names = await MEReads.fileNames(
                mfs: wantsMFS ? volume : nil,
                efs: wantsEFS ? analysis.efsVolume : nil,
                configIDs: wantsConfig ? configIDs : [],
                platform: volume?.ftblPlatform ?? -1,
                dictionary: volume?.ftblDictionary ?? -1)
            guard let self, self.generation == generation else { return }
            self.fileTableTask = nil
            guard let names, let analysis = self.analysis else { return }
            self.mfsNames = names.mfs ?? self.mfsNames
            self.efsNames = names.efs ?? self.efsNames
            self.configPaths = names.config ?? self.configPaths
            // Re-presenting rebuilds the rows with the names in them; the
            // selection is kept by path, so the row the reader is looking at
            // stays where it is and simply gains its name.
            self.present(analysis)
            // The panel is showing this analysis — named now — which is what
            // `onDisplay` means, and the seam a test waits on.
            self.onDisplay?(analysis)
        }
    }

    /// Everything the panel shows, in one call.
    private func show() {
        let focus = focusPath.flatMap { MEATree.node(at: $0, in: roots) }
        controller.show(roots: roots, focusPath: focusPath, tab: tabIndex)
        host.publish(focus.map(MEAZones.build) ?? .empty)
    }

    // MARK: - What the panel asks for

    /// The user picked a row in the tree. Revealing is what moves the outline in
    /// the dump: a row that stands for bytes scrolls the dump to them.
    private func select(_ path: [Int]?) {
        focusPath = path
        if let node = path.flatMap({ MEATree.node(at: $0, in: roots) }),
           let range = node.range {
            host.reveal(range, select: false)
        }
        show()
        // Looking at the checksums row is what asks for the checksums: the
        // engine leaves them out of a parse because they are three passes over
        // the whole region, and until now nothing was going to read them.
        if let path, path == MEACurator.checksumsPath(in: roots) {
            loadChecksums()
        }
    }

    /// Compute the region's digests off the main actor and put them into the
    /// analysis the panel is showing. The bytes are read again rather than kept
    /// alive between parses — this path runs once per file, if at all, and a
    /// retained region would cost every open dump the memory for a row most
    /// readers never open.
    private func loadChecksums() {
        guard let analysis, analysis.checksums == nil, checksumsTask == nil,
              let snapshot = try? host.snapshot() else { return }
        let meRegion = treeProvider?.uefiTree()?.region(.me)
        let analysisProvider = self.analysisProvider
        let generation = self.generation
        checksumsTask = Task { [weak self] in
            let checksums = await MEReads.checksums(snapshot, meRegion: meRegion)
            guard let self, self.generation == generation else { return }
            self.checksumsTask = nil
            // The cache is read here rather than taken from this session's own
            // snapshot: the other panel may have put a fuller analysis there
            // while the digests were being computed, and writing this session's
            // copy back would undo it. Nothing awaits between this read and the
            // write below, so on the main actor the two are one step.
            guard let current = analysisProvider?.cachedMEAnalysis() ?? self.analysis,
                  current.checksums == nil else { return }
            var updated = current
            updated.checksums = checksums
            analysisProvider?.setCachedMEAnalysis(updated, meRegion: meRegion)
            // Re-presenting rebuilds the rows from the fuller analysis; the
            // selection is kept by path, so the row the reader is looking at
            // stays where it is and simply fills in.
            self.present(updated)
            // The panel is showing this analysis, which is what `onDisplay`
            // means — and it is the seam a test waits on instead of the clock.
            self.onDisplay?(updated)
        }
    }

    /// The user changed tab. Purely a choice of what to look at — the analysis
    /// is independent of it — but it is what a parked session hands back.
    private func selectTab(_ tab: Int) {
        tabIndex = tab
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the row it stands for to the front —
    /// which is the half only this side knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        let path = id.split(separator: "/").compactMap { Int($0) }
        guard !path.isEmpty, MEATree.node(at: path, in: roots) != nil else { return }
        focusPath = path
        show()
    }
}
