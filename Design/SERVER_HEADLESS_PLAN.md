# byteripper-server alone — dumps, a local MCP, tokens and a console

> Status: proposal, 2026-10-29. Extends `Design/SERVER_PLAN.md`; its §6.4
> ("`/mcp` kept but not advertised") is withdrawn — the server serves no MCP
> over the network at all.

## 1. The decision in one page

1. **One process on the analysis machine.** `byteripper-server` holds a chosen
   set of firmware images, parses them with the same code the app's UEFI
   Structure panel uses (`UEFIContentSource`), and answers an agent on the same
   machine over a **local** MCP socket. The app is not needed for an analysis.
2. **Only REST goes outward.** The client app keeps its own MCP socket and its
   own open files, as today; it reaches the server for CAS and Ghidra with a
   token. The server's `/mcp`, `MCPEndpoint` and the network MCP are removed.
3. **Tokens carry identity and rights.** `tokens.json`, secrets stored only as
   hashes and shown once. Rights: `cas.read` (every token), `cas.write`,
   `ghidra.use`, `admin`. A token is required on every listener address.
4. **The local MCP has no token.** It is the operator's own agent, guarded by
   the socket's file permissions; it can do everything needed to review a
   module and save the result in the CAS — but nothing that acts on a screen or
   edits a dump.
5. **A web console on any address** under the admin token: the open documents,
   current activity, tokens, status.

## 2. Decisions

1. Dumps come from local paths (`--dump-roots`, repeatable) **and** from upload
   through the console. An upload lands in `<Server>/Uploads/`, is hashed, and
   is opened at once as `dN`; an already-open hash returns its id. Only uploaded
   files can be deleted from disk.
2. `--token-file` is removed. `tokens.json` (0600, hashes only, one-time
   secret) is the only token source. The client app and the scripts keep a
   0600 token file whose path is in Settings ▸ Code Analysis.
3. A token is required on **every** HTTP address, loopback included.
4. REST rights: `cas.read` on every token, `cas.write`, `ghidra.use`, `admin`.
   `ghidra_publish`/`ghidra_done` and the REST publish require `ghidra.use`
   **and** `cas.write`. No separate `ghidra.read`/`ghidra.publish`.
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
8. The console is reachable on any address, behind the admin token.
9. A document is a **snapshot**: the file is mapped as immutable data and
   hashed at open; a change on disk does not alter the bytes the agent reads,
   the document is marked "changed on disk"; Reopen replaces snapshot and tree,
   keeps the id, bumps `version`.
10. Document ids **survive a restart**: `documents.json` stores the id each
    document was given, new ones take `max+1`; there is no renumbering, because
    an agent holds ids across a restart.
11. Simple limits: document count and the total size of open files.
    Decompressed buffers are measured, not capped.
12. An upload opens the document immediately; the upload limit is
    `--max-open-bytes`.
13. The local MCP is a Unix socket at `<Server>/mcp.sock` (directory 0700,
    socket 0600) over the existing `UnixSocketListener`/`UnixSocketConnection`
    in `AgentKit`; the binary gains a `relay` subcommand (stdio↔socket) in a
    target of its own, which cannot reach HTTP, the store or Ghidra.
14. The local MCP is always on and always has the dumps; `--cas` and `--ghidra`
    are roles, and a disabled role's tools are absent from its list.
15. v1 tools: bytes + UEFI + CAS read + Ghidra. ME, FIT, `microcode_catalogue`,
    `survey` and `region_scan` follow.
16. The client keeps its secret in a 0600 file named in Settings; the scripts
    read the same file.
17. Without `tokens.json`, or without an admin token in it, the server refuses
    to start and names `byteripper-server token add --name admin --rights admin`.

## 3. Topology

| who | what |
|---|---|
| the server | dumps + local MCP + console always; `--cas` (CAS REST) and `--ghidra` (Ghidra REST and owners) as roles; no network MCP |
| the client app | its own MCP socket and its own open files, as today; CAS and Ghidra over REST with its token; its agent sees only its own files |
| the console | `/admin` on every listen address, signed in with the admin token |

## 4. Packages and targets

Everything lives in `Packages/ByteRipperServer`; new targets go into its
`Package.swift`, and `project.yml` needs no entry (the package is already
listed). The app links none of it.

