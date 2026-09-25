# The help: one book, read from the menu and from beside the thing it explains

> What the app has to say about itself, and what the words in the firmware
> panels mean. Written as content files, not as strings in Swift, so it can be
> translated; keyed by stable ids, so a `?` beside a form and a row in the ME
> panel can both point at it.

## Why it is shaped this way

The TODO entry this grew out of (`Design/TODO.md`, "Help for the ME panel")
asked for two things — a glossary of the ME panel's vocabulary and a note
saying where the decode comes from — and made three decisions that still hold:

- **Not an Apple Help book.** It is a build step and a bundle nobody maintains
  by hand.
- **Markdown-ish files, shipped in the repository.** Diffable, reviewable, and
  cheap.
- **One entry per term, keyed by a stable id** rather than one long page,
  "so that a term can also be reached from the panel itself later". That is
  what the `?` beside a panel's detail list now does.

Two things were added to that brief. The help covers the *whole app*, not only
the ME panel — a bench meets the comparison, the colours and the editing rules
before it ever opens a firmware panel. And everything a reader sees is a
resource, because the app is likely to be translated (the user is in Germany
and the first readers are not all English speakers).

## The two packages

**`Packages/HelpBook`** — pure Swift, no AppKit. The model (`HelpTopic`,
`HelpTerm`, `HelpBlock`), the markup parser, the loader, and the content
itself under `Sources/HelpBook/Resources/Help/<language>/`.

**`Packages/HelpUI`** — AppKit. The window, the `?` button, the per-term
popover, and the renderer that turns blocks into attributed text.

The split is what lets the book's own tests walk every link in the content
without a window server, and it is why `ToolModuleKit` can carry a
`HelpTopicID` on the module seam while only the drawing half links `HelpUI`.

## Structure is code, words are resources

`HelpContents.sections` lists the pages and their order, in Swift.
`HelpTopicID` and `HelpTermID` name them. Everything a reader *reads* — a page,
a glossary entry, a section's name — is a file.

So a translator can never drop a page the app links to or reorder the contents
into something the code does not expect; and a page the code names but nobody
wrote is a test failure (`HelpContentTests`), not an empty window on a bench.

## The content layout

```
Resources/Help/
  en/
    Sections.md          @section <id> / @name <words>
    Topics/<id>.md       # Title, > summary, then markup
    Terms/general.md     @term / @name / @short / body / @see
    Terms/uefi.md
    Terms/me.md
```

A language is a **directory**, not an `.lproj` bundle, and `.copy` rather than
`.process` keeps the tree as written. Adding German is adding `Help/de` with
the same file names in it: no manifest to edit, no build setting. A file that
language has not translated yet falls back to the English one, file by file
(`HelpLoader.read`), so a half-translated book is readable rather than blank.

## The markup

Six rules, because every one of them is a rule a translator has to keep:

- `## text` — a sub-heading
- `- text` — a bullet; `1. text` — a step (the number is thrown away; the view
  numbers them, so a step inserted in a translation cannot be misnumbered)
- `! text` — a caution, drawn in the palette's caution colour
- a blank line ends a block
- `**bold**`, `` `code` ``
- `[[topic:id]]` / `[[term:id]]`, either with `|the words to show`

Not `AttributedString(markdown:)`: the book needs `[[term:fpt]]` to come out as
a link a *panel* can act on, and it needs the result to be a value the pure
tests can read.

## Where the help is reachable from

- **Help menu** — ByteRipper Help (⌘?), Getting Started, Bench Rules, the two
  glossaries, and the provenance note. Every item carries a `HelpLink` in its
  `representedObject`; the action is `AppDelegate.showHelp`, on the app rather
  than the responder chain, because help must work with no window open.
- **The landing screen** — the platform's round `?` beside the hint. The one
  screen where a new user arrives with "what is this for".
- **The find bar**, the **Segments** form, the **Go To / Bookmarks** form, the
  **Editing** settings tab.
- **A tool panel's header** — the `?` beside the ✕, opening the page for the
  running tool-module. Named on the seam (`ToolModule.helpTopic`), so the app
  draws it and the module only says which page.
- **A firmware panel's detail list** — the `?` in its top corner, opening a
  popover for the *row in focus*. The ME panel's terms are set by the curator
  (`MEANode.helpTerm`); the UEFI panel's come from the node's kind
  (`UEFIHelpTerms`).

## Three AppKit traps, all measured

The `?` on `ToolDetailScroll` hit all three, in order, and the comments beside
it say so. Each one *drew something*, which is why none of them announced
itself:

1. A **plain subview of an `NSScrollView` is never laid out** — a scroll view
   positions its own subviews and solves no constraints for one of them. The
   button sat at zero size in a corner nobody asked for.
2. `addFloatingSubview(_:for:)` is the documented API for a control over
   scrolling content, and the host it lands in is **flipped** — a clip view
   takes its flippedness from its document, and this document is flipped so the
   rows start at the top. Computing "the top corner" from `bounds.height` put
   the button at the bottom, while a test reading the unflipped scroll view's
   own coordinates insisted it was at the top.
3. A floating subview is **not in the view's own `subviews` and not in the
   accessibility tree**. It was drawn correctly and a walk of the running
   window found no such button while it was on screen — so VoiceOver could not
   reach it, and neither could a test that looked for it.

So it is an ordinary subview of the **document**, laid out by constraints,
level with the node's name it explains. It scrolls with the rows, which costs
nothing: a reader scrolled past the name is no longer looking at the thing the
button is about.

Two habits came out of this, and both are worth keeping:

- **Measure in the window's space.** `termButtonFrameInWindow` exists because
  neither the scroll view's coordinates nor the document's answer "where does
  the reader see it".
- **Test that a control can be *reached*, not only that it exists.**
  `testTheButtonIsReachable` walks the window's view tree, hit-tests the
  button's centre, and asks for its accessibility label. Traps 1 and 3 both
  pass a test that only asks whether the button is there.

## Adding to the book

- **A page**: add its `HelpTopicID`, put it in `HelpContents.sections`, write
  `Topics/<id>.md`. The tests then require it in every shipped language.
- **A term**: add a `@term` block to the right `Terms/<group>.md`. Point at it
  from a node (`MEANode.helpTerm`, `UEFIHelpTerms.term(for:)`) or from prose.
- **A language**: copy `Help/en` to `Help/<code>` and translate. Nothing else.
- **A `?`**: `HelpButton.standard(for:)` in a form or a dialog,
  `HelpButton.inline(for:)` in a panel's chrome.

## What is deliberately not done

- **No minimap `?`.** The panel is 120–240 points wide and its header and
  status bar are both fully claimed; a button there would squeeze the mode
  switch. The page is reached from the contents and from links.
- **No `?` on the other settings tabs.** Only Editing has a switch with
  consequences on a bench — it turns off the dialogs that stand between a flash
  dump and a length-changing edit.
- **No search ranking.** The book is forty pages; a substring match over title,
  summary and body is the whole of it.
