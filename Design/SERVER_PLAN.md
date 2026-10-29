# byteripper-server — one shared store and one Ghidra host for a personal network

> Status: accepted in conversation on 2026-10-26; the phases below were the
> order of work and are done. `Design/SERVER_HEADLESS_PLAN.md` extends this
> one and supersedes its MCP parts: the server holds dumps, serves a local MCP
> on a Unix socket, keeps `tokens.json` with rights, and has a web console.
> Read the two together; where they differ, the headless plan wins. macOS
> first; the other platforms are a TODO (§9).

## 1. Decision in one page

1. **One process, two roles.** `byteripper-server` is a Swift executable whose
   roles are switched on separately: `--cas` serves a code-analysis store,
   `--ghidra` hosts the Ghidra owners of `Design/GHIDRA_SHARED_PLAN.md`. Both
   are on by default, and `--cas` alone turns Ghidra off. The store is
   always the server's own (`Design/SERVER_HEADLESS_PLAN.md` decision 17):
   there is no `--cas-url`, and no mirror of somebody else's store.
2. **One listener, tokens with rights.** The roles share one HTTP port and
   one `tokens.json`: a token carries `cas.read`, `cas.write`, `ghidra.use`
   or `admin`, and every address needs one. The owners stay on loopback
   behind it and never see the network.
3. **The store's rules exist once.** The server runs `ContentStore`
   (`Packages/CodeAnalysis`) on its own directory and is the only writer of
   it. A client sends operations — put an object, put an analysis, record a
   revision, import a bundle — never files, so the reading table (§5.6 of the
   Ghidra plan) and the publish order are decided where they are today. No
   conditional writes, no second implementation.
4. **The app reads a mirror.** With the store on a server, the app keeps a
   local `ContentStore` as a mirror of it, fed by a change feed. The read path
   — the badge, the Code panel, the annotations, the bundle export — reads the
   mirror exactly as it reads a local store now, FSEvents included. An object
   the mirror lacks is fetched on first read and kept, since objects never
   change.
5. **A setting, not a mode.** Settings ▸ Code analysis ▸ *Analyses are kept*:
   **on this Mac** (the default, and all a DMG user ever needs) or **on a
   server** (address and token). Switching keeps both directories; the first
   switch to a server offers to send it the analyses only this Mac has, as a
   bundle import with its usual report.
6. **Owners are Java, everything around them is Swift.** An owner lives inside
   Ghidra's JVM because Ghidra's API is Java. Locating Ghidra, building
   `Owner.jar`, making a project, starting, stopping, the lease, publishing into
   the store and the MCP tools are Swift (`GhidraHost`), so the same code runs
   in the server and, for the desktop, inside the app. Python stays for the
   skill's scripts and tests; a DMG user never needs it.
