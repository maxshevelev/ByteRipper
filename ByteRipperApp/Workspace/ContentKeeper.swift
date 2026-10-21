import ByteRipperCore
import Foundation
import Workspace

/// Keeps every document's content beside the workspace, so a crash does not
/// take a join, a New File, a part's changes or a file's unsaved changes with
/// it (`Design/PERSISTENT_UNDO_PLAN.md`, "Content = base + journal").
///
/// A document's content is kept as a base — the file on disk, or the content
/// written whole once — and a log the document's transactions are appended to
/// (`HistoryLog`). A snapshot appends the transactions made since the last
/// one and writes down which state the document is in; an undo writes nothing
/// but that. The base is written again only when no transaction leads from it
/// to the document's state any more — the history was emptied, its bounds
/// dropped steps before they were written — or when the log has grown to
/// twice what the history holds. A written base or log is never rewritten: a
/// new one gets a new name, and the old goes once the workspace that read it
/// has been replaced (`endSnapshot`).
@MainActor
final class ContentKeeper {
    private let folder: WorkspaceFolder
    /// True for a project, whose files are also found relative to it.
    let isProject: Bool
    /// The folder a project's files are found relative to; nil outside one.
    var relativeBase: URL? { isProject ? folder.enclosingFolder : nil }

    private final class Entry {
        weak var document: BinaryDocument?
        let id: String
        /// The base as decided: its kind, file and serial. Its hash is the
        /// writer's to fill in.
        var base: KeptBase?
        /// The log the writes go to.
        var logName: String?
        /// About what the log holds, to know when to start it afresh.
        var loggedBytes: UInt64 = 0
        /// The serials of the transactions in the log, each to its parent.
        var parents: [UInt64: UInt64] = [:]
        /// The newest serial in the log: everything after it is new.
        var newestLogged: UInt64 = 0
        /// States the log is known to lead to from the base — so a snapshot
        /// checks only the way from the new head to one of them.
        var connected: Set<UInt64> = []
        /// The selection after each transaction as the log has it, so one a
        /// command refined after the snapshot wrote it is written again.
        var afters: [UInt64: SelectionModel] = [:]
        /// The segments the log pairs with each transaction, before it and
        /// after it, so a snapshot paired anew is written again.
        var segments: [SegmentKey: Segmentation] = [:]
        /// What the last snapshot wrote down for this document — its base and
        /// log as decided; the writer fills in what the bytes came out as.
        var kept: KeptContent?
        /// The content's version and the saved state when it was.
        var version: UndoHistory.Version?
        var saved: UInt64?

        init(document: BinaryDocument, id: String) {
            self.document = document
            self.id = id
        }
    }

    private struct SegmentKey: Hashable {
        let serial: UInt64
        let after: Bool
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// The kept files the snapshot being taken named, so the ones nobody names
    /// any more can go once it is written.
    private var named: Set<String> = []
    /// The documents it kept, by their ids.
    private var namedIDs: Set<String> = []
    /// What the snapshot being taken has for the writer.
    private var pending: [KeptWrite] = []

    /// Writes off the main thread what the snapshots decide.
    let writer: KeptWriter

    /// A log larger than this is let grow until it is twice what the history
    /// holds; then the content is written whole again and the log begins anew.
    var compactionFloor: UInt64 = 64 << 20

    init(folder: WorkspaceFolder, isProject: Bool = false) {
        self.folder = folder
        self.isProject = isProject
        self.writer = KeptWriter(folder: folder)
    }

