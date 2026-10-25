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
| the Annotations window | its place among a window's tabs, or a window of its own; the selected cards by annotation id | `NotesWindowController.restore(_:among:)` |
| undo history | per document — files, untitled documents, parts — both sides, the saved state, the joins, the segments paired with each step | `ContentKeeper.adopt`, `UndoHistory.restore` (`PERSISTENT_UNDO_PLAN.md`) |

**Not kept**, deliberately:

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
- **Closing the last window is a quit**, answered exactly as ⌘Q is: the
  windows are kept for the next launch, and nothing is asked about what the
  workspace holds. (It used to empty the workspace, as Safari and Xcode
  do; a closed last window lost the session for good, which is not what a
  person closing the app means.)
- With the setting off nothing is recorded, and switching it off deletes the
  file, so a workspace from months ago never comes back when it is switched on
  again.

### Untitled documents

A document never saved (New, Join, Duplicate, a torn-off fragment — named
by Rename or not: what matters is that it has never been written) has no
file to come back from, so its content is kept beside the workspace, in
`Kept/`: its bytes written whole once, and a log its edits are appended to
(`ContentKeeper`, `PERSISTENT_UNDO_PLAN.md`, "Content = base + journal"). A
part with changes its parent has not got keeps its own content the same way
(`PartOrigin.edits`), and it is laid over what the parent gives at restore.

**Quitting does not ask about them** with the switch on: they come back at
the next launch, still unsaved. Before its questions, quitting takes a
snapshot, and asks only about what the workspace does not hold as it is now
— anything whose bytes could not be written. A document closed in the
session takes its copy with it.

### Unsaved changes to files on disk

Kept as a project keeps them (below, "Projects"): the file is the base, and
the edits made over it are a log in `Kept/`, appended to as they are made,
laid over the file at restore only when it is the file they were made on. A file changed outside the app opens without
them, and the warning says so. Quitting does not ask about them either; the
session differs from a project only in finding its files by path alone, with
no `relativePath`. (They used to be the one question quitting still asked,
and were lost in a crash.)

A part whose parent did not come back still brings its changes, as an
untitled document with no way home.

The join case — the reason issue #19 exists — comes back whole: the image's
bytes, its segments, and their links to `chip1.bin` and `chip2.bin`.

## Where it is written

`~/Library/Application Support/ByteRipper/Workspace/` — beside
`Annotations.json` and the favourites:

```
Workspace/
  Workspace.json
  Kept/
    3F2A…E1-9C04B2D1.bin     an untitled document's or a part's base
    3F2A…E1-9C04B2D1.log     the edits over it
    77D0…3A-15E2C0FF.log     the edits over a file on disk
```

`Workspace.json` carries a `version`. See "Versions" below for what a build
does with a file of another one.

## Versions

A project and the session are both the person's work — the session is work
not yet saved under a name — so a build opens what the builds before it wrote.
The promise starts at version 4 (`WorkspaceMigration.oldestReadable`); files
of versions 1–3 were written before it and are refused.

- **Earlier version** — read through `WorkspaceMigration`: the file's JSON is
  taken one version at a time (`steps[n]` makes n + 1 out of n) up to
  `Workspace.currentVersion`, then decoded. The steps work on the JSON, not on
  the types, which describe only the newest version. The next snapshot writes
  the file in the current version.
- **Newer version** — refused, with a message for a project that says so. A
  build cannot know what a newer one meant, and misreading is worse than not
  reading.
- **A newer session on an older build** — left untouched for the rest of the
  launch (`WorkspaceRecorder.isSessionNewer`): neither restored, nor written
  over, nor deleted, whatever the switch says. The launch says so once, and
  until quit the session is kept no more than with the switch off — quitting
  asks about unsaved work. The newer build finds its session as it left it.
  A project needs no such care: an older build refuses to open it, so never
  writes it.

What may change without raising the version: an added optional field (an
earlier file has not got it and reads as nil). What raises it, with a step: a
required field added, a field renamed, removed or given another meaning, a
case taken out of an enum or its payload changed.

`Kept/` follows the same promise without a version of its own. A log record's
kind carries its format in its tag (`BRT1`, `BRS1`, `BRP1`, `BRB1`): a record
whose body changes gets a new tag, and the reader goes on reading the old
one. A file's edits (`OverlayEdits`, a binary property list) and the segments
in a log follow the `Codable` rule above.

