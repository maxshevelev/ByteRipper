# A shared registry of library functions — reviewed once, applied everywhere

> **The rule, as the person set it (2026-11-03), over everything below that says
> otherwise:** a library function is one code, one C and one description, whichever
> module it is in, and the description exists only in the registry. A module holds
> the code at its addresses, and a link to the entry: the name and signature its
> callers print, and nothing else. A reader takes the rest from the entry
> (`LibraryView`). A different body is a different function: its own entry, its own
> C, and its own name. A library function's name is unique in the registry: a body
> offered under a name another entry holds is refused (`name_conflicts`), and the
> review looks at what both functions mean and resolves it, by renaming either: a
> name goes by meaning, not by who came first, and `ghidra_library_rename` lets the
> entry that holds one too wide give it up. A module's own
> function is in the module's scope and conflicts with nothing in other modules.
> A text true of one module only means the function is not a library function, and
> it does not belong here. An open links (`mode: link`); `whole` remains only as the
> working copy `replace` asks for, to change an entry on. A module stores its own facts
> and the link: no name, signature, plate, comment or C of a registry function, in the
> artifact or the review (`LibraryCopyFree`); such a function has `state: linked`, a
> stored copy shows as `stored_copy`. The key masks an operand, so a function whose data
> references point at other bytes than the entry's is another function
> (`reference_bytes`). A reference reads 16 bytes, a string only up to its terminator, and
> doubt counts as a difference. One limit: a GUID whose first byte is printable and whose second
> is zero reads as a one-character string. An entry learns its bytes at its source module's
> publish and decides nothing until then, so a source module publishes first. A function is in one
> place in the registry, and history is no copy.
>
> **What a library function is (2026-11-03):** it depends on no module. It refers to
> no data, or only to a constant defined in its own library's source file, cited by
> file and line by an agent who compared the bytes; a GUID never qualifies. It calls
> only library functions, so classification runs bottom-up, from functions that call
> nothing. A doubt goes to the module. A publish refuses a new body that fails
> (`not_library`); `taken_out` in the index holds what was given back, with its last
> text, for its modules to take at their next open (`LibraryChanges.swift`).

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

