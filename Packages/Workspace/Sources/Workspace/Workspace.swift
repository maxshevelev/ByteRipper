import Foundation

/// The session as it is written down: every window, its tabs in order, and
/// what each tab had open and where (`Design/WORKSPACE_PLAN.md`).
///
/// A value, gathered from the live windows and applied back to new ones. It
/// names files by path and says what they were like when it was taken
/// (`FileStamp`), so the restore can tell a file that is still the same from
/// one that was rewritten in between.
public struct Workspace: Codable, Equatable, Sendable {
    /// The version this build writes. A file of another version is ignored
    /// rather than migrated: losing a workspace is an inconvenience, misreading
    /// one is not acceptable.
    public static let currentVersion = 4

    public var version: Int
    /// Front to back, as `NSApp.orderedWindows` lists them.
    public var windows: [WindowState]

    public init(windows: [WindowState]) {
        self.version = Self.currentVersion
        self.windows = windows
    }

    /// Nothing to bring back: no window has a tab with anything open in it,
    /// and the Annotations window was closed.
    public var isEmpty: Bool {
        windows.allSatisfy { $0.notes == nil && $0.tabs.allSatisfy(\.isEmpty) }
    }
}

/// One window: where it stood, and its tabs left to right.
public struct WindowState: Codable, Equatable, Sendable {
    public var frame: Rect
    public var tabs: [TabState]
    /// The tab on screen, as an index into `tabs`.
    public var selectedTab: Int
    /// The Annotations window, when it is this window or one of its tabs.
    public var notes: NotesState?

    public init(frame: Rect, tabs: [TabState], selectedTab: Int, notes: NotesState? = nil) {
        self.frame = frame
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.notes = notes
    }
}

extension Workspace {
    /// The workspace with every kept content in it — a file's, an untitled
    /// document's, a part's, in a tab or a panel — passed through `transform`:
    /// what fills in a content's base and log once they are written.
    public func updatingKept(_ transform: (KeptContent) -> KeptContent) -> Workspace {
        func pane(_ state: PaneState) -> PaneState {
            var state = state
            state.kept = state.kept.map(transform)
            switch state.document {
            case .file: break
            case .untitled(var stamp):
                stamp.content = transform(stamp.content)
                state.document = .untitled(stamp)
            case .part(var origin):
                if var edits = origin.edits {
                    edits.content = transform(edits.content)
                    origin.edits = edits
                }
                state.document = .part(origin)
            }
            return state
        }
        var copy = self
        for w in copy.windows.indices {
            for t in copy.windows[w].tabs.indices {
                copy.windows[w].tabs[t].panes = copy.windows[w].tabs[t].panes.map { $0.map(pane) }
                for f in copy.windows[w].tabs[t].fragments.indices {
                    copy.windows[w].tabs[t].fragments[f].pane = pane(copy.windows[w].tabs[t].fragments[f].pane)
                }
            }
        }
        return copy
    }
}

/// The Annotations window: where it stands among the window's tabs, and which
/// cards were selected. The annotations themselves are kept in a file of
/// their own, with ids that last from one launch to the next.
public struct NotesState: Codable, Equatable, Sendable {
    /// Its place in the tab bar: before `tabs[position]`, or after the last
    /// tab when it equals `tabs.count`.
    public var position: Int
    /// Whether it was the tab on screen; `selectedTab` is then not.
    public var isSelected: Bool
    /// The annotations' ids, as `Annotations.json` keeps them.
    public var selected: [String]

    public init(position: Int, isSelected: Bool, selected: [String]) {
        self.position = position
        self.isSelected = isSelected
        self.selected = selected
    }
}

