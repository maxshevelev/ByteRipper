# byteripper-server alone — dumps, a local MCP, tokens and a console

> Status: proposal, 2026-10-29; revised after review the same day. Extends
> `Design/SERVER_PLAN.md`; its §6.4 ("`/mcp` kept but not advertised") is
> withdrawn — the server serves no MCP over the network at all.

## 1. The decision in one page

1. **One process on the analysis machine.** `byteripper-server` holds a chosen
   set of firmware images, parses them with the same code the app's UEFI
   Structure panel uses (`UEFIContentSource`), and answers an agent on the same
   machine over a **local** MCP socket. The app is not needed for an analysis.
2. **One agent layer, two hosts.** The tools both the app and the server serve
   — the query adapter, the document rule, the code readings, `ghidra_open` by
   a node — move out of the app target into `Packages/AgentDocuments`. The
   server does not keep a second copy of them.
3. **Only REST goes outward.** The client app keeps its own MCP socket and its
   own open files, as today; it reaches the server for CAS and Ghidra with a
   token. The server's `/mcp`, `MCPEndpoint` and the network MCP are removed.
4. **Tokens carry identity and rights.** `tokens.json`, secrets stored only as
   hashes and shown once. Rights: `cas.read` (every token), `cas.write`,
   `ghidra.use`, `admin`. A token is required on every listener address.
5. **The local MCP has no token.** It is the operator's own agent, guarded by
   the socket's file permissions; it can do everything needed to review a
   module and save the result in the CAS — but nothing that acts on a screen or
   edits a dump.
6. **A web console on any address** under the admin token: the open documents,
   current activity, tokens, status.

## 2. Decisions

1. Dumps come from local paths (`--dump-roots`, repeatable) **and** from upload
   through the console. An upload lands in `<Server>/Uploads/`, is hashed, and
   is opened at once as `dN`; an already-open hash returns its id. Only uploaded
   files can be deleted from disk.
2. `--token-file` is removed. `tokens.json` (0600, hashes only, one-time
   secret) is the only token source on the server. The client side does not
   change: the app's Settings ▸ Code Analysis token field writes the 0600 file
   the skill's scripts read, as today; only the command its caption names
   becomes `byteripper-server token add`.
3. A token is required on **every** HTTP address, loopback included — so the
   app sends its token on loopback too.
4. REST rights: `cas.read` on every token, `cas.write`, `ghidra.use`, `admin`.
   `ghidra_publish`/`ghidra_done` and the REST publish require `ghidra.use`
   **and** `cas.write`. No separate `ghidra.read`/`ghidra.publish`. The app
   answers a 403 by naming the missing right, not with a network failure.
5. Only the operator changes the open set, through `/admin`; there is no
   `open_dump`/`close_dump` in MCP. An upload from a client app is a later
   phase.
6. No history: only current activity — live local-MCP connections and REST
   clients per token. No log files.
7. The local MCP reviews: dumps read-only, Ghidra including its edits and
   publish. It never offers `annotate`/`annotations`/`remove_annotations`,
   `reveal`/`focus`/`show`, `write`, `update_in_parent`, `*_fix_checksum`,
   `open_panel`/`open_code`/`open_part`, `uefi_select`/`uefi_selection`,
   `compare`/`reveal_diff`, or the microcode edits.
8. The console is reachable on any address, behind the admin token. It is in
   English only and is not a page of the app's help book: it is documented in
   `SERVER_PLAN.md` and the skill.
9. A document is a **snapshot**: the file is read whole into memory at open
   (`Data(contentsOf:)`, no mapping) and hashed. A mapped file is not a
   snapshot — a writer that rewrites it in place changes the bytes under the
   agent, and one that truncates it ends the process with `SIGBUS`. Dumps are
   kilobytes to tens of megabytes and the open set is capped, so the copy is
   affordable. A change on disk marks the document "changed on disk"; Reopen
   replaces snapshot and tree, keeps the id, bumps `version`.
