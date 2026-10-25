# The Code panel — a module's code beside its bytes

> A TE/PE32 image in the UEFI tree can have a code analysis kept beside it in
> the local CAS. The tree marks the image, and **Open with Code** opens the
> module's bytes with its code in a fragment panel over the dump. Ghidra runs
> once; the panel and an agent read the result afterwards without it.

**In scope.** The association between a firmware node and a stored analysis,
the tree badge, the replacement of `Open Body` for an analyzed image, the
fragment panel with the module's bytes and its code, the read model, the help
and the tests.

**Not in scope.** Running Ghidra from the app, editing code, a second hex view,
per-section analyses, a code diff between two dumps, and a general code browser
for files that are not in a UEFI tree. Those can come later; the read model is
built so they can.

## Decisions taken

1. **The unit is the module image, not the FFS file and not the section as a
   container.** A TE/PE32 image is what Ghidra analyzes. An FFS file may hold
   several images; a section is a header and a body that happens to contain one.
   The node is the one whose **body is the image**: a `section` with subtype
   `0x10` (PE32) or `0x12` (TE), or a raw `file` whose body is the image.
2. **The association is computed, not stored.** The key is the SHA-256 of the
   exact module blob plus the recipe; the CAS is the authority. No workspace
   field points a node at an analysis. The same module in another dump gets the
   same code; changed bytes get no badge.
3. **The badge is a role badge, not a verdict.** `ellipsis.curlybraces`
   on the image node, after its name, means *a usable analysis exists for
   these bytes*, not "these bytes are code".
4. **For an analyzed image, `Open Body` is replaced by `Open with Code`.**
   The panel holds the same bytes plus the code, so two menu items would be two
   routes to one act. `Open Body` stays for an unanalyzed image.
5. **The panel is the part plus a code pane.** It reuses the existing
   read-only part/hex machinery; the code pane is added inside that surface. It
   is not a second hex implementation and not a separate document type.
6. **The panel is a snapshot reader.** It never edits bytes and never runs
   Ghidra. It says when its analysis no longer matches the module.
7. **Ghidra stays outside the app.** The skill and the agent write the CAS;
   the app reads it. Without an analysis there is no badge and no
   `Open with Code`.

## What a module is

`UEFINode` already carries the facts this needs: `kind`, `subtype`, `body`,
`space`, and `header`/`body`/`tail` ranges. No name matching:

| Node | Is it an image node? |
| --- | --- |
| `section`, subtype `0x10` (PE32), body begins `MZ` | yes |
| `section`, subtype `0x12` (TE), body begins `VZ` | yes |
| `file` (usually RAW or FREEFORM), body begins `MZ`/`VZ` | yes — the skill's fallback for a body that did not read as sections |
| compressed section | no; it is a container. Its decoded children are image nodes when the branch is materialized |
| any other section or file | no |

The candidate rule is deliberately structural. `node.name.contains("PE32")` is
not a predicate; section names are display text. The parser's `subtype` is the
type byte.

**The blob is `node.body`, not `node.range`.** The section header is not part of
the image Ghidra analyzed. The blob must be the same bytes
`Skills/ghidra-uefi/scripts/module_scan.py` extracts — the section body, or the
raw file body — and that `te_to_pe.py` converts: no trimming and no
normalisation. If the app hashes a different range, no badge will ever appear.

The key is:

```
AnalysisKey(module: SHA256(node.body), recipe: "code-vN-ghidra-X.Y.Z")
```

`AnalysisManifest.module.sha256`, `module.size`, `recipe.id`, and
`ContentStore` already spell this shape. A candidate whose `body.count` differs
from every analyzed module's `size` cannot match, so the index can reject it
before hashing.

**Compressed images.** A TE/PE32 image inside an LZMA or Tiano buffer has a
`space` other than `.file`. Its body is read through the same
`spaceReaders` the tree uses. The badge appears when the branch is materialized;
the panel can show the module's bytes even though no file offset addresses
them.

