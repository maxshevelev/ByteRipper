import Foundation

/// Pure placement decision for the File > Open panel (§4.1) — no AppKit, so it
/// is unit-testable. Drag-and-drop uses its own targeted rules (§4.3).
/// Where an open puts its first file.
enum OpenPanePlacement {
    /// §4.1: an empty pane first, otherwise the active one (Finder, Dock).
    case fillFree
    /// ⌘O, Open Recent: the active pane.
    case activePane
    /// Compare with…, ⌥ on an Open Recent row: the pane the active one is
    /// compared with.
    case otherPane
}

enum OpenPlacement {
    struct Result: Equatable {
        /// Pane the first selected file opens into (0 or 1), if any.
        var firstFilePane: Int?
        /// Whether the second selected file also opens (only when both panes
        /// were empty; otherwise it would clobber an occupied pane).
        var openSecond = false
        /// Number of additional selected files that are ignored (need a
        /// notification), given `fileCount`.
        var ignoredCount = 0
    }

    /// Rules §4.1.1–§4.1.3:
    /// - no panes occupied → first two files to panes 1/2, extras ignored;
    /// - only pane 1 occupied → first file to pane 2, all others ignored;
    /// - both occupied → first file replaces the active pane, all others ignored.
    static func plan(
        activePaneIndex: Int,
        pane1Open: Bool,
        pane2Open: Bool,
        fileCount: Int
    ) -> Result {
        switch (pane1Open, pane2Open) {
        case (false, _):
            return Result(firstFilePane: fileCount >= 1 ? 0 : nil,
                          openSecond: fileCount >= 2,
                          ignoredCount: max(0, fileCount - 2))
        case (true, false):
            return Result(firstFilePane: fileCount >= 1 ? 1 : nil,
                          openSecond: false,
                          ignoredCount: max(0, fileCount - 1))
        case (true, true):
            return Result(firstFilePane: fileCount >= 1 ? activePaneIndex : nil,
                          openSecond: false,
                          ignoredCount: max(0, fileCount - 1))
        }
    }

    /// ⌘O and Open Recent: the file goes into the **active** pane, replacing
    /// what it holds, and never starts a second pane by itself. Only with both
    /// panes empty do the first two files still fill them (picking two files
    /// is how a comparison is started from nothing); anything beyond is ignored.
    static func planOpen(
        activePaneIndex: Int,
        pane1Open: Bool,
        pane2Open: Bool,
        fileCount: Int
    ) -> Result {
        guard pane1Open || pane2Open else {
            return plan(activePaneIndex: activePaneIndex, pane1Open: false, pane2Open: false,
                        fileCount: fileCount)
        }
        return Result(firstFilePane: fileCount >= 1 ? activePaneIndex : nil,
                      openSecond: false,
                      ignoredCount: max(0, fileCount - 1))
    }

    /// Compare with…: the file goes into the pane the active one is compared
    /// with — the free pane if there is one, otherwise the one that is not
    /// active. With nothing open there is nothing to compare with, so it is a
    /// plain open.
    static func planCompare(
        activePaneIndex: Int,
        pane1Open: Bool,
        pane2Open: Bool,
        fileCount: Int
    ) -> Result {
        let target: Int
        switch (pane1Open, pane2Open) {
        case (false, false):
            return plan(activePaneIndex: activePaneIndex, pane1Open: false, pane2Open: false,
                        fileCount: fileCount)
        case (true, false): target = 1
        case (false, true): target = 0
        case (true, true): target = 1 - activePaneIndex
        }
        return Result(firstFilePane: fileCount >= 1 ? target : nil,
                      openSecond: false,
                      ignoredCount: max(0, fileCount - 1))
    }
}
