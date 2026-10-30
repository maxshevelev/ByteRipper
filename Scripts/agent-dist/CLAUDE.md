# ByteRipper analysis install

This folder is a self-contained ByteRipper analysis server and the skill that
reviews firmware modules with it. Everything it keeps — the code store, the
modules' kept Ghidra projects, the documents and their uploads, the tokens, the
MCP socket — is under `var/` here. No path points at another install, at the
ByteRipper app's folders, or at a repository.

## The tools

The session's MCP server `byteripper` is `bin/byteripper-server relay`, which
speaks to the running server over `var/support/mcp.sock`. It carries:

- `documents`, `read`, `find_bytes` — the dumps this server holds;
- `uefi_tree`, `uefi_find`, `uefi_node`, `uefi_node_data` — a firmware image's
  structure, down to the PE32 and TE images inside compressed sections;
- `ghidra_open` and the `ghidra_` review tools — the decompiled C, names,
  signatures, types, comments, the module description, `ghidra_publish`;
- `code_modules`, `code_query` — the stored analyses, readable without Ghidra.

A module is named by the SHA-256 of its bytes; `ghidra_open` takes its image
`node` and `document`, and the server sends the bytes.

## The skill

`skills/ghidra-uefi/SKILL.md` is the review discipline — finding the module,
opening it, and what a review makes of the code, with `reference/` for the
structures, the artifact and the store. Read it before the first review;
`/ghidra-uefi` loads it.

## The server

- `scripts/start-server.sh` brings it up, `scripts/stop-server.sh` takes it
  down, `scripts/restart-server.sh` does both, `scripts/doctor.sh` says what is
  missing. `scripts/agent.sh` does the first, writes `.mcp.json` with this
  folder's absolute paths and starts a Claude Code session here.
- The console is `http://127.0.0.1:<port>/admin` (the port is in `var/port`);
  its token is `var/admin-token.txt`.
- Ghidra is not shipped. `GHIDRA_HOME` names an install; otherwise the newest
  `~/Projects/ghidra/ghidra_*` is used. A JDK is needed for the owner.
- Dumps go in `var/dumps`, the one folder the console may open dumps from.

## Rules

- Never point this server at another install's folders, and never run two
  servers on the same `var/`.
- `var/` is the analyses themselves: do not delete it, and do not edit files
  in it by hand — a review's changes arrive through `ghidra_publish`.
- What the person asks about a module is answered from the tools, not from
  memory of another dump.