/// A window's frame, in screen coordinates. Its own type rather than `CGRect`
/// so the package needs nothing from CoreGraphics and the file reads plainly.
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One tab: File A and File B, which of them has the keyboard, and the
/// tab-wide state around them.
public struct TabState: Codable, Equatable, Sendable {
    /// File A, then File B. Nil for a slot with nothing open.
    public var panes: [PaneState?]
    public var activePane: Int
    /// The share of the split the first pane takes in a comparison (0...1).
    /// Nil outside a comparison.
    public var dividerFraction: Double?
    /// The tab's bookmarks: one list for both panes, by row (§20).
    public var bookmarks: [BookmarkState]
    /// The minimap and the Find bar.
    public var surface: SurfaceState
    /// The panels over the tab, in the order they were opened — a parent
    /// always before the parts taken out of it.
    public var fragments: [FragmentState]
    /// The panel in front, as an index into `fragments`; nil when the tab's
    /// own panes are.
    public var expandedFragment: Int?

    public init(panes: [PaneState?], activePane: Int, dividerFraction: Double? = nil,
                bookmarks: [BookmarkState] = [], surface: SurfaceState = SurfaceState(),
                fragments: [FragmentState] = [], expandedFragment: Int? = nil) {
        self.panes = panes
        self.activePane = activePane
        self.dividerFraction = dividerFraction
        self.bookmarks = bookmarks
        self.surface = surface
        self.fragments = fragments
        self.expandedFragment = expandedFragment
    }

    /// A tab with no file in it: an empty window, worth a tab only if it was
    /// the last thing open.
    public var isEmpty: Bool { panes.allSatisfy { $0 == nil } }
}

/// One pane: the document in it, and where the reader was in it.
public struct PaneState: Codable, Equatable, Sendable {
    /// What the parts taken out of this pane name it by (`PartOrigin.parent`).
    /// Unique within one workspace, meaningless outside it.
    public var id: String?
    public var document: DocumentSource
    /// The selection, half-open; an empty one is the caret.
    public var selectionStart: UInt64
    public var selectionEnd: UInt64
    /// Whether typing goes to the hex column or the text column.
    public var inputRegion: InputRegion
    public var insertMode: Bool
    /// The first byte on screen.
    public var topOffset: UInt64
    /// The pieces the file was cut into, when it was cut. Nil for a file that
    /// is one piece of itself.
    public var segments: SegmentationState?
    /// The rows the UEFI panel had open, each a node's path in the tree.
    public var uefiOpenRows: [[Int]]?
    /// A file's content beyond what is on disk — its unsaved changes and the
    /// history that made them — kept beside the workspace. Nil for a file
    /// with neither.
    public var kept: KeptContent?

    public init(id: String? = nil, document: DocumentSource,
                selectionStart: UInt64, selectionEnd: UInt64,
                inputRegion: InputRegion = .hex, insertMode: Bool = false,
                topOffset: UInt64, segments: SegmentationState? = nil, uefiOpenRows: [[Int]]? = nil,
                kept: KeptContent? = nil) {
        self.id = id
        self.document = document
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.inputRegion = inputRegion
        self.insertMode = insertMode
        self.topOffset = topOffset
        self.segments = segments
        self.uefiOpenRows = uefiOpenRows
        self.kept = kept
    }
}

public enum InputRegion: String, Codable, Equatable, Sendable {
    case hex
    case text
}

/// Where a pane's bytes come from.
public enum DocumentSource: Codable, Equatable, Sendable {
    /// A file on disk, as it was when the workspace was written.
    case file(FileStamp)
    /// A document with no file — New, a join, a duplicate — whose content the
    /// workspace keeps beside itself (`KeptContent`).
    case untitled(UntitledStamp)
    /// A part of another document, decoded from it again at restore
    /// (`PartOrigin`) — in a panel over a tab, or torn off into a tab of its
    /// own.
    case part(PartOrigin)
}

