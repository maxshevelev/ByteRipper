# The code artifact

The one-time half of the plan: Ghidra reads a module once, and what it found is
kept under the module's SHA-256 so the panel and an agent can read it later
without Ghidra. `ExportModule.java` answers a single question about a module;
this artifact is the whole module, and is the shape the Code panel will read.

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

`code_artifact.py` looks the module up before doing anything: an analysis from
the current exporter is reused; `--force` runs the analysis again. Bump
`SCRIPT_VERSION` in the script and in `ExportCode.java` whenever the exporter's
output changes.

## What is in `code.json`

```json
{
  "script_version": 3,
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

| `script_version` | What changed |
| --- | --- |
| 2 | The first artifact the Code panel reads. |
| 3 | Same shape. UTF-16 strings kept and scanned for; status-code candidates only in a 32-bit image. |
| 4 | Adds, all optional: a function's `name_source` and `name_reason`, its `c_spans`, and the top-level `symbols`. `c` is written from the decompiler's tokens. |
| 5 | `post_codes` are the POST codes followed back through their wrappers, with `value`, `width`, `via` and `unresolved`; the other ports' writes are `port_writes`; a function's `c_sites` place its calls in `c`. |

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

The Swift reader (`CodeArtifact.supportedScriptVersions`) and `code_query.py`
(`SUPPORTED_SCRIPT_VERSIONS`) accept the same set and refuse any other. A v3
run is a new recipe beside the v2 one; the v2 analysis stays readable.

## Reading it

```bash
# one-time; Ghidra
python3 Skills/ghidra-uefi/scripts/code_artifact.py CpuPei.te --name CpuPei \
    --document "CSME 15.bin" --node 0.5.5.2.0.1.0.8.1

# later; no Ghidra
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te summary
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te functions
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te function 0x4BF
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te disasm 0x4BF --limit 20
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te decompile 0x4BF
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te xrefs 0x4BF
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te uses 0x4BF
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te search 0x11004
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te strings
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te post-codes
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te status-codes
```

A target may be the module file (its hash is computed) or the SHA-256 itself.
`--json` gives the same answer as data, for an agent that wants to post-process
it.

`--document` and `--node` are provenance with a use: the UEFI panel matches the
manifest's `source.document` to the file name it shows, opens the branch
`source.node` names, and puts the code badge on that image node — including a
PEI image inside a compressed Boot FV, which the lazy tree has not materialized
otherwise. The body's SHA-256 still decides whether the analysis applies; the
path is only where to look. Naming an existing analysis this way does not run
Ghidra again.

## What CpuPei looks like in it

- 13 functions, 508 instructions, no strings, no `OUT` writes;
- one status-code candidate at `0x535`, a `CALL dword ptr [ECX + 0x58]` with
  the pushes `0x80000002`, `0x11004`, the core id and the descriptor — the
  `ReportStatusCode` call the analysis found by hand;
- `search 0x11004` finds the `PUSH`, and `decompile 0x4BF` shows the loop that
  reports it per core.

## Boundaries

- The artifact is a snapshot. New user-guided analysis (retyping a function,
  resolving an indirect call) needs `analyzeHeadless` again; the store then
  replaces the entry. The module bytes determine the key; an exporter change
  determines the version.
- Ghidra is not needed to read an artifact, and this script does not start it.
- A status-code candidate is exactly that: a candidate. The function, the
  context and the decompiled C say whether it is `ReportStatusCode`.
- The artifact says what the code does, not what the board did: observed order,
  values and hangs remain runtime facts.