10. Document ids **survive a restart**: `documents.json` stores, per document,
    the id it was given, its path and the hash it was opened with; new ones
    take `max+1`; there is no renumbering, because an agent holds ids across a
    restart. A restored file whose hash differs is opened with `version` bumped
    and marked "changed on disk", so an agent's node ids from before are not
    silently read against other bytes.
11. Simple limits: document count and the total size of open files.
    Decompressed buffers are measured, not capped.
12. An upload opens the document immediately. It has a limit of its own,
    `--max-upload-bytes` (256 MiB by default), applied to that route alone —
    every other route keeps the parser's present body limit. The request body
    is buffered: the peak memory is about twice the file.
13. The local MCP is a Unix socket at `<Server>/mcp.sock` (directory 0700,
    socket 0600) over the existing `UnixSocketListener`/`UnixSocketConnection`
    in `AgentKit`; the binary gains a `relay` subcommand (stdio↔socket) in a
    target of its own, which cannot import HTTP, the store or Ghidra. If the
    relay's measured RSS or start time is poor (phase 8), it becomes an
    executable of its own.
14. The local MCP is always on and always has the dumps and the store;
    `--ghidra` is the only optional role, and without it its tools are absent
    from the list.
15. v1 tools: bytes + UEFI + CAS read + Ghidra. ME, FIT, `microcode_catalogue`,
    `survey` and `region_scan` follow.
16. Without `tokens.json`, or without an admin token in it, the server refuses
    to start and names `byteripper-server token add --name admin --rights admin`.
17. The store is always this server's own and local: `--cas-url` and
    `RemoteStore` are not used by the server, and the CAS role is always on.
    Only Ghidra is optional.
18. Every path opened — from the console or restored at start — must resolve
    (`realpath`, symlinks followed) inside a `--dump-roots` directory or inside
    `<Server>/Uploads/`. Anything else is refused.
19. The console checks `Host` and `Origin` against the listen addresses plus
    the names given with `--server-name` (repeatable: a LAN name, a tailnet
    MagicDNS name). An unlisted name is refused — the guard against DNS
    rebinding.

## 3. Topology

| who | what |
|---|---|
| the server | dumps + local MCP + console + this machine's store over CAS REST, always; `--ghidra` (Ghidra REST and owners) optional; no network MCP |
| the client app | its own MCP socket and its own open files, as today; CAS and Ghidra over REST with its token; its agent sees only its own files |
| the console | `/admin` on every listen address, signed in with the admin token |

## 4. Packages and targets

### 4.1 `Packages/AgentDocuments` — the shared agent layer

Today the pieces both hosts need live in the app target, tied to `AgentDesk`
and its panes. They move into a new shared package, which the app and the
server both link:

| what | from | shape in the package |
|---|---|---|
| the document rule | `AgentDesk.place(named:)` | `AgentDocumentSet` (`@MainActor` protocol): the list of documents (id, name, size, version), and `resolve(_ document: String?) throws -> AgentDocument` with the one rule — one open: implied; several: required, the error lists ids and names; none: the host's own message |
| the query adapter | `AgentModuleTools.query`/`runQuery` (`ByteRipperApp/Agent/AgentModuleTools.swift:48-105`) | `ToolQueryTools.tool(for: ToolAgentQuery, documents:)`: adds `document`, resolves it, runs the query on the document's `ToolReadHost`, puts `document` into the answer. The app wraps it with its own node links (`AgentNodeLinks`), which belong to parts and stay in the app |
| the code readings | `AgentCodeTools` query and modules tools | `CodeReadings`: `code_query` and `code_modules` over a `ToolReadHost & UEFITreeProviding` and a `ContentStore`, with the GUID catalogue passed in as a closure (as `UEFIAgentQueries.all(catalogue:)` takes it). `open_code` stays in the app — it opens a panel |
| `ghidra_open` by a node | `AgentGhidraTools.openTool` | `GhidraNodeOpen`: reads the node's body through `UEFIAgentNodeData.bytes` and opens it on a `GhidraBackend`; by `module` for a project already made. Both hosts use `GhidraTools.tools(backend:includeOpenByImage: false)` and **replace** its `ghidra_open` with this one — two tools of one name in one list is a defect |

