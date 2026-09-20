import AppKit
import MEFirmware
import MEPresentation
import MEReads
import ToolModuleKit
import UEFIContentSource
import UEFIImage
import UEFITool

/// The structure of a UEFI firmware image, read and shown
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// A bench opens a dump and wants to see what is in it — the volumes, the files
/// in them, the sections in those — and, for the one node it is looking at,
/// where it is and what its header says. It answers by reading, never by
/// assuming: the tree is the parser's, and the detail is the node's header read
/// back through the same reader.
public enum UEFIToolModule: ToolModule {
    public static let identifier = "dev.maxik.tool.uefi-structure"
    public static let title = "UEFI Structure"
    /// Three columns — name, type, subtype — and a list of label/value fields:
    /// the same room the FIT table takes, more than the minimap's 120.
    public static let preferredPanelWidth: CGFloat = 480

    /// How long a branch may take to be read before the row waiting on it says
    /// "Loading…". Under this the row simply opens when it is ready, and no
    /// placeholder is drawn at all — which is what keeps a fast branch from
    /// costing two animations over the same rows.
    ///
    /// Settable so a test can take the timing out of the picture and drive the
    /// slow path on demand.
    @MainActor public static var loadingRowDelay: TimeInterval = 0.2

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        UEFIToolSession(host: host)
    }
}

/// What a parked session hands back: the node the user was looking at, and
/// nothing else. The tree itself is the pane's, not the session's — parking
/// costs it nothing and reactivating finds it exactly as it was left
/// (`ToolSession.parkedState`).
struct UEFIParkedState: ToolSessionState {
    var focus: NodeID?
    /// The ME row the user was looking at, as its path under the ME region
    /// node. Kept apart from `focus` (a UEFI `NodeID`) because the two resolve
    /// against different trees, and only one is the active focus at a time.
    var meFocus: [Int]?
}

/// What one checksum pass hands back: for every node it read, the fields that
/// are wrong and the writes that would put them right — read together off the
/// main actor, because a pass reads every file body it covers and must never
/// run on show or in a table callback. The repairs are the half that makes a
/// wrong field say what it should be; the fields are the half the warning and
/// the icon key on.
///
/// A pass covers only the nodes that have just been materialized, never the
/// whole image: the tree grows a branch at a time, and each branch is read
/// once, as it appears.
private struct ChecksumPass: Sendable {
    let nodeRepairs: [NodeID: [ChecksumRepair]]
    let badChecksums: [NodeID: Set<UEFIChecksumField>]
}

