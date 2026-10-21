import CryptoKit
import Foundation

/// The bytes an undo op carries — what an overwrite had before and wrote, what
/// an insert added, what a delete removed.
///
/// An edit hands them over in memory; the history moves them into its journal
/// as it records the edit, and from then on only where they lie is held in
/// RAM (`Design/PERSISTENT_UNDO_PLAN.md`). A 512 MB replace used to cost its
/// size twice in memory for as long as it could be undone.
///
/// A fill's bytes are not kept at all: they are its pattern repeated over the
/// range, and that is what is held — a few bytes for a fill of a gigabyte.
///
/// Equality compares the bytes, wherever they are: a test's literal equals
/// the same bytes read back from a journal.
public struct UndoBytes: Equatable, Sendable, ExpressibleByArrayLiteral {
    enum Storage: Sendable {
        case inline([UInt8])
        case stored(UndoJournal, offset: UInt64, count: Int)
        /// `count` bytes of `pattern` repeated, from its first byte.
        case pattern([UInt8], count: Int)
    }

    let storage: Storage

    public init(_ bytes: [UInt8]) {
        storage = .inline(bytes)
    }

    public init(arrayLiteral elements: UInt8...) {
        storage = .inline(elements)
    }

    /// `count` bytes of `pattern` repeated from its first byte; the last
    /// repetition is cut short where the count ends.
    public init(pattern: [UInt8], count: Int) {
        storage = pattern.isEmpty || count == 0 ? .inline([]) : .pattern(pattern, count: count)
    }

    init(journal: UndoJournal, offset: UInt64, count: Int) {
        storage = .stored(journal, offset: offset, count: count)
    }

    public var count: Int {
        switch storage {
        case .inline(let bytes): return bytes.count
        case .stored(_, _, let count), .pattern(_, let count): return count
        }
    }

    /// What keeping these bytes costs: all of them, or a pattern's own length.
    var heldCount: Int {
        if case .pattern(let pattern, _) = storage { return pattern.count }
        return count
    }

    /// The bytes, read from the journal when they are there.
    public func load() throws -> [UInt8] {
        switch storage {
        case .inline(let bytes): return bytes
        case .stored(let journal, let offset, let count): return try journal.read(at: offset, count: count)
        case .pattern(let pattern, let count):
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            while bytes.count < count {
                bytes.append(contentsOf: pattern.prefix(count - bytes.count))
            }
            return bytes
        }
    }

    /// A pattern and the count it is repeated to, when the bytes are one.
    var patternForm: (pattern: [UInt8], count: Int)? {
        if case .pattern(let pattern, let count) = storage { return (pattern, count) }
        return nil
    }

    /// The bytes in slices of at most `size`, read from the journal one slice
    /// at a time: what writes them elsewhere without holding them whole.
    func forEachSlice(_ size: Int = UndoJournal.copySlice, _ body: ([UInt8]) throws -> Void) throws {
        switch storage {
        case .inline(let bytes):
            var at = 0
            while at < bytes.count {
                let end = min(at + size, bytes.count)
                try body(Array(bytes[at..<end]))
                at = end
            }
        case .stored(let journal, let offset, let count):
            var at = 0
            while at < count {
                let slice = min(size, count - at)
                try body(try journal.read(at: offset + UInt64(at), count: slice))
                at += slice
            }
        case .pattern:
            try body(try load())
        }
    }

    /// The journal these bytes lie in; nil while they are still in memory.
    var journal: UndoJournal? {
        if case .stored(let journal, _, _) = storage { return journal }
        return nil
    }

    public static func == (lhs: UndoBytes, rhs: UndoBytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard let left = try? lhs.load(), let right = try? rhs.load() else { return false }
        return left == right
    }
}