Depends on `AgentKit`, `ToolModuleKit`, `UEFIImage`, `UEFITool` (the pure
target), `CodeAnalysis`, `GhidraHost`. It is listed in `packages:` in
`project.yml`; `xcodegen generate` after adding it. A shared package that
depends on a tool-module's pure target is a new edge in the graph; the rule
it must not break is the other direction — no tool-module depends on
`AgentDocuments`.

`documents`, `read` and `find_bytes` are **not** moved: in the app they speak
of panes, parts, comparisons and unsaved edits, and the server's versions are
a few dozen lines over a snapshot. The server writes its own, with the same
answer keys (`id`, `name`, `size`, `version`, `link`), and a test in
`ByteRipperServerTests` pins those keys.

### 4.2 Targets in `Packages/ByteRipperServer`

New targets go into its `Package.swift`; `project.yml` needs no new entry for
them (the package is already listed). Its `dependencies:` gain
`../AgentDocuments`, `../UEFIImage`, `../UEFIContentSource`,
`../ToolModuleKit` and `../../Modules/UEFITool`. The app links none of it.

| target | what | depends on |
|---|---|---|
| `ServerAuth` | `HTTPPrincipal`, `HTTPAuthorizer`, `TokenStore`, hashes, presets, one-time secrets, console cookie and CSRF | `HTTPService`, CryptoKit, Foundation |
| `DumpHost` | `DocumentRegistry` (an `AgentDocumentSet`), `DocumentHost`, `SnapshotReader`, `documents.json`, uploads, limits | `AgentDocuments`, `UEFIImage`, `UEFIContentSource`, `ToolModuleKit` |
| `ServerMCP` | the `AgentServer`, `documents`/`read`/`find_bytes`, the tool assembly, headless descriptions, the activity registry | `AgentKit`, `AgentDocuments`, `DumpHost`, `UEFITool`, `GhidraHost`, `CodeAnalysis` |
| `ServerConsole` | `/admin`: pages, JSON, sign-in, tokens, activity, status | `HTTPService`, `ServerAuth`, `DumpHost`, `AgentKit` |
| `ServerRelay` | the stdio↔socket bridge; `AgentKit` only, which is what keeps the roles out of it | `AgentKit` |
| `ByteRipperServer` | role composition, CLI, the removal of `MCPEndpoint` | all of the above + `CASService`, `GhidraHost`, `HTTPService` |

`Modules/UEFITool` is a pure target, but it depends on `ToolModuleKit`, which
imports AppKit in several files: the server stays macOS-only in v1.

## 5. HTTP authorization and tokens

- `HTTPRequest` gains `principal: HTTPPrincipal?` (`id`, `name`, `rights`);
  `HTTPAuthorizer` turns `Authorization: Bearer` into it. `HTTPServer` requires
  an authorizer — both loopback exemptions go — and calls
  `onRequest(method, path, status, duration, principal)`, which is where the
  REST activity rows come from.
- The body limit becomes per route: `HTTPRouter` lets a route name its own
  maximum, which the parser reads once the request line and headers are in;
  the default stays what it is now.
- `CASService.routes(access:)`: `cas.read` for the GETs (hello, objects,
  analyses, reviews, conflicts, refs, verify, changes, export); `cas.write` for
  `PUT objects`, `POST analyses`/`reviews`/`import`, `PUT`/`DELETE refs`.
- `GhidraRoutes.routes(host:published:access:)`: `ghidra.use` for reads and
  edits; `publish` and `release` need `ghidra.use && cas.write`.
