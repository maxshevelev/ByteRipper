# Installing the analysis server

`byteripper-server` is a headless ByteRipper: it holds dumps and reads their
structure, hosts the kept Ghidra projects of the modules reviewed in them,
keeps the analyses in a code store, and speaks MCP to an agent — the same
`uefi_`, `code_` and `ghidra_` tools the app gives one, and the review skill
that knows what to do with them.

It is installed as one folder that carries everything it needs except Ghidra
and a JDK. Nothing in that folder points at this repository or at the app's
own data.

## What you need

- macOS 14 or later, on the Mac that runs the analyses;
- **Ghidra**, unzipped anywhere. 12.1.2 is what the analyses here were made
  with; the version is part of an analysis's key, so another version reads the
  old analyses and writes new ones beside them;
- **a JDK 21 or newer** — the one `/usr/libexec/java_home -v 21+` answers, or
  `JAVA_HOME`. It runs Ghidra and compiles the owner;
- **network access once**: on the first module opened, EDK2's headers (about
  10 MB) and the GUID catalogue are fetched into
  `~/Library/Application Support/ByteRipper/Ghidra`, and the type archives are
  built there in about a minute. A machine that cannot reach GitHub copies that
  folder from one that can;
- to build the folder: Xcode or its command line tools (`swift`).

## Build it

From a checkout of this repository:

```bash
Scripts/make-agent-dist.sh
```

It builds `byteripper-server` and `byteripper-cas` in release, stages the
folder as `dist/byteripper-analysis-<version>/`, and writes a tarball beside
it. The binaries are built for the architecture of the Mac that builds them —
build on an Apple-silicon Mac for Apple-silicon Macs.

## Install it

```bash
mkdir -p ~/ByteRipperAnalysis
tar -xzf byteripper-analysis-<version>.tar.gz -C ~/ByteRipperAnalysis
cd ~/ByteRipperAnalysis/byteripper-analysis-<version>
./scripts/doctor.sh
```

`doctor.sh` changes nothing: it says whether the folder is complete, whether
Ghidra and a JDK are found, whether the server is up, and where it reads its
Ghidra scripts from. Everything else in the guide assumes you are in this
folder.

```
bin/            byteripper-server, byteripper-cas
ghidra/         the Ghidra scripts the server compiles and runs
skills/         the review skill the agent reads
scripts/        start-server, stop-server, agent, doctor
var/            everything this copy keeps (empty until it runs)
README.md       the short card of this folder
INSTALL.md      this file
VERSION         what was built, from which commit
```

## First start

```bash
./scripts/start-server.sh
```

