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
| prose in a popover (a summary, a plate), as in the help popovers | `size` |
| a header over a part of a popover | `size`, semibold |
| a popover's title | `(size * 1.2).rounded()`, bold |
| a secondary note under something (a source, a reference) | `max(size - 2, 9)` |
| code, addresses, bytes | `ToolPanelFont.monospaced(size:)` |

The information popovers take these sizes from `ToolPanelPopover`
(`titleFont`, `proseFont`, `headerFont`, `noteFont`).

**Exception: form popovers.** The bookmark and cut editors use fixed 12 pt
fields. Their fields hold what the user types, and the zoom does not change
their purpose.

## 2. Popovers

The app has two kinds of popover, and each kind has one layout.

### 2.1 An information popover

It says what something is and offers the one place it leads to. Examples:
the function under a call, a name the code explains, a function's callers,
a module's summary from the UEFI tree, and a CPUID's processors in the FIT
table and the microcode catalogue.

The layout lives in `ToolPanelPopover` (`Packages/ToolModuleKit`). A popover
asks it for its parts (`stack`, `title`, `prose`, `action`, `content`,
`show`) and never writes a size of its own.

| part | rule |
|---|---|
| behaviour | `.transient`, `animates = false` |
| edge | `.maxY` from a word in text; `.maxX` from a row of a list or a tree, so that the rows under it stay visible |
| width | fixed: `(size * 40).rounded()`; the callers' table sizes to its columns |
| margins | `(size * 1.3).rounded()` on all four sides |
| spacing between parts | `(size * 0.6).rounded()` |
| order | title (with its mark, when it has one), facts, prose, then the action |
| prose | wrapping label at `size`, selectable, `preferredMaxLayoutWidth` = width − 2 × margin; secondary colour when it says that there is nothing (“not described yet”) |
| long prose | scrolls inside the popover after `(size * 22).rounded()` (`CodeExplanationPopover.scrolling`) |
| loading | a small spinning `NSProgressIndicator` stands where the content will be, and `ControlHelp` says what is being read |
| the action | one button, regular size, `.rounded`, at the bottom, aligned to the leading edge, and it is the **default button** (`ToolPanelPopover.action`). It is the thing the popover is for, so Return does it and it wears the accent colour. Once shown, the popover's window holds the Return as its `defaultButtonCell`, and the button's own `keyEquivalent` then reads empty; a test checks the window |
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
  CPUID's (i) on a microcode, a module's (i), a field's (i), every (?) in a
  panel's chrome or a popover (`HelpButton.inline`, the detail pane's term
  button), and the code panel's book while a description is available. Use `NSColor.linkColor`, and on a selected row
  use `alternateSelectedControlTextColor`, because blue on the accent colour
  cannot be seen.
- **The (i)** is `ToolPanelInfoButton` (`Packages/ToolModuleKit`):
  `info.circle`, semibold, at `ToolPanelTable.codeBadgePointSize`, drawn as a
  palette symbol in that colour, with its `backgroundStyle` passed on from the
  row. It is always a real button. Inside text, as on the FIT table's CPUID
  lines, the text keeps an empty room for it and the button is laid over
  that room. A link or an attachment in the text loses the click to the
  text's selection and to the table's row.
- **Size an image view from `image.size`, not from its intrinsic size.** An
  image view reports the wrong size for a configured symbol. Tint with
  `.sourceIn` when the symbol is not a palette symbol.
- **A button in a table cell names its target** when the cell is made. With a
  nil target, the action travels the responder chain from whatever has the
  focus, and that may be another pane.
- **Toolbar items** use plain `NSToolbarItem` images. A view item draws small.
- **(?) is the help's, and only the help's.** A question mark on screen
  opens a page of the book (`HelpButton`); no other mark uses one.
- **A row the review inferred** rather than read from the code (a record row
  with confidence `inference`) is drawn in italics, with `circle.dashed` in
  the secondary colour after its key; the pointer on the row reads
  "Inference: <the row's note>" (`CodeRecordSectionView`).
