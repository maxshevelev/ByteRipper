# A shared Ghidra workbench — long-lived projects, a reviewed reading, a cached artifact

> Status: proposal for review. Nothing described here exists yet.
>
> Русское слово для главного понятия этой записки — **разбор модуля**: то, что
> человек или агент понял о смысле кода и записал в Ghidra — имена, сигнатуры,
> комментарии, типы. Разбор делается только инструментами Ghidra.
>
> The main workflow is: one Ghidra owner per module keeps the project open, an
> agent or a person renames and comments through Ghidra's own APIs, and one
> *publish* saves the program and exports the code artifact that the app reads.
> The review document — a JSON copy of the semantic decisions — is the last
> phase of this plan, not a step in that workflow: it exists to survive the loss
> of a project, to carry a reading to another machine, and to diff two readings.

## 1. Decision in one page

1. **The review is made in Ghidra, with Ghidra's tools.** The project's symbol
   table, function signatures, comments, data names and data types *are* the
   review. A person does it in a CodeBrowser; an agent does it through a bridge
   that calls the same Ghidra APIs. There is no second editing surface and no
   private model of what a name is.
2. **One Ghidra owner per module.** A long-lived headless Ghidra process holds
   the program and serves the bridge. A CodeBrowser is a second host for the same
   endpoints. The supervisor hands out one write lease per module, because a
   Ghidra program is not a multi-writer database.
3. **The project is where the work lives.** Unlike today's one-run temp project,
   the project is kept per module, so a review survives between sessions. It is
   the truth about the module's meaning.
4. **Publishing is the only thing that reaches CAS:** save the program, export
   the artifact, store it, announce it. A rename never writes to CAS. Publishing
   is a checkpoint that repeats through a session, not a finale (§5.5).
5. **CAS is the cache the product reads.** Artifacts, keyed by module SHA +
   recipe, carrying the names the review produced. The app, the Code panel,
   `code_query.py` and agent queries read them; nothing in the read path needs
   Ghidra.
6. **The store does not hold firmware.** The module's bytes come from the dump
   and stay where the dump is; step 0 produces an identity, not a stored copy.
7. **A closed operation set, not a script runner.** The bridge exposes rename,
   comment, signature, type, save, publish — never "run this script" and never a
   filesystem path. That is what makes putting it on a network defensible.
8. **Local by default.** The owner listens on loopback; another machine reaches
   it through an SSH forward or a tailnet. Binding a real interface requires a
   token and is documented as the exception.
9. **No new dependency on GhydraMCP.** It stays the ad-hoc human tool it is; the
   agent-facing contract is our own versioned protocol, because save,
   local-variable rename and export do not exist there.
10. **The review document comes last.** A JSON copy of the decisions, exported
    from the project on request, is the only way to survive a lost or
    unopenable project, to rebuild a reading on another machine, to feed CI, or
    to diff two readings. It is a backup capability, not a stage of the
    workflow, and it is built after the workflow works.

## 2. What is made where

Every stage below produces exactly one kind of thing. Only one of them cannot be
recreated, and that is why the project is kept.

| step | what is being read | who does it | what appears | where it is kept | if it is deleted |
|---|---|---|---|---|---|
| 0. the module | the UEFI tree: which node holds a PE32/TE image | ByteRipper (tree), the skill | the module's **identity**: its SHA-256 and where it came from | nowhere — bytes stay in the dump and in the client's temporary file | the dump is the copy that matters |
| 1. mechanical analysis | the bytes: PE/TE headers, sections, imports | Ghidra's analyzers + `ApplyUefi.java` (EDK2 types, GUIDs, phase signature) | an analyzed *program*: functions, instructions, xrefs, C, strings | project `GhidraProjects/<module-sha>/` | re-run, seconds to a minute |
| 2. the review | the program: what each function, parameter and place *means* | a person in a CodeBrowser, or an agent through the bridge — both calling Ghidra's own APIs | names, signatures, parameter and local names, comments, data names, structs — all inside the project | **the project** | **lost** until the last phase of this plan exists |
| 3. publish | the reviewed program | `ExportCode.java` on the owner, at each checkpoint the client chooses | the JSON everything reads | CAS `analyses/<module-sha>/<recipe>/` | re-publish from the project |

Two conclusions, and they are the whole design:

- **The read path is cache-only.** Step 3 is the cache; the app and
  `code_query.py` are satisfied by it and no Ghidra is involved. Step 0 leaves
  nothing behind.
- **The review is the only irreplaceable thing, and it lives in the project.**
  Until the last phase, losing the projects loses the reading.

**How a review reaches the app.** A rename writes to the project; the artifact
is written by `publish`, at a checkpoint the client chooses, not on every
rename. An export decompiles the whole program, so two hundred renames would
mean two hundred exports; and an artifact published in the middle of a burst of
renames would have the app show names the next rename contradicts. So a session
publishes where it has reached a coherent state, and does so as often as it
likes: save, export, store, announce (§5.4), then read again and continue
(§5.5).

**What is not in this table.** The review document — the JSON copy of the
decisions — is not a stage. Nothing in the workflow needs it, and the app never
sees it. It is described in §11 and built last.