/// Where a part came from: the pane it was taken out of, the stretch of it,
/// and how it was read — enough to take it out again.
public struct PartOrigin: Codable, Equatable, Sendable {
    /// The parent pane's `PaneState.id`, wherever in the workspace it is: in
    /// the same tab, in another, in another window.
    public var parent: String
    public var sourceStart: UInt64
    public var sourceEnd: UInt64
    /// What the part is called in its parent.
    public var name: String
    /// How the part is read, and how it goes back into its parent — the app's
    /// own encoding of its layout and codec, as JSON text. The package does
    /// not read it.
    public var layout: String?
    public var codec: String?
    /// What it decoded to, so a part that decodes to another length is known
    /// to be other bytes.
    public var size: UInt64
    /// The part's own bytes, when it holds changes its parent has not got:
    /// kept beside the workspace like an untitled document's, and laid over
    /// what the parent gives at restore. Nil for a part that is what its
    /// parent holds.
    public var edits: UntitledStamp?

    public init(parent: String, sourceStart: UInt64, sourceEnd: UInt64, name: String,
                layout: String?, codec: String?, size: UInt64, edits: UntitledStamp? = nil) {
        self.parent = parent
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.name = name
        self.layout = layout
        self.codec = codec
        self.size = size
        self.edits = edits
    }
}

/// A panel over a tab: a part of a document (`DocumentSource.part`), or bytes
/// with no parent at all (`DocumentSource.untitled`).
public struct FragmentState: Codable, Equatable, Sendable {
    public var pane: PaneState
    public var surface: SurfaceState

    public init(pane: PaneState, surface: SurfaceState) {
        self.pane = pane
        self.surface = surface
    }
}

/// An untitled document: its content as the workspace keeps it, the name it
/// showed, and whether it held work nobody had saved.
public struct UntitledStamp: Codable, Equatable, Sendable {
    public var content: KeptContent
    /// The name the header showed; nil for a plain "Untitled".
    public var name: String?
    public var size: UInt64
    /// Whether closing it would have asked to save. A restored document asks
    /// the same.
    public var dirty: Bool

    public init(content: KeptContent, name: String?, size: UInt64, dirty: Bool) {
        self.content = content
        self.name = name
        self.size = size
        self.dirty = dirty
    }
}

/// A document's content as a workspace keeps it: a base, and the log of the
/// transactions made over it (`Design/PERSISTENT_UNDO_PLAN.md`).
///
/// Every state a document passes through has a serial of its own. The base
/// holds one state; the log holds transactions, each naming the state it was
/// applied to; the content is the state `head` names, found from the base by
/// the transactions between them. An edit appends to the log and an undo only
/// moves `head`, so a snapshot writes what changed since the last one.
public struct KeptContent: Codable, Equatable, Sendable {
    /// The document's name in `Kept/`, for as long as it is kept.
    public var id: String
    public var base: KeptBase
    /// The state the document was in.
    public var head: UInt64
    /// Where its serials go on counting from.
    public var nextSerial: UInt64
    /// For a file: the state the file on disk holds. Nil for a document with
    /// no file.
    public var saved: UInt64?
    /// The transactions over the base; nil while there are none.
    public var log: KeptLog?
    /// The history over the content: what undo and redo find after a
    /// relaunch. Nil for content kept without one.
    public var history: KeptHistory?

    public init(id: String, base: KeptBase, head: UInt64, nextSerial: UInt64,
                saved: UInt64? = nil, log: KeptLog? = nil, history: KeptHistory? = nil) {
        self.id = id
        self.base = base
        self.head = head
        self.nextSerial = nextSerial
        self.saved = saved
        self.log = log
        self.history = history
    }

    /// The files in `Kept/` this content is read from.
    public var files: [String] {
        var files: [String] = []
        switch base {
        case .file: break
        case .bytes(let file, _, _), .edits(let file, _, _): files.append(file)
        }
        if let log { files.append(log.file) }
        return files
    }
}

