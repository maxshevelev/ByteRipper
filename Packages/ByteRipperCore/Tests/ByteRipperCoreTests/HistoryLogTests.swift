import Foundation
import XCTest
@testable import ByteRipperCore

/// A kept history's log: what goes in comes back, a damaged or cut log is
/// refused, and the content of any state is found from any other by the
/// transactions between them (`Design/PERSISTENT_UNDO_PLAN.md`).
final class HistoryLogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDocument(_ bytes: [UInt8]) -> BinaryDocument {
        BinaryDocument(storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: bytes)),
                       url: folder.appendingPathComponent("doc.bin"), readOnly: false)
    }

    private func content(_ doc: BinaryDocument) throws -> [UInt8] {
        try doc.read(at: 0, length: Int(doc.size))
    }

    /// The content of the state `head` names, from `base` holding `baseBytes`.
    private func rebuild(_ baseBytes: [UInt8], from base: UInt64, to head: UInt64,
                         _ records: [KeptTransaction]) throws -> [UInt8] {
        let map = Dictionary(uniqueKeysWithValues: records.map { ($0.transaction.serial, $0.transaction) })
        let ops = try XCTUnwrap(HistoryLog.path(from: base, to: head, through: map))
        let storage = EditOverlayStorage(base: MemoryBackedStorage(bytes: baseBytes))
        try HistoryLog.apply(ops, to: storage)
        return try storage.read(at: 0, length: Int(storage.size))
    }

    private func write(_ records: [KeptTransaction], to url: URL) throws -> HistoryLogWriter {
        let writer = try HistoryLogWriter(creating: url)
        for record in records { try writer.append(record) }
        return writer
    }

    // MARK: -

    /// Every kind of op, a typing series, a label and a fill's pattern come
    /// back as they went in.
    func testWhatIsWrittenReadsBack() throws {
        let doc = makeDocument([UInt8](0..<64))
        doc.beginSeries(7)
        try doc.overwrite(range: 0..<1, with: [0xAA])
        doc.endSeries()
        try doc.insert(at: 10, bytes: [1, 2, 3])
        try doc.delete(range: 20..<25)
        try doc.fill(pattern: [0xF0, 0x0F], in: 30..<50)
        doc.beginEditGroup(label: "Add Microcode")
        try doc.overwrite(range: 2..<4, with: [9, 9])
        doc.endEditGroup()

        let held = doc.undoHistory.heldTransactions
        let url = folder.appendingPathComponent("a.log")
        let writer = try write(held, to: url)
        let read = try HistoryLog.read(url, length: writer.length, hash: writer.hash)
        XCTAssertEqual(read, held)
        XCTAssertEqual(read.first?.seriesID, 7)
        XCTAssertEqual(read.last?.label, "Add Microcode")
    }

    /// From the content as first written, the log rebuilds the content the
    /// document holds now — and every state the history passed through.
    func testTheLogRebuildsEveryStateFromTheBase() throws {
        let original = [UInt8](0..<48)
        let doc = makeDocument(original)
        let start = doc.undoHistory.headSerial
        try doc.overwrite(range: 4..<8, with: [1, 1, 1, 1])
        let afterFirst = try content(doc)
        let first = doc.undoHistory.headSerial
        try doc.insert(at: 0, bytes: [7, 7])
        try doc.delete(range: 30..<40)
        let url = folder.appendingPathComponent("b.log")
        let writer = try write(doc.undoHistory.heldTransactions, to: url)
        let records = try HistoryLog.read(url, length: writer.length, hash: writer.hash)
        let head = doc.undoHistory.headSerial

        XCTAssertEqual(try rebuild(original, from: start, to: head, records), try content(doc))
        XCTAssertEqual(try rebuild(original, from: start, to: first, records), afterFirst)
        // Down from the state the document holds now, back to the opened file.
        XCTAssertEqual(try rebuild(try content(doc), from: head, to: start, records), original)
    }

    /// A branch: undo, then a different edit. The way from one branch's tip to
    /// the other's goes up to where they part, then down.
    func testAWayLeadsAcrossBranches() throws {
        let original = [UInt8](repeating: 0, count: 16)
        let doc = makeDocument(original)
        try doc.overwrite(range: 0..<2, with: [1, 1])
        try doc.overwrite(range: 4..<6, with: [2, 2])
        let tipA = doc.undoHistory.headSerial
        let contentA = try content(doc)
        let branchA = doc.undoHistory.heldTransactions
        try doc.undo()
        try doc.insert(at: 8, bytes: [3, 3, 3])
        let tipB = doc.undoHistory.headSerial
        let contentB = try content(doc)
        let all = Dictionary((branchA + doc.undoHistory.heldTransactions).map { ($0.transaction.serial, $0) },
                             uniquingKeysWith: { a, _ in a }).values.sorted { $0.transaction.serial < $1.transaction.serial }

        XCTAssertEqual(try rebuild(contentA, from: tipA, to: tipB, Array(all)), contentB)
        XCTAssertEqual(try rebuild(contentB, from: tipB, to: tipA, Array(all)), contentA)
    }

    /// No transaction joins the two states: there is no way.
    func testNoWayWithoutTheTransactionsBetween() {
        XCTAssertNil(HistoryLog.path(from: 3, to: 9, through: [:]))
        XCTAssertEqual(HistoryLog.path(from: 3, to: 3, through: [:]), [])
    }

    // MARK: - Integrity

    /// A changed byte anywhere in a record breaks its hash.
    func testADamagedLogIsRefused() throws {
        let doc = makeDocument([UInt8](0..<32))
        try doc.overwrite(range: 0..<8, with: [UInt8](repeating: 5, count: 8))
        let url = folder.appendingPathComponent("c.log")
        let writer = try write(doc.undoHistory.heldTransactions, to: url)
        var data = try Data(contentsOf: url)
        data[data.count / 2] ^= 0xFF
        try data.write(to: url)
        XCTAssertThrowsError(try HistoryLog.read(url, length: writer.length, hash: writer.hash))
    }

    /// A log shorter than its manifest says, or pinned by another hash, is refused.
    func testACutOrMisnamedLogIsRefused() throws {
        let doc = makeDocument([UInt8](0..<32))
        try doc.overwrite(range: 0..<8, with: [UInt8](repeating: 5, count: 8))
        try doc.insert(at: 0, bytes: [1])
        let url = folder.appendingPathComponent("d.log")
        let writer = try write(doc.undoHistory.heldTransactions, to: url)
        XCTAssertThrowsError(try HistoryLog.read(url, length: writer.length + 1, hash: writer.hash))
        XCTAssertThrowsError(try HistoryLog.read(url, length: writer.length, hash: HistoryLog.emptyHash))
    }

    /// What was appended after the manifest pinned the log — a crash between
    /// the two — is not part of it, and is cut off when appending goes on.
    func testATailPastThePinnedLengthIsCutOff() throws {
        let doc = makeDocument([UInt8](0..<32))
        try doc.overwrite(range: 0..<2, with: [1, 1])
        let url = folder.appendingPathComponent("e.log")
        let writer = try write(doc.undoHistory.heldTransactions, to: url)
        let (pinnedLength, pinnedHash) = (writer.length, writer.hash)
        try doc.overwrite(range: 2..<4, with: [2, 2])
        try writer.append(doc.undoHistory.heldTransactions[1])        // never pinned

        XCTAssertEqual(try HistoryLog.read(url, length: pinnedLength, hash: pinnedHash).count, 1)
        let resumed = try HistoryLogWriter(appendingTo: url, length: pinnedLength, hash: pinnedHash)
        try doc.overwrite(range: 4..<6, with: [3, 3])
        try resumed.append(doc.undoHistory.heldTransactions[2])
        let read = try HistoryLog.read(url, length: resumed.length, hash: resumed.hash)
        XCTAssertEqual(read.map(\.transaction.serial), [doc.undoHistory.heldTransactions[0].transaction.serial,
                                                        doc.undoHistory.heldTransactions[2].transaction.serial])
    }

    /// An op that does not fit the content it is laid over is refused, not
    /// done half.
    func testAnOpThatDoesNotFitIsRefused() throws {
        let storage = EditOverlayStorage(base: MemoryBackedStorage(bytes: [1, 2, 3]))
        XCTAssertThrowsError(try HistoryLog.apply([.delete(range: 2..<9, bytes: UndoBytes([UInt8](repeating: 0, count: 7)))],
                                                  to: storage))
    }

    // MARK: - Serials

    /// A reset names its content anew, so the edits after it never descend
    /// from a state the content before it had.
    func testEveryStateHasASerialOfItsOwn() throws {
        let doc = makeDocument([0, 0, 0, 0])
        try doc.overwrite(range: 0..<1, with: [1])
        let edited = doc.undoHistory.headSerial
        doc.undoHistory.reset()
        XCTAssertNotEqual(doc.undoHistory.headSerial, 0)
        XCTAssertNotEqual(doc.undoHistory.headSerial, edited)
        XCTAssertFalse(doc.undoHistory.isDirty, "a reset document is its file")
        let reset = doc.undoHistory.headSerial
        try doc.overwrite(range: 1..<2, with: [1])
        XCTAssertEqual(doc.undoHistory.heldTransactions.last?.transaction.parent, reset)
    }

    /// A resumed history goes on counting where the kept one stopped, and
    /// knows the saved state when there is one.
    func testAResumedHistoryGoesOnCounting() throws {
        let history = UndoHistory()
        history.resume(at: 40, nextSerial: 52, saved: 31, dirty: false)
        XCTAssertEqual(history.headSerial, 40)
        XCTAssertTrue(history.isDirty, "the file holds state 31, the content is 40")
        history.record([.overwrite(range: 0..<1, before: [0], after: [1])])
        XCTAssertEqual(history.heldTransactions.last?.transaction.serial, 52)
        XCTAssertEqual(history.heldTransactions.last?.transaction.parent, 40)

        let untitled = UndoHistory()
        untitled.resume(at: 9, nextSerial: 10, saved: nil, dirty: true)
        XCTAssertTrue(untitled.isDirty)
        let clean = UndoHistory()
        clean.resume(at: 9, nextSerial: 10, saved: 9, dirty: false)
        XCTAssertFalse(clean.isDirty)
    }

    // MARK: - The history itself

    /// A history written down and put back into a fresh document undoes and
    /// redoes as the one it was taken from — a fast-undone series one redo step,
    /// a step's name and series with it, the saved state recognised.
    func testAKeptHistoryUndoesAndRedoesAsBefore() throws {
        let original = [UInt8](repeating: 0, count: 32)
        let doc = makeDocument(original)
        try doc.overwrite(range: 0..<2, with: [1, 1])
        doc.undoHistory.markSaved()
        doc.beginEditGroup(label: "Add Microcode")
        try doc.overwrite(range: 4..<6, with: [2, 2])
        doc.endEditGroup()
        doc.beginSeries(5)
        for i in 0..<3 { try doc.overwrite(range: UInt64(10 + i)..<UInt64(11 + i), with: [3]) }
        doc.endSeries()
        try doc.undo(batch: false)
        try doc.undo(batch: true)                     // the rest of the series: one redo step
        let history = doc.undoHistory
        XCTAssertEqual(history.redoStepSizes, [2, 1])

        let url = folder.appendingPathComponent("h.log")
        let writer = try write(history.heldTransactions, to: url)
        let records = try HistoryLog.read(url, length: writer.length, hash: writer.hash)
        let map = Dictionary(uniqueKeysWithValues: records.map { ($0.transaction.serial, $0) })
        let sides = try XCTUnwrap(HistoryLog.sides(head: history.headSerial, undoBase: history.undoBaseSerial,
                                                   redoTip: history.redoTipSerial,
                                                   redoSizes: history.redoStepSizes, in: map))
        XCTAssertEqual(sides.undo.count, 2)
        XCTAssertEqual(sides.redo.map(\.count), [2, 1])

        let copy = makeDocument(try content(doc))
        copy.undoHistory.restore(undo: sides.undo, redo: sides.redo, base: history.undoBaseSerial,
                                 nextSerial: history.upcomingSerial, saved: history.savedStateSerial,
                                 dirtyRegardless: history.isDirtyRegardless)
        XCTAssertEqual(copy.undoHistory.undoLabel, "Add Microcode")
        XCTAssertTrue(copy.isDirty)
        try copy.redo()
        try copy.redo()
        XCTAssertEqual(try content(copy), try { try doc.redo(); try doc.redo(); return try content(doc) }())
        try copy.undo(batch: false)
        try copy.undo(batch: true)
        try copy.undo()
        XCTAssertFalse(copy.isDirty, "the saved state, reached by undo")
        try copy.undo()
        XCTAssertEqual(try content(copy), original)
        XCTAssertFalse(copy.canUndo)
        try copy.overwrite(range: 20..<21, with: [9])
        XCTAssertGreaterThanOrEqual(copy.undoHistory.heldTransactions.last!.transaction.serial,
                                    history.upcomingSerial, "serials go on, never named twice")
    }

    /// No way down to the undo base: nothing to put back. A redo side that does
    /// not add up is left out, the undo side kept.
    func testSidesThatDoNotAddUpAreLeftOut() throws {
        let doc = makeDocument([UInt8](repeating: 0, count: 8))
        try doc.overwrite(range: 0..<1, with: [1])
        try doc.overwrite(range: 1..<2, with: [1])
        try doc.undo()
        let held = doc.undoHistory.heldTransactions
        let map = Dictionary(uniqueKeysWithValues: held.map { ($0.transaction.serial, $0) })
        let head = doc.undoHistory.headSerial
        XCTAssertNil(HistoryLog.sides(head: head, undoBase: 999, redoTip: nil, redoSizes: [], in: map))
        let wrong = try XCTUnwrap(HistoryLog.sides(head: head, undoBase: 0, redoTip: doc.undoHistory.redoTipSerial,
                                                   redoSizes: [5], in: map))
        XCTAssertEqual(wrong.undo.count, 1)
        XCTAssertEqual(wrong.redo.count, 0)
    }

    /// A selection a command placed after the snapshot wrote its transaction
    /// is written as a record of its own and read back over it.
    func testARefinedSelectionReadsBack() throws {
        let doc = makeDocument([UInt8](repeating: 0, count: 16))
        try doc.overwrite(range: 0..<2, with: [1, 1])
        let url = folder.appendingPathComponent("s.log")
        let writer = try write(doc.undoHistory.heldTransactions, to: url)
        let serial = doc.undoHistory.headSerial
        let refined = SelectionModel(start: 3, end: 7, fileSize: 16)
        try writer.appendSelection(after: serial, refined)
        let read = try HistoryLog.read(url, length: writer.length, hash: writer.hash)
        XCTAssertEqual(read.first?.transaction.selectionAfter, refined)
    }

    /// Segments paired with a transaction read back on its side; the same
    /// ones again cost a flag, and still read back whole.
    func testSegmentsPairedWithATransactionReadBack() throws {
        let doc = makeDocument([UInt8](repeating: 0, count: 16))
        try doc.overwrite(range: 0..<1, with: [1])
        try doc.overwrite(range: 1..<2, with: [1])
        let held = doc.undoHistory.heldTransactions
        let url = folder.appendingPathComponent("p.log")
        let writer = try write(held, to: url)
        let a = Data("cuts A".utf8)
        try writer.appendSegments(of: held[0].transaction.serial, after: false, a)
        let lengthBefore = writer.length
        try writer.appendSegments(of: held[1].transaction.serial, after: false, a)
        XCTAssertLessThan(writer.length - lengthBefore, 64, "a repeat is a flag, not the bytes again")
        try writer.appendSegments(of: held[1].transaction.serial, after: true, Data("cuts B".utf8))
        let read = try HistoryLog.read(url, length: writer.length, hash: writer.hash)
        XCTAssertEqual(read[0].segmentsBefore, a)
        XCTAssertEqual(read[1].segmentsBefore, a)
        XCTAssertEqual(read[1].segmentsAfter, Data("cuts B".utf8))
    }

    /// A history's journal is its log: a transaction's record names the bytes
    /// the edit already wrote there, and reads back whole.
    func testARecordNamesTheBytesTheJournalHolds() throws {
        let history = UndoHistory(journalDirectory: folder)
        let big = [UInt8](repeating: 0xAB, count: 300_000)
        history.record([.insert(at: 0, bytes: UndoBytes(big))])
        let journal = try XCTUnwrap(history.journal)
        let before = journal.length
        let writer = HistoryLogWriter(journal: journal)
        try writer.append(history.heldTransactions[0])
        XCTAssertLessThan(journal.length - before, 512, "named, not written again")
        XCTAssertTrue(UndoJournal.liveNames(in: folder).contains(journal.url!.lastPathComponent))

        let read = try HistoryLog.read(journal.url!, length: writer.length, hash: writer.hash)
        XCTAssertEqual(read, history.heldTransactions)
        guard case .insert(_, let bytes) = read[0].transaction.ops[0] else { return XCTFail() }
        XCTAssertEqual(try bytes.load(), big)
    }

    /// A journal taken up again goes on: its old records name bytes written
    /// into a record, and written again by reference.
    func testAContinuedJournalNamesWhatItsRecordsCarried() throws {
        let doc = makeDocument([UInt8](repeating: 0, count: 64))
        try doc.overwrite(range: 0..<8, with: [UInt8](repeating: 7, count: 8))
        let url = folder.appendingPathComponent("c2.log")
        let first = try write(doc.undoHistory.heldTransactions, to: url)   // the bytes written into the record
        let continuing = try UndoJournal(continuing: url, length: first.length, hash: first.hash)
        let records = try HistoryLog.read(continuing, length: first.length, hash: first.hash)
        let writer = HistoryLogWriter(journal: continuing)
        let lengthBefore = writer.length
        try writer.append(records[0])
        XCTAssertLessThan(writer.length - lengthBefore, 300, "named by where the record carried them")
        let again = try HistoryLog.read(url, length: writer.length, hash: writer.hash)
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again[1].transaction.ops, records[0].transaction.ops)
    }
}
