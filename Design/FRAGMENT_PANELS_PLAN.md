# Fragment panels — a part of a file, opened over the window that holds it

> A zone, a decompressed body, anything a tool-module hands over: today it opens
> in a tab of its own and the file it came out of disappears behind it. It
> should open *over* that file instead — a panel that rises from the bottom,
> leaves the parent showing above it, and folds down into a pill in a dock along
> the window's bottom edge. A tab stays what `TABS_PLAN.md` says it is: a
> comparison. A part of a file is not a comparison.

## Why

The link back already exists and is the whole point of the feature.
`DocumentOrigin` (`ByteRipperApp/Documents/DocumentOrigin.swift`) holds the
parent pane weakly, the range the bytes came out of, and what putting them back
would do; `performUpdateInParent` writes them back as one undo step in the
parent. The pane's header even carries a link button that names the parent and
jumps to it — and that button exists *because the parent is not on screen*. A
tab is the reason it had to be built.

Three things follow from opening the part over its parent instead:

- **Update in Parent becomes something you can watch.** Edit the decompressed
  section, put it back, fold the panel down, and the change is right there in
  the dump behind it. Today that is three tab switches.
- **The dock says what you have pulled out of this image.** Four pills along the
  bottom of the window are four parts of *this* dump. A tab bar mixes them with
  other people's comparisons and sorts them by nothing.
- **The web edition gets the feature at all.** `ByteRipperWeb`'s D11 is one
  workspace per browser tab, with no in-app tabs; its G4 — a part opened as its
  own document, and Update in Parent — has been postponed outright, waiting for
  upstream to decide where a part opens when there is no tab to open it into.
  This is that decision, and it is made here so the port has Swift to read.

## The one way a part opens

Every command that opens a part opens a panel. There is no second route, because
two routes to one act means two of everything — menu validation, ⌘W, Esc, what
Find is aimed at, what the active pane is.

What changes its destination:

| Site | Now | Becomes |
| --- | --- | --- |
| `MainViewController.openZoneInNewTab` | sibling tab | fragment panel |
| `minimapMenuOpenZoneInNewTab` | sibling tab | fragment panel |
| `openBytesInNewTabForTool` | sibling tab | fragment panel |
| `ToolHost.openInNewTab` (`Packages/ToolModuleKit`) | the seam's name | `openPart` |
| `UEFITreeProviding.openInNewTab` (`Packages/UEFIImage`) | the seam's name | `openPart` |
| The zone menus' wording, dump block and minimap gutter | menu wording | `"Open Zone …"` |
| `UEFIPresenter.openTitle` (`Modules/UEFITool`) | `"… in New Tab"` | `"Open Decompressed Body"` |

**What does not change:** the pane header's own `Open in New Tab`
(`openPaneInNewTab`) and the New Tab drop strip. Those move a whole pane — a
file, with its own bookmarks and its own comparison to be — and a tab is exactly
right for them.

## What it looks like

```
┌──────────────────────────────┐
│▒ File A / File B ▒▒▒▒▒▒▒▒▒▒▒▒│ ← the parent shows above
├──────────────────────────────┤ ← the panel's shadow falls upward
│ NVRAM @0x300000 · bios.bin ⌄ │ ← the same header a pane has, link and all
│ ┌───────┬──────────┬───────┐ │
│ │ tool  │ hex      │ map   │ │
│ └───────┴──────────┴───────┘ │
├──────────────────────────────┤
│ ( NVRAM ) ( ME body )   dock │ ← folded panels, one pill each
└──────────────────────────────┘
```

The panel is anchored to the dock strip, and its top edge **covers a fifth of
the panes' header**. That overlap is the shape's whole point: enough of the
parent shows to say which file the part came out of, and cutting into its header
is what says the panel is laid *over* that file rather than docked beside it. A
panel you cannot see the parent behind is a tab with a shadow; one that clears
the header entirely reads as a second pane.

The area a panel slides in is exactly the area the panes occupy — below the New
Tab strip and above the dock — so a panel never covers either, and the strip
stays reachable for dragging a panel out to a tab while one is up. In a window
too short for the panel to be useful the peek gives way before the panel does,
and in one shorter still the panel takes what there is.

At most one panel is expanded. Clicking another pill folds the open one down and
raises that one, in one animation.

## The panel is a surface, not a pane

The requirement is that the panel has its own header, its own minimap and its own
tool panel. That is not a pane — it is everything `MainViewController` currently
*is* below the find bar, and all three of those are window singletons today:

