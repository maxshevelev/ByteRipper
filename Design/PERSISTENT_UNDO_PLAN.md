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

So each document gets a **journal**, `History/<id>.log`, and the operations'
bytes live there. RAM holds the history's skeleton — serials, ranges,
selections, labels, series ids, and where each op's bytes sit in the journal.
Undo and redo read the bytes they need from the journal.

- With a workspace or project, the journal is inside it.
- Without one (the restore switch off), the journal is a temporary file of the
  session, deleted when the document closes. One code path either way.

### Records

Append-only. A record once written is never rewritten.

| record | carries |
|---|---|
| `T` | a transaction: serial, ops (with their bytes), selection before and after, series id, label key, the segment snapshot paired with it |
| `S` | a refined selection after the last transaction (`noteSelectionAfterOnLast`) |
| `F` | a fold: older steps were folded into a new base (below) |

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
written whole. Today `UntitledKeeper.stamp(for:)` reads a whole untitled
document on the main thread and rewrites `Untitled/<id>.bin` at every change of
`version`; `editsStamp(for:)` re-encodes the file's `OverlayEdits` whole. A
32 MB joined image being typed into writes 32 MB every 2 s.

With the journal holding every change, the content is not written again:

- **Base** — the state before the oldest step kept. For a file on disk: the
  file (by its hash) plus `OverlayEdits` at the fold. For an untitled document
  or a part: a snapshot of its bytes in `Untitled/`.
- **The base is rewritten only at a fold:** when a bound drops the oldest
  steps, they are folded into a new base, an `F` is written, and the journal is
  compacted without its dead records. Amortized, as `EditOverlayStorage`
  materializes a fresh base once per many edits.
- **At open:** the base is checked by its hash, the journal by its chain, and
  the transactions are applied up to `head`.
- `UntitledKeeper` as it is today — whole bytes by `version` — goes away.

Writing moves off the main thread: the timer only collects the new records,
which are values already; a background queue appends and syncs.

## Integrity

- **The file a project points to.** Size and date stay the quick first look;
  SHA-256 (CryptoKit) decides. Only a file something is laid over needs one —
  unsaved changes or history; a clean file keeps the stamp for caret, segments
  and tool state.
  - Computed once per version of the base: when the document first becomes
    dirty (its stamp still unchanged), and at Save, from the bytes being
    written.
  - At open, checked in the background before anything is laid over; a file of
    gigabytes shows progress in the restore.
  - A file whose date moved but whose hash matches (copied, touched) keeps its
    changes and history. Today it loses them.
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

A step's name ("Add Microcode") is stored as its `L()` key and arguments, not
as the translated string, so the menu speaks the current language after a
relaunch.

## Phases

1. **Journal as the store** — skeleton in RAM, bytes in the journal, a
   temporary journal without a workspace; the bounds and their settings.
   Fixes today's RAM cost of large edits on its own. *(done)* An edit group
   writes its ops into the journal as it collects them, so a join or a
   streamed replace does not hold its bytes until it closes either. A journal
   that cannot be made or written leaves the bytes in memory: the edit stays
   undoable. Still in memory while an edit runs: a fill builds its before and
   after whole before recording them.
2. **Content from base + journal** — folds, compaction; `UntitledKeeper` and
   whole-file `Edits/` rewriting replaced; the manifest's journal length and
   chained hash.
3. **Integrity** — SHA-256 of the base file, the background check at open,
   hashes of the project's own files, the restore warning's new lines.
4. **History restored** — `head`, `savedSerial`, redo grouping, join marks;
   undo and redo after a relaunch, for files, untitled documents and parts.
5. **Segments** — the paired snapshot stack, source ids re-minted at restore.
6. **Help** — `workspace.md` and the editing page in en, ru, de;
   `WORKSPACE_PLAN.md` "Not kept" updated.
