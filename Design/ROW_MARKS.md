# Row marks — one way to mark a row, in every firmware panel

A row in a firmware panel can say more than its text: that its bytes live in a
decompressed buffer, that an edit to it breaks a hash something checks at boot,
that it holds a compressed section or the hashes others are checked against,
that it compares well or badly with what it could be, that something in it is
wrong. This document gives each of those one visual channel, reserves the
colours and symbols for them, and says what each channel means in each panel:
the **UEFI Structure** tree, the **FIT** table and the **ME Analyzer** Full
Tree.

One set of rules for all three, because a reader moves between them on the same
image: a rose row in the FIT table has to mean what a rose row in the UEFI tree
means.

---

## 1. The channels

| Channel | The question it answers | Drawn as |
| --- | --- | --- |
| Background | What does an edit here break? | a translucent tint behind the whole row |
| Rail | Where do these bytes live? | a 3 pt bar at the row's leading edge |
| Verdict | How does this compare with what it could be? | an SF Symbol in the text column |
| Problem | What is wrong with it? | an SF Symbol in the text column |
| Role badges | What is this row to the others? | up to two SF Symbols in the text column |

The icons sit in the column the row is named by — the UEFI tree's Name, the FIT
table's Type, the ME tree's title — in this order, leading to trailing:

**verdict · problem · role badges · text**

Verdict before problem is the order `ToolPanelTable` already lays out, for the
reason it gives: where a panel has a verdict, it is what the reader reads the
column for. Role badges sit against the text because they describe the thing
the text names. An icon a row does not wear takes no room.

**Why protection takes the background.** Protection and decompression overlap on
nearly every image — the DXE volume sits inside an LZMA section *and* under a
vendor hash or the post-IBB range — and one background cannot say both.
Protection is the answer that decides whether an edit is safe, and UEFITool
already draws it as a row background, so a reader coming from it looks there.
The rail says the other answer without mixing colours with it.

---

## 2. The rules, for every panel

