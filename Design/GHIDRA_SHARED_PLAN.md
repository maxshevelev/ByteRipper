# A shared Ghidra workbench — long-lived projects, a reviewed reading, a cached artifact

> Status: proposal for review. Nothing described here exists yet.
>
> Русское слово для главного понятия этой записки — **разбор модуля**: то, что
> человек или агент понял о смысле кода и записал в Ghidra — имена, сигнатуры,
> комментарии, типы. Разбор делается только инструментами Ghidra.
>
> The main workflow is: one Ghidra owner per module keeps the project open, an
> agent or a person renames and comments through Ghidra's own APIs, and a
> *publish* saves the program, exports the code artifact the app reads, and
> harvests a copy of the decisions — the review document — so the reading
> survives the project.

## 1. Decision in one page

1. **The review is made in Ghidra, with Ghidra's tools.** The project's symbol
   table, function signatures, comments, data names and data types *are* the
   review. A person does it in a CodeBrowser; an agent does it through a bridge
   that calls the same Ghidra APIs. There is no second editing surface and no
   private model of what a name is.
2. **One Ghidra owner per module.** A long-lived Ghidra process holds the
   program and serves the bridge. The owner hands out one write lease, because
   a Ghidra program is not a multi-writer database. A supervisor, when there is
   more than one owner, only starts, routes and evicts them.
3. **The project is where the work lives.** Unlike today's one-run temp
   project, the project is kept per module, so a review survives between
   sessions. It is the truth about the module's meaning.
4. **Publishing is the only thing that reaches CAS:** save, export the
   artifact, harvest the review document, hand both to the client, which stores
   them. A rename never writes to CAS. Publishing is a checkpoint that repeats
   through a session, not a finale (§5.5).
5. **The owner owns no store.** It returns what it produced; the client writes
   it into the store the app watches. With no client there is no publish: an
   idle exit, an eviction or an expired lease *saves* and reports unpublished
   changes, nothing more.
6. **An artifact says which reading it is.** A publish replaces the artifact
   under the same module and recipe, so every manifest names the reading that
   produced it — the project's identity and a revision. That is what lets a
   bundle import, a second machine or a batch run tell newer from older, and a
   different reading from both (§5.6).
7. **The review document is made from the start, applied later.** Harvesting
   the decisions on every publish is cheap and is the only copy of the review
   outside the project. Applying a document to a fresh project, diffing two
   readings and the batch path with a review come in phase 5.
8. **A reviewed project is never deleted by housekeeping.** Disk-budget
   eviction removes only projects that hold nothing but mechanical analysis —
   those are a cache. A project with a person's or an agent's decisions is
   removed only by an explicit purge, and only after its document is stored.
9. **CAS is the cache the product reads.** Artifacts, keyed by module SHA +
   recipe, carrying the names the review produced. The app, the Code panel,
   `code_query.py` and agent queries read them; nothing in the read path needs
   Ghidra.
10. **The store does not hold firmware.** The module's bytes come from the dump
    and stay where the dump is.
11. **A closed operation set, not a script runner.** The bridge exposes rename,
    comment, signature, type, save, publish — never "run this script" and
    never a filesystem path, in a request or in an answer.
12. **Local by default.** Everything listens on loopback; another machine
    reaches the supervisor through an SSH forward or a tailnet. Binding a real
    interface requires a token and is documented as the exception.
13. **No dependency on GhydraMCP.** It stays the ad-hoc human tool it is; the
    agent-facing contract is our own versioned protocol, because save,
    local-variable rename and export do not exist there.

## 2. What is made where

| step | what is being read | who does it | what appears | where it is kept | if it is deleted |
|---|---|---|---|---|---|
| 0. the module | the UEFI tree: which node holds a PE32/TE image | ByteRipper (tree), the skill | the module's **identity**: its SHA-256 and where it came from | nowhere — the bytes stay in the dump | the dump is the copy that matters |
| 1. mechanical analysis | the bytes: PE/TE headers, sections, imports | Ghidra's analyzers + `ApplyUefi.java` | an analyzed *program*: functions, instructions, xrefs, C, strings | project `GhidraProjects/<module-sha>/` | re-run, seconds to a minute |
| 2. the review | the program: what each function, parameter and place *means* | a person in a CodeBrowser, or an agent through the bridge | names, signatures, variable names, comments, data names, types — inside the project | **the project** | rebuilt from the last review document (phase 5); until then, re-done by hand from it |
| 3. publish | the reviewed program | `ExportCode.java` and `HarvestReview.java` on the owner | the artifact everything reads, and the review document | CAS: `analyses/<module-sha>/<recipe>/`, `reviews/<module-sha>/` | re-publish from the project |

- **The read path is cache-only.** The app and `code_query.py` are satisfied by
  step 3 and no Ghidra is involved.
- **The review lives in the project, and its last published copy in the
  store.** Work done since the last publish exists only in the project.

**Why not publish on every rename.** An export decompiles the whole program, so
two hundred renames would mean two hundred exports; and an artifact published
in the middle of a burst of renames would show names the next rename
contradicts. A session publishes where it has reached a coherent state, as
often as it likes (§5.5).

