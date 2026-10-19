import ByteRipperCore
import Foundation
import Workspace

/// Keeps a copy of every untitled document's bytes beside the workspace, so a
/// crash does not take a join or a New File with it
/// (`Design/WORKSPACE_PLAN.md`, "Untitled documents").
///
/// A document is named by an id it keeps for its whole life; its bytes are
/// written again only when its content's version (`UndoHistory.version`) has
/// moved since the last write, so an untitled document nobody is editing costs
/// nothing after the first snapshot.
@MainActor
final class UntitledKeeper {
    private let folder: WorkspaceFolder

    private struct Entry {
        weak var document: BinaryDocument?
        let id: String
        var written: UndoHistory.Version?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// The ids the snapshot being taken named, so the copies nobody names any
    /// more can go once it is written.
    private var named: Set<String> = []

    init(folder: WorkspaceFolder) {
        self.folder = folder
    }

    /// The stamp `pane`'s untitled document is written down as, its bytes
    /// written first if they changed. Nil when the bytes could not be written:
    /// a workspace must never name bytes that are not there.
    func stamp(for pane: PaneViewModel) -> UntitledStamp? {
        guard pane.isUntitled, let document = pane.document else { return nil }
        let key = ObjectIdentifier(document)
        var entry = entries[key].flatMap { $0.document === document ? $0 : nil }
            ?? Entry(document: document, id: UUID().uuidString, written: nil)
        let version = document.undoHistory.version
        if entry.written != version {
            do {
                let bytes = try document.read(at: 0, length: Int(document.size))
                try folder.writeUntitled(entry.id, bytes: Data(bytes))
                entry.written = version
            } catch {
                return nil
            }
        }
        entries[key] = entry
        named.insert(entry.id)
        return UntitledStamp(id: entry.id, name: pane.untitledName, size: document.size,
                             dirty: pane.status.isDirty)
    }

    /// A snapshot is about to be taken.
    func beginSnapshot() {
        named = []
    }

    /// The snapshot was written: the copies it did not name belong to
    /// documents that were saved, closed or discarded.
    func endSnapshot() {
        folder.removeUntitled(except: named)
        entries = entries.filter { $0.value.document != nil && named.contains($0.value.id) }
    }

    /// The bytes a written-down untitled document had.
    func bytes(for stamp: UntitledStamp) -> Data? {
        folder.readUntitled(stamp.id)
    }

    /// A restored document goes on under the id it was written down with, and
    /// its bytes on disk are already the ones it holds.
    func adopt(_ pane: PaneViewModel, as stamp: UntitledStamp) {
        guard let document = pane.document else { return }
        entries[ObjectIdentifier(document)] = Entry(document: document, id: stamp.id,
                                                    written: document.undoHistory.version)
    }
}
