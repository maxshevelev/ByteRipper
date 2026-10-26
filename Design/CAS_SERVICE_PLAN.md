# CAS — one store, one implementation, many clients

> Status: phases 1–3 are done (§6). The rest is later, and each later phase
> starts from a need named in §6, not from this document.
>
> This document replaces the earlier proposal of a separate CAS daemon in Go or
> Rust with its own socket protocol. That proposal solved a real problem — the
> store implemented twice, in Swift and in Python, and the two drifting — with
> a new language, a second signed executable, a service lifecycle and a remote
> protocol for a product that has one user and one machine per store. The
> problem is solved here with less: one implementation, in the language the app
> is written in, run as a command line by everything that is not the app.

## 1. Decision in one page

1. **One implementation of the store: `ContentStore` in
   `Packages/CodeAnalysis`.** Objects, analyses, references, collection,
   bundles and the rule for which artifact replaces which are written once, in
   Swift. The app links it.
2. **A command line, not a daemon.** `byteripper-cas` — an executable target of
   the same package — is `ContentStore` behind a JSON command set
   (`CASCommand`). The skill's Python (`scripts/cas.py`) is its client and
   holds no store logic. There is no process to start, discover, keep alive or
   upgrade; each command is one process that takes the store's `flock` for as
   long as it writes.
3. **The change feed is the file system.** The app follows `analyses/` with
   FSEvents (`CodeStoreWatcher`); a slow fallback poll (30 s) and a refresh on
   app activation and system wake cover what FSEvents misses. Any writer —
   the tool, a project import — is seen within a fraction of a second. No
   writer has to announce anything.
4. **Readings decide replacement.** A manifest may name the reviewed Ghidra
   project and revision that produced its artifact (`reading`,
   `Design/GHIDRA_SHARED_PLAN.md` §5.6). A newer reading replaces an older one;
   a mechanical run never replaces a reading unless told to; another project's
   reading is kept aside under `conflicts/`. The same rule holds at a put and
   at a bundle import.
5. **The store's layout and its manifests stay as they were.** Every store and
   bundle written before still reads; the new fields are optional, and an
   older build ignores them.
6. **A service comes when something needs a store it cannot open as a
   directory** — a remote store, or the Electron shell on Windows (§5). It
   would expose the same command set over a socket and keep `ContentStore` as
   its file backend. Nothing in the clients' model changes when it arrives.
7. **ByteRipperWeb gets no CAS by default.** The browser edition stays static,
   with no backend, no install, and files that never leave the machine (§5.2).

## 2. Why not a daemon, now

- **The race the daemon was to prevent did not exist.** Swift and Python
  already took the same `flock` and wrote atomically. The real problems were
  that one semantics lived in two places and drifted (the Swift manifest model
  dropped `recipe.types`, `recipe.passes` and `module.phase` that Python wrote;
  a rebind through Swift would have erased them), and that the app polled.
- **A second executable costs more than it looks.** The macOS release is
  ad-hoc signed; a sidecar binary is one more thing for quarantine and
  Gatekeeper to stop, one more thing to version against the app, and one more
  lifecycle to get right (start-on-demand, duplicate starts, idle exit, crash).
- **A new language is a second toolchain** in a project whose rule is "no
  third-party dependencies", for a service whose first deployment is one user
  on one Mac.
- **A command line answers the same need.** One implementation, one writer
  semantics, JSON answers, no base64 for large artifacts (they pass as files),
  and a process the skill can run headless in CI on a Mac.

## 3. Architecture

```
       app (links ContentStore)                skill / CLI / CI
                 │                                    │
                 │                     cas.py ──► byteripper-cas (CASCommand)
                 │                                    │
                 └──────────► ContentStore ◄──────────┘
                                   │  flock, atomic writes
                                   ▼
             ~/Library/Application Support/ByteRipper/Analysis/
                                   │
                         FSEvents ─┴─► the app's badges and Code panel
```

### 3.1 The command set

