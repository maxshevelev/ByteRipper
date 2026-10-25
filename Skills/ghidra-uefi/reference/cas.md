# The local CAS

A directory that holds code artifacts by their content, plus a manifest for
each analysis that produced one. It is not a database: the directory is the
index, `analyses()` walks it, and a future Swift reader can read the same
files without this module.

## Layout

```
~/Library/Application Support/ByteRipper/Analysis/
  objects/<sha256 of the artifact>            # immutable bytes
  analyses/<sha256 of the module>/<recipe>/
      manifest.json
  refs/<name>.json                            # named sets a project keeps
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
  "recipe": {"id": "code-v2-ghidra-12.1.2", "exporter": 2,
             "ghidra": "12.1.2", "script": "ExportCode.java"},
  "artifact": {"sha256": "...", "size": 93246, "media_type": "application/json"},
  "source": {"path": "...", "document": "CSME 15.bin", "node": "0.5.5.2.0.1.0.8.1"},
  "analyzed_at": "2026-10-25T15:19:41+00:00",
  "stats": {"functions": 13, "instructions": 508, "strings": 0,
            "post_code_writes": 0, "status_code_candidates": 1}
}
```

- The module key is the **whole module's bytes**, not its GUID: the same GUID
  can be a different build.
- The recipe is the exporter version and the Ghidra version. A new Ghidra may
  find other functions, so it gets a second recipe rather than overwriting the
  first. `code_artifact.py` reuses an analysis only from the current exporter.
- Putting the same recipe with another artifact is refused unless
  `replace=True` (`--force`), because two runs of one recipe should agree.
- The manifest is written atomically under a `flock`; readers see either the
  old or the new file, never a partial one.

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
`bundle.json`, the manifests, and the objects. `import analyses.zip` verifies
each object's hash, stores it, and writes the manifest if the same analysis is
not already present with another artifact. A project can carry a bundle with
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
```

`code_artifact.py` writes through this store and `code_query.py` reads through
it, both with the same `--store`.

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
- The lock is local to one machine; a network store needs an object service
  with atomic writes, not a shared filesystem.
- The old flat store from the first slice (`<module-sha>/manifest.json`) is not
  read; re-run `code_artifact.py` to put the same module into the CAS.

## Tests

```bash
python3 -m unittest discover -s Skills/ghidra-uefi/tests
```

The suite covers duplicate and corrupt objects, recipe separation, replacement,
path traversal, references and GC, and export/import.
