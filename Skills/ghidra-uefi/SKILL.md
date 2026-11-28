---
name: ghidra-uefi
description: Review one PEI or DXE module of a firmware dump in Ghidra — ByteRipper or byteripper-server is the oracle for where the module is and what its bytes are, and this skill reviews it in a kept Ghidra project through the `ghidra_` tools: decompiled C, names, signatures, types, comments, a module description, published into the code store. Use when a person asks what a PEIM or DXE driver does, where a function is called from, or why a module in a dump misbehaves; when a module inside a Tiano or LZMA section has to be disassembled; or when a firmware image has to be read as code rather than as bytes.
---

# A UEFI module in Ghidra

ByteRipper knows where a module is: it has walked the volumes, opened the FFS
files, decompressed the Tiano and LZMA sections and named the PE32 and TE
images. Ghidra knows what the module means. This skill is the narrow path
between them. It never parses firmware volumes itself — a second parser would
disagree with the panel the person sees. The bytes come from the server's tree;
the review is made through the `ghidra_` tools.

| reference | what it holds |
|---|---|
| `reference/uefi-images.md` | the structures and the addresses |
| `reference/ghidra.md` | import rules, the review tools by task, constants and equates, pitfalls |
| `reference/uefi-pass.md` | what `ApplyUefi.java` names and types before a review |
| `reference/description.md` | the module description: sections, Markdown, links, origin, interfaces record |
| `reference/library.md` | the library registry and the shared definitions in full: links, entries, additions, proposals, votes |
| `reference/code-artifact.md` | the stored artifact's schema, queries and limits |
| `reference/cas.md` | the code store, its command line, and the analysis server |

The scripts (`owner/`, `scripts/ApplyUefi.java`, `ExportCode.java`,
`cas_cli.py`) are run by the server. A review never runs them by hand.

## 1. Find the module

The server must be running: the app with **Settings ▸ Agent** on, or
`byteripper-server`. `documents` lists what is open; with a headless server,
name the `document`. `uefi_find` with `guid`, `name` or `type: "Section"`
(`PE32 image`, `TE image`) gives the node id, the path, and `in_compressed`.
`uefi_tree` / `uefi_node` give size, types and place. A name there is the
firmware's; the name a review gave is in `ghidra_modules`. Never guess offsets:
`uefi_node_data` reads a node even when it has no file address.

A `find_bytes` match in a node carries `body_offset` (from the body, what
`uefi_node_data` reads by default) and `node_offset` (from the node's first
byte, part `all`). The wrong one reads other bytes with no error.

- **F1.** Make every "only here" or "no other module holds it" claim from a `find_bytes` with `node: "root"`, never from one without a node.
  Why: without a node only the raw image is searched; compressed modules are invisible, so zero matches proves nothing.
- **F2.** Read the PEI APRIORI order from the APRIORI file's Raw section with `uefi_node_data` (`part: "body"`), as 16-byte GUIDs in dispatch order. A description states it only as a condition.
  Why: the file usually sits in a compressed section `read` cannot reach, and the order is a fact of the image, not of the module.