- `panelSplit` = `[tools.panel | contentHost | minimapPanel]`, one per window,
  with its divider clamps and persisted widths;
- `MinimapView` draws one or two maps by `mapIndex`, and its entire feed —
  `byteStates`, `matchRanges`, overview rebuild, bookmarks, segments, zones — is
  closures held in `MainViewController`;
- `ToolController` is one per tab, its `boundPane` deliberately never
  re-pointed, and its `owner` typed as `MainViewController` outright.

So the work is to lift that composite out into a **`DocumentSurface`**: the
split, the minimap wiring, the tool controller, and one or two panes. The window's
content becomes surface 0 with its one or two panes; every fragment panel is a
surface with exactly one. `ToolController.owner` becomes a protocol the surface
conforms to — the alerts, the open/save panels and the part-opening the host
does — rather than a concrete controller.

This is the decomposition `TABS_PLAN.md` began when it sorted what is the
window's from what is the tab's, carried one level further: what is the tab's
from what is the *surface's*. It is worth doing on its own merits; `MainViewController`
is 7,482 lines.

| Per surface | Per tab | Per application |
| --- | --- | --- |
| the pane(s) and the active-pane pointer | the dock and which panel is up | settings, theme, file-type registration |
| the minimap, its mode and overviews | the find bar and the toolbar | the Settings window |
| the tool panel and its session | the window's own bookmarks | the menu bar |
| the split widths | the comparison | which files are open and where |
| the bookmark list it reads | | the sandbox's bookmarks |

## Which commands follow the front surface

`activePane` is one computed property read from 63 places. Routing it
through the front surface is one line; the work is auditing those 63 and sorting
them into two lists, which the plan owes before any of it is written:

- **Follow the front surface**: Find, Go To, the Edit menu, caret and selection,
  Save Selection as…, the tool-module commands, the minimap's mode, Update in
  Parent.
- **Stay with the window's panes, whatever is up**: File ▸ Open and the open
  placement rules (§4.1 — a file opens into a *pane*, never into a fragment
  panel), drag-and-drop of files, Swap Panels, the comparison itself, Close Pane,
  the New Tab strip.

A command in neither list is a bug in this plan, not a judgement call at the call
site.

## The dock is a model

Which panels exist, in what order, which one is up, what folding and unfolding do
— none of that is AppKit. It is a small pure type with unit tests, and it is the
piece the web port takes verbatim rather than re-derives:

```
FragmentDock
  panels: [Panel]        // order is the order they were opened
  expanded: Panel.ID?    // at most one
  open(_:) / expand(_:) / collapse(_:) / close(_:) -> Effect
```

Everything about a pill's look, the slide, and the shadow is the view's. Nothing
about *which* pill is up is.

## Bookmarks

A fragment panel reads **the window's list**, at the part's own offsets (§20.7).

The first version gave every panel a `BookmarkStore` of its own, reasoning that a
part's offsets are its own. That is true of the offsets and false of the marks: a
bookmark is a row of a *file*, and a panel is a window onto that file, not a
different one. A mark put on the ME region in the dump should be on the ME region
in the part taken out of it, and it was not — the two lists could not see each
other, so marking a row twice was the only way to have it marked in both places.

`BookmarkSpace` is the fix and the whole of it: the list, plus where the pane's
byte 0 sits in it. The tab's two panes get it at offset 0 (a mark is an absolute
offset and means the same row in both, §20), and a panel gets it at the part's
offset in its parent — the parent's own plus `sourceRange.lowerBound`, so a part
opened out of a part composes without anyone counting the depth. Every verb is in
the pane's offsets and the translation lives in that one type.

A **decompressed** body is the exception, and it is the exception for the reason
the original decision was reaching for: those bytes are not the file's bytes, so
no offset in them is an offset in the list. Its pane gets no space at all — marks
are neither drawn nor made, the offset menu carries no bookmark block, ⌘D and
⇧⌘D are off, and the Go To form opens with its list closed over a sentence
saying why rather than looking merely empty.

## Tearing a panel off into a tab

A fragment panel that is up is dragged by its header onto the New Tab strip and
leaves for a tab of its own — the same gesture, the same strip and the same
handle a pane is torn off by, because a panel's header *is* a pane's. A folded
one has no header on screen, so its pill carries **Open in New Tab** in its own
menu, and the header's menu carries the same item for the panel that is up. The
mechanism underneath all three is the one that already exists, and is the right
one: `releasePane(at:)` / `adoptPane(_:bookmarks:)` **move** the
`PaneViewModel` object, so the document, the unsaved edits, the undo history, the
segments and the change watcher travel with it, and the file stays open exactly
once (§4.1 rule 6 is never in question).

