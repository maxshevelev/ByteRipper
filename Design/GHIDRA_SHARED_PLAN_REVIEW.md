# A shared Ghidra workbench — review of the plan

Review of `8395f046` ("The Ghidra workbench plan names each reading and keeps
the review from the start") against `5c75d3e3`, the version that was reviewed
commit by commit in chat. The document was re-read in full, and every claim it
makes about the repository was checked against the source: the references to
`ApplyUefi.java`, `ExportCode.java`, `code_artifact.py`, `cas.py`,
`ContentStore.swift`, `CodeAnalysisStore.swift`, `UEFIToolModule.swift`,
`FragmentPanels.swift` and `AgentAnnotation.swift` all hold. The factual base of
the plan is sound; what follows is about the design it builds on that base.

Written as a work list for `Design/GHIDRA_SHARED_PLAN.md`: each finding names
the section it lands in and the change proposed. Two findings break the plan's
own acceptance criteria, one breaks a repository format rule, the rest are
specification gaps.

**Round 2 is §5.** The fixes, and the implementations that landed with them
(`53ea9495`, `24506c18`, `49f26145`), were reviewed the same way: §5.1 records
which findings above are closed and where, and §5.2 lists what the fixes
themselves opened.

**Headline.** The revision fixes the model in the right direction — the reading
has an identity, replacement is one rule for `putAnalysis` and bundle import
alike, the owner no longer owns a store, housekeeping no longer deletes a
review, and the recipe is tied to the project. The gaps are where that model
meets the store: a rebuilt project, the garbage collector, and the order in
which two manifests about one reading are written.

## 1. What was checked and holds

| claim (§3) | evidence |
|---|---|
| `ApplyUefi` leaves a decided name alone | `Skills/ghidra-uefi/scripts/ApplyUefi.java:298-308` — `label()` returns early unless `getSource() == SourceType.DEFAULT` |
| The exporter writes `name`, `name_source`, `name_reason` | `ExportCode.java:213`, `:217` |
| A recipe is more than its id | `code_artifact.py:200-214` — id, exporter, ghidra, script, types, passes |
| Bundle import refuses a key with another artifact | `cas.py:453`, `ContentStore.swift:426-431` |
| The app ignores that failure | `CodeAnalysisStore.swift:42` — `_ = try? store.importBundle(...)` |
| Only the tree's badges watch the store | `CodeStoreWatcher` is constructed only in `UEFIToolModule.swift:483` |
| The Code screen keeps its place as an index | `CodeScreenState.selectedFunction/selectedInstruction: Int?` (`Workspace.swift:306`), `CodeScreen.selectedInstruction: Int?` (`PanelContent.swift:44`) |
| An annotation keeps the function's name from its making | `AgentAnnotation.swift:53-59` |

Two small inaccuracies in the references, not in the facts:

- §10 gives `FragmentPanels.swift` without a directory; the file is
  `ByteRipperApp/Fragments/FragmentPanels.swift`, and every other row of that
  table gives a full path.
- §5.2 says "a publish builds its recipe from these" while its own example
  takes the exporter from the running tool; see finding 6.

## 2. Findings, most severe first

### 2.1 A rebuilt project becomes a second reading — HIGH

**Where:** §5.2 (`state.json` keeps "the project's identity (a UUID minted at
creation)"), §11 ("writes into a new revision of the same project's reading when
applied to a rebuild"), §5.6's table.

**Why it breaks.** A rebuild — after a lost disk, a broken Ghidra upgrade, a
purge, or on another machine — creates a project with a new UUID and `rev = 1`.
The first publish then offers `{project: Q, rev: 1}` against a stored
`{project: P, rev: n}`. That is the table's "P | another project Q" row: the
incoming manifest is kept aside, the store keeps the old reading. Every later
publish repeats the conflict, so a rebuilt project can never publish again — and
the plan's own rebuilding story (§11.1) is what creates the situation.

**Proposal.** A rebuild adopts the reading it was built from:

- `ApplyReview.java`, when it is applying a document to a project it created
  (not to an existing one), writes `reading.project` and `reading.rev` from the
  document into `state.json`, instead of minting a UUID and starting at 1; the
  next publish is `rev n+1` of the same project.
- §5.2 says the UUID is "minted at creation **unless the project is being
  rebuilt from a document, which brings its identity with it**".
- §11 adds a line to `ApplyReview`'s list: "continues the reading instead of
  starting one".
- §15 "Phase 5" gains the assertion: rebuild, publish, and the stored artifact
  is replaced rather than a conflict recorded.

### 2.2 The garbage collector will delete review documents — HIGH

**Where:** §9's layout (`reviews/…`, `conflicts/…` among the store's
directories), §15's test "after `gc` … both documents are still in
`reviews/` history". The collector itself is unchanged in both languages:
`cas.py:370-374` keeps only objects named as `artifact.sha256` by analysis
manifests, and `ContentStore.gc` has the same shape.

