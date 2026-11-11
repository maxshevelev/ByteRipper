# Design guide — one look for the components the app repeats

The same kind of thing looks the same wherever it appears. A reader who has
used one popover knows where the next one's button is, what Return does in it
and how far its text stands from the edge. When two of them differ, the
difference is read as meaning, so a difference nobody chose is a defect.

This guide covers the components the app draws in more than one place. For
each one it gives the rule, the values, and where the values live in code. A
value written here has to live in code exactly once. When a guide entry has no
shared code behind it yet, the entry says so.

Other documents already settle some areas. This guide points to them rather
than repeating them:

| area | where it is settled |
|---|---|
| marks on a firmware panel's row: colours, symbols, badges | `Design/ROW_MARKS.md` |
| colours that mean something (good, caution, bad, …) | `Packages/AppPalette` (`SemanticColors`, `ZoneColors`, `SegmentTints`, `DifferenceColors`) |
| words, translation, tone | `Design/LOCALIZATION.md` |
| help pages, `?` buttons, anchors | `Design/HELP.md` |
| hex view states, the status bar, the menus | `Design/REQUIREMENTS.md` §6, §15 |
| split views | `ALSplitView`, never `NSSplitView` (`CLAUDE.md`) |

## 1. Type size

Every panel, popover and code view takes its sizes from the app's **Zoom**:
`ToolPanelFont.size` (13 pt by default, 9–24). Sizes are written as multiples
of it, never as points, so that everything grows together.

| role | size |
|---|---|
| body text, table cells, detail rows | `size` |
| prose a reader reads (a summary, a plate, a description) | `size + 1` |
| a popover's title | `(size * 1.35).rounded()`, bold |
| a secondary note under something (a source, a reference) | `max(size - 2, 9)` |
| code, addresses, bytes | `ToolPanelFont.monospaced(size:)` |

**Exception: form popovers.** The bookmark and cut editors use fixed 12 pt
fields. Their fields hold what the user types, and the zoom does not change
their purpose.

## 2. Popovers

The app has two kinds of popover, and each kind has one layout.

### 2.1 An information popover

It says what something is and offers the one place it leads to. Examples:
the function under a call, a name the code explains, a function's callers,
and a module's summary from the UEFI tree.

| part | rule |
|---|---|
| behaviour | `.transient`, `animates = false` |
| edge | `.maxY` from a word in text; `.maxX` from a row of a list or a tree, so that the rows under it stay visible |
| width | fixed: `(size * 40).rounded()`; the callers' table sizes to its columns |
| margins | `(size * 1.3).rounded()` on all four sides |
| spacing between parts | `(size * 0.6).rounded()` |
| order | title (with its mark, when it has one), facts, prose, then the action |
| prose | wrapping label at `size + 1`, selectable, `preferredMaxLayoutWidth` = width − 2 × margin; secondary colour when it says that there is nothing (“not described yet”) |
| long prose | scrolls inside the popover after `(size * 22).rounded()` (`CodeExplanationPopover.scrolling`) |
| loading | a small spinning `NSProgressIndicator` stands where the content will be, and `ControlHelp` says what is being read |
| the action | one button, regular size, `.rounded`, at the bottom, aligned to the leading edge, and it is the **default button** (`keyEquivalent = "\r"`). It is the thing the popover is for, so Return does it and it wears the accent colour |
| a failed load | secondary text beside the dimmed action, saying why |

**The margins are constraints of a container, not `edgeInsets`.** Put the
stack inside a plain view and pin its four sides to that view with the margin,
then fix the container's width. A vertical `NSStackView` with `edgeInsets`
reports a fitting width without its right inset once a wrapping label is in
it, and the popover then cuts the text at its edge. That was the cause of the
module summary bug (`0e6b567e`).

### 2.2 A form popover

It edits one small thing in place. Examples: a bookmark's offset and name, or
a cut's offset and description.

| part | rule |
|---|---|
| behaviour | `.transient`; closing it without Return discards the edit |
| edge | `.maxY` |
| width | fixed at 300 |
| margins | 14 top and bottom, 16 left and right; spacing 8 |
| fields | span the whole width; a placeholder names the field, and there is no label beside it |
| keys | Return commits and Esc leaves the thing unchanged; there is no OK or Cancel button |
| delete | one `.small` button under the fields, never the default |

