import Foundation

/// The bytes an undo op carries — what an overwrite had before and wrote, what
/// an insert added, what a delete removed.
///
/// An edit hands them over in memory; the history moves them into its journal
/// as it records the edit, and from then on only where they lie is held in
/// RAM (`Design/PERSISTENT_UNDO_PLAN.md`). A 512 MB replace used to cost its
/// size twice in memory for as long as it could be undone.
///
/// Equality compares the bytes, wherever they are: a test's literal equals
/// the same bytes read back from a journal.
public struct UndoBytes: Equatable, Sendable, ExpressibleByArrayLiteral {
    enum Storage: Sendable {
        case inline([UInt8])
        case stored(UndoJournal, offset: UInt64, count: Int)
    }

    let storage: Storage

    public init(_ bytes: [UInt8]) {
        storage = .inline(bytes)
    }

    public init(arrayLiteral elements: UInt8...) {
        storage = .inline(elements)
    }

    init(journal: UndoJournal, offset: UInt64, count: Int) {
        storage = .stored(journal, offset: offset, count: count)
    }

    public var count: Int {
        switch storage {
        case .inline(let bytes): return bytes.count
        case .stored(_, _, let count): return count
        }
    }

    /// The bytes, read from the journal when they are there.
    public func load() throws -> [UInt8] {
        switch storage {
        case .inline(let bytes): return bytes
        case .stored(let journal, let offset, let count): return try journal.read(at: offset, count: count)
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

/// An append-only file the bytes of a document's undo history live in.
///
/// Unlinked as soon as it is opened: the file goes when the history lets go of
/// it, and a crash leaves nothing behind in the temporary directory. A journal
/// is never rewritten in place — compacting means a new journal, so bytes
/// still pointing into the old one stay readable for as long as they live.
final class UndoJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    /// Bytes written so far: the offset the next append lands at.
    private(set) var length: UInt64 = 0

    init(directory: URL = FileManager.default.temporaryDirectory) throws {
        let path = directory.appendingPathComponent("ByteRipper-undo-\(UUID().uuidString)").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StorageError.writeFailed }
        unlink(path)
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Appends `bytes`, returning the offset they start at.
    func append(_ bytes: [UInt8]) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let offset = length
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(offset) + off_t(done))
                guard n > 0 else { throw StorageError.writeFailed }
                done += n
            }
        }
        length += UInt64(bytes.count)
        return offset
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
            return UndoBytes(journal: self, offset: try append(inline), count: inline.count)
        case .stored(let other, let offset, let count):
            if other === self { return bytes }
            let start = length
            var copied = 0
            while copied < count {
                let slice = min(Self.copySlice, count - copied)
                _ = try append(try other.read(at: offset + UInt64(copied), count: slice))
                copied += slice
            }
            return UndoBytes(journal: self, offset: start, count: count)
        }
    }

    static let copySlice = 1 << 20
}
