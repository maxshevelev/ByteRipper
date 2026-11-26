# Library functions and shared definitions

The full mechanics behind SKILL.md's "Library functions" and "Shared definitions": what the registry takes, how a module stores a link, how an entry changes, and how a shared type or entry is replaced by proposal.

## Library functions

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
- A string an `amd` or `intel` body reads — a debug message it passes to a debug print,
  an assert's text — is no obstacle (person's ruling 2026-11-26): those libraries have no
  public source to cite, so the string's bytes, terminator included, enter the entry as
  part of its data, and in another module the body is the entry's only where the string
  at that instruction has the same bytes. A differing string is another function, under
  the same rules as any other difference. `ghidra_library` lists it under `globals` with
  its `text` (hex). An `edk2` body's string still needs its line cited with
  `ghidra_library_cite`.
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


## Changing a shared definition

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

### After a proposal is applied

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
- **T6.** For an agreed library proposal, read its `state` with `ghidra_type_proposals`, then publish the module unchanged. A dry run may still list the agreed entries under `library.conflicts`; the real publish applies them.
  Why: the dry run did not see agreed library proposals (server 576); the publish did. Drop this rule once a dry run answers an agreed entry correctly.