| target | what | depends on |
|---|---|---|
| `ServerAuth` | `HTTPPrincipal`, `HTTPAuthorizer`, `TokenStore`, hashes, presets, one-time secrets, console cookie and CSRF | `HTTPService`, CryptoKit, Foundation |
| `DumpHost` | `DocumentRegistry`, `DocumentHost`, `SnapshotReader`, `documents.json`, uploads, limits | `UEFIImage`, `UEFIContentSource`, `ToolModuleKit` |
| `ServerMCP` | the `AgentServer`, its tools, headless descriptions, the document rule, the activity registry | `AgentKit`, `DumpHost`, `UEFITool`, `GhidraHost`, `CodeAnalysis` |
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
  `X-CSRF-Token` (or a hidden field); `Host`/`Origin` checked; failed sign-ins
  delayed and throttled. `Secure` waits for TLS; the docs say a LAN cookie is
  sniffable.
- `tokens.json`: `{version, tokens: [{id, name, hash, rights, created,
  last_used, revoked}]}`; SHA-256, constant-time compare, file lock. CLI:
  `byteripper-server token add|list|rotate|revoke`, the secret printed once.
- `TokenFile` and `--token-file` are deleted.

## 6. Documents

- `DocumentRegistry` (`@MainActor`): open by path or upload, close, reopen,
  list, reorder; ids persisted; new ids `max+1`.
- `SnapshotReader: ToolContentReader` over
  `Data(contentsOf:options:[.mappedIfSafe])` — an immutable snapshot in file
  pages, not resident memory.
- `DocumentHost: ToolReadHost, UEFITreeProviding`: `fileName`, `contentSize`,
  `read`, `snapshot()`, `contentVersion = version`; `uefiTree()` lazily builds
  `LazyUEFITree(ToolContentByteSource(reader: snapshot))` (not
  `WindowedByteSource`, which is internal to `UEFIImage`); the tree lives with
  the document.
- Reopen: reread, rehash, `tree = nil`, `version += 1`, same id.
  `changedOnDisk` comes from mtime and size; the tree is not rebuilt under the
  agent.
- Restore: every path is checked against `--dump-roots` (`realpath`, symlinks
  resolved); a missing file stays as a "missing" row with no id.
- Limits: `--max-documents` (8), `--max-open-bytes` (512 MiB), counted over
  file sizes and checked before opening.
- Upload: `POST /admin/documents?name=…` with a raw body (there is no multipart
  parser), written atomically to `Uploads/` mode 0600, checked against the
  limit, hashed; an open hash discards the copy and answers the existing id.
  `DELETE` only for uploaded documents.

## 7. The local MCP and the relay

- `ServerMCP` builds one `AgentServer` (instructions, tools, limits 16 MiB per
  line and 96 KiB per answer) and serves it through `UnixSocketListener(path:)`
  and `UnixSocketConnection`, following
  `ByteRipperApp/Agent/AgentService.swift:419-450`: `AgentConnectionTag`,
  `onFirstMessage`, `observer`, `onCallStarted`.
- Tools: `documents`, `read`, `find_bytes` (stored bytes only in v1);
  `UEFIAgentQueries.all(catalogue: .empty)`, `UEFIAgentChecksums`,
  `UEFIAgentRegions`, `UEFIAgentDMI`, `UEFIAgentVariables.queries`,
  `UEFIAgentNodeData`; `code_modules`/`code_query` over the local
  `ContentStore` with `--cas`, or `RemoteStore` with `--cas-url`;
  `GhidraTools.tools(backend:includeOpenByImage:)` with `--ghidra`, plus a
  server `ghidra_open(document, node)` that reads a node's bytes through
  `UEFIAgentNodeData`.
- Not included: `UEFIAgentVariables.comparisons`, `UEFIAgentEdits`, and the
  excluded screen and edit names of decision 7. A test lists the forbidden
  names, asserts none is present, and asserts `uefi_tree`, `read` and
  `ghidra_publish` are present under their roles.
- Descriptions: a `ServerToolText` table in `ServerMCP` overrides the
  panel-oriented texts; `Modules/UEFITool` is not edited.
- The document rule: one document open — implied; several — `document` is
  required and the error lists ids and names; none — a pointer to `/admin`.
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
- Status: version, addresses, roles, store, Ghidra, documents and bytes, limits,
  socket path, uptime.
