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

A name here is the firmware's, as the panel shows it, not a review's: a file with
no name of its own reads by its kind — the SEC core's as `Volume Top File` — and
is found by its GUID. The name a review gave a module is in `ghidra_modules`.

Do not guess offsets. The node id is the address of the thing in the tree, and
`uefi_node_data` reads it even when it has no file address at all.

A match from `find_bytes` in a node carries two offsets. `body_offset` counts
from the body, which is what `uefi_node_data` reads by default; `node_offset`
counts from the node's first byte, its part `all`. A `node_offset` given to a
read of the body returns other bytes and no error.

Example, from a 32 MiB SPI dump with a BIOS region:

```
uefi_find(document: d1, name: "PE32 image", type: "Section", limit: 10)
  -> 0.5.4.2.0.1.0.2.2  "PE32 image in AmiUpdateDxePolicyCallback"
     path: … FFSv2 > AmiUpdateDxePolicyCallback > PE32 image
     compressed: LZMA, in_compressed: true
```

### Rules learned in review: finding the module

- **F1.** Make every "only here" or "no other module holds it" claim from a `find_bytes` with `node: "root"` (or `"0"`), never from a search without a node.
  Why: a search without a node reads only the raw image and cannot see compressed modules, so zero matches proves nothing.
- **F2.** Read the PEI APRIORI order from the APRIORI file's Raw section with `uefi_node_data` (`part: "body"`), as 16-byte GUIDs in dispatch order.
  Why: the file usually sits in a compressed section that `read` and `find_bytes` on the document cannot reach. The order is a fact of the image, so a description states it only as a condition.
- **F3.** Take a GUID string from a tool answer (`ghidra_set_data` with type `EFI_GUID`, whose refusal prints the GUID, or `find_bytes`, or `uefi_node`), never decode it from hex by hand, and run `ghidra_guid_add` with `dry_run` first.
  Why: Data4 is a byte array and is never byte-swapped. A hand-decoded GUID got into the shared registry, and only an administrator can remove a registry entry.
- **F4.** Copy a module's full SHA-256 from a tool answer (`ghidra_modules`, `code_query`'s `sha256`), never rebuild it from a shortened form.
  Why: ticket tools accept an unknown SHA and create a stray ticket. An answer with no `name` and no `reviewer` means the SHA was wrong.
- **F5.** Search a body against a sibling module with `find_bytes {node: "root", hex}` or with `code_query {module, what: "instructions", function}` on the sibling's stored analysis.
  Why: a compressed module cannot be found by a document-wide search. Reading the store needs no lease, so a sibling held by another reviewer can still be compared.

## 2. Get it into Ghidra

A review — reading the decompiler, renaming, typing, commenting — goes through
the `ghidra_` tools. `ghidra_create` takes the image `node` and its `document`;
the server sends the bytes, so there is nothing to extract, and it converts a
TE image itself. A module opened before opens by `module`, its SHA-256.

Each module has a kept Ghidra project, made once by the same analysis and UEFI
pass that fills the code store, and every change is published into the store,
so each ByteRipper reading that store shows it.

Then: `ghidra_functions`, `ghidra_gaps` (the spans between bodies the analysis
never made functions of, with what refers into them), `ghidra_function` (C, the
parameters and the locals with their storage), `ghidra_disassembly`,
`ghidra_xrefs`, `ghidra_data`,
`ghidra_strings`, `ghidra_type_definition` (a type as the program, the shared
review archive and EDK2 hold it — what a `type_conflicts` of a publish is read
with), `ghidra_type_uses` (where every module's published analysis names a type); `ghidra_rename`, `ghidra_label` (a branch label — `LAB_<address>` in the
C — named; a function's entry is refused here, that is `ghidra_rename`'s),
`ghidra_function_create` (a function where only a table points — a services
table's or a PPI's slot; an address inside another function's body is refused,
see `ghidra_function_merge` and `ghidra_function_delete`; a jump from another function's end
to the new entry is marked a tail call), `ghidra_flow_override` (a jump read as a tail call, or
given its own flow back — for a function whose C holds the body of the function it jumps to),
`ghidra_function_locals_reset`
(the function's locals let go and the C decompiled again — the candidate for a function the
decompiler refuses, not a guarantee), `ghidra_rename_variable`
(a local by its storage and first use, a parameter by its ordinal; a storage the
decompiler shows as two variables is named once with `shared`), `ghidra_signature`,
`ghidra_type`, `ghidra_set_data`, `ghidra_comment`, `ghidra_code_mode` (a range
read as 16-bit or 32-bit code — the reset vector's real-mode code in a 32-bit
module, an AP's startup in an X64 one — or as 64-bit again in an X64 module), `ghidra_equate` (a name for a constant an instruction holds: an I/O
port, an MSR, a PCI config address — as an enum member with a comment saying
what it is and its source, which the app shows when the name is clicked);
`ghidra_library_candidate` (a reviewed function the module statically links in,
proposed for the library registry with whose library it is — `edk2`, `amd`, `intel` —
by the criteria in "Library functions"; `ghidra_publish` decides, and the module then
stores a link and no text of it);
`ghidra_description` and `ghidra_describe` for the module description (the
whole document, or one `## ` section) and its origin category (`origin`:
`edk2`, `edk2_modified`, `amd`, `intel`, `vendor`, `unknown` — the evidence and
its order are in `reference/description.md`, "The origin category");
`ghidra_interfaces` and `ghidra_set_interfaces` for the module's interfaces
record — what it installs, locates and is notified of, each with its GUID,
address and condition (`reference/description.md`, "The interfaces record");
`ghidra_publish` at a coherent
checkpoint, `ghidra_done` at the end. The rules a review keeps are in "What a
review makes of the code".

A review takes the module into work first: `ghidra_take`, before the first
write. From then on only its holder writes and publishes the module — through
any number of `ghidra_publish`, which keep it in work — until `ghidra_done`
gives it back (publishing what is left, or with `discard: true` dropping it).
There is no term; reading needs no lease. A module another holder has in work
refuses a write with the holder and since when. An administrator can close a
lease from the server's console: the holder's unpublished changes are dropped,
the project is the last published revision again, and the holder's next call
on the module says so — take it again to go on.

Never review in a Ghidra window of your own: what it holds is not in the store,
no other Mac sees it, and Ghidra's project lock keeps the owner off a project a
window has open.

#### Rules learned in review: lease, publish, done

- **G1.** Publish before a pause, a server update or the end of a session, and treat writes since the last publish as possibly lost.
  Why: unpublished renames have vanished after an owner restart or idle stop. `unpublished_writes` can read `false` after an owner reopens, so check it only right after a publish on the same owner.
- **G2.** Prefer a plain `ghidra_publish` or `ghidra_done` over `ghidra_done {discard: true}`. After a discard, check that names, types and links came back (row counts, a C sample) before writing again.
  Why: a discard can move the kept project to the Trash. The next open rebuilds it from the store, so only published work survives.
- **G3.** Do not expect a `ghidra_done` with no writes to make a revision or refresh the stored C. When a module's stored recipe differs from its siblings', say so rather than reading its stored C as current.
  Why: a publish with nothing written is skipped by design, so the store keeps the older exporter's C.