**Same bytes, several places.** Two occurrences of one module share an
analysis; the badge may appear on both. The panel's provenance says which node
it was opened from, and the manifest's `source` says where the analysis was
originally made. Do not rewrite the second as the first.

**Edits.** The index hashes the bytes as they are now, unsaved edits included.
A changed module loses its badge when the index refreshes. A byte changed
outside the module leaves the module's hash alone.

## The badge

`ellipsis.curlybraces` is a role badge in `Design/ROW_MARKS.md`, drawn after
the node's name rather than in the leading badge slots:

- tint `secondaryLabelColor`, like the other role badges;
- tooltip: "A code analysis is stored for this module; Open with Code opens it";
- only on the image node, never rolled up to the FFS file or the volume;
- the badge is present only when the manifest is readable **and** its artifact
  object exists. A manifest whose object is missing is a `verify` problem, not a
  dead menu item.

The Name column has two role-badge slots. A PE32/TE image node does not
normally wear two others — the compression badge belongs to the container, not
to the image inside it — so the code badge takes the first free slot. If a
future node wears two other role badges, the menu still offers `Open with Code`;
the badge budget is not widened in this plan.

The badge is not clickable. The gesture stays the row's: a double click. A
later filter ("only modules with code") can use the same index; it is not part
of this plan.

`Design/ROW_MARKS.md` gains the symbol and its legend entry; the UEFI legend
draws the same words as the tooltip, as every mark does.

## Open with Code

The action replaces the body-opening item on an analyzed image:

| Node | Analysis | Menu |
| --- | --- | --- |
| TE/PE32 image | usable | **Open with Code**; no body item |
| TE/PE32 image | none | `Open Body` / `Open Decompressed Body`, as now |
| raw file whose body is the image | usable | **Open with Code** |
| raw file whose body is the image | none | body item, as now |
| compressed section (container) | — | `Open Decompressed Body` stays |
| image inside a decompressed buffer | usable | **Open with Code** |

The whole-node item — `Open “CpuPei”` / `Open Decompressed “CpuPei”`, header
and body — stays. It opens a different range from the module body and is how a
reader inspects the section header. `Save Body…` / `Save Decompressed Body…`
stays too: saving the module is how it reaches an external Ghidra run.

`Open Decompressed Body` on a compressed **section** is not replaced. That
buffer may hold several modules, a volume, or something else; it is not one
image, and guessing that it contains one would make the command lie.

**Double click takes the same decision.** On an analyzed image it opens the
Code panel; elsewhere it keeps `UEFIPresenter.content(of:)`. The action and the
gesture must not diverge.

**The decision is pure and testable.** `UEFIPresenter` (or a small adjacent
type) gains something like:

```swift
enum OpenChoice: Equatable, Sendable {
    case code
    case decompressedBody
    case body
    case node
}

static func openChoice(for node: UEFINode, hasCode: Bool) -> OpenChoice
static func offersBodyOpen(for node: UEFINode, hasCode: Bool) -> Bool
```

`hasCode` is the presence of a usable analysis for this node's module, supplied
by the index. `UEFIToolModule` uses `openChoice` for the double click and
`offersBodyOpen` when it builds the menu's two body items.

**Do not hide the body from `nodeSaveTitle`.** Today `nodeSaveTitle` guards on
`nodeOpenTitle(..., body: true) != nil`. Hiding the body in `nodeOpenTitle`
would silently remove `Save Body…` as well. The menu decision belongs in the
menu builder, not in the title helper.

The label is `Open with Code` (`L("Open with Code")`): English, Russian
«Открыть с кодом», German «Mit Code öffnen». The node's name is not part of the
key. The help page names the item in bold, so `help_names.py` must find the
translated menu name in each language.

## The panel

`Open with Code` opens a **fragment panel over the parent**, as every part does
(`Design/FRAGMENT_PANELS_PLAN.md`): the dump stays visible above, the panel
folds into a pill in the dock, and its header is the part's header.

The part is the module body, read-only:

- `DocumentOrigin.source` is the node's body (or the outermost compressed
  section, for an image in a decompressed buffer);
