# The code artifact

The one-time half of the plan: Ghidra reads a module once, and what it found is
kept under the module's SHA-256 so the panel and an agent can read it later
without Ghidra. `ExportModule.java` answers a single question about a module;
this artifact is the whole module, and is the shape the Code panel will read.

## Store

```
~/Library/Application Support/ByteRipper/Analysis/<sha256 of the module bytes>/
    manifest.json
    code.json
```

`--store` puts it elsewhere. The key is the SHA-256 of the **module's own
bytes** — the TE image, not the PE rebuilt for Ghidra — so the same PEIM from
another dump reuses the artifact, and one whose bytes changed does not.
`manifest.json` records where it came from, the Ghidra and exporter versions,
and the counts; `code.json` is the analysis.

`code_artifact.py` checks the manifest before doing anything: an artifact whose
`script_version` is current is reused; `--force` re-runs it. Bump
`SCRIPT_VERSION` in the script and in `ExportCode.java` whenever the exporter's
output changes, so no reader mistakes an old shape for a new one.

## What is in `code.json`

```json
{
  "script_version": 1,
  "ghidra": "12.1.2",
  "program": {
    "name": "CpuPei", "language": "x86:LE:32:default",
    "image_base": "0x0", "sha256": "...", "executable": "..."
  },
  "blocks": [{"name": ".text", "start": "...", "end": "...",
              "executable": true, "initialized": true}],
  "strings": [{"address": "...", "type": "string", "value": "..."}],
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
- `post_codes` is every `OUT` instruction, with its port and text. A board's
  POST card shows what these write.
- `status_code_calls` is a **candidate** list: a call through a table entry at
  `+0x58`, which is `ReportStatusCode` in a 32-bit PEI services table. The
  eight instructions before it are kept as `context`; for CpuPei they are the
  pushes of `0x80000002` (Type), `0x11004` (Value), the instance and the data
  pointer. Another table could use the same displacement, so the reader must
  look at the context and the function, not take the label on trust.

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
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te search 0x11004
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te strings
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te post-codes
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te status-codes
```

A target may be the module file (its hash is computed) or the SHA-256 itself.
`--json` gives the same answer as data, for an agent that wants to post-process
it.

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