- **G4.** Read and write a module only through the MCP tools. Never open store objects or project files on disk, and never delete them to force a rebuild.
  Why: a kept project is review data and a delete cannot be undone. A read from disk bypasses the store's own checks. If the tools are missing, ask for a reconnect.

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
   global or an end-of-line comment that names it. A GUID gets its name from the GUID registry
   (`guid_registry`): one name for every review, in EDK2's form
   `gEfiPeiMemoryDiscoveredPpiGuid`, for the label on its bytes, the interface
   record and the comments alike. A GUID the registry does not hold is added
   with `ghidra_guid_add` at the place the code shows what it is — the install
   with its descriptor, the call that uses it; a role known with no name is a
   placeholder, `gUnknownPpi9C98130AGuid`. A name the registry refuses is the
   registry's to keep: a review that believes it wrong tells the person. Write the tag of
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
   synthetic pieces included. The server's Ghidra has a patched x86 language
   (`README.md` in the patch's folder, `ghidra/language-patch/` in an install; `language_patch` in `ghidra_create`'s answer), in
   which a `SIDT` prints as two reads:
   `Idtr.Limit = InterruptDescriptorTableLimit();`,
   `iVar1 = InterruptDescriptorTableBase();`. Name the temporary for what it holds
   (`IdtBase`), type the stack local with `IA32_DESCRIPTOR`, and say in an
   end-of-line comment what is kept below the base (in PEI, the PEI Services
   pointer at base − 4). A local typed as an array of words keeps printing pieces
   (`Idtr[0]._2_2_`): retype it.
   Until a module's next publish, its live C differs from its stored C on every
   function with such an instruction: `ghidra_function` prints the two reads,
   `code_query` the stock form. That is expected, not drift.
   Likewise
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
   - a plate comment on the function. Its first paragraph, up to the first
     blank line, says briefly what the function is for, so that a reader grasps
     its meaning without the details: what it does for its caller, not what it
     operates on or how ("Finds the boot option to start", not "Walks the
     option list"). The panel shows that paragraph alone in the popover over a
     call. After it: what it does, why it exists in this
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
   Read a rename back at once, without waiting for the publish: list the
   function again after `ghidra_rename` or `ghidra_rename_variable` and look
   for the name in its C. Reviews have reported names and types answered `ok`
   that did not hold. Those reports could not be reproduced and are not
   explained, so `ok` alone does not show the name took. If the name is
   missing, report the call and its answer rather than writing it again.
6. **Findings are reported, not hidden.** A defect the review finds — an
   unbounded buffer, a wrong format, an unused parameter — goes in a comment
   at its place and in the report to the person. It never shapes a name: the
   function is named for what it was meant to do, and the comment says what it
   actually does. A defect of a *tool* — a call that answered wrong, refused
   what it should take, or failed — goes to `ghidra_report_issue` with the
   call, its arguments, what came back and what was expected; the analysis
   server keeps it, and its console lists it for whoever fixes the tools.
7. **The module is described, not only its functions.** The review writes the
   module description — an article, in plain language with every abbreviation
   expanded in parentheses at its first mention, and only this module's narrow
   terms explained in full in `Terms`,
   that tells a service technician who does not program what the
   module is for, how it works, what it works with and how it is built — in the
   structure `reference/description.md` sets: a summary, then `What it is`,
   `What it does`, `Execution flow` (the main chains as short ordered walks, linking the main functions responsible, and
   the events it registers for), `Interactions`, `Inside the module`,
   `Failures`, `Known problems`, `Terms`. It is not
   the review's record: review state is in the app and the store. Start it on the first pass, change it a
   section at a time with `ghidra_describe` as the review learns, and keep it
   true at every publish: a rename or a refuted guess is corrected there
   before publishing. It is published with the review as an object of its own,
   and the app shows it under **Description** beside ASM and C; a function
   linked as `[Name](0xADDRESS)` or written as `` `Name` `` opens there.
   A review is not finished while its description says nothing of what the
   review found.
8. **Its interfaces are recorded, not only described.** Every
   `InstallPpi`, `LocatePpi`, `NotifyPpi` and their protocol counterparts goes
   into the interfaces record with `ghidra_set_interfaces`: the GUID, its name
   as the GUID registry gives it (another name is refused; a GUID the registry
   does not hold is added first with `ghidra_guid_add`), the address where the module supplies it, the condition, and its purpose —
   why the module needs it and what it gives. Each of the
   three lists is answered — an empty list when the module does none of it —
   and the review is not complete while one is unanswered. Find them all: the
   services table's slots, the wrappers the module calls, the descriptor lists
   one call installs, a list handed over at entry. The `Interactions` section
   says in prose what the record lists.

#### Rules learned in review: the rules above in practice

**Rule 1, names, not constants.**

- **N1.** Before naming a GUID in a description, a depex line or a plate, look it up in the GUID registry or grep the EDK2 tag's `.dec` files with leading zeros stripped from each field (`1f34d25`, not `01f34d25`).
  Why: names recalled from memory were wrong (the PCD PPI was called "memory discovered"), and a grep for the padded form wrongly called an EDK2 GUID vendor-added.
- **N2.** When a depex GUID is not in the module's own INF, write "added by a linked library" (for example PcdLib adds the PCD PPI), and name the library only when it is established.
  Why: a GUID missing from the INF is usually a library's, not a vendor addition.
- **N3.** Expect no equate where no operand holds the value: a constant built by `XOR`/`INC`, an address-typed operand (refused with `applied: 0`, `skipped: 0` and no reason), or a char-typed call argument (the C still prints `'a'`). Say the meaning in the plate or a `pre` comment.
  Why: these are limits of the decompiler and the tool. An empty answer here is not a tool failure.
- **N4.** Give enum names only to the values the module itself gives a meaning to, or that a cited source names. Never invent member names for a bare range check.
  Why: eight `CMP AL,n` instructions prove a range, not names, and an invented name is worse than the number.
- **N5.** For a value the decompiler folds into one expression, name the displacement with an equate and put the member's name in a `pre` comment at the start of the block, rather than promising a local.
  Why: a value used once has no local to rename or retype. An `eol` comment on the call does not print.
- **N6.** Where a BOOLEAN-typed expression prints `& TRUE`, read it as the bit mask 1: retype the expression, or comment it at its place.
  Why: with BOOLEAN as an enum, the decompiler's enum path prints mask 1 as `TRUE` and ignores equates.
- **N7.** Decode a 4-character CPM or AGESA table tag pushed as a dword byte by byte, low byte first, before naming it in a plate, comment, type or interfaces purpose: 0x30334124 is the bytes 24 41 33 30, "$A30", not "$A03".
  Why: three modules had their tags reversed.
- **N8.** Name a constant (an equate, a plate) from what this module's own call shows, including a callee in a sibling module read at its instructions: a helper that writes to Port+4 makes 0x60/0x64 the KBC pair. A sibling's plate text alone is not evidence.
  Why: the callee's instructions are a fact; another review's words are a claim (K8).

**Rule 2, structures, not pointer arithmetic.**

- **S1.** In an IA32 PEIM, type the local that holds `InterruptDescriptorTableBase()` as `EFI_PEI_SERVICES ***` first, then read the C back.
  Why: one retype turns every `(**(code **)(*(int *)(IdtBase - 4) + 0x34))` into `(*(*IdtBase[-1])->CreateHob)(…)`. Also check the entry point, where the base can print as the field `Idtr.Base`.
- **S2.** Write `#pragma pack(1)` before and `#pragma pack()` after any record whose fields are not naturally aligned, and check the answer's `size` and offsets.
  Why: without it a `UINT8` before a `UINT32` pads, and every later offset shifts (a 0x68-byte record became 0x6C).
- **S3.** Before `ghidra_type` with a new name, call `ghidra_type_definition` on that name. If the shared archive holds a different type under it, choose another name.
  Why: a clash on a shared name is refused at the dry run. `ghidra_types` lists only what the program holds, so its silence proves nothing. A name held twice (a program copy and an archive copy) makes every type write fail as "Unrecognized data type". Delete the duplicate; do not add a third.
- **S4.** Declare a structure's function-pointer members inline (`EFI_STATUS (*GetSocInfo)(…);`), never through named function-pointer typedefs.
  Why: a named pointer typedef never round-trips through the exporter and leaves conflicts that do not converge.
- **S5.** Type a function-pointer local through a function typedef (`typedef VOID NAME(args);`, local typed `NAME *`), and send each function typedef in its own `ghidra_type` call, apart from any struct.
  Why: an inline `void (*)(…)` type is refused, a pointer typedef comes out self-referential, and a function typedef sent with its struct makes a root wrapper that prints `(code *)` and spoils proposals.
- **S6.** Define one struct per `ghidra_type` call, and never redeclare a shared member's typedef.
  Why: two structs in one text can rewrite an existing program `_func_N`. A redeclared shared typedef becomes a type conflict.
- **S7.** Map a PPI or protocol table from its descriptor: type the descriptors (`EFI_PEI_PPI_DESCRIPTOR[n]`), take the table base from the `Ppi` field, count the slots by the type the module builds, check that the next datum starts where the table ends, and match each slot to its body.
  Why: tables and descriptors sit back to back in `.data`. A table read from the wrong base (an 18-slot header over a 31-slot table) made invented contradictions in plates and the description.
- **S8.** Before writing what a PPI call means, match the GUID loaded at the locate to its header and the call's offset to that structure's member.
  Why: a "board check" taken from the module's file name stood through five revisions while the code called `gEfiGetPcdInfoPpiGuid`'s `GetSku`. A file name is not evidence of what a body does.
- **S9.** Read a PCD's start value from PcdPeim's Raw section (header, ExMap, LocalTokenNumberTable) with `uefi_node_data`. An offset at or past the header's `Length` is in the uninitialised area, which starts at 0.
  Why: a branch that "cannot run" because of a PCD must rest on the value in the bytes.
- **S10.** Find code Ghidra left outside any function through `ghidra_xrefs {to}` call sites that have no `function` field, and create the function at the prologue.
  Why: the function list and the "unfinished" filter cover only functions Ghidra created. `ghidra_gaps` finds most of these, and a call site with no owner is the quick sign.
- **S11.** Merge a stack frame split into many byte locals by typing the first slot as the whole buffer (`UINT8[N]`, or the record type), then state offsets from it.
  Why: 35 `local_NN` bytes hid a wrong plate. One typed slot made the offsets checkable.

**Rule 3, names for everything that stays.**

- **V1.** After each `ghidra_rename_variable`, compare the storage and `first_use` in the answer with the ones sent, treat `stale: true` or an unexpected `parameter: true` as a miss, and read the locals and their types back.
  Why: `ok` has landed on another local, renamed parameter 0, and kept `ulonglong` over a requested `UINT64`. The skill's rule 5 says such reports were never explained; these are the observed cases.
- **V2.** Try a rename with `storage` and `first_use` before writing that the tool refuses a local, including `HASH:00000000` locals, and quote the answer.
  Why: the tool's text says such storage is refused, yet the write was accepted. Plates claimed "the tool refused a name" without a call.
- **V3.** Name a chain of zero-hash temporaries (each built from the one before) in descending `first_use` order, last link first, and re-read the locals after each write.
  Why: in ascending order 13 of 14 names were refused with "landed on another variable". In descending order all of them took.
- **V4.** After typing a HASH local, read `temporaries` and the locals again.
  Why: one listed local can stand for two occurrences, and typing the first can reveal the second. Naming a fragment can bring up new default names on other registers. Repeat until none are left.
- **V5.** When two locals share both storage and `first_use`, retry once, then name every other local and say in the plate what the two mean.
  Why: Ghidra keeps one variable per storage, so the API cannot tell them apart. Further retries only renumber the temporaries.
- **V6.** Name either a 64-bit register pair (`EDX:4,EAX:4`) or its 32-bit half at the same `first_use`, not both: name the one the code uses and describe the pair in the plate.
  Why: the two share one variable. A rename that would drop the other's name is refused with 409 and names it; before v0.10-832 it answered `ok` and dropped it silently, and the row still read `full`.
- **V7.** When a refusal says a name is "already held by" a storage that the locals list does not show, rename that storage to a marker name first, then use the wanted name.
  Why: a stale symbol invisible in the C can hold a name across sessions.
- **V8.** When `ghidra_signature` answers "Parameter name conflict, likely due to concurrent operation", rename the local that holds that name, then sign again.
  Why: the message names no concurrency. A local already held the name.
- **V9.** For a 64-bit argument on a 32-bit stack, pass `storage` for every parameter and `return_storage`, and compare each storage with the instructions. Type a 64-bit stack local by its 4-byte storage (`Stack[-0x18]:4`, type `UINT64`).
  Why: a `UINT64` parameter was aligned to 8 and moved the next one a slot, with an `ok` answer. The same local with `:8` answers 404.
- **V10.** After signing a tail-jump stub, read the jump target's signature and a few callers' locals before publishing.
  Why: signing a stub rewrote its target's signature and its sibling stubs, and the answer named only the stub.
- **V11.** When a `locals` gap remains with every local named, give each local still typed `undefined…` a real type before calling it a tool problem.
  Why: the gap counts untyped locals, not unnamed ones. `void **` is an honest type for a pointer whose target is not established.
- **V12.** Accept unnamed locals on a thunk (a JMP stub; `ghidra_function` shows `thunk_of`), name them in the target, and explain them in the stub's plate. Never run a locals reset on a thunk.
  Why: a thunk shares its target's locals, and the store keeps no C for it (`no_body`).
- **V13.** Before a `ghidra_function_locals_reset` on a function whose C is null, read its names from an older recipe's stored C (`code_query {what: "c", recipe}`). Then restore them in this order: stack slots, then registers by `first_use`, then HASH, re-reading between batches.
  Why: the reset wipes every name. An older recipe can still hold the C with every name. A 409 inside a batch can pass when sent alone.

**Rule 4, comments.**

- **C1.** In a plate or comment, refer to an unnamed temporary by its storage and first-use address ("the EAX value first set at 0x…"), never by a default name such as `uVar4`.
  Why: Ghidra renumbers default names after any rename in the function, so the comment goes wrong at once.
- **C2.** Give every claim in a plate an instruction address or a source-tree line, or mark it "inference".
  Why: claims without an anchor were where the real errors were. A marked inference tells the next reader what to check.
- **C3.** State in plates and comments only facts from the module's own bytes, as the description does, and write anything about the rest of the image as a condition. After a publish, a search of the stored C for "this board" should find nothing.
  Why: plates are keyed by the module's hash, like the description, and show in every firmware with the same bytes.
- **C4.** Before `ghidra_comment`, list the function's `comments` at that address.
  Why: a comment replaces the one of the same kind at that address. A caller's comment was overwritten this way. (Rule 4 says this; the point is to list them first.)

**Rules 5 and 6, read it again and findings.**

- **K1.** Before writing a finding, open every helper it depends on, read the exact bytes at the cited address, decode attribute and bit values against the header, and trace each register back to its load.
  Why: a re-read withdrew about eight accepted claims: a GUID one table entry off, a helper never opened, a leftover RCX taken for an argument, and a global never read.
- **K2.** Read a global's initial value from the image bytes before writing what code that tests it does.
  Why: a guard byte assumed to be 0 is 1 in the image, and the plate said the opposite of the code.
- **K3.** Check that a name matches what its instruction does (sizes, flag polarity, pointer or index) when reading C back.
  Why: `full` rows held two swapped size names, a `NameEmpty` that meant not-empty, and an index typed as a pointer.
- **K4.** Never use a callee list to show that a callback does not run: read the registration (`CreateEvent`, `RegisterProtocolNotify`, `NotifyPpi`) and the signal at the instructions.
  Why: static callee lists show direct calls only. A "dead" notify callback ran for consoles already present.
- **K5.** Decode an attribute word, a mask or a format's output from its value and the source, never from the words a plate uses for it.
  Why: "Attributes 6 (NV | BS)" was accepted twice. 6 is BS | RT, and NV is exactly the bit that is not set.
- **K6.** Before writing that a module consumes a protocol it does not implement, search for its install in this module and read any table of the module's own function pointers.
  Why: a module can install a protocol and then locate it for itself. A "service table" typed from four slots was a slice of the module's own table.
- **K7.** Before calling a block "dead" or "never reached", look for data that holds its address as well as code references.
  Why: a record in data named the entry of a block called dead.
- **K8.** Treat a plate from an earlier review as a claim, not evidence: read the body at the instructions before repeating it in another module or relying on it.
  Why: an early bulk plate had a boot-mode test inverted and a HOB type wrong. The module's name made it sound right.
- **K9.** Name a status from its numeric value decoded against `Base.h` and from the function's `return` lines, not from its `@retval` doc comment.
  Why: an EDK2 header comment says RETURN_INVALID_PARAMETER where the code returns RETURN_UNSUPPORTED, and the registry plate copied the comment.

**Rule 7, the description.**

- **D1.** Always pass `section` to `ghidra_describe` unless you mean to replace the whole document, and check the answer's `sections` list and `bytes` after every call.
  Why: `text` with no `section` replaced the whole description and left one section. The summary above the first `##` has no section name: resend the whole document to change it.
- **D2.** To change a `###` subsection, resend its whole parent `## ` section with the subsection fixed inside, or use `old_text`/`new_text` within the parent.
  Why: `section` addresses `## ` headings only. Naming a `###` title appends a duplicate top-level section.
- **D3.** In `Execution flow` and `Failures`, mark each branch that cannot run with the module's own build values ("cannot happen: the PCD is folded to 0 in this build") and give the reason from the bytes.
  Why: a technician should not chase paths that never run. `description.md` allows "cannot happen" only when the reason is in the module's own bytes, and this rule asks for it to be said wherever it applies.
- **D4.** Set the origin (`ghidra_describe` with `origin: {category, confidence, vendor}`) before `ghidra_done`, and confirm it in the answer.
  Why: a module without an origin category is not closed, and modules have been handed back without one.
- **D5.** Write the origin `vendor` as a bare name (or leave it empty), and put any doubt in `confidence: inferred`, never in the vendor text.
  Why: the app draws `inferred` as a dashed outline, so "Insyde (not confirmed)" repeats it and clutters the label.
- **D6.** Do not take AMD MSRs, AMD register access or any other platform fact as evidence of an AMD (or Intel) origin. Only the vendor's own code, texts or libraries in the module count.
  Why: a core EDK2 module touched AMD MSRs and is `edk2_modified`, not `amd`.

**Rule 8, interfaces.**

- **I1.** Write a record entry's purpose without naming a single installing module. Where the provider matters, write it as a condition or list every installer the closed records show. Call a PPI or protocol "vendor" only when its GUID is in no EDK2 `.dec`.
  Why: a purpose named one transport installer when two install it, and called an EDK2 PPI (`gEdkiiIoMmuPpiGuid`) vendor. Which module installs a GUID is a fact of the image, not of these bytes.
- **I2.** Record each entry's `address` as the service CALL instruction (`CALL [reg+0x18]` InstallPpi, `+0x20` LocatePpi, `+0x24` NotifyPpi, or the helper's CALL), never as the PUSH of the GUID or descriptor or a descriptor-fill MOV before it; read it in `ghidra_disassembly`.
  Why: three reviews in a row recorded the last PUSH or the GUID push; the address is meant to land a reader on the call.
