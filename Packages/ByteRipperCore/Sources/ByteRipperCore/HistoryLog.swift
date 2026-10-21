import CryptoKit
import Foundation

/// A transaction as a kept history writes it down: the transaction, and the
/// two things about it its step knows — the typing series it belongs to and
/// the name the menu gives it.
public struct KeptTransaction: Equatable, Sendable {
    public let transaction: UndoTransaction
    public let seriesID: UInt64?
    public let label: String?
    /// What the pane paired with the transaction, read back from the log: the
    /// segments before it (while it was on the undo side) and after it (while
    /// it was on the redo side), in the app's own encoding.
    public var segmentsBefore: Data?
    public var segmentsAfter: Data?

    public init(transaction: UndoTransaction, seriesID: UInt64?, label: String?) {
        self.transaction = transaction
        self.seriesID = seriesID
        self.label = label
    }
}

public enum HistoryLogError: Error, Equatable, Sendable {
    /// The log is shorter than its manifest says, a record does not parse, or
    /// the chained hash does not come out as written down.
    case unreadable
    /// No way leads from the state the base holds to the one asked for.
    case noPath
    /// An op does not fit the content it is laid over.
    case doesNotFit
}

/// A document's transactions written down beside a workspace
/// (`Design/PERSISTENT_UNDO_PLAN.md`, "The journal").
///
/// Append-only. A record is never rewritten; each carries the SHA-256 of the
/// previous record's hash and its own bytes, so appending costs what is
/// appended, and the manifest pins the log by its length and the hash at that
/// length. Bytes past that length — written after the last manifest, before
/// a crash — are not part of it.
///
/// A record: `BRT1`, the body's length (u64), the body, the 32-byte hash. The
/// body: serial, parent, the selections before and after, the series id, the
/// label, and the ops with their bytes — a fill's as its pattern. `BRS1`
/// records, framed the same way, refine the selection after a transaction
/// written before the command that made it had placed it.
public enum HistoryLog {
    static let magic: [UInt8] = Array("BRT1".utf8)
    /// A refined selection after a transaction already written
    /// (`UndoHistory.noteSelectionAfterOnLast`): serial, then the selection.
    static let selectionMagic: [UInt8] = Array("BRS1".utf8)
    /// The segments paired with a transaction already written: serial, side
    /// (0 before it, 1 after it), then the encoding — or, flagged, the same as
    /// the last such record in the log.
    static let segmentsMagic: [UInt8] = Array("BRP1".utf8)
    /// An edit's bytes, written the moment it was recorded; transaction
    /// records name them by where they start.
    static let blobMagic: [UInt8] = Array("BRB1".utf8)
    /// The hash a log starts its chain from.
    public static let emptyHash = Data(repeating: 0, count: 32)

    /// The ops that take the content from the state `base` names to the one
    /// `head` names: back up from `base` to the state the two descend from,
    /// each transaction undone, then down to `head`, each one done. Nil when
    /// the transactions in `records` lead from neither to a state the other
    /// came from.
    public static func path(from base: UInt64, to head: UInt64,
                            through records: [UInt64: UndoTransaction]) -> [UndoOperation]? {
        func lineage(_ serial: UInt64) -> [UInt64] {
            var line = [serial]
            var seen: Set<UInt64> = [serial]
            var at = serial
            while let record = records[at], seen.insert(record.parent).inserted {
                at = record.parent
                line.append(at)
            }
            return line
        }
        let up = lineage(base)
        let down = lineage(head)
        let upSet = Set(up)
        guard let meet = down.firstIndex(where: { upSet.contains($0) }) else { return nil }
        let common = down[meet]
        var ops: [UndoOperation] = []
        for serial in up.prefix(while: { $0 != common }) {
            ops += records[serial]!.ops.reversed().map(\.inverted)
        }
        for serial in down.prefix(meet).reversed() {
            ops += records[serial]!.ops
        }
        return ops
    }