- Tokens: presets `reader` (`cas.read`), `app` (`cas.read` + `cas.write` +
  `ghidra.use`), `admin` (all); the secret is shown once.

## 9. Removing the network MCP

`MCPEndpoint.swift`, its route in `Server.swift` and `MCPEndpointTests` are
deleted. `GhidraTools` stay for the local MCP and the app. `SERVER_PLAN.md`
(roles, §6.4, phases 4–5) and `Skills/ghidra-uefi` (tokens, no `/mcp`) are
updated with the change.

## 10. Phases

1. **The authorization seam in `HTTPService`**: `HTTPPrincipal`,
   `HTTPAuthorizer`, `principal` on the request, `onRequest`, no anonymous
   start; tests in `HTTPServiceTests`.
2. **`ServerAuth` and the CLI**: `TokenStore`, `ServerAuthorizer`, cookie and
   CSRF, `token add|list|rotate|revoke`, `TokenFile` removed; tests for the
   once-only secret, revocation, the rights matrix, and the refusal to start
   without an admin token.
3. **`DumpHost`**: registry, `SnapshotReader`, `DocumentHost`, persistence with
   the saved ids, limits; a synthetic image in the server tests (a ~50-line
   builder in `ByteRipperServerTests/SyntheticDump.swift`; a shared
   `UEFIImageTestSupport` only if a third package needs it).
4. **`ServerMCP` and `ServerRelay`**: tool assembly, descriptions, the document
   rule, the socket, the relay, `MCPEndpoint` removed; tests for the forbidden
   tools, `uefi_tree`/`read` on the synthetic image, the relay's isolation and a
   call through the socket.
5. **Rights on the roles**: `CASService.routes(access:)`,
   `GhidraRoutes.routes(access:)`, the rights matrix end to end.
6. **The console**: pages, sign-in and CSRF, documents and upload, activity,
   tokens, status; loopback tests.
7. **Documentation and measurements**: `SERVER_PLAN.md` and the skill; RSS and
   start time of `relay`; RSS of the server with the 21 MB LVM volume open; a
   lighter relay target and a decompressed-buffer cap only if the numbers
   demand them.

## 11. Verification

- Package tests, not a full sweep: `HTTPService`, `ByteRipperServer` (all new
  targets), `CASService`; the app's agent tests do not change.
- A manual end-to-end run on a real Lenovo dump:
  `byteripper-server --dump-roots … --cas --ghidra`; an agent through
  `byteripper-server relay`: `documents` → `uefi_tree` → `uefi_node_data` →
  `ghidra_open(document, node)` → edit → `ghidra_publish` → `code_query`.
- Rights: a token without `cas.write` gets 403 on publish; without
  `ghidra.use`, 403 on the Ghidra routes; `admin` opens the console; a console
  cookie is refused outside `/admin`.
- Console: sign-in, the secret shown once, rotate and revoke, open by path and
  upload, reopen, delete an upload, the set and the ids surviving a restart, the
  activity of the MCP and of the REST clients.
- Measurements: RSS and start time of `relay`; RSS of the server with the 21 MB
  LVM volume open; the status page shows the memory.

## 12. Risks and decisions still to confirm

- **`--cas-url`**: the server is a client of another store, and the old single
  token is gone; it needs `--cas-token-file <0600>` (or an environment
  variable) for publishing and reading a remote store.
- **`ghidra_open` on the server** needs the `(document, node)` form beside the
  base64 one, or a local agent cannot open a module from a dump.
- **Upload memory**: `HTTPParser` buffers the whole body; at a 512 MiB limit the
  peak is about twice that. v1 accepts it with a documented limit; streaming is
  later.
- **`find_bytes`** searches the stored bytes only; a search inside decompressed
  content arrives with `region_scan`.
- **AppKit**: `ToolModuleKit` brings AppKit; the server is macOS-only and must
  keep the main-actor executor alive.
- **The socket**: file permissions are the only guard; any process of the user
  can connect. Accepted by decision 13.
- **Plain HTTP**: an admin cookie on a LAN is sniffable; documented, with
  loopback or the tailnet recommended.
- **Decompressed buffers** are not capped, only measured; the status page shows
  the actual use.

## 13. Not in scope

- ME, FIT and NVRAM module tools, `microcode_catalogue`, `survey`,
  `region_scan` — the next stage.
- Uploading a dump from the client app — a later phase.
- A cross-platform server, TLS, history and log files.