- **I3.** Read the module's dependency section (`uefi_node` on the FFS file's PEI/DXE dependency child) before writing interfaces and Known problems. A PPI the depex requires always exists when the module runs, so a failed locate of it is a branch that cannot occur; say so instead of listing it as a hang or crash.
  Why: a review listed "stale pointer if the PCD PPI is missing" for a module whose depex is exactly that PPI.

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
  A decompiler's temporary is no exception: a register piece or a `HASH:` local
  (`bVar1`, `pEVar1`) is not counted against `full`, but its purpose is still
  worked out from how the code uses it, and it is named. Only where no definite
  purpose can be established may a default name stay, as an exception. Where the
  tool refuses a name for a local whose purpose is known, the default name stays
  and a comment says what the value is.
- The plate and the `pre`/`eol` comments of rule 4 are there, with the error
  and status numbers spelled out.
- Where the decompiler merged two meanings into one name, or printed a field
  through the wrong member of a union, the plate says so in one line each and
  names the places — a reader who meets `Count` holding a size will look.
- The function is named for what it does for its caller, the functions it calls
  are named too.
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

#### Rules learned in review: before `ghidra_done`

- **X1.** Before `ghidra_done`, publish, then run `code_query {what: "c", pattern: "code_r0x|[a-zA-Z]+Var\\d|param_|local_|in_|unaff_|FUN_|LAB_|DAT_|undefined|WARNING|\\(code \\*\\*\\)", summary: true}` and clear or plate every hit in the module's own functions.
  Why: `full` ignores `DAT_` globals, `LAB_` labels, temporaries and calls by raw offset. Modules with `partial 0` were reopened with dozens of hits, and five were closed with `InstallPpi` printing as `+0x18`.
