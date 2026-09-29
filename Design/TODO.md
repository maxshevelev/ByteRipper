# TODO — what shipped, and where the rest lives

Everything waiting for its turn is in
[GitHub Issues](https://github.com/maxshevelev/ByteRipper/issues). The buckets
this file used to keep are labels there — `next`, `later`, `someday`,
`tech-debt` — and an entry moves between them freely; a label is a decision
about order, not a promise.

An issue says **what**, **why**, and enough **how** to start: the shape of the
solution, what it touches, and what it would cost. Rough hours, not estimates to
be held to — they are there to tell a half-day from a week. An issue that turns
out to be wrong is closed with a line saying why.

What stays in this file is the record below: what was built, with the commit or
the branch that did it, so the next reader can see where the reasoning ended up.
An issue that gets built is closed, and gets a line here.

---

## Done

- **Fetching each database once a run, and checking it once a day** —
  `Packages/FreshData`, `7e5f8c7`…`8dbf076`. Only ME Analyzer held its database
  between files, and only until the app quit; `guids.csv` (680 KB, plus its
  parse) and the microcode tree listing were fetched again for every file a tool
  was opened on. All three now hold the parsed value in a `Freshened` — one per
  *resource*, since `MEA.dat` and `Huffman.dat` have their own ETags and their
  own clocks — and ask `If-None-Match` once a day, with
  `.reloadIgnoringLocalCacheData` so the `304` actually arrives rather than
  being answered from `URLSession`'s own cache. **The check runs behind the
  reading**: past the first call of a run nobody waits on the network for
  something already in hand, and a value that *replaces* one is announced
  through `changes()`, so ME Analyzer analyses again (dropping the pane's cached
  analysis, read against the same superseded file), the UEFI tree is drawn again
  with the names that arrived, and the FIT table is rated again — "the latest
  there is" being a verdict about one listing. A check that cannot be made
  leaves what is held in place and is not retried for five minutes, so a day
  without a network does not put a connection timeout in front of every file
  opened. It also fixed a memoized failure that outlived the network that caused
  it: the repository stored its `Task` before awaiting it and never cleared it,
  so a tool opened while offline replayed that error for the rest of the run.
  What is *not* done is the disk half — nothing survives a relaunch — and the
  two visible pieces, which are issue #13.
- **Carrying the pattern favourites between machines** —
  `Design/FAVORITES_SYNC_IDEA.md` and `Design/FAVORITES_SYNC_PLAN.md`, eight
  stages on the `favorites-sync` branch. The library became a file in the app's
  container, movable to any folder a sync client watches — iCloud Drive, Google
  Drive, Dropbox — which needs no entitlement of its own. The local file is the
  truth and the folder the medium: the app never draws from a file another
  machine may be writing. **One file per machine** — each Mac writes only its
  own and reads everyone else's — because a file with two writers makes the sync
  provider the judge of who wins, and it was measured deciding silently and
  wrongly. Every publish merges each file three ways against the last state
  agreed with it, with ids, tombstones and a version vector, because a synced
  folder is not a lock and the two machines *will* write inside the window. What
  a rule must not decide — the same entry changed differently on both sides,
  edited here and deleted there, one search under two names — is asked in a
  sheet, on **both** machines, and an answer on one settles the other. Nothing in the folder that is not a
  machine's own file is touched. The whole merge is tested without a
  window or a network.
- **A library of named patterns** — `Design/PATTERN_LIBRARY_IDEA.md`, on the
  `pattern-favorites` branch. The pattern field became an `NSSearchField`
  whose menu carries both lists — **Recent Queries** and **Favorites** — where
  a favourite is a recent with a name and nothing else: one stored shape, one
  row format, one pick. A row states its pattern, its encoding and its case
  rule, because a row that hides one is lying about what picking it does; a
  pick loads all three, searches, and records nothing in the history. **Add to
  Favorites** keeps what the field describes and asks only for a name, and the
  Favorites tab in Settings edits the list — nothing unsearchable is stored, a
  new row is a draft until it has a pattern, and the order is the user's, so
  rows are dragged. Escape now belongs to the field (menu, then clear), so the
  bar closes by Done.
- **Smart Search** — the encoding as a result rather than an instruction: with
  the toggle on (the default), a pattern is looked for as hex when it reads as
  hex and then as text, ASCII through UTF-16 BE, until something is found, and
  the encoding that found it goes into the popup and the history. Where the
  user names one — picked out of the history, or chosen by hand — that is where
  the search starts, and it outranks the search already running; what worked
  replaces it afterwards. The pass, the order and the wrap live in the model
  (`SmartSearch` in the Core package), so they are tested without a window.
  Two things the dump cannot show are said on a frosted plate in the window's
  lower third: a search that came round the end of the file (a circular arrow),
  and a pass where no encoding found anything, naming what it tried.
- **Find highlighting** — `Design/FIND_HIGHLIGHT_PLAN.md`, seven stages on the
  `find-highlight` branch. One scan per activated pattern is the single source:
  Find Next became an index step (and wraps), the Find bar counts ("3 of 128"),
  every occurrence is greyed in the dump with the current one on a raised
  yellow plate, both minimap modes mark the matches, and the results panel
  reads the set instead of running its own scan — refusing to list past 1000,
  where a list stops being a tool.
- **Segments, and joining a second chip's dump** — `Design/SEGMENTS_PLAN.md` and
  `Design/JOIN_SPLIT_PLAN.md`, shipped in 0.5 (`959c7ca`…`ccba1a6`, 2026-08-22 to
  08-29). The partition model that follows the content, the tint, the strip, the
  form and writing pieces out; append or insert a file by menu or drop band, and
  a joined image named after the dump it grew from (`422c22d`).
- **Dragging panes, and a drop zone for a new tab** — `Design/PANE_DRAG_PLAN.md`,
  shipped in 0.6 (`8da3103`…`093faef`, 2026-08-29/30). Swap by drag, a strip at
  the top for opening a file in a new tab, a pane dragged to another tab or into
  a new one, and Option to copy instead of move.
- **The test-suite revision** — `Design/TEST_REVIEW.md`, finished 2026-08-22.
  965 tests audited, app suite 674 → 559 and core 291 → 203 with coverage up
  (ten tests added for behaviour nothing watched, nineteen rewritten because
  they could not fail), 60 copied helpers replaced by one file, and ~12 s of
  wall-clock waiting replaced by seams. Two production bugs found on the way:
  silent data loss on a sandboxed save (`5bbef2a`) and the minimap's divider no
  longer following the panes' (`cb8f9aa`).