## 3. Facts this design is built on

Verified against Ghidra 12.1.2 on this machine and the installed GhydraMCP
2.2.0-rc.3 extension.

- **A name is a symbol-table entry, not text.** A `CALL` targets an address, and
  Ghidra renders the name from the symbol table when it draws a listing or
  decompiles a caller. Renaming one entry fixes every use in every caller, with
  no re-analysis. But the *decompiled C is regenerated*, which is why a C cache
  has to be invalidated by any mutation, not by function.
- **Ghidra saves all of this with the project.** Symbols, signatures, comments,
  data names and data types are the program's database; saving the program saves
  the review. No side file is needed for Ghidra itself.
- **The artifact is a rendering, not the review.** `ExportCode.java` writes
  functions, signatures, instructions, references, strings, named symbols and C.
  It does not write listing comments, and it does not carry data-type
  definitions. A review cannot be reconstructed from an artifact without
  guessing.
- **`analyzeHeadless -process`** opens an existing program with no analysis —
  the path for re-publishing from a kept project.
- **Shared projects** (`ghidra://host:13100/Repo/RootFolder`, `-connect`,
  `-commit`, `-readOnly`, `-keystore`) exist, and commits are on by default. The
  Ghidra Server gives history and exclusive check-out; it has no editing API. It
  is not a concurrency mechanism (§12).
- **GhydraMCP** serves REST inside a CodeBrowser and has no save, no script
  execution, no local-variable rename and no authentication. Parameters can be
  renamed only by rewriting the signature; locals cannot be renamed at all.
- **`ExportCode.java` already writes `name` and `name_source`** per function, so
  an artifact exported from a reviewed program needs no schema change to carry
  names.
- **The CAS key is the module's own SHA-256**, computed from the bytes at
  extraction. That number is all the store needs to know which module an
  analysis is about.

## 4. Architecture

```
      agents (MCP wrapper)     skill / CLI (Python)      app (later)
            \                       |                       /
             \                      v                      /
              +------ Ghidra owner supervisor -------------+
              |    Unix socket: pool, leases, routing      |
              |                                            |
              |   one owner per open module                |
              |   +------------------------------------+   |
              |   | Ghidra — headless or CodeBrowser    |  |
              |   |   project: GhidraProjects/<sha>/    |  |
              |   |   the review lives here             |  |
              |   |   bridge: /v1 (Ghidra APIs only)    |  |
              |   +------------------------------------+   |
              +----------------------+---------------------+
                                     | publish
                                     v
                       CAS analyses/<sha>/<recipe>/  (cache)
                                     |
                                     v
                             app, code_query, agents

      later, dashed: project --.review.json--> another machine, CI, git
```

## 5. The stages in detail

### 5.1 Step 0 — the module's identity

- The UEFI tree names the node; `byteripper_extract.py` fetches its bytes in
  4 KiB pages from the app and writes them to a temporary file.
- The only lasting result is the hash of those bytes and the provenance they
  came with (`source.document`, `source.node`). Both are already what the store
  keys and records today.
- **Nothing is written to the store here.** Decompilation has not happened, so
  there is no analysis to store, and the bytes are the dump's, not the store's:
  keeping a second copy would make the store a firmware library and invite it
  to go stale against the dump.

### 5.2 Step 1 — mechanical analysis, no meaning yet

- Import (TE converted to PE first), Ghidra's analyzers, then `ApplyUefi.java`:
  EDK2 types, GUID names, the PEI/DXE entry signature, and function names
  recovered from the module's own `DEBUG` strings.
- Result: a program in a project under
  `~/Library/Application Support/ByteRipper/GhidraProjects/<module-sha>/`.
- This step is deterministic enough to repeat, but **not free**: a DxeCore-sized
  module takes tens of seconds. That is why the project is kept.

### 5.3 Step 2 — the review

This is where meaning is made, and it is made **in Ghidra**, through the same
operations a person would use:

| the decision | Ghidra operation | seen by |
|---|---|---|
| a function's name | `SymbolTable.rename` on the function symbol | listing, decompiled callers, xrefs |
| a parameter's or local's name and type | `Function` variable APIs (`HighFunction` for locals) | decompiled C |
| a function's signature | `Function.setSignature` | decompiled C, callers' casts |
| a comment | listing comments (pre, post, eol, plate, repeatable) | listing; plate comments in C |
| a datum's name or type | `Data`/`Listing` APIs | C, disassembly |
| a structure or enum | `DataTypeManager` with C source | everywhere the type is used |

- The bridge is a **remote control for those APIs**, not an editor of its own:
  it opens a Ghidra transaction per change, lets Ghidra validate the name, and
  returns Ghidra's answer. A rename that Ghidra would silently disambiguate
  (`Foo` → `Foo_1`) is an error to the client, not a surprise in the C.
- A person may do the same in a CodeBrowser with Ghidra's dialogs while the
  owner is that CodeBrowser. Same state, same result; the agent's edits are the
  person's edits.
- **Nothing leaves the project here.** A rename changes the program; the app
  still shows the previous artifact until the session publishes.
