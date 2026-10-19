# Workspace — the session the app brings back at launch

> Issue #19 asked whether a project is "a file the user saves deliberately or a
> window state the app restores by itself". This document answers: **the app
> restores it by itself**, when **Settings ▸ General ▸ Reopen the workspace at
> launch** is on. It is off by default.

**Words.** The Russian interface calls it «рабочая сессия», the German one
«Arbeitsbereich». "Workspace" stays the code's word.

## What a workspace is

Everything the person built up in a session that is not the bytes of a file
and not an app-wide preference:

| | kept | how it comes back |
|---|---|---|
| windows and tabs | frame of each window, tab order, the selected tab, the key window | rebuilt with `makeWindow(tabbedWith:)` in order |
| File A / File B | path, size and modification date of each slot (`FileStamp`) | `PaneViewModel.open`, silently |
| active pane, divider fraction | per tab | `activatePane(at:)`, `ComparisonView.setFraction` |
| caret, selection, input region (hex/ASCII), insert mode | per pane | `setSelection`, `setInputRegion`, `isInsertMode` |
| scroll | the first visible row, per pane | `FilePaneView.scrollRowToTop(containing:)`, after layout |
| bookmarks | per tab (they are tab-wide, §20.1) | `BookmarkStore.seed` |
| segments and their links | per pane | `SegmentStore.restore`, links re-minted from paths |
| fragment panels and parts | per tab, parent first | `openPart` / `openFragment`, then `fragments.expand` |
| minimap | visible, render mode, per surface | `setPanelVisible`, `setRenderMode` |
| tool panel | which tool, its parked state, open UEFI rows | `tools.activate` after `restore(state)` |
| find bar | visible, pattern text | a new setter on the find bar |
| untitled documents | their bytes and name | `openBytes(_:named:origin:)` |

**Not kept**, deliberately:

- **Undo history.** It belongs to the session that made it.
- **Unsaved changes to a file on disk.** Quitting asks Save / Discard first, as
  it does today, so at a normal quit there are none. After a crash they are
  lost. The tab, the file and its position still come back.
- **Search All results.** They are recomputed from the pattern on demand.
- **Navigation history (Back / Forward).** Its places hold live pane
  references. It starts empty.
- **App-wide settings** (font, word size, theme, panel widths, side-by-side
  or stacked panes — that last one is `LayoutSettings`, one for the app). They are
  already persisted, and a workspace that restored them would fight the
  Settings window.

## When it is written

**Continuously.** A crash must not cost the workspace, so the file is kept up
to date as the session changes, not only at quit.

- A `WorkspaceRecorder` (one, owned by `AppDelegate`) takes a snapshot of every
  window, encodes it, and writes the file **only if the encoded bytes differ**
  from what it last wrote.
- It snapshots on a coarse timer (2 s) while the app is active, on
  `applicationDidResignActive`, when a window closes, and one last time at
  quit, after every Save / Discard has been answered.
  - A timer rather than observers: scroll, caret, segments, fragments and
    tools change in a hundred places. A snapshot is a walk over a handful of
    tabs, it costs microseconds, and the compare keeps the disk quiet. An
    observer per mutation would be a hundred hooks that each can be forgotten.
- **Closing the last window by hand empties the workspace**, as in Safari and
  Xcode: the person closed it deliberately. ⌘Q with tabs open keeps them.
- With the setting off nothing is recorded, and switching it off deletes the
  file, so a workspace from months ago never comes back when it is switched on
  again.

### Untitled documents

An untitled document (New, Join, Duplicate, a torn-off fragment) has no file
to come back from, so its bytes are written beside the workspace:
`Untitled/<uuid>.bin`, one per document, rewritten only when the document's
content changed since the last write. At a normal quit Save / Discard still
runs first: a saved document comes back as its file, a discarded one is gone
(its `.bin` is deleted). After a crash it comes back as it was at the last
snapshot.

The join case — the reason issue #19 exists — comes back whole: the image's
bytes, its segments, and their links to `chip1.bin` and `chip2.bin`.

## Where it is written

`~/Library/Application Support/ByteRipper/Workspace/` — beside
`Annotations.json` and the favourites:

```
Workspace/
  Workspace.json
  Untitled/
    3F2A…E1.bin
```

`Workspace.json` carries a `version`. A file of an unknown version is ignored,
not migrated: losing a workspace is an inconvenience, misreading one is not
acceptable.

## The model

Pure, `Codable`, in a package of its own (`Packages/Workspace`), with the
reconciliation logic beside it — what to do with a snapshot when the file on
disk is no longer the file it was taken of. The app target only gathers
snapshots from live objects and applies them.