/// How deep a document's undo history may grow (`Design/PERSISTENT_UNDO_PLAN.md`,
/// "Bounds"). Past either bound, the oldest steps are dropped at the next edit.
/// Nil is no bound.
public struct UndoLimits: Equatable, Sendable {
    /// The bytes the ops carry, before and after alike.
    public var bytes: UInt64?
    /// Transactions; a typed byte is one.
    public var transactions: Int?

    public init(bytes: UInt64?, transactions: Int?) {
        self.bytes = bytes
        self.transactions = transactions
    }

    public static let unlimited = UndoLimits(bytes: nil, transactions: nil)
    public static let `default` = UndoLimits(bytes: 4 << 30, transactions: nil)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = UndoLimits.default

    /// The bounds every history without its own reads at each edit. Set by the
    /// app from its settings.
    public static var current: UndoLimits {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// The file a document's undo history keeps its bytes in — and, when a
/// workspace keeps the document, the same file its log is
/// (`Design/PERSISTENT_UNDO_PLAN.md`, "One journal").
///
/// Append-only, in framed records, each carrying the SHA-256 of the previous
/// record's hash and its own body (`HistoryLog`). An edit's bytes go in as a
/// `BRB1` record the moment the edit is recorded; a workspace's snapshot later
/// adds the transaction records that name them, without writing the bytes a
/// second time.
///
/// Made in a workspace's `Kept/` while one is recorded (`directoryProvider`),
/// and then registered as live, so tidying `Kept/` leaves it alone while a
/// document writes it. Otherwise made in the temporary directory and unlinked
/// at once: it goes when the history lets go of it, and a crash leaves
/// nothing behind. A journal is never rewritten in place — compacting means a
/// new journal, so bytes still pointing into the old one stay readable for as
/// long as they live.
public final class UndoJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    /// Where it is on disk; nil for a temporary journal, unlinked.
    public let url: URL?
    private var end: UInt64 = 0
    private var chain = HistoryLog.emptyHash

    /// Where a new journal is made: the `Kept/` of the workspace being
    /// recorded, or nil for the temporary directory. Set by the app.
    public static var directoryProvider: (() -> URL?)? {
        get { providerLock.withLock { provider } }
        set { providerLock.withLock { provider = newValue } }
    }
    private static let providerLock = NSLock()
    nonisolated(unsafe) private static var provider: (() -> URL?)?

    /// A new, empty journal in `directory`, or a temporary one.
    public init(directory: URL?) throws {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).log")
            let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw StorageError.writeFailed }
            self.fd = fd
            self.url = url
            Self.register(url)
        } else {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("ByteRipper-undo-\(UUID().uuidString)").path
            let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw StorageError.writeFailed }
            unlink(path)
            self.fd = fd
            self.url = nil
        }
    }

    /// A new, empty journal at `url` — a test's, or one a keeper makes.
    public init(creating url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw StorageError.writeFailed }
        self.fd = fd
        self.url = url
        Self.register(url)
    }

    /// The journal at `url` as a workspace pinned it — `length` bytes ending
    /// in the chained hash `hash` — taken up again: anything past `length` is
    /// cut off, and appending goes on from there.
    public init(continuing url: URL, length: UInt64, hash: Data) throws {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw StorageError.readFailed }
        var info = stat()
        guard fstat(fd, &info) == 0, UInt64(info.st_size) >= length, ftruncate(fd, off_t(length)) == 0 else {
            close(fd)
            throw StorageError.readFailed
        }
        self.fd = fd
        self.url = url
        self.end = length
        self.chain = hash
        Self.register(url)
    }

    /// A journal opened only to read it. Appending fails.
    init(reading url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw StorageError.readFailed }
        self.fd = fd
        self.url = nil
        var info = stat()
        end = fstat(fd, &info) == 0 ? UInt64(info.st_size) : 0
    }

    deinit {
        close(fd)
        if let url { Self.unregister(url) }
    }

    /// Bytes written so far: where the next record goes.
    public var length: UInt64 { lock.withLock { end } }

    /// The length and the chained hash at it, together: what a workspace
    /// pins the journal by.
    public func pin() -> (length: UInt64, hash: Data) {
        lock.withLock { (end, chain) }
    }

    /// Puts what was appended on the disk, before a workspace names it.
    public func synchronize() {
        _ = fsync(fd)
    }

    // MARK: - Live journals

    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: [String: Int] = [:]

    private static func register(_ url: URL) {
        liveLock.withLock { live[url.standardizedFileURL.path, default: 0] += 1 }
    }

    private static func unregister(_ url: URL) {
        liveLock.withLock {
            let path = url.standardizedFileURL.path
            live[path, default: 1] -= 1
            if live[path] == 0 { live[path] = nil }
        }
    }

    /// The names of the journals in `directory` an open document writes —
    /// files a workspace that does not name them yet must not remove.
    public static func liveNames(in directory: URL) -> Set<String> {
        let folder = directory.standardizedFileURL.path
        return liveLock.withLock {
            Set(live.keys.filter { ($0 as NSString).deletingLastPathComponent == folder }
                .map { ($0 as NSString).lastPathComponent })
        }
    }

    // MARK: - Records

    /// Appends one framed record: `kind`, the body's length, the body — given
    /// in pieces through `emit`, never whole — and the chained hash. Returns
    /// where the body starts. On failure the journal is cut back to where it
    /// was.
    @discardableResult
    func appendRecord(_ kind: [UInt8], bodyLength: UInt64,
                      _ body: (_ emit: ([UInt8]) throws -> Void) throws -> Void) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let start = end
        var out = Output(fd: fd, at: start)
        var hasher = SHA256()
        hasher.update(data: chain)
        do {
            try out.write(kind)
            try out.write(Self.u64(bodyLength))
            let bodyStart = out.position
            try body { bytes in
                hasher.update(data: bytes)
                try out.write(bytes)
            }
            guard out.position - bodyStart == bodyLength else { throw StorageError.writeFailed }
            let digest = Data(hasher.finalize())
            try out.write([UInt8](digest))
            try out.flush()
            end = out.position
            chain = digest
            return bodyStart
        } catch {
            _ = ftruncate(fd, off_t(start))
            throw error
        }
    }

    /// Appends `bytes` as a `BRB1` record, returning where they start.
    func appendBlob(_ bytes: [UInt8]) throws -> UInt64 {
        try appendRecord(HistoryLog.blobMagic, bodyLength: UInt64(bytes.count)) { emit in try emit(bytes) }
    }

    static func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// Writes through a buffer of a slice's size.
    private struct Output {
        let fd: Int32
        var at: UInt64
        var pending: [UInt8] = []
        var position: UInt64 { at + UInt64(pending.count) }

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

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { raw in
            var done = 0
            while done < count {
                let n = pread(fd, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                guard n > 0 else { throw StorageError.readFailed }
                done += n
            }
        }
        return bytes
    }

    /// The bytes stored here, as bytes stored in this journal: appended when
    /// they are in memory or in another journal, kept as they are when they
    /// already lie here. A large run is copied in slices, never read whole.
    func store(_ bytes: UndoBytes) throws -> UndoBytes {
        switch bytes.storage {
        case .inline(let inline):
            guard !inline.isEmpty else { return bytes }
            return UndoBytes(journal: self, offset: try appendBlob(inline), count: inline.count)
        case .pattern:
            return bytes
        case .stored(let other, let offset, let count):
            if other === self { return bytes }
            let start = try appendRecord(HistoryLog.blobMagic, bodyLength: UInt64(count)) { emit in
                var copied = 0
                while copied < count {
                    let slice = min(Self.copySlice, count - copied)
                    try emit(try other.read(at: offset + UInt64(copied), count: slice))
                    copied += slice
                }
            }
            return UndoBytes(journal: self, offset: start, count: count)
        }
    }

    static let copySlice = 1 << 20
}