## 3. Facts this design is built on

Verified against Ghidra 12.1.2 on this machine, the installed GhydraMCP
2.2.0-rc.3 extension, and the repository as of `5c75d3e3`.

- **A name is a symbol-table entry, not text.** Ghidra renders a name from the
  symbol table when it draws a listing or decompiles a caller. Renaming one
  entry fixes every use with no re-analysis, but the decompiled C of every
  caller is regenerated.
- **Ghidra saves all of this with the project.** Symbols, signatures,
  comments, data names and data types are the program's database.
- **The artifact is a rendering, not the review.** `ExportCode.java` writes
  functions, signatures, instructions, references, strings, named symbols and
  C. It does not write listing comments or data-type definitions, so a review
  cannot be reconstructed from an artifact.
- **`ExportCode.java` already writes `name`, `name_source` and `name_reason`**
  per function. `ApplyUefi.java` names with `SourceType.ANALYSIS` and records
  why in the program property `ByteRipper.nameReason`; a review's names are
  `USER_DEFINED`. An artifact therefore already tells a reviewed name from a
  pass's, with no schema change.
- **`ApplyUefi.java` leaves a named symbol alone** (it skips anything that is
  not `SourceType.DEFAULT`, `ApplyUefi.java:302`). Running a newer pass over a
  reviewed project keeps the review; that property must be kept deliberately.
- **A recipe is more than its id.** The manifest's recipe carries the exporter
  version, the Ghidra version, the EDK2 type archive (`types`) and the passes
  (`passes`) — `code_artifact.py:205`.
- **The store is implemented once, and already knows readings.** `ContentStore`
  (`Packages/CodeAnalysis`) is the only implementation; the skill's `cas.py`
  runs it as `byteripper-cas` (`Design/CAS_SERVICE_PLAN.md`). The manifest's
  optional `reading`, the table of §5.6 at put and at bundle import,
  per-key import with a report, and `conflicts/` exist since `CAS_SERVICE_PLAN`
  phase 3. The app imports a project's `Analyses.bundle` on open but does not
  yet show what the import skipped or kept aside
  (`CodeAnalysisStore.swift:42`).
- **The badge matches by SHA.** `UEFICodeScan.scan` hashes candidate bodies and
  looks the digest up; `source.document`/`source.node` only say which branches
  to open first. A moved dump costs nothing.
- **An open Code panel does not follow the store.** Only the UEFI tree's badges
  watch it (`UEFIToolModule.swift:514`). A saved Code screen remembers its place
  as a function and an instruction *index* (`FragmentPanels.swift:174`), and an
  annotation on code keeps the function's name as it was when it was made
  (`AgentAnnotation.swift:59`).
- **Shared projects** (`ghidra://host:13100/…`, `-connect`, `-commit`,
  `-keystore`) exist. The Ghidra Server gives history and exclusive check-out;
  it has no editing API and is not a concurrency mechanism (§12).
- **GhydraMCP** serves REST inside a CodeBrowser and has no save, no
  local-variable rename and no authentication.

To verify in phase 0 (§14), because the design depends on them:

- whether a script run by `analyzeHeadless` holds one transaction around the
  whole script — if it does, a blocking server script cannot save mid-session,
  and the owner needs its own entry point (§6.1);
- `DomainObject.getModificationNumber()` restarts with every open, so it can
  say "changed since the last publish" only within one run of an owner (§5.5);
- how a register-based local keeps its identity across renames and
  re-decompilation (storage plus first-use offset, §7.1).

## 4. Architecture

```
      agents (MCP wrapper)     skill / CLI (Python)      app (later)
            \                       |                       /
             \                      v                      /
              +------ supervisor (phase 3) ----------------+
              |    pool, routing, network auth             |
              |                                            |
              |   one owner per open module                |
              |   +------------------------------------+   |
              |   | Ghidra — headless or CodeBrowser    |  |
              |   |   project: GhidraProjects/<sha>/    |  |
              |   |   lease, bridge /v1                 |  |
              |   +------------------------------------+   |
              +----------------------+---------------------+
                                     | publish: artifact + review document
                                     v
                               the client stores them
                                     |
                                     v
                 CAS analyses/<sha>/<recipe>/, reviews/<sha>/
                                     |
                                     v
                             app, code_query, agents
```

Until phase 3 there is no supervisor: one owner, started by the client, on one
loopback port.

## 5. The stages in detail

### 5.1 Step 0 — the module's identity

- The UEFI tree names the node; `byteripper_extract.py` fetches its bytes from
  the app and writes them to a temporary file.
- The only lasting result is the hash of those bytes and the provenance they
  came with (`source.document`, `source.node`) — what the store keys and
  records today.
- **Nothing is written to the store here.** Keeping a second copy of the bytes
  would make the store a firmware library and invite it to go stale against
  the dump.

### 5.2 Step 1 — mechanical analysis

- Import (TE converted to PE first), Ghidra's analyzers, then `ApplyUefi.java`:
  EDK2 types, the shared review types (§6.5), GUID names, the PEI/DXE entry
  signature, and names recovered from the module's own `DEBUG` strings.