7. **Agents get one set of tools from either place.** The tools are defined
   once (`GhidraHost`, on `AgentKit`), and what they need of a document —
   the document rule, a module query, `code_query`/`code_modules`,
   `ghidra_open` by a node — is `Packages/AgentDocuments`, which both hosts
   link. The app serves the list on its own MCP server — in-process for a
   desktop host, relayed to the server otherwise — beside the tree tools. The
   server serves its own list to an agent on its own machine over
   `<Server>/mcp.sock` (`byteripper-server relay` is the client's end); it has
   no `/mcp`, and nothing of MCP reaches the network
   (`Design/SERVER_HEADLESS_PLAN.md` §7, §9).
8. **Local by default, tailnet as the network, a token on every address.**
   The server binds loopback unless told an address, and every address it
   listens on — loopback included — requires a token of its `tokens.json`,
   which carries the token's rights. Encryption is the tailnet's (WireGuard);
   TLS is a proxy's job if ever needed.
9. **A personal installation.** One person, a few tokens, few writers. Collisions
   are rare and handled by the rules the store already has; there is no user
   model, no per-project scoping. That is a deliberate limit (§8).

## 2. Deployments

| | store | Ghidra | agent connects to |
|---|---|---|---|
| desktop (DMG) | this Mac | the app starts owners (`GhidraHost` in-process) | the app's MCP |
| server, app on the same Mac | server | server | the app's MCP |
| server, app on a laptop | server, mirrored on the laptop | server | the laptop app's MCP |
| server, agent alone | server | server | `byteripper-server relay` → the server's local MCP on `mcp.sock` |

An agent on the server with no app running still reviews: a module it opens
by SHA must already have a project or be sent its bytes (§6.3).

## 3. Packages

| package | targets | what it is |
|---|---|---|
| `Packages/HTTPService` | `HTTPService` | a small HTTP/1.1 server: listener, request parsing, routes with access and body limits, the authorizer seam, long poll. macOS: Network.framework |
| `Packages/AgentDocuments` | `AgentDocuments` | the tools both hosts serve over their own documents: the document rule, a tool-module's query, `code_query`/`code_modules`, `ghidra_open` by a node |
| `Packages/CodeAnalysis` | + `RemoteStore`, `StoreMirror` | the client of a served store and the mirror the app reads; the store itself as today |
| `Packages/CASService` | `CASService` | the store's routes over `ContentStore` and its change feed, each naming its right |
| `Packages/GhidraHost` | `GhidraHost` | Ghidra install, `Owner.jar`, projects, owner pool, lease, publish, the MCP tools |
| `Packages/ByteRipperServer` | `ServerAuth`, `DumpHost`, `ServerMCP`, `ServerRelay`, `ServerConsole`, `ByteRipperServer` + executable `byteripper-server` | tokens with rights and the console's door; the documents a snapshot is read from; the local MCP and its socket; the stdio↔socket relay; `/admin`; the roles on one listener |

The app links `CodeAnalysis` (mirror), `GhidraHost` (desktop host and the
tools) and `AgentDocuments` (the tools over its panes); it never links
`HTTPService` or anything of `Packages/ByteRipperServer`.

## 4. The store over HTTP

All under `/cas/v1`, JSON unless the body is an object's bytes; every request
carries `Authorization: Bearer <token>`.

| call | answer |
|---|---|
| `GET hello` | protocol, store id (a UUID minted with the store), change sequence |
| `GET objects/<sha>` | the bytes; the client checks the hash |
| `HEAD objects/<sha>` | 200 or 404 |
| `PUT objects/<sha>` | stored; refused when the body's hash differs |
| `GET analyses` | every manifest (what `list` gives) |
| `GET analyses/<module>` | the module's manifests by recipe |
| `POST analyses` | `{module, recipe, artifact, source?, reading?, replace?, discard_reading?}` — `artifact` is the SHA of an object already put; the answer is `putAnalysis`'s, refusals included |
| `GET reviews/<module>` | the history |
| `POST reviews/<module>` | `{reading, by}` → `recordRevision` |
| `GET conflicts` | kept-aside manifests |
| `GET refs`, `PUT refs/<name>`, `DELETE refs/<name>` | references |
| `POST import` | a bundle as the body → the import report |
| `POST export` | `{keys}` → a bundle |
| `GET verify` | the report, read-only |
| `GET changes?since=<seq>&wait=<s>` | long poll: `{store, seq, modules: […]}` — the modules whose manifests or histories changed since `seq` |

- **Garbage collection is not served.** It runs on the server's own
  directory (`byteripper-cas gc`), by the person, as today.
- **The change sequence** counts the server's own writes and the FSEvents of
  its directory (a `byteripper-cas` or `code_artifact.py` run on the server
  writes there directly). It restarts with the server; a client that sees a
  different store id or a sequence lower than its own syncs everything.
- **Refs are per installation of the app**: `refs/<mac name>/…`, so `gc` on the
  server knows what every Mac's projects use.
- **Who claimed a reading** (§13 of the Ghidra plan): every writer is a token
  of the person's, so a token names the client and its rights, not a person;
  the history's `by` records `agent` or `person` and the server adds the
  client's name. A user model is out of scope (§8).

## 5. The mirror

- A directory `Analysis Mirrors/<store id>/` beside the local store, itself a
  `ContentStore`. The app opens it instead of the local store when the setting
  says *on a server*.
- **Sync** copies manifests and histories as they are — the server already
  decided them — through a `ContentStore` entry that writes a decided file
  under the lock without applying the reading table. At start, and when the
  store id or sequence says so, everything; otherwise the modules the change
  feed names.
- **Objects on demand.** `ContentStore.object(_:)` gains an optional fallback
  source: a missing object is fetched, checked against its hash and written to
  the mirror before it is returned. Reads already happen off the main actor.
- **Writes go to the server.** The app's only writes — a project's bundle
  import on open — become `POST import`; the answer is the report the open
  shows (2b). A bundle export reads the mirror, fetching what it lacks.
- **Offline.** Reading works from what the mirror holds. A write fails with a
  message naming the server; nothing queues — a second source of truth would
  have to be merged later. A publish from the desktop host is not involved:
  with the store on a server the owners are the server's.
- **Mirror housekeeping:** an object no mirrored manifest or history names is
  dropped by the mirror's own `gc`, run at launch.

## 6. The Ghidra role

### 6.1 What moves from Python to Swift

| today (`Skills/ghidra-uefi/scripts`) | `GhidraHost` |
|---|---|
| `ghidra_import.find_ghidra` | the install: a configured path, else the newest `ghidra_*_PUBLIC` in the usual places; the JDK from `JAVA_HOME` or `/usr/libexec/java_home -v 21` |
| `ghidra_owner.build` | `javac` of `owner/*.java` against the install's jars into `GhidraProjects/owner-<ghidra>-<source sha>/` |
| `uefi_types.py` | the EDK2 type archives and GUID table: fetched and built once, cached |
| `te_to_pe.py` | a TE→PE rewrite in Swift, checked byte for byte against the script |
| `ghidra_owner.open` (step 1) | `analyzeHeadless` with `ApplyUefi.java` into the kept project; `state.json` |
| `ghidra_owner` start, stop, `get`, writes | the owner pool: start on demand, loopback port, idle exit, `/v1` proxy |
| `ghidra_owner.publish` / `release` | publish: the owner's artifact and document into the store in the §5.4 order (`ContentStore` direct — the server's Ghidra role always publishes into its own store) |

