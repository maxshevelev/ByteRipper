# The code artifact

The one-time half of the plan: Ghidra reads a module once, and what it found is
kept under the module's SHA-256 so the panel and an agent can read it later
without Ghidra. It is the whole module, and it is the shape the Code panel
reads.

## Store

The artifact lives in the local CAS (`cas.md`):

```
Analysis/
  objects/<sha256 of the artifact>                  # the artifact bytes
  analyses/<sha256 of the module>/<recipe>/manifest.json
  refs/<name>.json
```

`--store` puts the store elsewhere. The key is the SHA-256 of the **module's
own bytes** — the TE image, not the PE rebuilt for Ghidra — so the same PEIM
from another dump reuses the analysis, and one whose bytes changed does not.
The recipe (exporter version and Ghidra version) is the second half of the
key: a new Ghidra is a second analysis beside the first, never an overwrite.
The manifest records the module, the recipe, the object, the source document
and node, and the counts.

The server looks the module up before it exports: an analysis from the current
exporter is reused, and a publish of a kept project is a new reading of the
same analysis. Bump `SCRIPT_VERSION` in `ExportCode.java` whenever the
exporter's output changes.

## What is in `code.json`

```json
{
  "script_version": 8,
  "ghidra": "12.1.2",
  "program": {
    "name": "CpuPei", "language": "x86:LE:32:default",
    "image_base": "0x0", "sha256": "...", "executable": "..."
  },
  "blocks": [{"name": ".text", "start": "...", "end": "...",
              "executable": true, "initialized": true}],
  "strings": [{"address": "...", "type": "string", "value": "..."},
              {"address": "...", "type": "unicode", "value": "BootOrder"},
              {"address": "...", "type": "unicode", "value": "...",
               "source": "scan"}],
  "functions": [{
    "entry": "0x4BF", "name": "FUN_000004bf", "size": 242,
    "signature": "...", "external": false, "thunk": false,
    "callers": ["0x355"], "callees": ["0x35E", "0x5E8"],
    "name_source": "DEFAULT",
    "review_level": "decompiled",
    "review_gaps": ["name", "plate", "comments", "params", "locals"],
    "c": "undefined4 __fastcall FUN_000004bf(...) { ... }",
    "instructions": [{
      "address": "0x4BF", "bytes": "55 8B EC 83 E4 F8 ...",
      "mnemonic": "PUSH", "text": "PUSH EBP", "flow": "FALL_THROUGH",
      "references": [{"to": "0x4C0", "type": "FLOW"}]
    }]
  }],
  "post_codes": [{"address": "...", "function": "...",
                  "port": "0x80", "text": "OUT 0x80,AL"}],
  "status_code_calls": [{
    "address": "0x535", "function": "0x4BF",
    "text": "CALL dword ptr [ECX + 0x58]",
    "context": ["PUSH 0x11004", "PUSH 0x80000002", "PUSH EDI"]
  }]
}
```

- Addresses are the program's own (module-relative for a TE image with image
  base 0, the PE base otherwise); `bytes` is the instruction's bytes in image
  order, so a reader can tie the listing to the dump.
- `references` are the non-fallthrough references from the instruction. Calls
  and jumps to addresses inside the module are what a reader follows.
- `c` is the decompiler's C, kept per function. It is a derived view: the
  instructions are the ground truth, and a later Ghidra may word the C
  differently.
- `strings` is every string Ghidra defined — `string`, `TerminatedCString`,
  `unicode`, `TerminatedUnicode` — and, marked `"source": "scan"`, the UTF-16
  runs of four characters or more that Ghidra left as bytes, outside any
  instruction. UEFI names its variables and menus in UTF-16; the v2 exporter
  kept only types whose name says `string`, so a v2 BdsDxe has 86 strings and
  no `L"BootOrder"`, a v3 one 328.
- `post_codes` is, before v5, every `OUT` instruction with its port operand
  and text; from v5, what the code writes to port 0x80 — what a board's POST
  card shows — at the place that supplies the value (v5, below).
- `status_code_calls` is a **candidate** list: a call through a table entry at
  `+0x58`, which is `ReportStatusCode` in a 32-bit PEI services table. The
  eight instructions before it are kept as `context`; for CpuPei they are the
  pushes of `0x80000002` (Type), `0x11004` (Value), the instance and the data
  pointer. Another table could use the same displacement, so the reader must
  look at the context and the function, not take the label on trust.
  Only a 32-bit image gets candidates: in a 64-bit one the same slot is Boot
  Services' `SetTimer` or Runtime Services' `SetVariable`. A v2 artifact named
  them in every image (66 in BdsDxe, none of them status codes); both readers
  drop a v2 artifact's list when its language is 64-bit.