- Result: a program in a project under
  `~/Library/Application Support/ByteRipper/GhidraProjects/<module-sha>/`.
- **The project records what made it.** `state.json` keeps the Ghidra version,
  the EDK2 tag, the passes and the project's identity (a UUID minted at
  creation). A publish builds its recipe from these, not from the tooling
  installed now: a project made with `edk2-stable202608` and published after an
  exporter update is `code-v5-ghidra-12.1.2` with `types: edk2-stable202608`,
  never the new tag it was not typed with.
- Not free: a DxeCore-sized module takes tens of seconds. That is one reason
  the project is kept.

### 5.3 Step 2 — the review

| the decision | Ghidra operation | seen by |
|---|---|---|
| a function's name | `SymbolTable` rename of the function symbol | listing, decompiled callers, xrefs |
| a parameter's or local's name and type | `Function` variable APIs; a decompiler local via `HighFunctionDBUtil.updateDBVariable` | decompiled C |
| a function's signature | `Function` signature update | decompiled C, callers' casts |
| a comment | listing comments (pre, post, eol, plate, repeatable) | listing; plate comments in C |
| a datum's name or type | `Data`/`Listing` APIs | C, disassembly |
| a structure or enum | `DataTypeManager` from C source | everywhere the type is used |

- The bridge is a **remote control for those APIs**: one Ghidra transaction
  per change, Ghidra validates, the bridge returns Ghidra's answer. A rename
  Ghidra would silently disambiguate (`Foo` → `Foo_1`) is an error to the
  client.
- **Every decision carries its author and reason.** A rename takes an optional
  `reason`; the owner records it, with `agent` or `person`, in
  `ByteRipper.nameReason` — the property `ApplyUefi` already uses — so the
  artifact's `name_reason` says who named a function and why, and the panel can
  tell a reviewed name from a pass's.
- A person may do the same in a CodeBrowser while the owner is that CodeBrowser
  (phase 4). Same state, same result.
- **Nothing leaves the project here.** The app shows the previous artifact
  until the session publishes.
- The owner saves on publish, on lease release or expiry, on idle exit and
  before it is stopped — not after every rename, because a save writes the
  database.

### 5.4 Step 3 — publish

```
save  →  export the artifact  →  harvest the review document  →  return both
                                                                      │
                                       the client stores them in its own store
                                                                      │
                                                    that store announces the change
```

- `POST /v1/publish`, and one command for a person.
- **The client stores; the owner does not.** The client writes into the store
  the app watches. On one machine that is the same store either way; with the
  owner on a powerful machine and the client on a laptop it is the only
  arrangement that puts the artifact where the laptop's panel sees it. It keeps
  one writer per store.
- **Triggers are the client's.** Any checkpoint it chooses, and lease release
  when the client asks for it (the review client and the MCP wrapper do, by
  default). Never a rename. An idle exit, an eviction or an expired lease has
  no client to hand anything to: it saves, and the next `hello` reports
  `unpublished: true`.
- **Readers keep seeing the previous artifact** until the publish lands; the
  app never presents a module mid-rename.
- **One current reading per module and recipe.** The recipe names *how* an
  artifact was produced; a second reading by the same tooling is the same
  recipe, so publish replaces the manifest under the same key. Another tool is
  a new recipe beside it, as today.
- **The manifest says which reading it is** (§5.6): a `reading` field with the
  project's UUID, a revision that grows with every publish that changed
  something, and the review document's SHA. A mechanical artifact — the batch
  path, or a project nobody has reviewed — has no `reading`.
- **Objects are never overwritten.** The new artifact and document are new
  objects; the manifest is replaced atomically; the previous object stays until
  garbage collection. A crash between the two leaves an unreferenced object,
  never a manifest pointing at a missing one.
- **Replacement is the publish path's, not a flag.** `putAnalysis` replaces
  when the incoming reading is newer than the stored one (same project, higher
  revision, or a reading over none). Anything else is refused as today, and
  `code_artifact.py --force` keeps its meaning but refuses to put a mechanical
  artifact over a reading unless told `--discard-reading`.
- **If publishing fails halfway** — save done, export failed — or the client
  dies before storing, the project is ahead of the cache. `state.json` keeps the
  last stored artifact's SHA and revision; the owner reports unpublished
  changes, and the next publish produces the same artifact, because
  `ExportCode` is deterministic on an unchanged program.
- **Cost:** an export over the open program — seconds for a PEIM, tens of
  seconds for DxeCore. A remote owner also sends the artifact over the wire: a
  few hundred kilobytes to about 10 MB.

### 5.5 The loop: 2 ↔ 3

The review is not one pass: read a function, name it, follow its callees,
publish, re-read the callers to see whether the name reads correctly there, go
back, rename more, publish again.

- **Any number of publishes per session.** The rule is "at a checkpoint, not on
  every rename".
- **Publishing an unchanged program is a no-op.** Within one run the owner
  compares the modification number with the one it last published; after a
  restart it has no number to compare, so it exports and compares the
  artifact's SHA with the one in `state.json`, and returns the stored reading
  without a new revision if they match.
