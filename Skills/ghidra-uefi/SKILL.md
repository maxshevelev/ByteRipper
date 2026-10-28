---
name: ghidra-uefi
description: Take one PEI or DXE module out of a firmware dump and analyze it in Ghidra — ByteRipper's UEFI Structure panel is the oracle for where the module is and what its bytes are, and this skill carries them across, rebuilds a TE image as a PE so Ghidra's loader accepts it, and reviews it in a kept Ghidra project through the `ghidra_` tools of ByteRipper or of byteripper-server, or runs a headless analysis that writes functions and decompiled C to JSON, and keeps a one-time code artifact that answers function, instruction, xref and status-code questions without Ghidra. Use when a person asks what a PEIM or DXE driver does, where a function is called from, or why a module in a dump misbehaves; when a module inside a Tiano or LZMA section has to be disassembled; or when a firmware image has to be read as code rather than as bytes.
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
| `reference/ghidra.md` | — | import rules, the headless recipe, the owner's Java, pitfalls |
| `reference/code-artifact.md` | — | the artifact's schema, queries and limits |
| `reference/cas.md` | — | the local CAS: the tool, layout, keys, readings, references, GC, bundles |
| `reference/description.md` | — | the module description a review writes: where it lives, its sections, its Markdown, its links into the code |

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

### Interactive: the `ghidra_` tools

A review — reading the decompiler, renaming, typing, commenting — goes through
the `ghidra_` tools. Each module has a kept Ghidra project, made once by the
same analysis and UEFI pass as `code_artifact.py`, and every change is
published into the CAS, so each ByteRipper reading that store shows it.

Reach them through ByteRipper's own MCP server, when Settings ▸ Code Analysis
names an analysis server: the same connection carries the tree tools, so a
module goes from its UEFI node to a rename without leaving it. `ghidra_open`
takes the image `node` and its `document`; the app sends the bytes, so there
is nothing to extract.

A TE image is converted by the server; a module opened before opens by
`module`, its SHA-256. Then: `ghidra_functions`, `ghidra_function` (C, the
parameters and the locals with their storage), `ghidra_disassembly`,
`ghidra_xrefs`, `ghidra_data`, `ghidra_strings`, `ghidra_type_definition` (a
type as the program, the shared review archive and EDK2 hold it — what a
`type_conflicts` of a publish is read with); `ghidra_rename`,
`ghidra_label` (a branch label — `LAB_<address>` in the C — named; a function's
entry is refused here, that is `ghidra_rename`'s), `ghidra_function_create` (a
function where only a table points — a services
table's or a PPI's slot), `ghidra_rename_variable`, `ghidra_signature`,
`ghidra_type`, `ghidra_set_data`,
`ghidra_comment`, `ghidra_code_mode` (a range read as 16-bit or 32-bit code — the
reset vector's real-mode code in a 32-bit module), `ghidra_equate` (a name for a
constant an instruction holds: an I/O port, an MSR, a PCI config address — as
an enum member with a comment saying what it is and its source, which the app
shows when the name is clicked);
`ghidra_description` and `ghidra_describe` for the module
description (the whole document, or one `## ` section); `ghidra_publish` at a
coherent checkpoint, `ghidra_done` at the end. The rules a review keeps are in "What a review makes of the code".

Never review in a Ghidra window of your own: what it holds is not in the CAS,
no other Mac sees it, and Ghidra's project lock keeps the owner off a project
a window has open.

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
`--idle` seconds without a call (1800 by default).

The review is made through the same owner: `rename`, `rename-var` (a local by
`--storage` and `--first-use` as `/v1/function` lists them, a parameter by
`--ordinal`), `comment`, `signature`, `data`, `type`, `equate` (`address name
--value 0xCF8 --enum FCH_IO_PORT --comment …`; `type` also takes `--name`,
`--description` and `--comment FIELD=TEXT`), `code-mode` (`start end
16|32`: the range [start, end) decoded again as 16-bit or 32-bit x86) and
`describe` (the module description, whole or `--section`; `@file` reads it
from a file). The first write takes
the module's write lease; `publish` stores the artifact with a `reading` —
this project's revision — and the review document; `release` publishes and
gives the lease back. A name Ghidra would make unique (`Foo_1`) is refused,
and so is a local named by a storage several locals share. A function no calling convention fits — a linker's clone that takes its
argument in EDX, or returns through a pointer in ECX — gets `storage`, one place
per parameter as `/v1/function` lists them (`["ECX:4", "Stack[0x4]:4"]`), and
`return_storage` (`EDX:4,EAX:4`, `void`), instead of dummy parameters for
registers it does not read. A signature or a
type may be written the EDK2 way (`VOID`, `IN`, `EFI_FIRMWARE_VOLUME_HEADER`):
the owner takes what the program lacks from the EDK2 archive. A type added
with `type` is shared at publish through `GhidraProjects/review-types-*.gdt`,
so a module opened afterwards can use it; one that another review defines
differently is reported and stays in its program.

