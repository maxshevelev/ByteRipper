import CryptoKit
import Foundation

/// A transaction as a kept history writes it down: the transaction, and the
/// two things about it its step knows — the typing series it belongs to and
/// the name the menu gives it.
public struct KeptTransaction: Equatable, Sendable {
    public let transaction: UndoTransaction
    public let seriesID: UInt64?
    public let label: String?

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
    public static func read(_ url: URL, length: UInt64, hash: Data) throws -> [KeptTransaction] {
        guard length > 0 else {
            guard hash == emptyHash else { throw HistoryLogError.unreadable }
            return []
        }
        let file = try UndoJournal(reading: url)
        guard file.length >= length else { throw HistoryLogError.unreadable }
        var reader = Reader(file: file, end: length)
        var chain = emptyHash
        var records: [KeptTransaction] = []
        var index: [UInt64: Int] = [:]
        do {
            while reader.at < length {
                let kind = try reader.bytes(4, hashing: false)
                guard kind == magic || kind == selectionMagic else { throw HistoryLogError.unreadable }
                let bodyLength = try reader.u64(hashing: false)
                guard bodyLength <= length - reader.at else { throw HistoryLogError.unreadable }
                reader.hasher = SHA256()
                reader.hasher.update(data: chain)
                let bodyEnd = reader.at + bodyLength
                if kind == magic {
                    let record = try reader.transaction()
                    index[record.transaction.serial] = records.count
                    records.append(record)
                } else {
                    let serial = try reader.u64()
                    let selection = try reader.selection()
                    guard let at = index[serial] else { throw HistoryLogError.unreadable }
                    var transaction = records[at].transaction
                    transaction.setSelectionAfter(selection)
                    records[at] = KeptTransaction(transaction: transaction, seriesID: records[at].seriesID,
                                                  label: records[at].label)
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

        init(file: UndoJournal, end: UInt64) {
            self.file = file
            self.end = end
        }

        mutating func bytes(_ count: Int, hashing: Bool = true) throws -> [UInt8] {
            guard UInt64(count) <= end - at else { throw HistoryLogError.unreadable }
            let bytes = try file.read(at: at, count: count)
            if hashing { hasher.update(data: bytes) }
            at += UInt64(count)
            return bytes
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
                var left = count
                while left > 0 {
                    let slice = Int(min(left, UInt64(UndoJournal.copySlice)))
                    _ = try bytes(slice)
                    left -= UInt64(slice)
                }
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

/// Appends records to a kept history's log.
public final class HistoryLogWriter {
    public let url: URL
    /// Where the next record goes: the length a manifest pins the log at.
    public private(set) var length: UInt64
    /// The chained hash at `length`.
    public private(set) var hash: Data
    private let fd: Int32

    /// A new, empty log at `url`.
    public convenience init(creating url: URL) throws {
        try self.init(url: url, length: 0, hash: HistoryLog.emptyHash, truncating: true)
    }

    /// The log at `url` as a manifest pinned it: anything past `length` is
    /// cut off before the next record goes on.
    public convenience init(appendingTo url: URL, length: UInt64, hash: Data) throws {
        try self.init(url: url, length: length, hash: hash, truncating: false)
    }

    private init(url: URL, length: UInt64, hash: Data, truncating: Bool) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | (truncating ? O_TRUNC : 0), 0o600)
        guard fd >= 0 else { throw StorageError.writeFailed }
        var info = stat()
        guard fstat(fd, &info) == 0, UInt64(info.st_size) >= length, ftruncate(fd, off_t(length)) == 0 else {
            close(fd)
            throw StorageError.writeFailed
        }
        self.url = url
        self.fd = fd
        self.length = length
        self.hash = hash
    }

    deinit {
        close(fd)
    }

    /// Appends one record. On failure the log is cut back to where it was.
    public func append(_ kept: KeptTransaction) throws {
        let txn = kept.transaction
        var head = Encoder()
        head.u64(txn.serial)
        head.u64(txn.parent)
        head.selection(txn.selectionBefore)
        head.selection(txn.selectionAfter)
        head.u8(kept.seriesID == nil ? 0 : 1)
        head.u64(kept.seriesID ?? 0)
        let label = Array((kept.label ?? "").utf8)
        head.u32(UInt32(label.count))
        head.bytes(label)
        head.u32(UInt32(txn.ops.count))
        // The body's length is known before a byte of payload is read: the
        // header, then each op's fixed part and its payloads' sizes.
        var bodyLength = UInt64(head.buffer.count)
        func payloadLength(_ bytes: UndoBytes) -> UInt64 {
            if let form = bytes.patternForm { return 1 + 8 + 4 + UInt64(form.pattern.count) }
            return 1 + 8 + UInt64(bytes.count)
        }
        for op in txn.ops {
            bodyLength += 1 + 16
            switch op {
            case .overwrite(_, let before, let after): bodyLength += payloadLength(before) + payloadLength(after)
            case .insert(_, let bytes), .delete(_, let bytes): bodyLength += payloadLength(bytes)
            }
        }

        var out = Output(fd: fd, at: length)
        var hasher = SHA256()
        hasher.update(data: hash)
        do {
            try out.write(HistoryLog.magic)
            var lengthField = Encoder()
            lengthField.u64(bodyLength)
            try out.write(lengthField.buffer)
            func body(_ bytes: [UInt8]) throws {
                hasher.update(data: bytes)
                try out.write(bytes)
            }
            try body(head.buffer)
            func payload(_ bytes: UndoBytes) throws {
                var field = Encoder()
                if let form = bytes.patternForm {
                    field.u8(1)
                    field.u64(UInt64(form.count))
                    field.u32(UInt32(form.pattern.count))
                    field.bytes(form.pattern)
                    try body(field.buffer)
                } else {
                    field.u8(0)
                    field.u64(UInt64(bytes.count))
                    try body(field.buffer)
                    try bytes.forEachSlice { try body($0) }
                }
            }
            for op in txn.ops {
                var fixed = Encoder()
                switch op {
                case .overwrite(let range, let before, let after):
                    fixed.u8(0); fixed.u64(range.lowerBound); fixed.u64(range.upperBound)
                    try body(fixed.buffer)
                    try payload(before)
                    try payload(after)
                case .insert(let at, let bytes):
                    fixed.u8(1); fixed.u64(at); fixed.u64(0)
                    try body(fixed.buffer)
                    try payload(bytes)
                case .delete(let range, let bytes):
                    fixed.u8(2); fixed.u64(range.lowerBound); fixed.u64(range.upperBound)
                    try body(fixed.buffer)
                    try payload(bytes)
                }
            }
            let digest = Data(hasher.finalize())
            try out.write([UInt8](digest))
            try out.flush()
            length = out.at
            hash = digest
        } catch {
            _ = ftruncate(fd, off_t(length))
            throw error
        }
    }

    /// Appends a refined selection after the transaction `serial`, already in
    /// the log.
    public func appendSelection(after serial: UInt64, _ selection: SelectionModel) throws {
        var body = Encoder()
        body.u64(serial)
        body.selection(selection)
        var frame = Encoder()
        frame.bytes(HistoryLog.selectionMagic)
        frame.u64(UInt64(body.buffer.count))
        var hasher = SHA256()
        hasher.update(data: hash)
        hasher.update(data: body.buffer)
        let digest = Data(hasher.finalize())
        var out = Output(fd: fd, at: length)
        do {
            try out.write(frame.buffer + body.buffer + [UInt8](digest))
            try out.flush()
            length = out.at
            hash = digest
        } catch {
            _ = ftruncate(fd, off_t(length))
            throw error
        }
    }

    /// Puts what was appended on the disk, before a manifest names it.
    public func synchronize() {
        _ = fsync(fd)
    }

    private struct Encoder {
        var buffer: [UInt8] = []
        mutating func u8(_ v: UInt8) { buffer.append(v) }
        mutating func u32(_ v: UInt32) { for i in 0..<4 { buffer.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        mutating func u64(_ v: UInt64) { for i in 0..<8 { buffer.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        mutating func bytes(_ b: [UInt8]) { buffer += b }
        mutating func selection(_ s: SelectionModel) { u64(s.start); u64(s.end); u64(s.fileSize) }
    }

    /// Writes through a buffer of a slice's size.
    private struct Output {
        let fd: Int32
        var at: UInt64
        var pending: [UInt8] = []

        init(fd: Int32, at: UInt64) {
            self.fd = fd
            self.at = at
        }

        mutating func write(_ bytes: [UInt8]) throws {
            pending += bytes
            if pending.count >= UndoJournal.copySlice { try flush() }
        }

        mutating func flush() throws {
            try pending.withUnsafeBytes { raw in
                var done = 0
                while done < raw.count {
                    let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(at) + off_t(done))
                    guard n > 0 else { throw StorageError.writeFailed }
                    done += n
                }
            }
            at += UInt64(pending.count)
            pending.removeAll(keepingCapacity: true)
        }
    }
}