- **After a publish the client chooses where to read.** The live program
  (`/v1/function/{address}`) is fresh and ahead of the cache while a session
  runs; the artifact is the whole module, consistent, and exactly what the app
  shows.
- **Every publish is announced** by the store's change event; the badges and an
  open Code panel follow it (§10).
- **Nothing about the loop is scripted.** The client exposes primitives; the
  agent decides when to stop.
- **If checkpoints on large modules become painful,** the answer is an
  incremental export — only functions whose C changed, merged into the
  previous artifact. A later optimisation, not this plan.

| the thing | what enforces it |
|---|---|
| the right to write | the lease, one per module, in the owner |
| one change is all-or-nothing | a Ghidra transaction per mutation |
| the review is not lost | save on publish, release, expiry, idle and stop; the document in the store at each publish |
| what the app sees | the last stored publish; a change event after each one |
| newer replaces older, never the reverse | the manifest's `reading` |
| a repeat publish costs nothing | the modification number; after a restart, the artifact's SHA |

### 5.6 Readings across bundles and machines

Replacing an artifact in place means the same key can hold different readings
in different places: a ByteRipper project's `Analyses.bundle` saved before the
last publish, a second Mac with its own owner, a batch run. The manifest's
`reading` decides, at `putAnalysis` and at bundle import alike:

| stored | incoming | result |
|---|---|---|
| none | anything | stored |
| no reading (mechanical) | a reading | the reading replaces it |
| a reading | no reading | kept; the incoming is skipped, not an error |
| reading of project P, rev n | P, rev m > n | replaced |
| P, rev n | P, rev m ≤ n | kept; skipped |
| P | another project Q | kept; the conflict is reported, and the incoming manifest is kept aside under `conflicts/` for a person to choose |

- Bundle import goes key by key: one conflict does not stop the rest of the
  bundle from importing. The app reports skipped and conflicting keys instead
  of discarding the result (`CodeAnalysisStore.swift:42` today ignores it).
- Two owners of the same module on two Macs are two projects, so their readings
  conflict rather than overwrite each other. The cure is one owner per module —
  on the powerful machine — which is what §12.1 recommends; from phase 5 the
  other cure is to apply one reading's document to the other project.

### 5.7 The batch path, for a machine with no owner

`code_artifact.py <module>` keeps doing import → analysis → `ApplyUefi` →
`ExportCode` in one headless process. It stays the CI and scripted path and
needs no owner. It writes a mechanical artifact, which never replaces a reading
(§5.6). From phase 5, `--review <document>` applies a stored reading first and
writes an artifact carrying that reading.

## 6. The owner

### 6.1 What it is

A Ghidra process with exactly one program open, serving the bridge on a
loopback port.

- **Headless host (default).** A Java entry point that initializes Ghidra in
  headless mode (`Application.initializeApplication`), opens the project and
  the program itself, and starts the HTTP server. It is not a script run by
  `analyzeHeadless`: a long-blocking script would hold the launcher's
  transaction and its lifecycle, and the owner needs both its own (phase 0
  confirms which). No window server, so launchd can own it.
- **CodeBrowser host (phase 4).** The same bridge code loaded as a plugin in
  the GUI.
- **Built without Gradle.** The skill compiles the Java with `javac` against
  the jars of the pinned Ghidra install, from Python, the way it already
  locates Ghidra (`ghidra_import.find_ghidra`). No build system joins the
  repository.

PyGhidra would be the obvious alternative, but it needs JPype and a Python with
matching wheels; this machine has only 3.14 and no JPype.

### 6.2 The project

- One project per module, under
  `~/Library/Application Support/ByteRipper/GhidraProjects/<module-sha>/`. Two
  dumps with the same module share it; a changed module gets a new one.
- Created on first open: import, analyze, `ApplyUefi`, and — from phase 5 —
  apply the stored review document if one exists.
- **Where the bytes come from:** the client sends them — it has just extracted
  them from its dump. On one machine the owner may instead fetch them through
  the app's relay by `source.document`/`source.node`; a remote owner cannot see
  the laptop's app, so there the client always sends them. The owner verifies
  the SHA-256 and refuses a mismatch.
- A project is exclusive to one process; the owner holds Ghidra's lock.
- `state.json` beside the project: the project UUID, what made it (§5.2), the
  last stored revision, artifact SHA and document SHA, and whether the project
  holds any decisions (`reviewed: true` after the first user-made change).

### 6.3 Lifecycle

- Start on demand; progress (import, analysis) over `GET /v1/hello`.
- Idle exit after a timeout: save, and exit. No publish (§5.4).
- A crashed owner keeps whatever was saved; `state.json` shows whether the
  cache is behind it. The client — or, from phase 3, the supervisor — restarts
  it on the next request.

### 6.4 Disk and housekeeping

A program database is single-digit to tens of megabytes; one dump's modules can
reach several gigabytes.

- A budget (default 20 GB). Over budget, the oldest **unreviewed** projects are
  removed: they hold only mechanical analysis and are rebuilt from the bytes.