    private static let editsEncoder: PropertyListEncoder = {
        // Binary: the added bytes go in as they are, not as base64 text.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    // MARK: - Writing

    /// The content of `pane`'s document as it now stands, written down: what
    /// changed since the last snapshot handed to the writer to append, the
    /// rest as it was. Nil for a file with nothing beyond what is on disk.
    /// Nothing is written here: `commit` hands the snapshot over.
    func keep(_ pane: PaneViewModel) -> KeptContent? {
        guard let document = pane.document else { return nil }
        let history = document.undoHistory
        let key = ObjectIdentifier(document)
        if !pane.isUntitled, !document.isDirty, !history.canUndo, !history.canRedo {
            entries[key] = nil
            return nil
        }
        let entry = entries[key].flatMap { $0.document === document ? $0 : nil }
            ?? Entry(document: document, id: UUID().uuidString)
        entries[key] = entry
        let saved = pane.isUntitled ? nil : history.savedStateSerial
        let refined = history.newestTransaction.map { entry.afters[$0.serial].map { $0 } != $0.selectionAfter } ?? false
        if entry.version != history.version || entry.saved != saved || entry.kept == nil || refined {
            update(entry, pane: pane, document: document, saved: saved)
        }
        if let kept = entry.kept {
            named.formUnion(kept.files)
            namedIDs.insert(entry.id)
        }
        return entry.kept
    }

    private func update(_ entry: Entry, pane: PaneViewModel, document: BinaryDocument, saved: UInt64?) {
        let history = document.undoHistory
        let epochMoved = entry.version.map { $0.epoch != history.version.epoch } ?? false
        var needsBase = entry.base == nil || entry.logName == nil || epochMoved
        if case .file = entry.base, pane.isUntitled { needsBase = true }
        var newBase: KeptBase?
        if !needsBase, let saved, saved != entry.saved {
            // Saved: the file on disk now holds the saved state, which the log
            // leads to — or the document was saved for the first time.
            newBase = .file(serial: saved)
            entry.base = newBase
        }
        if needsBase {
            guard rebase(entry, pane: pane, document: document, saved: saved) else { return failed(entry) }
        } else {
            var records: [KeptTransaction] = []
            var selections: [(UInt64, SelectionModel)] = []
            for kept in history.heldTransactions(after: entry.newestLogged) where entry.parents[kept.transaction.serial] == nil {
                let txn = kept.transaction
                records.append(kept)
                entry.parents[txn.serial] = txn.parent
                entry.afters[txn.serial] = txn.selectionAfter
                entry.newestLogged = max(entry.newestLogged, txn.serial)
                entry.loggedBytes += txn.ops.reduce(0) { $0 + $1.heldBytes }
            }
            // Only the newest transaction can have its selection refined after
            // it was recorded.
            if let newest = history.newestTransaction, entry.afters[newest.serial] != newest.selectionAfter {
                selections.append((newest.serial, newest.selectionAfter))
                entry.afters[newest.serial] = newest.selectionAfter
            }
            let segments = segmentWrites(of: pane, history: history, entry: entry)
            let tooLong = entry.loggedBytes > max(compactionFloor, 2 * history.heldBytes)
            if tooLong || !connects(entry, to: history.headSerial) {
                guard rebase(entry, pane: pane, document: document, saved: saved) else { return failed(entry) }
            } else if !records.isEmpty || !selections.isEmpty || !segments.isEmpty || newBase != nil {
                pending.append(.append(id: entry.id, records: records, selections: selections,
                                       segments: segments, base: newBase))
            }
        }
        let joins = document.keptJoins
        func kept(_ join: BinaryDocument.KeptJoin) -> KeptJoin {
            KeptJoin(serial: join.serial, path: join.url.path, readOnly: join.readOnly)
        }
        entry.kept = KeptContent(
            id: entry.id, base: entry.base!, head: history.headSerial, nextSerial: history.upcomingSerial,
            saved: saved,
            log: entry.logName.map { KeptLog(file: $0, length: 0, hash: "") },
            history: KeptHistory(undoBase: history.undoBaseSerial, redoTip: history.redoTipSerial,
                                 redoSteps: history.redoStepSizes, savedState: history.savedStateSerial,
                                 dirtyRegardless: history.isDirtyRegardless,
                                 joins: joins.undo.map(kept), undoneJoins: joins.redo.map(kept)))
        entry.version = history.version
        entry.saved = saved
    }

    /// Starts the document's content afresh: a new base, and a new log holding
    /// every transaction the history has. A file's base is the file itself when
    /// the history leads from its saved state; otherwise the content is written
    /// — whole for a document with no file, from a snapshot of it taken now;
    /// as runs over the file for one.
    /// A content that could not be taken afresh: the snapshot keeps what the
    /// last one kept, and the next one tries again from the start.
    private func failed(_ entry: Entry) {
        entry.base = nil
        entry.version = nil
    }

    @discardableResult
    private func rebase(_ entry: Entry, pane: PaneViewModel, document: BinaryDocument, saved: UInt64?) -> Bool {
        let history = document.undoHistory
        let name = "\(entry.id)-\(UUID().uuidString.prefix(8))"
        let held = history.heldTransactions
        var parents: [UInt64: UInt64] = [:]
        var afters: [UInt64: SelectionModel] = [:]
        for kept in held {
            parents[kept.transaction.serial] = kept.transaction.parent
            afters[kept.transaction.serial] = kept.transaction.selectionAfter
        }
        let head = history.headSerial
        let pendingBase: PendingBase
        let base: KeptBase
        if let saved, HistoryLog.connects(saved, head, parents: parents) {
            pendingBase = .file(serial: saved)
            base = .file(serial: saved)
        } else if saved != nil {
            guard let edits = pane.exportKeptEdits(), let data = try? Self.editsEncoder.encode(edits) else { return false }
            pendingBase = .edits(file: name + ".plist", serial: head, data: data)
            base = .edits(file: name + ".plist", serial: head, hash: "")
        } else {
            let store = TemporaryFileStore()
            let content: any ByteStorage
            if let overlay = document.storage as? EditOverlayStorage,
               let snapshot = try? overlay.contentSnapshot(scratch: store) {
                content = snapshot
            } else if let bytes = try? document.read(at: 0, length: Int(document.size)) {
                content = MemoryBackedStorage(bytes: bytes)
            } else {
                return false
            }
            pendingBase = .bytes(file: name + ".bin", serial: head, content: content, store: store)
            base = .bytes(file: name + ".bin", serial: head, hash: "")
        }
        entry.base = base
        entry.logName = name + ".log"
        entry.parents = parents
        entry.newestLogged = held.last?.transaction.serial ?? 0
        entry.connected = [base.serial]
        entry.afters = afters
        entry.loggedBytes = history.heldBytes
        entry.segments = [:]
        let segments = segmentWrites(of: pane, history: history, entry: entry)
        pending.append(.rebase(id: entry.id, name: name, base: pendingBase, held: held, segments: segments))
        return true
    }

    /// Whether the log leads from the base to `head`: the way up from `head`
    /// is followed only until it meets a state already known to be reached.
    private func connects(_ entry: Entry, to head: UInt64) -> Bool {
        guard let base = entry.base?.serial else { return false }
        if entry.connected.isEmpty { entry.connected = [base] }
        var walked: [UInt64] = []
        var at = head
        while !entry.connected.contains(at) {
            walked.append(at)
            guard let parent = entry.parents[at], walked.count <= entry.parents.count else {
                // Not upwards: the base may lie below `head`'s way, as after an
                // undo past it. The full check settles that.
                guard HistoryLog.connects(base, head, parents: entry.parents) else { return false }
                entry.connected.formUnion(walked)
                return true
            }
            at = parent
        }
        entry.connected.formUnion(walked)
        return true
    }

    /// The pane's segment snapshots, each paired with its step's serial — the
    /// undo side's before each step, the redo side's after each — that the log
    /// has not got yet. Read from the newest end of each side, as far as they
    /// are new: below that the stacks do not change.
    private func segmentWrites(of pane: PaneViewModel, history: UndoHistory, entry: Entry) -> [SegmentWrite] {
        var writes: [SegmentWrite] = []
        func pair(_ stack: [Segmentation], after: Bool, serial: (Int) -> UInt64?) {
            var k = 0
            while k < stack.count, let paired = serial(k) {
                let snapshot = stack[stack.count - 1 - k]
                let key = SegmentKey(serial: paired, after: after)
                if entry.segments[key] == snapshot { break }
                if let data = pane.encodedSegments(snapshot) {
                    writes.append(SegmentWrite(serial: key.serial, after: after, data: data))
                    entry.segments[key] = snapshot
                }
                k += 1
            }
        }
        pair(pane.segmentUndoStack, after: false, serial: history.undoSideSerial(fromNewest:))
        pair(pane.segmentRedoStack, after: true, serial: history.redoSideSerial(fromNewest:))
        return writes.reversed()
    }

    // MARK: - The files content is laid over

    private struct FileKey: Hashable {
        let path: String
        let size: UInt64
        let modified: Date?
    }

    /// SHA-256 of files on disk, by what they were like when hashed.
    private var fileHashes: [FileKey: String] = [:]
    private var hashing: Set<FileKey> = []
    /// Set for the snapshot that may be the last — quitting, leaving a
    /// project: a hash still missing is made there and then, not in the
    /// background, so the workspace written down has it.
    var waitsForHashes = false

    /// The SHA-256 of the file `stamp` describes, when it is known. The first
    /// time it is asked for, it is made in the background and the snapshot goes
    /// without it; the next one has it. A file that changed while it was read
    /// is not given one.
    func fileHash(for stamp: FileStamp) -> String? {
        let key = FileKey(path: stamp.path, size: stamp.size, modified: stamp.modified)
        if let hash = fileHashes[key] { return hash }
        let url = URL(fileURLWithPath: stamp.path)
        if waitsForHashes {
            guard let digest = try? FileDigest.sha256(of: url), Self.stillIs(key, url) else { return nil }
            fileHashes[key] = digest.hex
            return digest.hex
        }
        guard hashing.insert(key).inserted else { return nil }
        Task.detached(priority: .utility) { [weak self] in
            let digest = try? FileDigest.sha256(of: url)
            await MainActor.run {
                guard let self else { return }
                self.hashing.remove(key)
                if let digest, Self.stillIs(key, url) { self.fileHashes[key] = digest.hex }
            }
        }
        return nil
    }

    private nonisolated static func stillIs(_ key: FileKey, _ url: URL) -> Bool {
        guard let now = FileStamp(url: url) else { return false }
        return now.size == key.size && now.modified == key.modified
    }

    /// The untitled document or part in `pane`, kept: its content, its name,
    /// whether it is dirty. Nil when nothing about it could be kept.
    func stamp(for pane: PaneViewModel) -> UntitledStamp? {
        guard pane.isUntitled, let document = pane.document, let content = keep(pane) else { return nil }
        return UntitledStamp(content: content, name: pane.untitledName, size: document.size,
                             dirty: pane.status.isDirty)
    }

    /// Whether what `pane` holds now is what the last snapshot kept and the
    /// writer wrote — what lets quitting leave it unasked: it comes back at the
    /// next launch as it is. Asked after a final snapshot, which waits for the
    /// writer.
    func holdsCurrentBytes(of pane: PaneViewModel) -> Bool {
        guard let document = pane.document,
              let entry = entries[ObjectIdentifier(document)], entry.document === document,
              entry.kept != nil else { return false }
        return entry.version == document.undoHistory.version
            && !writer.hasFailed(entry.id) && writer.lastSnapshotWasWritten
    }

    /// A snapshot is about to be taken. A document whose last writes failed is
    /// started afresh.
    func beginSnapshot() {
        named = []
        namedIDs = []
        pending = []
        let failed = writer.takeFailures()
        guard !failed.isEmpty else { return }
        for entry in entries.values where failed.contains(entry.id) {
            entry.base = nil
            entry.version = nil
        }
    }

    /// The snapshot is taken: hands it to the writer, which writes what it
    /// decided, then `workspace`, then removes the kept files it no longer
    /// names. `wait` for a snapshot that may be the last.
    func commit(_ workspace: Workspace, wait: Bool) {
        writer.commit(pending, workspace: workspace, named: named, ids: namedIDs)
        pending = []
        entries = entries.filter { $0.value.document != nil && namedIDs.contains($0.value.id) }
        if wait { writer.flush() }
    }

    /// Tabs written down through this keeper outside a recorder, as the
    /// workspace file would have them: their kept content written, with its
    /// base and log as they came out.
    func settled(_ tabs: [TabState]) -> [TabState] {
        let workspace = Workspace(windows: [WindowState(frame: Rect(x: 0, y: 0, width: 0, height: 0),
                                                        tabs: tabs, selectedTab: 0)])
        commit(workspace, wait: true)
        return writer.filled(workspace).windows[0].tabs
    }

    // MARK: - Reading back

    /// The transactions a kept content's log holds, checked against its pin.
    private func records(of content: KeptContent) throws -> [KeptTransaction] {
        guard let log = content.log else { return [] }
        guard let hash = Data(hex: log.hash) else { throw HistoryLogError.unreadable }
        return try HistoryLog.read(folder.keptURL(log.file), length: log.length, hash: hash)
    }

    /// The ops from the content's base to the state it was in.
    private func ops(of content: KeptContent, _ records: [KeptTransaction]) throws -> [UndoOperation] {
        let map = Dictionary(records.map { ($0.transaction.serial, $0.transaction) }, uniquingKeysWith: { a, _ in a })
        guard let ops = HistoryLog.path(from: content.base.serial, to: content.head, through: map) else {
            throw HistoryLogError.noPath
        }
        return ops
    }

    /// Reads nothing that is not what was written: a base whose hash does not
    /// come out as kept is refused.
    private func checked(_ file: String, _ hash: String) throws -> URL {
        let url = folder.keptURL(file)
        guard try FileDigest.sha256(of: url).hex == hash else { throw HistoryLogError.unreadable }
        return url
    }

    /// The segments paired with a restored history's steps, as far back from
    /// the newest of each side as the log has them all.
    private func restoreSegments(of pane: PaneViewModel, undo: [KeptTransaction], redo: [KeptTransaction]) {
        func stack(_ side: [KeptTransaction], _ data: (KeptTransaction) -> Data?) -> [Segmentation] {
            var snapshots: [Segmentation] = []
            for kept in side.reversed() {
                guard let encoded = data(kept), let snapshot = pane.decodedSegments(encoded) else { break }
                snapshots.append(snapshot)
            }
            return snapshots.reversed()
        }
        pane.restoreSegmentSnapshots(undo: stack(undo, \.segmentsBefore), redo: stack(redo, \.segmentsAfter))
    }

    /// The content of an untitled document or a part as it was kept.
    func bytes(of content: KeptContent) throws -> [UInt8] {
        guard case .bytes(let file, _, let hash) = content.base else { throw HistoryLogError.unreadable }
        let url = try checked(file, hash)
        let records = try records(of: content)
        let storage = EditOverlayStorage(base: try FileBackedStorage(url: url))
        try HistoryLog.apply(try ops(of: content, records), to: storage)
        return try storage.read(at: 0, length: Int(storage.size))
    }

    /// Lays a file's kept content over the file `pane` has just opened.
    func apply(_ content: KeptContent, to pane: PaneViewModel) throws {
        let records = try records(of: content)
        var edits: OverlayEdits?
        switch content.base {
        case .file:
            break
        case .edits(let file, _, let hash):
            edits = try PropertyListDecoder().decode(OverlayEdits.self,
                                                     from: Data(contentsOf: try checked(file, hash)))
        case .bytes:
            throw HistoryLogError.unreadable
        }
        try pane.applyKeptContent(edits: edits, ops: try ops(of: content, records))
        adopt(pane, content: content, records: records, dirty: true)
    }

    /// A restored document goes on as kept: its history counts on from where
    /// the kept one stopped, and the next snapshot appends to the same log.
    /// Its undo and redo sides come back with it when the workspace kept them
    /// and the log holds them; otherwise it goes on with an empty history, as
    /// dirty as it was.
    func adopt(_ pane: PaneViewModel, content: KeptContent, records: [KeptTransaction]? = nil, dirty: Bool) {
        guard let document = pane.document else { return }
        let records = records ?? ((try? self.records(of: content)) ?? [])
        let map = Dictionary(records.map { ($0.transaction.serial, $0) }, uniquingKeysWith: { _, b in b })
        if let kept = content.history,
           let sides = HistoryLog.sides(head: content.head, undoBase: kept.undoBase, redoTip: kept.redoTip,
                                        redoSizes: kept.redoSteps, in: map) {
            document.undoHistory.restore(undo: sides.undo, redo: sides.redo, base: kept.undoBase,
                                         nextSerial: content.nextSerial, saved: kept.savedState,
                                         dirtyRegardless: kept.dirtyRegardless)
            func join(_ kept: KeptJoin) -> BinaryDocument.KeptJoin {
                BinaryDocument.KeptJoin(serial: kept.serial, url: URL(fileURLWithPath: kept.path), readOnly: kept.readOnly)
            }
            document.restoreJoins(undo: kept.joins.map(join), redo: sides.redo.isEmpty ? [] : kept.undoneJoins.map(join))
            restoreSegments(of: pane, undo: sides.undo, redo: sides.redo.reversed().flatMap { $0 })
        } else {
            document.undoHistory.resume(at: content.head, nextSerial: content.nextSerial,
                                        saved: content.saved, dirty: dirty)
        }
        let entry = Entry(document: document, id: content.id)
        entry.base = content.base
        entry.logName = content.log?.file
        entry.loggedBytes = content.log?.length ?? 0
        writer.submit([.resume(id: content.id, base: content.base, log: content.log)])
        for record in records {
            entry.parents[record.transaction.serial] = record.transaction.parent
            entry.afters[record.transaction.serial] = record.transaction.selectionAfter
            entry.newestLogged = max(entry.newestLogged, record.transaction.serial)
        }
        // What the log pairs with the steps is what the pane now holds.
        for (serial, snapshot) in zip(document.undoHistory.undoSideSerials.suffix(pane.segmentUndoStack.count),
                                      pane.segmentUndoStack) {
            entry.segments[SegmentKey(serial: serial, after: false)] = snapshot
        }
        for (serial, snapshot) in zip(document.undoHistory.redoSideSerials.suffix(pane.segmentRedoStack.count),
                                      pane.segmentRedoStack) {
            entry.segments[SegmentKey(serial: serial, after: true)] = snapshot
        }
        entry.kept = content
        entry.version = document.undoHistory.version
        entry.saved = content.saved
        entries[ObjectIdentifier(document)] = entry
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