The Java sources ship with the app (`Contents/Resources/GhidraOwner/`) and
with the server; they are compiled against whatever Ghidra is installed,
because a jar built for one Ghidra does not load in another.

### 6.2 The lease

The host holds the lease, not the agent: it takes it on the first write to a
module, renews it with each write, and releases it — publishing — when the
agent calls `ghidra_done`, when the lease has been idle for its TTL, or when
the host stops. Two agents on one module are serialized by the host; the owner's
own lease stays the guard against a second host.

### 6.3 Where a module's bytes come from

- **Through the app:** the app's tool takes a document and a node, reads the
  bytes as `uefi_node_data` does, and sends them with the open
  (`POST /ghidra/v1/modules`, the body is the image).
- **On the server alone:** a module with a project opens by SHA; a new module
  needs its bytes, sent by the skill (`byteripper_extract.py` and the CLI) —
  never a path on the server.

### 6.4 The tools

`ghidra_open`, `ghidra_functions`, `ghidra_function`, `ghidra_disassembly`,
`ghidra_xrefs`, `ghidra_data`, `ghidra_strings`, `ghidra_type_definition`, `ghidra_rename`,
`ghidra_function_create`, `ghidra_rename_variable`, `ghidra_signature`, `ghidra_comment`,
`ghidra_set_data`, `ghidra_type`, `ghidra_publish`, `ghidra_done`. The server's
MCP instructions carry the review rules of the skill (`SKILL.md`, "What a
review makes of the code"), so an agent without the skill gets them too.

The server serves this list, with the server's own documents, over a Unix
socket — `<Server>/mcp.sock`, reached from a client by `byteripper-server
relay` — and not at `/mcp`: an agent on the server keeps its own dumps, the
tree is read from them, and nothing of MCP reaches the network
(`Design/SERVER_HEADLESS_PLAN.md` §7, §9). The 2026-10-27 note that kept a
`/mcp` endpoint is withdrawn.

## 7. Configuration

```
byteripper-server [serve] [--cas] [--ghidra] [--listen <host>:<port>]
                  [--store <dir>] [--tokens <file>]
                  [--dump-roots <dir>] [--max-documents <n>]
                  [--max-open-bytes <n>] [--max-upload-bytes <n>] [--mcp-socket <path>]
                  [--server-name <name>] [--ghidra-home <dir>] [--projects <dir>] [--idle <s>]
byteripper-server token add --name <name> [--rights <r,…> | --preset <reader|app|admin>]
byteripper-server token list | rotate <id|name> | revoke <id|name>
byteripper-server relay [--mcp-socket <path>]
```

- Defaults: the store and Ghidra, loopback, the app's own directories under
  `~/Library/Application Support/ByteRipper/`, the dumps in `<Server>/Uploads`
  only, `mcp.sock` beside `tokens.json`.
- Every address needs a token, loopback included: `tokens.json` (0600, hashes
  only, one set of rights each), and the server refuses to start without an
  admin token. `byteripper-server token add` prints a secret once.
- `--dump-roots` names the folders the console may open dumps from; a path
  outside them and the server's `Uploads` is refused. `--server-name` adds a
  name the console answers to (`Design/SERVER_HEADLESS_PLAN.md` decisions 12,
  18, 19).
- A LaunchAgent plist in the docs runs it at login.

## 8. Not in scope

- Several people with separate rights. One token is one person.
- TLS in the server.
- A write queue for an offline Mac.
- Garbage collection over the network.

## 9. TODO — other platforms

External packages are acceptable for these (the app itself stays without
them).

- [ ] **HTTP server**: Network.framework is macOS-only — SwiftNIO behind
      `HTTPService`'s interface on Linux and Windows.
- [ ] **SHA-256**: `CryptoKit` is macOS-only — swift-crypto (`Crypto`) on the
      others, chosen with `#if canImport(CryptoKit)`.
- [ ] **File lock**: `flock` (`ContentStore.swift:716`) on POSIX,
      `LockFileEx` on Windows.
- [ ] **Change notification**: `CodeStoreWatcher` is FSEvents — inotify on
      Linux, `ReadDirectoryChangesW` on Windows, or the server's own writes
      plus a poll.
- [ ] **Paths**: Application Support → `$XDG_DATA_HOME` / `%LOCALAPPDATA%`.
- [ ] **Ghidra and JDK discovery**: `/usr/libexec/java_home` is macOS-only;
      `JAVA_HOME`, the PATH and `ghidraRun`'s own lookup elsewhere.
- [ ] **`analyzeHeadless`**: a `.bat` on Windows.
- [ ] **Service definition**: systemd unit, Windows service.
- [ ] **CI**: build and the package tests on Linux.

## 10. Phases

1. **The store served — done.** `HTTPService`, `CASService`,
   `byteripper-server --cas`, `RemoteStore`, `StoreMirror`; `byteripper-cas
   --server <url>`, and `--store http://host:port` in every script of the
   skill. A write made on the server's own directory reaches a waiting client
   through the server's FSEvents stream in under a second.
2. **The app on a served store — done.** Settings ▸ Code Analysis, the mirror
   read through every place that opens the store by its root (an object
   source registered for the mirror's root), the three watchers following a
   changed root, a project's bundle sent to the server with the server's
   report as the notice, project references kept on the server per Mac,
   *Send This Mac's Analyses*, the help page. The token is a 0600 file shared
   with the scripts, not a keychain item (an ad-hoc signed app would be asked
   again after every update).
3. **The Ghidra host in Swift — done.** `GhidraHost` finds Ghidra and a JDK,
   builds the owner, makes a project from a module's bytes (TE→PE, the EDK2
   archives and GUID table — EDK2 from its tag's tarball, so no `git` — and
   `analyzeHeadless`), starts owners in sessions of their own, holds the
   lease and publishes into a local or served store. Parity: 480 TE images
   convert to the bytes `te_to_pe.py` makes, the GUID table is the same
   file, and a project made here publishes the artifact `code_artifact.py`
   stores (CpuPei, TE; AmdMemAm4RnPei, PE32). `byteripper-server --ghidra`
   serves it under `/ghidra/v1`, naming no server path in an answer.
   Not done: `ghidra_owner.py` still runs its own owners; making it a client
   of the host is left until the scripts need the server.
4. **The tools — done.** `GhidraTools` over a `GhidraBackend` (the host, or
   a server's `/ghidra/v1`), and `AgentDocuments` for what they need of a
   document: the app serves the list on its own MCP server, with
   `ghidra_open` taking a node of an open dump, and the server serves its own
   list with the dumps it holds over `<Server>/mcp.sock`
   (`Design/SERVER_HEADLESS_PLAN.md` §7). The `/mcp` endpoint this phase
   first built is gone (§9 of that plan).
5. **Desktop — the host is done.** With the analyses on this Mac, the app
   answers the `ghidra_` tools from a `GhidraHost` in its own process
   (`LocalGhidraHost`): the same `GhidraProjects` folder a server on this Mac
   uses, the same Ghidra found by `GhidraInstall.find`, and publications
   written into the local store. Still open: the owner's Java in the app's
   resources, and the Settings pane saying which Ghidra and JDK it uses.

These replace phase 2c and phase 3 of `Design/GHIDRA_SHARED_PLAN.md`.

`Design/SERVER_HEADLESS_PLAN.md` is the second half of the work, in phases of
its own: tokens and rights, the app's side of them, `AgentDocuments`, the
documents a snapshot is read from, the local MCP and its relay, the rights on
the roles, `/admin`, and this documentation with its measurements.

## 11. Testing

- `HTTPService`: requests split across reads, bodies by length, keep-alive, a
  wrong or missing token, an oversized body, a long poll that ends on a change.
- `CASService` against a temporary store through a real loopback listener:
  every route, the reading table through `POST analyses`, the publish order,
  a refused object hash, the change feed across a write and across a restart.
- The mirror: a full sync, a feed-driven sync, an object fetched on demand
  and kept, a damaged object refused, offline reads, a write refused offline.
- The app: switching the setting reopens the panel on the mirror; a project's
  bundle import reaches the server and its report is shown.
- `GhidraHost`: the Python tests' cases, plus parity of artifacts with
  `code_artifact.py`.
