import Foundation

/// A single reversible byte mutation (decision D4).
///
/// Each case carries everything needed to apply and revert it without re-reading
/// the storage:
/// - `.overwrite` carries the bytes before and after (a fill is an overwrite
///   with a repeated pattern), so reverting simply writes `before` back.
/// - `.insert` is reverted by deleting its bytes; `.delete` is reverted by
///   re-inserting the removed bytes at the original offset.
///
/// An overwrite that extended past EOF is never stored as a single op here:
/// `BinaryDocument` splits it into an overwrite of the existing bytes plus an
/// insert of the new tail, so every stored op is length-preserving and reverts
/// without a truncate operation.
///
/// The bytes are `UndoBytes`: in memory as an edit hands them over, in the
/// history's journal once it has recorded them.
public enum UndoOperation: Equatable, Sendable {
    case overwrite(range: Range<UInt64>, before: UndoBytes, after: UndoBytes)
    case insert(at: UInt64, bytes: UndoBytes)
    case delete(range: Range<UInt64>, bytes: UndoBytes)

    /// The op that reverts this one, for applying a transaction in reverse
    /// (undo): an overwrite swaps its before/after bytes, an insert becomes the
    /// delete of its bytes, a delete re-inserts its removed bytes.
    var inverted: UndoOperation {
        switch self {
        case .overwrite(let range, let before, let after):
            return .overwrite(range: range, before: after, after: before)
        case .insert(let at, let bytes):
            return .delete(range: at..<(at + UInt64(bytes.count)), bytes: bytes)
        case .delete(let range, let bytes):
            return .insert(at: range.lowerBound, bytes: bytes)
        }
    }

    /// The bytes the op carries, before and after alike — what it costs the
    /// history to keep (`UndoLimits.bytes`). A fill's bytes count as its
    /// pattern.
    var heldBytes: UInt64 {
        switch self {
        case .overwrite(_, let before, let after): return UInt64(before.heldCount + after.heldCount)
        case .insert(_, let bytes), .delete(_, let bytes): return UInt64(bytes.heldCount)
        }
    }

    /// The same op with its bytes in `journal`.
    func stored(in journal: UndoJournal) throws -> UndoOperation {
        switch self {
        case .overwrite(let range, let before, let after):
            return .overwrite(range: range, before: try journal.store(before), after: try journal.store(after))
        case .insert(let at, let bytes):
            return .insert(at: at, bytes: try journal.store(bytes))
        case .delete(let range, let bytes):
            return .delete(range: range, bytes: try journal.store(bytes))
        }
    }

    /// How many of the op's bytes lie in `journal`.
    func bytes(in journal: UndoJournal) -> UInt64 {
        func count(_ bytes: UndoBytes) -> UInt64 { bytes.journal === journal ? UInt64(bytes.count) : 0 }
        switch self {
        case .overwrite(_, let before, let after): return count(before) + count(after)
        case .insert(_, let bytes), .delete(_, let bytes): return count(bytes)
        }
    }
}

/// A committed undo step: the ops applied as a unit, plus the selections that
/// bracket it — what was selected when the edit started (`selectionBefore`,
/// restored by undo) and what the edit left selected (`selectionAfter`,
/// restored by redo). Captured by `BinaryDocument` at record time.
///
/// The whole selection is stored, not just the caret: typing into a selection
/// consumes it byte by byte, and an undo that dropped the selection would make
/// the two directions asymmetric — the state undo returns to would be one the
/// editing never passed through (§7.5).
public struct UndoTransaction: Equatable, Sendable {
    public fileprivate(set) var ops: [UndoOperation]
    public let selectionBefore: SelectionModel
    /// Set at record time from the edit's natural end, then refined by
    /// `noteSelectionAfterOnLast` once the command that made the edit has left
    /// the selection where it wants it.
    public private(set) var selectionAfter: SelectionModel
    /// The state-name this step was recorded under — the serial `record` handed
    /// out. A document-level act (a join, §22.2) captures it so undo/redo can
    /// recognise the transaction and re-attach/detach the file.
    public let serial: UInt64