- Changes live in the program until `save`. The owner saves on publish, on
  releasing a lease, on idle exit and before eviction — not after every rename,
  because a program save writes the database.

### 5.4 Step 3 — publish: what puts the review into CAS

One action, repeatable through a session:

```
save the program  →  export the artifact  →  hand it to the client
                                                     │
                               the client stores it in the CAS it reads from
                                                     │
                                       that store announces the change
```

- `POST /v1/publish` on the bridge, and one command for a person.
- **The owner owns no store.** It saves, exports and returns the artifact; the
  *client* writes it into the store the reader watches — the one the app already
  follows with FSEvents. On one machine that is the same store either way; with
  the owner on a powerful machine and the client on a laptop it is the only
  arrangement that puts the artifact where the panel can see it without a remote
  CAS standing in between (§12). It also keeps the owner free of store layout,
  and keeps one writer per store — the client library, until the CAS service
  takes over.
- **Triggers:** any checkpoint the client chooses, the lease being released, and
  the owner's idle or evict path when the project is dirty. Never a rename:
  publishing decompiles the whole program, and a half-reviewed module must not
  reach the app.
- **While a session runs, readers keep seeing the previous artifact.** The app
  never presents a module mid-rename, and a second agent reading the artifact
  during someone else's session reads a coherent reading.
- **The recipe does not change; the artifact does.** A recipe names *how* an
  artifact was produced — exporter version, Ghidra version, the EDK2 type
  archive (`code-v4-ghidra-12.1.2`) — not what it says. A second reading of the
  same module by the same tooling is the same recipe, so publish rewrites the
  manifest under the same key to point at a new artifact. There is one current
  reading of a module, and the app should never have to choose between two.
- **Objects are never overwritten.** The new artifact is written as
  `objects/<new sha>`; the manifest is replaced atomically; the previous object
  becomes unreferenced and stays on disk until garbage collection. A crash
  between the two leaves an unreferenced object, never a manifest pointing at a
  missing one.
- **The guard stays.** `putAnalysis` refuses a same-key, different-artifact
  write unless the caller says replace (`ContentStore.swift:104`,
  `cas.py:168` — today only `--force` does). Publish is the one caller allowed
  to replace routinely, and only within the recipe it was told to use.
- **A changed tool is a changed recipe.** A new exporter or a new Ghidra
  version produces `code-v5-ghidra-13.0` beside the old analysis, as it does
  today; readers pick the recipe they understand. So: another reading →
  replace inside the recipe; another tool → a new recipe beside it.
- **Keeping the previous reading** is not what refs do — they name analyses, not
  artifact versions, so a publish moves the ref's target with it. If a "before"
  has to survive, export it as a bundle (which copies the manifest and the
  object) or give it a distinct recipe.
- **If publishing fails halfway** — save done, export failed — or the client
  dies before storing, the project is ahead of the cache. That is the normal
  direction: the project is the truth. The owner records the last good
  artifact's SHA in the project's own `state.json`, reports "unpublished
  changes", and the next publish is idempotent because `ExportCode` is
  deterministic on an unchanged program.
- **Cost:** one `-process -noanalysis` run over a kept project — seconds, no
  analysis. With a remote owner the artifact also crosses the network: a few
  hundred kilobytes for a PEIM, up to the size of a DxeCore artifact (about
  8 MB).

The store therefore sees exactly one kind of mutation in the workflow: a
manifest is rewritten. That is what `Design/CAS_SERVICE_PLAN.md` calls
`putAnalysis` with replacement, and it is the operation the service must make
atomic first.

### 5.5 The loop: 2 ↔ 3

The review is not one pass. The usual shape is: read a function, name it, follow
its callees, publish, re-read the callers in the artifact to see whether the new
name reads correctly there, go back, rename more, publish again.

```
        ┌───────────────┐
        │  2. review    │◄──────────────┐
        │  (the program)│               │
        └───────┬───────┘               │
                │ publish               │ read again, changed
                v                       │ something, continue
        ┌───────────────┐               │
        │  3. publish   │───────────────┘
        │  (the cache)  │
        └───────────────┘
```

- **Publish is a checkpoint, not a finale.** Any number per session. The rule is
  "at a checkpoint, not on every rename", not "once".
- **Publishing an unchanged program is a no-op.** The owner compares the
  program's modification counter with the last publish and returns the existing
  artifact without exporting, so a client may call publish liberally.
- **After a publish the client chooses where to read.** The live program
  (`/v1/function/{address}`) is fresh and authoritative and ahead of the cache
  while a session runs; the artifact is the whole module, consistent, and
  exactly what the app shows. They agree at the publish point and drift between
  checkpoints, which is the intended direction.
- **Every publish announces itself**, so the app follows each checkpoint: a
  person watching sees the names improve, and a second agent reading the
  artifact never sees a half-renamed module.
- **Nothing about the loop is scripted.** The client exposes the primitives and
  the agent decides when to stop. A fixed sequence — read N functions, rename,
  publish, done — would fight the work, which jumps by xrefs and revisits.
