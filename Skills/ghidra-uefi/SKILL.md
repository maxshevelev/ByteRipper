---
name: ghidra-uefi
description: Review one PEI or DXE module of a firmware dump in Ghidra — ByteRipper or byteripper-server is the oracle for where the module is and what its bytes are, and this skill reviews it in a kept Ghidra project through the `ghidra_` tools: decompiled C, names, signatures, types, comments, a module description, published into the code store. Use when a person asks what a PEIM or DXE driver does, where a function is called from, or why a module in a dump misbehaves; when a module inside a Tiano or LZMA section has to be disassembled; or when a firmware image has to be read as code rather than as bytes.
---

# A UEFI module in Ghidra

ByteRipper already knows where a module is: its UEFI Structure panel has walked
the volumes, opened the FFS files, decompressed the Tiano and LZMA sections and
named the PE32 and TE images. Ghidra knows what the module means: instructions,
functions, cross-references, a decompiler.

This skill is the narrow path between them. It does **not** parse firmware
volumes on its own — asking ByteRipper is the reference, and a second parser
would disagree with the panel the person is looking at. The bytes travel from
the server's own tree, and the review is made through the `ghidra_` tools.

## The pieces

The Ghidra scripts are compiled and run by the analysis server —
`byteripper-server` or the app's when Settings ▸ Code Analysis names one — and
live in its scripts folder, `owner/` and `scripts/`: `Skills/ghidra-uefi` in
the repository, `ghidra/` in an installed copy. A review does not run them by
hand; they are listed here because their rules and their output are what a
review reads.

| piece | what it does |
|---|---|
| `owner/Owner.java`, `owner/Harvest.java`, `owner/TypeText.java` | the owner: one program held open, the read calls, the writes, the publish |
| `scripts/ApplyUefi.java` | the UEFI pass before an export: EDK2 types on the entry point and down the calls, gBS/gRT/gST, GUID names, protocol and PPI pointers, callbacks, DEBUG names (`reference/uefi-pass.md`) |
| `scripts/BuildUefiTypes.java` | parses MdePkg's headers into `uefi_X64.gdt` / `uefi_Ia32.gdt`, once |
| `scripts/ExportCode.java` | the code artifact an export stores: every instruction, references, C with its token spans, named data, strings, POST writes and status-code candidates |
| `scripts/cas.py` | the client of the code store, which is implemented once in `Packages/CodeAnalysis` |
| `scripts/cas_cli.py` | the store's command line: list, show, verify, gc, ref, export, import, conflicts |
| `reference/uefi-images.md` | the structures and the addresses |
| `reference/ghidra.md` | import rules, the review tools by task, constants and equates, pitfalls |
| `reference/code-artifact.md` | the artifact's schema, queries and limits |
| `reference/cas.md` | the local CAS: the tool, layout, keys, readings, references, GC, bundles |
| `reference/description.md` | the module description a review writes: where it lives, its sections, its Markdown, its links into the code |

## 1. Find the module

The server must be running: the app with **Settings ▸ Agent** switched on, or
`byteripper-server` with the dumps under `--dump-roots`. Its MCP connection is
what the agent talks to.

- `documents` — what is open; with the app, the focused dump is the default;
  with a headless server, name the document.
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

## 2. Get it into Ghidra

A review — reading the decompiler, renaming, typing, commenting — goes through
the `ghidra_` tools. `ghidra_open` takes the image `node` and its `document`;
the server sends the bytes, so there is nothing to extract, and it converts a
TE image itself. A module opened before opens by `module`, its SHA-256.

Each module has a kept Ghidra project, made once by the same analysis and UEFI
pass that fills the code store, and every change is published into the store,
so each ByteRipper reading that store shows it.

Then: `ghidra_functions`, `ghidra_function` (C, the parameters and the locals
with their storage), `ghidra_disassembly`, `ghidra_xrefs`, `ghidra_data`,
`ghidra_strings`, `ghidra_type_definition` (a type as the program, the shared
review archive and EDK2 hold it — what a `type_conflicts` of a publish is read
with); `ghidra_rename`, `ghidra_label` (a branch label — `LAB_<address>` in the
C — named; a function's entry is refused here, that is `ghidra_rename`'s),
`ghidra_function_create` (a function where only a table points — a services
table's or a PPI's slot), `ghidra_rename_variable`, `ghidra_signature`,
`ghidra_type`, `ghidra_set_data`, `ghidra_comment`, `ghidra_code_mode` (a range
read as 16-bit or 32-bit code — the reset vector's real-mode code in a 32-bit
module), `ghidra_equate` (a name for a constant an instruction holds: an I/O
port, an MSR, a PCI config address — as an enum member with a comment saying
what it is and its source, which the app shows when the name is clicked);
`ghidra_function_tag` (library code the module statically links in, tagged
with whose it is — `library.edk2`, `library.amd`, `library.intel` — by the
criteria in "Library functions"; the exported artifact records it at the
`library` review level with that kind: complete as it is, no further review;
an empty tag removes it);
`ghidra_description` and `ghidra_describe` for the module description (the
whole document, or one `## ` section); `ghidra_publish` at a coherent
checkpoint, `ghidra_done` at the end. The rules a review keeps are in "What a
review makes of the code".