## 3. Buttons

- **One default button per surface**, and only for the action that surface
  exists to do: the OK of a sheet, **Write** of an update, **Add** of a
  microcode, the action of an information popover. Nothing else gets the
  accent colour.
- **A sheet's buttons** are aligned to the trailing edge, 8 apart: **Cancel**
  (`keyEquivalent = "\u{1B}"`) and then the default button. A message about a
  field sits just under the fields, and the full gap comes before the buttons.
- **A destructive button** is never the default and never alone in a place
  where Return could reach it.
- **Size.** Use regular buttons in sheets and popovers. Use `.small` in a
  panel's chrome and for secondary actions under a form.
- **Bezel.** `.rounded` for a button with a title. `.inline` with no border for
  a glyph that sits in a row or a bar.

## 4. Glyph buttons in rows and bars

- **Something that opens something has a link's colour.** Examples: the
  CPUID's (i) on a microcode, a module's (i), and the code panel's book while
  a description is available. Use `NSColor.linkColor`, and on a selected row
  use `alternateSelectedControlTextColor`, because blue on the accent colour
  cannot be seen.
- **The (i)** is `info.circle`, semibold, at `ToolPanelTable.codeBadgePointSize`,
  drawn as a palette symbol in that colour.
- **Size an image view from `image.size`, not from its intrinsic size.** An
  image view reports the wrong size for a configured symbol. Tint with
  `.sourceIn` when the symbol is not a palette symbol.
- **A button in a table cell names its target** when the cell is made. With a
  nil target, the action travels the responder chain from whatever has the
  focus, and that may be another pane.
- **Toolbar items** use plain `NSToolbarItem` images. A view item draws small.

## 5. Words on a control

- Every user-visible string goes through `L("…")`.
- A control's name and tooltip come from `ControlHelp`: one phrase, or
  `name:` and `tooltip:` when what it *is* and what it *does* are two
  sentences.
- Anything user-visible declares `// help: <anchor>` where it is implemented,
  and a help page covers that anchor (`Design/LOCALIZATION.md`, `Design/HELP.md`).

## 6. Progress and failure

- Show progress where the result will appear, not in a separate place.
- A spinner says it is working. A bar says how much is left, so use a bar only
  when that amount is known.
- Say what is being done: **Loading** while data comes from the server,
  **Reading** while this Mac works on what it already has.
- A failure leaves what was on screen in place and says why in secondary or
  `SemanticColors.bad` text next to the place it concerns, until the next
  choice.

## 7. Theme and appearance

- Colours come from the system (`labelColor`, `secondaryLabelColor`,
  `linkColor`, …) or from `AppPalette`. Never hand-mix a colour.
- A layer's shadow is set again in `viewDidChangeEffectiveAppearance`, because
  AppKit resets `shadowOpacity` before it is called.
- Dark Mode is checked for every new surface.

## 8. Checking a layout

Measure before changing a layout, and test what was measured. Load the view,
lay it out, and assert frames in the coordinate space of the outermost view,
comparing **alignment rects**, not frames. A text field's frame extends 2 pt
past its text, so the frames of a title and a button do not line up even when
their text does. `ToolRowMarksTests.testALongSummaryKeepsThePopoversMargins`
is the pattern. To check how something looks, capture the window with
`CGWindowListCreateImage` instead of reading numbers.

## 9. Where the code stands

The rules above are the target, and the code does not meet all of them yet.
Each line below is a known deviation. Remove it from this list when it is
fixed.

| component | deviation |
|---|---|
| `CodeFunctionPopover` | **Go to Function** is not the default button, so it is grey where **Open with Code** is accent-coloured, and Return does nothing |
| `ToolPanelModuleSummaryPopover` | title `size * 1.25` (rule: 1.35), margins `size * 1.2` (1.3), prose at `size` (`size + 1`), width `size * 34` (40) |
| `CodeFunctionPopover`, `CodeExplanationPopover`, `CodeCallersPopover` | margins come from `edgeInsets` rather than a container's constraints; they hold only because each pins its stack's width |
| information popovers | the metrics are written in every popover, and no shared code holds them |