    /// The undo and redo sides of a kept history, from the transactions in
    /// its log: the undo side is the way from `undoBase` to `head`, oldest
    /// first; the redo side the way from `head` down to `redoTip`, cut into
    /// steps of `redoSizes`, the next to redo first. Nil when the log does not
    /// hold the way to `undoBase`; a redo side that does not add up is left
    /// empty — what can be undone is not lost over what could be redone.
    public static func sides(head: UInt64, undoBase: UInt64, redoTip: UInt64?, redoSizes: [Int],
                             in records: [UInt64: KeptTransaction])
        -> (undo: [KeptTransaction], redo: [[KeptTransaction]])? {
        var undo: [KeptTransaction] = []
        var at = head
        while at != undoBase {
            guard let record = records[at], undo.count <= records.count else { return nil }
            undo.append(record)
            at = record.transaction.parent
        }
        undo.reverse()
        guard let tip = redoTip else { return (undo, []) }
        var way: [KeptTransaction] = []
        at = tip
        while at != head {
            guard let record = records[at], way.count <= records.count else { return (undo, []) }
            way.append(record)
            at = record.transaction.parent
        }
        way.reverse()
        guard redoSizes.allSatisfy({ $0 > 0 }), redoSizes.reduce(0, +) == way.count else { return (undo, []) }
        var redo: [[KeptTransaction]] = []
        var from = 0
        for size in redoSizes {
            redo.append(Array(way[from..<(from + size)]))
            from += size
        }
        return (undo, redo)
    }

    /// Whether the transactions whose parents `parents` lists lead from the
    /// state `a` names to the one `b` names — what `path` needs, known
    /// without the ops themselves.
    public static func connects(_ a: UInt64, _ b: UInt64, parents: [UInt64: UInt64]) -> Bool {
        func lineage(_ serial: UInt64) -> [UInt64] {
            var line = [serial]
            var seen: Set<UInt64> = [serial]
            var at = serial
            while let parent = parents[at], seen.insert(parent).inserted {
                at = parent
                line.append(at)
            }
            return line
        }
        let up = Set(lineage(a))
        return lineage(b).contains { up.contains($0) }
    }

    /// Does `ops` to `storage`, in order, checking each fits before it is done.
    public static func apply(_ ops: [UndoOperation], to storage: any EditableByteStorage) throws {
        for op in ops {
            switch op {
            case .overwrite(let range, _, let after):
                guard range.upperBound <= storage.size, Int(range.count) == after.count else {
                    throw HistoryLogError.doesNotFit
                }
                try storage.overwrite(range: range, with: try after.load())
            case .insert(let at, let bytes):
                guard at <= storage.size else { throw HistoryLogError.doesNotFit }
                try storage.insert(at: at, bytes: try bytes.load())
            case .delete(let range, let bytes):
                guard range.upperBound <= storage.size, Int(range.count) == bytes.count else {
                    throw HistoryLogError.doesNotFit
                }
                try storage.delete(range: range)
            }
        }
    }

    /// Reads the records in the first `length` bytes of the log at `url`,
    /// checking each one's hash and the last against `hash`. The ops' bytes
    /// are not read into memory: they point into the log.
    public static func read(_ url: URL, length: UInt64, hash: Data,
                            progress: ((Int) -> Void)? = nil) throws -> [KeptTransaction] {
        try read(try UndoJournal(reading: url), length: length, hash: hash, progress: progress)
    }