- `layout` is `.image` (or the existing decompressed layout);
- the codec is a read-only codec: `Update in Parent` is refused with a sentence
  saying an analysis is a snapshot, and edits belong in the dump.

The panel's content is two `ALSplitView`s: a function list down the left, and
the code with the hex view under it on the right.

```
┌ Code — CpuPei · TE ──────────────────────────────── ASM │ C ─ ? ┐
│ Functions      │ CpuPei (code-v2 · Ghidra 12.1.2)              │
│ FUN_000004bf   │ 0x68  55 8B EC   PUSH EBP                     │
│ FUN_000005e8   │ ...                                           │
│ ...            ├───────────────────────────────────────────────┤
│                │                       [code-v2 ▾]        [fold] │
├────────────────┴───────────────────────────────────────────────┤
│ 00000000  VZ 00 00 ...                                          │
│ 00000010  00 00 00 ...                                          │
├──────────────────────────────────────────────────────────────────┤
│ module 0x5C00 in the file · analyzed 2026-10-25 · recipe ...      │
└──────────────────────────────────────────────────────────────────┘
```

A code panel torn off into a tab is still a Code screen, and its title bar
belongs to the whole screen: the pane's header is hoisted above the function
list and the code, not left over the hex view. The pane's own close button is
hidden in that header — the window's close button closes the tab — and comes
back if the tab becomes an ordinary document again.

The left pane is the whole function list, not a dropdown: the reader sees every
function at once. The right pane splits vertically: code above, the hex view
below as a reference for the bytes an instruction points at. The code is drawn
on the ordinary text background; the hex view is not the subject of the screen.
`ASM` and `C` are the names of formats and are not translated.

A thin bar — the **dump bar** — sits at the bottom of the code pane, between
the code and the hex view. At its right are the analysis dropdown and
`inset.filled.bottomthird.rectangle`; the `ASM`/`C` switch stays in the header's
top-right corner, where it has room. While the bytes are showing the fold
button is in its selected state, and a click folds the hex view to nothing and
brings it back. The bar belongs to the code pane, so it stays visible when the
dump is folded and cannot be dragged out of sight: the split's divider only
moves the dump. A drag of that divider updates the button — any remaining
height is open, none is closed — and a closed button opens the dump again. The
move runs on `ALSplitView`'s trailing-pane animation, so the code grows and the
bytes shrink as one motion.

**The hex view is the existing part view, not a new hex view.** The panel gets
its bytes from the same `PaneViewModel`/hex view every part has; the code pane
is the additional view. If a future change rebuilds a hex view inside the panel,
the reason for replacing `Open Body` disappears and the duplication is back.

**The code pane is not a `ToolModule`.** A tool-module owns the left strip and
its rows; this screen needs the content width and its own function list. It is a
new shared view package (`Packages/CodeView`), drawn by the app's fragment
surface. It is a reader: no tool strip, no minimap, and the Tools menu and its
toolbar popup are disabled while it is in front — the function list is the
screen's structure.

**`Code` is the panel's badge.** The panel header and its pill in the dock wear
a `Code` capsule with the code glyph (`ellipsis.curlybraces`), not the codec's
`Read-only` capsule: Code is what the panel is, not a transform its bytes went
through. The read-only codec still refuses Update in Parent and its sentence is
still the codec's; the badge says which reader the reader is in.

The code pane has:

- the whole function list, with the selected function's code beside it;
- a four-way navigator — Functions, Strings, POST writes, Status codes — and a
  search field that narrows the list in front; a function also matches the text
  of its instructions, so `MOV` finds the functions that contain one;
- the selected function's callers and callees as short menus, each target one
  click away;
- a disassembly listing: address, instruction bytes, mnemonic and operands;
- an `ASM`/`C` switch for the selected function's decompiled text;
- strings, POST writes and `ReportStatusCode` candidates as selectable lists;
- search across the listing, symbols and strings.

The listing is the ground truth; C is a derived view and says so. The panel
shows `status_code_calls` as candidates, not as confirmed calls.