- **A reviewed project is never removed by the budget.** `gh projects purge`
  removes one only when asked, prints what it would free first, and refuses a
  project whose current state is not in a stored document (it publishes or
  harvests first if an owner can run).
- `cas_cli.py gh projects list` shows size, last use, reviewed or not, and
  unpublished changes.
- Not in `~/Library/Caches`: a reviewed project is durable work and belongs
  where the rest of the app's data is, carried by a normal backup. Not in the
  store: it is large, binary, exclusive and not content-addressed.

### 6.5 Types shared between modules

A structure a review defines in one module — a vendor configuration block, a
private protocol's interface — is usually needed in the modules that consume
it. A type made in one project is invisible to another.

- A **review type archive** (`GhidraProjects/review-types.gdt`) beside the EDK2
  archives. `POST /v1/type` adds the type to the program *and* to the archive;
  every project opened afterwards has the archive attached, as it has EDK2's.
- The archive is part of the review: harvested types carry their source, and
  from phase 5 a document can rebuild the archive's entries it uses.
- The archive has one writer at a time — the owner that holds it open; a second
  owner adding a type waits for it or is refused. Measured in phase 2 whether
  this is a real constraint.

## 7. The bridge

### 7.1 Protocol

JSON over HTTP, versioned in the path (`/v1/…`). Every response carries the
program identity (module SHA, language, image base), the project UUID, the last
stored revision and `unpublished`. No response carries a path.

Reads:

| call | answer |
|---|---|
| `GET /v1/hello` | protocol, Ghidra version, program identity, state, progress while opening |
| `GET /v1/functions` | entries, names, sizes, signatures (paged) |
| `GET /v1/function/{address}` | signature; parameters and locals with storage, first use and type; decompiled C |
| `GET /v1/disassembly/{address}` | instructions with bytes and references |
| `GET /v1/xrefs?to=/from=` | reference list |
| `GET /v1/data`, `GET /v1/strings` | data items and strings |

Writes (each requires the lease token):

| call | Ghidra operation |
|---|---|
| `POST /v1/lease` / `DELETE /v1/lease` | take or release the write lease (§7.3) |
| `POST /v1/rename/function` | `{address, name, reason?}` → symbol rename |
| `POST /v1/rename/variable` | `{function, storage, first_use?, name, type?}` → parameter or local |
| `POST /v1/set/signature` | `{address, signature}` |
| `POST /v1/set/comment` | `{address, kind, text}` |
| `POST /v1/set/data` | `{address, name, type}` |
| `POST /v1/type` | `{name, c}` → the program and the review type archive |
| `POST /v1/save` | save the program |
| `POST /v1/publish` | save, export, harvest; returns the artifact, the document and the revision (§5.4) |

- A local is named by its storage and, for a register, its first use: `EAX:4`
  alone names many locals in one function. A parameter also by its ordinal.
- Deliberately absent: script execution, file paths, project management,
  analysis options.

### 7.2 Reading C

- Decompilation is cached per function, tagged with the program's modification
  number. Any mutation makes every cached function stale; a function is
  decompiled again only when it is read, so a rename costs one decompilation
  per function read afterwards, not an export.
- The bridge returns the same C `ExportCode.java` would write. Bulk reading
  belongs to the artifact; the bridge is for the loop.

### 7.3 Leases

- One live write lease per module, held by the owner. A second is refused with
  the holder and expiry rather than blocking.
- A lease has a TTL and is renewed by any write with its token. An expired
  lease saves; it does not publish.
- **An agent never sees a token.** MCP tool calls are stateless; the MCP
  wrapper takes the lease on the first write of a module, renews it with every
  write, and releases it — with a publish — when the agent says it is done or
  the wrapper exits. The agent's tools are rename, comment, type and publish.
- Reads need no lease.
- The lease holder is logged beside every mutation.

### 7.4 Transport and network

- Every owner binds loopback only.
- Until phase 3 the client talks to its owner's port directly. From phase 3 the
  supervisor is the only listener a client knows: a Unix domain socket under
  `~/Library/Application Support/ByteRipper/Ghidra/` for local clients and a
  loopback HTTP port for the MCP wrapper, proxying to the owners.
- Another machine reaches the supervisor through an SSH forward
  (`ssh -L 8765:127.0.0.1:8765`) or a tailnet address — the documented default
  and the whole of the "powerful machine, laptop client" deployment.
- A non-loopback bind is an explicit option that refuses to start without a
  token file (0600) and a client allowlist; TLS is expected at a proxy.

### 7.5 Who talks to it

- **Agents:** a thin MCP wrapper (`Skills/ghidra-uefi/scripts/ghidra_mcp.py`,
  stdlib) translating tool calls to `/v1` and owning the lease (§7.3). Whether
  these tools also appear on ByteRipper's own MCP server is open (§16.8).
- **The skill:** `ghidra_review.py` drives a session — lease, rename, comment,
  publish, store; `code_query.py` keeps reading artifacts, with `--live` as the
  escape hatch to the bridge.
- **The app:** a reader of what publishes store; from phase 7, "Open in Ghidra".

## 8. A session, end to end

