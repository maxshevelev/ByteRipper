---
name: ghidra-uefi
description: Take one PEI or DXE module out of a firmware dump and analyze it in Ghidra — ByteRipper's UEFI Structure panel is the oracle for where the module is and what its bytes are, and this skill carries them across, rebuilds a TE image as a PE so Ghidra's loader accepts it, and drives either the running Ghidra through GhydraMCP or a headless analysis that writes functions and decompiled C to JSON, and keeps a one-time code artifact that answers function, instruction, xref and status-code questions without Ghidra. Use when a person asks what a PEIM or DXE driver does, where a function is called from, or why a module in a dump misbehaves; when a module inside a Tiano or LZMA section has to be disassembled; or when a firmware image has to be read as code rather than as bytes.
---

# A UEFI module in Ghidra

ByteRipper already knows where a module is: its UEFI Structure panel has walked
the volumes, opened the FFS files, decompressed the Tiano and LZMA sections and
named the PE32 and TE images. Ghidra knows what the module means: instructions,
functions, cross-references, a decompiler.

This skill is the narrow path between them. It does **not** parse firmware
volumes on its own for the main workflow — asking ByteRipper is the reference,
and a second parser would disagree with the panel the person is looking at.
The one exception is the offline fallback at the end, which exists for a machine
with no app running.

## The pieces

| piece | where | what it does |
|---|---|---|
| `scripts/byteripper_extract.py` | talks MCP/stdio to the app's relay | fetches a node's bytes in 4 KiB pages and writes them to a file |
| `scripts/te_to_pe.py` | stdlib | rebuilds a PE32/PE32+ file from a TE image |
| `scripts/ghidra_import.py` | calls Ghidra's `analyzeHeadless` | converts TE if needed, imports, analyzes, exports JSON |
| `scripts/ExportModule.java` | a Ghidra script | functions, signatures, callers/callees, decompiled C |
| `scripts/ApplyUefi.java` | a Ghidra script, before the export | the UEFI pass: EDK2 types on the entry point and down the calls, gBS/gRT/gST, GUID names, protocol and PPI pointers, callbacks, DEBUG names (`reference/uefi-pass.md`) |
| `scripts/BuildUefiTypes.java` | a Ghidra script, once | parses MdePkg's headers into `uefi_X64.gdt` / `uefi_Ia32.gdt` |
| `scripts/progress.py` | stdlib | what a long step is doing while it runs, and its time limit |
| `scripts/uefi_types.py` | git, Ghidra, once | builds and caches the type archives and the GUID table the pass needs |
| `scripts/ExportCode.java` | a Ghidra script | the full code artifact: every instruction, references, C with its token spans, named data, strings, POST writes and status-code candidates |
| `scripts/code_artifact.py` | one Ghidra run per module | analyzes once and stores the artifact under the module's SHA-256 |
| `scripts/code_query.py` | stdlib, no Ghidra | reads the stored artifact: functions, disassembly, C, xrefs, the uses of an address, search, post-codes |
| `scripts/ghidra_owner.py` | analyzeHeadless, javac, java | a kept Ghidra project per module and the long-lived owner that serves it on loopback: open, read calls, publish into the CAS, stop |
| `owner/Owner.java` | built by `ghidra_owner.py` | the owner: one program, the bridge's read calls and publish (`Design/GHIDRA_SHARED_PLAN.md` phase 1) |
| `scripts/cas.py` | `byteripper-cas` (built once with `swift build`) | the client of the local content-addressed store, which is implemented once in `Packages/CodeAnalysis` |
| `scripts/cas_cli.py` | `cas.py` | the store's command line: list, show, verify, gc, ref, export, import, conflicts |
| `scripts/module_scan.py` | stdlib, offline only | finds PE32/TE images in a dump without the app; opens LZMA, not Tiano |
| `reference/uefi-images.md` | — | the structures and the addresses |
| `reference/ghidra.md` | — | GhydraMCP tools, import rules, pitfalls |
| `reference/code-artifact.md` | — | the artifact's schema, queries and limits |
| `reference/cas.md` | — | the local CAS: the tool, layout, keys, readings, references, GC, bundles |

## 1. Find the module in ByteRipper

The app must be running with **Settings ▸ Agent** switched on. The relay the app
installs is what both the agent and the scripts talk to.

- `documents` — what is open; the focused dump is the default.
- `uefi_find` with `guid`, `name` (part of the name) or `type: "Section"` — for
  modules, the useful names are `PE32 image` and `TE image`; the answer gives
  the node id, the path of names and, when the module lives inside a compressed
  section, `in_compressed: true` and the algorithm.
- `uefi_tree` / `uefi_node` — the node's size, its file and section types, its
  place in the tree.

Do not guess offsets. The node id is the address of the thing in the tree, and
`uefi_node_data` reads it even when it has no file address at all.

Example, from a 32 MiB SPI dump with a BIOS region:

```
uefi_find(document: d1, name: "PE32 image", type: "Section", limit: 10)
  -> 0.5.4.2.0.1.0.2.2  "PE32 image in AmiUpdateDxePolicyCallback"
     path: … FFSv2 > AmiUpdateDxePolicyCallback > PE32 image
     compressed: LZMA, in_compressed: true
```

## 2. Carry the bytes out

```bash
python3 Skills/ghidra-uefi/scripts/byteripper_extract.py \
    --document "CSME 15.bin" --node 0.5.4.2.0.1.0.2.2 \
    --out /tmp/AmiUpdateDxePolicyCallback.efi \
    --meta /tmp/AmiUpdateDxePolicyCallback.json
```

- `--part body` (default) is the image itself; `all` includes the section
  header; `decompressed` is a compressed section's whole contents.
- The script opens the relay at
  `~/Library/Application Support/ByteRipper/byteripper-mcp`, or
  `$BYTERIPPER_RELAY`, or beside `$BYTERIPPER_AGENT_SOCKET`.
- It reads 4 KiB per call; a 100 KiB DxeCore takes about half a second.
- The metadata records the node, the compression source (`start`, `end`,
  `section`), the size, SHA-256 and the PE/TE header facts.

## 3. Get it into Ghidra

### Interactive: a running Ghidra and GhydraMCP

Ghidra's MCP extension (`GhydraMCP`) listens on 8192, 8193, … for each open
CodeBrowser. Use `instances_list`, then `instances_use(port)`.

- **PE32/PE32+** — open the extracted file in Ghidra. The PE loader handles it.
- **TE** — Ghidra's PE loader starts at a DOS header and refuses `VZ`.
  Convert first: `te_to_pe.py module.te -o module.pe`, then open the `.pe`.

Then the useful tools are `functions_list`, `functions_decompile`,
`functions_disassemble`, `xrefs_list`, `analysis_get_callgraph`,
`data_list_strings`, `functions_rename`, `functions_set_comment`.

### Batch: headless, result on disk

```bash
python3 Skills/ghidra-uefi/scripts/ghidra_import.py /tmp/module.efi \
    --out /tmp/module.analysis.json \
    --ghidra-home ~/Projects/ghidra/ghidra_12.1.2_PUBLIC
```

It converts a TE, imports the image, runs the default analyzers (a few seconds
to a minute depending on size), and writes JSON: program facts, memory blocks,
and for each function its entry, size, signature, callers, callees and the
decompiled C. The Ghidra project is kept, so a follow-up question can use
`analyzeHeadless … -process <program> -noanalysis -postScript …` and skip the
analysis.

`--no-decompile` gives names and call edges only. `--delete` removes the
temporary project.

### Kept: a long-lived owner per module

```bash
python3 Skills/ghidra-uefi/scripts/ghidra_owner.py open /tmp/CpuPei.te --name CpuPei \
    --document "CSME 15.bin" --node 0.5.5.2.0.1.0.8.1
python3 Skills/ghidra-uefi/scripts/ghidra_owner.py get <module-sha> /v1/function/0x68A
python3 Skills/ghidra-uefi/scripts/ghidra_owner.py publish <module-sha>
python3 Skills/ghidra-uefi/scripts/ghidra_owner.py stop <module-sha>
```

`open` keeps the module's Ghidra project in
`~/Library/Application Support/ByteRipper/GhidraProjects/<module-sha>/` — made
once by the same analysis and UEFI pass as `code_artifact.py` — and starts an
owner that holds it open; a later `open` reuses a running one. The read calls
(`/v1/hello`, `/v1/functions`, `/v1/function/<addr>`, `/v1/disassembly/<addr>`,
`/v1/xrefs?to=`, `/v1/data`, `/v1/strings`) answer from the live program, with
decompiled C and every local's storage and first use. `publish` stores the
program's artifact in the CAS the app reads; for an unchanged program it is
byte for byte what `code_artifact.py` stores. The owner saves and exits after
`--idle` seconds without a call (1800 by default). Renames through the owner
are phase 2 of `Design/GHIDRA_SHARED_PLAN.md`.

## The one-time code artifact

Analysis and reading are split. `code_artifact.py` runs Ghidra once and stores
what it found in the local CAS, keyed by the module's SHA-256 and the analysis
recipe; `code_query.py` answers from that store and never starts Ghidra.

```bash
python3 Skills/ghidra-uefi/scripts/code_artifact.py CpuPei.te --name CpuPei \
    --document "CSME 15.bin" --node 0.5.5.2.0.1.0.8.1

python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te functions
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te decompile 0x4BF
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te search 0x11004
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te uses 0x4BF
python3 Skills/ghidra-uefi/scripts/code_query.py CpuPei.te status-codes
```

The exporter writes `script_version: 4` (`reference/code-artifact.md`): a
module analyzed by an older exporter is analyzed again as a new recipe beside
the old one. Before the export, `ApplyUefi.java` types and names the module
from EDK2 (`reference/uefi-pass.md`); the first run builds its type archives,
about a minute. `--phase pei|dxe` overrides the guess (TE or 32-bit is PEI);
`--no-uefi` keeps Ghidra's names only, as a `-plain-` recipe of its own.