/// A document's undo history as a workspace keeps it, beside its content: the
/// transactions are in the log, this says how they stand
/// (`Design/PERSISTENT_UNDO_PLAN.md`, "Position lives in the manifest").
public struct KeptHistory: Codable, Equatable, Sendable {
    /// The state an empty undo side stands for: the undo side is the way from
    /// it to `KeptContent.head`.
    public var undoBase: UInt64
    /// The newest state the redo side leads to; nil with nothing to redo.
    public var redoTip: UInt64?
    /// How many transactions each redo step holds, the next to redo first.
    public var redoSteps: [Int]
    /// The state last saved, and whether the document is dirty in any state —
    /// content nobody saved, with nothing earlier to undo to.
    public var savedState: UInt64
    public var dirtyRegardless: Bool
    /// The joins that can be undone and those that can be redone, each with
    /// the file it detached the document from.
    public var joins: [KeptJoin]
    public var undoneJoins: [KeptJoin]

    public init(undoBase: UInt64, redoTip: UInt64?, redoSteps: [Int], savedState: UInt64,
                dirtyRegardless: Bool, joins: [KeptJoin] = [], undoneJoins: [KeptJoin] = []) {
        self.undoBase = undoBase
        self.redoTip = redoTip
        self.redoSteps = redoSteps
        self.savedState = savedState
        self.dirtyRegardless = dirtyRegardless
        self.joins = joins
        self.undoneJoins = undoneJoins
    }
}

/// A join on a kept history: its transaction, and the file it detached the
/// document from — which undoing it attaches the document to again.
public struct KeptJoin: Codable, Equatable, Sendable {
    public var serial: UInt64
    public var path: String
    public var readOnly: Bool

    public init(serial: UInt64, path: String, readOnly: Bool) {
        self.serial = serial
        self.path = path
        self.readOnly = readOnly
    }
}

/// The state a kept content starts from.
public enum KeptBase: Codable, Equatable, Sendable {
    /// The file on disk, which holds the state `serial` names.
    case file(serial: UInt64)
    /// The whole content, in `Kept/<file>`: an untitled document or a part.
    /// `hash` is the file's SHA-256, hex: it is read only when it matches.
    case bytes(file: String, serial: UInt64, hash: String)
    /// Runs over the file on disk (`OverlayEdits`), in `Kept/<file>`: a file
    /// whose saved state no transaction kept leads to.
    case edits(file: String, serial: UInt64, hash: String)

    public var serial: UInt64 {
        switch self {
        case .file(let serial), .bytes(_, let serial, _), .edits(_, let serial, _): return serial
        }
    }
}

/// A log in `Kept/`, pinned: the length it is read to and the chained hash
/// at that length, hex.
public struct KeptLog: Codable, Equatable, Sendable {
    public var file: String
    public var length: UInt64
    public var hash: String

    public init(file: String, length: UInt64, hash: String) {
        self.file = file
        self.length = length
        self.hash = hash
    }
}

/// A file on disk and what it was like: enough to open it again and to tell
/// whether it is still the file the rest of the pane's state was measured on.
public struct FileStamp: Codable, Equatable, Sendable {
    public var path: String
    /// The same file's path relative to the folder a project sits in — so a
    /// job folder of a project and its dumps can be moved or copied whole.
    /// Nil outside a project.
    public var relativePath: String?
    public var size: UInt64
    /// The modification date, to the whole second.
    public var modified: Date?
    /// The file's SHA-256, hex — written down only when something is laid over
    /// the file at restore (`PaneState.kept`), and then what decides whether it
    /// is still the file: a copy or a `touch` moves the date, not the bytes.
    public var sha256: String?

    public init(path: String, size: UInt64, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    /// Reads `url`'s stamp from disk. Nil when the file is not there.
    public init?(url: URL, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        self.init(path: url.standardizedFileURL.path,
                  size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                  // Whole seconds: the file keeps dates as ISO 8601, which
                  // has none finer, and a stamp must read back equal.
                  modified: (attributes[.modificationDate] as? Date).map {
                      Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down))
                  })
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Where the file is now: at its path, or — moved together with the
    /// project — at its relative path from `folder`. Nil when it is at
    /// neither.
    public func locate(relativeTo folder: URL?, fileManager: FileManager = .default) -> URL? {
        if fileManager.fileExists(atPath: path) { return url }
        guard let relativePath, let folder else { return nil }
        let moved = folder.appendingPathComponent(relativePath).standardizedFileURL
        return fileManager.fileExists(atPath: moved.path) ? moved : nil
    }