Never review in a Ghidra window of your own: what it holds is not in the store,
no other Mac sees it, and Ghidra's project lock keeps the owner off a project a
window has open.

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
   After a signature change, or any change to a variable, list the locals
   again before `rename-var`: Ghidra merges and retypes them, the old storages
   no longer exist, and a type alone gives a local a `HASH:` storage.
   Branch labels are names too. Ghidra prints an unnamed jump target as
   `LAB_<address>`, and that label is a step of the flow — an error exit, a
   loop's head, the place a structure starts being read — so it gets a name
   that says which (`ErrorShortRead`, `NextSection`,
   `CheckMachineAndSections`), never the address. A label is not a function and
   has its own call: `ghidra_label`, which names the symbol at the address and
   takes an empty name to delete one;
   `ghidra_rename` takes any address but names the function around it, so a
   label given to it leaves the label as it was and renames the function —
   read the answer's `entry` back.
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

### Library functions

A library function is code the module links in rather than its own work. It is
tagged instead of reviewed, and the tag says whose library it is. The panel
groups the three kinds under Library functions and marks each function with its
kind: **EDK2**, **AMD**, **Intel**. The kinds are reserved for every review,
whatever vendor's module is open.

| Tag | Kind | What it covers |
| --- | --- | --- |
| `library.edk2` | EDK2 | MdePkg, MdeModulePkg and UefiCpuPkg libraries: BaseMemoryLib, BaseLib (its 64-bit math included), HobLib, PeiServicesLib, PcdLib, IoLib, DebugLib, TimerLib; and the compiler helpers a 32-bit MSVC build links (`__allshl`, `__aullshr`, `_allmul`, `_aulldiv`). |
| `library.amd` | AMD AGESA | AGESA's own libraries: LibAmd I/O and memory access, `AgesaAssertHalt`-style asserts, IDS debug print and IDS hook dispatch, AGESA delay and register-access helpers. |
| `library.intel` | Intel FSP/RC | The FSP's and Reference Code's own libraries: PCH/SA/CPU register access (`PchPcr*`, `MmPciBase`), FSP debug and assert, RC delay and SMBus helpers. |

A function is tagged only when all three of these hold; otherwise it is the
module's own work and is reviewed like any other function.

1. **It is a general service.** Memory, string, GUID, 64-bit math, port or
   MMIO access, a delay, finding a HOB, a PPI or a PCD, an assert, a debug
   print. A function that reads or fills this module's own structures,
   programs its registers or makes a decision of its own is the module's work,
   whoever wrote it: AGESA's fabric MMIO allocation, its PSP directory walk,
   its APOB lookups and a library *constructor* that does such work are AMD
   code and are still reviewed.
2. **Its kind is shown by evidence**, at least one of:
   - **EDK2**: the body is the EDK2 routine's — the same arguments, the same
     checks, the same calls in the same order (the public `CopyMem` returns
     `Destination` at once when `Length` is 0 or the two pointers are equal, and
     otherwise calls `InternalMemCopyMem`). The function takes its EDK2 name,
     and so does the internal routine behind a public one.
   - **AMD**: an AGESA assert code (`file id << 16 | line`) inside a
     general-service body; AGESA's argument conventions (`AccessWidth` 1/2/3
     with the S3 variants 0x81–0x83, `AMD_CONFIG_PARAMS *StdHeader` last); the
     IDS debug-print or hook dispatch; or the same body, byte for byte apart from
     relocated addresses, in another AMD module of the same image (`find_bytes`
     on the dump).
   - **Intel**: a body and name matching Intel's open silicon packages
     (IntelSiliconPkg, the FSP headers, MinPlatformPkg); Intel's conventions
     (PCH private-register access by port ID and offset); or the same body in
     another Intel module of the image — FSP-M, FSP-S or a Pch/Sa/Cpu PEIM.
3. **The evidence is written down**: one line in the function's plate or name
   reason — "EDK2 BaseMemoryLib CopyMem: returns Destination when Length is 0
   or the pointers are equal", "AGESA LibAmdIoWrite: assert 0x10195, S3 widths
   0x81–0x83".

An EDK2 routine inside an AMD or Intel module is EDK2. Evidence short of
point 2 is not enough: such a function is not tagged, and the review reads it.
The bare `library` tag of an earlier review names no kind; the panel shows it
as a library of no recorded kind until the review tags it again.

### On an analysis server

`byteripper-server` (`Design/SERVER_PLAN.md`, `Design/SERVER_HEADLESS_PLAN.md`)
runs the owners from Swift and serves them with the store and the documents, so
one machine keeps every module's project and every Mac reads the result:

```bash
swift build -c release --package-path Packages/ByteRipperServer
.build/release/byteripper-server token add --name admin --rights admin  # once: the console's
.build/release/byteripper-server token add --name <mac> --preset app    # one per Mac, and per client
.build/release/byteripper-server --dump-roots <dir> \
    --listen 127.0.0.1:8765 --listen 100.64.0.7:8765
# loopback for the app on the server itself (a Mac does not reach its own
# tailnet address), the tailnet address for the other Macs.
# Every address needs a token now, loopback included: the secret goes into the
# app's Settings ▸ Code Analysis.
```

The server keeps its own documents — the dumps under `--dump-roots` and what
the console uploads — and serves them to an agent **on that machine** over a
Unix socket; the agent's client reaches it through the relay:

```bash
.build/release/byteripper-server relay      # MCP on stdin/stdout ↔ <Server>/mcp.sock
```

`/admin` on any listen address is the operator's console — documents,
activity, tokens, status — behind an admin token. There is no `/mcp` over the
network: an agent is on the machine, or it goes through the app.

The server holds the module's lease; every `ghidra_` call, the publish
included, goes to it. The store it publishes into is its own: `--store` names
the directory, and `cas_cli.py --store` reads the same one from the terminal.

## The code store

A publish does three things: it exports the program as it stands, stores the
artifact under the module's SHA-256 and the analysis recipe, and stores the
review with it — the revision number, the review Markdown and the module
description. Nothing is analyzed twice: the same PEIM from another dump reuses
the analysis, and a new Ghidra version is a second recipe beside the first,
never an overwrite.

Reading needs no Ghidra: `code_modules` lists the analyzed modules, and
`code_query` answers from a stored artifact — functions, disassembly, C, xrefs,
the uses of an address, search, post-codes. The exporter writes
`script_version: 5` (`reference/code-artifact.md`): a module analyzed by an
older exporter is analyzed again as a new recipe beside the old one.

Before the export, `ApplyUefi.java` types and names the module from EDK2
(`reference/uefi-pass.md`); the first run builds its type archives, about a
minute. A module with a kept project needs no new analysis: a publish exports
the program as it stands, the review with it.

The store is `~/Library/Application Support/ByteRipper/Analysis`, or wherever
`--store` says:

```
objects/<sha256 of the artifact>
analyses/<sha256 of the module>/<recipe>/manifest.json
refs/<name>.json
```

The artifact holds functions, every instruction with its bytes and references,
the decompiled C, strings, the POST codes with the place that sends each —
followed back through `IoWrite8`, a `PostCode()` or a halt routine to the
constant — and candidates for `ReportStatusCode` calls (a call through a PEI
services table entry at `+0x58`, with the pushes before it kept as context).

The store has its own commands for the work the MCP tools do not cover:

```bash
python3 scripts/cas_cli.py list
python3 scripts/cas_cli.py verify
python3 scripts/cas_cli.py ref add laptop <module-sha>/<recipe>
python3 scripts/cas_cli.py gc --apply
python3 scripts/cas_cli.py export --all --out analyses.zip
python3 scripts/cas_cli.py import analyses.zip
```

`gc` is a dry run unless `--apply`; `--analyses` also drops analyses no
reference names and refuses to do that on a store with no references. The
bundle is how a project carries its analyses; `reference/cas.md` has the layout
and the rules. The first store command builds `byteripper-cas` (about 20 s,
once; it needs Xcode's `swift`) unless `BYTERIPPER_CAS` names a built one. The
store's tests run without Ghidra:

```bash
python3 -m unittest discover -s tests
```

For CpuPei the artifact is 13 functions and 508 instructions; it finds the
status-code call at `0x535` with `PUSH 0x80000002`, `PUSH 0x11004`, the core id
and the descriptor — the call the manual analysis found. The Code panel in the
app reads the same artifact.

## What Ghidra will and will not tell you

- **The loaded base is the header's ImageBase.** PEI modules often carry the
  address they are mapped at (`0xFFC50558` in one dump), and then the analysis
  addresses are the addresses the firmware uses. A compressed module usually
  has ImageBase 0; its addresses are then offsets from the image, not physical
  addresses.
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

## Check

A run is deterministic: the same dump, node and Ghidra version give the same
module and the same function list. Useful checks:

- `ghidra_open` answers the module's SHA-256 and its blocks; the same image
  opened twice is the same `module`.
- `ghidra_publish` reports the functions and instructions its export holds; a
  changed review reads as a new revision of the same module, not a new module.
- `cas_cli.py verify` checks every object's hash, every manifest's artifact and
  module, and every reference.
- `ghidra_function` after a publish reads the names and types back as the
  artifact holds them.

Tested against `CSME 15.bin` (32 MiB SPI dump): a PE32 DXE driver in an LZMA
section (15 functions), the 106 KiB DxeCore (PE32+, 241 functions), and a TE
PEIM from a compressed PEI volume (82 functions). The code artifact was checked
on CpuPei: 13 functions, 508 instructions, and one status-code candidate at
`0x535` (`0x80000002`/`0x11004`); every query above was answered from the store
with no Ghidra running.