    /// Where the caret sits in each bracketing state — an empty selection is a
    /// caret, and a non-empty one's caret is its start.
    public var caretBefore: UInt64 { selectionBefore.start }
    public var caretAfter: UInt64 { selectionAfter.start }

    public init(ops: [UndoOperation], selectionBefore: SelectionModel, selectionAfter: SelectionModel,
                serial: UInt64 = 0) {
        self.ops = ops
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.serial = serial
    }

    /// Caret-only form, for edits recorded without a selection to speak of.
    public init(ops: [UndoOperation], caretBefore: UInt64, caretAfter: UInt64,
                fileSize: UInt64 = .max) {
        self.init(ops: ops,
                  selectionBefore: .empty(at: caretBefore, fileSize: fileSize),
                  selectionAfter: .empty(at: caretAfter, fileSize: fileSize))
    }

    fileprivate mutating func setSelectionAfter(_ selection: SelectionModel) {
        selectionAfter = selection
    }
}

/// Linear undo/redo history with a dirty checkpoint (decision D4).
///
/// The history is a list of *steps* — one step is one undo gesture: either a
/// single transaction (a normal edit, or one entered byte of a typing series)
/// or a batch of transactions (the rest of a series removed by one fast
/// Cmd+Z). A step's `seriesID` links the steps of one typing series; `nil`
/// means the step is outside a series.
///
/// `undo(batch: true)` removes one step, but when the previous undo removed a
/// single series byte and the top step belongs to the same series, it removes
/// every remaining step of that series as one batch — the "coalescing window"
/// of segmented undo. `redo()` restores one step; a batch is unfolded back
/// into individual byte steps on the undo stack, so byte-by-byte rollback is
/// available again after a redo.
///
/// Dirty state compares the *state* the document is in with the one the last
/// `markSaved()` checkpointed, not how many edits stand. Every recorded
/// transaction gets a serial that is handed out once and never reused, and the
/// serial of the newest committed transaction names the current state (0 for an
/// empty history). Undoing back to the saved state clears dirty; redoing past it
/// sets it again (§5.1, §17.7).
///
/// Counting instead — the depth of the history, as this class used to — makes
/// two different states with as many edits look identical: undo one edit, make a
/// different one, and the document claimed to match the file on disk. Closing or
/// replacing it then discarded the change with no prompt (§7.5).
///
/// This class is confined to a single thread (the document it belongs to).
public final class UndoHistory: @unchecked Sendable {
    /// A recorded transaction and the state it produced. The serial travels with
    /// the transaction through undo and redo, so returning to a state returns to
    /// its serial — that is what lets the saved checkpoint be recognised.
    private struct Entry {
        var transaction: UndoTransaction
        var serial: UInt64
    }

    /// One undo gesture: a transaction (a normal edit or one entered byte)
    /// or a batch of transactions (the rest of a series removed by one fast
    /// press). `seriesID` links the steps of one typing series; nil is
    /// outside a series.
    private struct Step {
        /// What the user would call this step — "Add Microcode" — or nil for
        /// the ordinary editing that needs no name (typing, a paste, a fill).
        /// Set only by an edit made on the user's behalf by something with a
        /// name of its own, which today means a tool-module's transaction
        /// (`Design/TOOL_MODULES_PLAN.md`).
        var label: String?
        var entries: [Entry]                  // in recording order (first..last)
        var seriesID: UInt64?

        var transactions: [UndoTransaction] { entries.map(\.transaction) }
        var heldBytes: UInt64 {
            entries.reduce(0) { $0 + $1.transaction.ops.reduce(0) { $0 + $1.heldBytes } }
        }
        func bytes(in journal: UndoJournal) -> UInt64 {
            entries.reduce(0) { $0 + $1.transaction.ops.reduce(0) { $0 + $1.bytes(in: journal) } }
        }
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    /// Handed out on every `record`, never reused — not even after `reset`, so a
    /// serial can never name two different states in one document's lifetime.
    private var nextSerial: UInt64 = 1
    /// The serial `markSaved()` checkpointed; 0 means "the file as opened".
    private var savedSerial: UInt64 = 0
    /// True after the history was cleared while keeping the document dirty — a
    /// document-level act (a join) produced never-saved content that cannot be
    /// undone (there is no prior state to return to) but must not be silently
    /// discarded on close. Cleared by the next save or reset.
    private var dirtyAfterClear = false
    private var undoTransactionCount = 0