    /// `path` relative to `folder`, climbing out of it with `..` where it has
    /// to. Nil for a file on another volume's root, where a relative path
    /// would say nothing a move keeps.
    public static func relativePath(of path: String, to folder: URL) -> String? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let base = folder.standardizedFileURL.pathComponents
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        // Sharing only "/" is no relation worth keeping.
        guard common > 1 else { return nil }
        let up = Array(repeating: "..", count: base.count - common)
        return (up + target[common...]).joined(separator: "/")
    }

    /// Whether `current` is the same file content as far as size and
    /// modification date tell. A file rewritten with the same bytes reads as
    /// changed; a restore that drops a little state for it errs the safe way.
    public func isUnchanged(comparedWith current: FileStamp) -> Bool {
        guard size == current.size else { return false }
        switch (modified, current.modified) {
        case let (was?, now?): return abs(was.timeIntervalSince(now)) < 1
        case (nil, nil): return true
        default: return false
        }
    }
}

/// A bookmark: the row it marks and its name (§20).
public struct BookmarkState: Codable, Equatable, Sendable {
    /// The row's first offset.
    public var row: UInt64
    public var name: String

    public init(row: UInt64, name: String) {
        self.row = row
        self.name = name
    }
}

/// A file cut into pieces (§21): its size when it was cut, and every piece in
/// file order.
public struct SegmentationState: Codable, Equatable, Sendable {
    public var contentSize: UInt64
    public var pieces: [PieceState]

    public init(contentSize: UInt64, pieces: [PieceState]) {
        self.contentSize = contentSize
        self.pieces = pieces
    }
}

/// One piece: where it opens, its name, and the file its bytes came from.
public struct PieceState: Codable, Equatable, Sendable {
    public var start: UInt64
    public var name: String
    public var link: PieceLinkState?

    public init(start: UInt64, name: String, link: PieceLinkState? = nil) {
        self.start = start
        self.name = name
        self.link = link
    }
}

/// A piece's link to its source file (§21.7): the file by path, and the
/// stretch of it the piece stands for.
public struct PieceLinkState: Codable, Equatable, Sendable {
    public var path: String
    public var sourceStart: UInt64
    public var sourceEnd: UInt64

    public init(path: String, sourceStart: UInt64, sourceEnd: UInt64) {
        self.path = path
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

/// What sits around a tab's panes: the minimap and the Find bar.
public struct SurfaceState: Codable, Equatable, Sendable {
    public var minimapVisible: Bool
    /// "detail" or "overview" (§19.4); nil leaves the mode the file picks.
    public var minimapMode: String?
    /// The Find bar's pattern while the bar is open; nil while it is closed.
    public var findPattern: FindPatternState?
    /// The tool panel, while one is open.
    public var tool: ToolState?

    public init(minimapVisible: Bool = false, minimapMode: String? = nil,
                findPattern: FindPatternState? = nil, tool: ToolState? = nil) {
        self.minimapVisible = minimapVisible
        self.minimapMode = minimapMode
        self.findPattern = findPattern
        self.tool = tool
    }
}

/// The tool panel: which tool-module, what it had chosen, and — on a tab's
/// own panes — which of them it read.
public struct ToolState: Codable, Equatable, Sendable {
    public var identifier: String
    /// What the session parked, as the tool-module encoded it; nil for one
    /// that keeps nothing.
    public var state: Data?
    /// File A (0) or File B (1); nil on a panel, which has one pane.
    public var pane: Int?

    public init(identifier: String, state: Data?, pane: Int?) {
        self.identifier = identifier
        self.state = state
        self.pane = pane
    }
}

/// The text in the Find bar and the encoding it is read in.
public struct FindPatternState: Codable, Equatable, Sendable {
    public var text: String
    /// A `SearchEncoding` raw value.
    public var encoding: String

    public init(text: String, encoding: String) {
        self.text = text
        self.encoding = encoding
    }
}
