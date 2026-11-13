# The local CAS

A directory that holds code artifacts by their content, plus a manifest for
each analysis that produced one. It is not a database: the directory is the
index, and a reader walks it.

## One implementation

The store is written once, in Swift: `ContentStore` in
`Packages/CodeAnalysis`. The app links it; the skill runs it as the
`byteripper-cas` command line, and `scripts/cas.py` is only that tool's
client. A rule — which artifact may replace which — therefore cannot differ
between the app and the skill.

`cas.py` finds the tool as `$BYTERIPPER_CAS`, or builds it from this
repository with `swift build -c release` into
`~/Library/Caches/ByteRipper/byteripper-cas` — once, about 20 seconds, and
again whenever a source of the package is newer than the build. A machine that
builds it therefore needs Xcode or its command line tools; one that sets
`BYTERIPPER_CAS` needs neither.

```
byteripper-cas [--store <root>] [--no-create] <command>
  hello | put-object | has-object | get-object | put-analysis | analysis
  recipes | list | conflicts | record-revision | review-history | set-ref
  refs | remove-ref | verify | gc | export | import
```

Every answer is JSON on standard output (an object's bytes are the
exception); a refusal is `{"error": "…"}` on standard error, status 1 for what
the store refused and 2 for a command or argument it does not know. A field the
store does not know in `--module`, `--recipe`, `--source` or `--reading` is
refused, never dropped.

## Layout

```
~/Library/Application Support/ByteRipper/Analysis/
  objects/<sha256 of the artifact>            # immutable bytes
  analyses/<sha256 of the module>/<recipe>/
      manifest.json
  refs/<name>.json                            # named sets a project keeps
  conflicts/<module-sha>/<recipe>/<artifact-sha>.json
                                              # another project's reading, kept aside
  reviews/<module-sha>/manifest.json          # every revision of the module's readings
  library/index.json                          # the library registry: entries, and every body's entry
  library/history/<id>.json                   # every version of one registry entry
  private/projects/<module-sha>/project.zip   # the module's Ghidra project, at its current revision
  private/projects/<module-sha>/record.json   # which revision it is, and what made it
  private/journal/<id>.json                   # a publish that has not finished
  private/publish.lock                        # flock one publish holds from its decision to its end
  private/types/<bits>/index.json             # the shared review types' versions, Ia32 or X64, current last
  private/types/<bits>/<version>/archive.gdt  # one version: the Ghidra archive,
  private/types/<bits>/<version>/origin.json  #   the module that wrote each type,
  private/types/<bits>/<version>/withdrawn.json  # and the names taken out, with who and why
  tmp/                                        # staging; cleaned by gc
  .lock                                       # flock for writers
```

`private/` is the server's own: no route serves it, a mirror copies nothing
of it, and `gc` walks `objects/` only — keeping the objects an unfinished
journal names.

The default root is `~/Library/Application Support/ByteRipper/Analysis`;
`--store` puts it elsewhere. The directory is `0700`, objects and manifests
`0600`.

### Objects

An object is the artifact's bytes, named by their SHA-256. `put_object`
writes a temporary file, fsyncs it, and renames it into place; a second put of
the same bytes is a no-op. `get_object` hashes what it read and refuses a
corrupt or missing object. Two analyses with the same artifact share one
object.

### Parted objects

An object keeps its name, the SHA-256 of its whole bytes, and `get_object`
returns exactly those bytes; a reader of the store through `ContentStore` sees no
difference. A file that is not in this form is reported as corrupt: a store of
plain files from a build before it no longer reads. A file `parted-objects` left
in a store by an earlier build means nothing now.