- **What iteration costs.** A whole-program export is seconds for a PEIM and
  tens of seconds for a DxeCore-sized module. If checkpoints on large modules
  become painful, the answer is an incremental export — only functions whose
  decompilation changed, merged into the previous artifact — with its own merge
  rules. That is a later optimisation, not part of this plan.

The table of what holds which part of the loop together:

| the thing | what enforces it |
|---|---|
| the order of steps | the agent or the person; the documentation describes a loop, not a script |
| the right to write | the lease, one per module, in the supervisor |
| one change is all-or-nothing | a Ghidra transaction per mutation |
| the review is not lost | save on publish, on lease release, on idle exit and before eviction |
| what the app sees | the last publish; a change event after each one |
| a repeat publish costs nothing | the modification counter, checked before exporting |
| the work outlives the session | the project; from phase 5, the review document as well |

### 5.6 The batch path, for a machine with no owner

`code_artifact.py <module>` already does import → analysis → `ApplyUefi` →
`ExportCode` in one headless process and writes the same artifact. It stays the
CI and scripted path, and it needs no supervisor and no project. Applied to a
module that was reviewed elsewhere, it produces an artifact with Ghidra's names,
because the review itself lives only in that project — carrying a reading
between machines is what the last phase (§11) adds.

## 6. The owner

### 6.1 What it is

A Ghidra process with exactly one program open, serving the bridge. Two hosts,
one implementation:

- **Headless host (default).** A small Java entry point in the extension opens
  the project with Ghidra's headless launcher and starts the HTTP server; the
  JVM stays up until stopped. No window server, so launchd can own it.
- **CodeBrowser host (optional).** The same extension loaded in the GUI, the
  same endpoints served from the running tool. A person watches, undoes with
  Ctrl-Z, and can take over.

PyGhidra would be the obvious third option and is present in 12.1.2, but it
needs JPype and a Python whose wheels exist; this machine has only 3.14 and no
JPype. The Java host is the one that works without that argument, and it is the
same code in both hosts.

### 6.2 The project

- One project per module, named by SHA, under
  `~/Library/Application Support/ByteRipper/GhidraProjects/<module-sha>/`.
  Two dumps with the same module share it; a changed module gets a new one.
- Created on first open: import, analyze, `ApplyUefi`, and — from the last phase
  on — apply a review document if one exists.
- **Where the bytes come from:** the client that asks for the open supplies
  them — it has just extracted them from its dump — or the supervisor fetches
  them through the app's relay by `source.document`/`source.node`. The owner
  verifies the SHA-256 and refuses a mismatch. There is no third source: the
  store is not a firmware library.
- A project is exclusive to one process; the supervisor enforces it and Ghidra's
  lock is the backstop.
- **Never evicted dirty.** Eviction and purge save first, and a project that
  cannot be saved is not removed. With no review document yet, a project is the
  only copy of its reading; that is the reason for the rule.
- `state.json` in the project directory is bookkeeping, not a record: the time
  of the last publish and the artifact's SHA, so the owner can say "unpublished
  changes" when the program was saved later than that.

### 6.3 Pool and lifecycle

- At most N owners (default 2; each JVM costs a few hundred MB plus decompiler
  structures). LRU eviction saves first, then exits.
- Start on demand: the first request starts an owner; progress (import,
  analysis) is reported over a status endpoint.
- Idle exit after a timeout: save, and publish if the project is dirty and a
  session held its lease.
- A crashed owner is detected by the supervisor and restarted on the next
  request; the project keeps whatever was saved, and `state.json` shows whether
  the cache is behind it.

### 6.4 Who creates a project, where it lives, and what points to it

**Who.** Nobody by hand. A client asks the supervisor to open a module; if that
module has no project, the supervisor starts an owner, and the owner imports,
analyzes and saves it. The supervisor's own operations are small:

```
POST /open    { module: <sha256>, bytes?: <blob> | source?: { document, node } }
              -> { owner: <endpoint>, state: opening | ready, progress }
GET  /status  -> owners, modules, leases, disk use
POST /lease   { module, ttl } -> { token, expires }
DEL  /lease   { token }
POST /close   { module } -> saved, evicted
GET  /projects -> what exists, size, last used, dirty or not
```

The vocabulary is the module's SHA-256. Turning a UEFI tree node into that SHA
is the client's job — `uefi_node_data` through the app's relay, then a hash —
and the answer is remembered in the analysis's `source`. A UEFI node id means
nothing to an owner, and a path means nothing after the dump moves.

**Where.** `~/Library/Application Support/ByteRipper/GhidraProjects/<module-sha>/`
— one Ghidra project per module, inside the directory Ghidra's launcher is
pointed at, plus the owner's `state.json`. Not in `~/Library/Caches`: until
phase 5 a project is the only copy of a reading, so it belongs where the rest of
the app's durable data is and is carried by a normal backup. Not inside the CAS
store either: it is large, binary, exclusive to one process and not
content-addressed.

Disk is the real constraint. A program database is single-digit to tens of
megabytes; one dump's modules can reach several gigabytes. So: a budget
(default 20 GB), LRU eviction that saves first and never evicts a dirty project,
`cas_cli.py gh projects list` with sizes and last use, and `gh projects purge
--older-than` printing what it would free before it frees it.

