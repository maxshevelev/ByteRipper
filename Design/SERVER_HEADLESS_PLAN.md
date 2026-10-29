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
   replaces snapshot and tree, keeps the id, bumps `version`. There is no disk
   watcher: the mark is a `stat` compared with the one taken at open, and
   nothing is rebuilt. The comparison is over inode, ctime, mtime and size —
   not mtime and size alone: a dump of the same chip has the same size, and
   `cp -p`, `rsync -a` or an unpacked archive keep the mtime of another file,
   while ctime cannot be set and changes on every write, and the inode changes
   when the file is replaced atomically. The `stat` is taken at each listing —
   the console's poll and the `documents` tool — **and on every tool call that
   names a document**, whose answer then carries `disk` (below): an agent
   calls `documents` once and works in `uefi_tree`, `read` and `ghidra_open`
   after, so that is where it must see the mark. A `stat` costs microseconds.
   The mark has two values: `changed` (the file is there but is not the one
   read) and `gone` (the `stat` fails — deleted or renamed). Either way the
   document goes on serving its snapshot.
10. Document ids **survive a restart**: `documents.json` stores, per document,
    the id it was given, its path, the hash it was opened with, the `stat`
    fields of decision 9 and its `version`; there is no renumbering, because
    an agent holds ids across a restart. A restore always hashes the bytes it
    read: the snapshot has to be read whole anyway (decision 9), so the hash
    costs tens of milliseconds for a dump and under a second at the
    `--max-open-bytes` cap, and a hash taken from the snapshot itself leaves no
    window between a `stat` and the read in which a writer could put new bytes
    under the old hash and `version`. The stored `stat` serves the `disk` mark
    only, and is refreshed from the file at restore — taken before the read, so
    a write that lands during the read shows as `changed` rather than hiding.
    A restored file whose hash differs is opened with `version` set to the
    stored one plus one, so an agent's node ids from before are not silently
    read against other bytes. It carries no `disk` mark: its snapshot is the file on disk
    now, and the bumped `version` is what tells the agent.
    **An id is never given to another file.** `documents.json` keeps `next_id`,
    and a new document takes it and advances it — not `max+1` over the rows
    present, which would hand a closed or forgotten document's id to the next
    upload, and an agent still holding it would read another file under it. A
    "missing" row (decision 18) keeps its id, held but not served; when its
    file comes back, or the roots widen again, it reopens under that id, with
    `version` by the rule above — but only if the limits of decision 11 allow;
    otherwise it stays missing with the limit named as the reason, its id held.
    The server does not watch the disk: a row comes back only at start, when
    the rows are restored, or when the operator reopens it from the console.
    The console's **Forget** removes a missing row for good; its id is retired
    with it, not freed.