```
byteripper-cas [--store <root>] [--no-create] <command>
  hello                                   protocol, schema, store root
  put-object <file>                       { sha256, size }
  has-object <sha256>                     { present }
  get-object <sha256> [--out <file>]      the bytes, or { sha256, size }
  put-analysis --module <json> --recipe <json> --artifact <file>
               [--source <json>] [--reading <json>] [--replace] [--discard-reading]
  analysis <module-sha> [--recipe <id>]   the manifest, or null
  recipes <module-sha>                    [ id ]
  list | conflicts                        [ manifest ]
  set-ref <name> <key>... | refs | remove-ref <name>
  verify                                  { problems }
  gc [--apply] [--analyses]               the report; a dry run unless --apply
  export --out <file> <key>...            the bundle's list
  import <file>                           { imported, unchanged, skipped, conflicts }
```

- Answers are JSON on standard output, an object's bytes the one exception.
  A refusal is `{"error": "…"}` on standard error with status 1; a command or
  argument the tool does not know is status 2.
- A JSON argument with a field the store does not know is refused, never
  dropped, so a client cannot lose a field silently.
- `hello` names the protocol (1). It is raised when an answer's shape changes,
  never for an addition.

### 3.2 Where the tool comes from

- `cas.py` uses `$BYTERIPPER_CAS` when it is set, and otherwise builds the tool
  from the repository with `swift build -c release` into
  `~/Library/Caches/ByteRipper/byteripper-cas` — about 20 seconds, once, and
  again when a source of the package is newer than the build. The build step
  says what it is doing while it runs.
- So a machine that runs the skill needs Xcode or its command line tools. Every
  machine the skill runs on today has them.
- Later, if the skill must run where only the app is installed, the app can
  carry the tool in its bundle and `cas.py` can look there before building
  (§6, phase 5).

### 3.3 The rules the store enforces

- Objects are named by their SHA-256, written atomically, verified on read.
- A manifest is written atomically under the store's `flock`.
- The same artifact under the same key is the same analysis: a put merges the
  source it names and takes a newer reading — over none, or a later revision of
  the same project.
- Another artifact under the same key is decided by the readings — the table is
  in `Skills/ghidra-uefi/reference/cas.md` and in the Ghidra plan §5.6.
- A bundle import goes analysis by analysis and reports what it did with each;
  one entry the store cannot take does not stop the rest. Every object that
  matches its hash is stored, so a workspace naming a skipped artifact still
  opens it.
- `gc` keeps every object a kept manifest names — the artifact and the
  reading's review document — and those of the readings kept aside.
- A reading is trusted input: on a local store its writer is the user. A
  remote service (§5.1) must let only an authenticated writer claim a reading,
  record who claimed it, and refuse a claim on a project that writer has not
  written before.

## 4. Current state

### Native macOS app

- Links `ContentStore`; reads the store for the Code badge and the Code panel;
  writes only through project bundles (`WorkspaceRecorder` exports, and
  `CodeAnalysisStore.importProjectBundle` imports on project open).
- Follows `analyses/` with FSEvents; the 30 s fallback poll and the
  activation/wake refresh are the safety net.
- Ignores what a project-bundle import skipped or kept aside: the result is
  computed but not shown (§6, phase 4).

### Ghidra skill

- `cas.py` is the client of `byteripper-cas`; `code_artifact.py`,
  `code_query.py` and `cas_cli.py` reach the store only through it.
- `code_artifact.py --force` replaces a mechanical artifact; replacing a
  reviewed reading also needs `--discard-reading`.
- The skill runs without the app, including headless on a Mac. The app's MCP
  relay is needed only to extract nodes from an open dump.

### ByteRipperWeb

- The browser edition: TypeScript, Vite, static hosting, no backend, no Code
  panel and no CAS.
- `ByteRipperWeb/desktop` is an optional Electron shell around the same page,
  with a narrow preload bridge.

## 5. Later: a service, Electron, the web

None of this is scheduled. It is written down so that the first need for it
does not reopen the decision above.

