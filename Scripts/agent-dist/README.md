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

or, by hand:

```bash
./scripts/start-server.sh   # idempotent; makes the console token on first start
./scripts/doctor.sh         # what is there, what is missing
./scripts/stop-server.sh
```

The console is at `http://127.0.0.1:<port>/admin` — the first free port from
8765, written to `var/port`, or `BYTERIPPER_PORT`; the token is in
`var/support/admin-token.txt`. Open a dump from it — the dumps it may open are
under `var/dumps` — and the agent's tools see it.

## What is where

```
bin/            byteripper-server, byteripper-cas
ghidra/         the Ghidra scripts the server compiles and runs
skills/         the review skill the agent reads (SKILL.md, reference/)
scripts/        start-server, stop-server, agent, doctor
var/            everything this install keeps: store, projects, support, dumps, log
CLAUDE.md       what the agent is told about this folder
VERSION         what was built, from which commit
```

## Upgrading

Untar a new copy beside this one and keep its `var/` — or replace `bin/`,
`ghidra/`, `skills/` and `scripts/` in place and leave `var/` alone. The store
and the kept projects carry the reviews; a newer server reads them as they are.