**A panel keeps its screen in any container.** The dock, a tab of its own and a
tab in another window are all containers for the same `PanelContent`: the pane,
its marks, and whether the screen is bytes or code. Tearing a code panel off
into a tab — moving or copying it — rebuilds the code screen there, not a plain
hex part, and opens it on the function, instruction and `ASM`/`C` side the
reader had chosen. The pane, its edits and its link to the parent still travel
as before. A code screen also refuses a tool-module at the controller, not only
in the menu, so an agent or a restored workspace cannot put one there.

**The workspace remembers the screen.** `FragmentState.code` and `TabState.code`
are optional and carry the analysis manifest as text plus the function,
instruction and `ASM`/`C` side. The session and a project both go through the
same workspace value, so both bring a Code panel back as Code. The panel is
opened as Code on its first route through the dock — not turned into one after
it is up — so it is measured and animated by the same panel mechanics as every
other panel. The artifact is read from the store the manifest names; if it is
gone, the part opens as the bytes it holds rather than not at all.

### Selection and addresses

- The ASM listing's first column is the instruction's **offset in the module
  bytes**, the same number the hex view's Offset column shows. Ghidra's virtual
  address is what the code and its branch operands use, but it is not the row
  address: `0x220` in Ghidra can be `0x68` in the dump, and a reader looking for
  those bytes needs the latter.
- Selecting a function marks its whole stored range as the dump's **main zone**
  (the focused zone), not as a selection: the reader keeps the selection for
  reading bytes.
- Selecting an instruction selects its `bytes` range in the part's hex.
- Selecting bytes in the hex shows the containing instruction and function.
- Following a reference goes to its target address when it is inside the
  module; an external target says so and goes nowhere.
- The hex view shows the part's own bytes, so its Offset column is the module
  offset from 0. Where the module lies in the parent file, the header says the
  file offset of module offset 0; a module inside a decompressed buffer has no
  file address and says that instead.

The address map comes from the **original** module's TE/PE headers, not the PE
rebuilt for Ghidra. `te_to_pe.py` may move section data when it expands the
header; the virtual addresses stay, the original raw pointers do not. Parse the
original section table (or the header's `SizeOfHeaders` for code in the
headers) in `CodeAnalysis` and map:

```
rva = address - imageBase
fileOffset = rva < sizeOfHeaders ? rva
                                : section.rawOffset + (rva - section.virtualAddress)
```

The artifact's instruction `bytes` are the check: for every instruction in a
fixture analysis, the bytes at the mapped file offset must equal the artifact's
`bytes`. If they do not, the mapping is wrong and the sync degrades to
"instruction bytes only"; it must never guess.

### Provenance and staleness

The header shows:

- module name and kind (TE / PE32);
- recipe and Ghidra version (`code-v2-ghidra-12.1.2`); the dropdown for the
  module's other readable analyses lives in the dump bar, not the header;
- when it was analyzed;
- the module's short SHA-256;
- the manifest's source document and node, when known.

If the module's current hash differs from the analysis key, the panel says
**"The module changed after this analysis"** and does not pretend the code is
current. It offers no in-app re-analysis; re-running Ghidra is the skill's job.
If the parent is edited while the panel is open, the panel's bytes are the
snapshot it opened, not the live parent; the same sentence explains that.

### Several recipes

A module may have more than one analysis — a newer Ghidra, a different exporter.
The badge means at least one usable analysis. `Open with Code` takes the newest
readable recipe. When at least one readable recipe exists, the header lists the
others; an unreadable one is marked as such and never guessed at. A recipe whose
artifact object is missing or whose schema is unknown does not count as usable.

### Empty and broken states

- No usable analysis: no badge, no `Open with Code`; `Open Body` remains.
- Manifest readable, object missing or corrupt: no badge; `verify` reports it.
- If a panel is already open and a later reload finds its artifact unreadable,
  the panel says so; it does not switch to another recipe silently.
- A code pane opened from a store that has since gone: the snapshot already on
  screen stays readable; reopening asks the store again and says it cannot.

## The read model

`Packages/CodeAnalysis` already has the CAS and the manifest model, but only
counts the artifact. The panel needs a typed `CodeArtifact`:

```swift
struct CodeArtifact: Codable, Sendable {
    var scriptVersion: Int
    var ghidra: String
    var program: Program          // name, language, imageBase, sha256
    var blocks: [Block]           // name, start, end, executable, initialized
    var strings: [StringEntry]
    var functions: [Function]     // entry, name, size, signature, callers,
                                  // callees, c, instructions
    var postCodes: [PostCode]
    var statusCodeCalls: [StatusCodeCall]
}
```

Addresses and instruction bytes stay as the artifact spells them, but are
validated and parsed into numbers at the boundary. Unknown JSON fields are
ignored; an unknown `script_version` or schema is refused. The C text is
rendered as text, never as HTML or a web view; the artifact is untrusted input
even when its hash is sound.

The artifact's `script_version` is the exporter's version, separate from the
manifest `schema`. The current skill writes `script_version: 2`; the panel must
read 2. An added optional field the reader can ignore needs no new version;
anything the reader must understand is a new `script_version`, and old
artifacts stay readable.

`CodeAnalysis` also gains:

- `ModuleLayout` — parse the original TE/PE headers, answer `rva → fileOffset`
  and the section a range belongs to;
- `ContentStore.analysis(module:preferredRecipe:)` and
  `usableAnalyses(ofModule:)`;
- a `CodeAnalysisIndex` (actor or `@MainActor` service) that maps module
  digests to the manifests the panel may open. The index is not a new source of
  truth; it is a cache over the store.

The index never hashes on the main actor. It reads the manifests' module sizes,
skips candidates whose body lengths cannot match, and hashes the rest off the
main actor. With an empty store it does no hashing at all. It refreshes on the
tree's edit generation and when the store changes.

## Where the decisions live

| Place | What it owns |
| --- | --- |
| `Packages/CodeAnalysis` | `CodeArtifact`, `ModuleLayout`, lookup, readable recipes, artifact validation, the index over the store |
| `Modules/UEFITool` (pure) | candidate predicate, badge presence input, `OpenChoice`, menu titles; no AppKit, no file IO |
| `Modules/UEFIToolUI` | badge wiring, menu item, double-click, asking the host to open the Code part |
| `Packages/CodeView` (new) | the code pane: functions, listing, C, selection, search, stale banner; takes a `CodeArtifact`, does not read the store |
| `ByteRipperApp` | the store service and its path, the fragment surface hosting bytes + code, the read-only codec, the help `?` wiring |
| `Packages/HelpBook` / `HelpUI` | the page and glossary entries; `?` on the panel header |

`Packages/CodeView` is listed in `project.yml` and `xcodegen generate` runs when
it appears, like every package.

The host gains one opening on the seam, rather than `UEFIToolUI` reaching into
the app: `ToolHost.openCode(named:linkedTo:manifest:artifact:codec:)`. The app
turns it into a fragment with a read-only codec and a code pane; the
tool-module says *what* to open, the app decides *where*. `ToolModuleKit`
imports `CodeAnalysis` for the manifest and artifact values, as it already
imports the packages a panel hands it; both are pure. This is the same split as
`ToolHost.openPart`.

A tool-module must not depend on the app, and the Code pane must not depend on
`UEFITool`: the pane reads a `CodeArtifact`, so a later reader (another tool,
an agent, a CAS browser) can use it without the UEFI tree.

## Help and localization

- A new help topic, `code-panel`, with the badge, the action, the panel,
  read-only bytes, provenance, recipe choice, and what is uncertain about
  Ghidra's output. Link it from the UEFI tool page and from the panel's `?`.
- `// help: panel.uefi.open-with-code` at the menu/double-click site;
  `@covers panel.uefi.open-with-code` in the page. The panel's own `?` names
  `topic:code-panel`; the code pane's strings are resources, not Swift.
- `Design/ROW_MARKS.md` gains the badge and its legend words. The legend and the
  row's tooltip use the same sentence.