```swift
struct Workspace: Codable { var version: Int; var windows: [WindowState]; var keyWindow: Int? }
struct WindowState: Codable { var frame: CGRect; var tabs: [TabState]; var selectedTab: Int }
struct TabState: Codable {
    var panes: [PaneState?]          // [File A, File B]
    var activePane: Int
    var layout: ComparisonLayout?    // vertical + divider fraction
    var bookmarks: [BookmarkState]
    var fragments: [FragmentState]   // parent first
    var expandedFragment: Int?
    var surface: SurfaceState        // minimap, tool panel, find bar
}
struct PaneState: Codable {
    var source: DocumentSource       // .file(path, FileIdentity, size) | .untitled(id, name)
    var selection: Range<UInt64>; var caretRegion: InputRegion; var insertMode: Bool
    var topRow: UInt64
    var segments: SegmentationState? // pieces + links by source path
    var uefiOpenRows: [[Int]]
}
struct FragmentState: Codable {
    var parent: FragmentParent       // .pane(0|1) | .fragment(index)
    var source: Range<UInt64>; var name: String
    var codec: String                // codec identifier, see "Parts"
    var pane: PaneState; var surface: SurfaceState
}
struct ToolState: Codable { var identifier: String; var state: Data? }
```

## Restoring

At launch, before the first empty window would be made:

1. If the setting is on and `Workspace.json` reads, build each window's tabs in
   order, then select each window's tab and order the key window front.
   Otherwise launch as today.
2. Per tab, open File A and File B **silently**: `openIntoPane` grows a mode in
   which it raises no alerts and does not touch Recent Files. A file that is
   missing is skipped and reported.
3. **A file that changed on disk** — its size or modification date differs
   from the snapshot (`FileStamp.isUnchanged`) — still opens, but only the position comes back:
   - caret, selection and scroll that fall past the end move to the last
     address;
   - bookmarks past the end are dropped;
   - segments and tool state for that file are not restored — cuts and tree
     nodes measured on other bytes would point at the wrong places.
4. Fragments are replayed parent first; a fragment whose parent did not come
   back, or whose source range no longer fits, is skipped and reported.
5. Positions are applied after the tab has laid out, as `go(to:)` already does.
6. **One warning after everything is open**, if anything was skipped or reset:
   a sheet on the key window listing the missing files and the files that
   changed on disk, saying what was not restored for each. Nothing to report,
   no sheet.

### Launched with a file

Double-clicking a dump in Finder with the setting on restores the workspace
first, then opens the file as it is opened today. A file already open in the
workspace has its tab brought forward instead of the "open in one place" alert.

## Tools

The tool sessions already park their state between activations
(`ToolSession.parkedState` / `restore(_:)`). A workspace makes that state
outlive the process, so the only addition is a way to encode it:

```swift
public protocol PersistableToolSessionState: ToolSessionState, Codable {}

protocol ToolModule {
    /// Nil by default: a tool that does not opt in comes back open, with
    /// nothing chosen.
    static func restoredState(from data: Data) -> (any ToolSessionState)?
}
```

`UEFIParkedState`, `MEAParkedState` and `FITParkedState` conform (`NodeID`
is `Codable`). The open UEFI rows live on the pane and are saved with it.

- The restored state goes into the same box a session parks into
  (`ToolController.park`), so the session that starts finds it exactly as it
  would after a switch between tools.
- On a tab's own panes the tool goes back to the pane it read, which need
  not be the active one.
- The panel opens **without moving the window** (`activate(movesWindow:)`):
  the window's frame was written with the panel open.
- What a tool had chosen, and the open rows, come back only for a document
  that has not changed since.

## Parts

A fragment panel's identity is its origin: the parent, the source range, the
part name, the root layout and the codec. A part is written down as that, not
as its bytes, and **decoded again from its parent at restore** — parents
first, off the main actor when the codec says decoding is slow, as `openPart`
does. The recorder pauses until every panel is back, so a snapshot never
writes a tab with its panels half restored.

- The codec is written by the app (`PartCodecState`: copy, read-only, UEFI
  structure, Lenovo `LENV` block), as JSON text the package does not read; the
  root layout and the UEFI rebuild target are `Codable` in `UEFIImage`.
- A part whose parent did not come back, or changed on disk, is not opened:
  its stretch of the parent may hold something else.
- A part's unsaved edits are not kept: quitting asks to put them back or
  discard them; after a crash the part comes back as its parent holds it.
- A panel with no parent — bytes handed over by a tool, or a part whose
  parent was closed — is kept as untitled bytes, like an untitled document,
  and comes back without a way home.
- A part torn off into a tab of its own is an untitled document there, and
  comes back as one: its link to the parent does not survive a restart.

## Phases

Each phase is a commit, and each leaves the app working with the setting on.

1. **Settings ▸ General** — the tab and the switch. *(done)*
2. **Tabs and files** — the package and the model, the recorder and the file,
   windows, tabs, File A / File B, active pane, divider, caret, selection,
   scroll, insert mode. *(done)*
3. **The rest of a pane** — bookmarks, segments and links, minimap, find bar. *(done)*
4. **Untitled documents** — their bytes. *(done)*
5. **Fragments and parts.** *(done)*
6. **Tools.** *(done)*
7. **Changes on disk, and launch with a file** — the warning sheet, Finder
   launch, and the help page `workspace.md` in three languages.
