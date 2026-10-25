# CAS service — one store, many clients

> Status: proposal for review. This document describes a design and a migration
> order; it does not describe code that exists yet.
>
> The problem is not the file layout. It is that the same layout is implemented
> twice — Swift in `Packages/CodeAnalysis`, Python in
> `Skills/ghidra-uefi/scripts/cas.py` — and written by two different processes.
> A source-provenance change already had to be made twice. The next change may
> not be, and a shared/network store cannot be built on two writers.

## 1. Decision in one page

1. **One CAS implementation**, behind a versioned protocol. It owns objects,
   analyses, references, bundles, garbage collection and change notifications.
2. **The service is a process, not the GUI.** The native app, the Electron
   shell and the Ghidra skill are clients. The native app may start the service
   and bundle its binary, but it is not the only host and does not own its
   lifetime.
3. **Local first, remote-ready.** A local sidecar serves the native app,
   Electron and the skill; a remote service later speaks the same protocol.
   The current on-disk store remains the first backend.
4. **No direct writes to the store.** `code_artifact.py`, `cas_cli.py`,
   `code_query.py`, the native app and the Electron main process go through a
   client. The service is the only writer.
5. **Change feed replaces the 2-second poll.** The service publishes
   `analysisChanged` after a commit; clients re-read the affected index and
   refresh their badges. A slow fallback poll (and a watcher during migration)
   covers missed events, sleep and old direct writers.
6. **ByteRipperWeb does not get a local process by default.** It is a static
   web edition with no backend; its Electron shell may use a bundled sidecar or
   a remote service, but a browser cannot spawn one. The web edition keeps its
   current promises — no backend, files never leave the machine, no install —
   unless a remote CAS is explicitly enabled as a separate, disclosed mode.
7. **Preserve the store.** Existing `Analysis/` directories remain readable.
   Manifests, content keys, references and bundles keep their meaning. The
   service can wrap the existing layout before any new backend exists.

## 2. Current state

### Native macOS app

- `Packages/CodeAnalysis` has `ContentStore`: content-addressed objects,
  `AnalysisManifest`, references, export/import bundles, garbage collection.
- `UEFIToolUI` reads the store for the Code badge and the Code panel. It also
  writes nothing to the store itself except project bundles through
  `WorkspaceRecorder`.
- `UEFIToolSession.refreshCodeAnalysis` polls the store every 2 seconds. A
  manifest's `source.document`/`source.node` now lets the panel materialize the
  branch an analysis names and put the badge on a PEI image inside a compressed
  Boot FV without the reader expanding it.
- The store lives under
  `~/Library/Application Support/ByteRipper/Analysis`.

### Ghidra skill

- `Skills/ghidra-uefi/scripts/cas.py` implements the same store in Python.
- `code_artifact.py` runs Ghidra headless and writes the artifact and manifest
  directly; `code_query.py` and `cas_cli.py` read and manage the store
  directly.
- The skill can run without the app, including in CI and on a headless analysis
  machine. The app's MCP relay is needed only for extracting nodes from an open
  dump; it is not a storage API.

### ByteRipperWeb

- `ByteRipperWeb` is the browser edition: TypeScript, Vite, static hosting, no
  backend; files never leave the machine and nothing must be installed.
- `ByteRipperWeb/desktop` is an optional Electron shell around the same page.
  Its main process owns the filesystem and process access; the page gets a
  preload bridge (`byteripperDesktop`) and never Node or direct disk access.
- The web edition uses IndexedDB, OPFS and the Cache API for its own local
  state. It has no Code panel and no CAS today.
- A local CAS sidecar is possible in the Electron shell, but not in a browser:
  a browser cannot spawn a process, and a page served from HTTPS cannot rely on
  an `http://localhost` companion without mixed-content and installation
  problems.

## 3. Goals

- One implementation of CAS semantics, used by every client.
- The native app, the Electron shell and the skill work **offline** and
  **headless**; CI runs the same service.
- A remote service can be added later without changing the clients' model.
- Immediate badge updates when an analysis is written, without polling.
- Existing stores, projects and bundles remain readable and migratable.
- No double writers and no split brain on one store.
- Large artifacts (the BdsDxe artifact is about 8 MB) are transferred as
  binary, not as base64 in a command protocol.
