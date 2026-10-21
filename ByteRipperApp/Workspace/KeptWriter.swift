import ByteRipperCore
import Foundation
import Workspace

/// What a snapshot hands the background to write for one document
/// (`ContentKeeper`). Values only: the transactions' bytes are read from where
/// they lie — the history's journal, a kept log, memory — none of which the
/// main thread rewrites.
enum KeptWrite: @unchecked Sendable {
    /// A restored document: its log — the journal the history goes on
    /// writing — taken up as the workspace pinned it.
    case resume(id: String, base: KeptBase, journal: UndoJournal?)
    /// The content afresh: the history's journal as its log, every transaction
    /// the history holds recorded in it — naming the bytes already there — the
    /// segments paired with them, and the base.
    case rebase(id: String, journal: UndoJournal?, base: PendingBase, held: [KeptTransaction],
                segments: [SegmentWrite])
    /// What changed since the last snapshot: transactions not in the log yet,
    /// selections refined after ones that are, segments paired anew — and a
    /// new base when a save made the file on disk the base.
    case append(id: String, records: [KeptTransaction], selections: [(UInt64, SelectionModel)],
                segments: [SegmentWrite], base: KeptBase?)

    var id: String {
        switch self {
        case .resume(let id, _, _), .rebase(let id, _, _, _, _), .append(let id, _, _, _, _): return id
        }
    }
}

/// A base still to be written.
enum PendingBase {
    /// The file on disk, which holds the state `serial` names: nothing to write.
    case file(serial: UInt64)
    /// The base already written, which a new log still leads from: kept as
    /// the writer has it, its hash included.
    case unchanged
    /// Runs over the file, encoded already.
    case edits(file: String, serial: UInt64, data: Data)
    /// The whole content, read from a snapshot nothing changes any more; the
    /// store keeps whatever the snapshot needs on disk alive until it is read.
    case bytes(file: String, serial: UInt64, content: any ByteStorage, store: TemporaryFileStore)
}

/// Segments paired with a transaction: before it, or after it.
struct SegmentWrite {
    let serial: UInt64
    let after: Bool
    let data: Data
}

/// Writes what snapshots of a workspace decided, off the main thread
/// (`Design/PERSISTENT_UNDO_PLAN.md`): the logs and bases in `Kept/`, then
/// the workspace file, with each content's base and log as they came out —
/// lengths and hashes the main thread cannot know before the bytes are
/// written. One serial queue: the snapshots land in the order they were taken.
///
/// A snapshot whose writes all went through is written down, and the kept
/// files it does not name are removed after it. One that failed is not: the
/// workspace on disk stays the last whole one, and the document that failed is
/// started afresh by the next snapshot (`takeFailures`).
final class KeptWriter: @unchecked Sendable {
    let folder: WorkspaceFolder
    private let queue = DispatchQueue(label: "ByteRipper.KeptWriter", qos: .utility)

    /// Queue-only: each document's base and log as written.
    private struct Kept {
        var base: KeptBase
        var log: HistoryLogWriter?
    }
    private var kept: [String: Kept] = [:]

    private let lock = NSLock()
    private var failed: Set<String> = []
    private var lastSnapshotWritten = true

    init(folder: WorkspaceFolder) {
        self.folder = folder
    }

    /// Writes `writes`, then `workspace` with its kept content filled in, then
    /// removes the kept files `named` does not list. Documents not in `ids` are
    /// forgotten. Returns at once.
    func commit(_ writes: [KeptWrite], workspace: Workspace, named: Set<String>, ids: Set<String>) {
        queue.async { [self] in
            var whole = true
            for write in writes {
                do {
                    try perform(write)
                } catch {
                    whole = false
                    lock.withLock { _ = failed.insert(write.id) }
                }
            }
            for id in Set(writes.map(\.id)) { kept[id]?.log?.synchronize() }
            guard whole else { return setWritten(false) }
            let filled = fill(workspace)
            do {
                try folder.write(filled)
            } catch {
                return setWritten(false)
            }
            // Documents no longer kept let go of their journals first; a
            // journal an open document still writes stays, named yet or not.
            kept = kept.filter { ids.contains($0.key) }
            folder.removeKept(except: named.union(UndoJournal.liveNames(in: folder.keptFolder)))
            setWritten(true)
        }
    }

