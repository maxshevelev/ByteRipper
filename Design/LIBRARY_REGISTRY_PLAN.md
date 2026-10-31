# A shared registry of library functions — reviewed once, applied everywhere

A library function — EDK2's, AGESA's, Intel's (`Skills/ghidra-uefi/SKILL.md`,
"Library functions") — is the same code in every module that links it:
`InternalX86Delay` is in 35 modules of one Cezanne image, `LibAmdIoWrite` in
13. Today each module's review finds, names, types and plates it again. The
registry keeps a library function's review once, keyed by its body, and gives
it to every module whose function has the same body.

This document is the design. It extends `GHIDRA_SHARED_PLAN.md` (the owner, the
store, publish) the way §6.5 there extends it for types, and keeps its rules:
the owner writes nothing to the store, the host stores through `AnalysisWriter`
(a local `ContentStore` or a served one), and a stored thing is rebuildable from
review documents.

## 1. Decision in one page

- **What goes in**: every function a review tagged `library.edk2`,
  `library.amd` or `library.intel`, at every publish of its module. Nothing
  else: a module's own work is not shared, and a function tagged without a kind
  is not either.
- **The key is the body, as Ghidra's Function ID hashes it**: the full hash and
  the specific hash of `FidService.hashFunction`, with the code-unit count. The
  full hash masks every operand that is an address, so the same routine at
  another base, calling relocated callees, hashes the same; the specific hash
  keeps the constants, so `LibAmdMemRead` fixed to a byte and fixed to a dword
  differ. Ghidra's own minimum applies: a body shorter than its short-hash
  length (a `ret` stub, a three-byte `mov al,1; ret`) is not keyed.
- **An entry is the review of that body**: name, kind, signature, the
  parameters' and locals' names and types by storage, the plate, and step
  comments by offset from the entry; the evidence line the skill requires; and
  where it came from — module SHA-256, entry address, revision, reviewer. Types
  it names travel by name: the review type archive (§6.5 of the shared plan)
  already holds them.
- **One body is one function, whatever the reviews called it.** An exact match
  — full hash, specific hash and size — is the same function in every module,
  so the registry holds one entry for it and every module converges on that
  entry's name. Two reviews that named the same body differently do not make
  two entries; they make one entry and a rename.
- **Applying an exact match** when the module is opened:
  - a function no review has named (`name_source` is not `USER_DEFINED`) takes
    the whole entry: name, signature, variables, plate, comments and the
    library tag, with a plate line saying where it came from, and carries the
    entry's key and version (`ByteRipper.libraryEntry`) — a later version of
    the entry re-applies itself at the next open unless the function was
    edited since;
  - a function a review has named takes the entry's name — renamed if its own
    differs, the old name kept in the name's reason ("was `FindGuidHob`") — and
    the entry fills only what the review left empty: a signature or variables
    still `param_N`/`undefined`, a missing plate, a step comment at an offset
    that has none, a missing tag. What the review made stays; where it differs
    from the entry (another signature, a plate that says otherwise, another
    library kind) the open's answer lists the difference, and the agent either
    keeps the module's version or improves the entry with it. Such a function
    is part review, part registry: it carries no `libraryEntry` mark, and a
    later version of the entry is offered to it as a candidate, not applied.
- **A match on the full hash only** (the same shape with other constants — an
  AGESA routine built with another assert code) is a candidate: `ghidra_library`
  shows it, and the agent applies or declines it.
- **One entry per key, improved in place.** A publish whose tagged function has
  the key of an existing entry does not add an entry: when its review equals the
  entry, nothing changes; when it differs, it is a proposed change to the one
  entry, reported in the publish answer with the module that wrote the entry,
  and `take_library_conflicts: true` makes it the entry's next version — which
  then reaches every module that applied the entry. The module that wrote the
  entry changes it by publishing, without a conflict.
- **Readers see where a function came from**: the artifact records a function
  applied from the registry (`library_entry`: key, version, source module), the
  panel shows it beside the badge and opens the source module's function, and
  `code_query` answers it.

## 2. Storage

```
library/index.json                 { key → { version, entry: <sha256>, kind, name, source } }
library/history/<key>.json         every version of one key: { version, entry, source, recorded_at, by }
objects/<sha256>                   the entries, as review documents are
```

- `key` is `<size>-<fullhash>-<specifichash>`, in hex, so an index is readable
  and a near match (same size and full hash) is a prefix scan.
