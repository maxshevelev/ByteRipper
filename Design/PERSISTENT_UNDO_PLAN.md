# Persistent undo — the history a workspace and a project keep

> Today the undo history belongs to the session that made it
> (`WORKSPACE_PLAN.md`, "Not kept"). This plan keeps it: a workspace or a
> project opened again undoes and redoes as it did before quitting, for files,
> untitled documents and parts alike.

## Decisions

- **Every document keeps its history** — File A, File B, an untitled
  document, a part (panel or torn off). A part weighs as much as a file.
- **Projects stay on this computer.** They are not handed to someone else, so
  overwritten bytes kept in the history are not a leak and need no "Clear
  History" command.
- **Nothing is laid over a file that is not the file it was made on.** The
  file a project points to is checked by SHA-256, not only by size and date.
- **Writing is incremental.** A snapshot writes what changed since the last
  one, never a whole history or a whole document.
- **The depth is bounded, and the bounds are settings** (below).

## The journal is the history's store, not only its copy

`UndoOperation` holds the bytes before and after an edit as `[UInt8]`, in RAM.
`SegmentReplacer` streams a donor in 1 MiB slices so it is "never loaded whole
into RAM" — and then the history holds every slice twice. A 512 MB replace
costs 1 GB of memory today. With bounds of gigabytes that cannot stay in RAM.

So each document gets a **journal**, `Kept/<uuid>.log`, and the operations'
bytes live there. RAM holds the history's skeleton — serials, ranges,
selections, labels, series ids, and where each op's bytes sit in the journal.
Undo and redo read the bytes they need from the journal.

- With a workspace or project, the journal is inside it — and is its log
  ("One journal", below).
- Without one (the restore switch off), the journal is a temporary file of the
  session, deleted when the document closes. One code path either way.

### Records

Append-only. A record once written is never rewritten.

Three kinds (`HistoryLog`): `BRT1`, a transaction — serial, parent, selection
before and after, series id, label, the ops with their bytes, a fill's as its
pattern; `BRS1`, a selection refined after a transaction already written
(`noteSelectionAfterOnLast`); `BRP1`, the segments paired with a transaction.
There is no fold record: a fold writes a new base and a new log.