### Versions

An artifact from a Ghidra with a patched language carries `language_patch`, the
patch's name, beside `ghidra`, and its recipe id ends in `-lang-<name>`; a stock
Ghidra's has neither (`language-patch/README.md`).

| `script_version` | What changed |
| --- | --- |
| 2 | The first artifact the Code panel reads. |
| 3 | Same shape. UTF-16 strings kept and scanned for; status-code candidates only in a 32-bit image. |
| 4 | Adds, all optional: a function's `name_source` and `name_reason`, its `c_spans`, and the top-level `symbols`. `c` is written from the decompiler's tokens. |
| 5 | `post_codes` are the POST codes followed back through their wrappers, with `value`, `width`, `via` and `unresolved`; the other ports' writes are `port_writes`; a function's `c_sites` place its calls in `c`. |
| 6 | A call the processor model makes into one of its named operations (x86's `SIDT`) is a `pcode` span, not a function with no target. |
| 7 | Adds a function's `review_level` and `review_gaps`: how far the review has got with it, and what keeps it from `full`. |
| 8 | Added a library function's `library_kind`. No longer stored: see "A stored function". |
| 9 | Added a function's `library_entry`. No longer stored: see "A stored function". |

### v7: review level

Every function carries `review_level`, how far the review has got with it, and
`review_gaps`, what still keeps it from `full`; both are written after
`name_source` and `name_reason`, and before the C. `code_query` also answers
`temporaries` for a function: the placeholder names its C still prints
(`uVar1`, `in_ECX`), read from `c_spans`, and `with_temporaries` in the `library`
block. They are reported and bar nothing: a library function can hold them and
still be its entry, and a value folded into an expression cannot be named. An
empty list does not mean the C is clean of raw offsets. The levels are:

- `full` — a plate comment; at least one step comment on an instruction; every
  parameter and local named and typed (a decompiler fragment of a register —
  one register, or a value split over two such as `EDX:4,EAX:4` — or of a
  `unique:` space does not count as a name); and a name that is not Ghidra's
  `FUN_` placeholder. Ghidra's own variable names (`iVar1`, `EVar1`, `uVar2`,
  `local_4`, `param_1`) are placeholders too.
- `partial` — some of that is done. `review_gaps` names what is missing:
  `name`, `plate`, `comments`, `params`, `locals` or `c`, a body that did not
  decompile: a function with no C is never `full`, whatever its names say.
- `decompiled` — nothing of the review: no plate, no step comments, and no
  parameter, local or function name a person gave. A name the UEFI pass read
  or the image carried is not review work.
- `library` — library code the module statically links in: a function carrying
  a library tag. A publish stores none without a registry entry.
- `no_body` — external or thunk; the exporter writes no C for it, so there is
  nothing to review and its gaps are empty.

`full` and an empty `review_gaps` say that nothing the review can name is left,
not that the C holds no placeholder: a decompiler temporary (`sVar1`, `pCVar3`)
on a register piece or in the `unique:` space has no storage to name. Such
pieces are `leftovers.fragments` in `ghidra_function`, and are read there.

`full` says the fields are filled, not that they are right. Nothing in the
store can tell a right name or type from a wrong one: a sweep of BdsDxe's `full`
rows found two size locals swapped, an inverted flag's name and a `uint[2]`
under a single dword's name. Only reading the instructions finds those.

`full` is a mechanical bar: the function's name, plate, step comments,
parameters and stack locals. It does not reach three things. A comment on data
belongs to no function's row, so a stale one on a PPI list keeps nothing from
`full`. A placeholder on a register or `HASH` is reported as `temporaries`, not
as a gap. An index typed as a pointer is a judgement no check makes. A function
given back from the registry reads by the same bar and carries no mark of its
own.

`review_gaps` is always written, empty when there are none. A v2–v6 artifact
has neither field, and the panel shows its functions as "Review level not
recorded".

### A stored function: its own, or a link

What the store holds of a function is one of two records
(`ModuleFormat.stored`, which every analysis goes through on its way in):

- **Its own**: the fields of this schema, with no library field.
- **A link**: `registry`, the library entry's number
  (`Design/LIBRARY_REGISTRY_PLAN.md`), and `entry`, `size`, `callers`, `callees`,
  `targets`, `body`, `reference_bytes`. No name, signature, comment, C or instruction:
  a reader takes those from the registry. `targets` maps what the body's code refers
  to outside itself — a callee by its registry number, data by its label — to the
  address in this module.

The registry holds a body's code as an object of its own (`LibraryVariant.code`):