    /// The bounds this history keeps to; nil reads `UndoLimits.current` at
    /// each edit, which is what a document does — the settings can change
    /// while it is open.
    public var limits: UndoLimits?
    /// Where the journal is made. A test points it at a folder of its own.
    let journalDirectory: URL
    /// The file the ops' bytes live in, made at the first edit that has any.
    private var journal: UndoJournal?
    /// The bytes every recorded op carries, undo and redo side together.
    public private(set) var heldBytes: UInt64 = 0
    /// How many of those lie in the current journal; the rest of its length is
    /// dead — steps dropped, redo sides cut, groups cancelled.
    private var liveJournalBytes: UInt64 = 0
    /// Dead bytes the journal may hold before it is compacted, at the least;
    /// beyond that, it is compacted once they outweigh the live ones.
    var compactionFloor: UInt64 = 64 << 20
    /// The state an empty undo side stands for: 0 for the file as opened, the
    /// serial of the newest dropped transaction once the bounds have dropped
    /// any. Undoing everything that is left lands there, not on 0.
    private(set) var baseSerial: UInt64 = 0

    public init(journalDirectory: URL = FileManager.default.temporaryDirectory) {
        self.journalDirectory = journalDirectory
    }

    // Fast-rollback state:
    private var lastUndoWasSeriesByte = false
    private var lastUndoSeriesID: UInt64?

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    /// True when the current state differs from the last saved state, or when
    /// the document holds never-saved content a cleared history no longer names
    /// (a join, §22.2): that content must still warn on close.
    public var isDirty: Bool { dirtyAfterClear || currentSerial != savedSerial }
    /// Number of committed transactions.
    public var undoDepth: Int { undoTransactionCount }

    /// The serial of the newest committed transaction — the name of the state the
    /// document is in. With nothing to undo, the state the undo side starts
    /// from: the file as it was opened (0), or the newest step the bounds
    /// dropped.
    private var currentSerial: UInt64 { undoSteps.last?.entries.last?.serial ?? baseSerial }

    /// How many times the history was emptied (`reset`, `clearKeepingDirty`).
    /// After either, the current serial is 0 again while the content is not
    /// what it was the last time it was 0 — the epoch tells the two apart.
    private var epoch: UInt64 = 0

    /// Names the content's state: two equal versions of one document hold
    /// the same bytes. An undo goes back to an earlier version; every edit and
    /// every emptying of the history makes a new one. What lets a copy of the
    /// bytes kept elsewhere — a workspace's untitled document — be rewritten
    /// only when they changed.
    public struct Version: Hashable, Sendable {
        let epoch: UInt64
        let serial: UInt64
    }

    public var version: Version { Version(epoch: epoch, serial: currentSerial) }

    /// The serial of the newest committed transaction, or `nil` when nothing has
    /// been committed. A document-level act (a join, §22.2) captures this right
    /// after its transaction commits, so undo/redo can recognise that step.
    public var lastCommittedSerial: UInt64? {
        undoSteps.last?.entries.last?.serial
    }

    /// Records a transaction of ops applied to storage. Any undone steps
    /// (the redo stack) are discarded, because the state has diverged. The
    /// selection pair records what the edit started from and what it left, so
    /// undo/redo can restore it. `seriesID` marks the transaction as part of a
    /// typing series (nil for everything else). A new record also breaks the
    /// fast-rollback window — a fresh edit is never batched with a previous
    /// undo.
    public func record(_ ops: [UndoOperation],
                       selectionBefore: SelectionModel,
                       selectionAfter: SelectionModel,
                       seriesID: UInt64? = nil,
                       label: String? = nil) {
        guard !ops.isEmpty else { return }
        discardRedo()
        let ops = stored(ops)
        let entry = Entry(transaction: UndoTransaction(ops: ops,
                                                      selectionBefore: selectionBefore,
                                                      selectionAfter: selectionAfter,
                                                      serial: nextSerial),
                          serial: nextSerial)
        nextSerial += 1
        undoSteps.append(Step(label: label, entries: [entry], seriesID: seriesID))
        undoTransactionCount += 1
        account(ops, sign: 1)
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
        dropBeyondLimits()
        compactIfNeeded()
    }