Every file is gzip. An artifact is cut along its JSON: each function, and each
top-level section of 1 KiB or more, is an object of its own, named by its own
bytes. The file under the artifact's name holds `{"byteripper_parted":1,
"parts":[…]}`, gzipped: in order, the text between the parts, as strings, and
`{"sha256": …}` for each part. Put end to end they are the original bytes, and a
read checks the whole against its name. Two revisions that differ in a few
functions share the others. `verify` names a part that is missing, and `gc`
keeps the parts of what it keeps.

The root also holds `functions`: each function without its code, with `part`,
the object that holds it, and `fingerprint`, what the reader compares it by. It
is `null` when a function would not read as one. A server answers
`GET /cas/v1/objects/<sha>/root` with the root (its gzip file under
`Content-Encoding: gzip` when the request's `Accept-Encoding` takes gzip, inflated
otherwise), 404 when the object is
not cut or not there, and `POST /cas/v1/objects/parts` with up to 1024 objects:
`{"sha256": […]}` in, and for each name in order the name in hex, its length in
eight big-endian bytes and that many bytes of gzip file, length 0 for an object
it lacks.

A mirror keeps this form too, holding the root and only what something read: a
read of one function (`ContentStore.artifact(_:function:)`) fetches that function
and the sections, and a read of the whole fetches the rest. The Code panel opens
on `ContentStore.skeleton(of:)`, the root's index as an artifact whose functions
carry `fingerprint` and no code (`codeIsPending`), and reads a function with
`functions(_:of:)` when it is shown; search, callers and a name's uses read the
remaining ones. An agent's tools read the whole. A bundle is written
from what the store has and fetches nothing: an artifact short of parts goes as
`roots/<sha>` and the parts it has. `importBundle` takes that when bundle and
store make the whole; only `acceptingPartial`, as a project opened without a
server, keeps less.

### Analyses

`analyses/<module-sha>/<recipe>/manifest.json` says which module bytes and
which analysis recipe produced which object:

```json
{
  "schema": 1,
  "module": {"sha256": "...", "size": 2016, "name": "CpuPei",
             "kind": "TE", "language": "x86:LE:32:default", "image_base": "0x0"},
  "recipe": {"id": "code-v4-ghidra-12.1.2", "exporter": 4,
             "ghidra": "12.1.2", "script": "ExportCode.java",
             "types": "edk2-stable202608", "passes": ["ApplyUefi.java"]},
  "artifact": {"sha256": "...", "size": 93246, "media_type": "application/json"},
  "source": {"path": "...", "document": "CSME 15.bin", "node": "0.5.5.2.0.1.0.8.1"},
  "analyzed_at": "2026-10-25T15:19:41+00:00",
  "stats": {"functions": 13, "instructions": 508, "strings": 0,
            "post_code_writes": 0, "status_code_candidates": 1},
  "reading": {"project": "6f0c…", "rev": 3, "review": "…", "description": "…"}
}
```

`module.phase`, `recipe.types`, `recipe.passes` and `reading` are optional:
`types` and `passes` say the UEFI pass ran and with which EDK2 headers, and
`reading` is present only on an artifact published from a reviewed Ghidra
project (`Design/GHIDRA_SHARED_PLAN.md` §5.6). Inside it, `description` names
the module description — the review's Markdown, an object of its own
(`reference/description.md`) — and is absent while the review has written none.

- The module key is the **whole module's bytes**, not its GUID: the same GUID
  can be a different build.
- The recipe is the exporter version and the Ghidra version. A new Ghidra may
  find other functions, so it gets a second recipe rather than overwriting the
  first. The server reuses an analysis only from the current exporter.
- The same artifact under the same key is the same analysis: a put merges the
  source it names, and takes a newer reading (over none, or a later revision of
  the same project) — a comment changes the review document, and a description
  is an object of its own; neither changes the artifact.
- Another artifact under the same key is decided by the two readings:

  | stored | incoming | put | import |
  |---|---|---|---|
  | none (mechanical) | none | refused unless `replace` (`--force`) | skipped |
  | none | a reading | replaces | replaces |
  | a reading | none | refused unless `discard_reading` (`--force --discard-reading`) | skipped |
  | project P, rev n | P, rev m > n | replaces | replaces |
  | P, rev n | P, rev m ≤ n | refused | skipped |
  | P | another project Q | refused unless `discard_reading` | kept aside in `conflicts/` |
- The manifest is written atomically under a `flock`; readers see either the
  old or the new file, never a partial one.

### The review history

`reviews/<module-sha>/manifest.json` lists every revision a publish recorded,
oldest first: revision, review document, description (when there is one), the
artifact — the code as it stood — when and by whom. A module has one history:
the store numbers its revisions, one more than the last, and records none when
the code, the document and the description are the last revision's. A `project`
in an older file is read and means nothing. It is an index for diffs and
pruning; the analysis manifest's `reading` alone says which reading is current.
A revision recorded before revisions kept their code names none, and `gc` keeps
only what a revision names: such a revision cannot be compared with, and the
panel's picker leaves it out.

A publish is one transaction. What the owner exports, the registry's decision
and the shared types' decision come first, and nothing is written while either
can still say no. Then the journal (`private/journal/`) goes down with
everything the publish will write, and the steps follow, each marked there when
it is done and each safe to do again: the registry's entries, their code, the
revision, the sources' revision number, the entries' equates, the analysis, the
shared types' next version — the store's steps — then the marks in the project,
the bytes the registry learns from it, `state.json` and the kept project — the
owner's. A server that stopped part way finishes the store's steps before
it opens a route, and the owner's the next time the module is opened; the last
step removes the journal. One publish at a time holds a store, from its
decision to its end. A registry source names the revision the store recorded;
`verify` reports one that names a revision the module's history does not
hold.

The shared review types — one archive per pointer size — are kept by the server
in versions, by the registry's rule. While a publish holds the store, its owner
merges the review's types into a copy of the current version: a type new to
the archive is added; the same type is nothing; an addition — an enum member, a
real name where the shared copy had a placeholder (`Unknown…`, `field_0x…`,
`param_N`, a member type Ghidra made up as `_func_N` or a `.conflict` copy), a
placeholder over untyped bytes (`UINT8 Unknown04[24]`, `undefined4`) cut into
fields that stay inside its bytes, with every named field at its place and size
and the structure's size unchanged — makes the next version. Comments and descriptions are the last publish's: a
module whose text for a type, a field or an enum member differs from the
archive's writes its own, and that too is the next version. A type the
archive holds differently in any other way refuses the publish, and nothing is
written. A replacement is a proposal and nothing else: the module's holder proposes it, two
other agents agree with no objection open — or an administrator agrees it on the
console's Review Tickets page — and the module's next publish
replaces the types the proposal names — while the module and the shared copy
still hold the texts the voters read. The proposals are kept in
`private/type-proposals.json` beside the review board's `private/tickets.json`;
each records the module, both texts of every type, the votes, and the
revision and version that applied it. The same proposal carries the library
registry entries the publish would replace — each changed field as the entry
holds it and as the module offers it — and an agreed one makes each entry's
next version, the proposal's reason, id and voters in the entry's history. A name withdrawn from the archive does not refuse: it stays
in the module's program and is reported. A withdrawal is a version of its own.
A typedef named like the function it renames — what the C parser makes of
`typedef UINT32 NAME(…)` — is that function, so a module that holds the
typedef and an archive that holds the function agree; a `.conflict` copy the
archive kept of such a typedef, or of a type that became its twin, is folded
into the twin in the same merge, so republishing an unchanged module makes no
version.
A version names the module, the revision, who made it and what it added,
amended, replaced or took out, and is never rewritten. The first version of an
archive is the one an earlier server kept beside its projects
(`GhidraProjects/review-types-*.gdt`); those files stay a copy of the current
version, which owners read when they start, and the server puts them right when
it starts. `verify` checks each version's files against its index.

### The library registry

`library/` is the shared registry of library functions
(`Design/LIBRARY_REGISTRY_PLAN.md`): one entry per function body — its
Function ID code units, full hash and specific hash, written
`<size>-<full>-<specific>` in hex — holding the review one module published and, per body, the body's code.
`index.json` declares the libraries and what each depends on (`libraries`:
`edk2` on nothing, `amd` and `intel` on `edk2`), and maps every entry's id to its current version (an object, as a
review document is), name, kind (`edk2`, `amd`, `intel`), source (module,
address, revision, who) and bodies, and every body to its entry.
`history/<id>.json` keeps every version and who published it, with the reason
when an agent took a review not made on the current version.

A publish offers the registry the review's candidates
(`ghidra_library_candidate`), and every other function it marks as library,
whose review meets the bar of a finished function; if the registry does not take
them all, nothing is stored. A body the registry lacks
is a new entry; the same review is no change; a review made on the entry's
current version (`based_on` and `base`, from the function's mark) is the next
version, from any module; any other review is a conflict, and the entry stays
unless the publish takes it with a reason. No module holds an entry. A served store takes the
offer at `POST /cas/v1/library` and serves `GET /cas/v1/library` and
`GET /cas/v1/library/history/<id>`; its change feed says `library: true` when
the index changed, and a mirror copies the index (not the histories). `gc`
keeps every object the index and the histories name, a body's code among them. A
body's code is an object of its own (`reference/code-artifact.md`), and a mirror
fetches it when a reader needs it, as it does any object.

### References and collection

A reference is a named set of analyses a project wants to keep:

```
cas_cli.py ref add laptop <module-sha>/<recipe>
```

`gc` removes objects no manifest names; with `--analyses` it also removes
analyses no reference names. It is a dry run unless `--apply`. With no
references at all, `--analyses --apply` refuses unless `--force`, so a store
cannot be emptied by accident. `verify` checks every object's hash, every
manifest's artifact and module, and every reference's analysis.

### Moving analyses

`export --all --out analyses.zip` (or several `--key`) writes a bundle: a
`bundle.json`, the manifests, and the objects. `import analyses.zip` takes the
bundle analysis by analysis: it verifies and stores each object, then writes,
skips or keeps the manifest aside by the table above, and reports
`{imported, unchanged, skipped, conflicts}`. One entry the store cannot take
does not stop the others; only an unreadable `bundle.json` fails the import.
A bundle carries the review document and the description each reading names,
and the import stores them beside the artifact; a bundle written before
documents travelled still imports. `gc` keeps every object a kept manifest
names — its artifact and its reading's review document and description — the
objects of readings kept aside, and every document and description a review
history names; `verify` reports a review document or a description a reading
or a history names but the store does not hold, and a history entry
ahead of its analysis. A project can carry a bundle with
it, or the store can be shared by putting the same directory on a synced
folder. Entries are written stored, not deflated, so the Swift store in
`Packages/CodeAnalysis` reads them without linking a decompressor.

## Commands

```bash
python3 scripts/cas_cli.py list
python3 scripts/cas_cli.py show <module-sha>
python3 scripts/cas_cli.py ref add laptop <module-sha>/<recipe>
python3 scripts/cas_cli.py ref list
python3 scripts/cas_cli.py verify
python3 scripts/cas_cli.py gc --apply
python3 scripts/cas_cli.py gc --analyses --apply
python3 scripts/cas_cli.py export --all --out analyses.zip
python3 scripts/cas_cli.py import analyses.zip
python3 scripts/cas_cli.py conflicts
python3 scripts/cas_cli.py history <module-sha>
```

The server writes through this store — a publish is a write — and its
`code_query` tool reads it. `cas_cli.py` takes the same `--store` and is how a
person reads, verifies or moves what the store holds.

`byteripper-cas drop-earlier-projects [--apply]` removes what a module's earlier Ghidra projects
left from before a module had one history — their analyses, revisions and readings kept aside —
and refuses while a registry entry's source is one of them. `byteripper-cas library-source-rev
--module <sha> --from <rev> --to <rev> [--apply]` puts registry sources naming a revision that
never came on one the module has. `byteripper-server pack-projects [--apply]` keeps each project
folder whose last publish is the store's last revision in `private/projects/`; the folders are
read, never changed. Each answers what it would do until `--apply` is given.

No command changes what the registry holds. A replacement of what an entry says, its name
included, is a proposal, applied by the module's next publish once it is agreed; taking an
entry out, restoring a body and splitting one off are proposals too, applied by the server
the moment they are agreed. A citation only adds, and is made directly.

## A served store

`byteripper-server` (`Packages/ByteRipperServer`, `Design/SERVER_PLAN.md`)
serves one store to a personal network: every Mac's app mirrors it, and every
script can write to it. The server runs this same `ContentStore` on its own
directory and is that directory's only writer over the network, so the rules
above hold unchanged.

```bash
# on the server
byteripper-server token add --name admin --rights admin   # the console's, once
byteripper-server token add --name <mac> --preset app     # one per Mac, and per client
byteripper-server --listen 100.64.0.7:8765                # a tailnet address; loopback by default
# each secret is shown once. Paste a Mac's into the app's Settings ▸ Code
# Analysis there: the app writes …/ByteRipper/Server/token, the file its
# scripts read.