- An entry is a JSON object of its own, deterministic like the review document
  (sorted keys, no time inside): an unchanged review stores the same object.
- Writers: the host at publish, through `AnalysisWriter` — a new
  `writeLibraryEntries`, implemented by `ContentStore` and `RemoteStore`, so a
  served store takes them the same way it takes revisions. The server's mirror
  carries `library/` like `reviews/`.
- `gc` keeps every object an index or a history names.
- Rebuildable: every entry is also in its module's review document (the
  functions' decisions are there already); a rebuild walks the stored
  documents of tagged functions.

## 3. Publish

1. The owner, at `/v1/publish`, after the export: for every function with a
   `library.<kind>` tag, its Function ID hashes and its entry, from the same
   decisions `Harvest` collects — served at `GET /v1/library`.
2. The host, after the revision is recorded: `writeLibraryEntries(module:,
   revision:, entries:)`. The store adds a key it does not have, writes the
   next version of a key this module wrote, and answers the others as
   conflicts with the module that holds them.
3. The publish answer gains `library_added`, `library_updated` and
   `library_conflicts` (with `library_conflict_origins`), as it carries
   `type_conflicts`.

## 4. Open and apply

1. At `ghidra_open` the host reads the index and hands the owner the keys
   (`POST /v1/library/match`: the keys only, a few kilobytes even for
   thousands of entries).
2. The owner hashes every function of the program once (Function ID is
   designed for exactly this; a PEIM hashes in well under a second) and
   answers the matches: exact and unnamed, exact and named by a review, or
   full-hash-only.
3. For the exact matches the host sends the entries
   (`POST /v1/library/apply`); the owner applies each in its own transaction,
   as §1 says — the whole entry to an unnamed function; to a named one the
   entry's name (the old one kept in the reason) and only what its review left
   empty — and reports what it could not place (a storage the function does not
   have, a type the archive does not hold) without failing the rest.
4. The open's answer lists what was applied, what was renamed (old name → the
   entry's), the differences a review kept, and the candidates. The agent sees
   them through `ghidra_library`, applies a candidate with
   `ghidra_library_apply` or declines it (remembered in the project, so it is
   not offered again), and settles a difference by keeping the module's
   version or publishing it as the entry's next version.

The applied functions are review work like any other: the next publish
exports them, harvests them into the module's review document, and — since
they carry the tag — offers them back to the registry, where the same content
under the same key is no change.

## 5. Agents and the panel

- `ghidra_library` (read): a module's matches — applied, candidates, declined —
  and, with `key`, one entry and its history.
- `ghidra_library_apply` (write): applies a candidate, or declines it.
- `library_registry` (read, app and server): the index, by kind and name, with
  how many modules each entry was applied to.
- The artifact's function gains `library_entry`; the panel shows "reviewed in
  <module>" in the function's hover and on the C view's header, and the link
  opens that module's function where the store has its analysis.

## 6. Later: similar, not equal (BSim)

Function ID matches equal bodies. The same routine built with other options —
another inlining, another register allocation — hashes differently. Ghidra
12.2's BSim (with its local H2 database) finds such functions by their p-code
features. A second phase adds a BSim database built from the registry's source
functions and offers its matches as candidates only, never applied by itself.

## 7. Phases

1. **Collect.** Owner: hashes and `GET /v1/library`. Store: `library/`, index,
   history, conflicts; `writeLibraryEntries` in `ContentStore` and
   `RemoteStore`; the server's routes and mirror. Publish answer. Read tool
   `library_registry`. Tests: an entry written, versioned, refused as a
   conflict, taken; gc keeps them.
2. **Apply.** `/v1/library/match` and `/v1/library/apply`; the open applies
   exact matches; `ghidra_library`, `ghidra_library_apply`; the mark and
   re-application of a new version. Tests against a module pair that shares
   routines (AmdSocFp6CznPei and AmdSocFp6RnPei share most of their library
   code).
3. **Show.** `library_entry` in the artifact (exporter v9), `code_query`, the
   panel's hover and link; help in every language.
4. **Similar.** BSim candidates.

## 8. Open questions

- Who may take a conflict: any publisher, as with types, or only a person?
- A library function whose body differs between two vendors' builds by a
  constant (the same AGESA routine with another assert code) is two entries
  with one full hash. The full-hash candidate covers it; is that enough, or
  should the registry group them as one function with variants?