When the owner runs on another machine, this whole tree is remote: the client
never sees a path, only the module's SHA and the supervisor's endpoint (§12.1).
That is the deployment "review on the powerful machine, work from the laptop".

**What points to it.** Nothing by path, and the workspace does not change.

- The module's **SHA-256 is the whole link**. The same module in another dump,
  or at another node of the same dump, resolves to the same project, the same
  analysis and the same review.
- An analysis manifest records `source.document` and `source.node` as a *hint*
  for the badge — which file and which row the bytes came from. It is not a key,
  and a moved or renamed dump only costs a refreshed hint.
- A **ByteRipper workspace/project knows nothing about Ghidra** and gains no
  field: it opens files, and the Code panel shows a badge on rows named by
  analyses whose `source.document` is the open file. There is no path in the
  workspace to go stale, and no workspace format change.
- What travels between machines is the **bundle**, not the project: a project
  bundle already carries analyses, and from phase 5 it can carry review
  documents. A Ghidra project is machine-specific and stays behind; it is
  rebuilt from the dump's bytes and the document.

The app's later "Open in Ghidra" command (phase 7) adds nothing to this: it
takes the focused document and node, asks the supervisor to `open` that module,
and raises the panel when the owner reports `ready`.

## 7. The bridge

### 7.1 Protocol

JSON over HTTP, versioned in the path (`/v1/…`). Every response carries the
program identity (module SHA, language, image base), the last published
artifact and the project path.

Reads:

| call | answer |
|---|---|
| `GET /v1/hello` | protocol, Ghidra version, program identity, published artifact, dirty flag |
| `GET /v1/functions` | entries, names, sizes, signatures (paged) |
| `GET /v1/function/{address}` | signature, parameters and locals with storage and types, decompiled C |
| `GET /v1/disassembly/{address}` | instructions with bytes and references |
| `GET /v1/xrefs?to=/from=` | reference list |
| `GET /v1/data`, `GET /v1/strings` | data items and strings |

Writes (each requires `lease`):

| call | Ghidra operation |
|---|---|
| `POST /v1/rename/function` | `{address, name}` → symbol rename |
| `POST /v1/rename/variable` | `{function, storage, name, type?}` → parameter or local |
| `POST /v1/set/signature` | `{address, signature}` |
| `POST /v1/set/comment` | `{address, kind, text}` |
| `POST /v1/set/data` | `{address, name, type}` |
| `POST /v1/type` | `{name, c}` → `DataTypeManager` |
| `POST /v1/save` | save the program into the project |
| `POST /v1/export` | run `ExportCode.java`, return the artifact |
| `POST /v1/publish` | save, export and return the artifact for the client to store — a checkpoint (§5.4) |

Deliberately absent: script execution, file paths, project management, analysis
options. A client may ask what the code is; it may not ask the owner to do
something we have not defined.

### 7.2 Reading C

- Decompilation is cached per function in the owner, keyed by function entry
  plus the program's modification counter, so a rename invalidates exactly what
  it must — including the callers of the renamed function, whose C contains the
  callee's name.
- The bridge returns the same C `ExportCode.java` would write. Bulk reading
  belongs to the artifact; the bridge is for the loop.

### 7.3 Leases

- `POST /v1/lease {module, ttl}` → `{token, expires}`. One live write lease per
  module; a second is refused with the holder and expiry rather than blocking
  forever.
- Renewal is explicit. A lease that expires while the owner has unsaved edits
  saves them; a later publish can follow.
- Reads need no lease; many agents may read one module at once.
- The lease holder is recorded in the owner's log beside every mutation.

### 7.4 Transport and network

- A Unix domain socket under `~/Library/Application Support/ByteRipper/Ghidra/`
  for local clients, plus a loopback HTTP port for clients that speak only HTTP
  (the MCP wrapper).
- Another machine gets in through an SSH forward
  (`ssh -L 8765:127.0.0.1:8765`) or a tailnet address. That is the documented
  default and needs no new auth surface. It is also the whole of the
  "powerful machine, laptop client" deployment: the supervisor runs there, the
  laptop forwards to it, and nothing else changes (§12.1).
- A non-loopback bind is an explicit option that refuses to start without a
  token file (0600) and a client allowlist; TLS is expected at a proxy. An
  unauthenticated port that can rename every function in a project is not a
  configuration we ship.
- The supervisor listens on the network, never the owner; the owner binds
  loopback only. One choke point for auth, rate limits and logs.

### 7.5 Who talks to it

- **Agents:** a thin MCP wrapper (`Skills/ghidra-uefi/scripts/ghidra_mcp.py`,
  stdlib) translating tool calls to `/v1`, so the MCP surface stays ours and the
  skill's Python can call the same REST.
- **The skill:** `ghidra_review.py` drives a session — lease, rename, comment,
  publish; `code_query.py` keeps reading artifacts, with `--live` as the escape
  hatch to the bridge.
- **The app:** later, and only for "open this module in Ghidra".

## 8. A session, end to end