- **Background: Boot Guard protection, by file range**
  (`UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §7.3). A row whose bytes lie wholly
  inside the IBB is tinted *IBB*; wholly inside the union of all ranges,
  *firmware-checked*. A row only partly covered gets no tint — a region or a
  volume would be coloured for bytes it mostly is not — and wears the
  *partly protected* badge instead. A row with no range in the file has no
  background; a row inside a compressed section takes the background of the
  section that holds it.
- **Rail: decompressed.** A row whose bytes, or whose values, came out of a
  decompressed buffer, and the row holding that compressed data while it is open
  on what came out of it — so the rail ties the subtree to its parent, the way
  the eye groups a subtree. A shut holder has nothing to tie and no rail, even
  with its branch already read. One rail whatever the nesting — indentation
  already shows depth. The holder's bytes are still the file's, so its tooltip
  says it holds decompressed rows, not that it was decompressed.
- **Problem: one icon, the worst.** An error — a checksum, a hash or a
  signature that does not check out — is the red octagon; a caution — something
  that could not be checked, or is suspicious without being wrong — is the
  orange circle. Every problem the row has is in the icon's tooltip. A badge
  never signals a problem, and a verdict never signals an error.
- **Selection** replaces the background, as on every table; the rail and the
  icons stay drawn over it.
- **Show Markings**, in the header of the panel's legend (§6), turns the
  background and the rail off and on, remembered like the panel's other
  settings. The icons stay: they are part of what the row says.
- **Nothing by colour alone.** The row's tooltip names its background and rail
  in words ("Inside the IBB · decompressed from LZMA section at 0x60"), and
  every panel that marks its rows has a legend that says what each colour and
  each icon means (§6).
- **Text colour carries no mark.** It keeps the meanings it has: grey for a place
  that holds nothing (the ME tree's empty sections), standard otherwise.
- **Never a red, orange or green background.** Those are `SemanticColors` —
  bad, caution, good — and in the dump red is "modified" and orange is
  "different".

---

## 3. Reserved colours

An `AppPalette` group, `RowMarks`, so a panel names a meaning and not a colour.
Components are sRGB, `(red, green, blue, alpha)`.

| Catalogue name | Meaning | Light | Dark |
| --- | --- | --- | --- |
| `RowProtectedIBB` | background: wholly inside the Boot Guard IBB | `(1.000, 0.176, 0.333, 0.14)` rose | `(1.000, 0.216, 0.373, 0.24)` |
| `RowProtectedFirmware` | background: wholly inside firmware-checked ranges — post-IBB, PMDA, vendor hash files | `(0.196, 0.678, 0.902, 0.14)` cyan | `(0.392, 0.824, 1.000, 0.20)` |
| `RowDecompressed` | the rail, and the compressed badge where the data decodes | `(0.345, 0.337, 0.839, 1.00)` indigo | `(0.490, 0.478, 1.000, 1.00)` |

Rose rather than UEFITool's red, so a protected row never reads as an error
beside the red octagon. Cyan follows UEFITool; it is near `ZoneFocused` in hue,
which is drawn in the dump and not in a panel.

---

## 4. Reserved symbols

| SF Symbol | Channel | Meaning | Tint |
| --- | --- | --- | --- |
| `exclamationmark.octagon.fill` | problem | error: something is wrong | `SemanticColors.bad` |
| `exclamationmark.circle.fill` | problem | caution: could not be checked, or suspicious | `SemanticColors.caution` |
| `zipper.page` | badge | holds compressed data this project decodes | `RowDecompressed` |
| `zipper.page` | badge | holds compressed data it does not decode — an unsupported algorithm, an encrypted module, a missing dictionary, a failed decode (which also raises a problem) | `secondaryLabelColor` |
| `lock.shield` | badge | holds what others are checked against — protected ranges, or the hashes of other structures | `secondaryLabelColor` |
| `shield.lefthalf.filled` | badge | partly covered by protected ranges | `secondaryLabelColor` |

The verdict slot's symbols are the panel's own. The FIT table's, already in use:
`checkmark.seal.fill` (good — newest revision), `exclamationmark.triangle`
(caution — a newer one serves this board), `questionmark.circle` (caution — a
newer one might). The outline triangle stays the verdict's; a problem is never a
triangle, so the two never meet in one shape.

---

## 5. What each channel means, panel by panel

### 5.1. UEFI Structure — the tree

| Channel | Meaning here |
| --- | --- |
| Background | the node's file range against the protected ranges; a node inside a compressed section takes its holder's |
| Rail | the node's `space` is not `.file`, or it is a compressed section whose row is open on its decompressed children |
| Verdict | none |
| Problem | a wrong checksum (error) — today; a protected range whose hash does not match (error), a compressed section that did not decompress (caution) — with that work |
| Badges | `zipper.page` on a compressed section; `lock.shield` on an AMI or Phoenix hash file and an Insyde Flash Device Map; `shield.lefthalf.filled` on a partly covered node |

### 5.2. FIT — the table

| Channel | Meaning here |
| --- | --- |
| Background | the component the row points at (`targetRange`); the header row by the table's own bytes. A FIT component written inside a protected range is the case this exists for. |
| Rail | never: a FIT address is physical, and nothing it points at is inside a compressed section |
| Verdict | the microcode row's "latest" state, as today |
| Problem | the validator's problems for the row — the red octagon, as today; a caution-level one takes the orange circle |
| Badges | `lock.shield` on the Boot Guard Key Manifest (`0x0B`) and Boot Policy (`0x0C`) rows — they define the IBB; `shield.lefthalf.filled` when the component is partly covered |

### 5.3. ME Analyzer — the Full Tree

| Channel | Meaning here |
| --- | --- |
| Background | the node's `range` against the protected ranges, by the same rule. The ranges lie in the BIOS region, so an ME dump shows none — which is the truth, and the rule stays one rule. |
| Rail | a row whose values were decoded out of a decompressed module body: the RBE/PM Metadata rows when `pm`/`rbe` is stored compressed today; a module's internals when those are shown |
| Verdict | none |
| Problem | facts local to the row: a `$CPD` checksum that does not add up, a manifest whose RSA signature is invalid, a module whose Huffman or LZMA check failed (Issue ids 7 and 19). The last needs the engine's `Issue` to name its module — a result-model change, through the `sync-mea-engine` skill — before it can attach to a row; until then it stays in the Issues group only. |
| Badges | `zipper.page` on a module row stored compressed: indigo for LZMA, and for Huffman when the dictionary is at hand; grey for an encrypted module or a Huffman one with no dictionary. `lock.shield` on the manifest row — the hashes the modules are checked against. |

The Summary tab's status tones and the Issues group are not rows of this kind
and keep their own look.

---

## 6. The legend

**Every panel that marks its rows with colour or icons has a legend.** A mark a
reader has to guess at is a mark that is not doing its job, and the tooltip on
one row does not tell a reader what the rose rows three screens down are before
they hover over one.

- **Where.** A disclosure strip at the bottom of the table or tree, inside its
  pane — above the splitter in the UEFI and ME panels, under the entries in the
  FIT panel. Collapsed, it is one line: a disclosure chevron, "Legend", and the
  Show Markings switch (§2). Expanded, it grows upward and the table gives up
  the room; it never covers rows.
- **Room to read.** A margin above the header and below the last line, a
  wider gap between the header and the list, and space between the lines — a
  strip of text packed against the table's edge reads as part of the table.
- **Collapsed by default,** and its state remembered per panel like the panel's
  other settings — a reader who has learnt the marks stops paying the room.
- **What it lists.** One line per mark this panel can draw, grouped by channel in
  the order of §1 — background, rail, verdict, problem, role — each with a
  sample drawn exactly as the row draws it (the tint as a swatch over the row
  colour, the rail as a bar, the symbol in its tint) and a few words of meaning.
  A mark this panel never draws is not listed: the FIT legend has no rail, the ME
  legend no background and no partly-protected badge (§5). A mark that is
  reserved but not drawn yet — the Boot Guard ones, until the ranges are read —
  joins the legend in the same change that starts drawing it.
- **The same source as the rows.** The legend's entries come from the one
  catalogue in `ToolModuleKit` that dresses the cells (§7) — the same colour,
  the same symbol, the same words the tooltips use — so the legend and the rows
  cannot disagree. A panel adds only what is its own: the FIT table its verdict
  symbols and their meanings.
- **Markings off.** With Show Markings off the background and rail entries stay
  in the legend, greyed, so the switch explains what it has hidden.
- **Size and appearance.** The legend follows the panel's type size
  (`ToolPanelFont`) and both appearances, like the rows it explains, and every
  entry is text that VoiceOver reads.

---

## 7. Where it is decided

- **`ToolModuleKit`**, because three tool-modules draw it:
  - `ToolRowMarks` — a value with no AppKit in it: the background (`ibb`,
    `firmware`, none), the rail, the problem (`error` or `caution`, with its
    text), and the role badges. The verdict stays the panel's own, through
    `ToolPanelTable.setMarker` as today.
  - `ToolPanelRowView`, an `NSTableRowView` that draws the background under the
    cells and the rail over the selection.
  - `ToolPanelTable.makeCell` grows the badge slots, and one call dresses a cell
    from a `ToolRowMarks`. The symbol names live there, once.
  - `ToolRowMarksLegend`, the disclosure strip of §6: handed the channels and
    marks a panel draws (plus the panel's own verdict entries), it builds its
    lines from the same catalogue the cells are dressed from, and owns the Show
    Markings switch.
- **`AppPalette`** — the `RowMarks` colours.
- **Each tool-module's pure target** builds a `ToolRowMarks` per row — the UEFI
  tree from the node, the image, the checksum pass and the protected ranges; the
  FIT table from its display row and the image; the ME tree from the analysis —
  and tests it without a window. The view controllers only hand it to
  `ToolModuleKit`.

## 8. Order of work

Each step that starts drawing a mark adds it to that panel's legend in the same
change (§6).

**Status, 2026-09-13.** Steps 1 and 2 are in, and step 5 for the UEFI tree
alone: its background, `shield.lefthalf.filled`, `lock.shield` on the AMI and
Phoenix hash files and the Insyde flash device map, the hash problems, and the
four marks in its legend. The FIT table and the ME tree take theirs with steps 3
and 4, which draw no marks yet. Where the code differs from the
text: a compressed section carries `UEFINode.compression` (algorithm, and
whether it decodes), set by the parser, which is what the badge is read from;
the legend's lines are plain views with every edge constrained rather than
stacks, because a stack line inside the list was ambiguous in a window; and the
legend and switch states live in `ToolPanelFont.defaults`, the store the app
already points at its own suite.

1. `ToolModuleKit` — the row view, the cell's slots, the dressing call, the
   legend strip with its Show Markings switch — and the `AppPalette` colours.
2. UEFI Structure: the rail, `zipper.page`, the checksum problem through the new
   call, and the legend.
3. ME Analyzer: `zipper.page` on compressed modules, the rail on the RBE/PM rows,
   `lock.shield` on the manifest, the node-local problems, and the legend.
4. FIT: `lock.shield` on the Key Manifest and Boot Policy rows, its problems
   through the new call, and the legend with its verdict entries.
5. With the Boot Guard work (`UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §9): the
   background, `shield.lefthalf.filled` and the protection problems, in all
   three rows and legends at once.
