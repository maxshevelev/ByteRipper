# The module description

A review leaves three things behind: the program (names, types, signatures,
comments), the artifact the app draws from it, and the **module
description**: one Markdown document that says what the module is for, how
it works and how it is built. The C answers *what does this function do*;
the description answers *what is this module, and where in it do I look*.
It is written for two readers at once: a person at the bench who has never
opened the module, and an agent that picks the review up later and must not
re-derive what was already understood.

The description is a result of the review, not a summary written at the end.
It is started on the first pass, corrected as the review learns, and true to
the code at every publish.

## Where it lives

- In the module's Ghidra project, in the program's `ByteRipper` options, so
  it is saved and kept with the review (`Owner.java`, `Harvest.java`).
- Written with `ghidra_describe` (or `ghidra_owner.py describe`) under the
  write lease, and read back with `ghidra_description` (`GET /v1/description`:
  `text`, `sections`, `bytes`).
- Published with the review: the publish snapshots it, stores it in the CAS
  as an object of its own (`text/markdown`, UTF-8) and names it in the
  reading — `reading.description` in the manifest and `description` in the
  module's review history (`reference/cas.md`). A change to the description
  alone makes the next revision; an unchanged one is the same revision.
- Shown by the app in the code panel, under **Description** beside ASM and C.

The owner normalises the text: LF line ends, no trailing blanks, one final
newline. Up to 256 KiB.

## Writing it

`ghidra_describe` takes the whole document, or one section: with `section`,
`text` replaces the body of that `## ` heading (without the heading) — the
section is added at the end if it is missing, and removed if `text` is empty.
Write the outline once, then work section by section; read it with
`ghidra_description` before changing a section someone else may have
touched.

- **Start early.** After the first look at the entry point and the strings:
  the title, the summary, `Identity`, a provisional `Purpose` and the
  `Open questions`. Mark what is a first guess (`provisional`).
- **Keep it true.** When a function is renamed, a guess is confirmed or
  refuted, a structure is understood, the section that says it is updated
  before the next publish. A description that names `FUN_0000123` after the
  function became `ProcessFv` is a defect of the review.
- **Finish it.** Before `ghidra_done`: every section that has something to
  say says it, `Review status` says what is done and what is not, and nothing
  provisional remains unmarked.

## The structure

The headings are fixed, in this order, in English, written exactly so — the
app, the next agent and a diff all rely on them. A section with nothing to
say yet is left out rather than left empty. `###` subsections are free.

```markdown
# <ModuleName>

<One paragraph: what the module is, its phase (SEC, PEI, DXE, SMM), whose it
is (EDK2, AMI, Insyde, AMD, Intel, the OEM), and its role in one sentence.>

## Identity
## Purpose
## Interfaces
## Flow
## Internal structure
## Hardware and data
## Errors and diagnostics
## Findings
## Open questions
## Review status
```

### `# <ModuleName>` and the summary

The module's name as the firmware file names it. The paragraph under it is
what someone reads who reads nothing else: three to five sentences.

### `## Identity`

A list of facts, each with its evidence:

- file GUID and name, FFS file type (PEIM, DXE driver, SEC core…);
- image: PE32/PE32+/TE, machine, image base, entry point, size;
- the board (vendor, model, board number) and where the module sits in the
  firmware's layout: the region, the volume, the path of names in the tree,
  the offset in the volume or in an unpacked body. Never the dump file it was
  read from: a module is the same in every dump of the board, the review is
  of the module, and a file name tells the reader nothing about either;
- source: the package it is built from (`MdeModulePkg/Core/Pei`, AMI
  `CpuPei`…) and how sure that is — matched strings, a DEBUG file name, a
  known GUID, the layout of a known library;
- the libraries linked into it that matter (`BaseLib`, `PeiServicesLib`,
  `DebugLib` to serial…).

### `## Purpose`

What the module does for the firmware, why it is in this image, what depends
on it and what goes wrong without it. Two or three paragraphs.

### `## Interfaces`

What it consumes and what it produces, as a table:

```markdown
| Interface | GUID | Kind | Where |
|---|---|---|---|
| gEfiPeiStallPpiGuid | 1F4C6F90-B06B-48D8-A201-BAE5F1CD7D56 | PPI, located | [CpuInit](0x4BF) |
| gAmdCpuPolicyHobGuid | … | HOB, built | [PublishPolicy](0x612) |
```

Kinds: PPI/protocol located, installed or notified on; HOB read or built;
variable read or written (name and vendor GUID); PCD; a callback registered;
an event signalled; a table published. The dependency expression goes here
too.

### `## Flow`

The order of what happens, from the entry point: a numbered list, one step
per thing that matters, each naming its function. Branches that change the
outcome (boot mode, S3 resume, a missing PPI) are steps of their own or
nested lists. A callback runs later: say when.

### `## Internal structure`

How the module is built: its functions grouped by role (a `###` per group,
or a table: function, role), the globals and tables it keeps, the types the
review defined and what they describe. Functions that only the linker or a
library put there are one line together, not one each.

### `## Hardware and data`

What it touches below the firmware: MSRs, I/O ports, MMIO ranges, PCI
config registers, CMOS, SPI, SMBus — with the value or bit and its meaning.
Memory it lays out (a stack, a heap, a buffer at a fixed address) and the
structures it walks, field by field where that is not in a type already.

### `## Errors and diagnostics`

What a technician sees when it fails: status codes it reports
(`ReportStatusCode` class/value), POST and halt codes, DEBUG and ASSERT
messages, a deadloop, a beep, a reset. For each: when it happens and what it
means.

### `## Findings`

Defects and oddities the review found: an unbounded copy, a wrong format, a
value never checked, a deviation from the EDK2 code it was built from. Each
with its place. Also a note where they are, and in the report to the person.

### `## Open questions`

What is not understood yet, and where to look next: an unnamed field, a
callback whose trigger is unknown, a value from another module.

### `## Review status`

What the review covered and what it did not: functions named (`32 of 35`),
what is still `FUN_`/`local_`, which revision and by whom, what to do next.
Short: a list.

## The Markdown

CommonMark with GitHub's tables, as Foundation reads it:

- headings `#`, `##`, `###`; paragraphs; `-` and `1.` lists, nested by
  indentation; tables; fenced code blocks; `>` quotes;
- `` `code` ``, `**bold**`, `*italic*`, `~~struck~~`, `[text](target)`.

No HTML, no images, no footnotes.

### Links into the code

- `[ProcessFv](0x9DFD3F8)` — a function, by its entry address as Ghidra
  holds it. The app opens it in the code; Back returns to the description.
- `` `ProcessFv` `` — a function's name written as code is a link too, while
  the module has a function of that name; so is `` `0x9DFD3F8` `` while the
  code holds that address.
- `[text](https://…)` opens in the browser. Any other target is shown as
  text.

Use the link form in `Flow` and in tables, where the name alone may become
ambiguous; the code form elsewhere.

## Tone

- Facts from the code, with the place that shows them. A conclusion drawn
  from a pattern says so (`probably`, `not confirmed`); a guess is never
  written as a fact.
- Names as the program has them now; constants by their enum name, with the
  value where a reader will look for it (`EFI_NOT_FOUND`,
  `POST 0xB2`).
- No paraphrase of the C line by line: the description is the map, the code
  and its comments are the territory.
- English, like the names and comments in the code.
- Typically one to five screens. A module of three functions needs a
  paragraph per section; DxeCore needs subsections.