### What a review makes of the code

The aim of a review is decompiled C that reads like the module's source: a
person who has never seen the module follows a function from its C alone, and
a constant, a pointer walk or a branch says what it means where it stands.
Names alone do not get there. Every review applies these rules:

1. **Names, not constants.** A value that belongs to a set becomes an enum
   member, and the parameter, field or return type that carries it gets the
   enum type, so the decompiler prints the name: `EFI_STATUS` results as
   `EFI_SUCCESS`, `EFI_NOT_FOUND`; `DEBUG` levels; POST and halt codes; group
   and type ids of a vendor table. A constant an instruction holds — an I/O
   port, an MSR number, a PCI config address — gets its name with
   `ghidra_equate`, as a member of an enum that groups it with a comment
   saying what it is and where that is known from, and each port write an
   end-of-line comment: the register,
   the bits, and where the names come from (`reference/ghidra.md`, "I/O ports
   and other constants"). A signature or a magic size used once gets a named
   global or an end-of-line comment that names it. A GUID gets its name from the GUID table or a label. Write the tag of
   a `typedef enum`/`struct` (`typedef enum _APOB_HALT_CODE { … }
   APOB_HALT_CODE;`); the owner adds one that is missing, because Ghidra names
   an untagged type by its place in the text and two of them collide.
2. **Structures, not pointer arithmetic.** When the code reads `*(int *)(p +
   0x10)` or walks a buffer by hand, define the structure it walks — the header,
   the entry, the record — and type the pointer with it, so the C says
   `Entry->Size` and `Entries[Index]`. Put the layout in the type from what the
   instructions prove (which offsets are read, at what width), not from a
   guess; a field nobody can name is `Unknown08`, never a plausible invention.
   Fix the signatures first — a typed parameter retypes every local that
   follows from it, in this function and in its callers. Local buffers are
   typed the same way: a stack copy of a header that arrives as
   `undefined1[184]` becomes the structure it is, so `local_10c._24_4_` reads
   as `PeHeader.Pe32.OptionalHeader.Magic`. A union prints whichever member has
   a field at that offset; where the members share offsets —
   `EFI_IMAGE_OPTIONAL_HEADER_UNION`'s PE32, PE32+ and TE headers do — the
   plate carries the offset table and names the places where the printed member
   belongs to a sibling, rather than leaving the reader to trust a wrong name.

   **A structure the archive already holds is that structure.** Before
   defining one, look it up: `ghidra_type_definition` answers what the
   program, the shared review archive and EDK2 hold — `EFI_PEI_SERVICES`,
   `EFI_HOB_HANDOFF_INFO_TABLE`, `EFI_PEI_FIRMWARE_VOLUME_PPI`,
   `IA32_DESCRIPTOR`, the PE and TE headers — with every field's offset, and
   says whether the three agree. Type the variables with it, the decompiler's
   synthetic pieces included: the 6-byte IDTR a `SIDT` writes comes out as a
   2-byte local and a 4-byte one, and giving the 2-byte one `IA32_DESCRIPTOR`
   resizes its storage to six bytes and turns `IdtrBase` into `Idtr.Base`;
   a record that arrives as `void *` from a lookup becomes its structure, and
   `*(int *)(FvRecord + 4)` becomes `FvRecord->VolumePpi`. A field that is a
   function pointer pays twice: the call reads `VolumePpi->FindSectionByType2`,
   and a wrong offset would print a wrong field name — which is the check.
   A record no one publishes (`PEI_CORE_FV_RECORD`, the core's 0x20-byte
   volume entry) is defined from the instructions with `Unknown<offset>` where
   the code never reads, and a description saying what is known and what is
   not. Where the module keeps the table itself — `EFI_PEI_SERVICES` at
   0x9A06410 in PeiCore, `PEI_SERV` then the pointers — an offset is confirmed
   against the bytes there, not only against the archive.
3. **Names for everything that stays.** Functions, parameters and locals get
   names that say their role, in the module's own convention (EDK2:
   `CamelCase`, `Ptr` only where a pointer and its target both appear). A
   function is named for what it does for its caller, not for its first call.
   After a signature change, list the locals again before `rename-var`: Ghidra
   merges and retypes them, and the old storages no longer exist.
   Branch labels are names too. Ghidra prints an unnamed jump target as
   `LAB_<address>`, and that label is a step of the flow — an error exit, a
   loop's head, the place a structure starts being read — so it gets a name
   that says which (`ErrorShortRead`, `NextSection`,
   `CheckMachineAndSections`), never the address. A label is not a function and
   has its own call: `ghidra_label` (`/v1/rename/label`), which names the
   symbol at the address; `ghidra_rename` takes any address but names the
   function around it, so a label given to it leaves the label as it was and
   renames the function — read the answer's `entry` back.