```
open       code_modules → module SHA → POST /v1/lease
survey     artifact (fast, whole module): functions, callers, strings
read       /v1/function/{address} — C is fresh, names are current
decide     rename function, params, locals; set signature; comment; add a struct
publish    /v1/publish → save, export, store, announce
           ┌───────────────────────────────────────────────┐
read again │ artifact or live program: do the names read   │
           │ correctly in the callers? what is unexplained? │
           └───────────────────┬───────────────────────────┘
                               └──► decide again, publish again, as often as needed
release    lease ends; the badge and the panel show the last published names
```

- A second agent reading the artifact during the session sees the previous
  reading — coherent, just older.
- A session that dies before publishing leaves the project ahead of the cache;
  the owner reports `unpublished changes` and the next session publishes.

## 9. Storage layout

```
analyses/<module-sha>/<recipe>/manifest.json      the artifact cache
GhidraProjects/<module-sha>/                      program + review + state.json
reviews/<module-sha>/                             only from the last phase (§11)
```

- The store holds **artifacts**: what the product reads. That is its whole
  content in the workflow. Firmware bytes are not there, and neither is the
  review.
- A project lives beside the store, not in it: it is big, binary, exclusive to
  one process, and not content-addressed.
- One writer per store: the client library that already writes analyses
  (`Skills/ghidra-uefi/scripts/cas.py`) until the CAS service exists
  (`Design/CAS_SERVICE_PLAN.md`). The owner has no store — it returns the
  artifact and the client stores it (§5.4). Swift reads; it does not write.

## 10. What changes in the repository

| path | change |
|---|---|
| `Skills/ghidra-uefi/extension/` | new: the Java extension — bridge endpoints, headless host entry point, `buildExtension` wiring |
| `Skills/ghidra-uefi/scripts/ghidra_service.py` | new: supervisor — pool, leases, auth for network mode, routing |
| `Skills/ghidra-uefi/scripts/ghidra_review.py` | new: a review session client (lease, rename, comment, publish) |
| `Skills/ghidra-uefi/scripts/ghidra_mcp.py` | new: MCP wrapper over `/v1` |
| `Skills/ghidra-uefi/scripts/code_artifact.py` | unchanged in the workflow; `--review` arrives with §11 |
| `Skills/ghidra-uefi/scripts/cas_cli.py` | `gh status/stop/purge`, `review export/import` with §11 |
| `Skills/ghidra-uefi/reference/review.md` | new, with §11: the review document's contract |
| `Skills/ghidra-uefi/reference/ghidra.md` | the owner, the bridge, the shared-project mode |
| `Skills/ghidra-uefi/SKILL.md` | the new pieces in the table |

Not changed: the artifact reader model in `Packages/CodeAnalysis`, the Code
panel, and the artifact schema. The workflow adds no field to a manifest.

## 11. The review document — backup, added last

Nothing above needs it. It is built after the workflow works, and it exists for
four jobs the project cannot do:

1. **Survive the project.** A lost disk, a broken upgrade, a project Ghidra can
   no longer open.
2. **Move a reading.** Another machine, or CI, that has the dump but not the
   project.
3. **Diff two readings.** What changed between session 2 and session 3 of the
   same module.
4. **Travel in a bundle.** A project bundle carries analyses; a reading should
   travel with them.

### 11.1 What it is

A JSON document per module, exported from the project by `HarvestReview.java`
and applied to a project by `ApplyReview.java`. It holds semantic decisions
only — no code, no bytes, no instructions:

```json
{
  "schema": 1,
  "module": { "sha256": "9c1f…", "name": "AmdSocFp6CznPei", "kind": "TE",
              "language": "x86:LE:32:default", "image_base": "0x0" },
  "made_with": { "ghidra": "12.1.2", "exporter": 4, "types": "edk2-…" },
  "rev": 3,
  "meta": { "author": "agent", "time": "2026-10-26T12:00:00Z" },
  "functions": {
    "0x9a889ee": {
      "name": "AgesaAssert",
      "signature": "void AgesaAssert(UINT32 Code)",
      "params": [ { "ordinal": 0, "name": "Code", "type": "UINT32" } ],
      "note": "Never returns. Emits 0xDEAD on port 0xE0, then loops on 0x80."
    }
  },
  "locals":   { "0x9a889ee": { "Stack[-0x18]": { "name": "PciLength", "type": "UINT64" } } },
  "comments": [ { "address": "0x9a89030", "kind": "pre", "text": "AbovePcieCfgIsTooSmall" } ],
  "data":     { "0xdf360930": { "name": "gAgesaStatus", "type": "UINT32" } },
  "types":    [ { "name": "AMD_CONFIG_PARAMS", "c": "typedef struct { … }" } ]
}
```

Rules:

- **Keyed by address, never by an old name.** `FUN_0009a889ee` stops existing the
  moment it is renamed; its address does not.
- **Locals keyed by storage** (`Stack[-0x18]`, `EAX:4`), the identifier Ghidra
  keeps stable for a local across renames; parameters also carry their ordinal,
  because a signature change can move storage.
- **It is an export, not an editing format.** A hand edit would disagree with
  the project, and the next export would silently undo it. The only writer is
  `HarvestReview.java`.