- The console cookie is accepted **only** under `/admin`, so a browser session
  cannot reach CAS or Ghidra.
- Sign-in: `GET/POST /admin/login` with the admin token (URL-encoded body); a
  32-byte session id kept in memory; `Set-Cookie: br_admin=…; HttpOnly;
  SameSite=Strict; Path=/admin`. CSRF is double-submit: a `br_csrf` cookie plus
  `X-CSRF-Token` (or a hidden field); `Host`/`Origin` checked against decision
  19's names; failed sign-ins delayed and throttled. `Secure` waits for TLS.
- `tokens.json`: `{version, tokens: [{id, name, hash, rights, created,
  last_used, revoked}]}`; SHA-256 (the secret is 32 random bytes, so a slow
  hash buys nothing), constant-time compare, file lock. `last_used` is kept in
  memory and written at most once a minute and at stop — never a file write
  per request. CLI: `byteripper-server token add|list|rotate|revoke`, the
  secret printed once.
- `TokenFile` and `--token-file` are deleted.

## 6. Documents

- `DocumentRegistry` (`@MainActor`, an `AgentDocumentSet`): open by path or
  upload, close, reopen, list, reorder; ids persisted; new ids `max+1`.
- `SnapshotReader: ToolContentReader` over the `Data` read at open — the
  snapshot of decision 9.
- `DocumentHost: ToolReadHost, UEFITreeProviding`: `fileName`, `contentSize`,
  `read`, `snapshot()`, `contentVersion = version`; `uefiTree()` lazily builds
  `LazyUEFITree(ToolContentByteSource(reader: snapshot))` (not
  `WindowedByteSource`, which is internal to `UEFIImage`); the tree lives with
  the document.
- Reopen: reread, rehash, `tree = nil`, `version += 1`, same id.
  `changedOnDisk` comes from mtime and size; the tree is not rebuilt under the
  agent.
- Restore: each row of `documents.json` is checked by decision 18, read, and
  its hash compared with the stored one (decision 10); a missing file stays as
  a "missing" row with no id.
- Limits: `--max-documents` (8), `--max-open-bytes` (512 MiB), counted over
  file sizes and checked before opening.
- Upload: `POST /admin/documents?name=…` with a raw body (there is no multipart
  parser), checked against `--max-upload-bytes`, hashed, and written
  atomically to `Uploads/<sha256>` mode 0600 — the file is named by its hash,
  and `name` is kept only as the document's display name, so nothing a client
  sends becomes a path. An open hash discards the copy and answers the
  existing id. `DELETE` only for uploaded documents.

## 7. The local MCP and the relay

- `ServerMCP` builds one `AgentServer` (instructions, tools, limits 16 MiB per
  line and 96 KiB per answer) and serves it through `UnixSocketListener(path:)`
  and `UnixSocketConnection`, following the app's `adopt`
  (`ByteRipperApp/Agent/AgentService.swift:419-450`): `AgentConnectionTag`,
  `onFirstMessage`, `observer`, `onCallStarted`. The connection plumbing there
  is `AgentService.connect(connection:send:onFirstMessage:)`, an app method;
  the server writes its own few lines rather than moving it, since the app's
  is bound to its log and activity view.
- Tools: `documents`, `read`, `find_bytes` (stored bytes only in v1) — the
  server's own (§4.1); through `ToolQueryTools`:
  `UEFIAgentQueries.all(catalogue:)`, `UEFIAgentChecksums`, `UEFIAgentRegions`,
  `UEFIAgentDMI`, `UEFIAgentVariables.queries`, `UEFIAgentNodeData`;
  `code_modules`/`code_query` from `CodeReadings` over the local
  `ContentStore`; with `--ghidra`, `GhidraTools.tools(backend:
  includeOpenByImage: false)` with `ghidra_open` replaced by `GhidraNodeOpen`.
  The server has no base64 form.
