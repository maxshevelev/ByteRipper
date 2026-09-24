# Segment source links — a piece that remembers the file it came from

> The mechanism this stands on is `SEGMENTS_PLAN.md` (a dump as the pieces it is
> made of) and `JOIN_SPLIT_PLAN.md` (how a *file* becomes a piece). This document
> is the missing half of the join: the piece knows which file it came from, so
> the image built out of two chips can still show what has been patched in each
> half, and put either half back.

## Why

Join two chip dumps and the result is an untitled image: no file behind it, and
therefore — until now — **no red bytes at all**. `marksModifiedBytes` was false,
so a patch applied to the joined image looked exactly like the bytes around it.
That is the one workflow the join exists for, and it was the one workflow with no
modified-byte marking.

The fix is not to invent a baseline for the whole image. The image never existed
on disk and never will until it is saved. But every *piece* of it did: `chip1.bin`
and `chip2.bin` are sitting right there. A piece measured against its own source
is exactly as meaningful as a file measured against itself — and it is the same
question, asked one level down.

## The model

**A piece carries an optional link.** `Piece.link` is a `SegmentLink`: a
`SegmentSourceID` and the `sourceRange` — the stretch of that file the piece
stands for.

The id, not the file. The partition is a value: undo copies it, `Equatable`
compares it, and a snapshot of it has to stay valid across an undo that took the
file away. A URL in it would be an identity smuggled into a value; an open reader
in it would be a resource smuggled into a snapshot. So the partition names
sources by id, and `SegmentSources` — one per pane, outliving every snapshot —
says what each id is. An undone-and-redone join finds its sources still there.

**`sourceRange` is an extent, not a length.** It is not always the piece's own
length, and that difference is the point: an insert inside the piece leaves the
piece longer than the stretch it came from, a delete leaves it shorter, and a
source rewritten on disk changes it from the other side. Revert Segment asks
about exactly that difference before it moves anything.

### Links follow the content, like cuts do

Every operation on the partition carries the links with it, and the arithmetic is
forced by one invariant: **the piece's byte at `offset` stands for the source's
byte at `offset − piece.start + link.sourceRange.lowerBound`.**