- **What goes in**: a function a review tagged `library.edk2`, `library.amd` or
  `library.intel`, at every publish of its module — and only when its review is
  complete by the highest bar the skill sets for a function ("What a finished
  function looks like"): a name that is not a placeholder, every parameter and
  local named and typed, a plate that opens with the evidence for its kind, and
  step comments. The exporter grades a tagged function as it grades any other,
  and writes what it lacks into `review_gaps`; its `review_level` stays
  `library`, because the tag is the level and the gaps are the bar's. The
  registry takes it only with no gaps at all, because what it holds is copied
  into every module with the same body. A tagged function short of the bar
  stays in its module and is listed in the publish answer with its gaps. Nothing else goes
  in: a module's own work is not shared, and a function tagged without a kind
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
- **An exact match is linked** when the module is opened. The function takes
  the entry's name, signature and library tag, and carries the entry's key and
  version, with the digest of the review (`ByteRipper.libraryEntry`). Nothing
  else of the entry is written into the module: a reader takes the plate, the
  comments, the variables and the C from the entry (`LibraryView`), which writes
  this module's addresses and names into them. A later version reaches a linked
  function at the next open, unless the function was edited since. A function
  edited on the entry says so in its mark, and its next publish is a change to
  the entry (below). A function whose review differs from the entry is not
  overwritten: the open's answer lists it, and the agent either takes the
  entry's (`replace`) or publishes its own as the entry's next version.
- **Other constants are another function — except an assert code.** Two
  bodies with the same full hash and size but another specific hash differ
  only in operand values. An MSR number, a port, a mask or a size changes what
  the code does, so such bodies are two functions and two entries. One kind of
  value does not: the code an assert routine is called with — AGESA's
  `file id << 16 | line`, which moves when the source file gains a line above
  the call. Bodies that differ only there are **variants** of one entry: one
  review (name, signature, variables, plate, comments) and several bodies,
  each with the codes it carries.
  - The owner compares two such bodies instruction by instruction and lists
    every operand that differs — where, and both values. A difference is an
    assert code when the operand is the argument of a call to a function the
    registry holds as an assert routine (`AgesaAssertHalt`; Intel's when one is
    reviewed). That test is mechanical.
  - When every difference passes it, the open applies the entry to the new body
    as an exact match would, and the next publish adds the body to the entry as
    a variant, with its codes. When any difference fails it, the body is a
    candidate: `ghidra_library` shows it with the list of differences, and the
    agent reviews it as a function of its own — or, when it finds the values
    make no difference after all, says why and adds it as a variant.
  - The panel shows a variant as the entry's function, with "variant 2 of 3,
    assert 0x10196" in its hover.
- **One entry per key, improved in place.** A publish whose tagged function has
  the key of an existing entry does not add an entry: when its review equals the
  entry, nothing changes; when it differs, it is a change to the one entry.
- **No module holds an entry.** A function in the registry belongs to every
  module whose function has its body, alike; the module that published a
  version is in the history, as the author of a commit, and has no say over
  the next. What decides is the version a change was made on. Each function
  that is the entry carries its version in its mark — applied at an open, or
  marked by the publish that offered it. A change to such a function,
  published, is the entry's next version, whichever module publishes it. A
  review made on an older version, or by a function that never carried the
  entry, is a conflict, reported with the version it was made on; one publish
  takes the conflicts it names (`take_library_conflicts: ["<id>", …]`, or
  `true` for all), each with the reason the history keeps, and leaves the rest
  as conflicts. The agent that reviews and publishes resolves a conflict: it
  reads both reviews, keeps the better one or merges them, and gives the
  reason the history keeps.
  The next version reaches every other module at its next open, where its
  function was not edited since.
- **Readers see that a function is the registry's**: the artifact records
  `library_entry` (the entry, its version, and whether the function is the
  entry, was edited on it, or differs from it), `code_query` answers it, and
  the panel marks it on the library badge (§5).

## 2. Storage

```
library/index.json                 { body → { id, version } ;  id → { version, entry: <sha256>, kind, name, variants } }
library/history/<id>.json          every version of one entry: { version, entry, source, reason, recorded_at, by }
objects/<sha256>                   the entries, as review documents are
```

- A **body** is `<size>-<fullhash>-<specifichash>`, in hex; an **entry** has an
  id of its own (its first body), and its `variants` are the bodies it covers,
  each with the assert codes it carries and the module it was first seen in.
  Every body of every variant is in the index, so an exact match is one
  lookup, and a near match (same size and full hash) is a prefix scan.
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
   (`POST /v1/library/apply`, `mode: link`); the owner writes each in its own
   transaction, as §1 says: the entry's name, its signature with its storage,
   the tag and the mark, and reports what it could not place without failing
   the rest. Only `replace` asks for `mode: whole`, the working copy of the
   whole entry a review changes the entry on.
4. The open's answer lists what was linked, what was renamed (old name → the
   entry's), the differences a review kept, and the candidates. The agent sees
   them through `ghidra_library`, links a candidate with
   `ghidra_library_apply` or declines it (remembered in the project, so it is
   not offered again), and settles a difference by taking the entry's or
   publishing its own as the entry's next version.
5. A body the registry gave back (`taken_out`) is released at the next open:
   the function becomes the module's, with the entry's last text as its own, no
   mark and no tag.

A linked function has nothing to say to the registry: the next publish offers it
only when it is the entry's own review, which is no change. There is one
exception that changes no version: the module the entry's C came from, at the
same address, replaces the C when the text differs only in how the decompiler
prints it (a zero pointer as `NULL`, line breaks, the warning of a convention
nobody names). The review, the version and every module's mark stay.

## 5. Agents and the panel

- `ghidra_library` (read): a module's matches — applied, candidates, declined —
  and, with `key`, one entry and its history.
- `ghidra_library_apply` (write): applies a candidate, or declines it.
- `library_registry` (read, app and server): the index, by kind and name, with
  how many modules each entry was applied to.
  The lists (entries, taken-out bodies, citations) are paged; one entry's answer
  leaves out a recorded function's `instructions`, `c_spans` and `c_fields`,
  which are read apart a page at a time, since they alone can pass the answer
  bound.
- The artifact's function gains `library_entry` (exporter v9): `id`,
  `version`, `state` — `entry` (the function is the entry's version), `edited`
  (changed on that version since; the next publish makes it the next version,
  or reports the conflict), `differs` (a review that named the function keeps
  what differs from the entry, listed in `differences`) — and a variant's
  `codes`. The owner writes it before each export from the mark and from what
  the last apply left (`ByteRipper.libraryState`).
- The panel, on the library badge: filled for `entry`; outlined with a dot for
  `edited` and `differs`; outlined as before for a library function the
  registry does not hold. The hover says "Library registry entry, v3" (a
  variant adds its assert codes; `differs` lists what differs), and the C
  view's header carries the same line. There is no "reviewed in" and no link
  to another module: the function in this module is the entry. The
  navigator's library groups say how many of their functions the registry
  holds.
- Help in every language.

## 6. Later: similar, not equal (BSim)

Function ID matches equal bodies. The same routine built with other options —
another inlining, another register allocation — hashes differently. Ghidra
12.2's BSim (with its local H2 database) finds such functions by their p-code
features. A second phase adds a BSim database built from the registry's source
functions and offers its matches as candidates only, never applied by itself.

## 7. Phases

Phases 1, 2 and 3 are done.

1. **Collect.** Owner: hashes and `GET /v1/library`. Store: `library/`, index,
   history, conflicts; `writeLibraryEntries` in `ContentStore` and
   `RemoteStore`; the server's routes and mirror. Publish answer. Read tool
   `library_registry`. Tests: an entry written, versioned, refused as a
   conflict, taken; gc keeps them.
2. **Apply.** `/v1/library/match`, `/v1/library/compare`,
   `/v1/library/apply` and `/v1/library/decline`; the open applies the
   matches; `ghidra_library`, `ghidra_library_apply`; the mark and
   re-application of a new version. An entry records its body's constants
   (`constants`, by offset and operand) so a body of its shape can be compared
   without the source module, and an assert routine is tagged
   `assert_routine` (`assert` in its entry, `role` in the index). A live test
   (`GhidraHostLibraryTests`, `GHIDRA_LIBRARY_MODULES`) runs a module pair
   that shares routines — AmdSocFp6CznPei and AmdSocFp6RnPei.
3. **Show.** `library_entry` in the artifact (exporter v9), `code_query`, the
   panel's hover and link; help in every language.
4. **Similar.** BSim candidates.

## 8. Open questions

- None at the moment. Decided with the person: entries only at the highest
  bar; one body, one entry, renamed to converge; the agent resolves conflicts
  with a reason; other constants are other functions, assert codes make
  variants.