- The GUID catalogue: the server has no download of its own, so it passes
  `{ .empty }` and `uefi_node` names a file by GUID only. Bundling the
  catalogue into the server, or reading the app's downloaded copy on the same
  Mac, is a follow-up (§12).
- Not included: `UEFIAgentVariables.comparisons`, `UEFIAgentEdits`, and the
  excluded screen and edit names of decision 7. A test lists the forbidden
  names, asserts none is present, asserts `uefi_tree`, `read` and
  `ghidra_publish` are present under their roles, and asserts every tool name
  appears once.
- Descriptions: a `ServerToolText` table in `ServerMCP` overrides the
  panel-oriented texts; `Modules/UEFITool` is not edited.
- `ServerRelay`: `ServerCommand.parse` answers `.relay(socketPath)`, and `main`
  handles it before a `Server` exists; the path is `--mcp-socket` or
  `BYTERIPPER_SERVER_SOCKET`. A test asserts the mode creates no HTTP listener,
  no store and no Ghidra project.
- Activity: socket connections with start, end, client, calls, last tool,
  documents and errors — in memory, one row per connection.

## 8. The console

- `ServerConsole` serves `/admin` and the pages Documents, Activity, Tokens and
  Status; the HTML/CSS/JS are resources of the target (SPM resources).
- JSON: `/admin/api/documents`, `/admin/api/activity`, `/admin/api/status`;
  actions: open by path, upload, reopen, delete (uploads only), create/rotate/
  revoke a token, sign in and out.
- Polling every two seconds; no SSE or WebSocket, because `HTTPService` sends
  complete responses only.
- Activity: REST rows per token from `onRequest` (name, last seen, requests,
  last method/path/status); MCP rows from the socket.
- Status: version, addresses, server names, roles, store, Ghidra, documents and
  bytes, limits, socket path, uptime.
- Tokens: presets `reader` (`cas.read`), `app` (`cas.read` + `cas.write` +
  `ghidra.use`), `admin` (all); the secret is shown once.

## 9. Removing the network MCP

`MCPEndpoint.swift`, its route in `Server.swift` and `MCPEndpointTests` are
deleted. `GhidraTools` stay for the local MCP and the app. `SERVER_PLAN.md`
(roles, §6.4, phases 4–5) and `Skills/ghidra-uefi` (tokens, no `/mcp`) are
updated with the change.

## 10. Phases

Every phase ends with its packages' tests green and the server starting.

1. **Tokens end to end** (the authorization seam and `ServerAuth` together,
   because removing the loopback exemption without a token store would leave
   the server unable to start and the existing loopback tests failing):
   `HTTPPrincipal`, `HTTPAuthorizer`, `principal` on the request, `onRequest`,
   no anonymous start, per-route body limit; `TokenStore`, `ServerAuthorizer`,
   cookie and CSRF, `token add|list|rotate|revoke`, `TokenFile` removed; the
   existing `HTTPServiceTests`, `CASServiceTests` and `ByteRipperServerTests`
   moved onto a test token; new tests for the once-only secret, revocation,
   the refusal to start without an admin token, and `last_used` not written
   per request.
2. **The app side of tokens**: the app sends its token on loopback, names a
   missing right on 403, and its Settings caption names `token add` — through
   `L()` in English, Russian and German; `help_coverage.py` and
   `help_names.py` run, and the help page on the Code Analysis settings
   updated if it quotes the command. App suite: the Code Analysis settings and
   the store client.
3. **`AgentDocuments`**: the package, `AgentDocumentSet`, `ToolQueryTools`,
   `CodeReadings`, `GhidraNodeOpen`; the app moved onto them with no change
   in what its agent sees. Package tests for the document rule and the
   adapter; the app's agent tests run unchanged and pass.
4. **`DumpHost`**: registry, `SnapshotReader`, `DocumentHost`, persistence with
   the saved ids and hashes, decision 18, limits; a synthetic image in the
   server tests (a ~50-line builder in
   `ByteRipperServerTests/SyntheticDump.swift`; a shared
   `UEFIImageTestSupport` only if a third package needs it); a test that a
   file rewritten in place after open does not change what `read` answers.