4. **Comments that a source would have — in the body, not only above it.**
   All three are required, and a plate alone does not count:
   - a plate comment on the function: what it does, why it exists in this
     module, what it expects, what it returns or halts with, and the numbers a
     caller acts on — status values, `ImageError` codes, `BootMode` values —
     spelled out where the code carries them by number;
   - a `pre` comment at the first instruction of every step of the flow: each
     read, each structure the code walks, the loop, the branch that changes the
     meaning of what follows, and every error exit. The C then reads as a
     walkthrough: a person follows it top to bottom without going back to the
     plate to learn what the next twenty lines are for;
   - an `eol` comment where one line needs a remark: the hardware or firmware
     meaning of a value, a convention (the PEI Services pointer below the IDT),
     a field the decompiler could not name, an error path that does not return.
   Never paraphrase the line (`// add 1 to Index`). Say what is uncertain
   (`probably`, `not confirmed`). Read the existing comment before writing one:
   a `comment` replaces it. A label Ghidra shows (`LAB_09a05373`) is an
   instruction address, so branch targets already have somewhere to hang a step
   comment; the rest need one `ghidra_disassembly` page to find where each step
   begins.
5. **Read it again.** After a publish, read the function and its callers once
   more: a name or a type that reads wrong in a caller is not done. What still
   reads as a constant, a cast or `local_` is the next round.
6. **Findings are reported, not hidden.** A defect the review finds — an
   unbounded buffer, a wrong format, an unused parameter — goes in a comment
   at its place and in the report to the person. It never shapes a name: the
   function is named for what it was meant to do, and the comment says what it
   actually does.
7. **The module is described, not only its functions.** The review writes the
   module description — what the module is for, how it works, how it is built
   — in the structure `reference/description.md` sets: a summary, then
   `Identity`, `Purpose`, `Interfaces`, `Flow`, `Internal structure`,
   `Hardware and data`, `Errors and diagnostics`, `Findings`,
   `Open questions`, `Review status`. Start it on the first pass, change it a
   section at a time with `ghidra_describe` as the review learns, and keep it
   true at every publish: a rename or a refuted guess is corrected there
   before publishing. It is published with the review as an object of its own,
   and the app shows it under **Description** beside ASM and C; a function
   linked as `[Name](0xADDRESS)` or written as `` `Name` `` opens there.
   A review is not finished while its description says nothing of what the
   review found.

### What a finished function looks like

The bar is the same for every function of a reviewed module, whether or not it
was the reason for the review. A function is done when all of this is true:

- The signature reads in EDK2 terms, every parameter sits where the ABI really
  puts it (`storage`/`return_storage` when no convention fits), and every
  parameter is typed with the structure it receives — the archive's type when
  EDK2 has one, a type this review defines when only the code shows the layout.
- Local buffers are typed, not `undefined1[N]`: the DOS header, the section
  header, the image context's stack copy and the debug entry read as fields.