# on any machine
python3 scripts/cas_cli.py --store http://100.64.0.7:8765 list
```

- `--store http://host:port` works for every script; `byteripper-cas` takes it
  as `--server <url>`. The client's token is `--token-file`, or the file
  `BYTERIPPER_SERVER_TOKEN_FILE` names, or `…/ByteRipper/Server/token`.
- The server's own tokens live in `tokens.json` (0600, hashes only), and each
  carries rights: `cas.read` on every one, `cas.write` for the references
  and for publishing through the server's Ghidra, `admin` for writing the
  store past a publish — an object, an analysis, a revision, the registry, a
  bundle. The `app` preset has the first two and `ghidra.use`; a `reader` may
  read and nothing else. A 403 names the right the token lacks.
- Every address the server listens on requires a token, loopback included,
  and without an admin token in `tokens.json` it refuses to start. There is
  no token file on the server any more, and there is no `/mcp`: an agent on
  the server connects to `<Server>/mcp.sock` through `byteripper-server relay`
  (`Design/SERVER_HEADLESS_PLAN.md` §7).
- `gc` is refused over the network: run it on the server, against its own
  directory. A write made there directly — `byteripper-cas` — is seen by the
  server's FSEvents stream and announced like any other.
- The protocol is `/cas/v1` (`ServedStoreProtocol`). A client is told of a
  change by a long poll, `GET /cas/v1/changes?since=<seq>&epoch=<epoch>&wait=<s>`:
  it answers as soon as a module's manifests or history change, with the
  modules that did, or `resync` when the client must read everything again.