### 5.1 When a service is needed

A service is the right shape once a client cannot run `byteripper-cas` against
a directory it can open:

- **a remote store**, shared between machines or people — then the service is
  the only writer, behind HTTPS with authentication and per-project scoping;
- **the Electron shell on Windows or Linux** — `CryptoKit` is macOS-only, so
  the tool would first need a portable SHA-256 (the open question of a Linux
  CI is the same one).

It would serve the command set of §3.1 over a socket (and HTTP/WebSocket when
remote), keep `ContentStore` as the file backend, and add the one thing a
file system cannot give a remote reader: a change feed. Clients would switch
transport, not model. Before then, a remote store is a synced folder of
bundles, or the Ghidra plan's "the supervisor runs on the powerful machine and
returns artifacts to the client's own store".

### 5.2 ByteRipperWeb policy

- The browser edition remains **static, no backend, no install**, and files do
  not leave the machine by default.
- The Electron shell is the only place a local CAS may be used, through its
  main process; the page talks to it only through IPC and never gets a path or
  a token.
- A remote CAS for the browser is **opt-in** and visible in the UI: what is
  uploaded (analyses and artifacts, not the dump unless the user asks), where,
  and with what account.
- A browser-local writable CAS in OPFS/IndexedDB would be a second
  implementation of the store and is not in this plan.
- Project bundles remain the portable bridge: a project can carry its analyses
  to a machine with no store, and a web Code panel, if one is ever built, could
  read them.

## 6. Phases

1. **Done — the change feed.** FSEvents instead of the 2-second poll, with the
   slow poll and the activation/wake refresh as the safety net.
2. **Done — one implementation.** `byteripper-cas` over `ContentStore`;
   `cas.py` its client; the manifest model carries every field the skill
   writes (`module.phase`, `recipe.types`, `recipe.passes`); unknown fields
   refused.
3. **Done — readings.** `reading` in the manifest, `ReadingOrder`, replacement
   by reading at put and at import, per-key import with a report, `conflicts/`
   kept by `gc`, `code_artifact.py --discard-reading`.
4. **The app reports a project bundle's import.** Skipped entries and readings
   kept aside become a notice on project open, and a way to choose between two
   readings. Needed once readings exist, i.e. with phase 2 of the Ghidra plan.
5. **The tool in the app bundle (optional).** For a machine with the app and
   no Xcode: the app carries `byteripper-cas`, `cas.py` finds it there. Needs a
   signing check for a second executable in an ad-hoc signed bundle.
6. **A service (optional, §5.1).** Only for a remote store or a non-macOS
   client.

## 7. Testing

- `swift test` in `Packages/CodeAnalysis`: the store (`ContentStoreTests`,
  including the reading table at put and at import, a Python-written bundle
  fixture, a bad entry that does not stop the rest of a bundle) and the command
  line (`CASCommandTests`: answers, refusals, unknown fields, usage errors).
- `python3 -m unittest discover -s Skills/ghidra-uefi/tests`: the skill's
  client against the real tool, built on first use.
- A store written before this change opens, lists, verifies and serves its
  artifacts through the tool unchanged (checked on the nine analyses in this
  Mac's store).

## 8. Risks and open questions

1. **A Linux CI for the skill.** `byteripper-cas` uses CryptoKit, which is
   macOS-only. If the skill must run on Linux, the tool needs a portable
   SHA-256 (swift-crypto would be a dependency; a small SHA-256 in the package
   would not be).
2. **The first command builds the tool.** About 20 seconds once per machine and
   per change of the package's sources; a machine without Swift cannot use the
   store until `BYTERIPPER_CAS` names a built tool.
3. **Process per command.** Each call starts a process (10–15 ms). A
   session of thousands of calls would want a long-lived mode — a `--serve`
   reading commands from standard input — before it wants a daemon.
4. **Two readings of one module.** `conflicts/` keeps both; choosing between
   them needs the app's interface (phase 4) or a command line, neither designed
   yet.