```
open       code_modules → module SHA → bytes to the owner → ready
survey     artifact (fast, whole module): functions, callers, strings
read       /v1/function/{address} — C is fresh, names are current
decide     rename functions, params, locals; set signatures; comment; add a type
publish    artifact + document → the client's store → the app follows
           ┌───────────────────────────────────────────────┐
read again │ do the names read correctly in the callers?   │
           │ what is still unexplained?                    │
           └───────────────────┬───────────────────────────┘
                               └──► decide again, publish again
done       the wrapper publishes and releases the lease
```

A session that dies before publishing leaves the project ahead of the cache;
the next `hello` reports `unpublished: true` and the next session publishes.

## 9. Storage layout

```
analyses/<module-sha>/<recipe>/manifest.json   the artifact cache; gains "reading"
reviews/<module-sha>/manifest.json             { current: {project, rev, sha256}, history: [...] }
objects/<sha256>                               artifacts and review documents
conflicts/<module-sha>/<recipe>/<sha>.json     a manifest from another reading, kept for a person
GhidraProjects/<module-sha>/                   program + review + state.json
GhidraProjects/review-types.gdt                types shared by reviews (§6.5)
```

- The store holds artifacts and review documents — what the product reads, and
  the copy of the review. Never firmware bytes.
- A project lives beside the store, not in it.
- Writers: `byteripper-cas` (the skill's `cas.py` is its client), and the app
  through bundle import — one implementation, `ContentStore`, so §5.6 is one
  rule. The owner writes nothing.
- A bundle carries the review documents its analyses' readings name, so a
  project bundle carries the reading as well as its rendering.

### 9.1 The review document

A JSON document per module, written by `HarvestReview.java` at every publish.
It holds decisions only — no code, no bytes, no instructions — and only those a
person or an agent made (`USER_DEFINED`), not what the passes produced:

```json
{
  "schema": 1,
  "module": { "sha256": "9c1f…", "name": "AmdSocFp6CznPei", "kind": "TE",
              "language": "x86:LE:32:default", "image_base": "0x0" },
  "made_with": { "ghidra": "12.1.2", "exporter": 4, "types": "edk2-stable202608",
                 "passes": ["ApplyUefi.java"] },
  "reading": { "project": "6f0c…", "rev": 3 },
  "functions": {
    "0x9a889ee": {
      "name": "AgesaAssert", "by": "agent", "reason": "…",
      "signature": "void AgesaAssert(UINT32 Code)",
      "params": [ { "ordinal": 0, "storage": "Stack[0x4]:4", "name": "Code", "type": "UINT32" } ],
      "locals": [ { "storage": "Stack[-0x18]:8", "first_use": null,
                    "name": "PciLength", "type": "UINT64" } ]
    }
  },
  "comments": [ { "address": "0x9a89030", "kind": "pre", "text": "AbovePcieCfgIsTooSmall" } ],
  "data":     { "0xdf360930": { "name": "gAgesaStatus", "type": "UINT32" } },
  "types":    [ { "name": "AMD_CONFIG_PARAMS", "c": "typedef struct { … }" } ]
}
```

- **Keyed by address, never by an old name.** `FUN_0009a889ee` stops existing
  the moment it is renamed; its address does not.
- **Locals keyed by storage and first use**, parameters also by ordinal (§7.1).
- **An export, not an editing format.** The only writer is `HarvestReview.java`;
  a hand edit would be undone by the next harvest.
- **Deterministic**: sorted keys, no timestamps inside, so an unchanged review
  harvests to the same SHA. Time and author of a revision are in
  `reviews/<module-sha>/manifest.json`.

## 10. What changes in the repository

| path | change |
|---|---|
| `Skills/ghidra-uefi/owner/` | new: the Java owner — headless entry point, bridge, lease, `HarvestReview`; later the CodeBrowser plugin |
| `Skills/ghidra-uefi/scripts/ghidra_owner.py` | new: compile the owner against the pinned Ghidra, start and stop it, `state.json` |
| `Skills/ghidra-uefi/scripts/ghidra_review.py` | new: a review session client (lease, rename, comment, publish, store) |
| `Skills/ghidra-uefi/scripts/ghidra_mcp.py` | new: MCP wrapper over `/v1`, owner of the lease |
| `Skills/ghidra-uefi/scripts/ghidra_service.py` | new in phase 3: supervisor — pool, routing, network auth |
| `Packages/CodeAnalysis` (`ContentStore`, `byteripper-cas`) | done: `reading`, §5.6 at put and import, `conflicts/`; to do: `reviews/` and documents in bundles |
| `Skills/ghidra-uefi/scripts/code_artifact.py` | refuses to put a mechanical artifact over a reading; `--review` in phase 5 |
| `Skills/ghidra-uefi/scripts/cas_cli.py` | `gh projects list/purge`, `review list/export`; `review import/diff` in phase 5 |
| `Skills/ghidra-uefi/reference/review.md` | new: the review document's contract |
| `Skills/ghidra-uefi/reference/ghidra.md`, `SKILL.md` | the owner, the bridge, the loop |
| `ByteRipperApp/Pane/CodeAnalysisStore.swift` | report skipped and conflicting keys of a project's bundle |
| Code panel (`Packages/CodeView`, `MainViewController+CodeScreen.swift`) | an open panel reloads when its analysis's manifest changes, keeping the function, the place and the history by address |
| Code screen state (`FragmentPanels.swift`, workspace) | the place is kept by address (`CodeLocation`), not by index — independent of this plan, needed before it |
| `AgentAnnotation.swift`, cards | a code annotation's label is read from the current artifact by address; the stored name is the fallback |

`reading` is an optional manifest field: earlier builds read the manifest and
ignore it, so no store or workspace version changes. The artifact schema does
not change.

## 11. Phase 5 — applying a review

The document is harvested from phase 2 on; what phase 5 adds is using it.

1. **Rebuild a project.** A lost disk, a broken upgrade, a project the pinned
   Ghidra can no longer open, a project purged on purpose: import, analyze,
   apply the stored document.
2. **Move a reading.** Another machine, or CI, that has the dump and the store
   but not the project: `code_artifact.py --review`.
3. **Diff two readings.** `cas_cli.py review diff <module-sha> 2 3`.
4. **Reconcile two projects.** Apply one reading's document to the other
   project, then publish (§5.6).

`ApplyReview.java`:

- refuses a mismatch of `sha256`, `language` or `image_base`;
- applies types, then data, then functions, then comments, each in a
  transaction; is idempotent;
- reports and skips an address the program does not contain, a local whose
  storage it cannot find, or a type the C parser refuses — never an abort;
- writes into a new revision of the same project's reading when applied to a
  rebuild, and into the target project's reading when reconciling.

## 12. Discussion: is a Ghidra "shared project" what we want?

Partly, and later.

### 12.1 Centralising on a powerful machine does not need a shared project

- Put the supervisor and its owners on the powerful machine; the laptop
  connects to the supervisor (§7.4). The agent on the laptop never speaks a
  Ghidra protocol and never sees a path.
- The work that must be on the powerful machine is the JVM and the decompiler,
  which is the owner. The laptop sends rename/comment requests and reads C.
- The artifact and the document come back to the client, which stores them
  where its own app watches. No remote CAS is involved.
- One owner per module in one place is also what keeps two readings of a
  module from forking across machines (§5.6).

### 12.2 What a Ghidra Server would add, and what it costs

- **Adds:** a repository with per-user access control and a version history of
  every check-in. A second person can check a module out into their own
  CodeBrowser.
- **Does not add:** concurrency. Check-out is exclusive per file and the server
  has no editing API; agents still serialize behind one owner.
- **Costs:** another service to install, authenticate, secure and back up; a
  program checked out for an owner's whole life, and still checked out if the
  owner dies, until `svrAdmin` releases it; a new version of a large binary
  file per commit, so check-ins are coarser than publishes.
- With review documents in the store from phase 2, most of the history the
  server would give — what changed between two sessions — is already there,
  readable and diffable.

### 12.3 Recommendation

Defer it to phase 6 and decide then, on one trigger: a second *person* wants a
checkout in their own Ghidra.

## 13. Security

- Loopback by default; the network story is a forward, not a port.
- A non-loopback bind requires a token, an allowlist and a proxy for TLS, on
  the supervisor only.
- A closed operation set; no script execution, no paths, no imports.
- Names and addresses are validated by Ghidra; a name Ghidra would uniquify is
  an error to the client.
- A lease is not a permission model; it prevents accidental interleaving.
  Whoever reaches the bridge can write.
- Every mutation is logged with the session and the lease holder.
- `types[].c` and `POST /v1/type` are parsed by Ghidra's C parser inside a
  transaction; a failure is reported — it is data, not code.

## 14. Phases

Each phase leaves something usable.

0. **Spike.** Confirm the three facts of §3 "To verify": a long-lived headless
   owner that saves mid-session; the modification number's lifetime; the
   identity of a register local across a rename. Compile a minimal owner with
   `javac` against 12.1.2. Half a day to a day; the rest of the plan changes if
   any answer is different.
1. **One owner, reads and export.** `ghidra_owner.py` starts one owner for one
   module on a loopback port; read endpoints; `POST /v1/publish` without
   writes. The client stores the result. An artifact published from an
   unmodified program equals what `code_artifact.py` produces today; the panel
   shows it. No supervisor, no lease yet.
2. **Writes, publish, readings.** Lease; rename function/parameter/local with
   author and reason; signature, comment, data, type with the review type
   archive; save; `HarvestReview`; `reviews/` and documents in bundles (the
   manifest's `reading` and §5.6 already exist); the open Code panel following a republish; the
   place kept by address; `ghidra_review.py` and `ghidra_mcp.py`. The main
   workflow works end to end on one machine.
3. **Supervisor and network.** Pool, routing, eviction by the rules of §6.4,
   token and allowlist, SSH-forward documentation; a second machine's agent
   connected and reviewing.
4. **CodeBrowser host.** The bridge as a GUI plugin. A hand-over is explicit:
   the supervisor asks the headless owner to save and exit, the CodeBrowser
   opens the project under the module's own name (the project is named by SHA;
   the plugin shows the module's name and source), and back the same way. Both
   hosts exercised on one module.
5. **Applying a review** (§11): `ApplyReview.java`, rebuild, `--review`,
   `review import/diff`, reconcile.
6. **Ghidra Server (optional).**
7. **App integration (optional).** "Open in Ghidra" from the Code panel.

## 15. Testing and acceptance

- **Pipeline parity:** an artifact published from an unmodified program equals
  the one `code_artifact.py` produces for the same bytes and recipe.
- **Recipe from provenance:** a project made with one EDK2 tag publishes that
  tag after the installed archives move to another.
- **Review fidelity:** a rename by hand in a CodeBrowser and the same rename
  through the bridge produce the same program state and the same document.
- **Bridge:** a fake owner for client tests; a real owner smoke test on CpuPei
  (13 functions, 508 instructions) and on a DxeCore-sized program; C read again
  after renaming a callee shows the new name.
- **Iteration:** two publishes with renames between them; the second artifact
  carries the new names, has revision n+1 and replaces the first; a publish with
  no change does not raise the revision — within one run and after a restart.
- **Readings (§5.6):** each row of the table, at `putAnalysis` and at bundle
  import, in Python and in Swift; an old project bundle imports its other keys
  and reports the skipped one; two projects of one module conflict and nothing
  is overwritten.
- **Replacement in the store:** after two publishes the key has one manifest
  pointing at the second artifact; after `gc` the first object is gone,
  `verify` is clean, and both documents are still in `reviews/` history.
- **Persistence:** rename, publish, kill the owner, reopen: the names are
  there. Rename, do not publish, kill, reopen: `unpublished: true`.
- **Housekeeping:** over budget, only unreviewed projects are removed; purge
  refuses a reviewed project whose current state is not in a stored document.
- **Leases:** a second writer is refused with holder and expiry; an expired
  lease saves and does not publish; the MCP wrapper publishes and releases on
  exit.
- **App:** an open Code panel reloads after a publish and stays on the same
  function and place; a code annotation's label follows the rename; a saved
  Code screen reopens at the same address after functions were added.
- **No Ghidra in the read path:** with Ghidra stopped and its projects deleted,
  the panel, `code_query.py` and `code_modules` still answer from the
  artifacts.
- **Network:** a non-loopback bind without a token is refused; with the owner on
  another machine, a publish returns the artifact over the wire and the
  client's own store shows it to the app.
- **Phase 5:** applying a document to a fresh project reproduces the names; a
  mismatched `image_base` is refused; a skipped address is reported;
  `--review` reproduces the owner's artifact with no project.

Acceptance for the main workflow (phases 1–2):

- An agent reviews one real module from the Legion dump, renaming functions,
  parameters and locals, and the open Code panel shows those names without
  being reopened.
- The same session publishes at least twice; the panel follows each checkpoint,
  and the second artifact replaces the first.
- Restarting the owner, or the machine, loses no names.
- With Ghidra stopped, the app still shows the code and the names.
- The store holds the session's review documents, and a ByteRipper project
  saved between the two publishes reopens without losing its other analyses.

## 16. Risks and open questions

1. **Ghidra's API is the host.** The owner compiles against one Ghidra version;
   projects survive a bump only as far as Ghidra migrates them. Pin the version
   in the skill; after phase 5 a project Ghidra cannot open is rebuilt from its
   document.
2. **Work since the last publish exists only in the project.** Mitigation:
   save on every lifecycle edge, the wrapper publishes on exit, `unpublished` on
   the next open.
3. **Decompiler cost and memory per owner.** Each owner is a JVM; the pool cap
   (default 2) is a guess until measured on a DxeCore-sized program. The
   supervisor reports per-owner memory and refuses a third heavy one.
4. **Analysis drift.** A project reopened by another Ghidra may find different
   functions; a name can end up on an address that is no longer a function
   start. Ghidra's migration decides; the apply report of phase 5 is where it
   becomes visible.
5. **Name collisions across modules** are legitimate; the review is per
   module. The review type archive (§6.5) is the one cross-module piece, and
   two reviews defining the same type name differently is its open question —
   refused at the second definition for now.
6. **The UEFI types.** Semantic naming is only as good as the types behind it.
7. **A store without the dump.** Artifacts stay readable, but a project cannot
   be rebuilt without the module's bytes. If that becomes an obstacle, a project
   bundle may carry the bytes of the modules it names — not a second copy of
   the firmware beside every analysis.
8. **Where an agent finds the review tools.** A separate MCP server
   (`ghidra_mcp.py`) keeps Ghidra out of the app and works with the app closed;
   the same tools on ByteRipper's own server spare the agent a second
   connection and let it go from a tree node to a rename in one place, but make
   the app a client of the supervisor. The plan builds the separate wrapper;
   whether the app also relays it is decided after phase 2, by how agents use
   it.
9. **Conflicting readings.** §5.6 keeps a second project's reading aside rather
   than choosing. Choosing — or merging by address — is a person's decision, and
   its interface is not designed yet.
10. **A review document that drifts.** Only a harvest writes a document; only a
    publish says it is current; a hand-edited document is a bug.