The store is `~/Library/Application Support/ByteRipper/Analysis`:

```
objects/<sha256 of the artifact>
analyses/<sha256 of the module>/<recipe>/manifest.json
refs/<name>.json
```

The key is the module's own bytes plus the recipe (exporter and Ghidra
version), so the same PEIM from another dump reuses the analysis, and a new
Ghidra is a second analysis beside it. `--force` re-runs; `SCRIPT_VERSION` in
both the script and `ExportCode.java` is the invalidation when the exporter
changes. The artifact holds functions, every instruction with its bytes and
references, the decompiled C, strings, `OUT` writes, and candidates for
`ReportStatusCode` calls (a call through a PEI services table entry at `+0x58`,
with the pushes before it kept as context).

The store has its own commands, and the same `--store` as the scripts:

```bash
python3 Skills/ghidra-uefi/scripts/cas_cli.py list
python3 Skills/ghidra-uefi/scripts/cas_cli.py verify
python3 Skills/ghidra-uefi/scripts/cas_cli.py ref add laptop <module-sha>/<recipe>
python3 Skills/ghidra-uefi/scripts/cas_cli.py gc --apply
python3 Skills/ghidra-uefi/scripts/cas_cli.py export --all --out analyses.zip
python3 Skills/ghidra-uefi/scripts/cas_cli.py import analyses.zip
```

`gc` is a dry run unless `--apply`; `--analyses` also drops analyses no
reference names and refuses to do that on a store with no references. The
bundle is how a project carries its analyses; `reference/cas.md` has the layout
and the rules. The first store command builds `byteripper-cas` (about 20 s,
once; it needs Xcode's `swift`). The CAS tests run without Ghidra:

```bash
python3 -m unittest discover -s Skills/ghidra-uefi/tests
```

For CpuPei the artifact is 13 functions and 508 instructions; it finds the
status-code call at `0x535` with `PUSH 0x80000002`, `PUSH 0x11004`, the core id
and the descriptor — the call the manual analysis found. The Code panel in the
app will read the same artifact; this skill proves the data path first.

## What Ghidra will and will not tell you

- **The loaded base is the header's ImageBase.** PEI modules often carry the
  address they are mapped at (`0xFFC50558` in one dump), and then the analysis
  addresses are the addresses the firmware uses. A compressed module usually
  has ImageBase 0; its addresses are then offsets from the image, not physical
  addresses. `--image-base` on `te_to_pe.py` can give it a stand-in base.
- **x86_64 UEFI uses the Microsoft calling convention.** Ghidra's PE loader
  picks the Windows compiler spec, which is what EFIAPI uses on x64.
- **No UEFI symbol database is applied.** Functions arrive as `FUN_<address>`.
  Protocol GUIDs, boot-service names and driver names have to be added by hand
  (`functions_rename`, `structs_create`) or recognized from the module's own
  strings (`data_list_strings`).
- **TE relocation semantics are preserved by the conversion, not invented.**
  Section data keeps the offsets the TE table names; see
  `reference/ghidra.md` for the exact mapping.

## Offline fallback

When ByteRipper is not running, `module_scan.py` can still find images in a dump
and extract the ones it can open:

```bash
python3 Skills/ghidra-uefi/scripts/module_scan.py dump.bin
python3 Skills/ghidra-uefi/scripts/module_scan.py dump.bin \
    --guid 86D70125-BAA3-4296-A62F-602BEBBB9081 --out module.efi --meta module.json
```

It opens LZMA sections with the standard library and reports Tiano sections as
closed, because Tiano is not in the standard library. The app opens both. The
scanner's header parser is also what `byteripper_extract.py` uses for the
metadata, so the two agree on what a PE32 or TE image is.

## Check

A run is deterministic: the same dump, node and Ghidra version give the same
bytes and the same function list. Useful checks:

```bash
# the extraction's SHA-256 and header facts
python3 Skills/ghidra-uefi/scripts/byteripper_extract.py … | jq '.sha256, .image.kind'

# the module imports and analyzes
python3 Skills/ghidra-uefi/scripts/ghidra_import.py … | tail -3
#   functions: 82

# a TE image converted from the tree loads with the expected blocks
jq '.blocks[] | {name, start, end}' /tmp/module.analysis.json
```

Tested against `CSME 15.bin` (32 MiB SPI dump): a PE32 DXE driver in an LZMA
section (15 functions), the 106 KiB DxeCore (PE32+, 241 functions), and a TE
PEIM from a compressed PEI volume (82 functions). The code artifact was checked
on CpuPei: 13 functions, 508 instructions, and one status-code candidate at
`0x535` (`0x80000002`/`0x11004`); every query above was answered from the store
with no Ghidra running. The offline scanner was checked on
`orig_30072026.BIN` (16 MiB, 15 volumes, 74 images).
