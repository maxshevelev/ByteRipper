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
- `post_codes` is every `OUT` instruction, with its port and text. A board's
  POST card shows what these write.
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