- Browser defaults remain local and private; any remote mode is explicit.

## 4. Non-goals

- Running Ghidra inside the app or the service.
- Replacing workspace or project JSON with CAS; only code analyses and their
  blobs move behind the service.
- A general-purpose object store or a search index.
- A browser-local CAS in the first phase. If the Code panel is ever ported to
  the browser, that is a separate decision (see §11).
- A remote, multi-tenant service in the first phase; the protocol is designed
  for it, the deployment is later.
- Making the GUI the only host. The app may start the service; it does not own
  the only copy of it.

## 5. Architecture

```
                       CAS protocol
       putObject / putAnalysis / get / list / refs / bundle / gc / changes
                    /                              \
       native app (Swift client)            skill / CLI (Python client)
                    \                              /
                 local CAS service  ── files, locks, change feed ── store
                    ^
                    |
       Electron main (Node client)  ── preload IPC ── renderer (page)

       web page (browser) ── HTTPS/WS ── remote CAS service (opt-in)
```

### 5.1 Service responsibilities

- Own the store and be its only writer.
- Validate every content hash and every manifest before commit.
- Serialize writes per store; atomic object-before-manifest commits.
- Maintain references, bundles and garbage collection.
- Publish change events after a successful commit.
- Report health, version, store root and statistics.
- Refuse incompatible clients or stores with a clear error.

### 5.2 Clients and transports

A small client interface is shared conceptually across languages:

```text
putObject(stream, sha) -> ObjectRef
putAnalysis(module, recipe, manifest, artifact, source) -> AnalysisManifest
getAnalysis(moduleSha, recipe?) -> AnalysisManifest?
listAnalyses(filter) -> [AnalysisManifest]
setRef / getRef / listRefs
exportBundle(keys) / importBundle(stream)
collectGarbage(dryRun, deleteUnreferencedAnalyses)
subscribeChanges(since?) -> stream of AnalysisChanged
health() / version()
```

Transports:

| Client | Local transport | Remote transport |
|---|---|---|
| native Swift | Unix domain socket (and optionally a localhost HTTP port) | HTTPS + WebSocket |
| Python skill/CLI | Unix socket; start a local sidecar if absent | HTTPS + WebSocket |
| Electron main | Unix socket / named pipe; start a bundled sidecar if absent | HTTPS + WebSocket |
| Electron renderer | IPC to main only | IPC to main only |
| browser page | none | HTTPS + WebSocket (opt-in) |

Control messages are JSON; artifacts and object blobs are binary frames or
HTTP bodies. The protocol must not require base64 for multi-megabyte payloads.

### 5.3 Deployment modes

1. **Local sidecar (default for desktop).** A `byteripper-cas` binary runs as
   the user, one per store. Native app, Electron main and the skill connect to
   the same socket/pipe. Any client may start it; a lock prevents duplicates.
2. **User service (optional).** The same binary registered as a macOS
   LaunchAgent, a Windows scheduled task/service or a systemd user unit. It is
   always on; clients only connect.
3. **Remote service (opt-in).** HTTP/WebSocket, TLS, authentication and
   tenant/project scoping. The browser edition uses this mode only; the native
   and Electron clients may use it instead of a local store.
4. **No service.** ByteRipperWeb in a browser remains without CAS/Code unless a
   remote endpoint is configured. Existing projects with bundled analyses can
   still be opened read-only through the project bundle/cache path.

### 5.4 Service lifecycle

- **Discovery:** well-known socket path per user/store, overridable by
  `BYTERIPPER_CAS` and by a client setting; a small endpoint file with version
  and store root.
- **Start on demand:** client tries to connect; on failure, it starts the
  bundled binary with the store root, waits for the endpoint and handshakes.
  An OS lock makes concurrent starts harmless.
- **Lifetime:** the service is not killed when the app that started it quits.
  It exits after an idle timeout when no client is connected, or runs as a user
  service. A remote service is always on.
- **Crash:** clients reconnect; incomplete temp files are ignored; the service
  validates manifests on start and reports unreadable entries through
  `verify`.
- **Version:** protocol version and store schema version are separate. A
  client refuses a newer service it does not understand; a service refuses a
  newer store only where reading it would be guessing. Migration is explicit and
  fixture-tested.
