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
        var base: KeptBase?
        var log: HistoryLogWriter?
        /// The serials of the transactions in the log, each to its parent.
        var parents: [UInt64: UInt64] = [:]
        /// What the last snapshot wrote down for this document.
        var kept: KeptContent?
        /// The content's version and the saved state when it was.
        var version: UndoHistory.Version?
        var saved: UInt64?

        init(document: BinaryDocument, id: String) {
            self.document = document
            self.id = id
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// The kept files the snapshot being taken named, so the ones nobody names
    /// any more can go once it is written.
    private var named: Set<String> = []
    /// The documents it kept, by their ids.
    private var namedIDs: Set<String> = []

    /// A log larger than this is let grow until it is twice what the history
    /// holds; then the content is written whole again and the log begins anew.
    var compactionFloor: UInt64 = 64 << 20

    init(folder: WorkspaceFolder, isProject: Bool = false) {
        self.folder = folder
        self.isProject = isProject
    }

    private static let editsEncoder: PropertyListEncoder = {
        // Binary: the added bytes go in as they are, not as base64 text.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    // MARK: - Writing

    /// The content of `pane`'s document as it now stands, written down: what
    /// changed since the last snapshot appended, the rest as it was. Nil for
    /// a file with nothing beyond what is on disk. When writing fails, what the
    /// last snapshot kept — still whole on disk — is kept again, and quitting
    /// asks about the document (`holdsCurrentBytes`).
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
        if entry.version != history.version || entry.saved != saved || entry.kept == nil {
            do {
                try update(entry, pane: pane, document: document, saved: saved)
            } catch {
                // The log was cut back to what the last snapshot pinned.
            }
        }
        if let kept = entry.kept {
            named.formUnion(kept.files)
            namedIDs.insert(entry.id)
        }
        return entry.kept
    }

    private func update(_ entry: Entry, pane: PaneViewModel, document: BinaryDocument, saved: UInt64?) throws {
        let history = document.undoHistory
        let epochMoved = entry.version.map { $0.epoch != history.version.epoch } ?? false
        var needsBase = entry.base == nil || entry.log == nil || epochMoved
        if case .file = entry.base, pane.isUntitled { needsBase = true }
        if !needsBase, let saved, saved != entry.saved {
            // Saved: the file on disk now holds the saved state, which the log
            // leads to — or the document was saved for the first time.
            entry.base = .file(serial: saved)
        }
        if needsBase {
            try rebase(entry, pane: pane, document: document, saved: saved)
        } else {
            try append(history.heldTransactions, to: entry)
            let tooLong = (entry.log?.length ?? 0) > max(compactionFloor, 2 * history.heldBytes)
            if tooLong || !HistoryLog.connects(entry.base!.serial, history.headSerial, parents: entry.parents) {
                try rebase(entry, pane: pane, document: document, saved: saved)
            }
        }
        entry.log?.synchronize()
        entry.kept = KeptContent(
            id: entry.id, base: entry.base!, head: history.headSerial, nextSerial: history.upcomingSerial,
            saved: saved,
            log: entry.log.map { KeptLog(file: $0.url.lastPathComponent, length: $0.length, hash: $0.hash.hex) })
        entry.version = history.version
        entry.saved = saved
    }

    /// Starts the document's content afresh: a new base, and a new log holding
    /// every transaction the history has. A file's base is the file itself when
    /// the history leads from its saved state; otherwise the content is written
    /// — whole for a document with no file, as runs over the file for one.
    private func rebase(_ entry: Entry, pane: PaneViewModel, document: BinaryDocument, saved: UInt64?) throws {
        let history = document.undoHistory
        let name = "\(entry.id)-\(UUID().uuidString.prefix(8))"
        try folder.prepareKeptFolder()
        let log = try HistoryLogWriter(creating: folder.keptURL(name + ".log"))
        let held = history.heldTransactions
        var parents: [UInt64: UInt64] = [:]
        for kept in held {
            try log.append(kept)
            parents[kept.transaction.serial] = kept.transaction.parent
        }
        let head = history.headSerial
        let base: KeptBase
        if let saved, HistoryLog.connects(saved, head, parents: parents) {
            base = .file(serial: saved)
        } else if saved != nil {
            guard let edits = pane.exportKeptEdits() else { throw StorageError.readFailed }
            let file = name + ".plist"
            try Self.editsEncoder.encode(edits).write(to: folder.keptURL(file), options: .atomic)
            base = .edits(file: file, serial: head)
        } else {
            let file = name + ".bin"
            try writeWhole(document, to: folder.keptURL(file))
            base = .bytes(file: file, serial: head)
        }
        entry.base = base
        entry.log = log
        entry.parents = parents
    }

    private func append(_ held: [KeptTransaction], to entry: Entry) throws {
        guard let log = entry.log else { return }
        for kept in held where entry.parents[kept.transaction.serial] == nil {
            try log.append(kept)
            entry.parents[kept.transaction.serial] = kept.transaction.parent
        }
    }

    /// The document's content, in slices, into a new file put in place whole.
    private func writeWhole(_ document: BinaryDocument, to url: URL) throws {
        let partial = url.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else { throw StorageError.writeFailed }
        defer { try? handle.close() }
        var at: UInt64 = 0
        let size = document.size
        while at < size {
            let count = Int(min(UInt64(1 << 20), size - at))
            try handle.write(contentsOf: try document.read(at: at, length: count))
            at += UInt64(count)
        }
        try handle.synchronize()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
    }

    /// The untitled document or part in `pane`, kept: its content, its name,
    /// whether it is dirty. Nil when nothing about it could be kept.
    func stamp(for pane: PaneViewModel) -> UntitledStamp? {
        guard pane.isUntitled, let document = pane.document, let content = keep(pane) else { return nil }
        return UntitledStamp(content: content, name: pane.untitledName, size: document.size,
                             dirty: pane.status.isDirty)
    }

    /// Whether what `pane` holds now is what the last snapshot kept — what
    /// lets quitting leave it unasked: it comes back at the next launch as it
    /// is.
    func holdsCurrentBytes(of pane: PaneViewModel) -> Bool {
        guard let document = pane.document,
              let entry = entries[ObjectIdentifier(document)], entry.document === document,
              entry.kept != nil else { return false }
        return entry.version == document.undoHistory.version
    }

    /// A snapshot is about to be taken.
    func beginSnapshot() {
        named = []
        namedIDs = []
    }

    /// The snapshot was written: the kept files it did not name belong to
    /// documents saved, closed or discarded, or were replaced by newer ones.
    func endSnapshot() {
        folder.removeKept(except: named)
        entries = entries.filter { $0.value.document != nil && namedIDs.contains($0.value.id) }
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

    /// The content of an untitled document or a part as it was kept.
    func bytes(of content: KeptContent) throws -> [UInt8] {
        guard case .bytes(let file, _) = content.base else { throw HistoryLogError.unreadable }
        let records = try records(of: content)
        let storage = EditOverlayStorage(base: try FileBackedStorage(url: folder.keptURL(file)))
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
        case .edits(let file, _):
            edits = try PropertyListDecoder().decode(OverlayEdits.self,
                                                     from: Data(contentsOf: folder.keptURL(file)))
        case .bytes:
            throw HistoryLogError.unreadable
        }
        try pane.applyKeptContent(edits: edits, ops: try ops(of: content, records))
        adopt(pane, content: content, records: records, dirty: true)
    }

    /// A restored document goes on as kept: its history counts on from where
    /// the kept one stopped, and the next snapshot appends to the same log.
    func adopt(_ pane: PaneViewModel, content: KeptContent, records: [KeptTransaction]? = nil, dirty: Bool) {
        guard let document = pane.document else { return }
        document.undoHistory.resume(at: content.head, nextSerial: content.nextSerial,
                                    saved: content.saved, dirty: dirty)
        let entry = Entry(document: document, id: content.id)
        entry.base = content.base
        if let log = content.log, let hash = Data(hex: log.hash) {
            entry.log = try? HistoryLogWriter(appendingTo: folder.keptURL(log.file), length: log.length, hash: hash)
        }
        let records = records ?? ((try? self.records(of: content)) ?? [])
        for record in records { entry.parents[record.transaction.serial] = record.transaction.parent }
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
