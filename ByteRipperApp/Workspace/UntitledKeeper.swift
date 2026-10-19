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
///
/// Inside a project it also keeps the unsaved changes of files on disk
/// (`keepsFileEdits`), as runs over each file (`OverlayEdits`), by the same
/// rule: written again only when the content moved.
@MainActor
final class UntitledKeeper {
    private let folder: WorkspaceFolder
    /// True for a project: its files' unsaved changes are part of it. The
    /// session the app keeps by itself asks about them at quit instead.
    let keepsFileEdits: Bool
    /// The folder a project's files are found relative to; nil outside one.
    var relativeBase: URL? { keepsFileEdits ? folder.enclosingFolder : nil }

    private struct Entry {
        weak var document: BinaryDocument?
        let id: String
        var written: UndoHistory.Version?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var editEntries: [ObjectIdentifier: Entry] = [:]
    /// The ids the snapshot being taken named, so the copies nobody names any
    /// more can go once it is written.
    private var named: Set<String> = []
    private var namedEdits: Set<String> = []

    init(folder: WorkspaceFolder, keepsFileEdits: Bool = false) {
        self.folder = folder
        self.keepsFileEdits = keepsFileEdits
    }

    private static let editsEncoder: PropertyListEncoder = {
        // Binary: the added bytes go in as they are, not as base64 text.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    /// The name the unsaved changes of `pane`'s file are kept under, written
    /// first if they moved. Nil for a clean file, outside a project, or when
    /// they could not be written.
    func editsStamp(for pane: PaneViewModel) -> String? {
        guard keepsFileEdits, !pane.isUntitled, let document = pane.document, document.isDirty else { return nil }
        let key = ObjectIdentifier(document)
        var entry = editEntries[key].flatMap { $0.document === document ? $0 : nil }
            ?? Entry(document: document, id: UUID().uuidString, written: nil)
        let version = document.undoHistory.version
        if entry.written != version {
            guard let edits = pane.exportKeptEdits(),
                  let data = try? Self.editsEncoder.encode(edits),
                  (try? folder.writeEdits(entry.id, data: data)) != nil else { return nil }
            entry.written = version
        }
        editEntries[key] = entry
        namedEdits.insert(entry.id)
        return entry.id
    }

    /// The unsaved changes kept under `id`.
    func edits(_ id: String) -> OverlayEdits? {
        folder.readEdits(id).flatMap { try? PropertyListDecoder().decode(OverlayEdits.self, from: $0) }
    }

    /// A restored file's changes go on under the name they were kept by.
    func adoptEdits(_ pane: PaneViewModel, as id: String) {
        guard let document = pane.document else { return }
        editEntries[ObjectIdentifier(document)] = Entry(document: document, id: id,
                                                        written: document.undoHistory.version)
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

    /// Whether the bytes `pane` holds now are the ones last written for it —
    /// what lets quitting leave them unasked: they come back at the next
    /// launch as they are.
    func holdsCurrentBytes(of pane: PaneViewModel) -> Bool {
        guard let document = pane.document else { return false }
        let map = pane.isUntitled ? entries : editEntries
        guard let entry = map[ObjectIdentifier(document)], entry.document === document else { return false }
        return entry.written == document.undoHistory.version
    }

    /// A snapshot is about to be taken.
    func beginSnapshot() {
        named = []
        namedEdits = []
    }

    /// The snapshot was written: the copies it did not name belong to
    /// documents that were saved, closed or discarded.
    func endSnapshot() {
        folder.removeUntitled(except: named)
        entries = entries.filter { $0.value.document != nil && named.contains($0.value.id) }
        folder.removeEdits(except: namedEdits)
        editEntries = editEntries.filter { $0.value.document != nil && namedEdits.contains($0.value.id) }
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
