# UEFI Structure — tool-module plan

A **structure browser** for a UEFI firmware image: it reads the open file
through the pane's shared `LazyUEFITree`, shows that tree in an expandable
outline, and — for the one node the user has selected — draws its bytes in the
dump and explains what they are.

This is the "structure browser" `Design/TOOL_MODULES_PLAN.md` named but did not
build. It stands on the same seam as the FIT tool-module and reads the same
shared parser; what it adds is a tree, a per-node zone, and a per-node detail.

**In scope.** The `Modules/UEFITool` package (a pure target and a UI target, as
every tool-module has), the outline, the splitter, the detail, the one zone per
selected node, and the app wiring (registry + `project.yml`).

**Not in scope.** Editing the image (this tool reads; the FIT tool writes),
editing inside a compressed section (the parser opens them read-only —
`UEFI/COMPRESSED_SECTIONS.md` §7), and persistence beyond the session's parked
selection.

## What it shows

The panel is two halves, split by a vertical splitter:

- **Top — the tree.** An `NSOutlineView` over the pane's shared `LazyUEFITree`.
  Every node is a row; a container expands. The row is the node's name, with its
  kind and size in a secondary column. Nothing here is built up ahead of time,
  and nothing below the top level is even read: opening the panel yields the
  top level, and a row the reader opens materializes that one branch off the
  main actor, with a "Loading…" row in its place while it does.
- **Bottom — the detail.** A label/value list describing the *selected* node,
  by its type. A volume shows its file system, length and attributes; a file its
  name GUID, type and state; a microcode its signature and revision; and so on.
  The fields come from the node's header, read through the same `ImageReader`
  the parser used, so what the detail says is what the bytes say.

A line under the tree says when something is being read, the way the FIT panel
does. The bar beside it is indeterminate: what the panel waits for is a branch
of the tree or a node's checksums, and neither is a fraction of the image the
reader would recognise.

**The title.** The summary line names what the image *is* and counts nothing —
the tree behind it is materialized branch by branch, so a node count would be a
count of clicks. A wrapper root (an Intel image, the "UEFI image" the parser
groups several tops under, a capsule) folds into that title and its children
open the outline; a real root the file already had — a lone volume off a chip —
keeps its row, because folding it would mean deciding again the moment somebody
opened it.

## The one zone

Selecting a node publishes **one** zone: that node's range, focused. Nothing
else. A UEFI parse is a tree of thousands of nodes and drawing all of them in
the dump is how the hex view stops being readable — what is worth drawing is
the node the user is looking at, and that changes with the selection.

The zone's id is the node's path (`1.2.0`), which is stable across a re-parse of
the same image and is also the route a diagnostic about a node three levels down
needs. When the user picks that zone back in the dump — the host has already
selected the bytes — the panel expands the tree to that node and selects it.

Before anything is selected the map is empty: a parse that has landed but a
node nobody has chosen yet draws nothing, and that is the honest state.

## The detail, by type

The common fields every node has — kind, name, subtype, GUID, the header/body/
tail ranges, the whole range, the flags, and the physical address when the image
told us one — are shown for every kind. On top of that, each kind reads its own
header:

| Kind | What the header adds |
| --- | --- |
| volume | file system (GUID + name), `FvLength`, signature, attributes, header length, checksum, revision, extended-header offset |
| file | name GUID, type (code + name), attributes, size, state, header and body checksums |
| section | type (code + name), size |
| microcode | header type, update revision, date (BCD), processor signature, checksum, loader revision, platform ids, data and total size |
| capsule | capsule GUID (+ name), header size, flags, image size |
| flash descriptor | signature, FLMAP, version; then the reserved vector, the chipset generation, the chips' sizes, the SPI clocks and the forbidden opcodes, and grids of the regions (base and limit), the masters' masks, the BIOS master's access, the VSCC chips and the PCH strap words; the bit that soft-disables the ME, and on Tiger and Alder Point mobile the GPR0 range and the eSPI clock, as rows of their own (`UEFI_IMAGE_FORMAT.md` §2.6) |
| region | the region's base and limit, from the descriptor's table |
| padding / free space / non-UEFI data | nothing but the size the common fields already carry |

The offsets and the name tables (`FFS.typeName`, `Section.typeName`,
`KnownGUIDs`, `FlashRegionType.label`, `MicrocodeHeader.date`) all live in
`UEFIImage`; the detail builder reads them through the reader and does not
re-derive a single one.

## Marking the tree

The tree marks its rows the way every firmware panel does — a background for
Boot Guard protection, a rail for decompressed bytes, a problem icon, role
badges — as `Design/ROW_MARKS.md` sets out. What each channel means in this
tree is §5.1 there.

## Searching the tree