Each readable version is kept as a fixture that is never rewritten:
`Packages/Workspace/Tests/WorkspaceTests/Fixtures/v<N>` for the JSON,
`Packages/ByteRipperCore/Tests/ByteRipperCoreTests/Fixtures/v<N>` for `Kept/`.
Raising the version adds the new version's fixtures; the old ones' tests then
check that the migration arrives at what the new types describe.

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
    var code: CodeScreenState?       // a tab that is a code screen
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
    var code: CodeScreenState?       // the panel is a code screen, not a plain part
}
struct CodeScreenState: Codable {
    var manifest: String             // the analysis manifest, as JSON
    var selectedFunction: Int?; var selectedInstruction: Int?
    var showsC: Bool
}
struct ToolState: Codable { var identifier: String; var state: Data? }
```

`CodeScreenState` is an added optional field on both kinds of container: an
older workspace decodes with it absent, and a code panel that comes back looks
its analysis up in the store the manifest names. If the artifact is gone the
part opens as bytes rather than not at all.

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
   A window's frame is set once all its tabs are in: a tab joining it and a
   comparison opening in it both fit the window to their content. A tab in
   which nothing could be opened is closed rather than left empty; with
   nothing opened anywhere, the launch makes its one empty window. The
   recorder is paused for the whole restore.
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
- A part whose parent did not come back, or changed on disk, is not taken
  out of it: its stretch of the parent may hold something else. A part with
  changes comes back all the same, as untitled bytes with its changes.
- A part's unsaved changes are kept as an untitled document's are: its own
  content, in `Kept/` (`PartOrigin.edits`), laid over what the parent gives
  at restore. The parent's
  bytes stay its baseline, what **Update in Parent** compares with. Quitting
  does not ask about them, and a crash does not lose them.
- A panel with no parent — bytes handed over by a tool, or a part whose
  parent was closed — is kept as untitled bytes, like an untitled document,
  and comes back without a way home.
- A part torn off into a tab of its own is a part all the same, and comes
  back linked. Its parent may be in another tab or another window, so a part
  names its parent by the pane's id in the snapshot (`PaneState.id`,
  `PartOrigin.parent`), not by a place in its own tab.
- The restore is two passes over all tabs together (`WorkspaceRestorer`):
  first every tab opens its files and untitled documents, then the parts —
  panels and torn-off tabs alike — are taken out of their parents, each once
  its parent is open, until none is left that can be. A tab is laid out once
  its own panes are in; its panels open after that. What still waits at the
  end had no parent to come out of, and is reported.
- At quit a torn-off part is kept, like a panel, with its changes.

## Projects

A project is a named workspace the person switches between: everything open
for one job, kept in a file of its own, `.brp`, and opened again as one
thing.

- **A package.** `Job.brp/` holds `Project.json` (the `Workspace` value, a few
  kilobytes) and `Kept/` (the content of untitled documents and parts, and
  the unsaved changes of files on disk, as in the session). A project with
  no unsaved work is as small as its JSON. The bytes live with the project,
  not in Application Support: deleting a project deletes them, copying it
  copies them, and a job folder moved whole takes them along.
- **Files by two paths.** A file is written by its path and by its path
  relative to the folder the project is in (`FileStamp.relativePath`), and is
  looked for at the first, then the second (`FileStamp.locate`).
- **Code analyses travel with the project.** The analyses its Code screens show
  are written as `Analyses.bundle` beside `Project.json`, and a stable
  `project-…` reference in the local analysis store keeps their objects from
  being collected. Opening the project imports the bundle before its screens
  are restored, so a project moved to another Mac keeps its code. Opening a
  Code panel in the session without a project creates neither the bundle nor a
  reference.
- **Unsaved changes of files on disk** are kept as the log of the edits made
  over the file, about the size of the changes; only when the log no longer
  leads from what the file holds are they written as runs over the file
  (`OverlayEdits`). They are laid over the file again at open
  (`PaneViewModel.applyKeptContent`) only when the file is the one they were
  made on; a file changed outside the project opens without them, and the
  warning says so.
- **Live.** While a project is open the recorder writes into it rather than
  into Application Support (`WorkspaceRecorder.switchTo(project:)`), always,
  whatever the restore switch says. Leaving a project — another project,
  **Close Project**, quitting — asks nothing: everything it holds is written.
  Closing the project's last window (its close button, ⌘W, ⇧⌘W — the
  Annotations window too, when it is the last) is a quit, answered as ⌘Q is,
  so the project keeps its windows rather than recording none.
- **The session without a project** behaves as before. Opening a project
  from it, when it holds anything, asks whether to save it as a project
  (Save… / Don't Save / Cancel); Don't Save closes it the ordinary way.
- **At launch**, with the restore switch on, the project open at quit is
  opened again (`RecentProjectsStore.lastProject`); a `.brp` handed to the
  launch opens instead.
- **Opening.** **File ▸ Open…**, a drop and the Finder route a `.brp` to the
  project rather than into a pane (`MainViewController.openableFiles`,
  `AppDelegate.application(_:open:)`). The type is exported by the app
  (`dev.maxik.byteripper.project`, a package) and owned by it.
- **File menu:** **Open Recent Project ▸**, **Save as Project…**, **Close
  Project**. Every window's title carries the project's name.

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
   launch, and the help page `workspace.md` in three languages. *(done)*