11. Simple limits: document count and the total size of open files. Only
    open documents count; a missing row holds no bytes and counts toward
    neither. Decompressed buffers are measured, not capped.
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
    `<Server>/Uploads/`. Anything else is refused. A restored row that no
    longer passes — the roots narrowed between runs — is kept as a "missing"
    row, its id held (decision 10), not dropped, so the operator sees what left
    the set.
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
| the document rule | `AgentDesk.place(named:)` | `AgentDocumentSet` (`@MainActor` protocol): `documents()` and `resolve(_ document: String?) throws -> any AgentDocument`; an `AgentDocument` is an id, a label, the `disk` mark and a read host. The rule of a host with no focus is `AgentDocumentRule` — one open: implied; several: required, the error lists ids and names; none: the host's own message. The app keeps its own rule, the focused document when none is named, since the person is looking at one. Size and version stay with each host's `documents` tool, which is not moved |
| the query adapter | `AgentModuleTools.query`/`runQuery` (`ByteRipperApp/Agent/AgentModuleTools.swift:48-105`) | `ToolQueryTools.tool(for: ToolAgentQuery, documents:)`: adds `document`, resolves it, runs the query on the document's `ToolReadHost`, puts `document` into the answer, and `disk` beside it when the resolved `AgentDocument` reports one (the server's does; the app's reports none). The app wraps it with its own node links (`AgentNodeLinks`), which belong to parts and stay in the app |
| the code readings | `AgentCodeTools` query and modules tools | `CodeReadings`: `code_query` and `code_modules` over an `AgentDocumentSet`, each document's `ToolReadHost`, the store's root as a closure (the app's follows its setting) and the GUID catalogue as a closure (as `UEFIAgentQueries.all(catalogue:)` takes it). `open_code` stays in the app — it opens a panel |
| `ghidra_open` by a node | `AgentGhidraTools.openTool` | `GhidraNodeOpen`: reads the node's body through `UEFIAgentNodeData.bytes` and opens it on a `GhidraBackend`; by `module` for a project already made. Both hosts use `GhidraTools.tools(backend:includeOpenByImage: false)` and **replace** its `ghidra_open` with this one — two tools of one name in one list is a defect. The answer names the document it read and carries its `disk` mark, as a query's does: an agent works in `ghidra_open` after calling `documents` once (decision 9) |

Depends on `AgentKit`, `ToolModuleKit`, `UEFIImage`, `UEFITool` (the pure
target), `CodeAnalysis`, `GhidraHost`. It is listed in `packages:` in
`project.yml`; `xcodegen generate` after adding it. A shared package that
depends on a tool-module's pure target is a new edge in the graph; the rule
it must not break is the other direction — no tool-module depends on
`AgentDocuments`.

`documents`, `read` and `find_bytes` are **not** moved: in the app they speak
of panes, parts, comparisons and unsaved edits, and the server's versions are
a few dozen lines over a snapshot. The server writes its own, with the same
answer keys (`id`, `name`, `size`, `version`, `link`; the server adds
`disk`), and a test in
`ByteRipperServerTests` pins those keys.

### 4.2 Targets in `Packages/ByteRipperServer`

New targets go into its `Package.swift`; `project.yml` needs no new entry for
them (the package is already listed). Its `dependencies:` gain
`../AgentDocuments`, `../UEFIImage`, `../UEFIContentSource`,
`../ToolModuleKit` and `../../Modules/UEFITool`. The app links none of it.

| target | what | depends on |
|---|---|---|
| `ServerAuth` | `HTTPPrincipal`, `HTTPAuthorizer`, `TokenStore`, hashes, presets, one-time secrets, console cookie and CSRF | `HTTPService`, CryptoKit, Foundation |
| `DumpHost` | `DocumentRegistry` (an `AgentDocumentSet`), `DocumentHost`, `SnapshotReader`, `documents.json`, uploads, limits | `AgentDocuments`, `AgentKit`, `UEFIImage`, `UEFIContentSource`, `ToolModuleKit` |
| `ServerMCP` | the `AgentServer`, `documents`/`read`/`find_bytes`, the tool assembly, headless descriptions, the activity registry | `AgentKit`, `AgentDocuments`, `DumpHost`, `UEFITool`, `ToolModuleKit`, `BytePattern`, `GhidraHost`, `CodeAnalysis` |
| `ServerConsole` | `/admin`: pages, JSON, sign-in, tokens, activity, status | `HTTPService`, `ServerAuth`, `DumpHost`, `ServerMCP` (the socket's activity rows), `AgentKit` |
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
- **A request is authorized on its headers, before its body is read.** The
  parser asks the server once the request line and headers are in; the
  authorizer is synchronous for that reason. A request without an accepted
  token is answered 401 and its body never read — the connection goes unless
  there was no body — so nobody without a token can make the server hold an
  upload. Every path is asked for a token, a route or not, so a stranger
  learns nothing of what is served.
- Each route names its body limit and its access in `HTTPRouter.add`:
  `maxBodyBytes` (nil: the server's default, which stays what it is now) and
  `access` — `.token` (any accepted token; the default), `.rights([…])`
  (checked by the router before the handler; a request with no principal is
  refused), or `.open` (no token: the console's sign-in alone).
- A refused right is answered 403 with the rights the token lacks as a list
  in the answer — `{"error": "…", "rights": ["cas.write", "ghidra.use"]}` —
  every one of them in the single answer, not one per attempt, so the app
  and the Ghidra client name them without reading the sentence (decision 4).
- CAS: `cas.read` for the GETs (hello, objects, analyses, reviews, conflicts,
  refs, verify, changes) and for `POST export`, which only reads; `cas.write`
  for `PUT objects`, `POST analyses`/`reviews`/`import`, `PUT`/`DELETE refs`.
- Ghidra: `ghidra.use` for reads and edits; `publish` and `release` need
  `ghidra.use` and `cas.write`. `/mcp`, until it goes (§9), needs both.
- The console cookie is accepted **only** under `/admin`, so a browser session
  cannot reach CAS or Ghidra.
- Sign-in: `GET/POST /admin/login`, the open routes, with the admin token
  (URL-encoded body), through `ServerAuthorizer.signIn` — only an admin token
  signs in; a 32-byte session id, with the hash of the secret it signed in
  with, so a rotation ends it as a revocation does; `Set-Cookie:
  br_admin=…; HttpOnly; SameSite=Strict; Path=/admin; Max-Age=…`. CSRF is
  double-submit: a `br_csrf` cookie plus `X-CSRF-Token`; `Host`/`Origin`
  checked against decision 19's names; failed sign-ins delayed and throttled.
  `Secure` waits for TLS.
- Sessions are kept in `sessions.json` beside `tokens.json` (0600, the
  SHA-256 of each session id, never the id), so a restart or a rebuild does
  not sign the operator out; the cookie's `Max-Age` keeps it across a browser
  close. A session ends at sign-out, after 30 days without a request, or when
  its token is rotated or revoked. The file's session dates reach it every few
  minutes at most, not on every poll.
- A console route is refused by the authorizer, before the router runs, so no
  page can answer a missing session with a redirect to the form. The shell —
  the pages' HTML, CSS and script, which hold no data — is therefore `.open`
  as well, and everything it shows comes from `/admin/api/*`, which needs the
  session; a page opened by hand without one is answered 401, naming
  `GET /admin/login`.
- Two things follow from an `.open` shell. The `Host`/`Origin` check of
  decision 19 cannot live in the authorizer, which an open route never
  reaches — and `POST /admin/login` needs it most: without it a page on a
  rebound name could try tokens through the form, or sign a browser in to an
  attacker's session. It runs where the server admits a request, on its
  headers, for every path under `/admin`, open or not; the delay and the
  throttle of failed sign-ins stay in the sign-in route. And the router
  takes the first route that matches, so the shell names its pages one by
  one rather than as `/admin/*page`, which, added before `/admin/api/*`,
  would answer the API's GETs without a session. A test asserts
  `GET /admin/api/status` without a session is a 401.
- `tokens.json`: `{version, tokens: [{id, name, hash, rights, created,
  last_used, revoked}]}`; SHA-256 (the secret is 32 random bytes, so a slow
  hash buys nothing), constant-time compare, a file lock waited for two
  seconds at most, written 0600 from its first byte and renamed into place; a
  file that stops reading leaves the server with no token accepted until it
  reads again, and says so in the log once. `last_used` is kept in memory and
  written at most once a minute and at stop — never a file write per request.
  CLI: `byteripper-server token add|list|rotate|revoke`, the secret printed
  once.
- `TokenFile` and `--token-file` are deleted.

## 6. Documents

- `DocumentRegistry` (`@MainActor`, an `AgentDocumentSet`): open by path or
  upload, close, reopen, forget a missing row, list, reorder; ids persisted;
  new ids from `next_id`, never reused (decision 10).
- `SnapshotReader: ToolContentReader` over the `Data` read at open — the
  snapshot of decision 9.
- `DocumentHost: ToolReadHost, UEFITreeProviding`: `fileName`, `contentSize`,
  `read`, `snapshot()`, `contentVersion = version`; `uefiTree()` lazily builds
  `LazyUEFITree(ToolContentByteSource(reader: snapshot))` (not
  `WindowedByteSource`, which is internal to `UEFIImage`); the tree lives with
  the document.
- Reopen: reread, rehash, `tree = nil`, `version += 1`, same id; the new hash
  and `version` are written to `documents.json` at once, so a restart after a
  Reopen does not roll the version back. The tree is not rebuilt under the
  agent.
- The disk mark (decision 9): `DocumentHost.diskState()` takes the `stat` and
  answers `nil`, `.changed` or `.gone`. `documents` lists it as `disk`, and
  every tool that resolves a document — through `ToolQueryTools`,
  `CodeReadings`, `GhidraNodeOpen` or the server's own `read` and
  `find_bytes` — adds `"disk": "changed"` or `"disk": "gone"` to its answer
  when it is set, and nothing when it is not.
- Reopen of a `gone` document does not fail: the document becomes a missing
  row (decision 18's reason "the file is gone") that keeps its id, and comes
  back under it as any missing row does.
- Restore: each row of `documents.json` is checked by decision 18, read, and
  its hash compared with the stored one (decision 10). Rows are restored in
  their stored order — the order the console's reorder sets — and each is
  admitted if the limits (decision 11) still allow; each one that does not
  fit stays missing, so which documents open does not depend on the order the
  files happen to be read.
- A `documents.json` that names one id twice, or whose `next_id` is already
  passed by a row, is refused at start rather than trusted: an id handed out
  twice is the one thing the file must never allow.
- A missing row holds its id and serves nothing, and carries its reason: the
  file is gone, the path is outside the roots, **the root it was opened under
  is not there**, or a limit (named) refused it.
  `documents` does not list it; a call naming its id is told that reason —
  not that the id is unknown, and not "missing" when the file is there but
  over a limit. The console shows the same reason, and offers Reopen (which
  re-runs decision 18 and the limits) and Forget.
- Limits: `--max-documents` (8), `--max-open-bytes` (512 MiB), counted over
  file sizes and checked before opening.
- A `--dump-roots` that does not resolve is kept, not dropped: `absentRoots`
  names it, the server says so at start, and a document under it is missing
  for that reason, never as "the file is gone". The roots are resolved at
  each check, so mounting the volume and a Reopen — or a restart — brings
  its ids back. A root that is there does not excuse a file
  that went: that stays "the file is gone".
- Opening, reopening, a restore and an upload read and write in a detached
  task, off the main actor, which also runs the tools and the console; the
  `stat` is taken before the read (decision 10). `documents.json` itself is
  written on the main actor — it is small. Those four run one at a time, so
  one file opened twice at once is one id and two opens cannot both take
  the last place under a limit; Close, Forget and Delete do not wait, and a
  Reopen finds its row again by id after the read — one closed meanwhile is
  refused, never written over another. A restore empties the rows before it
  fills them, so the server finishes it before it opens the socket or the
  console.
- Upload: `POST /admin/api/uploads?name=…` with a raw body (there is no multipart
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
  `UEFIAgentQueries.all(catalogue:)`, `UEFIAgentChecksums`, `UEFIAgentDMI`,
  `UEFIAgentVariables.queries`, `UEFIAgentNodeData` — `UEFIAgentRegions` is
  not served: `region_scan` follows with ME and FIT (decision 15);
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
- Descriptions: `code_query`, `code_modules` and `ghidra_open` take their
  words from the host (`CodeReadings.Wording`, the description
  `GhidraNodeOpen.tools` is given); the rest — the module queries, and the
  server's own `documents`/`read`/`find_bytes` — are worded from a
  `ServerToolText` table in `ServerMCP`, which overrides the panel-oriented
  texts. `Modules/UEFITool` is not edited.
- `ServerRelay`: `ServerCommand.parse` answers `.relay(socketPath)`, and `main`
  handles it before a `Server` exists; the path is `--mcp-socket` or
  `BYTERIPPER_SERVER_SOCKET`. A test asserts the mode creates no HTTP listener,
  no store and no Ghidra project.
- Activity: socket connections with start, end, client, calls, last tool,
  documents and errors, and a log of the recent calls (tool, start, duration,
  outcome) — in memory, one row per connection. A call is logged when it
  starts and replaced by its finished record under the same id, so a tool
  still working shows as a running line.
- A call's line keeps its arguments as compact JSON, cut at 2048 characters,
  the tool's error in its own words, and the answer's size. A connection is
  "at work" while a call runs and for two seconds after one ends — the app's
  `AgentService.activityHold` — and the console shows that as a red lamp
  blinking where Live stands, at the app's toolbar dot's rate (steady under
  Reduce Motion).
- The Activity card shows the last three calls and opens the connection's
  log in a panel from the right: the calls newest first with time, tool, the
  arguments that say what it was about, duration as a bar and a number, the
  answer's size and the outcome; a search over tools, arguments and errors;
  filters for errors, running calls and one tool; Live tail, which paused
  holds the list still and counts the calls since; and the selected call's
  error and arguments, with a copy, below. Arrow keys move the selection,
  Escape closes it.
- The console's Configuration page carries the connection itself (`GET
  /admin/api/configuration`, `ConsoleAgent`), for the clients the app's
  Settings ▸ Agents offers: Claude Code (`claude mcp add --scope user`),
  Claude Desktop and Cursor (one `mcpServers` block, with where each keeps
  its file), and any other client's parameters one by one — with the
  socket, the relay's binary and the command beside them. The binary's
  absolute path is the server's own (`CommandLine.arguments`), which a
  client on this Mac has no other way to guess. The server is registered as
  `byteripper-server`, so in one client it sits beside the app's
  `byteripper` rather than replacing it. Activity points there when no agent
  is connected; Status keeps the socket and a way to the page.

## 8. The console

- `ServerConsole` serves `/admin` and the pages Documents, Activity, Tokens and
  Status; the HTML/CSS/JS are resources of the target (SPM resources), read
  once at start, with the app's own icon (`icon.png`, the 256 px AppIcon). One
  page, drawn by its script: the shell answers each page's path, and the
  script shows the one in the address.
- JSON: `GET /admin/api/session`, `/admin/api/documents`,
  `/admin/api/activity`, `/admin/api/tokens`, `/admin/api/status`, and
  `/admin/api/browse?path=…` — the file browser a dump is picked in
  (`DumpBrowser`): the roots at the top, then a folder's folders and files,
  folders first and hidden ones left out, each file the registry holds named
  by its id. Only a folder that resolves inside a root is listed, by the
  same `realpath` rule as opening (decision 18), so neither `..` nor a link
  walks out; a link out of the roots is listed and marked, and refused if
  followed. A folder lists 2000 entries at most, off the main actor. Actions:
  `POST /admin/api/documents` (open by path, `~` expanded), `POST
  /admin/api/uploads?name=…`, `POST /admin/api/documents/:id/reopen`
  (an open document or a missing row), `…/close`, `…/forget` (a missing row),
  `DELETE /admin/api/documents/:id` (uploads only), `PUT
  /admin/api/documents/order`, `POST /admin/api/tokens` (a preset or rights),
  `POST /admin/api/tokens/:id/rotate`, `…/revoke` — the last live admin token
  is not revoked, the console and the next start need one — and `POST
  /admin/login` / `/admin/logout`. A refusal of the registry or the token
  store is a 422 with its sentence, a name already taken a 409.
- Every console answer carries `Content-Security-Policy` (`'self'` only, no
  inline script or style), `X-Frame-Options: DENY`, `nosniff`,
  `no-referrer` and `no-store`. The page writes every value with
  `textContent`: a document's name comes from an upload.
- Sign-in: a failed attempt is answered after a second, and every attempt
  that arrives meanwhile waits it out (`SignInGate`). The cookies are
  `br_admin` (HttpOnly) and `br_csrf` (read by the page, sent back as
  `X-CSRF-Token`), both `SameSite=Strict; Path=/admin`.
- `Host`/`Origin` (decision 19): `ConsoleNames` — the listen hosts, their
  addresses, every loopback name for a loopback listener, this Mac's
  addresses and names for a wildcard one, and `--server-name` — screens every
  `/admin` request on its headers through `HTTPServer.Configuration.screen`,
  before the route and the authorizer; `Sec-Fetch-Site: cross-site` is
  refused too. The set is fixed when the server starts: an address a wildcard
  listener gains later — a new lease, a tunnel — is refused until the server
  restarts or the name is given with `--server-name`.
- Polling: every two seconds, and every second on Activity — the page that
  shows what a tool is doing right now. No SSE or WebSocket, because
  `HTTPService` sends complete responses only.
- Activity: REST rows per token from `onRequest` (name, last seen, requests,
  refused, last method/path/status, and a log of the recent requests), the
  console's own requests not counted and requests without an accepted token on
  a row of their own; MCP rows from the socket with the same log of calls. A
  request is reported when it starts and again when it answers, under one id,
  so a running call is on the page rather than only its count. A connection
  with a call in flight blinks, as the app's toolbar badge does. The log
  leaves out the console's answered reads.
- Status: version, addresses, server names, roles, store, Ghidra, documents and
  bytes, limits, socket path, uptime, sessions, and the resident memory.
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
   per request. The rights on the roles (first planned as phase 6) landed
   here too: tokens with presets were being issued, and without them a
   `reader` token could publish through `/mcp`.
2. **The app side of tokens** — done: the app sends its token on loopback
   (a test now holds the server to it), a 403 carries every missing right as
   a field (`"rights"`, all of them in one refusal) and the app names them, a
   refused token — or none kept on this Mac — is its own state instead of an
   unreachable server, and the Settings caption and the page on the Code
   Analysis settings name `token add` in English, Russian and German;
   `help_coverage.py` and `help_names.py` are clean.
3. **`AgentDocuments`** — done: the package, `AgentDocumentSet`,
   `ToolQueryTools`, `CodeReadings`, `GhidraNodeOpen`; the app moved onto
   them with no change in what its agent sees — its tool list, names,
   descriptions and schemas, is the same byte for byte before and after, and
   `AgentToolListTests` pins it in a golden file so the next move cannot drift
   it unseen.
   Each host gives the tools their words (`CodeReadings.Wording`, the
   description of `ghidra_open`), so the server's can name no panel.
   `UEFICodeOpening` moved to the UEFI Structure's pure target, its codec
   staying in the UI one. Package tests for the document rule, the adapter
   and the replaced `ghidra_open`; the app's agent tests run unchanged and
   pass.
4. **`DumpHost`** — done: `DocumentRegistry`, `SnapshotReader`,
   `DocumentHost`, `FileStamp` and the disk mark, `documents.json` with the
   saved ids, hashes, stamps, versions and `next_id`, decision 18, the
   limits, and uploads kept as `Uploads/<sha256>`; a synthetic image in the
   server tests (`ByteRipperServerTests/SyntheticDump.swift`); a test that a
   file rewritten in place after open does not change what the snapshot
   answers. A Reopen of an open document that would pass a limit is refused
   and leaves it open; a `documents.json` that would reuse an id stops the
   start; a `--dump-roots` that is not there is named as such, and its
   documents are missing for that reason, not as deleted files. Reads and the
   upload's write run off the main actor, the changes that read one at a
   time; tests hold a read to close a row under its Reopen and to open one
   file twice at once. The registry is not yet started by
   the server: the flags (`--dump-roots`, `--max-documents`,
   `--max-open-bytes`, `--max-upload-bytes`) and the restore at start come
   with phase 5, which is the first to serve the documents.
5. **`ServerMCP` and `ServerRelay`** — done: `ServerTools` assembles the list
   (the server's `documents`/`read`/`find_bytes`, the UEFI Structure's
   queries through `ToolQueryTools` with the texts that name the app's screen
   reworded in `ServerToolText`, `CodeReadings`, and Ghidra's with
   `ghidra_open` by a node under `--ghidra`), `MCPSocket` serves it on
   `<Server>/mcp.sock` with a row per connection in `ServerActivity`, and
   `ServerRelay` is the stdio↔socket bridge behind `byteripper-server relay`.
   `MCPEndpoint` and its tests are gone; `/mcp` answers 404. The server now
   takes `--dump-roots`, `--max-documents`, `--max-open-bytes`,
   `--max-upload-bytes` and `--mcp-socket`, restores `documents.json` at
   start and reports the roots that are not there. Tests: the forbidden names
   absent and the served ones present once, `documents`' keys, the tree and
   the bytes of the synthetic image, the disk mark in an answer, a search,
   a call through the socket, and the relay with and without a server.
   `find_bytes` runs `BytePattern`'s scan off the main actor and pages with
   `AgentPage`, as the app's does; a test pages through every match, the
   ASCII and UTF-16LE ones at one address both. `uefi_at` and
   `uefi_node_data` are reworded too, and two tests keep the rewordings
   honest: every one is of a served query, and no served description names
   a panel, a part, the focus, `survey`, `reveal` or `write`. `region_scan`
   is not served (decision 15), and a test names it among those that must
   stay out.
6. **Rights on the roles** — done in phase 1: each route names its access,
   and the rights matrix is tested end to end over a running server.
7. **The console** — done: `ServerConsole` (§8) with the pages, sign-in and
   CSRF, decision 19 through `ConsoleNames` and `HTTPServer`'s screen,
   documents and upload, activity, tokens, status; `--server-name`;
   `HTTPResponse.cookies` for the two `Set-Cookie` lines. Its shell `.open`
   with its pages named one by one, its data behind the session. Loopback
   tests: the API refused without a session and no page answering an
   unlisted name; sign-in by JSON and by form, a non-admin token refused, a
   change without its CSRF token refused, the cookie refused outside
   `/admin`, sign-out ending the session; an unlisted `Host` refused over the
   wire and `Origin`, `null` and `cross-site` refused; open by path (and
   refused outside the roots), upload, the disk mark, Reopen raising the
   version, the order, Delete for uploads only, Close; a secret answered once
   and never listed, rotate refusing the old secret, the last admin token
   kept, a revocation ending its sessions; REST rows per token; the status;
   a failed sign-in slowed.
8. **Documentation and measurements** — done: `SERVER_PLAN.md` brought back
   in line (tokens with rights, the dumps, the local MCP, the console, the
   flags) and the skill's server section rewritten (token commands, the
   relay, no `/mcp`); the numbers of §11 taken. What they decide, and what
   they do not: `relay` at 0.8 MiB and 0.02 s needs no executable of its own —
   the binary it ships in already starts none of the roles, and the target
   that carries it imports `AgentKit` alone. A cap on decompressed buffers is
   not added: 28 MiB of them for a 16 MiB image stays far under
   `--max-open-bytes`, which bounds the snapshots and so, indirectly, what is
   decompressed from them. If a large image measures worse than 1.75× its
   size, the cap returns to this list with that number.

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
  down coming back with `version` bumped, a Reopen's version surviving a
  restart, a missing row keeping its id and getting it back when the file returns, a returning
  row over a limit staying missing with that limit named (to the console and
  to the agent), restore in the stored order when the saved set no longer
  fits, missing rows not counted in the limits, no id reused
  after close or Forget, a file replaced with `cp -p` (same size and mtime)
  marked `changed`, the mark in the answer of `uefi_tree` and not only in
  `documents`, a deleted file still answering from its snapshot and marked
  `gone`, Reopen of a `gone` document leaving a missing row with its id, the
  activity of the MCP and of the REST clients, an
  unlisted `Host` refused.
- Measurements, taken on 2026-10-29 on `admins-imac`, macOS 15, with the
  server serving a 16 MiB SPI dump (`W25Q128FV.lenovo.la-c422p.orig.bin`):
  `relay` — a whole process start, the connect and a `ping` answered in
  0.02 s, 0.8 MiB resident while connected; the server — 59.5 MiB with two
  16 MiB snapshots open, 60.2 MiB once `uefi_tree` read the top of one,
  88.5 MiB after `uefi_find` opened every volume and decompressed every
  section (507 PE32 images), so the decompressed buffers of that image cost
  about 28 MiB, some 1.75× its own size. The console's Status page reads the
  process's resident memory at each ask.

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