- English, Russian and German in the same change. Keep the trade's words:
  «разбор кода», «дизассемблер», «декомпиляция»; do not invent a national name
  for `Ghidra`, `TE`, `PE32`, `ReportStatusCode`.
- Run `python3 Skills/help-coverage/scripts/help_coverage.py` and
  `python3 Skills/help-names/scripts/help_names.py`. Bless a page only after
  its translations are actually in line.

## Stages

Each stage builds, tests and is committable on its own.

1. **The read model.** `CodeArtifact` and `ModuleLayout` in `CodeAnalysis`, with
   tests over the existing artifact fixtures; a v2 artifact decodes, an unknown
   version is refused, and the mapped bytes match the artifact's instruction
   bytes.
2. **The association.** The candidate predicate in `UEFITool`, the index over
   the store, the badge and its legend, and the background scan with the size
   prefilter. Tests: PE32/TE/raw-file candidates, compressed-space reads,
   changed bytes, empty store, missing object.
3. **Open with Code.** `OpenChoice`, the menu replacement and the double click;
   `ToolHost`'s code opening; the app's fragment with the module bytes and a
   placeholder code pane. Tests: the matrix, no body item for an analyzed image,
   `Save Body…` still present, the read-only origin, the compressed case.
4. **The code pane.** `Packages/CodeView` with the function navigator, the
   listing, C, selection sync and the stale banner. Tests over a real artifact
   (`CpuPei`: 13 functions, 508 instructions, the status candidate at `0x535`)
   and over malformed artifacts.
5. **The rest of the reader.** In four parts, each shippable on its own:
   - **5a, the navigator:** Strings, POST writes and Status codes beside
     Functions, the search field over the list in front, and callers/callees as
     menus that lead to their functions. Done.
   - **5b, recipes:** the other readable analyses of the same module in the
     header; choosing one loads its artifact without guessing at another. Done.
   - **5c, the agent:** `code_query` reads the same typed model — functions,
     instructions, strings, references — and gives Ghidra's address beside the
     module offset. Done.
   - **5d, projects:** a project writes its Code analyses into an
     `Analyses.bundle` beside `Project.json` and keeps a store reference to the
     same keys, so a moved project comes back with its code and viewing alone
     creates no reference. Done.

## Verification

- `swift test` in `Packages/CodeAnalysis` and `Packages/CodeView`;
  `swift test` in `Modules/UEFITool` for the pure decisions.
- The app's flow tests: open a dump, expand to a PE32/TE image, see the badge,
  double-click it, get one Code fragment with bytes and code; the context menu
  has no body item for that image, keeps `Save Body…`, and still offers
  `Open Decompressed Body` on the compressed container above it.
- A compressed module: the badge appears after the branch is materialized; the
  panel shows decompressed bytes and no file address; `Update in Parent` is
  absent.
- Edit one byte of the module: after the index refresh the badge and
  `Open with Code` are gone, `Open Body` is back, and an open panel says the
  module changed.
- Cross-language: an analysis written by the Python store imports into the
  Swift store and marks the same module; the module hash equals
  `module_scan.py`'s hash for the same node.
- Help: both checkers, all three languages, and the legend's words.
- Performance: with an empty store no module is hashed; with the CpuPei
  analysis only candidates of its size are hashed; opening the panel does not
  block the main actor.

## Open questions

- Is `Open with Code` the final label, or `Open in Code Panel`?
- Does the whole-node `Open “CpuPei”` stay for an analyzed image, or does the
  Code panel plus `Save Body…` cover every reason to open it?
- Do bookmarks and the find bar belong in the Code panel's hex side, or is the
  panel read-only with no bookmark space? The first version says read-only and
  no bookmarks; the fragment-panel rules may want a different answer.
- What does a project reference protect, and when is it created — when an
  analysis is made, when it is imported, or when the user explicitly keeps it?
- Is there an in-app "Analyze with Ghidra…" entry at all, or does the help page
  send the reader to the skill? If there is one, where does it live?
- Can a Code panel outlive its parent dump and be reopened from the CAS alone,
  or is it always a fragment of an open document? This decides whether a
  CAS-only code browser is a later feature or the same one.