`origin` is a property of the pane, so **the link to the parent survives the
move**: a part torn off into a tab still knows where it came from and still has
Update in Parent, exactly as a part opened into a tab does today. The panel's own
bookmarks travel as the copy `adoptPane` seeds — at the part's own offsets,
because the tab it lands in is about those bytes and its list is in their
addresses, not the parent file's.

What leaves the dock is the surface, not the pane alone: its tool session ends
where its pane does (`tools.paneLeft`), and the tab opens the same tool-module
afresh if one was bound — the rule `tearOff` already follows.

**The other direction is not offered.** A pane cannot be dragged into the dock.
A pane holds a file; the dock holds parts of a file that is open in this window,
each with a link back. A document with no origin has nothing to be a fragment of.

## Closing, Esc, ⌘W

- **Esc** with a panel up folds it into its pill. It does not close anything.
- **⌘W** with a panel up closes *that panel*; with none up it closes the tab, as
  it does now.
- Closing a panel that is dirty asks the ordinary save/discard question, and —
  this is the new one — a panel whose `origin.hasChanges(in:)` is true says so:
  the bytes have not been put back, and closing loses them. Same for closing a
  tab that still has pills in its dock.
- A panel whose parent has gone (`origin.state == .parentClosed`) stays in the
  dock. It is a document; Update in Parent refuses it with the message it
  already has.

## A fragment of a fragment

A tool-module opened on a fragment panel can hand over a part of it — a section
inside a decompressed body. That opens another panel in the same dock, whose
`origin.parent` is the fragment's pane. The dock stays flat; the links form the
tree, and Update in Parent walks one step of it at a time, which is what it does
today. Nothing new is needed for this; it falls out of `DocumentOrigin` taking a
`PaneViewModel` rather than a window.

## Animation

Fold and unfold are one animation with one duration, driven by the panel's frame.
`ALSplitView` is not involved — the panel is not a pane of a split, it is a view
over the content area (the rule that every split view is `ALSplitView` still
holds for the split *inside* the panel). The shadow is the panel's own, cast
upward onto the parent.

## What the web takes

The port reads the Swift, as ever. `FragmentDock`, the command routing table and
the closing rules port directly; the surface is React composition rather than a
view-controller extraction, and the drag-out to a tab is `n/a` under D11 — there
is no tab to tear off into, which is one row in `GAPS.md` and not a hole in the
model. D11 itself stays true and gains a sentence: a part opens in a panel, which
is not a tab. G4 unblocks.

## Stages

1. **`FragmentDock`** — pure, unit-tested, no AppKit.
2. **Extract `DocumentSurface`** from `MainViewController`, window content
   becomes surface 0. No user-visible change; the existing suite is the check.
3. **The panel and the dock** — geometry, shadow, animation, pills.
4. **Re-aim the commands**, rename the seam, update `Modules/UEFITool`'s titles
   and tests, and settle the 63 `activePane` sites.
5. **Tear-off to a tab** through the New Tab strip.
6. **Port**, closing G4.

## The panel's own minimap and tool panel

A panel covers the whole content area, the tab's own side panels included, so
there is never a minimap or a tool panel on screen but the panel's. That settles
the interface without inventing any: **the commands follow what is in front**,
which is the rule everything else already follows. The toolbar's minimap button
and the Tools menu sit directly above the panel and act on the map and the tool
you can see; fold the panel and they mean the tab's again, each side keeping its
own.

What a panel opens with: **the minimap the tab has** — someone who works with
the map on wants it on the part too, and a part is exactly where a map earns its
place — and **no tool panel**, because running a parser over every part that is
opened is work nobody asked for and *which* tool is a choice.

Side-panel widths are the tab's, shared. A map that changed width as a panel was
folded and raised would be a jump for no reason.

Neither takes the window's width with it: a panel opens its map and its tool
inside the area it was given. A window that grew because something inside a
panel over it opened would be the window moving for something that is not the
window's.

## Open questions

- Is there a keyboard route to the dock — ⌃1…⌃9 by position, say — or is it
  pointer-only in the first cut?
- The gutter's own menus on a panel's map — Select Zone, the segment commands —
  are off for now: they are menu actions addressed to the tab, and pointing them
  at a surface is its own change.