- **Multiple stores:** a service instance has one root; a remote service may
  expose several stores/tenants. Clients name the store or use the default.

### 5.5 Native app

- The app bundles the service binary and starts it on first CAS use if no
  service is listening.
- Reads and writes go through the client; the existing `ContentStore` becomes
  the service's file backend or is replaced by the service implementation.
- The Code badge and panel subscribe to changes. The 2-second poll becomes a
  slow fallback, not the primary trigger.
- The app can still read a store written by an older build; it does not write
  around a running service.

### 5.6 Electron shell (ByteRipperWeb/desktop)

- The Electron **main process** is the only process with filesystem/process
  access. It is the CAS client for the window.
- `preload.cjs` exposes a narrow `byteripperDesktop.cas` bridge: `put`, `get`,
  `list`, `refs`, `bundle`, `changes`, `status`. The renderer has no fs and no
  direct network access to a local CAS.
- If the shell is configured for local CAS, main connects to the local
  socket/pipe or starts the bundled sidecar. The binary is packaged as an
  `asarUnpack` entry, like the agent relay. Windows uses a named pipe; other
  platforms use a Unix socket.
- If configured for remote CAS, main uses HTTPS/WebSocket; the renderer still
  uses IPC only. The endpoint and credentials are main-process settings.
- Single-instance behavior and profile isolation stay as they are; the CAS
  service is separate and outlives either window.
- The Electron shell is optional; the web page does not require CAS to work as
  it does today.

### 5.7 Browser web edition

- A browser cannot start a local sidecar. The default remains: no backend, no
  Code/CAS, files never leave the machine.
- If the Code panel is brought to the web edition, it has two honest modes:
  - **Remote CAS, opt-in:** an HTTPS/WebSocket endpoint with auth, CORS, change
    feed and a clear warning that analyses (and only analyses, not the dump)
    leave the machine. This is a team/shared mode, not the default.
  - **Project-bundle/read-only cache:** the page can read analyses bundled in a
    project or cached in OPFS/Cache API; it does not write a second CAS. This
    keeps the local promise but cannot create new analyses.
- A browser-local writable CAS in OPFS/IndexedDB is a **second implementation**
  and is not part of this plan. It would be considered only if offline Code in
  the browser becomes a requirement, and would be documented as a separate
  product decision.
- A local companion daemon for the browser is not a default: it requires
  installation and fights mixed-content rules. It is not part of this plan.

## 6. Protocol

### 6.1 Operations

- `hello` — protocol version, service version, store id/root, capabilities
  (binary blobs, change feed, bundle import/export).
- `putObject` — streamed, content-addressed; idempotent; hash verified.
- `putAnalysis` — module identity, recipe, manifest, artifact object, source
  identity; returns the committed manifest. Same module+recipe+artifact is
  idempotent; same key with another artifact is a conflict unless the caller
  explicitly replaces or uses another recipe.
- `getAnalysis` / `listAnalyses` / `listRecipes`.
- `setRef` / `getRef` / `listRefs` — named sets of analysis keys; the project
  bundle uses a stable `project-…` ref.
- `exportBundle` / `importBundle` — streamed ZIP or equivalent; preserves the
  existing `Analyses.bundle` meaning.
- `collectGarbage` — dry-run by default; never deletes an analysis named by a
  live reference; a shared service uses leases/refs, not a global sweep.
- `subscribeChanges` — from a cursor; events name module SHA, recipe and, when
  known, source document/node. Clients re-read manifests/index; events are a
  hint, not the payload.
- `health` / `stats` / `verify`.

### 6.2 Commit model

1. Receive and verify the artifact blob; write it atomically.
2. Validate the manifest against the blob hash and schema.
3. Commit the manifest under the module+recipe key.
4. Commit/refresh references and bundle metadata.
5. Publish `analysisChanged` after the commit is durable.
6. A crash before (5) leaves a valid analysis; the client's next read/index
   fetch sees it. A crash before (3) leaves an unreferenced object eligible for
   GC.

### 6.3 Versioning and compatibility

- Protocol version (`v1`) is independent of the manifest schema and the store
  layout.
- Clients refuse a service that does not speak their protocol; services refuse
  a store newer than they understand rather than guessing.
