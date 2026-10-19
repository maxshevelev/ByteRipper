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

    public init(panes: [PaneState?], activePane: Int, dividerFraction: Double? = nil) {
        self.panes = panes
        self.activePane = activePane
        self.dividerFraction = dividerFraction
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

    public init(document: DocumentSource,
                selectionStart: UInt64, selectionEnd: UInt64,
                inputRegion: InputRegion = .hex, insertMode: Bool = false,
                topOffset: UInt64) {
        self.document = document
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.inputRegion = inputRegion
        self.insertMode = insertMode
        self.topOffset = topOffset
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