Each record carries SHA-256(previous record's hash ‖ its own bytes). Appending
costs what is appended.

### Position lives in the manifest

`Workspace.json` / `Project.json` hold, per document, a few dozen bytes:
`head` (the serial of the current state), `savedSerial`, the redo side's
grouping (a fast undo of a series is one redo gesture), the join marks, and
**the journal's length with the chained hash at that length**.

Undo and redo touch no journal: only `head` moves. A new edit after an undo
cuts the redo tail in the manifest; the dead records stay in the journal until
it is compacted.

The manifest is written after the records it names. A tail written after the
last manifest (a crash between the two) is cut off at open.

## Content = base + journal up to `head`

Writing the history incrementally gains nothing while the content is still
written whole. `UntitledKeeper.stamp(for:)` used to read a whole untitled
document on the main thread and rewrite `Untitled/<id>.bin` at every change
of `version`, and `editsStamp(for:)` re-encoded the file's `OverlayEdits`
whole: a 32 MB joined image being typed into wrote 32 MB every 2 s.

With the journal holding every change, the content is not written again:

- **Every state has a serial of its own**, a reset's and a cleared
  history's included, and every transaction names the state it was applied
  to (`UndoTransaction.parent`). The states form a tree, and the content of
  any state is found from any other by the transactions between them —
  undone up to where the two part, done down from there
  (`HistoryLog.path`).
- **Base** — one state, kept whole. For a file on disk: the file itself, which
  holds the saved state, when the log leads from it; otherwise runs over the
  file (`OverlayEdits`). For an untitled document or a part: its bytes. All
  in `Kept/`, under names a `KeptContent` gives them.
- **The base is written again only when it has to be:** when no transaction
  in the log leads from it to the document's state any more — the history
  was emptied, or its bounds dropped steps before a snapshot wrote them — or
  when the log has grown past 64 MB and twice what the history holds. Then the
  content is written whole, under a new name, with a new log of every
  transaction the history holds. Amortized, as `EditOverlayStorage`
  materializes a fresh base once per many edits. A save needs no new base: the
  file now holds the saved state, and the log leads from it.
- **At open:** the base is checked by its hash, the journal by its chain, and
  the transactions are applied up to `head`.
- `UntitledKeeper` — whole bytes by `version` — is gone; `ContentKeeper`
  keeps every document's content this way.

### One journal

A document's undo journal and its log are one file. While a workspace or a
project is recorded, a new journal is made in its `Kept/`
(`UndoJournal.directoryProvider`, set by the app's recorder); otherwise in
the temporary directory, unlinked. The journal is framed throughout:

| record | written | carries |
|---|---|---|
| `BRB1` | by the history, as the edit is recorded | the edit's bytes |
| `BRT1` | by the snapshot | a transaction, its bytes **named** by where a `BRB1` (or an earlier record) put them; bytes not in this journal are written into the record |
| `BRS1`, `BRP1` | by the snapshot | a refined selection; the segments paired with a step |

So an edit's bytes reach the disk once. One chain of hashes runs through all
of them, under one lock: the history appends on the main thread, the writer on
its queue. The log is pinned as before, by length and hash; bytes appended
after the pin are cut off when the journal is taken up again
(`UndoJournal(continuing:)`), and the restored history goes on writing the
same file.

- The history's compaction is the log's: compacting makes a new journal, and
  the next snapshot starts a new log in it — records for every transaction
  held, naming the bytes the compaction copied — over the same base when the
  new log still leads from it, over a base written afresh when not.
- A journal made elsewhere — before the workspace was recorded, in the
  session before Save as Project, or one whose folder was removed when the
  restore was switched off — is moved into `Kept/`, never on the main thread
  (`UndoHistory.beginJournalMove` / `finishJournalMove`): the main thread
  lists the runs of bytes the history keeps, a background task copies them
  into a new journal, and the main thread switches to it — rewriting where
  the ops point, no I/O — once every run has its copy. Edits are not held
  back meanwhile: they append to the journal being left, and another round
  copies what they added; a journal compacted or emptied under the move
  abandons it, and the next snapshot starts another. While a document's
  journal is moving, snapshots leave it as the last one kept it. A move still
  running after 200 ms shows its progress in a sheet on the document's
  window, so nothing is edited there by hand — what reaches the document
  past the sheet, an agent or a part, is caught up with all the same.
- A journal an open document writes is registered (`UndoJournal.liveNames`);
  tidying `Kept/` leaves it alone until the document lets go of it, whether
  a workspace names it yet or not.

The writing is off the main thread (`KeptWriter`). A snapshot decides on the
main thread, as before, what each document needs — which transactions,
refined selections and segment pairings are new, whether the base must be
written afresh — and hands that over as values: the transactions (their
bytes read from wherever they lie), the segments encoded, and for a base
written whole an O(1) snapshot of the content (`contentSnapshot`). One serial
queue appends, writes the bases, and then writes the workspace file with each
content's base and log as they came out — the lengths and hashes the main
thread cannot know. A snapshot whose writes all went through is written
down, and the kept files it does not name go after it; one that failed is
not, the workspace on disk stays the last whole one, and the document that
failed is started afresh by the next snapshot. A snapshot that may be the last
(`record(final:)`) waits for the queue. Still on the main thread: runs over a
file (`OverlayEdits`) when that base is needed — rare.

At restore the kept content is read back off the main thread too
(`ContentKeeper.readBack`): before the parts, every log is read and checked by
its chained hash and every base by its own, all at once, and a document's
whole content rebuilt; the untitled documents open after that, before any
part, which may come out of one of them. The same sheet as for the files'
check shows how far it has got. Content whose kept history no longer leads
back comes back without it, and the restore warning says so
(`RestoreIssue.historyLost`).

## Integrity

- **The file a project points to.** Size and date stay the quick first look;
  SHA-256 (CryptoKit) decides. Only a file something is laid over needs one —
  unsaved changes or history; a clean file keeps the stamp for caret, segments
  and tool state.
  - Computed once per version of the file (`ContentKeeper.fileHash`, keyed by
    path, size and date): by reading it in the background the first time a
    snapshot keeps content over it — the snapshot goes without, the next one
    has it — and there and then for a snapshot that may be the last
    (`record(final:)`: quitting, leaving or saving a project). A save that
    writes the file whole hashes it from the same slices it writes
    (`StorageSaver.save` returns the digest, `BinaryDocument.savedDigest`
    keeps it with the file's size and date), so it is not read a second
    time. A save that patches the file in place writes only what changed; its
    hash is then the one read of the whole file, in the background.
  - At open, checked in the second pass of the restore, before anything is
    laid over and before any part is taken out of it; all such files at
    once, off the main thread (`WorkspaceRestorer.settleKeptFiles`). From
    256 MB to read on, each window with such a file shows a sheet with the
    check's progress and no Cancel — cancelling could only mean dropping the
    kept work — and nothing in it is edited before the changes are on.
  - A file whose date moved but whose hash matches (copied, touched) keeps its
    changes, and everything measured on it. Other bytes under the same date
    are a changed file. A workspace written without the hash falls back to
    size and date.
- **The project's own files.** The manifest carries each referenced file's
  hash; a base snapshot is written under a new name per version, never over
  the one the manifest names.
- **A mismatch is never applied silently.** The history does not match → the
  content comes back without history (today's behaviour). The base does not
  match → the file opens without changes. The restore warning names which and
  why.

## Bounds — Settings ▸ General ▸ Editing

Two settings, per document, the same in memory and on disk (a history shorter
after a relaunch than before it would be a surprise):

| setting | choices | default |
|---|---|---|
| **Undo history size** | 512 MB, 1 GB, 2 GB, 4 GB, 8 GB, 16 GB | 4 GB |
| **Undo steps** | 1 000, 10 000, 100 000, Unlimited | Unlimited |

- The size counts the ops' bytes in the journal (before and after), not the
  skeleton.
- The steps count transactions; a typed byte is one. 10 000 is effectively
  unlimited in practice; the setting is there for whoever wants it lower.
- Lowering a bound takes effect at the next edit of each document: the oldest
  steps are folded until it fits. Nothing is asked.
- A dropped step that was the saved state only means undo can no longer reach
  it; dirty stays right (serials are compared, not counts).
- A fold drops the paired segment snapshots and the join marks of the steps it
  drops.
- One step larger than the size bound is still kept, alone: the edit must
  remain undoable once.
- Settings: `EditingSettings`, read live; `ControlHelp` words; anchor
  `settings.editing.undo-history`, covered on the editing help page in en, ru,
  de.

## Labels

A step's name ("Fill Zone A") is only what the Edit menu says — "Undo Fill
Zone A" — and is kept as the string it was, in the language it was made in.
Keeping its `L()` key instead would mean changing `ToolTransaction` and every
module that names a write (several pass arguments, some a language of their
own) for one effect: a menu caption in the earlier language after the
language was switched between two launches. The step itself — the bytes —
has no language.

## Phases

1. **Journal as the store** — skeleton in RAM, bytes in the journal, a
   temporary journal without a workspace; the bounds and their settings.
   Fixes today's RAM cost of large edits on its own. *(done)* An edit group
   writes its ops into the journal as it collects them, so a join or a
   streamed replace does not hold its bytes until it closes either. A journal
   that cannot be made or written leaves the bytes in memory: the edit stays
   undoable. A fill is worked in 1 MiB slices, and what it wrote is kept as
   its pattern (`UndoBytes(pattern:count:)`), not as bytes: its history costs
   the bytes it replaced.
2. **Content from base + journal** — folds, compaction; `UntitledKeeper` and
   whole-file `Edits/` rewriting replaced; the manifest's journal length and
   chained hash. *(done)* A log that does not read back as pinned is not laid
   over anything: the restore warning names the document. They were two files
   at first — the session's journal and the workspace's log — and became
   one later ("One journal").
3. **Integrity** — SHA-256 of the base file, the background check at open,
   hashes of the project's own files, the restore warning's new lines.
   *(done)* A kept base (`KeptBase.bytes`, `.edits`) carries its SHA-256,
   made as it is written and checked before it is read; the logs had their
   chained hash from phase 2. The workspace format goes to version 3.
4. **History restored** — `head`, `savedSerial`, redo grouping, join marks;
   undo and redo after a relaunch, for files, untitled documents and parts.
   *(done)* `KeptContent.history` (`KeptHistory`): the undo base, the redo
   tip and the redo steps' sizes — the redo side is the way from the state
   the document is in down to the tip — the saved state, whether the
   document is dirty in any state, and the joins on either side.
   `HistoryLog.sides` finds both sides in the log, `UndoHistory.restore` puts
   them back; the log is the restored history's journal from then on. A refined selection after a transaction
   already written is a `BRS1` record. When the log does not hold the way to
   the undo base, the document comes back with an empty history, as before;
   a redo side that does not add up is left out. The workspace format goes to
   version 4.
5. **Segments** — the paired snapshot stack, source ids re-minted at restore.
   *(done)* A `BRP1` record pairs a transaction with the segments before it
   (undo side) or after it (redo side), as `SegmentationState` JSON with
   links by path; the same segments again are a flag. Written when the log
   has not got that pairing yet, and read back as far from the newest end of
   each side as the log has them all.
6. **Help** — `workspace.md` and the editing page in en, ru, de;
   `WORKSPACE_PLAN.md` "Not kept" updated. *(done)* `workspace.md` and
   `projects.md`; the editing page had its part with phase 1.
