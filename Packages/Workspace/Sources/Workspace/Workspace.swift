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
    public static let currentVersion = 1

    public var version: Int
    /// Front to back, as `NSApp.orderedWindows` lists them.
    public var windows: [WindowState]

    public init(windows: [WindowState]) {
        self.version = Self.currentVersion
        self.windows = windows
    }

    /// Nothing to bring back: no window has a tab with anything open in it.
    public var isEmpty: Bool {
        windows.allSatisfy { $0.tabs.allSatisfy(\.isEmpty) }
    }
}

/// One window: where it stood, and its tabs left to right.
public struct WindowState: Codable, Equatable, Sendable {
    public var frame: Rect
    public var tabs: [TabState]
    /// The tab on screen, as an index into `tabs`.
    public var selectedTab: Int

    public init(frame: Rect, tabs: [TabState], selectedTab: Int) {
        self.frame = frame
        self.tabs = tabs
        self.selectedTab = selectedTab
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

    public init(panes: [PaneState?], activePane: Int, dividerFraction: Double? = nil,
                bookmarks: [BookmarkState] = [], surface: SurfaceState = SurfaceState()) {
        self.panes = panes
        self.activePane = activePane
        self.dividerFraction = dividerFraction
        self.bookmarks = bookmarks
        self.surface = surface
    }

    /// A tab with no file in it: an empty window, worth a tab only if it was
    /// the last thing open.
    public var isEmpty: Bool { panes.allSatisfy { $0 == nil } }
}

/// One pane: the document in it, and where the reader was in it.
public struct PaneState: Codable, Equatable, Sendable {
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

    public init(document: DocumentSource,
                selectionStart: UInt64, selectionEnd: UInt64,
                inputRegion: InputRegion = .hex, insertMode: Bool = false,
                topOffset: UInt64, segments: SegmentationState? = nil) {
        self.document = document
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.inputRegion = inputRegion
        self.insertMode = insertMode
        self.topOffset = topOffset
        self.segments = segments
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
    /// A document with no file — New, a join, a duplicate — whose bytes the
    /// workspace keeps beside itself (`WorkspaceFolder.untitledURL`).
    case untitled(UntitledStamp)
}

/// An untitled document: the name of its bytes in the workspace folder, the
/// name it showed, and whether it held work nobody had saved.
public struct UntitledStamp: Codable, Equatable, Sendable {
    /// The file under `Untitled/` its bytes are in.
    public var id: String
    /// The name the header showed; nil for a plain "Untitled".
    public var name: String?
    public var size: UInt64
    /// Whether closing it would have asked to save. A restored document asks
    /// the same.
    public var dirty: Bool

    public init(id: String, name: String?, size: UInt64, dirty: Bool) {
        self.id = id
        self.name = name
        self.size = size
        self.dirty = dirty
    }
}

/// A file on disk and what it was like: enough to open it again and to tell
/// whether it is still the file the rest of the pane's state was measured on.
public struct FileStamp: Codable, Equatable, Sendable {
    public var path: String
    public var size: UInt64
    /// The modification date, to the whole second.
    public var modified: Date?

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

    public init(minimapVisible: Bool = false, minimapMode: String? = nil,
                findPattern: FindPatternState? = nil) {
        self.minimapVisible = minimapVisible
        self.minimapMode = minimapMode
        self.findPattern = findPattern
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