- No `param_`, `uVar`, `iVar`, `local_`, `undefined` or `FUN_` is left in the
  function. A value whose role the code does not establish gets an honest name
  (`HeaderField`, `TeOffset`, `HobOrStatus`) and the plate says what it stands
  for — never a plausible invention.
- The plate and the `pre`/`eol` comments of rule 4 are there, with the error
  and status numbers spelled out.
- Where the decompiler merged two meanings into one name, or printed a field
  through the wrong member of a union, the plate says so in one line each and
  names the places — a reader who meets `Count` holding a size will look.
- The function is named for what it does for its caller, the functions it calls
  are named too, and the module description's `Review status` lists it as read.
- It is in a published revision.

Reading one function of a reviewed module should look like this (`PeiCore`,
`PeCoffLoaderGetPeHeader`):

```c
/* Reads and validates the DOS and PE headers of an image ... (plate: the steps,
   the ImageError values, the offsets in the header buffer, what the union
   prints through a sibling member) */

EFI_STATUS PeCoffLoaderGetPeHeader (PE_COFF_LOADER_IMAGE_CONTEXT *ImageContext,
                                    EFI_IMAGE_OPTIONAL_HEADER_UNION *PeHeader)
{
  EFI_IMAGE_DOS_HEADER DosHeader;
  ...
  /* Step 1: the DOS header. ReadSize is in/out — a shorter answer means the
     file ends before the header does. */
  Status = (*ImageContext->ImageRead) (ImageContext->Handle, 0, &ReadSize, &DosHeader);

  /* MZ? then e_lfanew is where the PE or TE header begins; without MZ the same
     read starts at offset 0. */
  ...
  /* TE (VZ): machine at +2, subsystem at +5, stripped size at +6. SizeOfHeaders
     = BaseOfCode - StrippedSize + 0x28, because the stripped header sits at the
     front of the loaded image. */
  ...
  /* Step 3: machine. Only i386, x86-64, EBC and ARM64 are accepted, and a
     refusal here leaves ImageError untouched. Then every section header is
     read ... */
```

A review that stops at names, or at a plate with an unmarked body, is an
intermediate state and is reported as one.

### On an analysis server

`byteripper-server` (`Design/SERVER_PLAN.md`) runs the same owners from Swift
and serves them with the store, so one machine keeps every module's project
and every Mac reads the result:

```bash
swift build -c release --package-path Packages/ByteRipperServer
.build/release/byteripper-server token                       # once
.build/release/byteripper-server --listen 127.0.0.1:8765 --listen 100.64.0.7:8765
# loopback for the app on the server itself (a Mac does not reach its own
# tailnet address), the tailnet address for the other Macs
```

An agent reaches the review tools through ByteRipper's own MCP server when
Settings ▸ Code Analysis names the server: `ghidra_open` with a node,
`ghidra_function`, `ghidra_rename`, `ghidra_rename_variable`,
`ghidra_signature`, `ghidra_type`, `ghidra_comment`, `ghidra_publish`,
`ghidra_done`. The server holds the lease; the scripts here write to it with
`--store http://host:8765`. A project made by the server and one made by
`ghidra_owner.py` are the same files; do not run both on one project at once —
Ghidra's project lock refuses the second.

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
python3 Skills/ghidra-uefi/scripts/code_query.py BdsDxe.efi post-codes
python3 Skills/ghidra-uefi/scripts/code_query.py BdsDxe.efi post-codes 0x23B
```

The exporter writes `script_version: 5` (`reference/code-artifact.md`): a
module analyzed by an older exporter is analyzed again as a new recipe beside
the old one. A module with a kept project needs no new analysis: a publish
exports the program as it stands, the review with it, under the new recipe. Before the export, `ApplyUefi.java` types and names the module
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
references, the decompiled C, strings, the POST codes with the place that
sends each — followed back through `IoWrite8`, a `PostCode()` or a halt
routine to the constant — and candidates for
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
- **The UEFI pass names what EDK2 can name, and no more.** Services tables,
  GUIDs from the table, protocol and PPI pointers and DEBUG strings are named
  (`reference/uefi-pass.md`); a vendor's own functions and structures arrive
  as `FUN_<address>` and raw offsets until a review names them
  (`ghidra_rename`, `ghidra_type`) or the module's own strings
  (`ghidra_strings`) say what they are.
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