- **X1a.** On a follow-up task to a closed module (a `take_shared`, a remark fix) that changes only some bodies, X1 must be clean in the bodies the task changed; leftovers in bodies it did not touch stay as they are. A new review is clean everywhere.
  Why: a narrow task is not a reopened review, and widening it costs a review pass nobody asked for.
- **X2.** Put a regex in `code_query`'s `pattern`, never in `search`.
  Why: `search` is a plain substring, so `A|B` answers a false 0 and a close check passes on nothing.
- **X3.** Leave a `(code **)` call only where the structure behind it is truly unknown, and name that table in the plate.
  Why: PEI and DXE services and known PPI or protocol slots have types. An untyped `PeiServices` local prints `InstallPpi` as an offset.
- **X4.** Before `ghidra_done`, check that `code_query` level `partial` and level `decompiled` both list nothing; `ghidra_functions {filter: "unfinished"}` is not enough.
  Why: the filter checks names and plates only. A module went to done with 19 bodies missing their step comments.
- **X5.** Report a body as done only when its `code_query` row, read after the publish, says `review_level: full` with empty `review_gaps`. Otherwise say "read, not closed", and say how each body was read (whole instructions, part, C only).
  Why: "done" has meant "read and plated" while the row still had gaps, and `full` shows that fields are filled, not that they are right.
- **X6.** While editing, judge progress from `ghidra_function`'s `leftovers` (live), not from the store's `review_gaps`, and quote store numbers only after a publish.
  Why: `review_gaps` is one publish behind, in both directions. Register inputs such as `in_R8` count as fragments, not gaps: mention them in the plate.
- **X7.** Run `ghidra_gaps`, create every `body` target, and run it again until only `unclaimed` spans remain, then report both the span count and the bytes.
  Why: spans split when a function is created, and new targets appear inside them. A prologue scan missed 20 of 42 bodies. Do not invent a body for a span nothing points at.