- Added optional fields are backward-compatible; a changed field, a rename or
  a changed meaning raises the schema/version and gets a migration and
  fixtures.
- The first implementation must pass a language-neutral conformance suite
  built from existing CAS fixtures.

### 6.4 Source identity

- `source.document` is the file name the UEFI panel shows; `source.node` is the
  image node path (`0.6.4.0.0.205.2`).
- The service stores it as provenance; it is not a content key.
- Clients use it only as a hint to open the branch that holds the image. The
  body's SHA-256 still decides whether the analysis applies.
- Re-binding an existing analysis's source is a metadata update, not a new
  analysis; it must not erase fields the caller did not name.

## 7. Store

- Keep `objects/<sha256>`, `analyses/<module-sha>/<recipe>/manifest.json`,
  `refs/<name>.json` and the bundle format as the first local backend.
- The service is the only writer. Existing stores remain readable; a one-time
  scan builds the in-memory index.
- Project `Analyses.bundle` export/import remains the portable path; a remote
  service stores the same bundles.
- The service validates on read where it is cheap and on `verify` where it is
  not.
- A remote backend may use object storage for blobs and a database for
  manifests/refs; the protocol, not the layout, is the contract.

## 8. Change feed and UI

- On commit, the service publishes `analysisChanged` with module SHA, recipe,
  and source (document/node when known).
- Native app and Electron subscribe; the relevant tree reloads its index and
  marks the node; source-node materialization is already implemented and stays
  the path for compressed PEI images.
- Missed events (sleep, reconnect) are recovered by re-reading the index; the
  event stream is an optimisation, not the source of truth.
- During migration, a fallback poll (slow, e.g. 30 s) and/or a store watcher
  covers old direct writers. Once direct writes are removed, the poll can be
  removed or kept only as a safety net.

## 9. Security

- Local sockets/pipes: user-only permissions; the service never listens on a
  network interface by default.
- Remote: TLS, authentication, per-project/tenant authorisation, CORS allowlist
  and size limits.
- Client paths are names/hashes, not arbitrary filesystem paths; the service
  refuses traversal.
- Electron renderer gets IPC only; main validates the sender and the message;
  the page never receives a filesystem path or a service token.
- Change subscriptions are scoped to what the client may read.
- GC on a shared service uses references/leases; never delete objects another
  tenant/project still names.

## 10. Migration order

Each phase leaves the product working.

1. **ADR and protocol.** Decide the service language/host model, web policy and
   remote auth model. Write the protocol and the conformance fixtures.
2. **Service core.** Local file backend, object/manifest/ref/bundle/GC
   operations, `hello`, `health`, `verify`, change feed. CLI only; no client
   migrated yet.
3. **Python client.** `code_artifact.py`, `code_query.py`, `cas_cli.py` go
   through a `cas_client`; the skill starts a headless service when needed.
   Direct writes to the store are removed from the skill. CI runs the service.
4. **Native client.** Swift `CASClient` over the local socket; the app starts
   the bundled service if needed; Code badge/panel use the client; change feed
   replaces the 2 s poll; fallback remains. Existing stores are read and
   verified.
5. **Electron shell.** Main process CAS client, preload bridge, packaged
   sidecar (or remote endpoint); Windows named pipe; packaging/signing checks.
   The browser edition is untouched.
6. **Web Code (optional).** If approved: a TS `CasClient` with remote transport
   and an opt-in remote mode, or project-bundle/read-only cache. No browser
   writes a second CAS.
7. **Remote service.** Same protocol, HTTPS/WS, auth/tenancy, deployment,
   quotas and GC leases; native/Electron/skill can point at it.
8. **Cleanup.** Remove duplicate CAS write implementations; document direct
   write removal; archive the old Python store code as a client/reference only;
   update design docs and tests.

## 11. ByteRipperWeb policy

This is the part most likely to need a product decision, so it is stated
explicitly:

- The browser edition remains **static, no backend, no install**, and files do
  not leave the machine by default.
- The Electron shell is the only place a local CAS sidecar may run, because it
  is installed and its main process may spawn a process; the page still talks
  to it only through IPC.