/// The running instrument: read the pane's shared tree, show it, publish the
/// one zone for the node in focus, and say what that node is.
///
/// It never parses the image. Opening the panel yields the top level; a row
/// the reader opens materializes that one branch, off the main actor, with a
/// "Loading…" row in its place while it does; the address mapping is one
/// descent to the last node. Everything it materializes stays in the pane's
/// tree, so the next tool-module to want the same branch finds it open.
@MainActor public final class UEFIToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = UEFIToolViewController()

    /// The pane's one shared lazy tree — everything this panel shows is read
    /// through it: the outline's rows, the summary line, the detail's fields,
    /// and the mapping the Address row needs. Kept across every `show()`, and
    /// across every activation of this tool-module, so a panel switch costs
    /// nothing: whatever an earlier session (or MEA, or FIT) already opened is
    /// still open.
    private var tree: LazyUEFITree?
    /// Our subscription to that tree, so a branch someone else materialized
    /// reaches this panel's rows and its checksum pass too.
    private var observation: LazyUEFITree.ObserverToken?
    /// The tree this session built for itself, under a host that offers none —
    /// a test double. Dropped whenever the content changes, since it is over a
    /// frozen snapshot rather than the live file.
    private var ownTree: LazyUEFITree?

    /// Which nodes' checksums have been read so far, so each branch is read
    /// once as it appears rather than the whole image over again every time
    /// one more branch does.
    private var checkedIDs: Set<NodeID> = []
    /// How many checksum passes are running, and who is waiting for the last
    /// of them to land — what makes "the panel is showing this file" mean the
    /// flags on it are settled.
    private var checksumPassesInFlight = 0
    private var checksumWaiters: [() -> Void] = []
    /// Whether the mapping has been asked for since the last edit, so a second
    /// selection does not start a second descent to the Volume Top File.
    private var askedForAddresses = false
    /// Which nodes' checksums were found wrong, keyed by node id. Readable
    /// from outside so the app's tests can assert on it without reaching into
    /// a view.
    public private(set) var checksumProblems: [NodeID: Set<UEFIChecksumField>] = [:]
    /// The same passes' repairs, keyed by node id — what a wrong field should
    /// read, carried so the detail can quote it without re-reading the body.
    private var nodeRepairs: [NodeID: [ChecksumRepair]] = [:]
    /// The node the user is looking at. Nil before a choice, and after an edit
    /// that lost it.
    private var focus: NodeID?
    /// Which reading of the file is the current one. A file edited twice in
    /// quick succession has checksum passes in flight against both, and the
    /// one that finishes second is not necessarily the one that read the newer
    /// bytes.
    private var generation = 0
    /// The GUID catalogue the tree names are read from: empty until a fresh
    /// download lands, which then names the GUIDs for the rest of the session.
    /// A node with a GUID shows the GUID itself in the meantime.
    private var guids: GuidsCatalogue = .empty
    /// Which catalogue download is the current one, so a slow one does not
    /// overwrite a fresh one.
    private var guidsGeneration = 0

    // MARK: - The ME sub-tree

    /// The one engine instance this session keeps: `MEFirmwareAnalyzer` holds
    /// the data source, whose in-memory single-flight cache of MEA.dat is what
    /// makes re-reading the same dump cheap. The ME branch of the structure
    /// tree is built from its analysis, presented through the shared
    /// `MEPresentation` tree (`Design/ME_REGION_IN_UEFI_TREE_PLAN.md`).
    private let analyzer: MEFirmwareAnalyzer
    /// Where the fresh firmware database comes from. A test installs its own so
    /// the suite does not reach GitHub — the same public seam as
    /// `MEAToolSession.dataSource`, for the app-suite tests that drive this
    /// session end to end.
    ///
    /// The storage is the shared reads' (`MEReads`), so this and the ME
    /// Analyzer's seam are one source and a test that installs one covers both
    /// panels. The name is kept because this is the name this module's tests
    /// and doc comments use.
    static var dataSource: any MEADataSource {
        get { MEReads.dataSource }
        set { MEReads.dataSource = newValue }
    }
    /// The analysis the presented sub-tree was built from, kept so the lazy
    /// reads — the file names, the Checksums group's digests — can re-present
    /// the sub-tree from a fuller analysis once they land. Nil until the first
    /// analysis.
    private var meAnalysis: FirmwareAnalysis?
    /// The presented ME sub-tree of the last analysis — the rows the ME region
    /// node opens onto. Empty until the analysis has run (or was cached), which
    /// is why the region's row is shut on first paint.
    private var meRoots: [MEANode] = []
    /// The ME row the user is looking at, as its path under the ME region node.
    /// Kept apart from `focus` (a UEFI `NodeID`): the two resolve against
    /// different trees, and only one is the active focus at a time.
    private var meFocus: [Int]?
    /// The in-flight ME analysis. Cancelling it stops nothing — the reading runs
    /// detached — so it is kept for the identity a landing is judged by
    /// (`meRun`), not as a way to stop the work.
    private var meTask: Task<Void, Never>?
    /// Which analysis is the current one. `generation` catches a landing whose
    /// file has since been re-read; this catches one a later open has already
    /// superseded within the same reading. The newer analysis owns the panel's
    /// "Loading…" row and the sub-tree it will present, so the older landing
    /// must end neither.
    private var meRun = 0
    /// The region node whose "Loading…" row an in-flight analysis put up, so the
    /// one place that takes the row down knows which row it is ending. Nil when
    /// no row is up.
    private var meLoadingID: NodeID?
    /// The file names the ME sub-tree's rows are named with — the MFS volume's,
    /// the EFS volume's, and the ID-keyed Configuration records' — fetched from
    /// the firmware database the same way the ME Analyzer fetches them. The
    /// sub-tree is presented from these, so a re-present after a fetch fills the
    /// rows in with their names.
    private var meMfsNames: MFSFileNames = .none
    private var meEfsNames: EFSFileNames = .none
    private var meConfigPaths: ConfigRecordPaths = .none
    /// The in-flight file-name fetch, so a re-present asks once.
    private var meFileTableTask: Task<Void, Never>?
    /// Whether that fetch has been made for this reading, answered or not. A
    /// reading that could not reach the database — offline, rate-limited, a
    /// table that does not describe this volume — is not worth asking again:
    /// the answer would be the same, and each attempt costs the repository's
    /// own timeout while the reader waits behind it. Reset with the reading
    /// (`bind`), because a new analysis is a new question.
    private var askedForFileNames = false
    /// The in-flight digest computation for the Checksums group, so selecting
    /// the row twice asks once.
    private var meChecksumsTask: Task<Void, Never>?

    /// Listening for a newer `guids.csv`. Cancelled in `stop()`.
    private var guidsWatch: Task<Void, Never>?
    /// The protected ranges asked for, a moment after an edit. Cancelled by the
    /// next edit, and in `stop()`.
    private var rangesRequest: Task<Void, Never>?
    /// Whether the line under the tree is an answer to something the user asked
    /// for — a fix that wrote, or a refusal. Such a line survives the re-read
    /// its own write caused and is wiped by the next re-read that is not its
    /// own (the check in `bind()`).
    private var noticeAnswersTheUser = false

    /// Where the fresh catalogue comes from. A test installs its own so the
    /// suite does not reach GitHub.
    static var guidsSource: any GuidsSource = LongSoftGuidsRepository()

    /// Called on the main actor once the tree's top level is there and the
    /// panel has been shown. The build runs off the main actor, so a test that
    /// waited for it on the clock would be a test that fails on a busy
    /// machine. The image it is handed is the tree as materialized so far —
    /// the top level, plus whatever anything has since opened.
    public var onDisplay: ((UEFIImage?) -> Void)?

    /// Called on the main actor each time a checksum pass has landed and its
    /// findings are on screen. A branch's checksums are read after the branch
    /// itself arrives, so this is the seam a test waits on when what it is
    /// about is a flag rather than a row.
    public var onChecksums: (() -> Void)?

    public init(host: any ToolHost) {
        self.host = host
        self.analyzer = MEFirmwareAnalyzer(data: Self.dataSource)
        controller.onSelect = { [weak self] nodeID in self?.select(nodeID) }
        controller.onSelectTop = { [weak self] in self?.showTopNode() }
        controller.onRevealAtCaret = { [weak self] in self?.revealNodeAtCaret() }
        controller.onFixChecksum = { [weak self] nodeID in
            self?.fixChecksum(for: nodeID)
        }
        controller.onExportDecompressed = { [weak self] nodeID in
            self?.exportDecompressed(for: nodeID)
        }
        controller.onOpenDecompressed = { [weak self] nodeID in
            self?.openDecompressedInNewTab(for: nodeID)
        }
        controller.onOpenNode = { [weak self] nodeID, body in
            self?.openNodeInPanel(for: nodeID, body: body)
        }
        controller.onOpenRowsChanged = { [weak self] in self?.rememberOpenRows() }
        controller.onSelectME = { [weak self] path in self?.selectME(path) }
        controller.onOpenMERegion = { [weak self] id in self?.openMERegion(id) }
        controller.onMERegionLoading = { [weak self] id, loading in
            self?.meRegionLoading(id, loading: loading)
        }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        bind()
        refreshGuids()
        watchTheGuids()
    }

    /// `guids.csv` is re-checked once a day, behind whatever is being read at
    /// the time, so the names a tree is drawn with can be superseded while it
    /// is on screen. When that happens the tree is drawn again — the same thing
    /// `refreshGuids` does when the first download lands, and for the same
    /// reason: a better name is worth showing the moment it exists.
    private func watchTheGuids() {
        guard guidsWatch == nil else { return }
        let source = Self.guidsSource
        guidsWatch = Task { [weak self] in
            for await fresh in await source.guidsChanges() {
                guard let self else { return }
                self.guids = fresh
                self.show()
            }
        }
    }

    /// Any change is a reason to read again — but not to read the file again.
    /// The pane's tree has already been told which of its branches the edit
    /// made stale (`PaneUEFIState.invalidate`), so all this has to do is show
    /// what is left and let the reader re-open whatever they want back. The
    /// selection is kept by path, so it survives an edit that left its node
    /// where it was and is dropped when the node is gone.
    public func contentChanged(_ change: ToolContentChange) {
        // A tree of our own is over a frozen snapshot and cannot be told about
        // an edit; the shared one can, and was.
        ownTree = nil
        // An edit invalidates the pane's cached analysis when it lands inside
        // the ME region (`PaneUEFIState.invalidate`), and the sub-tree this
        // session presented from it goes with it either way.
        meRoots = []
        meFocus = nil
        meAnalysis = nil
        meMfsNames = .none
        meEfsNames = .none
        meConfigPaths = .none
        // Whatever the analysis was doing, its landing is not the current one
        // any more — the reading it was made from is gone. The row it put up is
        // the panel's, so it comes down here rather than waiting on a landing
        // that the generation guard below will drop.
        endMERegionLoading()
        meTask?.cancel()
        meTask = nil
        meFileTableTask?.cancel()
        meFileTableTask = nil
        meChecksumsTask?.cancel()
        meChecksumsTask = nil
        bind()
    }

    public func stop() {
        if let tree, let observation { tree.removeObserver(observation) }
        observation = nil
        guidsWatch?.cancel()
        guidsWatch = nil
        rangesRequest?.cancel()
        rangesRequest = nil
        // The ME reads are this session's own, and a parked panel is not going to
        // show what they find. The row an analysis put up goes with them: the
        // pane is not rebuilt on a restore, so a latch left here would still be
        // holding the region shut the next time the tool is brought back.
        endMERegionLoading()
        meTask?.cancel()
        meTask = nil
        meFileTableTask?.cancel()
        meFileTableTask = nil
        meChecksumsTask?.cancel()
        meChecksumsTask = nil
    }

    public var parkedState: (any ToolSessionState)? {
        UEFIParkedState(focus: focus, meFocus: meFocus)
    }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? UEFIParkedState else { return }
        focus = state.focus
        meFocus = state.meFocus
    }

    // MARK: - Reading

    /// The seam a UEFI-aware tool-module reaches through for the pane's one
    /// shared tree — the same protocol `MEATool` casts `host` for, defined in
    /// `UEFIImage` so neither side has to depend on the other or on the app.
    private var treeProvider: (any UEFITreeProviding)? { host as? any UEFITreeProviding }

    /// Points this session at the tree it should be reading, subscribes to it,
    /// and shows what it has.
    ///
    /// Nothing here parses. The shared tree is fetched — built, if this is the
    /// first thing to ask for it — and everything after that is on demand:
    /// the outline asks for a branch when a row is opened, the checksum pass
    /// reads a branch when one appears, and the mapping is worked out by
    /// walking to the last node rather than through the whole image. Opening
    /// this panel on a file another tool-module has already looked at costs
    /// one `show()`.
    private func bind() {
        // Re-subscribed unconditionally, even to the tree already in hand: a
        // session that was stopped and started again — parked and brought back
        // — dropped its subscription on the way out.
        if let tree, let observation { tree.removeObserver(observation) }
        observation = nil
        tree = currentTree()
        observation = tree?.addObserver { [weak self] change in
            self?.treeChanged(change)
        }

        generation += 1
        checkedIDs = []
        nodeRepairs = [:]
        checksumProblems = [:]
        // A new reading is a new sub-tree; the presented roots of the last one
        // mean nothing here, and neither do the names and digests the last
        // one's rows were filled with. The ME focus is kept — it may be a
        // parked selection this bind is restoring.
        meRoots = []
        meAnalysis = nil
        meMfsNames = .none
        meEfsNames = .none
        meConfigPaths = .none
        askedForFileNames = false
        meFileTableTask?.cancel()
        meFileTableTask = nil
        meChecksumsTask?.cancel()
        meChecksumsTask = nil

        guard let tree else {
            controller.endBusy()
            controller.say("Could not read the file.", asProblem: true)
            show(publish: true)
            return
        }

        // Only the top level of a chip dump with no descriptor costs a wait —
        // it is a signature scan of the whole file, and until it lands there
        // is nothing to draw. An Intel image is there before the bar is drawn.
        if !tree.isReady, !noticeAnswersTheUser {
            controller.say("Reading UEFI…")
            controller.showBusy()
        }
        show(publish: true, rowsChanged: true)

        tree.whenReady { [weak self] in
            guard let self, self.tree === tree else { return }
            self.controller.endBusy()
            if self.noticeAnswersTheUser {
                self.noticeAnswersTheUser = false
            } else {
                self.controller.say("")
            }
            // What the reader had open on this file, put back before anything
            // is announced — coming back to a panel and finding the tree shut
            // is coming back to a panel that forgot.
            self.controller.restoreOpenRows(self.treeProvider?.openUEFIRows() ?? [])
            // A parked ME focus is the sub-tree's half of the selection: run
            // the analysis (reusing the pane's cache) and open the region onto
            // it, so the row the reader was looking at is back on screen.
            if self.meFocus != nil, let regionID = self.meRegionID {
                self.openMERegion(regionID)
            }
            self.requestProtectedRanges(after: 0)
            // `onDisplay` means "the panel is showing this file": the top
            // level, and its own checksums read. A branch opened later brings
            // its own pass, announced through `onChecksums`.
            self.verifyNewChecksums {
                self.show(publish: true, rowsChanged: true)
                self.onDisplay?(self.currentImage)
            }
        }
    }

    /// The tree to read: the pane's shared one, or — under a host that offers
    /// none, which in practice means a test double — one of our own over a
    /// frozen snapshot, kept until the content changes.
    private func currentTree() -> LazyUEFITree? {
        if let shared = treeProvider?.uefiTree() { return shared }
        if let ownTree { return ownTree }
        guard let snapshot = try? host.snapshot() else { return nil }
        let tree = LazyUEFITree(ToolContentByteSource(reader: snapshot))
        ownTree = tree
        return tree
    }

    /// The tree grew, or was cut back. Either way the rows on screen are out
    /// of date, and a branch that has just appeared has checksums nobody has
    /// read yet.
    private func treeChanged(_ change: LazyUEFITree.Change) {
        switch change {
        case .built, .invalidated:
            if case .invalidated = change {
                generation += 1
                checkedIDs = []
                nodeRepairs = [:]
                checksumProblems = [:]
                askedForAddresses = false
                // Not on every keystroke: a reading opens every volume's files.
                requestProtectedRanges(after: 0.5)
            }
            verifyNewChecksums()
            show(publish: true, rowsChanged: true)
        case .expanded, .addressesResolved, .protectedRangesRead:
            // A branch appearing does not move the rows on screen: the panel
            // opens the row it was asked to open, itself, when the branch is
            // there. What changes here is what the rows *say*.
            verifyNewChecksums()
            show(rowsChanged: false)
        }
    }

    /// The protected ranges the rows are marked with
    /// (`BOOT_GUARD_PROTECTED_RANGES.md` §9.3), read by the tree off the main
    /// actor. When it lands the tree says so, and the rows are drawn again.
    private func requestProtectedRanges(after delay: TimeInterval) {
        rangesRequest?.cancel()
        guard let tree else { return }
        rangesRequest = Task { [weak self, weak tree] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, let tree, self.tree === tree else { return }
            tree.resolveProtectedRanges {}
        }
    }

    /// What the reader has open, written through to where the tree lives. It
    /// is about the file, not about this session: the panel is built again on
    /// every activation, and the branches are still read.
    private func rememberOpenRows() {
        treeProvider?.setOpenUEFIRows(controller.openRows)
    }

    /// The image as the tree has it right now — the top level plus whatever
    /// has been opened, with the mapping if it has been resolved.
    private var currentImage: UEFIImage? {
        guard let tree, tree.isReady else { return nil }
        return tree.image()
    }

    /// The catalogue download: in the background, so it never blocks a reading
    /// or the UI. On success it improves the names for the rest of the session
    /// and re-shows the tree with them; on failure the baseline the build ships
    /// stays, and the tree keeps the names it already shows. A download failure
    /// is not a problem worth saying in red — the names are still there, just
    /// older.
    private func refreshGuids() {
        guidsGeneration += 1
        let generation = guidsGeneration
        Task { [weak self] in
            do {
                let fresh = try await Self.guidsSource.guids()
                guard let self, self.guidsGeneration == generation else { return }
                self.guids = fresh
                self.show()
            } catch {
                // The baseline stays. Nothing to say: the tree is not wrong, it
                // is just not as up to date as it could be.
            }
        }
    }

    /// Reads the checksums of every node that has appeared since the last
    /// time, and of no others.
    ///
    /// A checksum pass reads whole file bodies, so it never runs on show or in
    /// a table callback — and, with a tree that grows a branch at a time, it
    /// never runs over the whole image either: each branch is read once, when
    /// it appears, and a reader who never opens a volume never pays for its
    /// files.
    private func verifyNewChecksums(then completion: (() -> Void)? = nil) {
        // A completion waits for every pass that is running, not only for the
        // one this call starts: the tree announces a new branch to its
        // observers before it answers whoever asked for it, so the pass over
        // that branch is already in flight by the time the asker gets here and
        // finds nothing left to read.
        if let completion { checksumWaiters.append(completion) }
        defer { if checksumPassesInFlight == 0 { drainChecksumWaiters() } }

        guard let tree, tree.isReady else { return }
        let image = tree.image()
        let candidates = image.allNodes.filter {
            $0.kind == .volume || $0.kind == .file || $0.kind == .microcode
        }
        let fresh = Set(candidates.map(\.id)).subtracting(checkedIDs)
        guard !fresh.isEmpty else { return }
        checkedIDs.formUnion(fresh)

        let readers = tree.spaceReaders
        let generation = self.generation
        checksumPassesInFlight += 1
        Task { [weak self] in
            let pass = await UEFIToolSession.checksums(in: image, only: fresh, readers: readers)
            guard let self else { return }
            self.checksumPassesInFlight -= 1
            defer { if self.checksumPassesInFlight == 0 { self.drainChecksumWaiters() } }
            guard self.generation == generation else { return }
            self.nodeRepairs.merge(pass.nodeRepairs) { _, new in new }
            self.checksumProblems.merge(pass.badChecksums) { _, new in new }
            self.show()
            self.onChecksums?()
        }
    }

    private func drainChecksumWaiters() {
        let waiting = checksumWaiters
        checksumWaiters.removeAll()
        for waiter in waiting { waiter() }
    }

    /// Off the main actor: the pass reads every file body it covers.
    private nonisolated static func checksums(
        in image: UEFIImage,
        only ids: Set<NodeID>,
        readers: SpaceReaders
    ) async -> ChecksumPass {
        await Task.detached(priority: .utility) {
            let nodeRepairs = UEFIChecksumCheck.repairs(in: image, only: ids, readers: readers)
            return ChecksumPass(
                nodeRepairs: nodeRepairs,
                badChecksums: UEFIChecksumCheck.fields(of: nodeRepairs, in: image)
            )
        }.value
    }

    /// Everything the panel shows, in one call: the tree, the detail for the
    /// node in focus, and — unless told not to — the one zone that node
    /// publishes. A reveal answers with the tree and nothing else: the dump is
    /// where the user is standing, so it shows without publishing, because a
    /// newly published focus would make the host scroll the dump to the node's
    /// start and away from the caret that asked.
    ///
    /// `rowsChanged` says whether the *set* of rows can have moved, which is
    /// what decides between rebuilding the table and re-rendering what is
    /// already in it (`UEFIToolViewController.show`).
    ///
    /// Publishing is off by default, and deliberately: most shows are redraws
    /// — a branch arriving, a checksum pass landing, the GUID catalogue —
    /// and republishing on one of those would move the dump under a reader who
    /// did nothing. Only a show that follows a change of focus, or a fresh
    /// reading of the file, says what the dump should be drawing.
    private func show(publish: Bool = false, rowsChanged: Bool = false) {
        guard let tree, tree.isReady else {
            controller.show(
                image: nil, tree: tree, focus: nil, detail: .empty, catalogue: guids,
                badChecksums: checksumProblems, canWrite: !host.isReadOnly,
                isBuilding: tree != nil, rowsChanged: true,
                meRoots: meRoots, meFocus: meFocus
            )
            if publish { host.publish(.empty) }
            return
        }
        // The mapping is asked for the first time a node is in focus, and not
        // before: it is the detail's Address row that wants it, and working it
        // out means opening the containers on the way to the Volume Top File.
        // A panel nobody has clicked in has no address to show and pays for
        // none. When it lands the tree says so, and this runs again.
        if focus != nil, !askedForAddresses, !tree.addressesResolved {
            askedForAddresses = true
            tree.resolveAddresses {}
        }
        let image = tree.image()
        let readers = tree.spaceReaders
        let node = focus.flatMap { image.node($0) }
        // The ME focus is the sub-tree's half of the selection, kept apart
        // from the UEFI focus, so at most one is in play. An ME row's detail
        // is the node's own curated fields; a UEFI node's is its header read
        // back through the node's own space.
        let meNode = meFocus.flatMap { MEATree.node(at: $0, in: meRoots) }
        let detail: UEFINodeDetail
        if let meNode {
            // An ME row's detail is its own curated fields. They render through
            // the UEFI detail's label/value rows; a field whose tone is a failed
            // check is the one worth the red the UEFI detail reserves for a bad
            // checksum. The full tone rendering (the green done-mark, the brown
            // caution) is the ME Analyzer's — this is the sub-tree's view of it.
            detail = UEFINodeDetail(
                title: meDetailTitle(of: meNode),
                fields: meNode.fields.map {
                    UEFIDetailField($0.label, $0.value, isProblem: $0.tone == .bad)
                },
                tables: []
            )
        } else {
            detail = node.map {
                // From the node's own space. A section on the way in that no
                // longer decodes leaves nothing to read, and the header fields
                // go with it rather than being read off the file at buffer
                // offsets.
                UEFIDetail.build(
                    for: $0, image: image,
                    reader: readers.reader(for: $0.space) ?? ImageReader([UInt8]()),
                    repairs: nodeRepairs[$0.id] ?? []
                )
            } ?? .empty
        }
        controller.show(
            image: image, tree: tree, focus: focus, detail: detail, catalogue: guids,
            badChecksums: checksumProblems, canWrite: !host.isReadOnly, isBuilding: false,
            rowsChanged: rowsChanged,
            meRoots: meRoots, meFocus: meFocus
        )
        if publish {
            // An ME focus zones the node's own byte range, the way the ME
            // Analyzer does; a UEFI focus zones the node as before. The two are
            // kept apart, so at most one is published.
            host.publish(meNode.map(MEAZones.build)
                         ?? UEFIPresenter.zones(for: node, in: image))
        }
    }

    // MARK: - What the panel asks for

    /// The user picked a node in the tree. Publishing again is what moves the
    /// outline in the dump, and the host brings a newly focused zone on screen
    /// by itself.
    private func select(_ nodeID: NodeID?) {
        focus = nodeID
        // A UEFI node and an ME row are two halves of one selection: picking a
        // node in the UEFI tree drops whatever ME row was in focus, and
        // `selectME` does the reverse.
        meFocus = nil
        show(publish: true)
    }

    /// The user picked a row of the ME sub-tree, or cleared it. The ME focus
    /// and the UEFI focus are kept apart, so picking an ME row drops the UEFI
    /// focus. A row that stands for bytes reveals them the way a UEFI node's
    /// does; a row that is only a summary of its children has nothing to
    /// reveal and says nothing in the dump.
    private func selectME(_ path: [Int]?) {
        meFocus = path
        focus = nil
        show(publish: true)
        // Looking at the checksums row is what asks for the checksums: the
        // engine leaves them out of a parse because they are three passes over
        // the whole region, and until now nothing was going to read them.
        if let path, path == MEACurator.checksumsPath(in: meRoots) {
            loadChecksums()
        }
    }

    // MARK: - The ME sub-tree

    /// The id of the ME region node in the tree, when there is one — the graft
    /// point the ME sub-tree opens under. Nil for a file with no ME region.
    ///
    /// A walk that stops at the first match rather than `image.allNodes`, which
    /// builds a fresh array for every node it has — and, because `flattened`
    /// rebuilds each subtree on the way out, copies a node once per level above
    /// it. The ME region is a sibling of the descriptor near the top of the
    /// tree, so this looks at a handful of nodes where that walked the image.
    private var meRegionID: NodeID? {
        guard let image = currentImage else { return nil }
        func find(in nodes: [UEFINode]) -> NodeID? {
            for node in nodes where node.kind == .region
                && node.subtype == UInt8(FlashRegionType.me.rawValue) {
                return node.id
            }
            for node in nodes {
                if let found = find(in: node.children) { return found }
            }
            return nil
        }
        return find(in: image.roots)
    }

    /// The pane's own whole-region cache of the last `FirmwareAnalysis`, reached
    /// through the host: the same seam `MEATool` casts for, so the UEFI
    /// Structure and the ME Analyzer share one analysis rather than each
    /// re-reading the region. Nil under a host that offers none (a test double).
    private var analysisProvider: (any MEAAnalysisProviding)? { host as? any MEAAnalysisProviding }

    /// The ME region node was opened: run the ME analysis (reusing the pane's
    /// cache) and, once the sub-tree is presented, open the region row onto it,
    /// settling on `settlingOn` when it resolves. The node is not expandable in
    /// the UEFI tree, so this is the only thing that opens it.
    private func openMERegion(_ id: NodeID, settlingOn path: [Int]? = nil) {
        runMEAnalysis(id) { [weak self] in
            self?.controller.openMERegion(id, settlingOn: path)
        }
    }

    /// A reveal that stopped at the ME region: the rows that could place the
    /// caret are not presented yet, so the region is opened for it — the panel's
    /// own open, its "Loading…" row and all, because that is what opening a
    /// region is — and the reveal lands on the row that owns the byte once the
    /// sub-tree is there.
    private func openMERegionForReveal(_ id: NodeID, at offset: UInt64) {
        runMEAnalysis(id) { [weak self] in
            guard let self else { return }
            self.controller.openMERegion(id, settlingOn: self.mePath(covering: offset))
        } onFailure: { [weak self] in
            // The sub-tree is not coming, so the region node is the nearest
            // thing above the caret the panel can still show. It covers the
            // caret — that is how the reveal got here — so landing on it is the
            // same answer one level up. Why it failed has already been said.
            self?.showUEFIFocus(id)
        }
    }

    /// Read the ME region and run the engine's analysis over it, reusing the
    /// pane's cached analysis when the ME Analyzer has already fetched it, and
    /// present the sub-tree when it lands. The reading runs off the main actor
    /// behind an indeterminate bar, because `MEFirmwareAnalyzer.analyze`
    /// reports no fractions of its own.
    ///
    /// `id` is the region node the panel opened: while a fresh analysis runs,
    /// the panel shows a "Loading…" row for it, the way a slow UEFI branch
    /// does, and the start and finish are signalled through
    /// `controller.onMERegionLoading`. A cached analysis is instant, so it is
    /// presented and opened with no placeholder in between.
    ///
    /// `onFailure` is for a caller with something to fall back on: the sub-tree
    /// is not coming, and the region node is where it can still land. A landing
    /// that a re-read or a later open superseded does not call it — that is not
    /// a failure, and the newer analysis owns the outcome.
    private func runMEAnalysis(
        _ id: NodeID,
        then completion: @escaping @MainActor () -> Void,
        onFailure failed: (@MainActor () -> Void)? = nil
    ) {
        guard let snapshot = try? host.snapshot() else {
            controller.say("Could not read the file.", asProblem: true)
            // The panel holds the region's row shut on the open that brought us
            // here, and has its "Loading…" clock on it besides. Nothing is going
            // to land, so the open is over and the row is released.
            controller.onMERegionLoading?(id, false)
            failed?()
            return
        }
        let meRegion = treeProvider?.uefiTree()?.region(.me)
        let provider = analysisProvider
        // A cached analysis is instant: the pane's holder only drops it when an
        // edit lands inside the region, so a re-open is a re-present, not a
        // second full analysis of data nothing changed. The "Loading…" clock the
        // panel started on the open is stopped here, or its placeholder task
        // would fire a moment later and put a row up for an analysis that is
        // already in hand.
        if let cached = provider?.cachedMEAnalysis() {
            presentME(cached)
            controller.onMERegionLoading?(id, false)
            completion()
            return
        }
        meTask?.cancel()
        meRun += 1
        let run = meRun
        let generation = self.generation
        let analyzer = self.analyzer
        controller.say("Reading ME…")
        controller.showBusy()
        // The analysis is about to run: the region's row earns a "Loading…" row
        // if it is slow enough, the way a UEFI branch does.
        controller.onMERegionLoading?(id, true)
        meLoadingID = id
        meTask = Task { [weak self] in
            // Two panels on one file ask for this region in the same moment —
            // this open, and the ME Analyzer re-parsing on a switch to it — so
            // the ask goes through the pane's cache, which runs it once and
            // hands the second caller the same answer rather than reading the
            // region a second time.
            let result: Result<FirmwareAnalysis, Error>
            if let provider {
                result = await provider.meAnalysis(for: meRegion) {
                    await MEReads.analyze(snapshot, analyzer: analyzer, meRegion: meRegion)
                }
            } else {
                result = await MEReads.analyze(snapshot, analyzer: analyzer, meRegion: meRegion)
            }
            guard let self else { return }
            // Two ways a landing is not the current one, and neither may touch
            // the panel. A re-read has replaced the file this analysis was made
            // from, and the row went with it (`contentChanged`). A later open
            // has superseded it, and that analysis owns the row now — ending it
            // from here would take down a "Loading…" that is still true.
            guard self.generation == generation, self.meRun == run else { return }
            self.meTask = nil
            self.endMERegionLoading()
            self.controller.endBusy()
            switch result {
            case .success(let analysis):
                self.controller.say("")
                provider?.setCachedMEAnalysis(analysis, meRegion: meRegion)
                self.presentME(analysis)
                completion()
            case .failure(let error):
                self.controller.say(MEReads.describe(error), asProblem: true)
                failed?()
            }
        }
    }

    /// A successful analysis lands here: present the curated sub-tree and show
    /// it, keeping whatever ME selection still resolves after the re-parse.
    private func presentME(_ analysis: FirmwareAnalysis) {
        meAnalysis = analysis
        // What the sub-tree held before this presentation, by path. A
        // re-presentation that follows a fetch changes what the rows *say* —
        // a file gains its name, a digest appears — and the outline only has to
        // redraw their cells for that. One that changes which rows there are
        // needs the outline to ask for the children again, or a row that left
        // the tree stays on screen: the Checksums group goes when the digests
        // come back with nothing in them, and it used to keep its row anyway.
        let rowsBefore = Self.meRowPaths(meRoots)
        meRoots = MEACurator.present(analysis, mfsNames: meMfsNames, efsNames: meEfsNames,
                                     configPaths: meConfigPaths)
        if let path = meFocus, MEATree.node(at: path, in: meRoots) == nil {
            meFocus = nil
        }
        show(publish: meFocus != nil, rowsChanged: rowsBefore != Self.meRowPaths(meRoots))
        // The sub-tree is on screen; the file names it still lacks are fetched
        // behind it, the way the ME Analyzer fetches them, and re-present the
        // rows with their names when they land.
        loadFileNames()
    }

    /// Takes the region's "Loading…" row down, if one is up. Only a landing that
    /// still owns the row reaches here (`meRun`), or `contentChanged`, where the
    /// reading the row stood for is gone. The row is the panel's, so the panel
    /// is what is told — and telling it twice is what the id being cleared first
    /// rules out.
    private func endMERegionLoading() {
        guard let id = meLoadingID else { return }
        meLoadingID = nil
        controller.onMERegionLoading?(id, false)
    }

    /// The region's analysis started or finished: forward it to the panel,
    /// which shows a "Loading…" row for the region while a fresh analysis runs
    /// and opens the row onto the sub-tree when it lands.
    private func meRegionLoading(_ id: NodeID, loading: Bool) {
        if loading {
            controller.meRegionOpening(id)
        } else {
            controller.meRegionLoading(id)
        }
    }

    /// Names the files of an FTBL-mode MFS volume, of the EFS volume beside it,
    /// and of the ID-keyed Configuration records either carries — the same
    /// reading the ME Analyzer makes after an analysis, and for the same reason:
    /// it costs a fetch, and most dumps never need it. The sub-tree is
    /// re-presented with the names when they land, so a row that read `File 63`
    /// gains its name in place. Silent on failure: offline, rate-limited, or a
    /// table that does not describe this volume all leave the rows reading their
    /// numbers, which is what the flash says about them.
    private func loadFileNames() {
        guard let analysis = meAnalysis, meFileTableTask == nil,
              !askedForFileNames else { return }
        let volume = analysis.mfsVolume
        let wantsMFS = volume?.usesFTBL == true && volume?.files.isEmpty == false
            && meMfsNames.resolution == nil
        let wantsEFS = analysis.efsVolume != nil && meEfsNames.resolution == nil
        // Every ID-keyed Configuration record in the analysis, wherever it came
        // from: the FITC partition's payload and a newer volume's own 6/7
        // streams are keyed into the same table.
        let configIDs = (analysis.oemConfiguration?.recordsByID ?? []).map(\.fileID)
            + (volume?.configurationsByID ?? []).flatMap { $0.records.map(\.fileID) }
        let wantsConfig = !configIDs.isEmpty && meConfigPaths.resolution == nil
        guard wantsMFS || wantsEFS || wantsConfig else { return }
        // Asked, whatever comes back: this is the one attempt for this reading.
        askedForFileNames = true
        let generation = self.generation
        meFileTableTask = Task { [weak self] in
            let names = await MEReads.fileNames(
                mfs: wantsMFS ? volume : nil,
                efs: wantsEFS ? analysis.efsVolume : nil,
                configIDs: wantsConfig ? configIDs : [],
                platform: volume?.ftblPlatform ?? -1,
                dictionary: volume?.ftblDictionary ?? -1)
            guard let self, self.generation == generation else { return }
            self.meFileTableTask = nil
            guard let names, let analysis = self.meAnalysis else { return }
            self.meMfsNames = names.mfs ?? self.meMfsNames
            self.meEfsNames = names.efs ?? self.meEfsNames
            self.meConfigPaths = names.config ?? self.meConfigPaths
            self.presentME(analysis)
        }
    }

    /// Compute the region's digests off the main actor and put them into the
    /// analysis the sub-tree was built from. The Checksums group is the one
    /// whose values `analyze` leaves out — three passes over the whole region
    /// for three rows — so looking at it is what asks for them, the way the ME
    /// Analyzer asks. The bytes are read again rather than kept alive between
    /// parses: this path runs once per file, if at all.
    private func loadChecksums() {
        guard let analysis = meAnalysis, analysis.checksums == nil,
              meChecksumsTask == nil, let snapshot = try? host.snapshot() else { return }
        let meRegion = treeProvider?.uefiTree()?.region(.me)
        let analysisProvider = self.analysisProvider
        let generation = self.generation
        meChecksumsTask = Task { [weak self] in
            let checksums = await MEReads.checksums(snapshot, meRegion: meRegion)
            guard let self, self.generation == generation else { return }
            self.meChecksumsTask = nil
            // The cache is read here rather than taken from this session's own
            // snapshot: the other panel may have put a fuller analysis there
            // while the digests were being computed, and writing this session's
            // copy back would undo it. Nothing awaits between this read and the
            // write below, so on the main actor the two are one step.
            guard let current = analysisProvider?.cachedMEAnalysis() ?? self.meAnalysis,
                  current.checksums == nil else { return }
            var updated = current
            updated.checksums = checksums
            analysisProvider?.setCachedMEAnalysis(updated, meRegion: meRegion)
            self.presentME(updated)
        }
    }

    /// The title names the image, not a row: the one root the tree folded into
    /// it is selected by a click exactly as its row would — its zone, its
    /// detail. A file with nothing folded into the title — one with several
    /// roots, or a single leaf — has nothing to select, so it does nothing
    /// rather than clear a focus the user set.
    ///
    /// Public because a click on the title is driven the same way the panel's
    /// other clicks are — through the session, not a simulated mouse.
    public func showTopNode() {
        guard let image = currentImage,
              let title = UEFITreeDisplay.present(image).title
        else { return }
        focus = title.id
        // The two focuses are halves of one selection, so a UEFI focus drops
        // whatever ME row was in focus — the same thing `select` and
        // `zoneSelected` do. Kept, it would win in `refreshTheOutline` and this
        // click would read as broken.
        meFocus = nil
        show(publish: true)
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the node it stands for to the front —
    /// expand the tree to it and select it, which is the half only this side
    /// knows how to do.
    ///
    /// The zone on screen belongs to whichever focus is active. An ME focus and
    /// a UEFI focus are kept apart, so the id is routed by which one is set —
    /// not by the id's shape, which a one-level ME path ("0") and a UEFI node
    /// ("0") cannot tell apart.
    public func zoneSelected(_ id: Zone.ID) {
        if meFocus != nil {
            let path = id.split(separator: "/").compactMap { Int($0) }
            guard !path.isEmpty, MEATree.node(at: path, in: meRoots) != nil else { return }
            selectME(path)
            return
        }
        guard let nodeID = UEFIPresenter.nodeID(ofZone: id) else { return }
        focus = nodeID
        meFocus = nil
        show(publish: true)
    }

    /// The node the caret in the dump stands in, shown in the tree: expanded,
    /// its row selected, its detail up. The offset is where the user is
    /// pointing — the start of a selection when there is one, else the caret —
    /// and the innermost node whose range covers it is the one that owns the
    /// byte.
    ///
    /// A byte of the ME region is owned by a row of the ME sub-tree, which the
    /// UEFI walk cannot see: its rows are `MEANode`s presented under the region
    /// rather than parsed into the tree, so the deepest node the walk finds
    /// inside the region is the region itself. The sub-tree is asked first, and
    /// a region it has not been given yet is opened for the reveal rather than
    /// answered for by the node above it.
    ///
    /// The dump is where the user is standing, so nothing a reveal does moves
    /// it. That is also why a reveal that moves off an ME row clears the zone
    /// map rather than republishing: the zones on screen belong to the tree just
    /// left, and a zone click after it would route by a focus that is no longer
    /// set — while drawing the new node's own zone would scroll the dump to the
    /// start of it.
    ///
    /// Public because a click on the title-row button is driven the same way
    /// the panel's other clicks are — through the session, not a simulated
    /// mouse.
    public func revealNodeAtCaret() {
        let offset = host.selection?.lowerBound ?? host.caret
        guard let tree, tree.isReady else { return }
        // The ME half first, because the walk below has never heard of it. The
        // two halves route by the same rule `zoneSelected` uses.
        if let path = mePath(covering: offset) {
            selectME(path)
            return
        }
        // The presented sub-tree placed the byte in no row of its own — or there
        // is no sub-tree yet, and the rows that could place it do not exist.
        // Only the second is worth opening a region for: the first has answered,
        // and the region node is that answer.
        if meRoots.isEmpty, let id = meRegionID,
           currentImage?.node(id)?.fileRange?.contains(offset) == true {
            openMERegionForReveal(id, at: offset)
            return
        }
        // The one place that asks the tree for an *offset* rather than for a
        // row, so it is also the one that has to open the branches on the way
        // to it: the node under the caret may sit inside a volume nobody has
        // read yet, and a tree that has not read it has nothing to reveal.
        //
        // Which means this answers later, and can take as long as opening that
        // branch does. The bar says so for the whole of it — a button that
        // answers a moment later and says nothing in between is a button the
        // reader takes for broken and presses again.
        controller.showBusy()
        tree.materialize(containing: offset) { [weak self] chain in
            guard let self else { return }
            self.controller.endBusy()
            guard let node = chain.last else { return }
            self.showUEFIFocus(node.id)
        }
    }

    /// Makes `id` the UEFI focus and shows it, dropping the ME half with it: the
    /// two are halves of one selection, so only one is ever set — an ME focus
    /// kept here would win in `refreshTheOutline` and the reveal would land
    /// nowhere.
    ///
    /// When there was an ME focus to cross from, the zones on screen belong to
    /// the tree just left, so they go — replaced by nothing rather than by the
    /// new node's own zone. Publishing a zone is what makes the host bring it on
    /// screen, and what it brings is the *start* of it
    /// (`FilePaneView.revealOffsetIfOffScreen`): for a node the caret sits deep
    /// inside, that is a scroll away from the byte the reveal was asked about,
    /// which is the one thing this gesture may not do. An empty map clears the
    /// stale zones and moves nothing — the host's scroll follows a focus, and an
    /// empty map has none.
    private func showUEFIFocus(_ id: NodeID) {
        let crossedHalves = meFocus != nil
        focus = id
        meFocus = nil
        show()
        if crossedHalves { host.publish(.empty) }
    }

    /// What names an ME row in the detail: its title, and — when the row has
    /// nothing else to say — the subtitle it carries.
    ///
    /// A row that stands for bytes already answers this in the fields under the
    /// heading (`Offset`, `Size`), and a heading repeating them would say it
    /// twice. A group carries no fields at all, so its heading is the whole of
    /// what the detail can say about it: without the subtitle a count like
    /// "17 regions" would be nowhere in the panel.
    ///
    /// This is the one place the subtitle can land. The ME Analyzer keeps it in
    /// a Summary column of its own, 150 points wide; this panel's tree has no
    /// column for it — the two beside the name are a UEFI node's kind and
    /// subtype, which an ME row is neither — and borrowing one would either
    /// squeeze a hex range past reading in 69 points or take the width off the
    /// Name column, where a UEFI row's GUID lives.
    private func meDetailTitle(of node: MEANode) -> String {
        guard node.fields.isEmpty, !node.subtitle.isEmpty else { return node.title }
        return "\(node.title) · \(node.subtitle)"
    }

    /// Every path a presentation holds, in order — the shape of the sub-tree,
    /// with what its rows say left out. A path is a node's position, so two
    /// presentations agree here exactly when they hold the same rows.
    private static func meRowPaths(_ nodes: [MEANode]) -> [[Int]] {
        nodes.flatMap { [$0.path] + meRowPaths($0.children) }
    }

    /// The path of the innermost presented ME row whose range covers `offset`,
    /// or nil when the offset falls in none of them. A row that stands for no
    /// bytes — the identity, a group — is descended through rather than
    /// answered with, the same way `MEAZones` refuses to zone one.
    private func mePath(covering offset: UInt64) -> [Int]? {
        func innermost(_ nodes: [MEANode]) -> [Int]? {
            for node in nodes {
                if let deeper = innermost(node.children) { return deeper }
                if node.range?.contains(offset) == true { return node.path }
            }
            return nil
        }
        return innermost(meRoots)
    }

    // MARK: - Fix Checksum

    /// Recompute a node's checksum and write the corrected bytes as one
    /// undoable step. A read-only file refuses; otherwise the node's current
    /// bytes are re-read off the main actor — they may have changed since the
    /// pass that flagged them — and whatever still differs is applied, ⌘Z
    /// taking it back. The write invalidates the branch it landed in, which
    /// clears the red flag and the icon on their own, so the "written" line
    /// survives exactly that one re-read.
    ///
    /// The node comes from the tree rather than from a parse of its own: it is
    /// already materialized — the row the click was on is on screen — and the
    /// only thing left to read is the handful of bytes its checksum covers.
    ///
    /// Public because a right-click cannot be simulated — this is the level the
    /// app's tests drive, the same way FIT's `fixChecksum()` is.
    public func fixChecksum(for nodeID: NodeID) {
        guard !host.isReadOnly else {
            fail("This file is open read-only.")
            return
        }
        guard let tree, tree.isReady, let image = currentImage,
              let node = image.node(nodeID)
        else {
            fail("Could not read the file.")
            return
        }
        // The file holds these bytes compressed. The repair is an offset into
        // a buffer, and writing it would mean compressing the section again —
        // which this panel does not do (`COMPRESSED_SECTIONS.md` §7).
        guard node.space == .file else {
            fail("This checksum is inside a compressed section, which the file holds compressed.")
            return
        }
        let revision = UEFIChecksumCheck.volumeRevision(of: node, in: image)
        let reader = tree.imageReader
        controller.showBusy()
        Task { [weak self] in
            let repairs = await UEFIToolSession.prepareChecksumFix(
                node, volumeRevision: revision, reader: reader
            )
            guard let self else { return }
            self.controller.endBusy()
            guard let repairs, !repairs.isEmpty else {
                // Nothing to write: its checksum already checks out — the flag
                // the click answered was a stale one.
                return
            }
            let transaction = ToolTransaction(
                name: "Fix Checksum",
                writes: repairs.map {
                    ToolTransaction.Write(offset: $0.offset, bytes: $0.bytes)
                }
            )
            do {
                try self.host.apply(transaction)
                self.noticeAnswersTheUser = true
                self.controller.say("Checksum written. ⌘Z takes it back.")
            } catch {
                self.fail("Could not write: \(error)")
            }
        }
    }

    /// Re-read the node's bytes off the main actor and return the writes that
    /// put its checksum right, or nil when it already checks out.
    private nonisolated static func prepareChecksumFix(
        _ node: UEFINode,
        volumeRevision: UInt8?,
        reader: ImageReader
    ) async -> [ChecksumRepair]? {
        await Task.detached(priority: .userInitiated) {
            let repairs = UEFIChecksumCheck.repairs(
                for: node, volumeRevision: volumeRevision, in: reader
            )
            return repairs.isEmpty ? nil : repairs
        }.value
    }

    // MARK: - Export

    /// Saves what a compressed section decompressed to — or one node's bytes
    /// from inside it — to a file the user picks (`COMPRESSED_SECTIONS.md`
    /// §8.2). The buffer is read off the main actor: it may have to be decoded
    /// again, and it is megabytes.
    ///
    /// Public because a right-click cannot be simulated — the level the app's
    /// tests drive, like `fixChecksum(for:)`.
    public func exportDecompressed(for nodeID: NodeID) {
        withDecompressedBytes(of: nodeID, nothing: "There is nothing decompressed to export here.") {
            [weak self] export, bytes in
            guard let self,
                  await self.host.exportFile(bytes, suggestedName: export.suggestedName)
            else { return }
            self.noticeAnswersTheUser = true
            self.controller.say("Exported \(bytes.count) bytes.")
        }
    }

    /// Opens the same bytes the export saves in a tab of their own, so the
    /// reader studies a decompressed body as a file — its own offsets from
    /// zero, the hex view's search and zones — without saving it first.
    ///
    /// Public for the same reason as `exportDecompressed(for:)`.
    public func openDecompressedInNewTab(for nodeID: NodeID) {
        // What the tab is linked to, and what its bytes are: a whole body is a
        // run of sections; one node's bytes are that node.
        var layout = UEFIRootLayout.image
        var source: Range<UInt64>?
        if let tree, tree.isReady {
            let image = tree.image()
            if let node = image.node(nodeID), let export = UEFIPresenter.decompressedExport(for: node) {
                layout = export.range == nil ? .decompressedBody : UEFIRootLayout.of(node, in: image)
                source = UEFIPresenter.fileSource(of: node, in: image)
            }
        }
        let chosenLayout = layout
        let chosenSource = source
        withDecompressedBytes(of: nodeID, nothing: "There is nothing decompressed to open here.") {
            [weak self] export, bytes in
            guard let self, let source = chosenSource else { return }
            let name = export.tabName(fileName: self.host.fileName)
            if let provider = self.treeProvider {
                // Where the bytes go back to: the whole buffer, or this node's
                // bytes in it (`UPDATE_IN_PARENT.md` §6).
                provider.openPart(bytes, named: name, linkedTo: source, layout: chosenLayout,
                                      part: UEFIRebuild.Target(space: export.space, range: export.range))
            } else {
                self.host.openPart(bytes, named: name, linkedTo: source)
            }
        }
    }

    /// Opens a node of the tree — or its body alone — as a panel of its own, so
    /// the reader studies a part of the image as a file: its own offsets from
    /// zero, its own search, its own tree (`Design/FRAGMENT_PANELS_PLAN.md`).
    ///
    /// Works wherever the node lives. Bytes of the file go across as they are
    /// and go back as they are; bytes of a buffer a compressed section opened
    /// to are linked to that section and go back through it.
    ///
    /// Public because a right-click cannot be simulated — the level the app's
    /// tests drive, like `fixChecksum(for:)`.
    public func openNodeInPanel(for nodeID: NodeID, body: Bool) {
        guard let tree, tree.isReady, let node = tree.image().node(nodeID),
              let open = UEFIPresenter.nodeOpen(for: node, in: tree.image(), body: body)
        else {
            fail("There is nothing to open here.")
            return
        }
        let readers = tree.spaceReaders
        let name = open.partName(fileName: host.fileName)
        controller.showBusy()
        Task { [weak self] in
            let bytes = await UEFIToolSession.bytes(of: open, readers: readers)
            guard let self else { return }
            self.controller.endBusy()
            guard let bytes, !bytes.isEmpty else {
                self.fail("Those bytes could not be read.")
                return
            }
            guard let provider = self.treeProvider else {
                self.host.openPart(bytes, named: name, linkedTo: open.source)
                return
            }
            if open.space == .file {
                provider.openFilePart(bytes, named: name, linkedTo: open.source,
                                      layout: open.layout, part: open.rebuild)
            } else {
                provider.openPart(bytes, named: name, linkedTo: open.source,
                                  layout: open.layout,
                                  part: open.rebuild ?? UEFIRebuild.Target(space: open.space,
                                                                           range: open.range))
            }
        }
    }

    private nonisolated static func bytes(
        of open: UEFIPresenter.NodeOpen,
        readers: SpaceReaders
    ) async -> [UInt8]? {
        await Task.detached(priority: .userInitiated) {
            readers.reader(for: open.space)?.bytes(open.range)
        }.value
    }

    /// Reads what a node has decompressed off the main actor, then hands it to
    /// `use` back on it; says so in red when there is nothing to read.
    private func withDecompressedBytes(
        of nodeID: NodeID,
        nothing: String,
        then use: @escaping @MainActor (UEFIPresenter.DecompressedExport, [UInt8]) async -> Void
    ) {
        guard let tree, tree.isReady, let node = tree.image().node(nodeID),
              let export = UEFIPresenter.decompressedExport(for: node)
        else {
            fail(nothing)
            return
        }
        let readers = tree.spaceReaders
        controller.showBusy()
        Task { [weak self] in
            let bytes = await UEFIToolSession.decompressedBytes(export, readers: readers)
            guard let self else { return }
            self.controller.endBusy()
            guard let bytes else {
                self.fail("The section does not decompress.")
                return
            }
            await use(export, bytes)
        }
    }

    private nonisolated static func decompressedBytes(
        _ export: UEFIPresenter.DecompressedExport,
        readers: SpaceReaders
    ) async -> [UInt8]? {
        await Task.detached(priority: .userInitiated) {
            guard let reader = readers.reader(for: export.space) else { return nil }
            return reader.bytes(export.range ?? reader.all)
        }.value
    }

    /// Something the user asked for did not happen, said in red. It survives
    /// the re-read that could otherwise wipe it, exactly like the success note.
    private func fail(_ text: String) {
        noticeAnswersTheUser = true
        controller.say(text, asProblem: true)
    }
}