- **X8.** Before closing, check that every function with an EDK2, AMD or Intel library name is either a registry link or plated "Not a registry function: <reason>", and that no signature still contains `undefined`.
  Why: a module was closed with seven library bodies never proposed. Neither "full" counts nor a clean pattern search show that.

### Library functions

A library function is code the module links in rather than its own work. It lives
in the registry and nowhere else: a module stores a link to its entry, and has no
field for its name or its text. A review works in one transaction: through the review
`ghidra_library_candidate` proposes functions, with whose library each is, and that is
kept in the project only. `ghidra_publish` ends the stage and decides for all of them
at once. Either the registry takes every candidate, and the one publish makes the
entries and stores the module with links, one revision. Or it is refused whole, nothing
is stored, and the module does not publish until that is resolved. Ask first with
`ghidra_publish` and `dry_run: true`. Publish when a stage of the review is finished,
never to get one function into the registry. The panel groups the three kinds under
Library functions and marks each function with its kind: **EDK2**, **AMD**, **Intel**.
The kinds are reserved for every review, whatever vendor's module is open.

| `kind` | Whose | What it covers |
| --- | --- | --- |
| `edk2` | EDK2 | MdePkg, MdeModulePkg and UefiCpuPkg libraries: BaseMemoryLib, BaseLib (its 64-bit math included), HobLib, PeiServicesLib, PcdLib, IoLib, DebugLib, TimerLib; and the compiler helpers a 32-bit MSVC build links (`__allshl`, `__aullshr`, `_allmul`, `_aulldiv`). |
| `amd` | AMD AGESA | AGESA's own libraries: LibAmd I/O and memory access, `AgesaAssertHalt`-style asserts, IDS debug print and IDS hook dispatch, AGESA delay and register-access helpers. |
| `intel` | Intel FSP/RC | The FSP's and Reference Code's own libraries: PCH/SA/CPU register access (`PchPcr*`, `MmPciBase`), FSP debug and assert, RC delay and SMBus helpers. |

**What the registry cannot hold is the module's function.** A refusal names every
function and why. Bring it to the bar, rename it, resolve the conflict, or take it off
the list with `remove`: then it is the module's. A thunk or an external function has no
body and cannot be a candidate that passes. A body under four instructions, which
Function ID does not hash, links nothing by itself: one `RET` is many functions.
`ghidra_library` lists the entries holding its bytes as `short_candidate`. Decide
from how the function is called: bind one with `ghidra_library_apply`, or if none
fits, give it a name of its own, write its plate and a step comment, and propose it. Its
identity is then the entry's number and its bytes, so a rename changes nothing. If it
is not library code, leave it as the module's. A name alone never makes a function a
library function. What the program held before any review, such as Function ID's
`Library Function` plate, is no review's text: it meets no bar, and it does not keep
a whole match from linking.

A function is a candidate only when all three of these hold; otherwise it is the
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
   reason — "AGESA LibAmdIoWrite: assert 0x10195, S3 widths 0x81–0x83". An
   EDK2 function's is its `Evidence:` line, in the form below.

An EDK2 routine inside an AMD or Intel module is EDK2. Evidence short of
point 2 is not enough: such a function is no candidate, and the review reads it.

**An EDK2 function takes its text from the source.** Read the source at the
pinned tag, `edk2-stable202608` (`~/Projects/edk2-stable202608`), never
master: line numbers move between versions. Finding the function and judging
that the body is it stay yours — the PEI, DXE and MM variants of a library
differ, and some functions exist in C and in assembly. Once it is identified:

- its name, its parameters' names and types (`IN`, `OUT`, `CONST` included)
  and its return type are the source's prototype;
- a local that stands for a source local takes that local's name;
- the plate is the source's doc comment (`@param`, `@retval`, the
  description) in the plate's own words, plus what this body does
  differently;
- you name only what the source has no name for — a local inlining created,
  a constant folded in from the module, a variable split or merged — and say
  in a step comment where the compiler changed the code: the callee it
  inlined, the test it dropped;
- the plate ends with the citation, in exactly this form:
  `Evidence: <Function>, <path>:<line>` — the path from the tree's root,
  the line the one that holds the function's name in its definition (for an
  assembly routine, its label). A remark may follow:
  `Evidence: GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:181, with GetNextGuidHob inlined.`

A publish checks every `edk2` candidate's citation against the tag and answers
`evidence`: for each function whose line does not hold, `no_evidence`,
`unparseable`, `file_not_at_tag`, `not_in_checkout` (the tag has the file,
the server's copy does not), or `not_definition` with `defined_at`, the
line the file does define it at. It is a warning, and the publish is stored;
correct the plate and publish again. `evidence_unchecked` says why nothing was
checked.

**The library registry.** The registry is shared by every module
(`Design/LIBRARY_REGISTRY_PLAN.md`) and keyed by a body as Function ID hashes it. It
takes a function only at the highest bar: the bar of "What a finished function looks
like" (a real name, every parameter and local named and typed, the plate with its
evidence, step comments). `ghidra_publish` with `dry_run: true` answers what it would
do, the gaps of a candidate short of the bar included. A name given to a
decompiler temporary (`HASH:` or `unique:` storage) is not in the entry. A candidate that is an
assert routine says so with `assert_routine: true` on its row, so the registry knows
its codes from its callers' bodies.

A new entry, by whichever publish, rewrites at once every module the store holds with
that body: its row becomes the link, its review loses its words on the function, and
its revision stays. Its project does not change.

`ghidra_publish` offers the candidates and the registry functions that became dirty
(below), and answers what happened:

- `library.added`, `library.updated`: the entries this publish made or moved
  to their next version; the ones it matched are a count
  (`library.unchanged_count`) unless `full: true` is given;
- `library.conflicts`: entries this module's review would replace — the entry's
  name and version, `changed` (what would change), `names` (the equates and
  labels its C prints otherwise), who wrote it (`held_by`), and the name this
  module proposes. The whole publish is refused and nothing is stored.

**The registry and the shared type archive follow one rule.**

| what arrives | what happens |
|---|---|
| new (a candidate, a type) | accepted |
| the same | nothing changes |
| only additions | the entry's next version, from any module, on any version it was made on |
| a replacement of what is there | the whole publish is refused, naming the source |

An addition is a comment or a plate where the entry had none, a name or a type in
place of a Ghidra placeholder, an equate or a label the entry did not name. The
function's name, its return type, its convention, a parameter's type or written name,
and any text already written are the entry's: changing one is a replacement. Everything
the entry says must still be there, word for word.

**Avoid replacing a shared definition unless the code proves it wrong.** When it does,
propose the replacement: two other agents agreeing apply it at the module's next publish
(see "Changing a shared definition" below). Renaming an entry is such a replacement:
name the function in a module that links to it, and propose that module's review.
Taking out, restoring and splitting an entry are proposals too (`ghidra_type_propose` with
`change`, below). Write down what was found in the report to the person.

A replacement refused: take the entry's text with `ghidra_library_apply`, `address`
and `take_text: true`, make the addition over it, name with `ghidra_label` any label
the refusal lists (`label -NAME`: an entry holds labels only as C text, so `take_text`
cannot place them), and publish again. Each version names its module and a reason in the
entry's history: `entry_reasons`, an object of entry id to why, gives it in the
review's words, and an addition without one says what was added. A history row's
`changed_from` is the module a change came from where `source` still names the review's
author: a rename, a take-out, a restore, a split, a recorded part.

A dry publish (`dry_run: true`) answers what the registry would do and writes nothing:
`library` with the entries it would add or move and the conflicts it would refuse for,
and `library_refused` with the words of the refusal.