- **Applying is idempotent and refuses on a mismatch** of `sha256`, `language`
  or `image_base`; an address the program does not contain is reported and
  skipped, never an abort. Types go first, then data, then functions, then
  comments, each in a transaction.

### 11.2 Where it goes

```
objects/<sha256 of the document>        revisions, content-addressed
reviews/<module-sha>/manifest.json      { current: {rev, sha256}, history: [...] }
analyses/…/manifest.json                gains "review": { rev, sha256 }
.review.json                            the same document as a file, for git or a bundle
```

The manifest's `review` field is what lets a reader tell which reading produced
an artifact — and, after this phase, what makes an artifact rebuildable on a
machine that has only the dump and the store.

### 11.3 What it enables and what it does not

- **Enables:** `code_artifact.py --review` (bytes + document → artifact, no
  project), `cas_cli.py review diff <sha> 2 3`, export/import, a bundle that
  carries a reading.
- **Does not:** become a second way to edit. The Ghidra project stays the only
  place a review is made.
- **Does not** make the app depend on it. The app still reads only artifacts.

## 12. Discussion: is a Ghidra "shared project" what we want?

Partly, and later. The question comes in two parts, and only the second is about
the Ghidra Server.

### 12.1 Centralising on a powerful machine does not need a shared project

- Put the supervisor and its owners on the powerful machine and let the laptop
  connect to the supervisor (§7.4). Projects are plain directories there
  (`GhidraProjects/<module-sha>/`); the agent on the laptop never speaks a Ghidra
  protocol, never sees a path, and never has to know where the work happens.
- The work that must be on the powerful machine is the JVM and the decompiler —
  and that is exactly the owner. The laptop only sends rename/comment requests
  and reads C.
- The artifact goes back to the client, which stores it where its own app
  watches (§5.4). So centralisation needs **no** remote CAS either, only a
  network path to the supervisor.
- This is phase 3, not a later idea: it is what "the agent works remotely" means
  in this plan.

### 12.2 What a Ghidra Server would add, and what it costs

- **Adds:** a repository on the server with per-user access control, and a
  version history of every check-in. A second person can check a module out into
  their own CodeBrowser on their own machine, and a bad session is one check-out
  away from being undone.
- **Does not add:** concurrency. The check-out is exclusive per file and the
  server has no editing API, so ten agents still serialize behind one owner; the
  server only records what they did.
- **Costs:** another service to install, authenticate (per user, never
  anonymous), secure and back up; a program database that stays checked out for
  the whole life of an owner, and stays checked out if that owner dies, until
  `svrAdmin` releases it; and a new version of a large binary file per commit,
  which forces a coarser save cadence than the publish cadence (one check-in at
  the end of a session, publishes as often as the review needs).
- **Unchanged:** the owner still needs its own project handle and its own lease;
  the server sits underneath the project cache, not in front of it. Enabling it
  is `-connect` / `-commit` plus `-keystore`, not a redesign.

### 12.3 Recommendation

Defer it to phase 6 and decide then, on two triggers: a second *person* wants a
checkout in their own Ghidra, or the project history has to be auditable. Until
then, "centralised" means "the supervisor runs on the powerful machine", which
needs nothing new.

## 13. Security

- Loopback by default; the network story is a forward, not a port.
- A non-loopback bind requires a token, an allowlist and a proxy for TLS.
- A closed operation set; no script execution, no arbitrary paths, no imports.
- Addresses and names are validated by Ghidra before they land; a name Ghidra
  would uniquify is an error to the client.
- A lease is not a permission model. Whoever reaches the bridge can write; the
  lease only prevents accidental interleaving.
- Every mutation is logged with the session and the lease holder, so a wrong
  name can be traced to its author.
- With §11: a document's `types[].c` is parsed by Ghidra's C parser inside a
  transaction, and a failure is reported — it is data, not code.

## 14. Phases

The workflow first, in four steps that each leave something usable; the review
document after it; the two optional pieces last.

1. **Owner and reads.** Extension skeleton, headless host, supervisor, project
   cache, the read endpoints, and `POST /v1/export` writing an artifact into
   CAS. No edits yet: an artifact published from an unmodified program must
   match what `code_artifact.py` produces today, and the panel must show it.
2. **Writes and publish.** Lease, rename function/parameter/local, signature,
   comment, data, type, save, `POST /v1/publish`. The main workflow now works end
   to end on one machine, and its loop does too: an agent reviews a module,
   publishes a checkpoint, reads again, renames more and publishes again; the app
   shows the last published names.
3. **Network.** Token and allowlist on the supervisor, SSH-forward
   documentation, `ghidra_mcp.py`, a second machine's agent connected and
   reviewing.
4. **CodeBrowser host.** The same extension in the GUI so a person can watch,
   undo and take over; both hosts exercised on one module.
5. **Review document (backup).** `HarvestReview.java`, `ApplyReview.java`,
   `reviews/` in the store, the manifest field, `code_artifact.py --review`,
   `cas_cli.py review export/import/diff`, `.review.json` in a bundle. Nothing
   built before this depends on it.