5. **`ServerMCP` and `ServerRelay`**: tool assembly, descriptions, the socket,
   the relay, `MCPEndpoint` removed; tests for the forbidden tools, unique
   names, the answer keys of `documents`, `uefi_tree`/`read` on the synthetic
   image, the relay's isolation and a call through the socket.
6. **Rights on the roles**: `CASService.routes(access:)`,
   `GhidraRoutes.routes(access:)`, the rights matrix end to end.
7. **The console**: pages, sign-in and CSRF, decision 19, documents and upload,
   activity, tokens, status; loopback tests.
8. **Documentation and measurements**: `SERVER_PLAN.md` and the skill; RSS and
   start time of `relay`; RSS of the server with the 21 MB LVM volume open; a
   relay executable of its own and a decompressed-buffer cap only if the
   numbers demand them.

## 11. Verification

- Package tests: `HTTPService`, `CASService`, `AgentDocuments`,
  `ByteRipperServer` (all new targets).
- The app suite for the agent groups and the Code Analysis settings (phases 2
  and 3): the agent tools now come from `AgentDocuments`, and the app must
  answer exactly as before.
- A manual end-to-end run on a real Lenovo dump:
  `byteripper-server --dump-roots … --ghidra`; an agent through
  `byteripper-server relay`: `documents` → `uefi_tree` → `uefi_node_data` →
  `ghidra_open(document, node)` → edit → `ghidra_publish` → `code_query`.
- Rights: a token without `cas.write` gets 403 on publish; without
  `ghidra.use`, 403 on the Ghidra routes; `admin` opens the console; a console
  cookie is refused outside `/admin`; the app shows the missing right.
- Console: sign-in, the secret shown once, rotate and revoke, open by path
  (and refused outside the roots) and upload, reopen, delete an upload, the
  set and the ids surviving a restart, a file changed while the server was
  down coming back marked, the activity of the MCP and of the REST clients, an
  unlisted `Host` refused.
- Measurements: RSS and start time of `relay`; RSS of the server with the 21 MB
  LVM volume open; the status page shows the memory.

## 12. Risks and follow-ups

- **The store is local only** (decided): a deployment with Ghidra here and the
  store on another machine is no longer served by the server; the app keeps
  its mirror for its own side.
- **Upload memory**: `HTTPParser` buffers the whole body, so a 256 MiB
  `--max-upload-bytes` means a peak of about 512 MiB. Documented in v1;
  streaming the body to disk is the follow-up.
- **Snapshot memory**: open documents are resident copies, bounded by
  `--max-open-bytes`.
- **`find_bytes`** searches the stored bytes only; a search inside decompressed
  content arrives with `region_scan`.
- **No GUID names** on the server in v1: `uefi_node` gives GUIDs where the app
  gives the catalogue's names. Follow-up: bundle the catalogue, or read the
  app's copy.
- **AppKit**: `ToolModuleKit` brings AppKit; the server is macOS-only and must
  keep the main-actor executor alive.
- **The socket**: file permissions are the only guard; any process of the user
  can connect, and that includes publishing to the store and driving Ghidra.
  Accepted by decision 13.
- **Plain HTTP**: on a LAN everything that crosses is readable — the admin
  token at sign-in, the console cookie, and every client's bearer token, the
  app's `cas.write` included. Documented, with loopback or the tailnet
  recommended until TLS.
- **Decompressed buffers** are not capped, only measured; the status page shows
  the actual use.

## 13. Not in scope

- ME, FIT and NVRAM module tools, `microcode_catalogue`, `survey`,
  `region_scan` — the next stage.
- Uploading a dump from the client app — a later phase.
- A cross-platform server, TLS, history and log files.
- Moving the app's `documents`/`read`/`find_bytes` into `AgentDocuments`.