`ghidra_library` lists each match with two readings of the same review: `gaps`
— what the function's review still lacks, as the last published analysis
recorded it (the bar's own reading, not the listing's, whose locals include
stack slots the decompiled C never mentions) — and `entry_gaps` — what the
entry's review lacks, read from the entry object. Compare them before
changing anything: a function with gaps and an entry without is the entry's;
the other way round is this module's. If the program has changed since that
publish, `code_query` says so with `unpublished_writes`, and the gaps are the
published ones. The names-and-types reading says what it can: a value the
entry split into two variables (a 64-bit register as two dwords) is a reading
of the C, not a gap, and stays one.

**One description, in the registry.** A library function is one code, one C and
one description, whichever module it is in. Creating a module links its function to
the entry: the number, the name and the signature its callers print. The panel and
`code_query` show the entry. To change an entry, write in the function of any module
that holds it, and publish: see "Reading through". A text true of one module only
means the function is not a library function: do not propose it.

**A name goes by meaning, not by who came first.** A different body is a different
function, with its own entry and its own name, and a library name is unique in the
registry. A publish that offers a body under a name another entry holds answers
`library.name_conflicts` with `held_by`. Read that entry beside the new function
(`library_registry`) and compare what they do. Rename the new function; if the name is
too wide for the old one or
fits the new one better, rename it in a module that links to it and propose that
module's review: renaming an entry is a proposal's, as any replacement is. A module's own
function
is in the module's scope: it is not offered here and conflicts with nothing elsewhere.

**What a library function is.** It depends on no module, which is decided bottom-up:
functions that call nothing first, then their callers.
- It refers to no data, or only to a constant defined in its own library's source
  file. Compare the bytes with that source and cite the file and line with
  `ghidra_library_cite`, one citation per constant. Code without sources in the tree
  cannot qualify through a constant.