- `GET /cas/v1/heartbeat` is a stream the server pushes for as long as the client
  stays: `text/event-stream`, one `data: {"beat":<n>}` every 5 seconds. A client
  that stops hearing it knows the connection is gone without waiting for a
  request to time out. An older server answers 404.

## The project's part

The store holds derived facts; a project holds decisions — which analyses it
uses, and the name/comment/type overlays. The project is expected to reference
analysis keys (`<module-sha>/<recipe>`) and to embed or export a bundle when it
must be self-contained. That integration belongs to the app, not to this
script; a missing store is not an error, only a prompt to analyze again.

## Limits

- No index beyond the directory walk; fine for thousands of analyses, not for
  millions. A `index.json` or SQLite can be added behind the same API.
- Objects are stored raw; gzip is a later concern.
- The lock is local to one machine. A network store is a served store (above),
  never a shared filesystem: `flock` over SMB or NFS is not to be trusted.
- The old flat store from the first slice (`<module-sha>/manifest.json`) is not
  read; analyze the module again to put it into the CAS.

## Tests

```bash
python3 -m unittest discover -s tests
```

(The paths here are the skill's own: run them from its directory.)

The suite runs the skill's client against the real tool and covers duplicate
and corrupt objects, recipe separation, replacement by reading, unknown fields,
path traversal, references and GC, and export/import with a conflict. The
store's own tests are `swift test` in `Packages/CodeAnalysis`.
