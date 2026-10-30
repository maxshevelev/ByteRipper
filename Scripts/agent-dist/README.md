# ByteRipper analysis

A firmware analysis server and the Ghidra review skill, in one folder. It is
independent of the ByteRipper app and of any source checkout: install it
anywhere and start an agent session in it.

## What you need

- macOS 14 or later;
- a Ghidra install (12.1.2 is the version the analyses are keyed by) and a
  JDK — `GHIDRA_HOME` names the install, or the newest
  `~/Projects/ghidra/ghidra_*` is used;
- network access on the first module opened: EDK2's headers are fetched once
  into `~/Library/Application Support/ByteRipper/Ghidra`.

## Start

```bash
./scripts/agent.sh          # the server, then a Claude Code session here
```

If that answers `Permission denied`, the copy lost its executable bit on the
way here (a file taken from a web view, a drive without file modes):
`chmod 755 bin/* scripts/*.sh` once.

Or, by hand:

```bash
./scripts/start-server.sh   # idempotent; makes the console token on first start
./scripts/stop-server.sh
./scripts/restart-server.sh # stop, then start — after a configuration change
./scripts/doctor.sh         # what is there, what is missing
```

The console is at `http://127.0.0.1:<port>/admin` — the first free port from
8765, written to `var/port`, or `BYTERIPPER_PORT`; the token is in
`var/support/admin-token.txt`. Open a dump from it — the dumps it may open are
under `var/dumps` — and the agent's tools see it.

## Configuration

The server reads **`~/.byteripper-server.json`** — a file you make in your home
folder — every time it starts. A flag on the command line still wins over it,
so nothing in the file stands in the way of what you type.

```json
{
  "ghidraHome": "~/Projects/ghidra/ghidra_12.1.2_PUBLIC",
  "dumpRoots": ["~/Dumps"],
  "listen": ["127.0.0.1:8765"],
  "idle": 1800
}
```

Every flag of `byteripper-server --help` is a key without its `--`: `support`,
`store`, `projects`, `dumpRoots`, `ghidraHome`, `ghidraScripts`, `tokens`,
`mcpSocket`, `listen`, `serverName`, `idle`, `maxDocuments`, `maxOpenBytes`,
`maxUploadBytes`. Paths are strings (`~` is expanded), lists are arrays, sizes
are numbers or `"512 MiB"`, and `serverName` is a name or a list of names.
`listen` and `dumpRoots` are lists a flag adds to:
the launchers' `--listen 127.0.0.1:<port>` does not drop the tailnet address
the file names. A `tokens` (or `mcpSocket`) in the file outlives the
launchers' `--support`: it keeps the store's credentials where the app keeps
them, and `--tokens` on the line still wins. `--config <file>` names another
file and `--no-config` reads none; a key the server does not know is refused
with its name — and a close one is suggested — never ignored. `INSTALL.md` has
the table and an example that keeps a copy self-contained.

## What is where

```
bin/            byteripper-server, byteripper-cas
ghidra/         the Ghidra scripts the server compiles and runs
skills/         the review skill the agent reads (SKILL.md, reference/)
scripts/        start-server, stop-server, restart-server, agent, doctor
var/            everything this install keeps: store, projects, support, dumps, log
CLAUDE.md       what the agent is told about this folder
VERSION         what was built, from which commit
```

## Upgrading

Untar a new copy beside this one and keep its `var/` — or replace `bin/`,
`ghidra/`, `skills/` and `scripts/` in place and leave `var/` alone. The store
and the kept projects carry the reviews; a newer server reads them as they are.

The full guide — requirements, building from the repository, configuration,
troubleshooting — is `INSTALL.md` beside this file.