- A remote CAS for the browser is **opt-in** and must be visible in the UI:
  what is uploaded (analyses and artifacts, not the dump unless the user asks),
  where, and with what account. It is a separate shared/team mode, not a silent
  default.
- A browser-local writable CAS is **not** in this plan. If Code must work
  offline in a browser, that is a new decision with a second implementation and
  its own storage/GC rules; it should not be smuggled in as "the same CAS".
- Project bundles remain the portable bridge: a project can carry its analyses
  to a machine with no service, and the web edition can read them if the Code
  panel is ported.

## 12. Testing and acceptance

- **Protocol conformance:** one fixture suite run against the service and each
  client; objects, manifests, conflicts, refs, bundles, GC, changes, errors,
  version refusal.
- **Store compatibility:** existing `Analysis/` fixtures and project bundles
  read by the service; old builds still read what the service writes (same
  layout).
- **Clients:** Swift, Python and TypeScript clients against a fake and a real
  service; reconnect and missed-event re-read.
- **Lifecycle:** start-on-demand, duplicate-start lock, crash/restart, idle
  exit, multiple clients, store root changes.
- **Electron:** main starts/connects; renderer cannot reach fs/CAS directly;
  packaged sidecar; Windows named pipe; single-instance behavior.
- **Web:** remote opt-in only; CORS/auth; privacy notice; no backend in the
  default build; project-bundle read path.
- **Security:** socket permissions, path traversal, size limits, remote
  auth/tenancy, renderer IPC validation.
- **CI/offline:** `code_artifact.py` and `cas_cli.py` with no GUI and no agent
  settings; service binary available.

Acceptance for the first migration:

- No skill or app code writes the CAS store directly.
- A native app with a running service shows a new analysis badge from the
  change feed without the 2 s poll.
- The skill analyzes and stores a module headless; the app reads it after
  launch.
- Existing store and project bundles still work.
- ByteRipperWeb's default build is unchanged; Electron can use a local
  sidecar or a remote endpoint.

## 13. Risks and open questions

1. **Service language/host.** A Swift-only service covers macOS but not the
   Windows Electron shell or a headless Linux CI. A cross-platform binary
   (Go/Rust) is the clean answer; Node/TS shares code with Electron but needs a
   runtime; Python is easy for the skill but poor for the GUI. Decide in the
   ADR.
2. **Web Code scope.** Is Code a macOS/Electron feature only, or a web feature?
   The answer decides whether a remote CAS is required or the web edition stays
   CAS-free.
3. **Remote privacy/tenancy.** Uploading analyses is still uploading data; the
   remote mode needs consent, auth, tenant isolation and clear retention.
4. **Service ownership/lifecycle.** Who installs/starts it? Bundled sidecar,
   user service, or both? What happens when the app quits? What if two clients
   start it at once?
5. **Packaging/signing.** macOS notarisation, Windows signing, sidecar updates,
   antivirus behaviour for a second executable.
6. **Large artifacts.** Streaming, limits, disk pressure, and whether the
   service or the client computes hashes.
7. **Migration of old writers.** A fallback watcher/poll is needed until every
   old client is upgraded; the plan must say when direct writes become an error.
8. **GC/leases on a shared service.** A simple reference set is enough locally;
   a remote service needs leases or project ownership so one tenant's GC cannot
   remove another's objects.
9. **Protocol governance.** Who may add fields/operations; how versions and
   capabilities are negotiated; how clients degrade.
10. **Store location/multiple stores.** Per-user local store, project-adjacent
    bundles, remote tenant stores; naming and discovery must be explicit.

## 14. Appendix — sketch

```
hello            -> { protocol: 1, service: "x.y.z", store: "...", caps: [...] }
putObject        <- stream + sha256 -> { sha256, size }
putAnalysis      <- module, recipe, manifest, artifactSha, source -> manifest
getAnalysis      <- moduleSha, recipe? -> manifest | notFound
subscribeChanges <- since? -> events: analysisChanged { module, recipe, source? }
```

Local endpoint (illustrative):

```
~/Library/Application Support/ByteRipper/CAS/endpoint.json
{ "protocol": 1, "socket": ".../cas.sock", "pid": 1234, "store": ".../Analysis" }
```

The endpoint file is a hint; the lock and the socket are the authority. A
client that finds a stale endpoint starts or waits for a fresh one.
