# The agent — an MCP service inside the app

> An agent beside the person at the bench. It sees the caret and the
> selection, asks the parsers about the dump, opens the panel it needs and
> shows a node in it, marks bytes and says what they are, and — when allowed —
> edits the open file through the undo the person uses. As a second class of
> work, it reads a folder of dumps without putting them on screen and reports
> what they share and where they differ. Issue #23.

## Why

The questions ahead — the OEM configuration record by record (#4), the
variables that hold a password (#6), the DMI area vendor by vendor (#8), a
variable's bytes named from the Setup forms (#24) — are all worked out by
looking at dumps. An agent does that today by reading a package to find its
API, building a scratch tool against it, and diffing reports with `awk`. That
is the cost the original #23 set out to remove, and a command-line server
would remove it.

What a command-line server cannot do is the conversation. The useful question
is about *this* byte and *this* node, and an agent outside the app can only be
told an address in words and answer in words. Pointing has to work both ways:
the person points with the caret or a click in the tree, the agent points by
moving the view, selecting, and marking. That needs the app.

## Decisions taken

- **The app leaves the sandbox first** (#30). A socket, a dump named by path,
  a folder surveyed — each is a fight with the sandbox and none of them buys
  the workshop anything.
- **A service of the app, not a tool-module.** One tool-module is open per tab
  (`ToolController`), and picking another one stops it. The agent has to keep
  working whatever the left panel shows — the UEFI tree on screen *while* the
  conversation is about it. So the service is application-wide, like the
  bookmarks or the search history, and lives as long as the app.
- **Its own window, not the tool panel.** What the agent has to show — whether
  a client is connected, the request log, its marks, its findings — goes in a
  window of its own (Window ▸ Agent); the switches and the client
  configurations are in Settings ▸ Agent. Put in the tool
  panel it would push out the very tree the conversation is about.
- **Agent tools come from three places.** The host's own (caret, reads, view,
  marks, edits, documents); each tool-module's *queries*, declared on the
  module's type and answered with its panel closed; and each live session's
  *panel actions*. The two module levels are explained under "What a
  tool-module contributes".
- **Two kinds of document.** An *open* document is one the person opened: on
  screen, editable, saved only by the person. A *background* document is one
  the agent opened by path: read-only, never on screen, parsed once and
  cached. The query tools do not tell them apart.
- **The contract is the edition-neutral part.** Tool names, input schemas and
  the shape of every answer are written down once, in
  `Design/AGENT_PROTOCOL.md`; Swift is the reference and the web edition ports
  the contract, not the code. The transport is each edition's own.
- **No third-party code.** MCP over a byte stream is newline-delimited JSON-RPC
  2.0. Written here.
- **Answers in English.** That is what the parsers, the specifications and the
  upstream tools (UEFIExtract, MEAnalyzer, PSPTool) say, and what an agent
  compares against. The agent speaks to the person in their language.
- **Off by default.** A Settings switch opens the socket; a second one lets
  the agent edit. Neither is on after an install.

## How it fits together

```
 Claude Code / Desktop
        │ stdio
        ▼
 Contents/Helpers/byteripper-mcp      — a relay: bytes in, bytes out
        │ Unix socket, mode 0600
        ▼
 AgentService (app, main actor)       — connections, sessions, the log
        │
        ├─ AgentKit  (package, pure)  — JSON, JSON-RPC, MCP both eras, registry
        │
        ├─ host tools  (app)          — documents, focus, read, reveal, select,
        │                                open_panel, marks, edits, open_dump,
        │                                show, survey
        ├─ module queries             — ToolModule.agentQueries, against a
        │                                read host (open or background document)
        └─ panel actions              — ToolSession.agentActions, on the live
                                         session, if there is one
```

### `Packages/AgentKit`

Pure Swift, no AppKit, tested by `swift test`. A package of its own because
three parties need it and none may depend on another: the app (the service),
`ToolModuleKit` (the types a module declares its tools with), and every
tool-module's pure target (the query handlers).

- `JSONValue` — the one JSON type, `Codable`, with the small helpers a handler
  needs to read its arguments and fail with a message that names the argument.
- The framing: one JSON-RPC message per line, in and out; a partial line is
  held, an oversized one is refused rather than buffered.
- Both eras of MCP. Revision `2026-07-28` dropped the handshake: every
  request carries its protocol version and the client's capabilities in
  `_meta`, the server keeps nothing between requests, a connection is not a
  session, and `server/discover` is required. The revisions before it
  (`2025-11-25` back to `2024-11-05`) open with `initialize`. Clients of both
  kinds are in use, so `AgentConnection` serves both, as the specification
  allows: a request with the modern `_meta` is modern, an `initialize` starts
  a legacy connection. Methods: `initialize`, `server/discover`, `ping`,
  `tools/list`, `tools/call`; `notifications/progress` out,
  `notifications/cancelled` in.
- `AgentTool` — name, description, input schema, hints (read-only, view,
  edit), and an `async` handler returning JSON or a sentence, or throwing an
  `AgentToolError`. A tool error is an answer the agent
  reads ("the UEFI panel is not open"), not a protocol failure.
- `AgentArguments` — the readers every handler uses. An offset is taken as
  an integer or as hex text (`"0x7F3000"`), because a model reads addresses in
  hex everywhere and should not convert them back.
- The bounds: every list takes `limit` and returns `truncated` and `total`
  when it can count them; a byte read is capped at 4 KiB; an answer over
  24 KiB is not sent, and the model is told to ask for less.

Nothing here knows about dumps.

### The relay

A command-line target in `project.yml`, copied into `Contents/Helpers` by a
copy-files phase. About a hundred lines: connect to the socket, copy stdin to
it and it to stdout, exit when either side closes. If the socket is not there
it launches the app with `open -b` and waits a few seconds for it; if the
switch in Settings is off, it answers every request with an error that says
where the switch is. It knows nothing about MCP beyond reading a request's
`id` for that answer.

The relay is what a client is configured with. Settings ▸ Agent has a button
that copies the configuration for Claude Code
(`claude mcp add --scope user byteripper -- <path>`) and one for Claude
Desktop (the JSON block), with the bundle's real path in it.

### `AgentService`

In the app target, `ByteRipperApp/Agent/`, on the main actor.

- Listens on `~/Library/Application Support/ByteRipper/agent.sock`, the folder
  0700 and the socket 0600: whoever can open it is the user already, and
  nothing reaches it from the network. No port, no token.
- Reads and writes off the main actor, dispatches each call to its tool, and
  hops to the main actor only for what touches the UI.
- One `AgentConnection` per socket connection, and any number at once. A
  connection is not a conversation — the protocol says so, and a client may
  restart its relay at any moment — so nothing the agent made hangs on one:
  marks, findings and background documents belong to the service, and go
  when the agent or the person clears them.
- Keeps a log of every call — tool, target, how long, how big the answer, the
  error if any — for the Agent window. Bounded, not persisted.
- While the service is on, a mark in the menu bar shows it, filled while a
  client is connected. The menu bar rather than a window's status bar: the
  person talking to the agent is typing in another app, with ByteRipper
  behind it.

## What a tool-module contributes

### Queries — answers from the bytes

A query depends only on the dump: the children of a UEFI node, a node's
fields, the nodes matching a name, what holds an offset, the ME analysis of
the region, the FIT table. It needs no panel and no session, so it is declared
on the module's **type**:

```swift
public protocol ToolModule {
    // …
    static var agentQueries: [AgentTool] { get }   // default: []
}
```

and it runs against a **read host** — the part of `ToolHost` that reading
needs:

```swift
@MainActor public protocol ToolReadHost: AnyObject {
    var fileName: String { get }
    var contentSize: UInt64 { get }
    func read(_ range: Range<UInt64>) throws -> [UInt8]
    func snapshot() throws -> any ToolContentReader
}
public protocol ToolHost: ToolReadHost { /* everything else, unchanged */ }
```

For an open document the read host is the pane's own host; for a background
document it is the document. Both also answer `UEFITreeProviding`, which is
how every firmware module already reaches the shared tree
(`host as? any UEFITreeProviding`): an open pane hands over the tree in
`PaneUEFIState`, so a query asked while the UEFI panel is closed is answered
from the same tree the panel will use when it opens, and costs it nothing.

The handlers live in the module's pure target, next to `UEFINodeDetail` and
`UEFITreeSearch` that they reuse, and are tested by `swift test` over the dumps
the module's tests already use.

### Panel actions — what only the open panel can do

Select a node in the tree and unfold the path to it; say which node the person
has chosen; set the tree's search. These need the panel on screen, so they
belong to the **session**:

```swift
public protocol ToolSession {
    // …
    var agentActions: [AgentTool] { get }   // default: []
}
```

The list the agent sees does not change with what is open. Each module's
actions are listed always; called while its panel is closed, one answers
"the UEFI Structure panel is not open in this tab" and the agent decides —
`open_panel`, or `reveal` in the dump instead. Clients are not equally good at
`notifications/tools/list_changed`, and a list that holds still is one an
agent can plan against.

### Identifying a node

`NodeID` is an index path, exact and stable for the same bytes. The agent gets
it as a string (`"0.2.5.1"`) together with a readable path of names
(`"BIOS region / FV 7A9354D9… / Setup / PE32 image"`), and gives either one
back. A node in another dump is found by what it is — GUID, name, kind — not
by its index path: two images do not number their volumes the same way.

## The host's own tools

| Tool | What it does |
|---|---|
| `documents` | Every open document — tab, pane A or B, or fragment panel; file name and path; size; modified or not — and every background one. Each with the id the other tools take. |
| `focus` | The key window's active pane: caret, selection, the first byte on screen; and, from each live session, what its panel has chosen (`navigationMark` read as data). What "this" means when the person says "look at this". |
| `read` | Bytes of a range as hex, ASCII, UCS-2 or integers of a width and an endianness. 4 KiB at most. |
| `reveal` | Bring the document's tab forward, scroll to a range, select it (`select`, by default when a length is given). A navigation step, so Back returns. |
| `open_panel` | Switch a tab's tool panel to a module, through the same door the Tools menu uses: the panel that was there parks its state, and the switch is a navigation step. Refused while a sheet is up, blocking work is running, or a field is being edited. |
| `mark` / `unmark` / `marks` | The agent's marks (below). |
| `write` | Overwrite bytes in an open document as one undo step named by the agent's label. Only with the edit switch on, only overwrite — a write that would move bytes is refused. |
| `open_dump` / `close_dump` | A background document from a path. |
| `show` | Open a background document in a new tab, at a range. Never into a pane that holds a file. |
| `survey` | One query over many files (below). |
| `finding` | Add a finding to the Agent window's list. |

Saving is not a tool. Neither is closing a document the person opened.

## Marks

Zones belong to the session that published them, and `ToolController`
clears them when it stops — deliberately: nothing else draws zones. The
agent's marks are therefore a layer of their own on `PaneViewModel`, drawn in
the dump and the minimap's gutter as a fourth state: not the difference
background, not the red of an unsaved edit, not a tool's zone outline. Each
has a range, a short label and a sentence; hovering shows the sentence,
the Agent window lists them, a click goes to one.

A relation — "this pointer leads there", "this checksum covers that" — is a
pair of marks with a line between their entries in the Agent window, both ends
clickable. Arrows drawn across the dump come later, if pairs turn out not to be
enough.

Marks stay until the agent removes them or the person clears them from the
Agent window, or the document closes. Not with the connection: under the
current protocol a connection is not a conversation, and a relay restarted
mid-conversation must not wipe what the agent showed. A mark the person pins
becomes a bookmark.

## Background documents and surveys

`open_dump(path)` reads a file into the app's chunked storage without a
window, read-only, and returns a handle. It is the same `BinaryDocument` an
open file is — not a second way of reading a file — held by `AgentService`
instead of a pane, with a `PaneUEFIState`-like object beside it for the tree.
Re-opening the same path with the same modification date returns the same
handle; a changed file is read again. Documents are let go least recently used
first, past a memory budget.

`survey(paths | folder, query, group_by, limit)` runs one module query over
many files and returns the aggregate, not fifty answers: for each distinct
value, how many files and which. Files are read in parallel up to a bound,
with progress notifications and cancellation. The query is one of the
module's query tools with its arguments — not code — and `group_by` names a
field of its answer. Detail comes after, by `open_dump` on the files that
matter.

A **finding** is a file, a range or a node, and a sentence. The Agent window
lists them; a click opens the file in a new tab at that place. A claim about
seven files out of fifty becomes seven lines the person can check.

## Language

`L()` reads one process-wide catalogue, and `UEFINodeDetail` alone has 157
calls. A query has to answer in English while the window speaks Russian, so
`Localization` gains a task-local override:

```swift
public enum Localization {
    @TaskLocal public static var override: AppLanguage?
}
```

`current` uses the override's catalogue when one is set. `AgentService` runs
every call with `.english`. The window is not affected.

The agent's tool names and descriptions are read by the model, not by the
person, and stay in English without `L()`; `Design/LOCALIZATION.md` says so,
so the coverage script does not count them as strings a language is missing.

## Edits

A `write` is a `ToolTransaction` through the pane's host: one undo step, red
until saved, refused on a read-only file. Checksums are put right by the code
that already does it (`ChecksumRepair`, `UEFIRebuild`), offered to the agent
as a module action, not computed by the agent. The edit switch in Settings is
off by default; when it is off, `write` answers that and names the switch.

## The web edition

The same contract; its own transport.

- **Electron.** The main process listens with Node's `net.createServer` — a
  Unix socket on macOS and Linux, a named pipe on Windows, one call — and
  relays each line to the page through the preload bridge, beside `setMenu`.
  The tools run in the renderer, where the documents and the parsers are. The
  relay a client launches is the app's own executable with
  `ELECTRON_RUN_AS_NODE=1` and a script, as long as the `RunAsNode` fuse stays
  on; a small binary if it is turned off.
- **Browser.** A page cannot listen. The relay would serve a WebSocket on
  loopback with a token, and the page connect to it — with Chrome's
  local-network permission prompt and a relay installed separately. Not
  planned.

`ByteRipperWeb`'s `Design/GAPS.md` gets a row when stage 2 lands here.

## Stages

Each ends in something that works and is committed.

0. **Out of the sandbox** — #30.
1. **AgentKit.** JSON, framing, both eras, registry, bounds. Done when
   `swift test` drives a legacy handshake and a modern discover-list-call
   through it, cancellation and progress included. *(Done. The transcripts in
   the tests follow the schemas; a real client's is recorded at stage 2, where
   there is a socket to record it on.)*
2. **The loop, end to end.** Relay, service, the Settings switch, the menu
   bar mark, the Agent window with the log; `documents`, `focus`, `read`,
   `reveal`. Done when Claude Code answers "what is under the caret" and "go
   to 0x7F3000", and Back returns. *(Done. Claude Code 2.1.292 speaks the
   modern era and refused the tool list until it carried `ttlMs` and
   `cacheScope`; its recorded requests are `RecordedClientTests`. The
   protocol document waits for stage 3, when module tools give it something
   beyond four host tools to fix.)*
3. **UEFI queries and actions.** `ToolReadHost`; `agentQueries` and
   `agentActions` on the seam; the language override; `tree`, `node`, `find`,
   `at`; `select_node`, `panel_selection`; `open_panel`. Done when, with the
   FIT panel open, "find the Setup variable store and show it to me" ends with
   the UEFI tree open on it.
4. **Marks.** The layer, its drawing, the window's list, relations as pairs.
5. **Background documents.** `open_dump`, `close_dump`, `show`, `survey`,
   findings. Done on the AMD and Intel dumps in `~/Desktop/ME`: one survey
   question answered across all of them, its findings clickable.
6. **ME, FIT and NVRAM.** The ME and FIT modules' queries; `variables` across
   VSS, NVAR and the rest, and a comparison of two documents' variables by
   name and GUID.
7. **Edits.** `write`, the edit switch, checksum repair as an action.
8. **Help and release.** The help page in en, ru and de with its anchors; the
   Settings controls through `ControlHelp`; the protocol document marked
   version 1; the README; whether an ad-hoc signed, quarantined helper runs
   when a client launches it, tried on a clean account.

Stages 3 and 4 can swap. Stage 6 is where the work for #4, #6 and #8 starts
paying.

## Testing

- `AgentKit` by `swift test`, including malformed input and a peer that
  closes mid-line.
- Each module's queries by its own `swift test`, over the images its tests
  already build or read.
- The host tools in the app suite through an in-memory connection, not the
  socket: a test opens a file, calls `focus`, `reveal`, `open_panel`, and
  checks the window, the selection and the history.
- One smoke test through the real socket and the real relay.

## Cost

AgentKit, a day and a half. The service, relay, window and settings, three
days. The seam changes and the UEFI tools, three days. Marks, two. Background
documents and surveys, three. ME, FIT and NVRAM, three. Edits, one. Help and
translations, one and a half. About 18 days, 140–150 hours — three times the
original #23, because what is built now is a feature of the app and not a tool
beside it.

## Open questions

- **The ME analysis has no shared home.** The UEFI tree lives per pane in
  `PaneUEFIState`; the ME analysis lives in the ME Analyzer's session and goes
  with it. A query that wants it with the panel closed would parse the region
  again. It needs a per-document cache like the tree's — decided at stage 6.
- **What a survey's query may be.** One query tool and a `group_by` is the
  start; whether it needs a filter, or two fields at once, is learnt on the
  first real survey.
- **Marks across a relaunch.** Gone when the app quits, unless pinned. If
  pinned marks turn out to want more than a bookmark holds, that is a project
  file (#19).
- **Which era clients speak.** Both are served. Which one Claude Code and
  Claude Desktop actually open with is recorded at stage 2, and the protocol
  document says which transcripts the tests are checked against.
- **The relay and Gatekeeper.** Whether a quarantined helper inside an app the
  person has already let run is let run by a client. Tried at stage 8; if it is
  refused, the window's button also clears the attribute on the helper.
- **A chat inside the window.** Not in this plan. Everything above is what
  such a panel would call; whether to build one is decided after the external
  client has been used on real work.