**Why it breaks.** Every object that is not an analysis artifact is an orphan to
the collector: the current review document (named by `reading.document`, not by
`artifact`), every earlier revision in `reviews/<sha>/manifest.json`, and every
manifest kept aside under `conflicts/`. The plan's test fails on the first run
after a `gc`.

**Proposal.** References, not a new mechanism:

- `gc` treats as live: `reading.document` of every analysis manifest, every
  `sha256` in every `reviews/<module-sha>/manifest.json` (current and history),
  and every artifact/document a `conflicts/` manifest names.
- `verify` gains the cross-checks: a `reading.document` that no object holds; a
  `reviews/` revision with no object; a `conflicts/` manifest with a missing
  object.
- The same change lands in `Design/CAS_SERVICE_PLAN.md`'s `collectGarbage`
  bullet, whose edit in this commit did not reach it.
- §15's test is written as: after two publishes and a `gc`, both documents are
  still there and `verify` is clean.

### 2.3 Two records of one reading, and no order between them — MEDIUM-HIGH

**Where:** §5.4's `reading` field, §9's layout, §9.1 ("the only writer is
`HarvestReview.java`").

**Why it breaks.** The same facts — current revision, document SHA — live in
two places: the analysis manifest's `reading`, and
`reviews/<module-sha>/manifest.json`. A client can store the artifact and die
before the review manifest, or the reverse; nothing in the plan says which one a
reader trusts, and `gc`/`verify` cannot arbitrate.

**Proposal.** A stated commit order, and a phrase for what "published" means:

1. store the document object;
2. write `reviews/<module-sha>/manifest.json` with the new revision;
3. store the analysis manifest naming that revision and SHA.

`publish` is not successful until all three are stored; a failure after (1) or
(2) leaves the store consistent (a revision nobody's artifact names yet, or a
document with no revision) and the next publish repairs it. `verify` reports
dangling in either direction.

### 2.4 A workspace format change that the plan says is not one — MEDIUM

**Where:** §10's row "the place is kept by address (`CodeLocation`), not by
index" against the paragraph below the table, "no store or workspace version
changes".

**Why it breaks.** The place is persisted in the workspace as indices:
`CodeScreenState.selectedFunction` and `selectedInstruction` are `Int?` in
`Packages/Workspace` (`Workspace.swift:306`). Changing what those fields mean —
or replacing them with addresses — is exactly the case the repository's rule
covers: `Workspace.currentVersion` (currently 4), a step in
`WorkspaceMigration.steps`, and fixtures for the older version. No added
optional field makes this go away, because the old value is still there and now
means something else.

**Proposal.** Either

- the plan declares it: "this raises `Workspace.currentVersion` to 5, adds a
  migration step that turns an index into the address it names at open time,
  and adds a version-4 fixture with a Code screen"; or
- the place stays index-based in this plan and the address work is dropped from
  §10.

Either way the sentence "no store or workspace version changes" must stop
covering the workspace.

### 2.5 A lease that requires a lease — LOW, but it is the protocol

**Where:** §7.1 — `POST /v1/lease` / `DELETE /v1/lease` are listed under
"Writes (each requires the lease token)".

**Proposal.** Move the lease pair above the "Writes" table and say what it
requires instead: nothing for a `POST` (the answer names the holder when
refused), the token for a `DELETE`.

### 2.6 The recipe names a Ghidra that did not make the artifact — MEDIUM

**Where:** §5.2 ("a publish builds its recipe from these", example
`code-v5-ghidra-12.1.2` with `types: edk2-stable202608`) against §3 ("a recipe is
more than its id") and the artifact's own `ghidra` field.

**Why it breaks.** `state.json` records the Ghidra version the project was
analysed with. The export runs on the owner's Ghidra, which may be newer (a
migrated project). The artifact then says `ghidra: 13.0` while the recipe says
`12.1.2`; a reader cannot tell which one to trust, and the recipe's whole
purpose is to let a reader decide whether it understands the file.

**Proposal.** Split the provenance by who produced what:

- `recipe.ghidra` and `recipe.exporter` come from the artifact
  (`script_version`, `ghidra`) — what actually wrote the JSON;
- `recipe.types` and `recipe.passes` come from `state.json` — what the program
  was typed with;
- `state.json`'s Ghidra version decides only whether the project should be
  rebuilt, and never labels an artifact.

§5.2 is rewritten to say exactly that, and its example is corrected to show a
new exporter with an old tag and the *running* Ghidra.

### 2.7 `reading` is trusted input — MEDIUM, remote only

**Where:** §5.6's table ("newer replaces older, never the reverse"), §13
Security (silent on it).

**Why it breaks.** Precedence is decided by a client-supplied project UUID and a
client-supplied revision. On the local store that is fine — one user, one
machine. `Design/CAS_SERVICE_PLAN.md` plans a remote service speaking the same
`putAnalysis`; there, any client could claim `{project: P, rev: 9999}` and
replace a review it never made.

**Proposal.** A line in §13 and in the CAS plan's security section: only an
authenticated writer may claim a reading; the service records which principal
claimed it; a claim that names a project the principal has not written to before
is refused (or queued for a person, like a conflict).

### 2.8 The review type archive has a lifetime problem — MEDIUM

**Where:** §6.5 ("one writer at a time — the owner that holds it open; a second
owner adding a type waits for it or is refused. Measured in phase 2").

**Why it breaks.** Every owner attaches the archive at project open (§6.5's
first bullet) and keeps it attached for its whole life; with a pool of two that
is the normal case, not an edge. "Waits for it or is refused" therefore means
"adding a type is unavailable whenever another module is open" — which is most
of the time, and the failure is not what the review loop expects.

**Proposal.** One of:

- types are written to the archive at publish, when the owner already does one
  batched operation, and the archive is read-only while any owner holds it;
- the archive is per-reading (`reviews/<module-sha>/types.gdt`) and merged into
  a shared one by `cas_cli.py`, offline;
- the plan says plainly: with more than one owner, new types are refused, and
  the pool is one until this is solved.

Whatever is chosen, §6.5 stops deferring the decision to a measurement that has
no answer in mind.

### 2.9 The `reviews/` history has no bound — LOW

**Where:** §9's layout, §9.1 ("deterministic … so an unchanged review harvests
to the same SHA").

**Why it matters.** Determinism deduplicates identical documents, but a live
review of fifty checkpoints keeps fifty distinct objects forever and a history
array that grows with each. That may be the intent — it is the diff base for
phase 5 — but it should be a stated choice, with a number a reader can act on.

**Proposal.** One sentence: history keeps every revision while the module is
under review; `cas_cli review prune <sha> --keep N` folds older ones into a
bundle, and `gc` then collects what nothing names.

### 2.10 Phase 2 is three deliverables — LOW, but it blocks the phase

**Where:** §14, phase 2: writes, `reading` in two languages, the open panel
following a republish, the place by address, `ghidra_review.py` and
`ghidra_mcp.py`.

**Why it matters.** The workspace migration (2.4) is marked "independent of this
plan, needed before it" and cannot live inside the phase that depends on it; the
app-side work (panel follows, annotation label by address) has no owner side at
all and can land before or after.

**Proposal.** Split:

- **1a** the place by address, with its workspace version, migration and
  fixtures — before everything else, its own commit series;
- **2a** the owner's writes, `HarvestReview`, `reading` in `cas.py`;
- **2b** `reading` and §5.6 in `ContentStore` and bundle import, the panel
  following a republish, the annotation label;
- **2c** `ghidra_review.py`, `ghidra_mcp.py`, the lease held by the wrapper.

## 3. Edits in passing

- §5.5's table row "the review is not lost … the document in the store at each
  publish" promises more than §5.4 delivers: an idle exit, an eviction and an
  expired lease save without publishing and without a document. Say "at each
  publish" or "the document, when a client publishes".
- §9.1: "only those a person or an agent made (`USER_DEFINED`)" has a source for
  symbols but not for data types. State the rule for types — for instance, a
  type the program holds that neither EDK2 archive nor the review archive
  defines — or the harvest will either miss user types or carry archive ones.
- §10's `FragmentPanels.swift` gets its directory.
- §5.6: say who writes `conflicts/` on the app's bundle import, and that its
  objects are pinned (finding 2.2).
- §15 "Pipeline parity" assumes the same `types` tag and exporter on both sides;
  with §5.2's provenance rule they can legitimately differ. Say the test pins
  both, or it will fail for the wrong reason.
- §2's note "re-done by hand from it" for a lost project: until phase 5 the
  document is readable but not machine-applied; that is worth saying in §11's
  opening instead of leaving the reader to infer it.

## 4. Order of work implied by this review

1. Decide the rebuild identity rule (2.1) — it changes what `state.json` holds
   and what `ApplyReview` writes.
2. Fix `gc` and `verify` (2.2) and the commit order (2.3) before any document
   is stored for real, or the first `gc` will lose the review.
3. Decide the workspace question (2.4) and, if taken, do it first as its own
   change (2.10).
4. Correct the recipe provenance (2.6) before phase 1's parity test is written,
   or the test encodes the wrong rule.
5. The protocol and archive items (2.5, 2.7, 2.8) can wait for their phases but
   should be decided in the document now.
6. 2.9 and §3's edits are prose.

## 5. Round 2 — the fixes, and what they opened

Reviewed: `53ea9495` … `49f26145`, which include the plan's revision, the store
reimplemented once in Swift, the owner, the harvest, the place by address and
the panel following a republish. Every new factual claim was checked against
the code again; all of them hold.

### 5.1 Status of round 1

| finding | status |
|---|---|
| 2.1 rebuild identity | **closed by design** — the UUID is inherited from the document (§5.2, §11, §5.6) — but §11 now names fields the document does not have: 5.2.1 |
| 2.2 `gc` deletes documents | **closed in code**: `ContentStore.collectGarbage` keeps the artifact, `reading.review` and the objects of `conflicts/` (`ContentStore.swift:409-418`); `verify` reports a missing document (`:362-363`) |
| 2.3 commit order | **closed** in §5.4 ("One record of a reading is the authority") — but step (2) has no writer: 5.2.4 |
| 2.4 workspace format | **closed differently, and better**: an optional `place` beside the indices, which stay and keep their meaning (`Workspace.swift:306-334`). An added optional field, so no version bump — the argument holds |
| 2.5 lease bootstrap | closed — a separate table, `POST` requires nothing |
| 2.6 recipe provenance | closed — exporter and Ghidra from the artifact, types and passes from the project, the project's Ghidra version deciding only a rebuild |
| 2.7 `reading` is trusted | closed for the claim itself (§13) — not for `--discard-reading`: 5.2.5 |
| 2.8 type archive | closed — no owner holds it, it is merged at publish under its lock — but the provenance it creates is unrecorded: 5.2.6 |
| 2.9 history bound | closed — `review prune --keep N`, then `gc` |
| 2.10 phase 2 size | closed — 1a, 2a, 2b, 2c, with what is done marked |

One thing this round found that the review had not: **a pass's decisions are
`USER_DEFINED` too** (`ApplyUefi` types the entry's parameters that way, the PE
loader writes section comments), so the harvest needs a baseline of the program
as the passes left it. That is the right answer, and it is what 5.2.2 is about.

### 5.2 What the fixes opened

#### 5.2.1 §11 rebuilds from fields the document does not carry — HIGH

**Where:** §11 ("it writes the document's `reading.project` and `reading.rev`
into `state.json`", line 742) against §9.1 ("The revision is not inside: it is
the manifest's") and the document's own shape (`"project": "6f0c…"` at the top,
no `reading`, no `rev`).

**Why it breaks.** The revision was deliberately taken out of the document so an
unchanged review harvests to the same bytes. A rebuild therefore cannot read it
from there, and an implementer following §11 literally will write an empty or
invented revision into `state.json` — which puts the rebuilt project back into
the conflict 2.1 described.

**Proposal.** The rebuild's input is the document **and the revision the store
names it by** (the analysis manifest's `reading`, or the `reviews/` entry that
points at it). `ApplyReview` writes `{project: document.project, rev: that
revision}` into `state.json`. §11 says so, and §9.1 says where a rebuild gets
the revision, since it says the document has none.

#### 5.2.2 The baseline swallows the document on a rebuild — HIGH

**Where:** §9.1 ("the harvest subtracts the baseline it recorded then"),
§6.2 ("Created on first open: import, analyze, `ApplyUefi`, and — from phase 5 —
apply the stored review document"), and the owner's behaviour:
`Owner.java:127-137` records the baseline at its **first open** if the program
has none, and saves it into the program's options (`Harvest.BASELINE`,
`Harvest.java:59-71`).

**Why it breaks.** If a rebuild applies the document while creating the project,
the owner's first open happens *after* the decisions are in the program, so the
baseline contains them. The next harvest subtracts the baseline and the review
comes out empty — the document is silently lost on the first publish after a
rebuild, which is exactly the case the document exists for.

**Proposal.** `ApplyReview` records the baseline **before** it applies anything
(`Harvest.recordBaseline(program)`), and §11 lists that step. §9.1 and §6.2
name where the baseline lives — the program option `ByteRipper.baseline`, saved
with the program — so a later reader does not have to guess. §15 gains the test
that catches it: rebuild from a document, publish, and the new document still
holds the review.

#### 5.2.3 `POST /v1/type` still writes the archive — MEDIUM

**Where:** §7.1's write table (`{name, c}` → "the program and the review type
archive", line 540) against §6.5 ("adds the type to the program only", line
493).

**Proposal.** The table cell becomes "→ the program; merged into the archive at
publish (§6.5)".

#### 5.2.4 The history entry has no writer — MEDIUM

**Where:** §5.4's commit order, step (2) "the history entry for the new
revision"; `Design/CAS_SERVICE_PLAN.md` §3.1, whose command set has no `review`
command; `ContentStore.putAnalysis`, which writes no history.

**Why it breaks.** `cas.py` is now a thin client of `byteripper-cas` and holds
no store logic. The only ways to write `reviews/<module-sha>/manifest.json` are
a new command, or Python writing the store directly — which is the
two-writer problem the single implementation was introduced to end.

**Proposal.** Write the history entry inside `put-analysis`, under the same
`flock`, as part of the same commit: the client passes the document and its
revision, the store stores the object, appends the history entry and writes the
manifest. The commit order then collapses to two steps — the document object
first, then one `put-analysis` — which is simpler to get right and leaves the
same failure modes. `cas_cli.py review list/prune` then needs only read and
prune commands.

#### 5.2.5 `--discard-reading` bypasses §5.6 — MEDIUM

**Where:** `CAS_SERVICE_PLAN.md:89,158,218` (`put-analysis --discard-reading`),
`ContentStore.putAnalysis` (`discardReading` accepts any incoming artifact), and
§13's "A reading is a claim", which does not mention it.

**Why it breaks.** The flag overrides the whole table, including another
project's reading. Locally that is a deliberate human escape hatch. On the
remote store §5.1 plans, it is a one-word bypass of the precedence rule the
security section just described.

**Proposal.** §13 and the CAS plan's §3.3 say: a remote store refuses
`discard-reading` (and `replace` outside the caller's own project); it requires
the same authentication and recording as any other claim; locally the flag stays
what it is.

#### 5.2.6 Cross-module types are invisible in the provenance — MEDIUM

**Where:** §6.5 (an archive merged at publish, attached to every project) and
§5.2's recipe rule (only the EDK2 tag).

**Why it breaks.** A module B opened after module A's review is typed from A's
definitions. B's artifact then depends on A's document, but B's manifest names
neither the archive nor A. Reproducing B on another machine without A's document
gives a different artifact, and nothing in B says why.

**Proposal.** Record the dependency, in a form that is stable: the `.gdt` file is
not byte-deterministic, so hash the *definitions* instead —
`recipe.review_types` = SHA-256 over the archive's `{name, C text}` pairs,
sorted, the same way the review document is canonicalised. A reader can then
tell two artifacts apart and find the documents that produce the hash.
`reading.types_from: [<module-sha>…]` is the more human form, if the merge keeps
track of which document contributed each type.

#### 5.2.7 §5.6's table misses "mechanical over mechanical" — LOW

**Where:** the table, against `ReadingOrder.unreviewed`
(`Models.swift:280-285`) and §5.4's own sentence "A mechanical artifact never
replaces another (§5.6)".

**Proposal.** Add the row: "no reading | no reading, another artifact | kept;
`replace` states a re-run by hand".

#### 5.2.8 `HarvestReview.java` is `owner/Harvest.java` — LOW

Three places still name the class the implementation calls something else:
§2's table (line 73), §9.1's "The only writer is `HarvestReview.java`" (line
677), and §10's owner row (line 693). The file in the repository is
`Skills/ghidra-uefi/owner/Harvest.java`.

### 5.3 In passing

- `CAS_SERVICE_PLAN.md`'s phase 4 is introduced as "Needed once readings exist,
  i.e. with phase 2 of the Ghidra plan". Readings exist since its own phase 3;
  what phase 2 adds is the *first* reading. Reword to "needed with the Ghidra
  plan's 2b, the first phase that stores a reading".
- §3's "To verify in phase 0" became "Verified in phase 0" — the two traps it
  found (`GhidraProject.openProgram`'s standing transaction, `ghidra.Ghidra` as
  a launcher for a class on `-cp`) are worth keeping in `reference/ghidra.md`
  too, not only in the plan.
- §9.1 could say what the baseline covers — symbols, comments, data names and
  types — since the harvest subtracts it field by field, and a decision that
  returns to its baseline value (a name renamed back) is, by design, not in the
  document.

### 5.4 What to do now

1. 5.2.2 first: it is silent data loss on a rebuild, and a one-line fix in
   `ApplyReview`'s design plus a test.
2. 5.2.1 with it — the same rebuild path, the same test.
3. 5.2.4 before 2b writes any history, or the history will be written by the
   wrong process.
4. 5.2.5 with the remote-service design; 5.2.6 before a second module's review
   relies on the archive.
5. 5.2.3, 5.2.7, 5.2.8 and §5.3 are edits to the text.