    /// Writes `writes` with no workspace after them: a restored document taken
    /// up again.
    func submit(_ writes: [KeptWrite]) {
        queue.async { [self] in
            for write in writes {
                do { try perform(write) } catch { lock.withLock { _ = failed.insert(write.id) } }
            }
        }
    }

    /// Runs `work` on the queue, after everything submitted before it.
    func enqueue(_ work: @escaping @Sendable (WorkspaceFolder) -> Void) {
        queue.async { [folder] in work(folder) }
    }

    /// `workspace` with each kept content's base and log as written so far,
    /// once everything submitted before is.
    func filled(_ workspace: Workspace) -> Workspace {
        queue.sync { fill(workspace) }
    }

    /// Queue-only.
    private func fill(_ workspace: Workspace) -> Workspace {
        workspace.updatingKept { content in
            guard let written = kept[content.id] else { return content }
            var content = content
            content.base = written.base
            content.log = written.log.map {
                KeptLog(file: $0.url.lastPathComponent, length: $0.length, hash: $0.hash.hex)
            }
            return content
        }
    }

    /// Waits until everything submitted so far is written.
    func flush() {
        queue.sync {}
    }

    /// The documents whose writes failed since the last call — to be started
    /// afresh.
    func takeFailures() -> Set<String> {
        lock.withLock {
            defer { failed = [] }
            return failed
        }
    }

    /// Whether `id` failed, without taking it.
    func hasFailed(_ id: String) -> Bool { lock.withLock { failed.contains(id) } }

    /// Whether the last snapshot was written whole.
    var lastSnapshotWasWritten: Bool { lock.withLock { lastSnapshotWritten } }

    private func setWritten(_ written: Bool) {
        lock.withLock { lastSnapshotWritten = written }
    }

    // MARK: - Queue

    private func perform(_ write: KeptWrite) throws {
        switch write {
        case let .resume(id, base, journal):
            kept[id] = Kept(base: base, log: journal.map(HistoryLogWriter.init(journal:)))
        case let .rebase(id, journal, pending, held, segments):
            try folder.prepareKeptFolder()
            let log = journal.map(HistoryLogWriter.init(journal:))
            for record in held { try log?.append(record) }
            for segment in segments { try log?.appendSegments(of: segment.serial, after: segment.after, segment.data) }
            let base: KeptBase
            switch pending {
            case let .file(serial):
                base = .file(serial: serial)
            case .unchanged:
                guard let current = kept[id]?.base else { throw StorageError.writeFailed }
                base = current
            case let .edits(file, serial, data):
                try data.write(to: folder.keptURL(file), options: .atomic)
                base = .edits(file: file, serial: serial, hash: FileDigest.sha256(data).hex)
            case let .bytes(file, serial, content, store):
                let hash = try Self.writeWhole(content, to: folder.keptURL(file))
                withExtendedLifetime(store) {}
                base = .bytes(file: file, serial: serial, hash: hash.hex)
            }
            kept[id] = Kept(base: base, log: log)
        case let .append(id, records, selections, segments, base):
            guard var current = kept[id], let log = current.log else { throw StorageError.writeFailed }
            for record in records { try log.append(record) }
            for (serial, selection) in selections { try log.appendSelection(after: serial, selection) }
            for segment in segments { try log.appendSegments(of: segment.serial, after: segment.after, segment.data) }
            if let base { current.base = base }
            kept[id] = current
        }
    }

    /// `content`, in slices, into a new file put in place whole. Returns its
    /// SHA-256, made as it was written.
    private static func writeWhole(_ content: any ByteStorage, to url: URL) throws -> Data {
        let partial = url.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else { throw StorageError.writeFailed }
        defer { try? handle.close() }
        var digest = FileDigest.Running()
        var at: UInt64 = 0
        let size = content.size
        while at < size {
            let count = Int(min(UInt64(1 << 20), size - at))
            let slice = try content.read(at: at, length: count)
            digest.update(slice)
            try handle.write(contentsOf: slice)
            at += UInt64(count)
        }
        try handle.synchronize()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        return digest.finalize()
    }
}
