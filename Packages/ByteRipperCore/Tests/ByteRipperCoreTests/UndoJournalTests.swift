import Foundation
import XCTest
@testable import ByteRipperCore

/// The undo history keeps the ops' bytes in a journal, not in memory, and keeps
/// to its bounds by dropping the oldest steps (`Design/PERSISTENT_UNDO_PLAN.md`).
final class UndoJournalTests: XCTestCase {
    private func overwrite(_ at: UInt64, _ before: [UInt8], _ after: [UInt8]) -> UndoOperation {
        .overwrite(range: at..<(at + UInt64(after.count)), before: UndoBytes(before), after: UndoBytes(after))
    }

    private func makeDocument(_ bytes: [UInt8]) -> BinaryDocument {
        BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: bytes)),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("journal-\(UUID().uuidString).bin"),
            readOnly: false
        )
    }

    private func journal(of bytes: UndoBytes) -> UndoJournal? { bytes.journal }

    // MARK: - Where the bytes are

    /// Recorded bytes leave memory: what undo hands back lies in the journal,
    /// and reads back as what was recorded.
    func testRecordedBytesLieInTheJournal() throws {
        let history = UndoHistory()
        history.record([overwrite(4, [1, 2, 3], [7, 8, 9])])
        let undone = try XCTUnwrap(history.undo())
        guard case .overwrite(_, let before, let after) = undone[0].ops[0] else { return XCTFail() }
        XCTAssertNotNil(journal(of: before))
        XCTAssertNotNil(journal(of: after))
        XCTAssertEqual(try before.load(), [1, 2, 3])
        XCTAssertEqual(try after.load(), [7, 8, 9])
        XCTAssertEqual(history.heldBytes, 6)
    }

    /// A long group — a join is one — puts its bytes into the journal as it
    /// goes, and a cancelled group still puts the document back as it was.
    func testAGroupsBytesGoToTheJournalAsItRuns() throws {
        let doc = makeDocument([0, 1, 2, 3])
        doc.beginEditGroup()
        try doc.overwrite(range: 0..<2, with: [9, 9])
        try doc.insert(at: 4, bytes: [5, 6])
        try doc.cancelEditGroup()
        XCTAssertEqual(try doc.read(at: 0, length: Int(doc.size)), [0, 1, 2, 3])
        XCTAssertFalse(doc.canUndo)
    }

    /// Undo and redo through the journal give the document its bytes back.
    func testUndoAndRedoReadTheJournal() throws {
        let doc = makeDocument([UInt8](repeating: 0x11, count: 64))
        try doc.fill(pattern: [0xAB, 0xCD], in: 8..<40)
        try doc.delete(range: 0..<4)
        try doc.insert(at: 2, bytes: [1, 2, 3])
        let edited = try doc.read(at: 0, length: Int(doc.size))
        try doc.undo(); try doc.undo(); try doc.undo()
        XCTAssertEqual(try doc.read(at: 0, length: Int(doc.size)), [UInt8](repeating: 0x11, count: 64))
        XCTAssertFalse(doc.isDirty)
        try doc.redo(); try doc.redo(); try doc.redo()
        XCTAssertEqual(try doc.read(at: 0, length: Int(doc.size)), edited)
    }

    // MARK: - A fill

    /// A fill keeps the bytes it replaced and its pattern — not the bytes it
    /// wrote — and works in slices that carry one repetition on across their
    /// seams, a pattern that does not divide the slice included.
    func testAFillKeepsItsPatternNotItsBytes() throws {
        let size = BinaryDocument.fillChunkSize * 2 + 1000
        let original = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let doc = makeDocument(original)
        let pattern: [UInt8] = [0xAA, 0xBB, 0xCC]
        try doc.fill(pattern: pattern, in: 10..<UInt64(size - 10))

        let filled = try doc.read(at: 0, length: size)
        for i in 10..<(size - 10) {
            guard filled[i] == pattern[(i - 10) % 3] else { return XCTFail("byte \(i)") }
        }
        XCTAssertEqual(Array(filled[0..<10]), Array(original[0..<10]))
        let slices = UInt64((size - 20 + BinaryDocument.fillChunkSize - 1) / BinaryDocument.fillChunkSize)
        XCTAssertEqual(doc.undoHistory.heldBytes, UInt64(size - 20) + 3 * slices,
                       "what it replaced, and three bytes of pattern a slice")
        XCTAssertEqual(doc.undoHistory.undoDepth, 1, "one fill, one step")

        try doc.undo()
        XCTAssertEqual(try doc.read(at: 0, length: size), original)
        try doc.redo()
        XCTAssertEqual(try doc.read(at: 0, length: size), filled)
    }

    /// A pattern's bytes read back as the pattern repeated and cut short.
    func testPatternBytesReadBackRepeated() throws {
        XCTAssertEqual(try UndoBytes(pattern: [1, 2, 3], count: 7).load(), [1, 2, 3, 1, 2, 3, 1])
        XCTAssertEqual(try UndoBytes(pattern: [1, 2, 3], count: 2).load(), [1, 2])
        XCTAssertEqual(UndoBytes(pattern: [9], count: 4), [9, 9, 9, 9])
    }

    // MARK: - Bounds

    /// Past the bound on steps the oldest go; undoing all that is left does not
    /// reach the file as opened, so the document stays dirty.
    func testTheOldestStepsGoPastTheStepBound() {
        let history = UndoHistory()
        history.limits = UndoLimits(bytes: nil, transactions: 3)
        for i in 0..<5 { history.record([overwrite(UInt64(i), [0], [1])]) }
        XCTAssertEqual(history.undoDepth, 3)
        XCTAssertEqual(history.heldBytes, 6)
        while history.undo() != nil {}
        XCTAssertTrue(history.isDirty, "two edits were dropped and still stand")
    }

    /// A saved state whose step was dropped is still the saved state when the
    /// undo side runs back to it.
    func testUndoingBackToADroppedSavedStateIsClean() {
        let history = UndoHistory()
        history.limits = UndoLimits(bytes: nil, transactions: 2)
        for i in 0..<3 { history.record([overwrite(UInt64(i), [0], [1])]) }
        history.markSaved()
        for i in 3..<5 { history.record([overwrite(UInt64(i), [0], [1])]) }
        XCTAssertTrue(history.isDirty)
        history.undo(); history.undo()
        XCTAssertFalse(history.isDirty)
        XCTAssertFalse(history.canUndo)
    }

    /// The byte bound counts before and after alike, and never drops the newest
    /// step: one edit larger than the bound stays undoable once.
    func testTheByteBoundKeepsTheNewestStepAlone() {
        let history = UndoHistory()
        history.limits = UndoLimits(bytes: 10, transactions: nil)
        history.record([overwrite(0, [0, 0], [1, 1])])     // 4
        history.record([overwrite(2, [0, 0], [1, 1])])     // 8
        history.record([overwrite(4, [0, 0], [1, 1])])     // 12 → the first goes
        XCTAssertEqual(history.undoDepth, 2)
        XCTAssertEqual(history.heldBytes, 8)
        history.record([overwrite(8, [UInt8](repeating: 0, count: 20), [UInt8](repeating: 1, count: 20))])
        XCTAssertEqual(history.undoDepth, 1)
        XCTAssertEqual(history.heldBytes, 40)
    }

    /// A lowered bound takes effect at the next edit.
    func testALoweredBoundTakesEffectAtTheNextEdit() {
        let history = UndoHistory()
        history.limits = .unlimited
        for i in 0..<10 { history.record([overwrite(UInt64(i), [0], [1])]) }
        history.limits = UndoLimits(bytes: nil, transactions: 4)
        XCTAssertEqual(history.undoDepth, 10)
        history.record([overwrite(10, [0], [1])])
        XCTAssertEqual(history.undoDepth, 4)
    }

    /// A cut redo side no longer counts.
    func testACutRedoSideNoLongerCounts() {
        let history = UndoHistory()
        history.record([overwrite(0, [0, 0], [1, 1])])
        history.record([overwrite(2, [0, 0], [1, 1])])
        history.undo()
        XCTAssertEqual(history.heldBytes, 8, "an undone step can still be redone")
        history.record([overwrite(4, [0], [1])])
        XCTAssertEqual(history.heldBytes, 6)
    }

    /// A join the bounds dropped cannot be undone, so nothing re-attaches the
    /// document to the file the join left.
    func testADroppedJoinNoLongerReattaches() throws {
        let doc = makeDocument([1, 2, 3])
        doc.undoHistory.limits = UndoLimits(bytes: nil, transactions: 1)
        try doc.join(contentsOf: MemoryBackedStorage(bytes: [9, 9]), at: .end)
        XCTAssertFalse(doc.isAttached)
        try doc.overwrite(range: 0..<1, with: [7])
        try doc.undo()
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.isAttached)
        XCTAssertEqual(try doc.read(at: 0, length: Int(doc.size)), [1, 2, 3, 9, 9])
    }

    // MARK: - Compaction

    /// Once dead bytes outweigh the live ones the journal is compacted into a
    /// new one, and every step still undoes and redoes to the right bytes.
    func testCompactionKeepsEveryStepsBytes() throws {
        let doc = makeDocument([UInt8](repeating: 0, count: 256))
        doc.undoHistory.compactionFloor = 0
        try doc.overwrite(range: 0..<4, with: [1, 1, 1, 1])
        try doc.overwrite(range: 100..<228, with: [UInt8](repeating: 2, count: 128))
        try doc.undo()                                          // the 128 bytes are only redo
        let before = try XCTUnwrap(doc.undoHistory.undo().flatMap { $0.first?.ops.first })
        try doc.undoHistory.redo()                              // back where the document is
        guard case .overwrite(_, let oldBytes, _) = before else { return XCTFail() }
        let oldJournal = try XCTUnwrap(journal(of: oldBytes))

        try doc.overwrite(range: 8..<10, with: [3, 3])         // cuts the redo side: 256 dead, 12 live
        let undone = try XCTUnwrap(doc.undoHistory.undo())
        guard case .overwrite(_, let newBytes, _) = undone[0].ops[0] else { return XCTFail() }
        XCTAssertFalse(journal(of: newBytes) === oldJournal, "compacted into a new journal")
        XCTAssertEqual(try oldBytes.load(), [0, 0, 0, 0], "bytes handed out before still read")
        doc.undoHistory.redo()

        try doc.undo(); try doc.undo()
        XCTAssertEqual(try doc.read(at: 0, length: 256), [UInt8](repeating: 0, count: 256))
        try doc.redo(); try doc.redo()
        var expected = [UInt8](repeating: 0, count: 256)
        expected.replaceSubrange(0..<4, with: [1, 1, 1, 1])
        expected.replaceSubrange(8..<10, with: [3, 3])
        XCTAssertEqual(try doc.read(at: 0, length: 256), expected)
    }

    /// Emptying the history lets the journal go.
    func testResetLetsTheJournalGo() {
        let history = UndoHistory()
        history.record([overwrite(0, [0], [1])])
        weak var journal: UndoJournal?
        if case .overwrite(_, let before, _) = history.undo()![0].ops[0] { journal = before.journal }
        XCTAssertNotNil(journal)
        history.reset()
        XCTAssertNil(journal)
        XCTAssertEqual(history.heldBytes, 0)
    }
}