```json
{"base": "0x…",
 "instructions": [{"address": "0x…", "bytes": "E8 …", "mnemonic": "CALL", "text": "CALL 0x…",
                   "flow": "…",
                   "references": [{"to": "0x…", "type": "UNCONDITIONAL_CALL", "entry": "<number>"}]}]}
```

`base` and the addresses are those of the module it was learned from; a reader replaces
them with its module's (`LibraryCode.instructions`), and the rebuild must give that
module's real bytes and text for the link to exist (`LibraryCode.bind`). The lists of an
artifact (`post_codes`, `port_writes`, `status_code_calls`) keep no text at a link's
instructions; a reader fills it the same way.

`library_kind`, `library_entry` and a `review_level` of `library` are not in the
stored form. A reader that meets them in an older object does not read them: a row
with no `registry` is the module's function.

`library_kind` and `library_entry` in `code_query`'s answer come from the entry, not
from the artifact. An export from a project still carries `library_entry` (`id`,
`version`, `state`: `entry`, or `edited` for a function written on since it was bound,
the mark `dirty` in the project): that is the project's note to the publish, and no store holds it.

### v5: POST codes

A POST code is seldom `OUT 0x80, imm` where it is sent. The constant is an
argument of `IoWrite8`, of a `PostCode()`, of a vendor's halt routine that
writes it and spins, and the `OUT` itself reads two parameters. So the
exporter reads each `OUT`'s port and value from the decompiler's p-code — a
constant, a parameter of its function, or computed — and where one is a
parameter, reads every call of the function with the argument in that place,
up to four wrappers deep. A value passed by pointer (`IoWrite(Width, Port,
&Value)`) is the constant stored to that local before the call.

```json
"post_codes": [
  {"address": "0x9A8596A", "function": "0x9A8595E", "port": "0x80",
   "value": "0x20320120", "width": 4,
   "via": [{"function": "0x9A85BE0", "name": "FUN_09a85be0"}], "text": "CALL 0x09a85be0"},
  {"address": "0x9A85C33", "function": "0x9A85BE0", "port": "0x80", "value": null,
   "width": 4, "unresolved": "value-computed", "via": [], "text": "OUT DX,EAX"}],
"port_writes": [{"address": "0x2A1F3", "function": "0x2A1C0", "port": "0x70", "value": "0x8F", …}],
"c_sites": [[122, 12, "0x9A8596A"]]
```

- `address` is the place that supplies the value: the call of the outermost
  wrapper, or the `OUT` when the value is there. `via` lists the functions
  between it and the `OUT`, outermost first.
- `port` is `0x80`, or null when the port is not known: such a write is kept
  in `post_codes`, since it may be one. Writes to any other known port are in
  `port_writes`.