    /// The same, from a journal already open — one taken up again
    /// (`UndoJournal(continuing:)`), which the restored history then goes on
    /// writing: the ops' bytes point into it.
    public static func read(_ file: UndoJournal, length: UInt64, hash: Data,
                            progress: ((Int) -> Void)? = nil) throws -> [KeptTransaction] {
        guard length > 0 else {
            guard hash == emptyHash else { throw HistoryLogError.unreadable }
            return []
        }
        guard file.length >= length else { throw HistoryLogError.unreadable }
        var reader = Reader(file: file, end: length)
        reader.progress = progress
        var chain = emptyHash
        var records: [KeptTransaction] = []
        var index: [UInt64: Int] = [:]
        var lastSegments: Data?
        do {
            while reader.at < length {
                let kind = try reader.bytes(4, hashing: false)
                guard kind == magic || kind == selectionMagic || kind == segmentsMagic || kind == blobMagic else {
                    throw HistoryLogError.unreadable
                }
                let bodyLength = try reader.u64(hashing: false)
                guard bodyLength <= length - reader.at else { throw HistoryLogError.unreadable }
                reader.hasher = SHA256()
                reader.hasher.update(data: chain)
                let bodyEnd = reader.at + bodyLength
                if kind == blobMagic {
                    reader.blobs[reader.at] = bodyLength
                    try reader.skip(bodyLength)
                } else if kind == magic {
                    let record = try reader.transaction()
                    index[record.transaction.serial] = records.count
                    records.append(record)
                } else if kind == segmentsMagic {
                    let serial = try reader.u64()
                    let after = try reader.u8() != 0
                    let data: Data
                    if try reader.u8() == 0 {
                        guard let last = lastSegments else { throw HistoryLogError.unreadable }
                        data = last
                    } else {
                        data = Data(try reader.bytes(Int(try reader.u32())))
                    }
                    lastSegments = data
                    guard let at = index[serial] else { throw HistoryLogError.unreadable }
                    if after { records[at].segmentsAfter = data } else { records[at].segmentsBefore = data }
                } else {
                    let serial = try reader.u64()
                    let selection = try reader.selection()
                    guard let at = index[serial] else { throw HistoryLogError.unreadable }
                    var transaction = records[at].transaction
                    transaction.setSelectionAfter(selection)
                    var refined = KeptTransaction(transaction: transaction, seriesID: records[at].seriesID,
                                                  label: records[at].label)
                    refined.segmentsBefore = records[at].segmentsBefore
                    refined.segmentsAfter = records[at].segmentsAfter
                    records[at] = refined
                }
                guard reader.at == bodyEnd else { throw HistoryLogError.unreadable }
                let digest = Data(reader.hasher.finalize())
                guard try Data(reader.bytes(32, hashing: false)) == digest else { throw HistoryLogError.unreadable }
                chain = digest
            }
        } catch is HistoryLogError {
            throw HistoryLogError.unreadable
        } catch {
            throw HistoryLogError.unreadable
        }
        guard chain == hash else { throw HistoryLogError.unreadable }
        return records
    }

    // MARK: - Reading

    private struct Reader {
        let file: UndoJournal
        let end: UInt64
        var at: UInt64 = 0
        var hasher = SHA256()
        var progress: ((Int) -> Void)?
        /// The edits' bytes read past so far: where each starts, its length.
        var blobs: [UInt64: UInt64] = [:]

        init(file: UndoJournal, end: UInt64) {
            self.file = file
            self.end = end
        }

        mutating func bytes(_ count: Int, hashing: Bool = true) throws -> [UInt8] {
            guard UInt64(count) <= end - at else { throw HistoryLogError.unreadable }
            let bytes = try file.read(at: at, count: count)
            if hashing { hasher.update(data: bytes) }
            at += UInt64(count)
            progress?(count)
            return bytes
        }

        /// Passes over `count` bytes, hashing them, a slice at a time.
        mutating func skip(_ count: UInt64) throws {
            var left = count
            while left > 0 {
                let slice = Int(min(left, UInt64(UndoJournal.copySlice)))
                _ = try bytes(slice)
                left -= UInt64(slice)
            }
        }

        mutating func u64(hashing: Bool = true) throws -> UInt64 {
            try bytes(8, hashing: hashing).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }

        mutating func u32() throws -> UInt32 {
            try bytes(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }

        mutating func selection() throws -> SelectionModel {
            let start = try u64(), end = try u64(), size = try u64()
            guard start <= end else { throw HistoryLogError.unreadable }
            return SelectionModel(start: start, end: end, fileSize: size)
        }

        /// A payload: in the log itself, hashed as it is passed over but not
        /// kept, or a pattern.
        mutating func payload() throws -> UndoBytes {
            switch try u8() {
            case 0:
                let count = try u64()
                guard count <= end - at else { throw HistoryLogError.unreadable }
                let start = at
                try skip(count)
                // Written into the record, and named from here on like an
                // edit's own bytes.
                blobs[start] = count
                return UndoBytes(journal: file, offset: start, count: Int(count))
            case 2:
                // The bytes of an edit written before, by where they start.
                let start = try u64(), count = try u64()
                guard blobs[start] == count else { throw HistoryLogError.unreadable }
                return UndoBytes(journal: file, offset: start, count: Int(count))
            case 1:
                let count = try u64()
                let patternLength = Int(try u32())
                let pattern = try bytes(patternLength)
                return UndoBytes(pattern: pattern, count: Int(count))
            default:
                throw HistoryLogError.unreadable
            }
        }

        mutating func transaction() throws -> KeptTransaction {
            let serial = try u64()
            let parent = try u64()
            let before = try selection()
            let after = try selection()
            let hasSeries = try u8()
            let series = try u64()
            let labelLength = Int(try u32())
            let label = labelLength == 0 ? nil : String(decoding: try bytes(labelLength), as: UTF8.self)
            let count = Int(try u32())
            var ops: [UndoOperation] = []
            for _ in 0..<count {
                let kind = try u8()
                let a = try u64(), b = try u64()
                switch kind {
                case 0:
                    guard a <= b else { throw HistoryLogError.unreadable }
                    ops.append(.overwrite(range: a..<b, before: try payload(), after: try payload()))
                case 1:
                    ops.append(.insert(at: a, bytes: try payload()))
                case 2:
                    guard a <= b else { throw HistoryLogError.unreadable }
                    ops.append(.delete(range: a..<b, bytes: try payload()))
                default:
                    throw HistoryLogError.unreadable
                }
            }
            return KeptTransaction(
                transaction: UndoTransaction(ops: ops, selectionBefore: before, selectionAfter: after,
                                             serial: serial, parent: parent),
                seriesID: hasSeries != 0 ? series : nil, label: label)
        }
    }
}

/// Appends a kept history's records to its journal: the transactions — naming
/// the bytes the journal already holds rather than writing them again — the
/// refined selections and the segments paired with them.
public final class HistoryLogWriter {
    public let journal: UndoJournal

    public init(journal: UndoJournal) {
        self.journal = journal
    }

    /// A new, empty log at `url`.
    public convenience init(creating url: URL) throws {
        self.init(journal: try UndoJournal(creating: url))
    }

    /// The log at `url` as a manifest pinned it: anything past `length` is
    /// cut off before the next record goes on.
    public convenience init(appendingTo url: URL, length: UInt64, hash: Data) throws {
        self.init(journal: try UndoJournal(continuing: url, length: length, hash: hash))
    }

    public var url: URL { journal.url! }
    /// Where the next record goes: the length a manifest pins the log at.
    public var length: UInt64 { journal.pin().length }
    /// The chained hash at `length`.
    public var hash: Data { journal.pin().hash }