- **F3.** Never decode a GUID from hex by hand. Take its string from a tool answer — `ghidra_set_data` with type `EFI_GUID` (a wrong or probe name is refused with the GUID and the registry's name), `find_bytes`, `uefi_node` — and run `ghidra_guid_add` with `dry_run` first.
  Why: Data4 is a byte array and is never swapped. A hand-decoded GUID reached the shared registry, which only an administrator can clean.
- **F4.** Copy a module's full SHA-256 from a tool answer, never rebuild it from a short form.
  Why: ticket tools accept an unknown SHA and open a stray ticket; an answer with no `name` and no `reviewer` means the SHA was wrong.
- **F5.** Compare a body with a sibling module through `find_bytes {node: "root", hex}` or `code_query {module, what: "instructions", function}` on the sibling's stored analysis.
  Why: a compressed module defeats a document-wide search; reading the store needs no lease.

## 2. Open, take, publish

`ghidra_create` takes the image `node` and `document` (or `module`, its
SHA-256, for one opened before); the server sends the bytes and converts a TE
image. Note the owner `build` and the `library` block of its answer. Each
module has one kept project; every change reaches the store only by a publish.

Read with `ghidra_functions`, `ghidra_gaps`, `ghidra_function` (C, parameters,
locals with storage, `leftovers`), `ghidra_disassembly`, `ghidra_xrefs`,
`ghidra_data`, `ghidra_strings`, `ghidra_type_definition` (the program's,
the shared archive's and EDK2's form of a type, and whether they agree),
`ghidra_type_uses`, `ghidra_description`, `ghidra_interfaces`. Write with
`ghidra_rename` (functions), `ghidra_label` (branch labels), `ghidra_function_create`
/ `_delete` / `_merge` / `_extend`, `ghidra_flow_override`, `ghidra_rename_variable`,
`ghidra_function_locals_reset`, `ghidra_signature`, `ghidra_type`,
`ghidra_set_data`, `ghidra_comment`, `ghidra_code_mode`, `ghidra_equate`,
`ghidra_describe`, `ghidra_set_interfaces`, `ghidra_library_candidate`,
`ghidra_library_apply`. `reference/ghidra.md` has each by task.

`ghidra_take` comes before the first write; only the holder writes and
publishes, through any number of `ghidra_publish`, until `ghidra_done` gives it
back. Reading needs no lease. An administrator can close a lease from the
console: unpublished work is dropped and the next call says so. Never review in
a Ghidra window of your own: nothing there reaches the store, and its lock keeps
the owner out.

- **G1.** Publish before a pause, a server update or the end of a session, and treat writes since the last publish as possibly lost.
  Why: unpublished renames have vanished at an owner restart. `unpublished_writes` can read `false` after an owner reopens; trust it only right after a publish on the same owner.
- **G2.** Prefer a plain `ghidra_publish` or `ghidra_done` over `discard: true`. After a discard, check names, types and links came back before writing again.
  Why: a discard can move the kept project to the Trash; the next open rebuilds only what was published.
- **G3.** Do not expect a `ghidra_done` with no writes to make a revision or refresh the stored C. When a module's stored recipe differs from its siblings', say so.
  Why: a publish with nothing written is skipped, so the store keeps the older exporter's C.
- **G4.** Read and write only through the MCP tools. Never open store objects or project files on disk, never delete them to force a rebuild.
  Why: a kept project is review data; a delete cannot be undone.
- **G5.** Publish a checkpoint every 8–10 finished bodies, with `dry_run: true` first. A remark that comes as old → new text is pasted as given unless the bytes contradict it; then say so in one line.
  Why: the publish is the only durable point and the verifier reads the store; ready text avoids re-deriving a wording twice.
- **G6.** Send a shell command in a response of its own, never beside MCP calls. Two large answers in one batch can share one saved file: re-read the lost one alone.
  Why: the harness refuses a mixed batch whole, and saved answers can overwrite each other.

## 3. What a review makes of the code

The aim is C that reads like the module's source: a person who never saw the
module follows a function from its C alone. Every review applies eight rules.

1. **Names, not constants.** A value of a set becomes an enum member and the
   carrier gets the enum type (`EFI_STATUS`, DEBUG levels, POST and halt
   codes, vendor group/type ids). A constant an instruction holds — port, MSR,
   PCI address — gets `ghidra_equate` as a member of a commented enum, and each
   port write an `eol` comment: register, bits, source (`reference/ghidra.md`).
   A GUID takes the GUID registry's name (`guid_registry`), in EDK2's form, for
   its label, the interfaces record and comments alike; one the registry lacks
   is added with `ghidra_guid_add` where the code shows its role, as a
   placeholder (`gUnknownPpi9C98130AGuid`) when the role has no name. A name the
   registry refuses is the registry's to keep. Write a tag on every `typedef
   enum`/`struct`.
2. **Structures, not pointer arithmetic.** Define the header, entry or record
   the code walks, from what the instructions prove (offsets read, widths); a
   field nobody can name is `Unknown08`. Fix signatures first — a typed
   parameter retypes everything that follows. Type local buffers and the
   decompiler's synthetic pieces too. **A structure the archive already holds
   is that structure**: ask `ghidra_type_definition` before defining one. Where
   a union prints a sibling member at a shared offset, the plate names the
   places. Where the module keeps a table itself, confirm offsets against its
   bytes. The server's patched language prints `SIDT` as
   `InterruptDescriptorTableLimit()` / `…Base()`; name the temporary and type
   the stack slot `IA32_DESCRIPTOR`.
3. **Names for everything that stays.** Functions, parameters, locals and
   branch labels get names that say their role, in the module's convention
   (EDK2 `CamelCase`). A function is named for what it does for its caller. A
   `LAB_` target is a step — error exit, loop head — named with `ghidra_label`,
   never with `ghidra_rename` (which renames the function around it; read the
   answer's `entry`). After any signature or variable change, list the locals
   again before renaming: old storages no longer exist.
4. **Comments a source would have — in the body.** All three are required:
   a plate whose first paragraph says briefly what the function is for (the
   panel's popover shows it alone), then what it expects, returns or halts
   with, with status and error numbers spelled out; a `pre` comment at the
   first instruction of every step — each read, walk, loop, meaning-changing
   branch and error exit — so the C reads top to bottom; an `eol` comment
   where one line needs a hardware or firmware meaning. Never paraphrase a
   line; mark what is uncertain.
5. **Read it again.** Read a rename back at once in the function's C; `ok`
   alone does not show it took. After a publish read the function and its
   callers again; what still reads as a constant, cast or `local_` is the next
   round. A name that did not take is reported, not rewritten blindly.
6. **Findings are reported, not hidden.** A defect in the code goes in a
   comment at its place and in the report; it never shapes a name. A defect of
   a tool goes to `ghidra_report_issue` once (read `ghidra_issues` first): the
   call, its arguments, what came back, what was expected.
7. **The module is described.** The description is an article for a service
   technician who does not program, in the fixed structure of
   `reference/description.md`: `# Name`, a summary, `What it is`, `What it
   does`, `Execution flow`, `Interactions`, `Inside the module`, `Failures`,
   `Known problems`, `Terms`. Start it on the first pass, keep it true at every
   publish.
8. **Its interfaces are recorded.** Every install, locate and notify of a PPI
   or protocol goes into `ghidra_set_interfaces` with its registry name,
   address, condition and purpose. Each of the three lists is answered (empty
   when the module does none); the review is not complete while one is
   unanswered. `Interactions` says in prose what the record lists.

### Rule 1 in practice

- **N1.** Before naming a GUID anywhere, look it up in the GUID registry, or grep the tag's `.dec` files with leading zeros stripped from each field (`1f34d25`).
  Why: names from memory were wrong, and a grep for the padded form called an EDK2 GUID vendor-added.
- **N2.** A depex GUID missing from the module's own INF is "added by a linked library"; name the library only when established.
  Why: PcdLib and friends add depex entries the INF never lists.
- **N3.** Expect no equate where no operand holds the value: a constant built by `XOR`/`INC`, an address-typed operand, a char-typed argument, a `MOV` the C folds. Say the meaning in a `pre` comment instead.
  Why: decompiler and tool limits, not tool failures.
- **N4.** Give enum names only to values the module or a cited source gives a meaning to. Never invent names for a bare range check.
  Why: eight `CMP AL,n` prove a range, not names.
- **N5.** For a value folded into one expression, equate the displacement and put the member's name in a `pre` comment.
  Why: a value used once has no local to rename, and an `eol` on the call does not print.
- **N6.** A BOOLEAN-typed expression printing `& TRUE` is the bit mask 1: retype it or comment it.
  Why: BOOLEAN is an enum, so mask 1 prints as `TRUE` and ignores equates.
- **N7.** Decode a 4-character table tag pushed as a dword low byte first: 0x30334124 is "$A30".
  Why: three modules had their tags reversed.
- **N8.** Name a constant from this module's own call, or a callee read at its instructions in a sibling — never from a sibling's plate text.
  Why: instructions are facts; another review's words are claims (K8).
- **N9.** A `DAT_` that is an immediate — a fixed MMIO or ECAM register, a constant address such as `DAT_ffffffff` — is not a global: name it with `ghidra_equate` on the instruction, or for an address outside the image with `ghidra_set_data` and a name only (no type), plus an `eol` comment with its width and meaning.
  Why: a datum typed outside the image is refused, and a `DAT_` left on a register read hides what the code touches.
- **N10.** A placeholder GUID name (`gUnknownProtocol…Guid`) gets its real name from the module's own string that names the interface (a DEBUG "… INIT COMPLETE" or a protocol name), offered as an addition with `ghidra_guid_add`; never invent one from the role alone.
  Why: the module's bytes are evidence; a role is not a name.

### Rule 2 in practice

- **S1.** In an IA32 PEIM, type the local holding `InterruptDescriptorTableBase()` as `EFI_PEI_SERVICES ***` first, then read the C back; check the entry point too.
  Why: one retype turns every `*(code **)(*(int *)(IdtBase - 4) + 0x34)` into a named service.
- **S2.** Write `#pragma pack(1)` … `#pragma pack()` around any record whose fields are not naturally aligned, and check the answer's `size` and offsets.
  Why: an unpacked `UINT8` before a `UINT32` pads and shifts every later offset.
- **S3.** Before `ghidra_type` with a new name, call `ghidra_type_definition` on that name; if the shared archive holds another type under it, choose another name. Never leave a name held twice.
  Why: a clash on a shared name is refused at the dry run, and a double name makes every type write fail as "Unrecognized data type".
- **S4.** Declare a structure's function-pointer members inline, never through named pointer typedefs.
  Why: a named pointer typedef never round-trips and leaves conflicts that do not converge.
- **S5.** Type a function-pointer local through a function typedef (`typedef VOID NAME(args);`, local `NAME *`), each typedef in its own `ghidra_type` call.
  Why: inline pointer types are refused; a typedef sent with its struct prints `(code *)`.
- **S6.** One struct per `ghidra_type` call; never redeclare a shared member typedef.
  Why: two structs in one text can rewrite a program `_func_N`; a redeclared shared typedef becomes a conflict.
- **S7.** Map a PPI or protocol table from its descriptor: type the descriptors, take the base from the `Ppi` field, count slots by the type the module builds, check the next datum starts where the table ends, match each slot to its body.
  Why: tables sit back to back; a table read from the wrong base invented contradictions.
- **S8.** Before writing what a PPI or protocol call means, match the GUID at the locate to its header and the call's offset to that member. A file name is no evidence.
  Why: a "board check" taken from a file name stood five revisions while the code called `GetSku`.
- **S9.** Read a PCD's start value from PcdPeim's Raw section with `uefi_node_data`; an offset past the header's `Length` is uninitialised, which starts at 0.
  Why: a "cannot run" branch must rest on the value in the bytes.
- **S10.** Code outside any function shows as `ghidra_xrefs {to}` call sites with no `function` field; create the function at the prologue.
  Why: function lists cover only what Ghidra created.
- **S11.** Merge a frame split into byte locals by typing its first slot as the whole buffer (`UINT8[N]` or the record), then state offsets from it.
  Why: 35 `local_NN` bytes hid a wrong plate; one typed slot made offsets checkable.
- **S12.** A protocol's true size and slot count come from its installer's static interface table: read the table as u64 words with `uefi_node_data` (or `read`) at the address the install passes, and type the protocol from that.
  Why: the callers use only some slots; the installer's table is the whole structure.
- **S13.** A shared type or registry function whose layout depends on the EDK2 version takes the suffix `_STABLEyyyymm` of the first `edk2-stable` tag whose source has that layout. Find it from the per-file history (`gh api repos/tianocore/edk2/commits?path=…`, then `…/compare/<commit>...<tag>`).
  Why: a tag is a point anyone can open; a year is four releases.
- **S14.** Prefer shared types over module-local ones, and propose a layout as shared once it is confirmed in a second build (another vendor's or another board's).
  Why: shared types carry review work to the next dumps; one build can carry a vendor's change.

### Rule 3 in practice

- **V1.** After each `ghidra_rename_variable`, compare the answer's storage and `first_use` with those sent; `stale: true` or an unexpected `parameter: true` is a miss. Read locals and types back.
  Why: `ok` has landed on another local, renamed parameter 0, and kept a type other than the one sent.
- **V2.** Name temporaries — register pieces, `HASH:` locals, `bVar1`, `pEVar1` — in the first pass, with `storage` and `first_use`, by what the code does with them. Try the call before saying it is refused, and quote the answer.
  Why: a reopen to name them costs a second full read; plates have claimed refusals no call made.
- **V3.** Name a chain of temporaries each built from the one before in descending `first_use` order, last link first, re-reading after each write.
  Why: ascending, 13 of 14 were refused as "landed on another variable"; descending, all took.
- **V4.** After typing a HASH local, read `temporaries` and the locals again until no new default names appear.
  Why: one listed local can stand for two occurrences; naming one surfaces the other.
- **V5.** A local the decompiler merges or copies (`HASH`, "only finds X after its types are settled", two locals sharing storage and `first_use`) takes no name or type: the server answers 409. Give the value an `eol` comment at its first use, or a plate line, and name every other local.
  Why: Ghidra holds one variable per storage at a first use; retries only renumber the temporaries.
- **V6.** For a register pair (`EDX:4,EAX:4`) or a 64-bit register and its 32-bit piece at the same `first_use`, name only one. When a piece's name is refused, write its type first and the name second, or name the wider variable and comment the piece.
  Why: the two share one variable; the refusal (409) names the other. A type often settles which variable the decompiler keeps.
- **V7.** When a refusal says a name is "already held by" a storage the locals list does not show, rename that storage to a marker first.
  Why: a stale symbol invisible in the C can hold a name across sessions.
- **V8.** When `ghidra_signature` answers "Parameter name conflict, likely due to concurrent operation", rename the local holding that name and sign again.
  Why: a local already held the name; there is no concurrency.
- **V9.** For a 64-bit argument on a 32-bit stack, pass `storage` for every parameter and `return_storage`, and check them at the instructions. Type a 64-bit stack local by its 4-byte storage (`Stack[-0x18]:4`, type `UINT64`).
  Why: a `UINT64` parameter was aligned to 8 and moved the next one a slot, with `ok`.
- **V10.** After signing a tail-jump stub, read the jump target's signature and a few callers' locals before publishing.
  Why: a stub's signature rewrote its target and its siblings; the answer named only the stub.
- **V11.** A `locals` gap with every local named means an untyped local: give each `undefined…` a real type (`void **` is honest for an unknown target).
  Why: the gap counts untyped locals, not unnamed ones.
- **V12.** A thunk shares its target's locals: name them in the target, explain them in the stub's plate, never reset a thunk's locals.
  Why: the store keeps no C for a thunk.
- **V13.** Before `ghidra_function_locals_reset` on a function with null C, read its names from an older recipe's stored C; restore stack slots, then registers by `first_use`, then HASH, re-reading between batches.
  Why: the reset wipes every name.
- **V14.** Never narrow the type of a stack local below the width its instructions use (a `UINT64` slot retyped `UINT32`): the rest of the slot comes back as an `undefined` local. Read the access width at the instructions before retyping.
  Why: a narrowed slot split into `NvValue` and `uStackX_14`, and the function fell to `partial`.
- **V15.** Names bind to storage plus `first_use`, not to the value. After anything that re-lays a frame — a callee's prototype, a body change, a type size change, a server or Ghidra upgrade — sample the live locals against the instructions; do not trust `full`.
  Why: a migration shifted stack names one slot in reviewed modules while their rows still read `full`.

### Rule 4 in practice

- **C1.** Refer to an unnamed temporary by storage and first-use address, never by `uVar4`.
  Why: default names renumber after any rename.
- **C2.** Anchor every plate claim to an instruction address or a source-tree line, or mark it "inference".
  Why: unanchored claims were where the errors were.
- **C3.** State in plates and comments only facts of the module's own bytes; anything about the rest of the image is a condition. A search of the stored C for "this board" finds nothing.
  Why: plates are keyed by the module's hash and show in every firmware with those bytes.
- **C4.** Before `ghidra_comment`, list the function's `comments` at that address; send a plate's full text.
  Why: a comment replaces the whole kind at that address.

### Rules 5 and 6 in practice

- **K1.** Before writing a finding, open every helper it depends on, read the bytes at the cited address, decode values against the header, trace each register back to its load.
  Why: a re-read withdrew eight accepted claims.
- **K2.** Read a global's initial value from the image bytes before describing code that tests it.
  Why: a guard byte assumed 0 was 1, and the plate said the opposite.
- **K3.** Check each name against what its instruction does: sizes, flag polarity, pointer or index.
  Why: `full` rows held swapped size names and an index typed as a pointer.
- **K4.** Never use a callee list to show a callback does not run: read the registration and the signal at the instructions.
  Why: a "dead" notify ran for consoles already present.
- **K5.** Decode an attribute word or mask from its value and the source: 6 is BS | RT.
  Why: "Attributes 6 (NV | BS)" was accepted twice.
- **K6.** Before writing that a module consumes a protocol, search for its install in this module and read any table of its own function pointers.
  Why: a module can install a protocol and locate it for itself.
- **K7.** Before calling a block dead, look for data that holds its address as well as code references.
  Why: a data record named the entry of a "dead" block.
- **K8.** A plate from an earlier review is a claim: read the body before repeating it.
  Why: an early plate had a boot-mode test inverted.
- **K9.** Name a status from its value decoded against `Base.h` and the `return` lines, not the `@retval` comment.
  Why: an EDK2 comment says INVALID_PARAMETER where the code returns UNSUPPORTED.
- **K10.** Before a module is reviewed, what it is — from its file name, GUID or FILE_GUID — is a hypothesis; say so, and check it against the code.
  Why: a name says what a file claims to be; a stated guess spreads into reviews as fact.

### Rule 7 in practice

- **D1.** Pass `section` to `ghidra_describe` unless replacing the whole document; check `sections` and `bytes` in every answer. Before `ghidra_done`, the `sections` list must show all eight headings and the summary must exist.
  Why: `text` without `section` replaced the whole description; modules were sent back for a missing summary or section.
- **D2.** To change a `###` subsection, resend its parent `## ` section, or use `old_text`/`new_text` inside it.
  Why: `section` addresses `## ` only; a `###` name appends a duplicate section.
- **D3.** In `Execution flow` and `Failures`, mark each branch that cannot run in this build and give the reason from the bytes.
  Why: a technician should not chase paths that never run.
- **D4.** Set the origin (`ghidra_describe` with `origin`) before `ghidra_done`, and confirm it in the answer.
  Why: a module without an origin is not closed.
- **D5.** Write `vendor` as a bare name; put doubt in `confidence: inferred`, never in the text.
  Why: the app draws `inferred` as a dashed outline.
- **D6.** Origin comes from the module's own bytes: its code compared with the tree, or the vendor's own strings, assert codes or libraries in it. A FILE_GUID, file name or platform fact (AMD MSRs, Intel registers) is not evidence; `established` needs the comparison or a name in the bytes.
  Why: a core EDK2 module touching AMD MSRs is `edk2_modified`, not `amd`.
- **D7.** `Known problems` stays in every description and lists only what the code does, written as conditions with their practical effect ("when PCD X is 0, Y is skipped and Z follows"). Do not hunt for weaknesses the code does not show, and do not drop the section when it is short.
  Why: the section is for the bench, not a security audit; speculative weaknesses mislead a technician.

### Rule 8 in practice

- **I1.** Write a record entry's purpose without naming a single installing module; call a GUID "vendor" only when no EDK2 `.dec` holds it.
  Why: which module installs a GUID is a fact of the image, not of these bytes.
- **I2.** Record `address` as the service CALL instruction, never the PUSH or MOV before it.
  Why: the address lands a reader on the call.
- **I3.** Read the FFS file's dependency section before writing interfaces and Known problems; a failed locate of a PPI the depex requires cannot occur.
  Why: a review listed a crash for a missing PPI the depex guarantees.
- **I4.** `ghidra_set_interfaces` takes kinds `ppi` and `protocol` only; configuration tables and event groups go into the description.
  Why: other kinds are refused.

## 4. What a finished function looks like

A function is done when all of this is true:

- The signature reads in EDK2 terms, every parameter sits where the ABI puts
  it, and each is typed with the structure it receives.
- Local buffers are typed, not `undefined1[N]`.
- No `param_`, `uVar`, `iVar`, `local_`, `undefined`, `DAT_`, `FUN_` or
  `(code **)` is left. A value whose role the code does not establish gets an
  honest name (`HobOrStatus`) and the plate says what it stands for.
  Temporaries are named too (V2); a default name stays only where the tool
  refuses one (V5), with a comment saying what the value is.
- The plate and the `pre`/`eol` comments are there, numbers spelled out.
- Merged meanings and wrong union members are named in the plate.
- The function and its callees are named for what they do.
- It is in a published revision.

```c
/* Reads and validates the DOS and PE headers of an image ... (plate: steps,
   ImageError values, header offsets, what the union prints through a sibling) */
EFI_STATUS PeCoffLoaderGetPeHeader (PE_COFF_LOADER_IMAGE_CONTEXT *ImageContext,
                                    EFI_IMAGE_OPTIONAL_HEADER_UNION *PeHeader)
{
  EFI_IMAGE_DOS_HEADER DosHeader;
  /* Step 1: the DOS header. ReadSize is in/out — a shorter answer means the
     file ends before the header does. */
  Status = (*ImageContext->ImageRead) (ImageContext->Handle, 0, &ReadSize, &DosHeader);
  ...
```

A review that stops at names, or at a plate over an unmarked body, is an
intermediate state and is reported as one.

### Before `ghidra_done` and before any report

- **X1.** Publish, then run `code_query {what: "c", pattern: "code_r0x|[a-zA-Z]+Var\\d|param_|local_|in_|unaff_|FUN_|LAB_|DAT_|undefined|WARNING|\\(code \\*\\*\\)", summary: true}` and clear or plate every hit in the module's own functions. Hits left are only registry bodies and documented refusals (V5, N9, an uninitialised register input).
  Why: `full` counts plate, signature and locals only; it ignores `DAT_`, labels, temporaries and raw-offset calls. Modules at `partial 0` were reopened with dozens of hits.
- **X1a.** On a follow-up task to a closed module that changes only some bodies, X1 must be clean in the bodies the task changed. A new review is clean everywhere.
  Why: a narrow task is not a reopened review.
- **X2.** Put a regex in `code_query`'s `pattern`, never in `search`.
  Why: `search` is a substring; `A|B` answers a false 0.
- **X3.** Leave a `(code **)` call only where the structure behind it is truly unknown, and name that table in the plate. Type the globals behind such calls.
  Why: services and known PPI or protocol slots have types.
- **X4.** Before reporting, after the last publish read `code_query` `level: "partial"` and `level: "decompiled"` (both empty) and the X1 sweep. A write after the last sweep needs another publish and another read.
  Why: `ghidra_functions {filter: "unfinished"}` checks names and plates only, and a late retype can drop a body to `partial` after the sweep.
- **X4a.** `stub` counts as done, like `full`, `library` and `no_body`. Give a stub a name that callers can read (`Isr_Irq001_Stub`); it needs no plate or comments. If a stub has an effect the decompiler lost (a volatile register write it dropped, or an effect inside a call it cannot see), set `ghidra_rename stub: "not_stub"` and review it in full after the publish. `auto` removes the manual mark.
  Why: the rule reads only the decompiled C, so it misses only the effects the decompiler lost.
- **X5.** Report a body as done only when its row, read after the publish, says `full` with empty `review_gaps`; otherwise "read, not closed". Say how each body was read.
  Why: `full` shows fields filled, not right.
- **X6.** While editing, judge progress from `ghidra_function`'s live `leftovers`; quote store numbers only after a publish.
  Why: `review_gaps` is one publish behind.
- **X7.** Run `ghidra_gaps`, create every `body` target, repeat until only `unclaimed` remains; report spans and bytes.
  Why: spans split at creation and reveal more targets.
- **X8.** Every function with an EDK2, AMD or Intel library name is a registry link or plated "Not a registry function: <reason>", and no signature contains `undefined`.
  Why: a module was closed with seven library bodies never proposed; "not proposed" in a report is a remark to resolve.

## 5. Library functions

A library function is code the module links in. It lives in the shared registry
only: a module stores a link to its entry, never its name or text. Kinds are
`edk2`, `amd` (AGESA), `intel` (FSP/RC). A function is a candidate only when it
is a general service (memory, string, math, port/MMIO, delay, HOB/PPI/PCD
lookup, assert, debug print), its kind is shown by evidence (the EDK2 routine's
body; an AGESA assert code or argument convention or the same bytes in another
AMD module; Intel's open packages or the same bytes in an FSP module), and the
evidence is written in its plate. A function that touches this module's own
structures or makes its own decisions is the module's, whoever wrote it.

An EDK2 function takes its text from the source at `edk2-stable202608`
(`~/Projects/edk2-stable202608`): its prototype, its locals' names, its doc
comment in the plate's words plus what this build does differently, ending in
`Evidence: <Function>, <path>:<line>` (the line of the definition's name).

`ghidra_library_candidate` proposes; `ghidra_publish` decides for all at once
— every candidate taken, or the publish refused whole. Ask with `dry_run: true`.
A new entry rewrites every module holding that body. Only additions (a plate or
comment where there was none, a name for a placeholder) pass freely; a
replacement of anything an entry or shared type holds goes through a proposal,
never by force. The whole mechanism — links, `take_text`, conflicts, globals,
strings, take-out, split, votes — is in `reference/library.md`.

- **L1.** Before the first publish adding an entry, read each candidate's instructions and C after its plate is written; describe this build, not the source.
  Why: the publish makes the plate an entry at once for every module with that body.
- **L2.** After `library.added`, read `ghidra_function` on the source and quote its `library_entry` (`id`, `state`).
  Why: entries were "added" while their sources stayed unlinked.
- **L3.** Name a variant of an EDK2 routine by the EDK2 name plus a suffix for the difference (`AllocatePool_RegArg`).
  Why: an invented base name cannot be grepped or cited.
- **L4.** Keep an entry's text free of one module's addresses and callers.
  Why: the entry shows in every module that links it.
- **L5.** When a body differs from an entry only in its length, compare bytes, check the xref on its tail `JMP`, and clear a `call_return` override with `ghidra_flow_override` `none`.
  Why: the override changes how the body is cut.
- **L6.** After `ghidra_signature` on a linked function, read back plate, comments and locals; restore a lost text with `ghidra_library_apply {address, take_text: true}`.
  Why: a signature on a link has stripped the entry's text.
- **L7.** Verify an `Evidence:` line in the tag tree: the file, the function, and the logic described.
  Why: 12 of 69 plates written from memory named the wrong library; the publish checks only the line.
- **L8.** A refused candidate is resolved by bringing it to the bar, renaming it, naming and typing the globals it reads, or `remove` — never by replacing another module's entry.
  Why: the registry is shared; a refusal names exactly what to fix.

## 6. Shared definitions

A shared type or registry entry is changed by additions freely; a replacement
needs a proposal (`ghidra_type_propose`) with the instructions that prove it,
agreed by two other agents (`ghidra_type_vote`) or by the person on the
console, applied at the module's next publish. The module that wrote the
current version may correct it alone when no other module holds it. One live
proposal per module: gather every change first and send each type complete.
After it applies, check every user with `ghidra_type_uses` and
`ghidra_type_definition` (`same: true`), and take shared types on an owner
started after the change. Steps and order: `reference/library.md`,
"Changing a shared definition".

## 7. The code store

A publish exports the program as it stands and stores the artifact under the
module's SHA-256 and the recipe, with the review: revision, description,
interfaces, origin. The same module in another dump reuses the analysis.
`code_modules` lists analyzed modules; `code_query` reads a stored artifact —
functions, instructions, C, uses, strings, POST codes — with no Ghidra running.
Layout and command line: `reference/cas.md`; schema: `reference/code-artifact.md`.

- **Q1.** `code_query` is the last publish, even with `live: true`. Read the live program with `ghidra_function`; repeat a store read after the last publish before reporting from it.
  Why: a read-back between writes reads the previous revision.
- **Q2.** Find bodies with no C by `code_query {what: "c", search: "{", limit: 1}` and comparing `functions_matched` with `total`.
  Why: a function with no C is never `full`.

## 8. What the decompiler gets wrong

The loaded base is the header's ImageBase (a compressed module usually has 0,
so its addresses are offsets). x64 UEFI uses the Microsoft convention. The
UEFI pass names what EDK2 can name and no more; vendor functions arrive as
`FUN_` until a review names them.

- **W1.** Read the conditional jump in the disassembly before writing which side of a test runs.
  Why: the C printed `~EFI_SUCCESS < Status` for a `JNS` that returns on success.
- **W2.** When names are wrong but uses right, say so in the plate rather than renaming a merged variable blindly.
  Why: such a rename can re-render the whole body.
- **W3.** On x64, read a variadic call's arguments from the stores before the `CALL`; fix a known callee's signature or say the decompiler lost them.
  Why: Ghidra drops arguments five and later when it does not know the arity.
- **W4.** Before writing that a bound is overwritten by a callee, find which register or slot the compare reads.
  Why: a merged register and stack slot produced a defect that does not exist.
- **W5.** Before calling a pushed register a constant, look for a back-edge to the push.
  Why: a register zeroed before a loop was the loop index.
- **W6.** Read the instructions for `MOV reg,imm; CALL reg` before calling a plate's "calls X" false.
  Why: such calls are missing from `ghidra_xrefs` and the store's callees.

## Check

A run is deterministic: the same dump, node and Ghidra version give the same
module and functions. `ghidra_create` answers the same `module` for the same
image; a changed review is a new revision of it; `ghidra_function` after a
publish reads back what the artifact holds; `cas_cli.py verify` checks every
object, manifest and reference.
