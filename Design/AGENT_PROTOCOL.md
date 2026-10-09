# The agent protocol — what ByteRipper says to an agent

> The contract both editions keep (`Design/AGENT_PLAN.md`): the transport,
> the conventions every answer follows, and each tool's arguments and answer.
> Swift is the reference; the web edition ports this, not the Swift. A change
> here is a change to an interface an agent may have been told about — say
> why in the commit.

Draft until stage 8 marks it version 1. The tool list grows by stage; what
is listed here is what the code answers today.

## Transport

- Newline-delimited JSON-RPC 2.0, one message per line, over a byte stream:
  the relay's stdin and stdout on the client's side, a Unix-domain socket
  (`~/Library/Application Support/ByteRipper/agent.sock`, mode 0600) on the
  app's. `BYTERIPPER_AGENT_SOCKET` moves the socket, for both ends.
- Both eras of MCP are served. A request whose `params._meta` carries
  `io.modelcontextprotocol/protocolVersion` is **modern** (`2026-07-28`): it
  must also carry `io.modelcontextprotocol/clientCapabilities`, every result
  carries `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`,
  and `server/discover` and `tools/list` carry `ttlMs: 300000` and
  `cacheScope: "public"`. An `initialize` opens a **legacy** connection
  (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`); its results carry
  none of those.
- Methods: `initialize`, `server/discover`, `ping`, `tools/list`,
  `tools/call`. Notifications in: `notifications/initialized` (ignored),
  `notifications/cancelled` (the call stops and is never answered). Out:
  `notifications/progress`, only for a request that carried a `progressToken`,
  never decreasing.
- The tool list is fixed while the app runs; `listChanged` is false.

Recorded against: Claude Code 2.1.292 (modern; `RecordedClientTests`).

## Conventions

- **Addresses and sizes are hex strings**, `"0x7F3000"`, in every answer.
  Every address argument takes a hex string or a decimal integer.
- **Ranges are half-open**: `{start, end, length}`, `end` the first byte after.
- **Documents** are named by ids `d1`, `d2`… minted when an agent first sees
  a document and good while it stays open. A tool that takes `document`
  defaults to the focused one.
- **UEFI nodes** are named by their place in the tree, `"0.2.5"` — exact for
  those bytes, meaningless in another dump. Find a node in another dump by
  what it is (`uefi_find`).
- **Refusals** are tool results with `isError: true` and one sentence saying
  what to do instead. Protocol errors (`-32602` unknown tool or bad params,
  `-32601` unknown method, `-32022` unsupported version) are for malformed
  requests only.
- **Bounds**: a list takes `limit`; a byte read is at most 4096 bytes; an
  answer over 24 KiB is not sent and the agent is told to ask for less.
- **English**, whatever language the window speaks.

## Host tools

| Tool | Arguments | Answer |
|---|---|---|
| `documents` | — | `documents[]`: `id`, `name`, `path` (not for an untitled one), `size`, `unsaved_edits`, `read_only`, `tab`, `slot` (`A`, `B`, `part`), `focused`; for a part, `part_of` and `source` (range in the parent). |
| `focus` | — | `document`, `name`, `caret`, `selection` (range or null), `on_screen` (range), `compared_with` (the other document of a comparison). |
| `read` | `offset`; `length` (default 256, ≤ 4096); `format` `hex`·`ascii`·`utf16le`·`u8`·`u16`·`u32`·`u64`; `endian` `little`·`big` | `document`, `offset`, `length`, `format`; `rows` (hex: `"00001000  4D 5A …  |MZ..|"`), `text`, or `values` (hex strings); `cut_at_end_of_file` when cut. |
| `reveal` | `offset`; `length` (default 0); `select` (default: length > 0) | `document`, `shown` (range), `selected`. A navigation step. |
| `open_panel` | `module` (`zonesketch`, `fit`, `uefi-structure`, `me-analyzer` — the last part of the module's identifier) | `document`, `module`, `panel`, `was_open`. A navigation step. Refused while a sheet is up. |

## Marks

| Tool | Arguments | Answer |
|---|---|---|
| `mark` | `offset`, `length` (≥ 1), `label` (≤ 80 characters); `note` (≤ 600); `related_to` (mark ids) | `id` (`m1`, `m2`… one counter for the app), `document`, `range`, `label`, `note`, `related_to`. Does not move the view. |
| `unmark` | `ids`, or `document`, or `all: true` | `removed[]`; `not_found[]` for ids there were not. Relations to a removed mark go with it. |
| `marks` | `document` (default: every document) | `marks[]`, each as `mark` answers. |

A mark lives on its document's pane: drawn dashed in the agent's colour over
the dump, its label and note shown under the pointer, listed in the Agent
window. It goes with `unmark`, the window's buttons, or its document.

## Many dumps

| Tool | Arguments | Answer |
|---|---|---|
| `open_dump` | `path` (absolute or `~/`) | `document`, `on_screen` (true when a tab already has the file, and the id is that tab's), `size`. Read-only, no window; the last eight are kept parsed. A file changed on disk is read again under the same id. |
| `close_dump` | `document` | `closed`. Refuses a document in a tab. |
| `show` | `document`; `offset`, `length` | `document` (on screen), `shown`, `replaces` (the background id it replaced). Opens a new tab, or brings forward the tab that has the file. |
| `survey` | `folder` (+ `recursive`) or `paths`; `tool` (one that takes `document`); `arguments`; `group_by` (dotted path, `-1` for the last element); `limit` (20, ≤ 100) | `files`, `groups[]` (`value`, `count`, `files` — ten at most), `more_groups`, `failed[]` (`file`, `error`). Progress per file. At most 200 files. |
| `finding` | `text`; `document` or `path`; `offset`, `length`, `node` | the finding: `id` (`f1`…), `path`, `range`, `node`, `text`. |
| `findings` | — | `findings[]`. |

A background document is answered about by every tool that reads — `read`,
`documents`, the module queries — and refused, with `show` named, by every
tool that shows: `focus`, `reveal`, `mark`, `open_panel`, panel actions.

## UEFI Structure

Queries — answered with the panel open or not, from the pane's shared tree:

| Tool | Arguments | Answer |
|---|---|---|
| `uefi_tree` | `node` (default the top); `depth` 1–3; `limit` (100, ≤ 400) | `image` (summary, at the top) or `node`; `children[]`, each a node summary, with `below[]` past depth 1; `note` when cut. |
| `uefi_node` | `node` | `node`, `path` (names from the top), `title`, `fields[]` (`label`, `value`, `problem`), `tables[]` (`title`, `columns`, `rows`), `diagnostics[]`. |
| `uefi_find` | any of `name` (part, any case), `exact`, `guid`, `type` (the Type column); `limit` (50, ≤ 200) | `matches[]` (node summary + `path`), `total`. Opens and decompresses everything once. |
| `uefi_at` | `offset` | `offset`, `chain[]`, outermost first. |

A node summary: `id`, `type`, `subtype`, `name`, `guid`, `start`/`end` — or
`in_compressed: true` and `size` for a node inside a decompressed section —
`children` (a count, or `"unread"`), `erased`.

Actions — on the live panel in the document's tab; refused with a pointer to
`open_panel` when it is not open:

| Tool | Arguments | Answer |
|---|---|---|
| `uefi_select` | `node` | `selected` (node summary). Opens the tree down to it, selects it, publishes its zone so the dump scrolls there. A navigation step. |
| `uefi_selection` | — | `selected` (node summary or null); `note` when an ME row is chosen instead. |