    /// Appends one transaction. Bytes already in this journal are named by
    /// where they start; bytes elsewhere — in memory, in another journal —
    /// are written into the record; a fill's are its pattern.
    public func append(_ kept: KeptTransaction) throws {
        let txn = kept.transaction
        var head: [UInt8] = []
        head += UndoJournal.u64(txn.serial)
        head += UndoJournal.u64(txn.parent)
        head += selection(txn.selectionBefore) + selection(txn.selectionAfter)
        head.append(kept.seriesID == nil ? 0 : 1)
        head += UndoJournal.u64(kept.seriesID ?? 0)
        let label = Array((kept.label ?? "").utf8)
        head += u32(UInt32(label.count)) + label
        head += u32(UInt32(txn.ops.count))
        let journal = journal
        enum Form { case named(UInt64, Int), pattern([UInt8], Int), written(UndoBytes) }
        func form(_ bytes: UndoBytes) -> Form {
            if let pattern = bytes.patternForm { return .pattern(pattern.pattern, pattern.count) }
            if case .stored(let owner, let offset, let count) = bytes.storage, owner === journal {
                return .named(offset, count)
            }
            return .written(bytes)
        }
        func size(_ form: Form) -> UInt64 {
            switch form {
            case .named: return 1 + 16
            case .pattern(let pattern, _): return 1 + 8 + 4 + UInt64(pattern.count)
            case .written(let bytes): return 1 + 8 + UInt64(bytes.count)
            }
        }
        var parts: [(fixed: [UInt8], payloads: [Form])] = []
        for op in txn.ops {
            switch op {
            case .overwrite(let range, let before, let after):
                parts.append(([0] + UndoJournal.u64(range.lowerBound) + UndoJournal.u64(range.upperBound),
                              [form(before), form(after)]))
            case .insert(let at, let bytes):
                parts.append(([1] + UndoJournal.u64(at) + UndoJournal.u64(0), [form(bytes)]))
            case .delete(let range, let bytes):
                parts.append(([2] + UndoJournal.u64(range.lowerBound) + UndoJournal.u64(range.upperBound),
                              [form(bytes)]))
            }
        }
        let bodyLength = UInt64(head.count) + parts.reduce(0) { total, part in
            total + UInt64(part.fixed.count) + part.payloads.reduce(0) { $0 + size($1) }
        }
        try journal.appendRecord(HistoryLog.magic, bodyLength: bodyLength) { emit in
            try emit(head)
            for part in parts {
                try emit(part.fixed)
                for payload in part.payloads {
                    switch payload {
                    case .named(let offset, let count):
                        try emit([2] + UndoJournal.u64(offset) + UndoJournal.u64(UInt64(count)))
                    case .pattern(let pattern, let count):
                        try emit([1] + UndoJournal.u64(UInt64(count)) + u32(UInt32(pattern.count)) + pattern)
                    case .written(let bytes):
                        try emit([0] + UndoJournal.u64(UInt64(bytes.count)))
                        try bytes.forEachSlice { try emit($0) }
                    }
                }
            }
        }
    }

    /// The segments last appended, so the same ones again cost a flag.
    private var lastSegments: Data?

    /// Appends the segments the pane paired with the transaction `serial`,
    /// already in the log: those before it, or — `after` — those after it.
    public func appendSegments(of serial: UInt64, after: Bool, _ data: Data) throws {
        var body = UndoJournal.u64(serial) + [after ? 1 : 0]
        if data == lastSegments {
            body.append(0)
        } else {
            body += [1] + u32(UInt32(data.count)) + [UInt8](data)
        }
        try journal.appendRecord(HistoryLog.segmentsMagic, bodyLength: UInt64(body.count)) { try $0(body) }
        lastSegments = data
    }

    /// Appends a refined selection after the transaction `serial`, already in
    /// the log.
    public func appendSelection(after serial: UInt64, _ selection: SelectionModel) throws {
        let body = UndoJournal.u64(serial) + self.selection(selection)
        try journal.appendRecord(HistoryLog.selectionMagic, bodyLength: UInt64(body.count)) { try $0(body) }
    }

    /// Puts what was appended on the disk, before a manifest names it.
    public func synchronize() {
        journal.synchronize()
    }

    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func selection(_ s: SelectionModel) -> [UInt8] {
        UndoJournal.u64(s.start) + UndoJournal.u64(s.end) + UndoJournal.u64(s.fileSize)
    }
}