A magnifier left of the filter in the title row opens a bar above the tree;
so does Edit ▸ Find (⌘F) while the tree or its details have the keyboard —
the panel answers the menu's `findPattern` ahead of the window — and the
cursor goes to the field. With the keyboard elsewhere ⌘F is the dump's Find. Its first line is the text and two arrows, its second a
type and — for a file or a section — a subtype. What it shows is one query
for the app (`UEFISearchSettings`, in the panel defaults), the same in both
panes, kept through a reparse, a change of file and a restart, and stored as
text and codes so a change of language leaves it alone.

**What matches.** The text is a case-insensitive substring of the name the row
shows, of the node's own name (a file's is its name section's) or of its GUID,
with the dashes or without when the text is hex. The type is the Type column's
code (`UEFITypes.Item`) and the subtype a file's or a section's type byte; all
three must hold. The menus are fixed lists (`UEFITreeSearchChoices`) rather
than what the image holds, so a choice survives the next file. The match is
`UEFITreeQuery.matches` in the pure target.

**The walk.** Not a filter: the next match, or the previous, in the order the
outline lists its rows with everything open — down before across — from the
last match (`searchCursor`), or from the selected row once the reader has
chosen one since; that row is not offered until the walk has come round to
it. Shutting the branch a match is in takes the selection away but not the
place: only a row chosen moves it. At
the end it goes on from the other end and shows the wrap sign the hex view's
find shows (`SearchWrapSigns` in `ToolModuleKit`, shared). Rows the filter
menu hides are not matches, and the ME region's sub-tree is not searched:
its structure is another one, which a name, a GUID and a type do not describe
(the bar says so on an image that has an ME region; the region's own row is
found).

`UEFITreeSearch` is the walk, a value over a `UEFITreeSearchSource` — the listed
rows, and `nil` for a branch not read yet. It hands back a row to test, or
the branch to read first and waits; the panel reads it with `LazyUEFITree.expand`
off the main actor, and asks again. A search that has run over 0.2 s says so: a progress bar and a stop button in the bar's second line, where **Not found** is said. What is read stays in the tree, so the second search
over it is instant. A long stretch of rows already read lets go of the main
thread every 8 ms.

**What it opens and shuts.** A match is selected as a click would select it,
without taking the keyboard from the field. The rows above it are opened and
the match itself one level down; the search notes each row it opened
(`UEFISearchOpenings`) and not a row the reader had open. On the next match
it opens the way to that one, selects it, and only then shuts what it opened
and the new match does not need, deepest first, so the tree comes back to what it
was before the search. The order matters: a branch read on the way makes the
session show the node it still has in focus again, and showing it opens the
rows above it — shut first, the old match's volume would be opened again
behind the search. A row the reader opens or shuts, a click on another row, a
changed query or a closed bar ends the search's claim on what it opened.

## Where the decisions live

As with the FIT tool-module, the panel is thin and the pure target is where the
decisions are made and tested by `swift test` over hand-built images:

- **`UEFITool`** (pure): the zone for a node, the trip back from a zone id to a
  node id, and the detail for a node. No AppKit.
- **`UEFIToolUI`**: the module, the session (read the pane's tree, show,
  publish, park the selection), and the view controller (the outline, the
  splitter, the detail).

The session holds no tree of its own. It reads the pane's `LazyUEFITree` — one
per open file, shared with the FIT and ME Analyzer tool-modules, and kept for as
long as the file is — and subscribes to it, so a branch any of them opens
reaches this panel's rows. Only the selected `NodeID` is the session's, kept by
path so it survives an edit that left its node where it was.

Three things the panel needs are asked for rather than computed up front:

- **A branch**, when a row is opened. `LazyUEFITree.expand` runs the volume's
  file walk or the region's signature scan off the main actor and coalesces a
  second request onto one already in flight.
- **The mapping**, the first time a node is in focus. It is what the detail's
  Address row reads, and it comes from the Volume Top File — whose last byte is
  at the top of the address space, so it is at the end of the last container of
  the image. One descent down the chain that reaches the last byte finds it; a
  panel nobody has clicked in pays for none of it.
- **Checksums**, per branch, as each one appears. A pass reads whole file
  bodies, so each branch is read exactly once and a reader who never opens a
  volume never pays for its files.

A content change does not re-read the file. `PaneUEFIState.invalidate` has
already told the tree which of its branches the edit made stale — the volume or
region it landed in, and nothing beside it — so the panel shows what is left and
the reader re-opens whatever they want back.

## Stages

Each stage builds, tests, and is committable on its own.

1. **Package.** `Modules/UEFITool` with the two targets and the ten-line
   `ToolContentByteSource` adapter, wired into `project.yml` and the registry.
   Empty for now: it builds and the menu lists it.
2. **The pure target.** The zone builder, the zone-id trip back, and the detail
   builder for every kind, with a `swift test` suite over images built byte by
   byte (the `UEFIImage` `TestImage` builders, reused).
3. **The view.** The outline over the tree, the splitter, the detail list, and
   the progress line. The session that reads the pane's tree and publishes the
   one zone.
4. **The app.** The module in the registry, the package in the binary, and the
   app's flow tests: open an image, select a node, and check the zone and the
   detail.