| operation | what happens to the link |
|---|---|
| **Add cut** | splits with the piece: both halves keep the source, at the offsets they sit at in it. The document bytes the earlier half keeps are clamped to the extent the link covers. |
| **Remove cut / merge** | the absorbing piece keeps its own link and grows its extent by what it absorbed; the absorbed piece's link goes with its name. Merging S0 shifts the survivor's extent back by S0's length — which is exactly right when both came from one file, and drops the link when the source has no room for it. |
| **Move cut** | the piece that opens at the cut gains or loses bytes at its front, so its extent slides by the same amount; the piece before it gains or loses at its tail, so its extent's far end moves. A slide that would take a front below the source's start drops the link rather than let it lie. |
| **Insert** | pieces after it shift whole, extents untouched. The piece *containing* the insert keeps its link: the inserted bytes have no source, and everything after them in the piece is off by the insert's length, so both read as modified — which is precisely what an insert already does to a plain file (`shiftedFrom`, §6). Nothing special is needed and nothing is dropped. |
| **Delete** | a run that keeps its head keeps its extent (the bytes pulled up behind it are simply not the source's, and read modified). A run that lost its head opens that much further into its source. |
| **Rebase (revert to saved)** | pieces dropped past the new end lose their links with themselves; survivors keep theirs. |
| **Reset (open / close / merge all)** | no links. A fresh file is one piece of itself. |

**A link is never dropped to be safe.** Misalignment paints red, which is true —
those bytes are not the source's bytes at that place. A dropped link would throw
away a working Revert Segment to avoid a red byte that is correct.

### Where links come from

- **Join.** The donor's piece links to the donor file at offset 0. *And* — this
  is the half that is easy to miss — the content the pane already held is linked
  to the file the join is about to take away from it (§22.2), each piece at its
  own offsets. Done before the insert, while those offsets are still the file's,
  and after the undo snapshot, so undoing the join (which gives the file back)
  takes the links with it.
  - This also makes the join **continuous**: before it, a patched byte was red
    against the pane's file; after it, the same byte is red against the same
    file, now as the piece's source. Nothing flickers.
  - Pieces that already carry a link (an earlier join's) keep the one they have.
- **Replace Segment from File…** links the piece to the donor.
- **Nothing else.** A manual split of a file that came from nowhere is a piece
  with no link, and that is most pieces. Opening a file does *not* link its one
  piece to itself: while the document has a file, the document's own attachment
  already answers "modified against what?", and a link would only have to be
  re-based on every Save As.

## What red means, and what it does not

**Decision: a link supplies the baseline only while the document has no file of
its own.**

`ModifiedBaseline` is one value the hex view and the minimap both read, and
everything in it is a *span*: a stretch of the document, a reader, and the source
offset it opens at.

- **Attached document** — one span over the whole saved file, and `beyondFrom`
  at its end. Exactly what the app did before; red still means "not saved yet",
  which is the CLAUDE.md rule and stays true.
- **Untitled document with links** — one span per linked piece. Red means
  "differs from the file this stretch came from", and bytes no span covers are
  unmarked, the way an untitled document's bytes always were.
- **Untitled document with an origin** (a part opened from a parent, §6) — the
  span is the bytes it was opened with, unchanged. When such a tab is *also*
  joined to, the origin answers the stretches no piece came from, so the join
  does not blank the marks on the part the tab started as.
- **A piece longer than what it came from** — the span covers the whole piece
  but stops answering at the source's extent, so bytes an insert added inside it
  read as new, exactly as a file that outgrew its saved copy does.
- **Untitled document with neither** — nothing is marked.

Saving the joined image therefore hands the baseline back to the saved file: red
goes back to meaning "not saved yet", and the links stay for Revert Segment, for
the row's mark in the form, and for watching the sources. The alternative — the
link always winning — would have left bytes red after a successful ⌘S, and the
only per-byte signal for "unsaved" would have been gone.

## Revert Segment to «file»

The inverse of the join, one piece at a time. It lives wherever the other
per-piece commands do: the Segments form's row menu, the strip's menu beside the
map, and the dump's own offset context menu. It is **present only for a piece
that has a source**, and named for it — `Revert Segment S1 to “chip2.bin”` — so
the menu says what it will do without a second look.

- Same length → it just runs. One undo step, streamed in 1 MiB chunks.
- Different length → **it asks**, naming both lengths and saying that every
  segment after this one moves by the difference. Agreeing restores the source's
  length: the stretch both sides have is written in place, and the difference is
  added or removed at the piece's tail.
  - The boundary needs its own rule, and it is not `moveCut`. The ordinary
    `.insert` rule gives bytes added at a cut to the piece that *starts* there
    (§21.2), which is right for an edit made at that offset and wrong for a
    swap: the bytes replaced *this* piece. `Segmentation.applyGrowth(of:by:)`
    says so directly — every piece after it moves whole, links untouched, and
    the grown piece's own extent grows with it. Sliding the cut instead would
    have slid the *next* piece's extent too, quietly breaking its link.
- The link stays, re-based on what was actually restored. The bytes are still
  that file's.
- **Replace Segment from File… asks the same question** instead of refusing a
  mismatch outright, which is what it used to do (§21.6). One rule, two commands.

## The source changed on disk

Each linked file is watched, the way the pane's own file is (§5.5). A change
drops the open reader — the link is to the *file*, not to the bytes it held when
it was linked — and asks:

> **Segment source changed on disk.** “chip2.bin” has been changed by another
> program. Segment S1 came from it, and is now compared against its new
> contents. Reload to take the new bytes into the dump.
> **[Reload Segment] [Keep Current Contents]**

Keeping is not doing nothing, and the alert says so: the marks are already
measured against what is on disk now. Reloading reverts every piece linked to
that source, back to front — a revert can change a piece's length, and the pieces
already done must not move underneath the ones still to do.

Under XCTest the prompt resolves to Keep, like every other blocking prompt.

## No write of the app's lands on a source

One rule, every command that names a file: **Save As**, **Save Segment…** and
**Save All as Separate Files…** A target that is a file some piece came from is
refused, and the panel opens again. Replacing `chip1.bin` with the image built
out of it — or with one piece of that image — would leave a segment linked to its
own result, and the dump the chip was read from gone. There is no "Replace
Anyway": the useful answer is another name, which is what the alert asks for.

- It holds even for a piece written over the very file it came from. "Put my
  patched half back over the chip dump" is a real wish, but it is a Save As on a
  copy, not a write that quietly unmakes the link.
- Save All is all or nothing (§21.5), so one part name landing on a source stops
  the set. The folder is the only thing that command asks for, so the folder is
  what there is to change.
- The untitled join result already routes ⌘S to Save As, and once it has a file
  of its own ⌘S writes that file — which is never a source.

The panel coming back up is a loop rather than a recursion in the two modal
commands, and the panel seam is consulted again each time round: a test that
drives it answers the second question the way a user would.

## The row says it

In the Segments form's **Name** column, a linked piece shows the `link` symbol
and the file's name (and its own name first, when the user gave it one that is
not simply the file's).

When the piece is no longer that file's bytes, the run goes red, wears
`xmark.octagon`, and carries the reason in brackets: `(edited)`, `(length
changed)`, `(file missing)` — the same two symbols and the same red the pane
header's link to a parent uses, so a link that has come apart reads the same
wherever it is shown. The tooltip gives the full path and the whole sentence.

The verdict is computed by comparing in 1 MiB chunks and cached against the
pane's `contentGeneration`, so a form that reloads on every change does not
re-read a megabyte per row.

## Two bugs this found

**`applyDelete` gave every later run piece 0's name.** The `nameIndex` search ran
`(0...j)` instead of `(i...j)` — and piece 0 opens before every deletion, so any
delete before a cut renamed (and, once links existed, re-sourced) every piece
after it. A delete of two bytes at offset 2 in a dump cut at 8 left two pieces
both called `a`.

**`PaneViewModel.join` renamed piece 1 after an append.** It assumed the pane
held a single piece before the join, so appending a file to a dump that had
already been cut landed the source's name on the wrong piece. The joined bytes
are the *last* piece — the cut at the old end splits whichever piece ran to it —
and that is where the name and the link now go.

## Implementation order

1. `SlicedStorage` and `SegmentReplacer`'s length-changing swap (`ByteRipperCore`).
2. `SegmentLink`/`SegmentSourceID` in the partition, and the propagation rules.
3. `SegmentSources` and `ModifiedBaseline`; the hex view and the minimap read it.
4. Links on join (both sides) and on replace.
5. Revert Segment, and the length question it shares with Replace.
6. The source watchers and their prompt; the guard on every write.
7. The form's Name column.
8. Tests: propagation, painting, revert, the join's two sides, the guards.

## Not in this

- **Persistence.** Links are session-only, like the partition itself (§21.1). A
  project file would change that, and is the same TODO it already was.
- **A link to a range of another *open pane*.** That is `DocumentOrigin` (§6),
  which exists and is a different relationship: a part taken *out* of a document,
  with a way back into it.
- **Linking a piece by hand.** Every link is made by an act that genuinely moved
  bytes in from a file. "Link this piece to that file" would be a claim, not a
  record.