- `value` is null when the code does not say it; `unresolved` says why:
  `value-parameter` (a caller this module does not show), `value-computed`
  (a table, a loop, a read), `port-parameter` (a service other modules call,
  such as CpuIoPei's I/O PPI), `port-computed`. Several values at one place —
  `Code = Error ? 0x10 : 0x20` — are several entries.
- `c_sites` are `[start, length, address]` in UTF-16 units of `c`: the called
  name of each call and the call's address, so a place in the listing is
  found in the C.

Later exporters of v5 add, all optional (a reader ignores what it does not
know):

```json
"equates": [{"name": "PCI_CONFIG_ADDRESS", "value": "0xCF8", "enum": "FCH_IO_PORT",
             "comment": "PCI configuration address port … Source: PCI 3.0",
             "references": [["0x9DFE6F5", 1]]}],
"types": [{"name": "SEC_SERIAL_DEVICE_INFO", "path": "/SEC_SERIAL_DEVICE_INFO",
           "kind": "typedef", "size": 32, "description": "…", "c": "typedef struct …"}],
"c_fields": [[1449, 3, "EFI_SYSTEM_CONTEXT_IA32", 628]],
"c_unreachable": [2310, 45, ["0x9DFF3F0", "0x9DFF16E", "…"]]
```

- `equates` are the names a review gave constants (`ghidra_equate`): the
  value, the enum the name is a member of and the member's comment, and every
  operand that holds it as `[instruction address, operand index]`. The C
  writes the name where the number was, as a `constant` span.
- `types` are the types the C names — through pointers and arrays — and the
  enums of the equates, as C with every field's offset and comment.
- a function's `c_fields` are `[start, length, type, offset]`: a structure
  field named in `c`, the type it belongs to and its offset in it.
- a function's `c_unreachable`, present only when the decompiler removed two
  or more blocks as unreachable, is `[start, length, [address, …]]`: the one
  line `/* WARNING: Removing 74 unreachable blocks */` that `c` holds in place
  of a warning per block, and the blocks' addresses in the decompiler's
  order. One removed block keeps Ghidra's own line. The owner's
  `/v1/function` still answers every warning.

The Code panel shows these when a name is clicked (`CodeExplanation`).

What it finds on modules at hand: BdsDxe 33 codes with their places, an AMD
PEIM's halt routine with 29 callers and their codes (`0xDF390148` …), CpuIoPei
none known (its writes are the I/O PPI, the port a caller's). PeiCore writes
nothing to a port: its codes are status codes, reported through
`ReportStatusCode`, and which byte reaches port 0x80 for one is the platform's
status-code module's choice.

### v4: names, spans, symbols

```json
"name_source": "ANALYSIS",
"name_reason": "CreateEventEx registers it for the gEfiEventReadyToBootGuid event group",
"c_spans": [[41, 3, "global", "0x31FD0"], [52, 5, "function", "0x230"], [0, 4, "type"]],
"symbols": [{"address": "0x31FD0", "name": "gBS", "type": "EFI_BOOT_SERVICES *",
             "source": "ANALYSIS", "reason": "written from a EFI_BOOT_SERVICES* value in FUN_00000498"}]
```

- `name_source` is Ghidra's `SourceType`: `DEFAULT` is the `FUN_` placeholder,
  `ANALYSIS` a name the UEFI pass read from the module (`uefi-pass.md`),
  `IMPORTED` the image's own, `USER_DEFINED` a person's.
- `c_spans` are `[start, length, kind]` or `[start, length, kind, target]`,
  in UTF-16 units of `c`. Kinds: `keyword`, `comment`, `type`, `constant`,
  `parameter`, `local`, `function` (target: the called entry), `global`
  (target: its address). The Code panel colours by kind and makes a target a
  link; without spans (v2, v3) it lexes the C and links names it knows.
- `symbols` is the named data: GUIDs, service tables, interfaces. A symbol
  the review commented (`ghidra_comment` at its address: plate, pre, eol or
  repeatable, the first there is) carries it as `comment`; the Code panel
  shows it when the name is clicked, with the value the image holds.

The Swift reader (`CodeArtifact.supportedScriptVersions`) and the `code_query`
tool accept the same set and refuse any other. A v3 run is a new recipe beside
the v2 one; the v2 analysis stays readable.

## Reading it

A module with a kept project is exported by a publish:

```
ghidra_create(node: "0.5.5.2.0.1.0.8.1", document: <id>)   # or module: <sha256>
ghidra_publish()                                         # artifact, revision, review
```

Later, with no Ghidra in the picture:

```
code_modules(document: <id>)                             # what the store holds
code_query(module: <sha256>, what: "functions")
code_query(module: <sha256>, what: "c", function: "0x4BF")
code_query(module: <sha256>, what: "instructions", function: "0x4BF", limit: 20)
code_query(module: <sha256>, what: "references", function: "0x4BF")
code_query(module: <sha256>, what: "uses", address: "0x4BF")
code_query(module: <sha256>, what: "strings", search: "Boot")
code_query(module: <sha256>, what: "symbols")
code_query(module: <sha256>, what: "post_codes")
```

A module may be named by its image `node` in a document instead of the SHA-256;
the bytes are hashed to find the analysis, and the answer also carries each
address's offset in the module — the number the hex view shows.

The node and document a module is opened by are provenance with a use: the UEFI
panel matches the manifest's `source.document` to the file name it shows, opens
the branch `source.node` names, and puts the code badge on that image node —
including a PEI image inside a compressed Boot FV, which the lazy tree has not
materialized otherwise. The body's SHA-256 still decides whether the analysis
applies; the path is only where to look.

## What CpuPei looks like in it

- 13 functions, 508 instructions, no strings, no `OUT` writes;
- one status-code candidate at `0x535`, a `CALL dword ptr [ECX + 0x58]` with
  the pushes `0x80000002`, `0x11004`, the core id and the descriptor — the
  `ReportStatusCode` call the analysis found by hand;
- `what: "uses", address: "0x11004"` finds the `PUSH`, and `what: "c",
  function: "0x4BF"` shows the loop that reports it per core.

## Boundaries

- The artifact is a snapshot. New user-guided analysis (retyping a function,
  resolving an indirect call) is made in the kept project and published; the
  store then takes it as a new reading. The module bytes determine the key; an
  exporter change determines the version.
- Ghidra is not needed to read an artifact, and this script does not start it.
- A status-code candidate is exactly that: a candidate. The function, the
  context and the decompiled C say whether it is `ReportStatusCode`.
- The artifact says what the code does, not what the board did: observed order,
  values and hangs remain runtime facts.