6. **Ghidra Server (optional).** Shared repository behind the project cache,
   per-user auth, check-in messages naming the session.
7. **App integration (optional).** "Open in Ghidra" from the Code panel.

## 15. Testing and acceptance

- **Pipeline parity:** an artifact published by the owner from an unmodified
  program equals the one `code_artifact.py` produces for the same bytes and
  recipe, modulo timestamps.
- **Review fidelity:** rename a function in a CodeBrowser by hand and publish;
  an agent renaming through the bridge produces the same program state. Same
  state, same result — the bridge calls Ghidra, it does not imitate it.
- **Bridge:** a fake owner for client tests; a real owner smoke test on CpuPei
  (13 functions, 508 instructions) and on a DxeCore-sized program; C cache
  invalidated after renaming a callee.
- **Iteration:** two publishes in one session, with more renames between them;
  the second artifact carries the new names and replaces the first; a publish
  with no change in between does not export at all and leaves the artifact
  untouched.
- **Replacement in the store:** after two publishes the key has one manifest,
  pointing at the second artifact; two objects exist until `gc`; after `gc` the
  first object is gone, `verify` is clean and the manifest still resolves.
- **Persistence:** rename, publish, kill the owner, reopen the module, and the
  names are still there; rename, do not publish, kill the owner, reopen, and the
  project reports `unpublished changes`.
- **Eviction:** a dirty project is saved before eviction and never removed
  unsaved.
- **Leases:** a second writer is refused with holder and expiry; an expired
  lease saves; a crashed owner is restarted on the next request.
- **No Ghidra in the read path:** with Ghidra stopped and its projects deleted,
  the panel, `code_query.py` and `code_modules` still answer from the artifacts.
- **Network:** without a token, a non-loopback bind is refused; loopback needs
  none; the MCP wrapper survives a restart. With the owner on another machine,
  a publish returns the artifact over the wire and the client's own store shows
  it to the app — no server-side store is involved.
- **Last phase only:** a document round-trips; applying it to a fresh project
  reproduces the names; a mismatched `image_base` is refused; a skipped address
  is reported; `--review` reproduces the owner's artifact with no project.

Acceptance for the main workflow (phases 1–2):

- An agent reviews one real module from the Legion dump, renaming functions,
  parameters and locals, and the Code panel shows those names without a restart.
- The same session publishes at least twice; the panel follows each checkpoint,
  and the second artifact replaces the first rather than sitting beside it.
- Restarting the owner, or the machine, does not lose the names.
- With Ghidra stopped, the app still shows the code and the names.
- No `reviews/` directory exists: the workflow needs no review document.

## 16. Risks and open questions

1. **Ghidra's API is the host.** The extension compiles against one Ghidra
   version; artifacts and projects survive a bump only as far as Ghidra migrates
   them. Pin the version in the skill and treat the extension as the thing to
   rebuild when Ghidra moves.
2. **Until phase 5, the project is the only copy of the review.** Accepted for
   now: it is the fastest route to a working loop, and the document is the answer
   for anyone who needs insurance sooner. The risk to state plainly is a disk
   failure or a Ghidra upgrade that cannot open the project.
3. **Unpublished work is the sharp edge of the workflow.** A session that ends
   without publishing leaves the cache older than the project. Mitigations:
   publish on lease release, on idle exit and on eviction; report
   `unpublished changes` on the next open. Open question: should the owner
   publish automatically on lease release, or only when asked? The
   recommendation is automatically — the app reading a stale artifact is a
   worse default than an extra export.
4. **Decompiler cost and memory per owner.** Each owner is a JVM; the pool cap is
   a guess until measured on a DxeCore-sized program. The supervisor must report
   per-owner memory and refuse a third heavy one.
5. **Analysis drift.** A project made by one Ghidra version and reopened by
   another may discover different functions; a name can end up on an address
   that is no longer a function start. Ghidra's own migration decides this, and
   §11's apply-report is the only place it becomes visible.
6. **Name collisions across modules.** Two modules may legitimately name two
   different functions `AgesaAssert`. The review is per module; a cross-module
   view is out of scope.
7. **The UEFI types.** Semantic naming is only as good as the types behind it. A
   module analyzed without `ApplyUefi` gets names but no structure.
8. **MCP surface.** One tool per operation or a few coarse tools
   (`review_code`, `rename`, `annotate`) changes how an agent is prompted, not
   what is possible.
9. **One machine, one user.** This design assumes the owner runs where the store
   is. A remote owner works over the same REST, but cache and store then live
   apart and the publish path has to cross the network. Out of scope; the
   protocol does not prevent it.
10. **A store without the dump.** Artifacts stay readable forever, but a new
    artifact cannot be exported and a project cannot be rebuilt unless the dump
    that holds the module is at hand. If that becomes an obstacle, the answer is
    a project bundle carrying the bytes for the modules it names — not a second
    copy of the firmware beside every analysis.
11. **A review document that drifts.** Once phase 5 exists, two representations
    of one reading exist: the project and the document. The rule that keeps them
    from fighting is that only a harvest writes the document and only a publish
    claims it is current. A hand-edited document is a bug, not a feature.