- A GUID global is no obstacle when it carries the GUID registry's name for its value
  (person's ruling 2026-11-25, issue d92d6b88): `gEfiPcdProtocolGuid` typed `EFI_GUID`
  is a known constant — EDK2's AutoGen gives each module its own copy of the value the
  package `.dec` fixes — and a body that passes its address does the same in every
  module. The entry records the global's registry name and value; in another module the
  body is the entry's only where the global there has the same name and value. A GUID
  global under another name, or of a value the registry does not hold, is still the
  module's data: the refusal says what the registry calls it, or to add it with
  `ghidra_guid_add` first.
- A module global of a shared type is no obstacle: `gBS` typed `EFI_BOOT_SERVICES *`,
  `gST`, `gImageHandle`, a PCD protocol pointer, a boot-script table pointer — a global
  a review named and typed with a type the EDK2 archive or the shared review archive
  holds under that name, with the same shape. The entry keeps the type it reads at each
  such instruction (and the name, for a reader), never an address; in another module the
  body is the entry's only where its own global there has the same type. Untyped data, a
  raw `undefined8`, a type only the program has, or an unnamed global (its C
  would print the module's address) is still the module's data: type and name the global
  first. `ghidra_library` lists what a candidate reads under `globals`, each with
  `shared`.
- It calls only functions the registry already holds.
- A doubt keeps it in the module.

A publish refuses a new body that fails this, under `library.not_library`, with `why`:
`data` (each datum by address, name and type, and the offset of the instruction that
reads it: `0x8F50 mHobList (void *) at +0x4`; no citation), `callee` (the names), `global` (a held body whose
global here is not of the type the entry reads: the reason names the global and the
type), or `taken_out`. Bodies of one
publish enter together when each one's callees are held or among them, so a pair that
call each other enters as a pair; a citation can be given before a body's first publish. The owner reads data references from the instructions and treats
a constant that lands in the image as one, so it errs towards refusing.

**What a module stores of a registry function.** A stored function is one of two
things. An own function has its name and its text and no library field. A link has
`registry`, the entry's number, and its own facts: `entry`, `size`, `callers`,
`callees`, `targets`, `body`, `reference_bytes` and `globals`. A link has no name, signature,
plate, comment, C or instruction, in the artifact and in the review document alike,
and no form holds them: the store writes every analysis through that one form,
whatever it was given. The instructions are the registry's, one list per body, with a
call to another library function kept as that function's number; `targets` says where
each such number (and each data reference, by label) is in this module, and a reader
gets the instructions at this module's addresses. A body links only if that rebuild
gives exactly its real bytes and text; a function whose code differs is the module's.
A library function calls only library functions, of its own library or of one it
depends on. The store holds those dependencies (`libraries` in `library_registry`'s
answer): EDK2 depends on nothing, AMD and Intel on EDK2, and not on each other. A
candidate that calls what the registry does not hold (`why: callee`) or a library its
own does not depend on (`why: dependency`) refuses the publish, and that says it is
not a library function. `library_registry` with `part: instructions` shows the code by offset, each
call by the name the callee has now. The Ghidra project is the review's own, and a
publish does not clean it: what was written on a function stays there, and only the
marks below change. The entry records the equates its C prints, and holds no labels. A
function written on since it was bound is dirty, `library_entry.state: edited` in the
project's answers; its text no store holds until the registry takes it. An entry from before
entries recorded equates learns them at the next publish of the module its C came
from, with no new version, and a history row says so. A caller's own C prints a
callee's name as it stood at that module's last publish: after an entry is renamed,
the caller shows the old name until its module publishes again. A write in a linked
function first brings the entry's current text into the project, so it works on what
the entry says; the publish takes it back out. The body's key masks an operand, so a
function whose data references point at other bytes than the entry's
(`reference_bytes`) is another function, however alike the instructions. A reference
reads 16 bytes, a string only up to its terminator, and anything in doubt counts as a
difference. One limit: a GUID whose first byte is printable and whose second is zero
reads as a one-character string, so two such GUIDs with the same first byte read
alike. A plan step `state: global` is a match whose global is untyped or of another
type than the entry reads: type the global, and the next plan links it. An entry learns its bytes when its source module publishes; until then it
decides nothing and lets a holder through, so a source module publishes first.

An entry's C is its text, so what a printed name means is the entry's: the entry records each equate
its C prints, with value and comment, and a holder's C reads the entry's. A linked function's own
equate is never printed: `ghidra_function` lists the entry's under `equates`, and an equate the
project holds beside them under `project_equates`. An edit in a linked function brings the entry's
equates with its text, except on an operand the project already names; that name is then the one the
publish offers. Any equate or named label the offered C prints differently from the entry's moves the
entry's version, so it needs a reason, whatever else was edited: the row names it in `names`. An
equate is not one module's fact once it is offered: name a value in a shared function only for what
it means in every holder. Named labels are not brought by an edit: another holder's edit drops one,
and the row says `label -NAME`. The listing is not the entry's: an instruction there shows the
equate this project holds, or the number where it holds none, so a holder's ASM and C can print
different names for one constant. The C and `equates` say what the entry means; `project_equates`
and the listing say what this project holds.

**Reading through.** A function at its entry reads as the entry wherever it is read:
`code_query` and `ghidra_function` give the entry's name, signature, plate, comments and C with
`text: "registry"`, and addresses and names that are this module's own. `parameters` and
`locals` stay the project's. Any write in the function makes it `edited`: it answers as Ghidra
holds it. A `ghidra_publish` that changes its review makes that the entry's next version, for
every module that holds it, from any holder. One that does not — a temporary's name, a label,
an equate alone — leaves the entry as it is, and the function reads as the entry again; a name on
a temporary is then not kept. A review ends with
`ghidra_publish`. `text_unavailable` says why a marked function has no `text`. A name that still carries the publisher's address is listed under
`publisher_addresses`, without a link. A mark on an entry given back is no mark: the function
reads its own text and shows no `library_entry`, and the next open releases it.

A pair enters only whole, in one publish of one module: propose both. With its other
half in another module, or with one half short of the bar, the publish is refused
under `callee` or the bar, until the review resolves it or takes them off the list.

**Putting the registry in order is a proposal.** `ghidra_type_propose` with `change`,
`reason` and the `module` the review found it in; agents vote, or the person decides on
the server's console, and the server applies it the moment it is agreed. The history keeps
the reason and who agreed. What the registry would refuse is refused before it is proposed.
- `change: take_out` with `id` (and `body` for one body of it) gives an entry back to its
  modules. A publish does not offer it again. A function that held it is the module's
  again, with the text its project holds; one with none takes the entry's at its module's
  next open. Open and publish every module that holds it. `change: restore` with `body`
  takes a wrong decision back; the body comes back as the proposing `module`'s function,
  so propose it from a module whose function is the entry's. An entry whose source is the
  wrong module is put right the same way: take its body out and restore it from the right
  module.
- `change: split` with `id`, `body` and `name` makes one body its own entry under a
  narrower name.
- A text is replaced only by a proposal (below): agents vote, or the person agrees it on
  the server's console, and the module's next publish applies it. There is no other way
  to replace a shared type or change a registry entry, the administrator's included; a
  citation (`ghidra_library_cite`) only adds and is made directly.

**A refusal for a replacement.** `library.conflicts` means this module's review would
replace what the registry says. Read the entry's review (`library_registry` with its
`id` gives the header — signature, parameters, plate; `part` reads `c`, `locals`,
`constants`, `comments`) beside the module's. What the entry lacks goes in as an addition over its text.
What the entry has wrong is proposed, with the evidence (`ghidra_type_propose`). Never replace an entry because it is another module's or older.

`library_registry` reads the registry: its entries by name and kind, the
taken-out bodies and the citations (`show`), and one entry's review and history,
taken-out ones too. A recorded function's `instructions`, `c_spans` and
`c_fields` are left out of that answer and read apart with `part`, a page at a
time.

**Applying the registry.** `ghidra_create` applies the registry to the module it
opens and says what it did in `library`; `ghidra_library` lists the matches at
any time, and `ghidra_library_apply` without `address` applies them again. A
match is by body: the same code, with the addresses a relocation moves masked.

- A matching function links: it takes the entry's number, its name (the old one is
  kept in the name's reason) and its signature with its storage, and what the project
  wrote on it stays in the project, unread: a reader is shown the entry.
  `results[].marked` says it is linked, `results[].renamed` what was renamed. There are
  never two names or two descriptions for one body in the store.
- Before adding to such a function, take the entry's text: `ghidra_library_apply`,
  `address`, `take_text: true`. A write made on what the project happened to hold is
  refused at the publish, short of the bar or as a replacement.
- What an entry carries is the review the decompiled C shows: locals with the
  decompiler's names and types, none for a stack slot the C never reads, and
  none for a register or a value split over registers — those are the
  decompiler's pieces, as the bar reads them, and never a gap.
- `edited`: a dirty function. A publish offers it, with no candidate mark, and the
  table above decides; `ghidra_library_apply` with `address` makes it clean again, and it
  offers nothing. A success takes the dirty and candidate marks off, and nothing else.
- `dry_run: true` on an apply answers the same `results` and writes nothing: each
  entry is applied in its transaction and rolled back.
- `candidates`: a body of an entry's shape with other constants, each one
  listed with the entry's. Another constant is another function — an MSR, a
  port, a mask or a size changes what the code does — so review it as a
  function of its own. The exception is the code an assert routine is called
  with (AGESA's `file id << 16 | line`): a body that differs only there is a
  `variant` of the entry and links as one by itself. Take a candidate with
  `ghidra_library_apply`, `address` and a `reason` only when the values are shown
  to make no difference, or refuse it with `decline: true`.

#### Rules learned in review: library functions

- **L1.** Before the first publish that adds an entry, read each new candidate's instructions and C after its plate is written, and describe what this build does, not what the source says.
  Why: the publish makes the plate an entry at once, for every module with that body. A `CompareMem` plate copied the source's zero-length test, which the build had dropped.
- **L2.** After a publish answers `library.added`, read `ghidra_function` on the source function and quote its `library_entry` (`id`, `state`).
  Why: entries were "added" while their source functions stayed unlinked, and row counts did not show it.
- **L3.** Name a library function that differs from its EDK2 routine by the EDK2 name plus a suffix for the difference (`PeiServicesAllocatePages_BootServicesData`, `AllocatePool_RegArg`), never by a new base name.
  Why: a base name the tree does not have cannot be grepped or cited.
- **L4.** Keep an entry's plate and comments free of any one module's addresses and callers: say what the body does, give a cause such as "probably folded because callers check" as an inference, and put caller facts in the calling module's own function.
  Why: the entry text shows in every module that links the body. One module's call site is false or meaningless in the others.
- **L5.** When a library-looking body's id differs from an entry's only in the length prefix, compare the bytes, check the xref type on its tail `JMP`, and clear a `call_return` override there with `ghidra_flow_override` `none`.
  Why: the override changes how the body is cut, so identical bytes stop matching the entry.
- **L6.** After a `ghidra_signature` on a registry-linked function, read back its plate, step comments and locals before any dry run. If the entry's text is gone, restore it with `ghidra_library_apply {address, take_text: true}`.
  Why: a signature on a link has stripped the entry's plate, comments and local names. A proposal built on that body would offer an empty entry.
- **L7.** When verifying an EDK2 `Evidence:` line, check the cited file and function in the tag tree, not only that the line parses.
  Why: 12 of 69 plates written from memory named the wrong library or claimed checks the source has. The publish's `evidence` check proves the line, not the library or the logic described.

### Changing a shared definition

This is the rule for a change to a shared definition — a shared type, or an entry of the
library registry — set by the person (2026-11-09). It is not a peer's or a role's to
narrow or widen: an agent that disagrees with it asks the person and meanwhile follows
it. It binds every agent that reaches the review tools — on the server's own MCP, or
through ByteRipper on any Mac (the app's MCP serves the same tools, and this skill in its
review kit) — and every such agent's vote counts the same.

| the change | who accepts it | how |
|---|---|---|
| a new type or entry, the same one | nobody needs to | the publish takes it |
| a type's addition — an enum member, a comment or description, a real name for a placeholder, a placeholder (`Unknown…[N]`, `field_0x…`, untyped bytes) cut into fields that stay inside its bytes, named fields at their place and size, the size unchanged | nobody needs to | the publish makes the shared types' next version |
| an entry's addition — a comment or a plate where it had none, a name or a type for a Ghidra placeholder, an equate or a label it did not name | nobody needs to | the publish makes the entry's next version |
| a type's replacement by the module that wrote it into the shared types, when no other module of its size holds it (no published review, no running program, no project with unpublished writes) | nobody needs to: the author corrects its own error | the publish takes it, `types_taken_as_origin` |
| an entry's replacement by the module that wrote its current version, when no other module of its size holds it (no published review linking it, no module one of its bodies came from, no project with unpublished writes) | nobody needs to: the author corrects its own error | the publish takes it, `library_taken_as_origin` |
| a replacement — anything else: a type's named field moved, resized, retyped or renamed, its size changed; an entry's name, signature, convention, a parameter, or any text it holds | two agents, by vote, or the person | a proposal; or the person in the console |

**A proposal.** Only the module's holder proposes, with the module in work and its publish
refused for the replacement: `ghidra_type_propose`, `reason` giving the evidence — the
instructions and offsets in this module that prove its layout or its review, and what
disproves the shared one. One proposal carries every type and every registry entry the
publish would replace. It keeps each type's two texts, the module's and the shared one,
and each entry's changed fields as the entry holds them and as the module offers them, as
they were when it was made. One live proposal per module, per type and per entry. A
proposal is made only with evidence; one the code does not support is not made.

**The vote.** `ghidra_type_vote`, by agents other than the author, each under its own
name (`agent`), wherever it runs: an agent working through ByteRipper on another Mac
votes like one on the server. Agents are told apart by that name alone, case aside — a
name is one agent whichever token or Mac it comes from, so an agent never votes under
a second name. A later vote of the same agent replaces its earlier one.
- `agree` — the voter read both texts, the author's evidence, and the instructions
  themselves: this module's at the addresses named, and those of the modules that use
  the type (`ghidra_type_uses`) or link to the entry (`library_registry`). Never on the
  author's word alone.
- `object` — with `text` naming what the code contradicts, with addresses. An objection
  is for wrong evidence only, never to hold a proposal back for someone.
- A voter who cannot settle it from the code does not vote.

**When it applies.** The proposal is `agreed` when two agents other than the author
agree and no objection stands. An objection stands until the agent that made it votes
`agree`; nobody else lifts it. An objection made after the agreement takes the
proposal back to `open`. The module's next publish (`ghidra_publish`, `ghidra_done`)
then replaces them: the types as the shared types' next version, each entry as its next
version with the proposal's reason, id and voters in the entry's history. Only if the
module still defines them as proposed and the shared ones are still those voted on;
otherwise the publish is refused as before, and the holder proposes again.

**After it.** The modules that wrote the replaced definitions, every module whose
published review uses a replaced type, and every module whose links the registry moved to
a replaced entry's new version get a remark on their tickets; their reviews are checked
again like any remark. Nobody waits for them before the replacement.

**The person** can agree or reject any proposal in the server's console (**Review
Tickets**, "Shared-definition proposals"), whatever the votes; that is the only way a
shared definition is replaced without the votes. **Activity** shows a module in work's
live proposal beside its lease and opens it. The author
`withdraw`s its own proposal.

#### Rules learned in review: after a proposal is applied

- **T1.** After a proposal is applied, open each module that uses the type (`ghidra_type_uses`) and run `ghidra_type_definition` on the type there. Send a remark by hand to any that reads `same: false`, including modules whose C never prints the type.
  Why: nothing re-exports the modules that use the type. Each keeps its old copy, its next publish then conflicts, and the server's automatic remark misses modules whose stored C does not name the type.
- **T2.** Take a changed shared type only on an owner that started after the change was applied. If `take_shared` brings back the old layout while answering `taken_from_shared: true`, publish or give the module back and take it again.
  Why: a running owner reads the shared types from its start-time copy and never reloads it.
- **T3.** Take shared types in this order: member function typedefs whose arguments do not name the struct, then the struct, then members that take `This *`. Take every `STRUCT_Member` typedef the proposal names, not only the struct, and check `same: true` after each take.
  Why: a struct take leaves the program's own member prototypes, so calls keep the old arguments. A member taken before its struct gets `This` typed `X.conflict *`.
- **T4.** When a take still reads `same: false`, redefine the program's copy in place: one `ghidra_type` with `c` (no `/* 0xNN */` offset markers, packed as the shared text), `description` and the shared `comments`. Never delete the copy, and read back the C of every use.
  Why: a delete can strip the type from signatures, locals and data. Pasting the shared C as it is folds the offset markers into member comments, and `same` stays false.
- **T5.** Before proposing, gather every change to the shared types and entries the module needs, since a module has one live proposal, and send each type complete the first time.
  Why: piecemeal extensions mean withdrawn proposals and extra vote rounds.

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

The server keeps the leases (`<store>/private/leases.json`, across restarts):
a call on its MCP socket holds a module as `local MCP`, an HTTP client as
`token <name>`. `GET /ghidra/v1/leases` lists the modules in work; an
administrator closes one with `DELETE /ghidra/v1/leases/<module>` or from the
console's Activity page, which shows each module in work with what its holder
has done under the lease, and under it the server log: every take, give-back,
close and publish (refused ones too) with its holder, and the server's
restarts with its version, two weeks long (`<store>/private/events.jsonl`).
Every agent on the socket is the one holder
`local MCP`, so a lease of it also names the connection that took the module
and the one that last named it, and a connection's card names the Claude Code
session behind it. A client waiting on `GET
/ghidra/v1/leases/<module>/wait` hears of it at once. Every `ghidra_` call,
the publish included, goes to the server.
The store it publishes into is its own — `<Server>/Analysis` by default, with
its projects in `<Server>/GhidraProjects`, apart from the app's — and `--store`
names another directory; `cas_cli.py --store` reads the same one from the
terminal. A publish through the server is the only way a client's work reaches
that store: the store's write routes (`PUT objects`, `POST analyses`, `POST
reviews/<module>`, `POST library`, `POST import`) take an `admin` token, and
`cas.write` is left the references and the publish.

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

The app's store, and the scripts' on this Mac, is
`~/Library/Application Support/ByteRipper/Analysis`, or wherever `--store`
says; a server keeps its own (above):

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

### Rules learned in review: the code store

- **Q1.** Treat `code_query` as the last publish, even when it answers `live: true`. Read the live program with `ghidra_function`, and repeat a `code_query` read after the module's last publish before reporting a finding from it.
  Why: a "read-back" through `code_query` between writes reads the previous revision. A finding was reported from a plate that a newer registry version had already replaced.
- **Q2.** To find bodies with no C, run `code_query {what: "c", search: "{", limit: 1}` and compare `functions_matched` with `total`.
  Why: a function with no C is never `full`, and this finds them in one call.

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

### Rules learned in review: what the decompiler gets wrong

- **W1.** Read the conditional jump in the disassembly before writing which side of a test runs (return on success, which bit selects which behaviour, "stops at the first X").
  Why: the C printed `if (~EFI_SUCCESS < Status) return Status;` for a `JNS` that returns on success. Locals merged across two shifts carried each other's bit names.
- **W2.** When the C's names are wrong but its uses are right, say so in the plate rather than renaming a merged variable blindly.
  Why: a rename of a merged variable can re-render the whole body.
- **W3.** On x64, read the arguments of a variadic call, or of a call through an untyped pointer, from the stores before the `CALL`. Fix them with `ghidra_signature` on a known callee, or say in the plate that the decompiler lost them.
  Why: Ghidra drops stack arguments five and later when it does not know the callee's arity. The C shows a four-argument call to a six-slot format.
- **W4.** Before writing that a loop bound or count is overwritten by a callee, find which register or stack slot the compare actually reads.
  Why: the decompiler merged a register copy with an out-parameter's slot, and a plate recorded a defect that does not exist.
- **W5.** Before calling a pushed register a constant, look for a back-edge to the push site, and check against the callee's own `[EBP+n]` reads.
  Why: a register zeroed before a loop was the loop index, and reading only the first pass nearly forced a wrong change to a shared prototype.
- **W6.** Do not trust `ghidra_xrefs` or the store's callees to list every call: read the instructions for `MOV EAX,imm; CALL EAX` before calling a plate's "calls X" false.
  Why: an indirect call through a loaded constant is missing from both lists.

## Check

A run is deterministic: the same dump, node and Ghidra version give the same
module and the same function list. Useful checks:

- `ghidra_create` answers the module's SHA-256 and its blocks; the same image
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