    /// `ops` with their bytes in the journal — what an edit group does with
    /// the ops it collects, so a long group (a join, a streamed replace) does
    /// not hold its bytes in memory until it closes. When the journal cannot
    /// be made or written, the bytes stay in memory: the edit stays undoable.
    func stored(_ ops: [UndoOperation]) -> [UndoOperation] {
        do {
            if journal == nil {
                guard ops.contains(where: { $0.heldBytes > 0 }) else { return ops }
                journal = try UndoJournal(directory: journalDirectory)
            }
            let journal = journal!
            return try ops.map { try $0.stored(in: journal) }
        } catch {
            return ops
        }
    }

    private func account(_ ops: [UndoOperation], sign: Int) {
        for op in ops {
            let held = op.heldBytes
            let live = journal.map { op.bytes(in: $0) } ?? 0
            if sign > 0 {
                heldBytes += held
                liveJournalBytes += live
            } else {
                heldBytes -= min(held, heldBytes)
                liveJournalBytes -= min(live, liveJournalBytes)
            }
        }
    }

    private func discardRedo() {
        for step in redoSteps {
            for entry in step.entries { account(entry.transaction.ops, sign: -1) }
        }
        redoSteps.removeAll()
    }

    /// Drops the oldest steps until the history is within its bounds — never
    /// the newest: one edit larger than the bound is still undoable once. Runs
    /// right after a record, when the redo side is empty.
    private func dropBeyondLimits() {
        let limits = self.limits ?? UndoLimits.current
        func over() -> Bool {
            if let bytes = limits.bytes, heldBytes > bytes { return true }
            if let count = limits.transactions, undoTransactionCount > count { return true }
            return false
        }
        while undoSteps.count > 1, over() {
            let step = undoSteps.removeFirst()
            for entry in step.entries { account(entry.transaction.ops, sign: -1) }
            undoTransactionCount -= step.entries.count
            if let serial = step.entries.last?.serial { baseSerial = serial }
        }
    }

    /// Moves the live bytes into a new journal once the dead ones outweigh
    /// them. The old journal is let go, not rewritten: bytes handed out from
    /// it stay readable while anything holds them.
    private func compactIfNeeded() {
        guard let old = journal else { return }
        let dead = old.length - min(liveJournalBytes, old.length)
        guard dead > compactionFloor, dead > liveJournalBytes else { return }
        guard let fresh = try? UndoJournal(directory: journalDirectory) else { return }
        do {
            func move(_ steps: [Step]) throws -> [Step] {
                try steps.map { step in
                    var step = step
                    for i in step.entries.indices {
                        step.entries[i].transaction.ops = try step.entries[i].transaction.ops.map {
                            try $0.stored(in: fresh)
                        }
                    }
                    return step
                }
            }
            let undo = try move(undoSteps)
            let redo = try move(redoSteps)
            undoSteps = undo
            redoSteps = redo
            journal = fresh
            liveJournalBytes = (undoSteps + redoSteps).reduce(0) { $0 + $1.bytes(in: fresh) }
        } catch {
            // The old journal still holds everything; try again at a later edit.
        }
    }

    /// Lets go of every op's bytes: the journal goes with them.
    private func dropAll() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        journal = nil
        heldBytes = 0
        liveJournalBytes = 0
        baseSerial = 0
    }

    /// Caret-only form of `record`, for edits with no selection to restore.
    public func record(_ ops: [UndoOperation], caretBefore: UInt64 = 0, caretAfter: UInt64 = 0,
                       fileSize: UInt64 = .max, seriesID: UInt64? = nil, label: String? = nil) {
        record(ops,
               selectionBefore: .empty(at: caretBefore, fileSize: fileSize),
               selectionAfter: .empty(at: caretAfter, fileSize: fileSize),
               seriesID: seriesID,
               label: label)
    }