- **Every list of the code navigator's tabs** — Interfaces, Search, the
  records, and the Functions list's rows — is drawn one way, from one place in
  `CodeNavigatorCell` (`Packages/CodeView`):
  - an outline is set up by `CodeNavigatorCell.dress` (the Functions table,
    which also takes columns, sets the same by hand): one column, no
    header, `.inset` with the system's rounded selection, the navigator's row
    height, no indentation or cell gaps of AppKit's own;
  - every row is a `CodeNavigatorCell` (or a subclass): the chevron's room,
    then a mark on a coloured square (`CodeNavigatorIcon`; a letter for an
    entry — `f`, `G`, a record's letter — a symbol for a heading; a record's
    row under a branch carries its branch's mark), then the
    words in `navigatorFont`; a level further in moves by `indent`;
  - a heading's words are `CodeNavigatorCell.headingAttributes()`: one
    weight up, grey, the count in brackets after them;
  - a control in a row — a heading's (?) or a branch's (i) — stands right
    after the words (`showsAccessory`), never at the trailing edge;
  - a branch opens and closes animated, through
    `CodeNavigatorCell.toggle(_:in:)`, from the chevron and from the row;
  - the filter is at the bottom, `CodePaneView.dressFilter`;
  - a tab is a `CodeNavigatorTreePanel`: its outline, the data source over
    the tab's nodes (`CodeNavigatorTreeNode`), the chevron redrawn as a branch
    opens and closes, a row chosen by a click or the arrow keys (`choose`),
    the window's fill under the list, and the zoom remaking the rows with
    what was open still open and the top row at the top. A tab gives its
    roots, its cells and what choosing a row does.
  A new tab adds no table settings, fonts, toggles or tree mechanics of its
  own.
- **A record tab in the navigator** is a list and details, as Functions:
  one column, a line of key in monospace and a short label (the `label`
  column, else the first sentence of the main text), labels aligned past the
  widest key by a tab stop, no sideways scroll, drawn as every navigator
  list above. A line carries at most one mark after its key: the inference
  circle; a tag after the key says the rest (flash, PEC, a pin's IN, OUT or I/O); an interrupt left off reads in grey. A
  branch shows its row count and an (i) whose popover holds what the
  profile says of it and the review's own note for it (`branch_notes`).
  The branch row is never an AppKit group row, which draws its
  `textField` in its own font until the row is made again. The selected row's details are the
  firmware panels' own: a `ToolDetailPane` under the list in an
  `ALSplitView`, filled by `ToolDetailScroll.showRows` — title (key, and
  the review's `label` if any), each field once with the main text whole
  and no field for the branch, links as `toolFieldLink` runs of a
  `ToolFieldList` value, back-references, confidence and note; Space or
  the corner button opens it large. No tooltip repeats what its row,
  branch or legend line shows. The label is never cut in the text, only
  by the line at the column's width. Each record keeps its selected row
  and scroll across tab switches and new revisions. Over the list stands one line,
  the record's name and status, and an (i) after it whose popover holds
  the review's words on the record and nothing else: what its rows cover
  (`note`) and, under a warning sign and a bold
  **Not checked:**, what the review has not checked (`not_checked`).
  Nothing over the list opens or takes the list's room; every record tab
  is drawn so. The filter is at the
  foot, as the Functions list has it (`CodePaneView.dressFilter`).

## 4a. The reader's line in read-only text

A view that is read and not edited has no caret. The line the reader is on
is marked instead with `CodeColors.currentLine`, Xcode's current-line colour,
across the whole width. That line is the one last clicked, or the selected
row of a list of lines. The band is half see-through (`currentLineAlpha`), drawn
over a diff's row tints and under a highlighted name, so a red or green row
stays red or green. The text keeps its own colours on it. While a block of text
is selected, the band is hidden. **↑ ↓** move it a line, **Page Up** and
**Page Down** a screen, **Home** and **End** to the first and the last line.
The C (`CodeTextView`) and the ASM listing (`CodeListingTableView`,
`CodeListingRowView`) follow this rule.

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

The rules above are the target. Each line below is a known deviation. Remove
it from this list when it is fixed.

| component | deviation |
|---|---|
| form popovers (`BookmarkEditPopover`, `CutEditPopover`) | their metrics are written in each of the two, the same in both, and no shared code holds them |
| sheets | the button row is written in `SheetControllers` and again in each tool's own sheet |