It makes the install's admin token on the first run, starts the server in the
background and waits for its socket. The first free port from 8765 is taken
(the app's own server usually has 8765) and written to `var/port`; the console
answers at `http://127.0.0.1:<port>/admin`, and its token is in
`var/support/admin-token.txt`.

Put a dump in `var/dumps` — the one folder the console may open dumps from —
and open it in the console. The agent's tools see what the console has open.

```bash
./scripts/doctor.sh     # now says the server is up and reads var/.../ghidra/scripts
./scripts/stop-server.sh
```

`stop-server.sh` stops the server. The owners it started — one Ghidra process
per module being reviewed — are processes of their own: each saves and exits
after `--idle` seconds without a call (30 minutes by default), and a restarted
server reuses one that is still running. Neither script removes anything from
`var/`.

## An agent session

```bash
./scripts/agent.sh
```

starts the server if it is not up, writes `.mcp.json` with this folder's
absolute paths, and opens a Claude Code session in the folder. The session
finds:

- the MCP server `byteripper` — the tools listed at the top of the session.
  Claude asks once whether to use a project's MCP server; say yes;
- the skill `skills/ghidra-uefi/SKILL.md`, which `/ghidra-uefi` loads. It is
  the review discipline: how a module is found, opened and reviewed;
- `CLAUDE.md`, which tells the agent what this folder is and that `var/` is
  its data.

Any other MCP client is configured the same way, with the same command:

```bash
<span>/bin/byteripper-server relay --mcp-socket <span>/var/support/mcp.sock
```

## Where everything is

Everything the copy keeps is inside `var/`, and backing the copy up means
backing up `var/`:

```
var/store/      the code store: artifacts, analyses, reviews, descriptions
var/projects/   the kept Ghidra project of each module
var/support/    tokens.json, sessions.json, documents.json, Uploads/, mcp.sock
var/dumps/      the dumps the console may open
var/log/        server.log
var/port        the console's port, as last started
```

Three caches live outside it, shared by every copy on the Mac: the EDK2 type
archives (`~/Library/Application Support/ByteRipper/Ghidra`), the compiled
owner (`~/Library/Caches/ByteRipper/ghidra-owner`), and nothing else. They can
be deleted at any time; the next run rebuilds them.

## Configuration

The server reads `~/.byteripper-server.json` when there is one, before any flag
on the line — a flag still wins, so no file can stand in the way of a command
you type. Each key is a flag without its `--`:

```json
{
  "support": "~/ByteRipperAnalysis/byteripper-analysis-<version>/var/support",
  "store": "~/ByteRipperAnalysis/byteripper-analysis-<version>/var/store",
  "projects": "~/ByteRipperAnalysis/byteripper-analysis-<version>/var/projects",
  "dumpRoots": ["/Volumes/HDD 10Tb/Dump Samples"],
  "ghidraHome": "~/Projects/ghidra/ghidra_12.1.2_PUBLIC",
  "listen": ["127.0.0.1:8765"],
  "idle": 1800,
  "maxOpenBytes": "1 GiB"
}
```

| key | what it is |
|---|---|
| `support` | the server's own folder: tokens, sessions, socket, documents, uploads, the client token |
| `store` | the code store's directory |
| `projects` | the kept Ghidra projects' folder |
| `dumpRoots` | folders the console may open dumps from |
| `ghidraHome` | the Ghidra install; `GHIDRA_HOME`, else the newest `ghidra_*` in `~/Projects/ghidra`, `~/ghidra`, `/Applications`, `/opt` |
| `ghidraScripts` | the folder of the Ghidra scripts, if not the `ghidra/` beside the binary |
| `tokens`, `mcpSocket` | files, when they are not inside `support` |
| `listen` | `host:port` addresses to serve the console on |
| `serverNames` | names the console answers under besides the addresses |
| `idle` | seconds an owner waits before it saves and exits |
| `maxDocuments`, `maxOpenBytes`, `maxUploadBytes` | limits: a count, and byte counts as numbers or `"512 MiB"` |

`byteripper-server --config <file>` reads another file, `--no-config` reads
none. A key the server does not know is refused with its name rather than
dropped, and `--help` lists every flag.

## One server, several Macs

The server serves the store and the console on `--listen` addresses, each
behind a token; the app on another Mac reaches it from **Settings ▸ Code
Analysis**. Make a token per Mac:

```bash
bin/byteripper-server token add --name bench-imac --preset app --tokens var/support/tokens.json
```

The secret is shown once; every address needs one, loopback included. There is
no MCP over the network: an agent connects through the local socket, so an
agent that is not on this Mac uses the app's own connection or a copy of the
folder there, reading the store from the server.

## Updating

Untar a new copy and keep its `var/`, or replace `bin/`, `ghidra/`, `skills/`
and `scripts/` in place and leave `var/` alone. The store and the projects
carry the reviews; a newer server reads what an older one wrote. The one thing
not to do is run two servers on the same `var/`.

## When something is wrong

- **`no Ghidra found`** — name it: `--ghidra-home /path/ghidra_12.1.2_PUBLIC`,
  or set `GHIDRA_HOME`. The folder must hold `support/analyzeHeadless`.
- **`no JDK 21 or newer`** — install one, or set `JAVA_HOME` to it.
- **`the owner's source is missing`** — the copy's `ghidra/owner/` is not
  where the server looked; the line above it in `var/log/server.log` says
  which folder it read. `doctor.sh` compares that with the copy's own.
- **`Address already in use`** — another server has the port. The launchers
  pick a free one from 8765; a hand-started server needs
  `--listen 127.0.0.1:<port>` or `BYTERIPPER_PORT`.
- **The agent's tools connect but see no dump** — dumps must be under a
  `--dump-roots` folder (`var/dumps` in the launchers' setup) and opened in
  the console; `documents` lists what is open.
- **The first module opened stalls** — it is fetching EDK2 and building the
  type archives; `var/log/server.log` and the console's activity say so. On a
  machine with no network, copy
  `~/Library/Application Support/ByteRipper/Ghidra` from one that has it.
- **A token is refused** — the secret goes into the client once, and is shown
  once; `token list` says what a file holds, `token rotate` replaces a secret
  without revoking the name.

## Removing it

`scripts/stop-server.sh`, then delete the folder. An owner still running saves
and exits by itself after its idle period. `var/` holds the analyses and the
reviews — remove it only when they are not wanted, or move it into another copy
first.
