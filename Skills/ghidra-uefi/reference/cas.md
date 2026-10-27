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
runs the skill therefore needs Xcode or its command line tools.

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
  tmp/                                        # staging; cleaned by gc
  .lock                                       # flock for writers
```

The default root is `~/Library/Application Support/ByteRipper/Analysis`;
`--store` puts it elsewhere. The directory is `0700`, objects and manifests
`0600`.

### Objects

An object is the artifact's bytes, named by their SHA-256. `put_object`
writes a temporary file, fsyncs it, and renames it into place; a second put of
the same bytes is a no-op. `get_object` hashes what it read and refuses a
corrupt or missing object. Two analyses with the same artifact share one
object.

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
  first. `code_artifact.py` reuses an analysis only from the current exporter.
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
oldest first: project, revision, review document, description (when there is
one), when and by whom. It is an
index for diffs and pruning; the analysis manifest's `reading` alone says which
reading is current. A publish stores, in this order, the document and the
description (`put-object`), the revision (`record-revision`, which refuses an
object the store does not hold), and the analysis naming it (`put-analysis`). A publish
that stops after the revision leaves an entry ahead of its analysis, which
`verify` reports and the next publish of the same revision overwrites.

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
python3 Skills/ghidra-uefi/scripts/cas_cli.py list
python3 Skills/ghidra-uefi/scripts/cas_cli.py show <module-sha>
python3 Skills/ghidra-uefi/scripts/cas_cli.py ref add laptop <module-sha>/<recipe>
python3 Skills/ghidra-uefi/scripts/cas_cli.py ref list
python3 Skills/ghidra-uefi/scripts/cas_cli.py verify
python3 Skills/ghidra-uefi/scripts/cas_cli.py gc --apply
python3 Skills/ghidra-uefi/scripts/cas_cli.py gc --analyses --apply
python3 Skills/ghidra-uefi/scripts/cas_cli.py export --all --out analyses.zip
python3 Skills/ghidra-uefi/scripts/cas_cli.py import analyses.zip
python3 Skills/ghidra-uefi/scripts/cas_cli.py conflicts
python3 Skills/ghidra-uefi/scripts/cas_cli.py history <module-sha>
```

`code_artifact.py` writes through this store and `code_query.py` reads through
it, both with the same `--store`.

## A served store

`byteripper-server` (`Packages/ByteRipperServer`, `Design/SERVER_PLAN.md`)
serves one store to a personal network: every Mac's app mirrors it, and every
script can write to it. The server runs this same `ContentStore` on its own
directory and is that directory's only writer over the network, so the rules
above hold unchanged.

```bash
# on the server
byteripper-server token                      # once: …/ByteRipper/Server/token, 0600
byteripper-server --listen 100.64.0.7:8765   # a tailnet address; loopback by default

# on any machine that has the token in …/ByteRipper/Server/token
python3 Skills/ghidra-uefi/scripts/cas_cli.py --store http://100.64.0.7:8765 list
python3 Skills/ghidra-uefi/scripts/code_artifact.py module.efi --store http://100.64.0.7:8765
```

- `--store http://host:port` works for every script; `byteripper-cas` takes it
  as `--server <url>`. The token is `--token-file`, or the file
  `BYTERIPPER_SERVER_TOKEN_FILE` names, or `…/ByteRipper/Server/token`.
- Off loopback the server refuses to start without a token file, and refuses
  a token file group or others may read.
- `gc` is refused over the network: run it on the server, against its own
  directory. A write made there directly — `byteripper-cas`, `code_artifact.py`
  — is seen by the server's FSEvents stream and announced like any other.
- The protocol is `/cas/v1` (`ServedStoreProtocol`). A client is told of a
  change by a long poll, `GET /cas/v1/changes?since=<seq>&epoch=<epoch>&wait=<s>`:
  it answers as soon as a module's manifests or history change, with the
  modules that did, or `resync` when the client must read everything again.

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
  read; re-run `code_artifact.py` to put the same module into the CAS.

## Tests

```bash
python3 -m unittest discover -s Skills/ghidra-uefi/tests
```

The suite runs the skill's client against the real tool and covers duplicate
and corrupt objects, recipe separation, replacement by reading, unknown fields,
path traversal, references and GC, and export/import with a conflict. The
store's own tests are `swift test` in `Packages/CodeAnalysis`.