    /// What the next undo would take back, when that step has a name — so the
    /// menu can say "Undo Add Microcode" rather than a bare "Undo". Nil for
    /// ordinary editing, which is most of it.
    public var undoLabel: String? { undoSteps.last?.label }
    /// The same for the next redo.
    public var redoLabel: String? { redoSteps.last?.label }

    /// Refines the last recorded transaction's post-edit selection, so redo
    /// restores what the editing command left on screen rather than the bare
    /// end of the byte range it wrote. Ignored unless the last transaction is
    /// the current one (nothing has been undone since it was recorded).
    public func noteSelectionAfterOnLast(_ selection: SelectionModel) {
        guard redoSteps.isEmpty, let step = undoSteps.indices.last,
              let entry = undoSteps[step].entries.indices.last else { return }
        undoSteps[step].entries[entry].transaction.setSelectionAfter(selection)
    }

    /// Reverts the most recent step, returning its transactions in recording
    /// order (for the caller to apply in reverse). With `batch == true`, a
    /// fast repeat of a series-byte undo removes the rest of that series as
    /// one step instead. Returns `nil` if there is nothing to undo.
    @discardableResult
    public func undo(batch: Bool = false) -> [UndoTransaction]? {
        guard let last = undoSteps.popLast() else { return nil }
        var collected = [last]
        if batch, let sid = last.seriesID, sid == lastUndoSeriesID, lastUndoWasSeriesByte {
            while let next = undoSteps.last, next.seriesID == sid {
                undoSteps.removeLast()
                collected.append(next)
            }
        }
        let ordered = collected.reversed().flatMap(\.entries)   // recording order
        undoTransactionCount -= ordered.count
        // The name goes onto the redo stack with the step, so a step undone
        // and offered back is still the same act by the same name.
        redoSteps.append(Step(label: last.label, entries: ordered, seriesID: last.seriesID))
        lastUndoWasSeriesByte = (collected.count == 1 && last.seriesID != nil)
        lastUndoSeriesID = last.seriesID
        return ordered.map(\.transaction)
    }

    /// Reapplies the next undone step, returning its transactions in
    /// recording order for the caller to apply in order. A batch step is
    /// unfolded back into individual byte steps on the undo stack, restoring
    /// the series' byte-by-byte structure. Returns `nil` if there is nothing
    /// to redo.
    @discardableResult
    public func redo() -> [UndoTransaction]? {
        guard let step = redoSteps.popLast() else { return nil }
        // Each transaction goes back with the serial it was recorded under, so a
        // redo that lands on the saved state is recognised as clean again.
        for entry in step.entries {
            undoSteps.append(Step(label: step.label, entries: [entry], seriesID: step.seriesID))
        }
        undoTransactionCount += step.entries.count
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
        return step.transactions
    }

    /// Marks the state the document is in as the saved one (called after a
    /// successful save).
    public func markSaved() {
        savedSerial = currentSerial
        dirtyAfterClear = false
    }

    /// Discards all history and the dirty checkpoint.
    public func reset() {
        dropAll()
        // `nextSerial` deliberately keeps counting: the history is empty, so the
        // current state is 0 again, and no future serial can collide with one a
        // caller still remembers.
        savedSerial = 0
        dirtyAfterClear = false
        epoch += 1
        undoTransactionCount = 0
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
    }

    /// Clears the undo/redo history but keeps the document marked as having
    /// unsaved content. A document-level act (a join, §22.2) produces never-
    /// saved content that cannot be undone — there is no prior state to return
    /// to — yet it must not be silently discarded on close, so the dirty flag
    /// survives the clear. A later save or reset clears it; edits made after the
    /// clear undo as usual and never reach the cleared work.
    public func clearKeepingDirty() {
        dropAll()
        savedSerial = 0
        dirtyAfterClear = true
        epoch += 1
        undoTransactionCount = 0
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
    }
}
